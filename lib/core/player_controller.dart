import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'download_service.dart';
import 'library.dart';
import 'models.dart';
import 'repair_bot.dart';
import 'settings_service.dart';
import 'youtube_service.dart';

/// Merkezi çalar. Bildirim, kilit ekranı, Bluetooth ve Android Auto
/// `audio_service` üzerinden bu sınıfa bağlanır.
///
/// Kuyruk yönetimi, geçiş kimliği (race guard), çevrimdışı öncelik,
/// önbellek/ısıtma, hata kurtarma ve parça atlama mantığı.
class PlayerController extends BaseAudioHandler with ChangeNotifier {
  PlayerController._() {
    // Özel AndroidLoadControl (12/30 sn, prioritizeTime) ağ dalgalanmasında
    // ExoPlayer'ı yeniden tamponlama döngüsüne sokuyordu. Varsayılan
    // yapılandırmaya (2,5/5 sn eşik) dönüldü. Lazy preparation kapalı: kaynak
    // tam hazır olmadan play() ilk milisaniyelerde klik üretiyordu.
    // Ekolayzer yalnızca AÇIKKEN zincire eklenir; kapalıyken efekt takılırsa
    // bazı cihazlarda çizirti/underrun oluşuyordu. Ayar açılınca uygulama
    // yeniden başlatılmadan refreshEqualizer() ile zincire alınır.
    _equalizer = AndroidEqualizer();
    _player = AudioPlayer(
      audioPipeline: AudioPipeline(androidAudioEffects: [_equalizer]),
      useLazyPreparation: false,
    );

    _player.playerStateStream.listen(_onPlayerState);
    // playbackEventStream pozisyon her tick'inde (~4 Hz) akıyor. Her olayda
    // _broadcast() çağırmak media-session/notification'ı ve tüm UI dinleyicilerini
    // saniyede 4 kez güncelliyordu; ana thread'deki bu yük ses yolunda
    // mikro kesintilere (çizirti) yol açıyordu. Durum/pozisyon/süre zaten
    // kendi kontrollü kanallarından broadcast ediliyor. Burada yalnızca hata
    // yakalanır.
    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace _) => _onPlaybackError(error),
    );
    _player.positionStream.listen(_onPosition);
    _player.durationStream.listen((_) => _broadcast());

    Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _recovering && current != null) {
        unawaited(_playAt(_index, resumeAt: _player.position, retry: true));
      }
    });
  }

  static final PlayerController instance = PlayerController._();

  late final AndroidEqualizer _equalizer;
  late final AudioPlayer _player;

  List<Track> _queue = const <Track>[];
  List<Track> _originalQueue = const <Track>[];
  bool _shuffleMode = false;
  bool _radioMode = true;

  int _index = -1;
  int _transitionId = 0;
  int _activeTransition = 0;
  int _generation = 0;

  bool _loading = false;
  bool _advancing = false;
  bool _recovering = false;
  bool _extending = false;
  bool _shuffleBusy = false;
  String? _error;
  int _lastBroadcastSecond = -1;
  DateTime _lastRecovery = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _sleepTimer;
  DateTime? _sleepEndsAt;

  /// Kalan uyku süresi; zamanlayıcı kapalıysa null.
  Duration? get sleepRemaining {
    final end = _sleepEndsAt;
    if (end == null) return null;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get sleepTimerActive => _sleepEndsAt != null;

  // Arka planda 3 parçanın adresini çözmek aktif ses akışının bant genişliğini
  // yiyor ve takılmaya yol açıyordu. Bir parça, iki adım ileri yeterli.
  static const int _lookahead = 2;
  static const int _maxPreloads = 1;
  final Set<String> _preloaded = <String>{};
  int _activePreloads = 0;

  /// Otomatik parça geçişinde beklenen süre. Önbellek ve ısıtma sayesinde
  /// toplam geçiş yaklaşık 1 saniyede tamamlanır.
  static const Duration transitionDelay = Duration(milliseconds: 1000);

  List<Track> get tracks => _queue;
  int get index => _index;
  bool get loading => _loading;
  String? get error => _error;
  bool get radioMode => _radioMode;
  bool get shuffleMode => _shuffleMode;
  bool get shuffleModeEnabled => _shuffleMode;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  bool get hasNext => _index + 1 < _queue.length;
  bool get hasPrevious => _index > 0;

  Stream<bool> get playingStream => _player.playingStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  bool get playing => _player.playing;
  Duration get position => _player.position;
  Duration get buffered => _player.bufferedPosition;

  int _nextTransition() => ++_transitionId;

  bool _isStale(int transition, int generation) =>
      transition != _activeTransition || generation != _generation;

  Future<void> playQueue(
    List<Track> tracks,
    int startIndex, {
    bool radio = true,
  }) async {
    if (tracks.isEmpty) return;
    _queue = List<Track>.unmodifiable(tracks);
    _originalQueue = _queue;
    _shuffleMode = false;
    _radioMode = radio && Library.instance.radioEnabled;
    _publishQueue();
    await _playAt(startIndex.clamp(0, tracks.length - 1));
  }

  Future<void> playAt(
    int index, {
    Duration? resumeAt,
    bool retry = false,
  }) =>
      _playAt(index, resumeAt: resumeAt, retry: retry);

  Future<void> _playAt(
    int index, {
    Duration? resumeAt,
    bool retry = true,
  }) async {
    if (index < 0 || index >= _queue.length) return;

    final transition = _nextTransition();
    _activeTransition = transition;
    final generation = ++_generation;

    _index = index;
    _loading = true;
    _error = null;
    _publishMediaItem(_queue[index]);
    _broadcast();
    notifyListeners();

    final track = _queue[index];
    try {
      final uri = await _resolveTrack(track);
      if (_isStale(transition, generation)) return;

      await _setSource(uri, resumeAt);
      if (_isStale(transition, generation)) return;

      _loading = false;
      _error = null;
      _broadcast();
      notifyListeners();

      await _player.play();
      unawaited(_fadeInVolume(transition, generation));
      unawaited(Library.instance.remember(track));
      // İlk tampon tamamlanmadan prefetch başlarsa aktif akışa rakip oluyor.
      Timer(const Duration(seconds: 4), () {
        if (!_isStale(transition, generation)) unawaited(_preloadUpcoming());
      });
    } on AudioBlocked catch (error) {
      if (_isStale(transition, generation)) return;
      if (kDebugMode) debugPrint('CT AudioBlocked ${track.id}: ${error.reason}');
      unawaited(RepairBot.instance.reportEvent('audio_blocked', {
        'video_id': track.id,
        'reason': error.reason,
      }));
      if (retry) {
        final direct = await YoutubeService.instance.forceDirect(track.id);
        if (_isStale(transition, generation)) return;
        if (direct != null) {
          try {
            await _setSource(direct, resumeAt);
            if (_isStale(transition, generation)) return;
            _loading = false;
            _error = null;
            _broadcast();
            notifyListeners();
            await _player.play();
            unawaited(_fadeInVolume(transition, generation));
            unawaited(Library.instance.remember(track));
            unawaited(_preloadUpcoming());
            return;
          } catch (_) {}
        }
      }
      if (_isStale(transition, generation)) return;
      _loading = false;
      _error = 'stream';
      _broadcast();
      notifyListeners();
      return;
    } catch (error) {
      if (_isStale(transition, generation)) return;
      if (kDebugMode) debugPrint('CT _playAt ${track.id}: $error');
      if (retry) {
        final direct = await YoutubeService.instance.forceDirect(track.id);
        if (_isStale(transition, generation)) return;
        if (direct != null) {
          try {
            await _setSource(direct, resumeAt);
            if (_isStale(transition, generation)) return;
            _loading = false;
            _error = null;
            _broadcast();
            notifyListeners();
            await _player.play();
            unawaited(_fadeInVolume(transition, generation));
            unawaited(Library.instance.remember(track));
            unawaited(_preloadUpcoming());
            return;
          } catch (_) {}
        }
      }
      if (_isStale(transition, generation)) return;
      _loading = false;
      _error = 'stream';
      _broadcast();
      notifyListeners();
      return;
    }
  }

  /// Parça ilk açıldığında Android AudioTrack oluşturulurken çıkan kısa
  /// klik/çizirtiyi maskeler. Ses 0'dan kademeli olarak 1.0'a çıkar.
  Future<void> _fadeInVolume(int transition, int generation) async {
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (_isStale(transition, generation)) return;
      await _player.setVolume(i / steps);
      if (_isStale(transition, generation)) return;
    }
  }

  Future<Uri> _resolveTrack(Track track) async {
    final saved = DownloadService.instance.savedPathOf(track.id);
    if (saved != null && File(saved).existsSync()) return Uri.file(saved);
    final direct = track.sourceUrl;
    if (direct != null && direct.isNotEmpty) return Uri.parse(direct);
    return YoutubeService.instance.audioUri(track.id);
  }

  Future<void> _setSource(Uri uri, Duration? resumeAt) async {
    // Fade-in öncesi sesi sıfırla: yeni kaynak açılırken eski gain kalırsa
    // ilk frame'de klik duyuluyor.
    await _player.setVolume(0);
    final isYoutube = uri.host.endsWith('googlevideo.com') ||
        uri.host.endsWith('youtube.com');
    final headers = <String, String>{
      'User-Agent': 'Mozilla/5.0 (Linux; Android 14) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/126.0 Mobile Safari/537.36',
      'Accept': '*/*',
      'Accept-Encoding': 'identity;q=1, *;q=0',
    };
    if (isYoutube) {
      headers['Referer'] = 'https://www.youtube.com/';
      headers['Origin'] = 'https://www.youtube.com/';
    }
    await _player
        .setAudioSource(
          AudioSource.uri(
            uri,
            tag: mediaItem.value,
            headers: headers,
          ),
          initialPosition: resumeAt,
        )
        .timeout(const Duration(seconds: 9));
  }

  void _onPosition(Duration position) {
    // Bildirim/media session 1 sn'de bir güncellenince bazı cihazlarda ses
    // yolunda mikro kesintiler oluyordu. Arayüz kendi positionStream'ini
    // kullandığı için 3 sn'lik kova yeterli.
    final bucket = position.inSeconds ~/ 3;
    if (bucket == _lastBroadcastSecond) return;
    _lastBroadcastSecond = bucket;
    _broadcast();
  }

  /// Sesli arama mikrofona basıldığında müziği duraklatıp geri vermek için
  /// kullanılır. `play()` bir toggle olduğu için onun yerine bunu kullan.
  Future<void> resume() async {
    if (_player.playing) return;
    if (_player.volume == 0) await _player.setVolume(1);
    await _player.play();
    _broadcast();
  }

  /// Ayarlar ekranından ekolayzer açılıp/kapatıldığında veya başlangıçta bir
  /// kez çağrılır. Parça başına çağrılmaz; aksi halde ses kırılır.
  Future<void> refreshEqualizer() => _applyEqualizer();

  Future<void> _applyEqualizer() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final settings = SettingsService.instance;
    if (!settings.ready) return;
    try {
      await _equalizer.setEnabled(settings.equalizerEnabled);
      if (!settings.equalizerEnabled) return;
      final params = await _equalizer.parameters;
      final bands = params.bands;
      if (bands.isEmpty) return;
      final gains = _eqGains(settings.equalizerPreset);
      for (var i = 0; i < bands.length; i++) {
        await bands[i].setGain(gains[i % gains.length]);
      }
    } catch (_) {}
  }

  static List<double> _eqGains(String preset) => switch (preset) {
        'flat' => [0, 0, 0, 0, 0],
        'bass' => [8, 5, 0, -1, 1],
        'treble' => [-1, 0, 2, 6, 8],
        'vocal' => [-2, 1, 5, 3, 0],
        _ => [0, 0, 0, 0, 0],
      };

  void _onPlayerState(PlayerState state) {
    _broadcast();
    if (state.processingState == ProcessingState.completed) {
      unawaited(_advance(auto: true));
    }
  }

  Future<void> _advance({bool auto = false}) async {
    if (_advancing || _shuffleBusy) return;
    _advancing = true;
    try {
      if (auto) {
        final nextIndex = _index + 1;
        if (nextIndex < _queue.length &&
            (_queue[nextIndex].sourceUrl ?? '').isEmpty) {
          unawaited(YoutubeService.instance.prefetch(_queue[nextIndex].id));
        }
        final generation = _generation;
        await Future<void>.delayed(transitionDelay);
        if (_generation != generation) return;
      }
      if (hasNext) {
        await _playAt(_index + 1);
        return;
      }
      if (!_radioMode || !Library.instance.radioEnabled) return;
      await _extendRadio();
      if (hasNext) await _playAt(_index + 1);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _extendRadio() async {
    final seed = current;
    if (seed == null || _extending) return;
    _extending = true;
    try {
      final more = await YoutubeService.instance.related(seed.id, limit: 30);
      final fresh = more.where((track) {
        return !_queue.any((queued) => queued.id == track.id);
      }).toList();
      if (fresh.isEmpty) return;
      _queue = List<Track>.unmodifiable([..._queue, ...fresh]);
      _originalQueue = _queue;
      _publishQueue();
      notifyListeners();
    } finally {
      _extending = false;
    }
  }

  Future<void> extendRadio() => _extendRadio();

  Future<void> _onPlaybackError(Object error) async {
    if (kDebugMode) debugPrint('CT playback error: $error');
    if (_recovering || _loading || _error != null || current == null) return;
    final now = DateTime.now();
    if (now.difference(_lastRecovery) < const Duration(seconds: 4)) return;
    _lastRecovery = now;
    _recovering = true;
    try {
      await _playAt(_index, resumeAt: _player.position, retry: true);
    } finally {
      _recovering = false;
    }
  }

  Future<void> retry() => _playAt(_index, retry: true);

  /// [minutes] 0 veya daha küçükse zamanlayıcı iptal edilir.
  Future<void> setSleepTimer(int minutes) async {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepEndsAt = null;
    if (minutes > 0) {
      _sleepEndsAt = DateTime.now().add(Duration(minutes: minutes));
      _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final left = sleepRemaining;
        if (left == null || left > Duration.zero) {
          notifyListeners();
          return;
        }
        cancelSleepTimer();
        if (_player.playing) unawaited(_player.pause());
      });
    }
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepEndsAt = null;
    notifyListeners();
  }

  Future<void> toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      // Bir önceki fade-in yarıda kesilmişse ses 0'da kalmış olabilir.
      if (_player.volume == 0) await _player.setVolume(1);
      await _player.play();
    }
    _broadcast();
  }

  Future<void> next() => _advance();

  Future<void> previous() async {
    if (_player.position > const Duration(seconds: 4) || !hasPrevious) {
      await _player.seek(Duration.zero);
      return;
    }
    await _playAt(_index - 1);
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  void setRadioMode(bool value) {
    _radioMode = value;
    notifyListeners();
  }

  void toggleShuffle() {
    if (_queue.length < 2) return;
    _shuffleBusy = true;
    try {
      if (_shuffleMode) {
        _queue = _originalQueue;
        _shuffleMode = false;
      } else {
        final active = current;
        final rest = _queue
            .where((track) => track.id != active?.id)
            .toList()
          ..shuffle();
        _queue = List<Track>.unmodifiable([
          if (active != null) active,
          ...rest,
        ]);
        _index = 0;
        _shuffleMode = true;
      }
      _publishQueue();
      notifyListeners();
    } finally {
      _shuffleBusy = false;
    }
  }

  Future<void> _preloadUpcoming() async {
    for (var offset = 1;
        offset <= _lookahead && _index + offset < _queue.length;
        offset++) {
      if (_activePreloads >= _maxPreloads) break;
      final upcoming = _queue[_index + offset];
      final id = upcoming.id;
      if (_preloaded.contains(id)) continue;
      if ((upcoming.sourceUrl ?? '').isNotEmpty) continue;
      if (DownloadService.instance.savedPathOf(id) != null) continue;
      _activePreloads++;
      try {
        await YoutubeService.instance.prefetch(id);
        _preloaded.add(id);
        if (_preloaded.length > 120) {
          _preloaded.remove(_preloaded.first);
        }
      } catch (_) {} finally {
        _activePreloads--;
      }
    }
  }

  void _publishQueue() {
    queue.add(_queue.map(_toMediaItem).toList());
  }

  MediaItem _toMediaItem(Track track) => MediaItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        album: track.artist,
        artUri: Uri.tryParse(track.thumb),
        duration: track.duration,
      );

  void _publishMediaItem(Track track) {
    mediaItem.add(_toMediaItem(track));
    _publishQueue();
  }

  AudioProcessingState _mapState(PlayerState state) {
    if (_error != null) return AudioProcessingState.error;
    return switch (state.processingState) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
  }

  void _broadcast() {
    final controls = <MediaControl>[
      if (hasPrevious) MediaControl.skipToPrevious,
      if (_player.playing) MediaControl.pause else MediaControl.play,
      if (hasNext) MediaControl.skipToNext,
      MediaControl.custom(
        androidIcon: 'drawable/ic_favorite',
        label: 'Beğen',
        name: 'like',
      ),
    ];
    final playIndex = hasPrevious ? 1 : 0;
    final compact = <int>[
      playIndex,
      if (hasNext) playIndex + 1,
    ].where((i) => i < controls.length).toList();

    playbackState.add(playbackState.value.copyWith(
      processingState: _mapState(
        PlayerState(_player.playing, _player.processingState),
      ),
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      controls: controls,
      androidCompactActionIndices: compact,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
    ));
    notifyListeners();
  }

  @override
  Future<void> play() => toggle();

  @override
  Future<void> pause() async {
    await _player.pause();
    _broadcast();
  }

  @override
  Future<void> skipToNext() => next();

  @override
  Future<void> skipToPrevious() => previous();

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        await toggle();
      case MediaButton.next:
        await next();
      case MediaButton.previous:
        await previous();
    }
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'like') {
      final track = current;
      if (track != null) await Library.instance.toggleLike(track);
      return null;
    }
    return super.customAction(name, extras);
  }

  void toggleLikeCurrent() {
    final track = current;
    if (track != null) unawaited(Library.instance.toggleLike(track));
  }
}
