import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_backend.dart';
import 'download_service.dart';
import 'library.dart';
import 'models.dart';
import 'repair_bot.dart';
import 'settings_service.dart';
import 'youtube_service.dart';

/// Tekrar modu. Tercih olarak saklanır ve `playbackState.repeatMode`
/// üzerinden MediaSession/Android Auto'ya da yayınlanır.
enum RepeatMode { off, all, one }

/// Merkezi çalar. Bildirim, kilit ekranı, Bluetooth ve Android Auto
/// `audio_service` üzerinden bu sınıfa bağlanır.
///
/// Kuyruk yönetimi, geçiş kimliği (race guard), çevrimdışı öncelik,
/// önbellek/ısıtma, hata kurtarma ve parça atlama mantığı.
class PlayerController extends BaseAudioHandler with ChangeNotifier {
  PlayerController._() {
    // Linux'ta just_audio'nun native implementasyonu yok: MissingPluginException
    // -> "parça oynatılamadı". Platforma göre doğru motor seçilir.
    _player = createAudioBackend();
    _player.statusStream.listen(_onPlayerState);
    _player.errorStream.listen((error) => unawaited(_onPlaybackError(error)));
    _player.positionStream.listen(_onPosition);
    _player.durationStream.listen((_) => _broadcast());

    Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _recovering && current != null) {
        unawaited(_playAt(_index, resumeAt: _player.position, retry: true));
      }
    });

    unawaited(_restorePreferences());
  }

  static final PlayerController instance = PlayerController._();

  late final AudioBackend _player;

  List<Track> _queue = const <Track>[];
  List<Track> _originalQueue = const <Track>[];
  bool _shuffleMode = false;
  bool _radioMode = true;
  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffleEnabled = false;
  String _quality = 'high';

  SharedPreferences? _prefs;
  Future<void>? _prefsFuture;
  bool _prefsReady = false;

  int _index = -1;
  int _transitionId = 0;
  int _activeTransition = 0;
  int _generation = 0;

  bool _loading = false;
  bool _opening = false;
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

  /// Radyo önerisi + sanatçı fallback toplamda 10 saniyeden fazla sürmez.
  static const Duration _radioTimeout = Duration(seconds: 10);
  static const int _maxQueueLength = 50;

  /// Yavaş ağlarda adres çözümü/akış açılışı için önceki 5/9 sn limitleri
  /// "bazı parçalar hiç açılmıyordu" şikayetine yol açıyordu.
  static const Duration _resolveTimeout = Duration(seconds: 20);
  static const Duration _openTimeout = Duration(seconds: 20);
  static const Duration _readyTimeout = Duration(seconds: 5);

  List<Track> get tracks => _queue;
  int get index => _index;
  bool get loading => _loading;
  String? get error => _error;

  /// Kullanıcıya gösterilmeye hazır hata metni. [error] kod olarak kalır;
  /// arayüz bu metni doğrudan gösterebilir.
  String? get errorMessage => switch (_error) {
        'blocked' =>
          'YouTube bu parçayı engelliyor. Farklı bir parça deneyin.',
        'offline' => 'Bağlantı yok. Parça indirilmediyse çevrimdışı açılamaz.',
        'stream' => 'Ses akışına ulaşılamadı. Tekrar deneyin.',
        _ => null,
      };

  bool get radioMode => _radioMode;
  bool get shuffleMode => _shuffleMode;
  bool get shuffleModeEnabled => _shuffleMode;

  /// Kalıcı shuffle tercihi. Kuyruk 2 parçadan kısaysa fiili shuffle
  /// uygulanmaz, ancak tercih korunur ve sonraki kuyrukta uygulanır.
  bool get shuffleEnabled => _shuffleEnabled;
  RepeatMode get repeatMode => _repeatMode;

  /// Aktif ses kalitesi (`low`/`medium`/`high`/`veryhigh`).
  String get quality => _quality;

  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  bool get hasNext => _index + 1 < _queue.length;
  bool get hasPrevious => _index > 0;

  Stream<bool> get playingStream => _player.playingStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  bool get playing => _player.playing;
  Duration get position => _player.position;
  Duration get buffered => _player.buffered;

  int _nextTransition() => ++_transitionId;

  bool _isStale(int transition, int generation) =>
      transition != _activeTransition || generation != _generation;

  Future<void> playQueue(
    List<Track> tracks,
    int startIndex, {
    bool radio = true,
  }) async {
    if (tracks.isEmpty) return;
    await _restorePreferences();
    final safeIndex = startIndex.clamp(0, tracks.length - 1);
    _queue = List<Track>.unmodifiable(tracks);
    _originalQueue = _queue;
    _index = safeIndex;
    _shuffleMode = false;
    _radioMode = radio && Library.instance.radioEnabled;
    _applyShuffle(enabled: _shuffleEnabled);
    _publishQueue();
    await _playAt(_index);
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
    Object? resolveError;
    Uri? uri;
    try {
      uri = await _resolveTrack(track);
    } catch (error) {
      resolveError = error;
    }
    if (_isStale(transition, generation)) return;

    if (uri != null) {
      final failure = await _tryOpen(
        uri,
        track: track,
        resumeAt: resumeAt,
        transition: transition,
        generation: generation,
      );
      if (failure == null || _isStale(transition, generation)) return;
      resolveError = failure;
    }

    if (resolveError is AudioBlocked) {
      if (kDebugMode) {
        debugPrint('CT AudioBlocked ${track.id}: ${resolveError.reason}');
      }
      unawaited(RepairBot.instance.reportEvent('audio_blocked', {
        'video_id': track.id,
        'reason': resolveError.reason,
      }));
    } else if (kDebugMode) {
      debugPrint('CT _playAt ${track.id}: $resolveError');
    }

    await _failOrRecover(
      track: track,
      resumeAt: resumeAt,
      retry: retry,
      blocked: resolveError is AudioBlocked,
      transition: transition,
      generation: generation,
    );
  }

  /// Kaynağı açar, hazır olana kadar bekler ve `play()`'i tam bir kez garanti
  /// eder. Hata döner; başarı/stale durumda null döner.
  Future<Object?> _tryOpen(
    Uri uri, {
    required Track track,
    required Duration? resumeAt,
    required int transition,
    required int generation,
  }) async {
    _opening = true;
    try {
      await _setSource(uri, resumeAt);
      if (_isStale(transition, generation)) return null;

      _loading = false;
      _error = null;
      _broadcast();
      notifyListeners();

      await _ensurePlaying(transition, generation);
      unawaited(Library.instance.remember(track));
      // İlk tampon tamamlanmadan prefetch başlarsa aktif akışa rakip oluyor.
      Timer(const Duration(seconds: 4), () {
        if (!_isStale(transition, generation)) unawaited(_preloadUpcoming());
      });
      return null;
    } catch (error) {
      if (_isStale(transition, generation)) return null;
      return error;
    } finally {
      _opening = false;
    }
  }

  Future<void> _ensurePlaying(int transition, int generation) async {
    if (_isStale(transition, generation)) return;
    final status = _player.status;
    if (status != PlaybackStatus.ready && status != PlaybackStatus.buffering) {
      try {
        await _player.statusStream
            .firstWhere(
              (s) => s == PlaybackStatus.ready ||
                  s == PlaybackStatus.buffering ||
                  s == PlaybackStatus.completed,
              orElse: () => _player.status,
            )
            .timeout(_readyTimeout);
      } catch (_) {
        // Motor hazır sinyali göndermese de play() denenmelidir.
      }
    }
    if (_isStale(transition, generation)) return;
    try {
      await _player.play();
    } catch (_) {
      // Bazı motorlar open() hemen sonrasında play()'i reddeder.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!_isStale(transition, generation)) await _player.play();
    }
  }

  /// AudioBlocked/stream hatasında: bir kez forceDirect, sonra alternatif
  /// kaynak, sonra kullanıcıya anlaşılır hata.
  Future<void> _failOrRecover({
    required Track track,
    required Duration? resumeAt,
    required bool retry,
    required bool blocked,
    required int transition,
    required int generation,
  }) async {
    if (retry) {
      Uri? direct;
      try {
        direct = await YoutubeService.instance
            .forceDirect(track.id)
            .timeout(_resolveTimeout);
      } catch (_) {}
      if (_isStale(transition, generation)) return;
      if (direct != null) {
        final failure = await _tryOpen(
          direct,
          track: track,
          resumeAt: resumeAt,
          transition: transition,
          generation: generation,
        );
        if (failure == null || _isStale(transition, generation)) return;
      }

      // Alternatif kaynak: cache tamamen temizlenip servisin Invidious
      // dahil tüm çözüm yolları sıfırdan denenir.
      YoutubeService.instance.clearCache();
      Uri? alternative;
      try {
        alternative = await YoutubeService.instance
            .audioUri(track.id)
            .timeout(_resolveTimeout);
      } catch (_) {}
      if (_isStale(transition, generation)) return;
      if (alternative != null) {
        final failure = await _tryOpen(
          alternative,
          track: track,
          resumeAt: resumeAt,
          transition: transition,
          generation: generation,
        );
        if (failure == null || _isStale(transition, generation)) return;
      }
    }

    if (_isStale(transition, generation)) return;
    var code = blocked ? 'blocked' : 'stream';
    try {
      final connections = await Connectivity().checkConnectivity();
      if (connections.every((r) => r == ConnectivityResult.none)) {
        code = 'offline';
      }
    } catch (_) {}
    _loading = false;
    _error = code;
    unawaited(RepairBot.instance.reportEvent('playback_alternative_failed', {
      'video_id': track.id,
      'blocked': blocked,
      'code': code,
    }));
    _broadcast();
    notifyListeners();
  }

  Future<Uri> _resolveTrack(Track track) async {
    final saved = DownloadService.instance.savedPathOf(track.id);
    if (saved != null && File(saved).existsSync()) return Uri.file(saved);
    final direct = track.sourceUrl;
    if (direct != null && direct.isNotEmpty) return Uri.parse(direct);
    return YoutubeService.instance.audioUri(track.id).timeout(_resolveTimeout);
  }

  Future<void> _setSource(Uri uri, Duration? resumeAt) async {
    // Gain'i kaynak değişiminden ÖNCE 1'e sabitle. Oynatma başladıktan sonra
    // yapılan setVolume() çağrıları bazı cihazlarda AudioTrack'e işlenmiyor;
    // parça sessiz açılıyor, pause/resume sonrası ses geliyordu.
    await _player.setVolume(1);
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
        .open(
          uri,
          headers: headers,
          initialPosition: resumeAt,
          tag: mediaItem.value,
        )
        .timeout(_openTimeout);
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

  /// Zaten çalıyorsa dokunmaz, duraklatılmışsa devam ettirir. Sesli arama
  /// sonrası ve medya `play` komutu bu yolu kullanır.
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
    if (kIsWeb || !(Platform.isAndroid || Platform.isLinux)) return;
    final settings = SettingsService.instance;
    if (!settings.ready) return;
    await _player.applyEqualizer(
      settings.equalizerEnabled,
      settings.equalizerPreset,
    );
  }

  void _onPlayerState(PlaybackStatus status) {
    _broadcast();
    if (status == PlaybackStatus.completed && !_opening && !_loading) {
      unawaited(_advance(auto: true));
    }
  }

  Future<void> _advance({bool auto = false}) async {
    if (_advancing || _shuffleBusy || _loading) return;
    _advancing = true;
    try {
      final generation = _generation;
      // Döngü/tek parça modu radyo ile çakışmaz.
      final canExtendRadio = _radioUsable && _repeatMode == RepeatMode.off;

      if (auto) {
        if (_repeatMode == RepeatMode.one) {
          await Future<void>.delayed(transitionDelay);
          if (_generation != generation) return;
          await _playAt(_index, resumeAt: Duration.zero);
          return;
        }

        final nextIndex = _index + 1;
        // Kuyruk bitmeden, son iki parça kala radyoyu genişlet.
        if (canExtendRadio &&
            nextIndex < _queue.length &&
            nextIndex >= _queue.length - 2) {
          await _extendRadio();
        }
        if (nextIndex < _queue.length &&
            (_queue[nextIndex].sourceUrl ?? '').isEmpty) {
          unawaited(YoutubeService.instance.prefetch(_queue[nextIndex].id));
        }
        await Future<void>.delayed(transitionDelay);
        if (_generation != generation) return;
      }

      if (hasNext) {
        await _playAt(_index + 1);
        return;
      }

      // Kuyruk sonu.
      if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
        await _playAt(0, resumeAt: Duration.zero);
        return;
      }
      if (_repeatMode == RepeatMode.one && _queue.isNotEmpty) {
        await _playAt(_index, resumeAt: Duration.zero);
        return;
      }

      // Manuel next() de kuyruk sonundaysa radyoyu genişletir.
      if (canExtendRadio) {
        await _extendRadio();
        if (auto && _generation != generation) return;
        if (hasNext) {
          await _playAt(_index + 1);
          return;
        }
      }

      // repeat off + radyo kapalı: otomatik geçişte dur.
      if (auto && _queue.isNotEmpty) {
        await _player.pause();
        await _player.seek(Duration.zero);
        _broadcast();
      }
    } finally {
      _advancing = false;
    }
  }

  Future<void> _extendRadio() async {
    final seed = current;
    if (seed == null || _extending || !_radioUsable) return;
    _extending = true;
    final deadline = DateTime.now().add(_radioTimeout);
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    try {
      List<Track> more = const <Track>[];
      try {
        more = await YoutubeService.instance
            .related(seed.id, limit: 30)
            .timeout(remaining());
      } catch (_) {}

      // related boşsa/en çok 10 sn içinde topArtist tohumuyla devam et.
      if (more.isEmpty) {
        final top = Library.instance.topArtist;
        final name = (top != null && top.trim().isNotEmpty)
            ? top
            : (seed.artist.trim().isNotEmpty && seed.artist != 'Bilinmeyen'
                ? seed.artist
                : null);
        final left = remaining();
        if (name != null && left > Duration.zero) {
          try {
            more = await YoutubeService.instance
                .artistTracks(name, channelId: seed.artistId, limit: 30)
                .timeout(left);
          } catch (_) {}
        }
      }
      if (more.isEmpty) return;

      final existing = _originalQueue.map((track) => track.id).toSet();
      final fresh = <Track>[];
      for (final track in more) {
        if (track.id.isEmpty || track.id == seed.id) continue;
        if (!existing.add(track.id)) continue;
        fresh.add(track);
        if (_originalQueue.length + fresh.length >= _maxQueueLength) break;
      }
      if (fresh.isEmpty) return;

      final original = [..._originalQueue, ...fresh];
      if (_shuffleMode) {
        _queue = List<Track>.unmodifiable([
          ..._queue,
          ...fresh.toList()..shuffle(),
        ]);
      } else {
        _queue = List<Track>.unmodifiable(original);
      }
      _originalQueue = List<Track>.unmodifiable(original);
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
    if (_radioMode == value) return;
    _radioMode = value;
    _publishModeState();
  }

  /// Geriye uyumlu takma ad. Tercih kalıcı hale getirilir.
  void toggleShuffle() => setShuffleEnabled(!_shuffleEnabled);

  bool get _radioUsable => _radioMode && Library.instance.radioEnabled;

  void setShuffleEnabled(bool value) {
    _shuffleEnabled = value;
    if (_queue.length >= 2) {
      _shuffleBusy = true;
      try {
        _applyShuffle(enabled: value);
        _publishQueue();
      } finally {
        _shuffleBusy = false;
      }
    }
    unawaited(_saveBool('ct.shuffle', value));
    _publishModeState();
  }

  /// Kuyruğu karıştırır veya orijinal sıraya döndürür. Aktif parça korunur.
  void _applyShuffle({required bool enabled}) {
    if (_queue.length < 2) {
      _shuffleMode = false;
      return;
    }
    if (!enabled) {
      if (!_shuffleMode) return;
      final active = current;
      _queue = _originalQueue;
      final restored = _queue.indexWhere((track) => track.id == active?.id);
      _index = restored >= 0 ? restored : 0;
      _shuffleMode = false;
      return;
    }
    if (_shuffleMode) return;
    final active = current;
    final rest = _queue.where((track) => track.id != active?.id).toList()
      ..shuffle();
    _queue = List<Track>.unmodifiable([
      if (active != null) active,
      ...rest,
    ]);
    if (active != null) _index = 0;
    _shuffleMode = true;
  }

  /// off -> all -> one -> off sırasıyla döner.
  void cycleRepeatMode() =>
      unawaited(setRepeatMode(_nextRepeatMode(_repeatMode)));

  RepeatMode _nextRepeatMode(RepeatMode mode) => switch (mode) {
        RepeatMode.off => RepeatMode.all,
        RepeatMode.all => RepeatMode.one,
        RepeatMode.one => RepeatMode.off,
      };

  /// [RepeatMode] alır. `BaseAudioHandler.setRepeatMode` ile aynı isimde
  /// olduğu için parametre `Object?` olarak genişletildi; MediaSession'dan
  /// gelen `AudioServiceRepeatMode` da aynı yolla çevrilir.
  @override
  Future<void> setRepeatMode(Object? repeatMode) async {
    final mode = _coerceRepeatMode(repeatMode);
    if (mode == null || _repeatMode == mode) return;
    _repeatMode = mode;
    _publishModeState();
    await _saveString('ct.repeatMode', mode.name);
  }

  RepeatMode? _coerceRepeatMode(Object? value) {
    if (value is RepeatMode) return value;
    if (value is AudioServiceRepeatMode) {
      return switch (value) {
        AudioServiceRepeatMode.none => RepeatMode.off,
        AudioServiceRepeatMode.all => RepeatMode.all,
        AudioServiceRepeatMode.one => RepeatMode.one,
        _ => null,
      };
    }
    return null;
  }

  /// Ses kalitesini değiştirir, aktif parçayı aynı pozisyondan yeni URI ile
  /// yeniden açar ve çözülmüş adres önbelleğini temizler.
  Future<void> setQuality(String quality) async {
    if (quality.isEmpty) return;
    final position = _player.position;
    final hasTrack = current != null;
    _preloaded.clear();

    YoutubeService.instance.setQuality(quality);
    // Ayarlar ekranı 'veryhigh' anahtarını kullanır; player 'lossless' da
    // gösterebilir. İki ekranı aynı değerde tut.
    final settingsQuality = quality == 'lossless' ? 'veryhigh' : quality;
    if (SettingsService.instance.ready &&
        SettingsService.instance.audioQuality != settingsQuality) {
      await SettingsService.instance.setAudioQuality(settingsQuality);
    }
    YoutubeService.instance.clearCache();
    _quality = YoutubeService.instance.quality;
    unawaited(_saveString('ct.quality', _quality));

    if (hasTrack) {
      await _playAt(_index, resumeAt: position);
    }
    _publishModeState();
  }

  Future<void> _restorePreferences() {
    if (_prefsReady) return Future<void>.value();
    return _prefsFuture ??= _doRestorePreferences();
  }

  Future<void> _doRestorePreferences() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final prefs = _prefs!;
      _shuffleEnabled = prefs.getBool('ct.shuffle') ?? false;
      _repeatMode = _decodeRepeatMode(prefs.getString('ct.repeatMode'));
      final quality = prefs.getString('ct.quality');
      if (quality != null && quality.isNotEmpty) _quality = quality;
    } catch (_) {
      // Okunamayan depolama: varsayılanlarla devam et.
    }
    _prefsReady = true;
  }

  RepeatMode _decodeRepeatMode(String? stored) => switch (stored) {
        'all' => RepeatMode.all,
        'one' => RepeatMode.one,
        _ => RepeatMode.off,
      };

  Future<void> _saveBool(String key, bool value) async {
    if (!_prefsReady) await _restorePreferences();
    try {
      await _prefs?.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _saveString(String key, String value) async {
    if (!_prefsReady) await _restorePreferences();
    try {
      await _prefs?.setString(key, value);
    } catch (_) {}
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
      } catch (_) {
      } finally {
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
        // Arayüz/Android Auto bu alanlardan mod durumunu okuyabilir.
        extras: <String, dynamic>{
          'ct.repeatMode': _repeatMode.name,
          'ct.shuffle': _shuffleEnabled,
          'ct.radio': _radioMode,
          'ct.quality': _quality,
        },
      );

  void _publishMediaItem(Track track) {
    mediaItem.add(_toMediaItem(track));
    _publishQueue();
  }

  /// Mod/kalite değişince MediaItem.extras ve playbackState'i yeniler.
  void _publishModeState() {
    final active = current;
    if (active != null) mediaItem.add(_toMediaItem(active));
    _publishQueue();
    _broadcast();
  }

  int _errorCode(String? code) => switch (code) {
        'blocked' => 1,
        'offline' => 2,
        'stream' => 3,
        _ => 0,
      };

  AudioProcessingState _mapState() {
    if (_error != null) return AudioProcessingState.error;
    return switch (_player.status) {
      PlaybackStatus.idle => AudioProcessingState.idle,
      PlaybackStatus.loading => AudioProcessingState.loading,
      PlaybackStatus.buffering => AudioProcessingState.buffering,
      PlaybackStatus.ready => AudioProcessingState.ready,
      PlaybackStatus.completed => AudioProcessingState.completed,
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
      processingState: _mapState(),
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.buffered,
      speed: _player.speed,
      controls: controls,
      androidCompactActionIndices: compact,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      repeatMode: switch (_repeatMode) {
        RepeatMode.off => AudioServiceRepeatMode.none,
        RepeatMode.all => AudioServiceRepeatMode.all,
        RepeatMode.one => AudioServiceRepeatMode.one,
      },
      shuffleMode: _shuffleEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      queueIndex: _index >= 0 ? _index : null,
      errorCode: _error == null ? null : _errorCode(_error),
      errorMessage: errorMessage,
    ));
    notifyListeners();
  }

  /// AudioService/medya tuşu `play` komutu her zaman çalmaya başlatır.
  /// toggle yalnızca kullanıcı dokunuşunda kullanılır; aksi halde zaten
  /// çalan parça medya tuşuyla duraklatılırdı.
  @override
  Future<void> play() => resume();

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
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    if (name == 'like') {
      final track = current;
      if (track != null) await Library.instance.toggleLike(track);
      return null;
    }
    if (name == 'repeat') {
      cycleRepeatMode();
      return null;
    }
    if (name == 'shuffle') {
      toggleShuffle();
      return null;
    }
    if (name == 'radio') {
      setRadioMode(!_radioMode);
      return null;
    }
    if (name == 'quality') {
      final value = extras?['quality'];
      if (value is String) await setQuality(value);
      return null;
    }
    return super.customAction(name, extras);
  }

  void toggleLikeCurrent() {
    final track = current;
    if (track != null) unawaited(Library.instance.toggleLike(track));
  }
}
