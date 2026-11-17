import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'download_service.dart';
import 'library.dart';
import 'models.dart';
import 'repair_bot.dart';
import 'settings_service.dart';
import 'youtube_service.dart';

class _SkipSegment {
  const _SkipSegment(this.start, this.end);

  final double start;
  final double end;

  bool contains(Duration position) {
    final seconds = position.inMilliseconds / 1000;
    return seconds >= start && seconds < end;
  }
}

/// Merkezi çalar. Bildirim, kilit ekranı, Bluetooth ve Android Auto
/// `audio_service` üzerinden bu sınıfa bağlanır.
///
/// Kuyruk yönetimi, geçiş kimliği (race guard), çevrimdışı öncelik,
/// önbellek/ısıtma, hata kurtarma ve parça atlama mantığı.
class PlayerController extends BaseAudioHandler with ChangeNotifier {
  PlayerController._() {
    _equalizer = AndroidEqualizer();
    // ExoPlayer varsayılan olarak 2,5 sn tampon bekler. İlk ses ve parça
    // geçişi için bu değer ~0,6 sn'ye indirilir; ileri tampon korunur.
    _player = AudioPlayer(
      audioPipeline: AudioPipeline(androidAudioEffects: [_equalizer]),
      audioLoadConfiguration: AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: const Duration(seconds: 12),
          maxBufferDuration: const Duration(seconds: 30),
          bufferForPlaybackDuration: const Duration(milliseconds: 600),
          bufferForPlaybackAfterRebufferDuration:
              const Duration(milliseconds: 900),
          prioritizeTimeOverSizeThresholds: true,
        ),
      ),
      useLazyPreparation: true,
    );

    _player.playerStateStream.listen(_onPlayerState);
    _player.playbackEventStream.listen(
      (_) => _broadcast(),
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
  int _failureStreak = 0;
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

  static const int _lookahead = 5;
  static const int _maxPreloads = 3;
  final Set<String> _preloaded = <String>{};
  int _activePreloads = 0;

  List<_SkipSegment> _skipSegments = const <_SkipSegment>[];
  _SkipSegment? _lastSkipped;

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
    _failureStreak = 0;
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
    _skipSegments = const <_SkipSegment>[];
    _lastSkipped = null;
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
      _failureStreak = 0;
      _error = null;
      _broadcast();
      notifyListeners();

      await _player.play();
      unawaited(Library.instance.remember(track));
      unawaited(_preloadUpcoming());
      unawaited(_applyEqualizer());
      if (SettingsService.instance.sponsorBlockEnabled) {
        unawaited(_loadSponsorSegments(track.id));
      }
    } on AudioBlocked catch (error) {
      if (_isStale(transition, generation)) return;
      _loading = false;
      _error = 'stream';
      notifyListeners();
      unawaited(RepairBot.instance.reportEvent('audio_blocked', {
        'video_id': track.id,
        'reason': error.reason,
      }));
      await _skipAfterFailure(transition, generation, const Duration(milliseconds: 400));
    } catch (_) {
      if (_isStale(transition, generation)) return;
      if (retry) {
        final direct = await YoutubeService.instance.forceDirect(track.id);
        if (_isStale(transition, generation)) return;
        if (direct != null) {
          try {
            await _setSource(direct, resumeAt);
            if (_isStale(transition, generation)) return;
            _loading = false;
            _error = null;
            _failureStreak = 0;
            _broadcast();
            notifyListeners();
            await _player.play();
            unawaited(Library.instance.remember(track));
            unawaited(_preloadUpcoming());
            return;
          } catch (_) {}
        }
      }
      if (_isStale(transition, generation)) return;
      _loading = false;
      _error = 'stream';
      notifyListeners();
      await _skipAfterFailure(transition, generation, const Duration(seconds: 2));
    }
  }

  Future<Uri> _resolveTrack(Track track) async {
    final saved = DownloadService.instance.savedPathOf(track.id);
    if (saved != null) return Uri.file(saved);
    return YoutubeService.instance.audioUri(track.id);
  }

  Future<void> _skipAfterFailure(
    int transition,
    int generation,
    Duration delay,
  ) async {
    _failureStreak++;
    if (!hasNext || _failureStreak > 3) return;
    await Future<void>.delayed(delay);
    if (_isStale(transition, generation)) return;
    await _advance();
  }

  Future<void> _setSource(Uri uri, Duration? resumeAt) async {
    await _player
        .setAudioSource(
          AudioSource.uri(
            uri,
            tag: mediaItem.value,
            headers: const {
              'User-Agent': 'Mozilla/5.0 (Linux; Android 14) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/126.0 Mobile Safari/537.36',
              'Referer': 'https://www.youtube.com/',
              'Origin': 'https://www.youtube.com/',
              'Accept': '*/*',
              'Accept-Encoding': 'identity;q=1, *;q=0',
            },
          ),
          initialPosition: resumeAt,
        )
        .timeout(const Duration(seconds: 9));
  }

  void _onPosition(Duration position) {
    final skipped = _lastSkipped;
    if (skipped != null) {
      if (skipped.contains(position)) {
        unawaited(_player.seek(_secs(skipped.end)));
        return;
      }
      _lastSkipped = null;
    }

    final segment = _findSegment(position);
    if (segment != null) {
      _lastSkipped = segment;
      unawaited(_player.seek(_secs(segment.end)));
      return;
    }

    final second = position.inSeconds;
    if (second == _lastBroadcastSecond) return;
    _lastBroadcastSecond = second;
    _broadcast();
  }

  _SkipSegment? _findSegment(Duration position) {
    for (final segment in _skipSegments) {
      if (segment.contains(position)) return segment;
    }
    return null;
  }

  static Duration _secs(double seconds) =>
      Duration(milliseconds: (seconds * 1000).round() + 100);

  Future<void> _loadSponsorSegments(String videoId) async {
    try {
      final response = await http
          .get(
            Uri.https('sponsor.ajay.app', '/api/skipSegments', {
              'videoID': videoId,
            }),
          )
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body);
      if (data is! List || current?.id != videoId) return;
      final enabled = SettingsService.instance.sponsorCategories.toSet();
      _skipSegments = data.whereType<Map>().map((item) {
        final category = item['category']?.toString();
        if (category != null && category.isNotEmpty && !enabled.contains(category)) {
          return null;
        }
        final segment = item['segment'];
        if (segment is! List || segment.length < 2) return null;
        final start = (segment[0] as num?)?.toDouble();
        final end = (segment[1] as num?)?.toDouble();
        if (start == null || end == null || end <= start) return null;
        return _SkipSegment(start, end);
      }).whereType<_SkipSegment>().toList();
    } catch (_) {
      // SponsorBlock verisi yoksa çalma etkilenmez.
    }
  }

  Future<void> _applyEqualizer() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final settings = SettingsService.instance;
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
      unawaited(_advance());
    }
  }

  Future<void> _advance() async {
    if (_advancing || _shuffleBusy) return;
    _advancing = true;
    try {
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
    if (_recovering || _loading || current == null) return;
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
    await SettingsService.instance.setSleepTimerMinutes(minutes);
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
      final id = _queue[_index + offset].id;
      if (_preloaded.contains(id)) continue;
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
