import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/song.dart';
import 'connectivity_service.dart';
import 'download_manager.dart';
import 'equalizer_service.dart';
import 'library_store.dart';
import 'music_service.dart';
import 'repair_bot_service.dart';
import 'room_service.dart';

/// Geçiş tipi: fade, cut, beat-match
enum TransitionType { fade, cut, beatMatch }

enum RepeatMode { off, all, one }
enum AudioQuality { auto, high, medium, low, ultra }

/// Tek noktadan oynatma yönetimi:
/// - Sonsuz rasgele şarkı oynatma (autoplay)
/// - Crossfade (geçiş) — kesintisiz akış
/// - Çevrimdışı / indirilmiş dosyadan çalma
class PlayerService extends ChangeNotifier {
  PlayerService._() {
    _player.playerStateStream.listen(_onPlayerState);
    _player.processingStateStream.listen(_onProcessingState);
    _initAudioSession();
  }


  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      debugPrint('Audio session init error: $e');
    }
  }

  static final PlayerService instance = PlayerService._();

  final AudioPlayer _player = AudioPlayer();
  final LibraryStore library = LibraryStore.instance;
  final ConnectivityService connectivity = ConnectivityService.instance;
  final MusicService music = MusicService.instance;
  final RoomService room = RoomService.instance;

  /// Son başarılı çözülen akış URL'si — oda ortaklarıyla paylaşılır.
  String? _activeStreamUrl;
  String? get currentStreamUrl => _activeStreamUrl;

  List<Song> _queue = const [];
  List<Song> _shuffledQueue = const [];
  int _index = -1;
  bool _shuffle = false;
  RepeatMode _repeat = RepeatMode.off;

  // ─── Otomatik oynatma (sonsuz rasgele) ───
  bool _autoplay = true;
  bool get autoplay => _autoplay;

  // ─── Radio modu ───
  bool _isRadioMode = false;

  // ─── Crossfade (geçiş) ───
  Timer? _crossfadeTimer;
  bool _crossfading = false;
  bool _crossfadeEnabled = true;
  int _crossfadeSeconds = 4;
  Duration get _crossfadeDuration => Duration(seconds: _crossfadeSeconds);

  // ─── Smart Automix ───
  /// Akıllı karıştırma: BPM/anahtar tabanlı geçiş (gelecekte ses analizi ile)
  bool _smartAutomix = false;
  bool get smartAutomix => _smartAutomix;
  
  /// Geçiş tipi: fade, cut, beat-match
  TransitionType _transitionType = TransitionType.fade;
  TransitionType get transitionType => _transitionType;

  /// BPM verisi (gelecekte ses analizi servisinden gelecek)
  /// Şimdilik placeholder: 0 = bilinmiyor
  double _currentBpm = 0;
  double get currentBpm => _currentBpm;
  
  /// Şarkı anahtarı (key) - placeholder
  String _currentKey = '';
  String get currentKey => _currentKey;

  // ─── Oynatma hızı ───
  double _speed = 1.0;
  double get speed => _speed;

  // ─── Çözümlenen akış URL önbelleği (sıradaki şarkı önceden ısıtılır) ───
  final Map<String, String> _streamCache = {};

  /// Stream önbelleği anahtarı: kaynak çakışmalarını önlemek için source
  /// adı + id birleştirir (Audius track ID ile IA identifier aynı olabilir).
  static String _cacheKey(Song song) => '${song.source.name}:${song.id}';

  // ─── YouTube Music benzeri özellikler ───
  AudioQuality _quality = AudioQuality.ultra;
  AudioQuality get quality => _quality;

  bool get crossfadeEnabled => _crossfadeEnabled;
  int get crossfadeSeconds => _crossfadeSeconds;

  // ─── Uyku zamanlayıcısı ───
  Timer? _sleepTimer;
  DateTime? _sleepEndTime;
  Duration? _sleepDuration;
  Duration? get sleepDuration => _sleepDuration;
  DateTime? get sleepEndTime => _sleepEndTime;
  bool get sleepTimerActive => _sleepTimer?.isActive ?? false;
  Duration? get sleepRemaining {
    if (!sleepTimerActive || _sleepEndTime == null) return null;
    final d = _sleepEndTime!.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  SharedPreferences? _prefs;

  Song? get current =>
      _index >= 0 && _index < effectiveQueue.length ? effectiveQueue[_index] : null;
  List<Song> get queue => effectiveQueue;
  int get index => _index;
  bool get shuffle => _shuffle;
  RepeatMode get repeat => _repeat;
  AudioPlayer get player => _player;

  bool get isPlaying => _player.playing;
  Duration get position => _player.position;

  Future<void> seekTo(Duration target) async {
    if (_player.duration != null &&
        target > (_player.duration ?? target)) {
      target = _player.duration ?? target;
    }
    if (target.isNegative) target = Duration.zero;
    await _player.seek(target);
    _syncRoom();
  }

  bool _isLoading = false;
  String? _lastError;
  bool get isLoading => _isLoading;
  String? get lastError => _lastError;

  bool get playingOffline {
    final song = current;
    if (song == null) return false;
    if (song.isDownloaded && File(song.localPath!).existsSync()) return true;
    return connectivity.isOffline;
  }

  List<Song> get effectiveQueue => _shuffle ? _shuffledQueue : _queue;

  // ─── Rasgele şarkı sorguları (autoplay için) ───
  static const List<String> _autoplayQueries = [
    'popular songs 2026',
    'trending music 2026',
    'top hits playlist',
    'best songs ever',
    'new music friday',
    'chill vibes playlist',
    'workout music mix',
    'relaxing music',
    'pop hits 2026',
    'rock classics',
    'hip hop hits',
    'electronic dance music',
    'acoustic chill',
    'indie pop playlist',
    'r&b hits 2026',
  ];

  /// Kuyruk kurar ve çalmaya başlar.
  /// [initialSource] önceden çözümlenmiş bir kaynak veriliyorsa, bunu doğrudan kullanırız;
  /// aksi takdirde akış URL'si otomatik çözümlenir. Bu, kullanıcı tıklaması sonrası
  //  anında çalma süreçlerini hızlandırır.
  void playQueue(List<Song> songs, {int startIndex = 0, String? initialSource}) {
    if (songs.isEmpty) return;
    _crossfadeTimer?.cancel();
    _crossfading = false;
    _queue = List.of(songs);
    _rebuildShuffled(startIndex);
    _index = _shuffle
        ? 0
        : startIndex.clamp(0, _queue.length - 1);
    library.pushRecent(current!);
    _buildAndPlay(initialSource: initialSource).catchError((_) {});
    notifyListeners();
    _syncRoom();
  }

  void _rebuildShuffled(int firstIndex) {
    if (_queue.isEmpty) return;
    final rest = List.of(_queue)..removeAt(firstIndex.clamp(0, _queue.length - 1));
    rest.shuffle();
    _shuffledQueue = [_queue[firstIndex.clamp(0, _queue.length - 1)], ...rest];
  }

  /// Tek bir şarkıyı yükler ve çalar.
  /// Her çağrıda o anki şarkı + crossfade için gerekli tek kaynak kurulur;
  /// geçişler `next()` ile manuel yönetilir (autoplay + crossfade için).
  /// [initialSource] veriliyorsa, stream URL çözme adımı atlanır ve oynatma hemen başlar.
  /// Akış adayları SIRAYLA denenir: bozuk/engellenmiş URL "source error" verirse
  /// bir sonraki adaya geçilir (mobil veride özellikle önemli).
  Future<void> _buildAndPlay({String? initialSource}) async {
    final songs = effectiveQueue;
    if (songs.isEmpty || _index < 0 || _index >= songs.length) return;

    _isLoading = true;
    _lastError = null;
    notifyListeners();

    while (true) {
      final q = effectiveQueue;
      if (_index < 0 || _index >= q.length) break;
      final song = q[_index];
      String? lastError;
      try {
        // Eski kaynağı tamamen kaldır: geçiş başarısız olursa eski şarkının
        // sesi sürpriz olarak devam etmesin; hata banner'ıyla dursun.
        await _player.stop();

        // 1) İndirilmiş dosya varsa her zaman yerelden çal.
        final downloaded = library.downloadedSong(song.id);
        final localPath = downloaded?.localPath;
        if (localPath != null && await File(localPath).exists()) {
          await _player.setAudioSource(await _buildSource(song),
              initialPosition: Duration.zero, preload: true);
          await _player.setSpeed(_speed);
          _applyEqualizer();
          await _player.play();
          _saveSession();
          break;
        }

        // 2) Çevrimdışıysa ve kaynak yoksa: hata.
        if (!connectivity.isOnline) {
          throw StreamUnavailableException(
              'Bu şarkı çevrimdışı kullanılamıyor.');
        }

        // 3) Akış adayları: odaya özel önceden çözülmüş URL veya kalite sıralı.
        final candidates = initialSource != null
            ? [initialSource]
            : await music.streamCandidatesForSong(song,
                quality: switch (_quality) {
                  AudioQuality.high => 'high',
                  AudioQuality.medium => 'medium',
                  AudioQuality.low => 'low',
                  AudioQuality.ultra => 'ultra',
                  AudioQuality.auto => 'auto',
                });

        var started = false;
        final failed = <String>[];
        for (final url in candidates) {
          try {
            final source = await _buildSourceFromString(url, song);
            await _player.setAudioSource(source,
                initialPosition: Duration.zero, preload: true);
            await _player.setSpeed(_speed);
            _applyEqualizer();
            await _player.play();

            // Oynatıcı hata verirse (kırık/engelli URL) kısa beklemede
            // "ready" olmaz ve sonraki adaya geçilir.
            await _player.playerStateStream
                .firstWhere((s) =>
                    s.processingState == ProcessingState.ready ||
                    s.processingState == ProcessingState.completed)
                .timeout(const Duration(seconds: 8));
            music.cacheStreamUrl(song.id, url);
            started = true;
            break;
          } catch (e) {
            lastError = e.toString();
            failed.add('${Uri.tryParse(url)?.host ?? url} → $e');
            try {
              await _player.stop();
            } catch (_) {}
          }
        }
        if (!started) {
          // Kaynak bazlı yedek: TÜM YouTube/CDN adayı başlamadıysa aynı şarkının
          // Audius / Internet Archive kopyasından çalmayı dene. Türkiye'de
          // googlevideo CDN IP engeli yüzünden YouTube akışı çoğunlukla
          // açılamaz; bu yedek o şarkıyı YİNE de çalınabilir yapar.
          final fallback = await music.fallbackStreamCandidates(song);
          for (final url in fallback) {
            try {
              final source = await _buildSourceFromString(url, song);
              await _player.setAudioSource(source,
                  initialPosition: Duration.zero, preload: true);
              await _player.setSpeed(_speed);
              _applyEqualizer();
              await _player.play();
              await _player.playerStateStream
                  .firstWhere((s) =>
                      s.processingState == ProcessingState.ready ||
                      s.processingState == ProcessingState.completed)
                  .timeout(const Duration(seconds: 8));
              music.cacheStreamUrl(song.id, url);
              started = true;
              failed.clear();
              break;
            } catch (e) {
              lastError = e.toString();
              failed.add('yedek:${Uri.tryParse(url)?.host ?? url} → $e');
              try {
                await _player.stop();
              } catch (_) {}
            }
          }
        }
        if (!started) {
          final brief = failed.take(3).join(' | ');
          // Sessizce onarım botuna bildir
          unawaited(RepairBotService.instance.reportEvent(
              RepairEventType.streamError,
              'Akış başlatılamadı: $brief',
              {'song': song.id, 'attempts': candidates.length}));

          // Auto-skip to next song if autoplay is enabled, otherwise show error
          if (_autoplay) {
            debugPrint('Stream failed, auto-skipping to next song (autoplay enabled)');
            unawaited(next());
          } else {
            throw Exception(
                lastError == null
                    ? 'Akış başlatılamadı'
                    : 'Akış başlatılamadı (${candidates.length} aday denendi: $brief)');
          }
        }
        _saveSession();
        // Ön yükleme: sıradaki şarkının stream URL'ini arka planda çöz
        _prefetchNext();
        break;
      } catch (e) {
        // Çalınamayan şarkı SIRADAKİNE ATLANMAZ: kullanıcı hangi şarkıyı
        // seçtiyse odur; şarkıda kalınır, hata banner'ıyla neden gösterilir.
        // Manuel "sonraki/türbülans" ile geçilebilir.
        _lastError = e.toString().replaceFirst('Exception: ', '');
        // Sessizce onarım botuna bildir
        unawaited(RepairBotService.instance.reportEvent(
            RepairEventType.streamError,
            'Oynatma hatası: ${e.toString().replaceFirst('Exception: ', '')}',
            {'song': song.id}));
        
        // Auto-skip to next song if autoplay is enabled
        if (_autoplay) {
          debugPrint('Playback error, auto-skipping to next song (autoplay enabled)');
          unawaited(next());
        } else {
          break;
        }
      }
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Verilen stream URL'ından doğrudan bir AudioSource oluşturur (cache'lenmiş URL için).
  Future<AudioSource> _buildSourceFromString(String streamUrl, Song song) async {
    _activeStreamUrl = streamUrl;
    Duration? duration;
    Uri? artUri;

    artUri = song.thumbnailUrl.isNotEmpty ? Uri.tryParse(song.thumbnailUrl) : null;
    duration = song.durationMs > 0 ? Duration(milliseconds: song.durationMs) : null;

    final mediaItem = MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: AppStrings.appName,
      artUri: artUri,
      duration: duration,
    );

    return AudioSource.uri(Uri.parse(streamUrl), tag: mediaItem);
  }

  /// Tek bir şarkı için AudioSource oluşturur.
  Future<AudioSource> _buildSource(Song song) async {
    final downloaded = library.downloadedSong(song.id);
    final localPath = downloaded?.localPath;
    final useLocal = localPath != null && await File(localPath).exists();

    Duration? duration;
    Uri? artUri;
    String? streamUrl;

    if (useLocal) {
      _activeStreamUrl = null;
      final art = File(DownloadManager.instance.artPath(song.id));
      artUri = art.existsSync() ? Uri.file(art.path) : null;
    } else if (connectivity.isOnline) {
      streamUrl = _streamCache[_cacheKey(song)] ??
          await music.resolveStreamUrlForSong(song,
              quality: switch (_quality) {
                AudioQuality.high => 'high',
                AudioQuality.medium => 'medium',
                AudioQuality.low => 'low',
                AudioQuality.ultra => 'ultra',
                AudioQuality.auto => 'auto',
              });
      _activeStreamUrl = streamUrl;
      // Başarılı çözümü önbellekle; hızlı şarkı değiştirme için.
      _streamCache[_cacheKey(song)] = streamUrl;
      artUri = song.thumbnailUrl.isNotEmpty ? Uri.tryParse(song.thumbnailUrl) : null;
      duration = song.durationMs > 0 ? Duration(milliseconds: song.durationMs) : null;
    } else {
throw StreamUnavailableException(
      'Bu şarkı çevrimdışı kullanılamıyor.');
    }

    final mediaItem = MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: AppStrings.appName,
      artUri: artUri,
      duration: duration,
    );

    if (useLocal) {
      return AudioSource.file(localPath, tag: mediaItem);
    }
    return AudioSource.uri(Uri.parse(streamUrl!), tag: mediaItem);
  }

  void _applyEqualizer() {
    try {
      final v = EqualizerService.instance.volumeMultiplier();
      _player.setVolume(v);
    } catch (_) {
      _player.setVolume(1.0);
    }
  }

  Future<void> loadAndPlay() async {
    await _buildAndPlay();
  }

  void togglePlayPause() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.idle && current != null) {
        try {
          await _buildAndPlay();
        } catch (_) {}
        return;
      }
      await _player.play();
    }
    _syncRoom();
  }

  /// Sonraki şarkıya geç. Liste biterse ve autoplay açıksa rasgele şarkı getir.
  Future<void> next({bool userTriggered = true}) async {
    if (effectiveQueue.isEmpty) return;
    if (_repeat == RepeatMode.one && !userTriggered) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }

    // Crossfade'i iptal et (sonraki şarkıya geçtik)
    _crossfadeTimer?.cancel();
    _crossfading = false;
    _player.setVolume(1.0);

    // Radio modunda ise radio kuyruğundan sonraki şarkı
    if (_isRadioMode && _radioQueue.isNotEmpty && _radioIndex >= 0) {
      final nextSong = _radioNextSong();
      _index = effectiveQueue.indexWhere((s) => s.id == nextSong.id);
      library.pushRecent(current!);
      try {
        await _buildAndPlay();
      } catch (_) {}
      notifyListeners();
      _syncRoom();
      return;
    }

    if (_index < effectiveQueue.length - 1) {
      _index++;
    } else if (_repeat == RepeatMode.all) {
      _index = 0;
    } else if (_autoplay && connectivity.isOnline) {
      // Liste bitti — autoplay: rasgele şarkı getir
      await _autoplayNext();
      return;
    } else {
      return; // liste bitti, autoplay kapalı
    }

    library.pushRecent(current!);
    try {
      await _buildAndPlay();
    } catch (_) {}
    notifyListeners();
    _syncRoom();
  }

  Future<void> previous() async {
    if (effectiveQueue.isEmpty) return;
    _crossfadeTimer?.cancel();
    _crossfading = false;
    _player.setVolume(1.0);

    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_index > 0) {
      _index--;
    } else {
      _index = effectiveQueue.length - 1;
    }
    library.pushRecent(current!);
    try {
      await _buildAndPlay();
    } catch (_) {}
    notifyListeners();
    _syncRoom();
  }

  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= effectiveQueue.length) return;
    _crossfadeTimer?.cancel();
    _crossfading = false;
    _player.setVolume(1.0);

    _index = i;
    library.pushRecent(current!);
    notifyListeners();
    try {
      await _buildAndPlay();
    } catch (_) {}
  }

  Future<void> playSmart(List<Song> list, int startIndex) async {
    if (startIndex < 0 || startIndex >= list.length) return;
    final ids = list.map((s) => s.id).toSet();
    final queueIds = _queue.map((s) => s.id).toSet();
    if (_queue.isNotEmpty && setEquals(ids, queueIds)) {
      final i = effectiveQueue.indexWhere((s) => s.id == list[startIndex].id);
      if (i >= 0) {
        await jumpTo(i);
        return;
      }
    }
    playQueue(list, startIndex: startIndex);
  }

  /// Sonsuz döngü: kuyruğu "tekrarla (tümü)" moduyla çalar.
  /// Ana sayfa listeleri bu modu kullanır — liste bitince başa döner.
  void playForever(List<Song> songs, {int startIndex = 0}) {
    _repeat = RepeatMode.all;
    playQueue(songs, startIndex: startIndex);
  }

  void toggleShuffle() {
    final currentId = current?.id;
    _shuffle = !_shuffle;
    if (_shuffle) {
      _rebuildShuffled(
          _queue.indexWhere((s) => s.id == currentId).clamp(0, _queue.length - 1));
      _index = 0;
    } else {
      _index = _queue.indexWhere((s) => s.id == currentId);
    }
    notifyListeners();
  }

  void cycleRepeat() {
    switch (_repeat) {
      case RepeatMode.off:
        _repeat = RepeatMode.all;
        break;
      case RepeatMode.all:
        _repeat = RepeatMode.one;
        break;
      case RepeatMode.one:
        _repeat = RepeatMode.off;
        break;
    }
    notifyListeners();
  }

  void toggleAutoplay() {
    _autoplay = !_autoplay;
    notifyListeners();
  }

  // ─── Radio için daha fazla şarkı getir ───
  Future<void> _fetchMoreRadio() async {
    try {
      final song = _radioQueue.isNotEmpty ? _radioQueue[_radioQueue.length - 1] : null;
      final related = await music.radioFor(song ?? Song(
        id: '',
        title: '',
        artist: '',
        durationMs: 0,
      ));
      // Zaten kuyruktaki şarkıları hariç tut
      final playedIds = _radioQueue.map((s) => s.id).toSet();
      final candidates = related.where((s) => !playedIds.contains(s.id)).toList();
      if (candidates.isNotEmpty) {
        final nextSong = candidates[Random().nextInt(candidates.length)];
        _queue = List.of(_queue)..add(nextSong);
        if (_shuffle) {
          _shuffledQueue = List.of(_shuffledQueue)..add(nextSong);
        }
        library.pushRecent(nextSong);
      }
    } catch (_) {
      // Radio fetch başarısız — sessizce dur
    }
  }

  // ─── Radio modunu durdur ───
  void stopRadio() {
    _isRadioMode = false;
    _radioQueue = [];
    _radioIndex = -1;
    notifyListeners();
  }

  // ─── Odasınık senkronized autoplay ───
  Future<void> _autoplayNextRoomSync() async {
    try {
      // Kuyruk bittiyse yeni şarkı getir
      if (_index >= effectiveQueue.length - 1) {
        final query = _autoplayQueries[Random().nextInt(_autoplayQueries.length)];
        final results = await music.search(query, limit: 10);
        if (results.isEmpty) return;

        // Çalınan şarkıları hariç tut
        final playedIds = effectiveQueue.map((s) => s.id).toSet();
        final candidates = results.where((s) => !playedIds.contains(s.id)).toList();
        if (candidates.isEmpty) return;

        final nextSong = candidates[Random().nextInt(candidates.length)];

        // Kuyruğa ekle
        _queue = List.of(_queue)..add(nextSong);
        if (_shuffle) {
          _shuffledQueue = List.of(_shuffledQueue)..add(nextSong);
        }
        _index = effectiveQueue.length - 1;

        library.pushRecent(nextSong);
        try {
          await _buildAndPlay();
        } catch (_) {}
        notifyListeners();
      } else {
        // Kuyruk içinde varsa sonraki şarkıya geç
        next(userTriggered: false);
      }
    } catch (_) {
      // Autoplay başarısız — sessizce dur
    }
  }

  // ─── Sonsuz Rasgele Şarkı (Autoplay) ───

  /// Oturum+kalıcı geçmişten TEMİZ (çalınmamış) bir şarkı seçer.
  /// Farklı sorguları dener: tek sorgu karışık sonuç verirse diğerine geçer —
  /// tekrarsız saatlerce akışın anahtarı, çalınmış havuzdan kaçınmaktır.
  /// Döner: seçilen şarkı veya null (tüm sorgular boş/çalınmış).
  Future<Song?> _pickAutoplaySong() async {
    final played = effectiveQueue.map((s) => s.id).toSet()
      ..addAll(library.recents.map((s) => s.id));
    for (var attempt = 0; attempt < 4; attempt++) {
      final query = _autoplayQueries[Random().nextInt(_autoplayQueries.length)];
      final results = await music.search(query, limit: 40);
      if (results.isEmpty) continue;
      final candidates = results.where((s) => !played.contains(s.id)).toList();
      if (candidates.isEmpty) continue;
      return candidates[Random().nextInt(candidates.length)];
    }
    return null;
  }

  /// Sonsuz karışık mod: mevcut kuyruğun devamına TEKRARSIZ yeni şarkılar
  /// ekler. Oturum+geçmişten temiz şarkı seçimi sayesinde saatlerce farklı
  /// şarkı akabilir. Kuyruk boşsa yeni bir şarkıyla başlar.
  Future<void> startInfiniteMix() async {
    _isRadioMode = false;
    _radioQueue = [];
    _radioIndex = -1;
    _autoplay = true;
    notifyListeners();
    if (_queue.isEmpty) {
      final song = await _pickAutoplaySong();
      if (song == null) return;
      playQueue([song]);
    } else {
      await _autoplayNext();
    }
  }

  Future<void> _autoplayNext() async {
    try {
      final nextSong = await _pickAutoplaySong();
      if (nextSong == null) return;

      // Kuyruğa ekle
      _queue = List.of(_queue)..add(nextSong);
      if (_shuffle) {
        _shuffledQueue = List.of(_shuffledQueue)..add(nextSong);
      }
      _index = effectiveQueue.length - 1;

      library.pushRecent(nextSong);
      try {
        await _buildAndPlay();
      } catch (_) {}
      notifyListeners();
    } catch (_) {
      // Autoplay başarısız — sessizce dur
    }
  }

  // ─── Crossfade (geçiş) ───
  void _startCrossfade() {
    if (_crossfading || !_crossfadeEnabled) return;
    _crossfading = true;

    // Crossfade sırasında sıradaki şarkının akış URL'sini önceden çöz.
    _warmNextTrack();

    final remaining = _player.duration != null
        ? _player.duration! - _player.position
        : Duration(seconds: 5);

    if (remaining.inSeconds <= _crossfadeDuration.inSeconds + 1) {
      // Zaten crossfade süresi kadar kaldı — hemen başlat
      _executeCrossfade();
      return;
    }

    // Crossfade başlaması gereken zamana kadar bekle
    final delay = remaining - _crossfadeDuration;
    _crossfadeTimer = Timer(delay > Duration.zero ? delay : Duration.zero, () {
      _executeCrossfade();
    });
  }

  void _executeCrossfade() {
    if (!_player.playing) return;

    // Volume fade-out: 4 saniyede 1.0 → 0.0
    final steps = 40; // 100ms aralıklarla
    final stepDuration = _crossfadeDuration.inMilliseconds ~/ steps;
    final volumeStep = 1.0 / steps;
    int step = 0;

    Timer.periodic(Duration(milliseconds: stepDuration), (timer) {
      step++;
      final newVolume = (1.0 - step * volumeStep).clamp(0.0, 1.0);
      _player.setVolume(newVolume);

      if (step >= steps || !_player.playing) {
        timer.cancel();
        // Sıradaki şarkıya geç — _buildAndPlay içinde EQ volume uygulanır
        next(userTriggered: false).then((_) {
          _crossfading = false;
        }).catchError((_) {
          _crossfading = false;
        });
      }
    });
  }

  // ─── Ses kalitesi ───
  Future<void> loadQualityPref() async {
    _prefs = await SharedPreferences.getInstance();
    final idx = _prefs?.getInt('audio_quality') ?? AudioQuality.ultra.index;
    _quality = AudioQuality.values[idx.clamp(0, AudioQuality.values.length - 1)];
    _speed = (_prefs?.getDouble('playback_speed') ?? 1.0).clamp(0.5, 2.0);
    _crossfadeEnabled = _prefs?.getBool('crossfade_enabled') ?? true;
    _crossfadeSeconds = (_prefs?.getInt('crossfade_seconds') ?? 4).clamp(2, 10);
    _smartAutomix = _prefs?.getBool('smart_automix') ?? false;
    _transitionType = TransitionType.values[_prefs?.getInt('transition_type') ?? 0];
  }

  Future<void> setQuality(AudioQuality q) async {
    _quality = q;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setInt('audio_quality', q.index);
    // Otomatik olarak ultra yüksek kalite uygulamak için
    if (q == AudioQuality.ultra) {
      // Quality zaten ultra, ayarları koru
    }
    if (current != null && !playingOffline && connectivity.isOnline) {
      try {
        await _buildAndPlay();
      } catch (_) {}
    }
    notifyListeners();
  }

  // ─── Oda senkronizasyonu ───

  /// Odadaki ortakların durumunu yayınlar (odadayken ve uzak uygulama değilken).
  void _syncRoom() {
    if (room.roomId != null && !room.applyingRemote) {
      room.publishFromPlayer();
    }
  }

  /// Uzak oda durumunu local playback'e uygular.
  Future<void> applyRoomState({
    required List<Song> songs,
    required int index,
    required Duration position,
    required bool playing,
    String? stream,
  }) async {
    if (songs.isEmpty) return;
    if (index < 0 || index >= songs.length) index = 0;

    final sameQueue = _queue.length == songs.length &&
        _queue.isNotEmpty &&
        _queue.first.id == songs.first.id &&
        _queue.last.id == songs.last.id;

    // Kuyruk veya şarkı değiştiyse yeniden yükle
    if (!sameQueue || _index != index) {
      // Oda sahibinin çözdüğü akış URL'si varsa onu kullan: üye kendi
      // tarafında akış çözemese bile ses garanti olur.
      _queue = List.of(songs);
      _shuffledQueue = List.of(songs);
      _shuffle = false;
      _index = index;
      _isRadioMode = false;
      _crossfadeTimer?.cancel();
      _crossfading = false;
      _player.setVolume(1.0);
      try {
        await _buildAndPlay(initialSource: stream);
      } catch (_) {}
    }

    try {
      // Senkron seek'leri zarif yap: RTT telafili hedefle aramız 250ms'den
      // azsa atla (nota seviyesinde duyulmaz, sürekli seek takılmasını önler).
      final cur = _player.position;
      if (position > Duration.zero &&
          (cur - position).abs() > const Duration(milliseconds: 250)) {
        await _player.seek(position);
      }
    } catch (_) {}

    if (playing && !_player.playing) {
      await _player.play();
    } else if (!playing && _player.playing) {
      await _player.pause();
    }
    notifyListeners();
  }

  /// Uzak oda komutlarını yürütür (mutik ederken yayın yapmaz).
  Future<void> roomPlayPause({bool? play}) async {
    if (play == null) {
      if (_player.playing) {
        await _player.pause();
      } else {
        if (_player.processingState == ProcessingState.idle && current != null) {
          try {
            await _buildAndPlay();
          } catch (_) {}
          return;
        }
        await _player.play();
      }
    } else if (play) {
      if (_player.processingState == ProcessingState.idle && current != null) {
        try {
          await _buildAndPlay();
        } catch (_) {}
        return;
      }
      await _player.play();
    } else {
      await _player.pause();
    }
    _syncRoom();
  }

  Future<void> roomSkip({required bool forward}) {
    if (forward) {
      return next();
    }
    return previous();
  }

  Future<void> roomSeek(Duration target) => seekTo(target);

  /// Odada herkes için komut yürütür (lokalde uygular, uzaklara yayınlar).
  Future<void> localCommand(String op, {int positionMs = 0}) async {
    switch (op) {
      case 'play':
        await roomPlayPause(play: true);
      case 'pause':
        await roomPlayPause(play: false);
      case 'toggle':
        await roomPlayPause();
      case 'next':
        await next();
      case 'prev':
        await previous();
      case 'seek':
        await seekTo(Duration(milliseconds: positionMs));
    }
  }

  String qualityLabel() => switch (_quality) {
        AudioQuality.auto => 'Otomatik',
        AudioQuality.high => 'Yüksek (320kbps)',
        AudioQuality.medium => 'Orta (128kbps)',
        AudioQuality.low => 'Düşük (48kbps)',
        AudioQuality.ultra => 'Ultra (lossless)',
      };

  // ─── Oynatma hızı ───
  Future<void> setSpeed(double value) async {
    _speed = value;
    try {
      await _player.setSpeed(value);
    } catch (_) {}
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setDouble('playback_speed', value);
    notifyListeners();
  }

  // ─── Crossfade ayarları ───
  Future<void> setCrossfadeEnabled(bool value) async {
    _crossfadeEnabled = value;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setBool('crossfade_enabled', value);
    if (value) _startCrossfade();
    notifyListeners();
  }

  Future<void> setCrossfadeSeconds(int value) async {
    _crossfadeSeconds = value.clamp(2, 10);
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setInt('crossfade_seconds', _crossfadeSeconds);
    notifyListeners();
  }

  /// Akıllı karıştırma aç/kapat
  Future<void> setSmartAutomix(bool enabled) async {
    _smartAutomix = enabled;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setBool('smart_automix', _smartAutomix);
    } catch (_) {}
  }

  /// Geçiş tipi değiştir
  Future<void> setTransitionType(TransitionType type) async {
    _transitionType = type;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setInt('transition_type', type.index);
    } catch (_) {}
  }

  /// BPM ayarla (ses analizi servisinden çağrılacak)
  void setBpm(double bpm) {
    _currentBpm = bpm;
    notifyListeners();
  }

  /// Anahtar (key) ayarla
  void setKey(String key) {
    _currentKey = key;
    notifyListeners();
  }

  // ─── Sıradaki şarkının akışını önceden çöz (gecikmeyi öldürür) ───
  Song? _nextSongForWarm() {
    final songs = effectiveQueue;
    if (songs.isEmpty || _index < 0) return null;
    if (_index < songs.length - 1) return songs[_index + 1];
    if (_repeat == RepeatMode.all && songs.isNotEmpty) return songs.first;
    return null;
  }

  void _warmNextTrack() {
    if (!connectivity.isOnline) return;
    final nextSong = _nextSongForWarm();
    if (nextSong == null || _streamCache.containsKey(_cacheKey(nextSong))) return;
    final q = switch (_quality) {
      AudioQuality.high => 'high',
      AudioQuality.medium => 'medium',
      AudioQuality.low => 'low',
      AudioQuality.ultra => 'ultra',
      AudioQuality.auto => 'auto',
    };
    music
        .resolveStreamUrlForSong(nextSong, quality: q)
        .then((url) {
          _streamCache[_cacheKey(nextSong)] = url;
        }).catchError((_) {});
  }

  // ─── Oturum kaldırma: kuyruk + konum geri yükleme ───
  Future<void> restoreSession() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final rawQueue = _prefs?.getString('session_queue') ?? '';
      if (rawQueue.isEmpty) return;
      var saved = Song.listFromJson(rawQueue);
      if (saved.isEmpty) return;

      // Çevrimdışıysa yalnızca cihazda indirilmiş şarkılardan devam et.
      if (connectivity.isOffline) {
        saved = saved.where((s) {
          final dl = library.downloadedSong(s.id);
          return dl != null &&
              dl.localPath != null &&
              File(dl.localPath!).existsSync();
        }).toList();
        if (saved.isEmpty) return;
      }

      _queue = saved;
      _rebuildShuffled(0);
      _index = (_prefs?.getInt('session_index') ?? 0).clamp(0, saved.length - 1);
      await _buildAndPlay();
      final posMs = _prefs?.getInt('session_position') ?? 0;
      if (posMs > 0) {
        await _player.seek(Duration(milliseconds: posMs));
      }
    } catch (e) {
      debugPrint('oturum geri yükleme uyarısı: $e');
    }
  }

  Future<void> _saveSession({bool clear = false}) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      if (clear) {
        await _prefs?.remove('session_queue');
        await _prefs?.remove('session_index');
        await _prefs?.remove('session_position');
        return;
      }
      if (_queue.isEmpty || _index < 0) return;
      await _prefs?.setString('session_queue', Song.listToJson(_queue));
      await _prefs?.setInt('session_index', _index);
      final pos = _player.position.inMilliseconds;
      await _prefs?.setInt('session_position', pos);
    } catch (e) {
      debugPrint('oturum kaydetme uyarısı: $e');
    }
  }

  // ─── Uyku zamanlayıcısı ───
  void startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepDuration = duration;
    _sleepEndTime = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, _onSleepTimerFire);
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDuration = null;
    _sleepEndTime = null;
    notifyListeners();
  }

  void _onSleepTimerFire() {
    _sleepTimer = null;
    _sleepEndTime = null;
    pauseAndClose();
    notifyListeners();
  }

  // ─── Şarkı radyosu ───
  Future<void> playRadio(Song song) async {
    try {
      final related = await music.radioFor(song);
      _isRadioMode = true;
      _radioQueue = [song, ...related];
      _radioIndex = 0;
      playQueue(_radioQueue);
    } catch (_) {
      _isRadioMode = false;
      playQueue([song]);
    }
  }

  // ─── Sonsuz Radio Kuyruğu ───
  List<Song> _radioQueue = [];
  int _radioIndex = -1;

  // Radio kuyruğundan sonraki şarkıyı getir
  Song _radioNextSong() {
    if (_radioIndex >= _radioQueue.length - 1) {
      // Kuyruk bitti, daha fazla şarkı getir
      _fetchMoreRadio().then((_) {
        if (_radioQueue.length > _radioIndex + 1) {
          _index = _radioIndex + 1;
          _buildAndPlay().catchError((_) {});
          notifyListeners();
        }
      });
    }
    _radioIndex++;
    return _radioQueue[_radioIndex];
  }

  void removeFromQueueAt(int i) {
    final q = _queue;
    if (i < 0 || i >= effectiveQueue.length) return;
    final removedSong = effectiveQueue[i];
    q.removeWhere((s) => s.id == removedSong.id);
    _shuffledQueue.removeWhere((s) => s.id == removedSong.id);
    if (i < _index) _index--;
    notifyListeners();
  }

  /// Kuyrukta şarkıyı taşır (sürükle-bırak sıralama için).
  void moveQueueItem(int from, int to) {
    final songs = effectiveQueue;
    if (from < 0 || from >= songs.length || to < 0 || to >= songs.length) return;
    if (_shuffle) return; // karışık modda sıralama anlamsız
    final song = songs[from];
    final q = List.of(_queue)..removeWhere((s) => s.id == song.id);
    q.insert(to.clamp(0, q.length), song);
    _queue = q;
    _shuffledQueue = List.of(_queue);
    if (_index == from) {
      _index = to;
    } else if (from < _index && to >= _index) {
      _index--;
    } else if (from > _index && to <= _index) {
      _index++;
    }
    notifyListeners();
  }

  Future<void> pauseAndClose() async {
    _crossfadeTimer?.cancel();
    _crossfading = false;
    await _player.stop();
    _queue = const [];
    _shuffledQueue = const [];
    _index = -1;
    _streamCache.clear();
    _saveSession(clear: true);
    notifyListeners();
  }

  void playNextUp(Song song) {
    final q = List.of(_queue);
    q.removeWhere((s) => s.id == song.id);
    final at = _index.clamp(-1, q.length - 1) + 1;
    q.insert(at, song);
    _queue = q;
    _shuffledQueue = List.of(_shuffledQueue)..removeWhere((s) => s.id == song.id);
    notifyListeners();
  }

  // --- just_audio durum köprüleri ---

  int _retryCount = 0;
  bool _wasPlaying = false;

  /// Onarım botu API'si: akış önbelleğini boşaltır (aynı bozuk aday
  /// tekrar denenmesin) ve mevcut şarkıyı farklı kaynak adaylarıyla çalar.
  void clearStreamCache() {
    _streamCache.clear();
  }

  /// Onarım botu API'si: oynatıcı kilitli/hatalıysa şarkıyı yeniden başlatır.
  Future<void> retryCurrent() async {
    if (_index < 0 || _index >= effectiveQueue.length) return;
    _retryCount = 0;
    await _retryLoad();
  }

  Future<void> _retryLoad() async {
    _retryCount++;
    _isLoading = true;
    _lastError = null;
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 1200));
    await _buildAndPlay().catchError((_) {});
    _isLoading = false;
    notifyListeners();
    Future.delayed(const Duration(seconds: 10), () => _retryCount = 0);
  }

  void _onPlayerState(PlayerState state) {
    // Mobil veride bağlantı düşünce ExoPlayer "Loading interrupted" ile
    // durur ve kendiliğinden geri dönmez. playing→idle geçişi kesintidir:
    // otomatik yeniden yükle (max 2), bozuk kaynakta aday zinciri dener.
    final wasPlaying = _wasPlaying;
    _wasPlaying = state.playing;
    if (wasPlaying &&
        !state.playing &&
        state.processingState == ProcessingState.idle &&
        effectiveQueue.isNotEmpty &&
        _retryCount < 2 &&
        !_isLoading) {
      _retryLoad();
    }
    if (!state.playing && state.processingState == ProcessingState.completed) {
      // Oynatma bitti — odadaki kişiler için otomatik ilerle.
      // Yalnızca oda sahibi ilerletir; üyeler sahibin durumunu bekler.
      if (room.roomId != null && room.role == RoomRole.owner) {
        _autoplayNextRoomSync();
      } else if (room.roomId == null) {
        next(userTriggered: false);
      }
    }
    _syncRoom();
    notifyListeners();
  }

  void _onProcessingState(ProcessingState state) {
    if (state == ProcessingState.ready || state == ProcessingState.completed) {
      _isLoading = false;
    }
    // Crossfade: şarkının sonuna yaklaşıldığında başlat
    if (state == ProcessingState.buffering || state == ProcessingState.ready) {
      _scheduleCrossfade();
    }
    notifyListeners();
  }

  void _scheduleCrossfade() {
    _crossfadeTimer?.cancel();
    _crossfading = false;

    // Şarkının son 4 saniyesinde crossfade başlat
    final duration = _player.duration;
    if (duration == null || duration.inSeconds < 10) return;

    final remaining = duration - _player.position;
    if (remaining <= _crossfadeDuration) {
      _startCrossfade();
    } else {
      final delay = remaining - _crossfadeDuration;
      _crossfadeTimer = Timer(delay, () => _startCrossfade());
    }
  }

  Future<void> _prefetchNext() async {
    final q = effectiveQueue;
    if (_index < 0 || _index + 1 >= q.length) return;
    final nextSong = q[_index + 1];
    if (_streamCache.containsKey(_cacheKey(nextSong))) return;
    try {
      final url = await music.resolveStreamUrlForSong(nextSong,
          quality: switch (_quality) {
            AudioQuality.high => 'high',
            AudioQuality.medium => 'medium',
            AudioQuality.low => 'low',
            AudioQuality.ultra => 'ultra',
            AudioQuality.auto => 'auto',
          });
      _streamCache[_cacheKey(nextSong)] = url;
    } catch (_) {}
  }

  @override
  void dispose() {
    _crossfadeTimer?.cancel();
    _sleepTimer?.cancel();
    _player.dispose();
    super.dispose();
  }
}
