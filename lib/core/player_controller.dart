import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'library.dart';
import 'models.dart';
import 'youtube_service.dart';

/// Tek merkezli calar. Ayni zamanda audio_service isleyicisidir; boylece
/// kilit ekrani / bildirim uzerinden sarki bilgisi, ileri-geri ve begeni
/// aksiyonlari calisir.
class PlayerController extends BaseAudioHandler with ChangeNotifier {
  PlayerController._() {
    _player.playerStateStream.listen(_onPlayerState);
    _player.playbackEventStream.listen(
      (_) => _broadcast(),
      onError: (Object error, StackTrace _) => _onPlaybackError(error),
    );
    _player.positionStream.listen((_) => _broadcastPosition());
    _player.durationStream.listen((d) {
      _duration = d;
      _broadcast();
    });
  }

  static final PlayerController instance = PlayerController._();

  final AudioPlayer _player = AudioPlayer();

  List<Track> _queue = const [];
  int _index = -1;
  bool _loading = false;
  String? _error;
  bool _advancing = false;
  bool _recovering = false;
  bool _extending = false;
  bool _radioMode = true;
  Duration? _duration;
  int _lastBroadcastSecond = -1;

  List<Track> get tracks => _queue;
  int get index => _index;
  bool get loading => _loading;
  String? get error => _error;
  bool get radioMode => _radioMode;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  bool get hasNext => _index + 1 < _queue.length;
  bool get hasPrevious => _index > 0;

  Stream<bool> get playingStream => _player.playingStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  void setRadioMode(bool value) {
    _radioMode = value;
    notifyListeners();
  }

  void _broadcastPosition() {
    final second = _player.position.inSeconds;
    if (second == _lastBroadcastSecond) return;
    _lastBroadcastSecond = second;
    _broadcast();
  }

  /// audio_service'e guncel durumu bildir (kilit ekrani icin).
  void _broadcast() {
    final track = current;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (_player.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl(
            androidIcon: Library.instance.isLiked(track?.id ?? '')
                ? 'drawable/ic_favorite'
                : 'drawable/ic_favorite_border',
            label: 'Begen',
            action: MediaAction.custom,
            customAction: const CustomMediaAction(name: 'like'),
          ),
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (_player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _index,
      ),
    );
  }

  void _publishMediaItem(Track track) {
    mediaItem.add(
      MediaItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        album: 'CloudTune',
        artUri: Uri.parse(track.thumb),
        duration: track.duration ?? _duration,
        extras: {
          'liked': Library.instance.isLiked(track.id),
          'artistId': track.artistId,
        },
      ),
    );
  }

  Future<void> playQueue(
    List<Track> tracks,
    int startIndex, {
    bool radio = true,
  }) async {
    if (tracks.isEmpty) return;
    _queue = List.unmodifiable(tracks);
    _radioMode = radio && Library.instance.radioEnabled;
    await _playAt(startIndex.clamp(0, tracks.length - 1));
  }

  Future<void> _playAt(int i, {Duration? resumeAt, bool retry = true}) async {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    _loading = true;
    _error = null;
    notifyListeners();

    final track = _queue[i];
    _publishMediaItem(track);
    _broadcast();
    try {
      final uri = await YoutubeService.instance.audioUri(track.id);
      if (_index != i) return; // Kullanici bu sirada baska sarkiya gecti.
      await _player.setAudioSource(
        AudioSource.uri(uri, tag: mediaItem.value),
        initialPosition: resumeAt,
      );
      _loading = false;
      notifyListeners();
      unawaited(_player.play());
      unawaited(Library.instance.remember(track));
    } catch (_) {
      if (_index != i) return;
      if (retry) {
        return _playAt(i, resumeAt: resumeAt, retry: false);
      }
      _loading = false;
      _error = 'stream'; // Kullaniciya gosterilmez, onarim botu devralir.
      notifyListeners();
    }
  }

  void _onPlayerState(PlayerState state) {
    _broadcast();
    if (state.processingState == ProcessingState.completed && !_advancing) {
      _advancing = true;
      _advance().whenComplete(() => _advancing = false);
    }
  }

  Future<void> _advance() async {
    if (hasNext) {
      await _playAt(_index + 1);
      return;
    }
    // Kuyruk bitti: radyo modunda devam et (sonsuz calma).
    if (!_radioMode || !Library.instance.radioEnabled) return;
    await _extendRadio();
    if (hasNext) await _playAt(_index + 1);
  }

  /// Mevcut sarkinin ilgili videolarini kuyruga ekle.
  Future<void> _extendRadio() async {
    final seed = current;
    if (seed == null || _extending) return;
    _extending = true;
    try {
      final more = await YoutubeService.instance.related(seed.id, limit: 30);
      final fresh = more.where((t) => !_queue.any((q) => q.id == t.id)).toList();
      if (fresh.isNotEmpty) {
        _queue = List.unmodifiable([..._queue, ...fresh]);
        notifyListeners();
      }
    } finally {
      _extending = false;
    }
  }

  /// Otomatik radyo doldurmasi (kullanici kaydirirken de cagrilabilir).
  Future<void> extendRadio() => _extendRadio();

  /// Akis adresi suresi dolarsa ayni konumdan yeni adresle devam eder.
  Future<void> _onPlaybackError(Object error) async {
    if (_recovering || current == null) return;
    _recovering = true;
    final position = _player.position;
    try {
      await _playAt(_index, resumeAt: position, retry: false);
    } finally {
      _recovering = false;
    }
  }

  /// Onarim botu / harici tetikleyiciler icin: mevcut indeksten yeniden dene.
  Future<void> retry() => _playAt(_index, retry: true);

  Future<void> toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      unawaited(_player.play());
    }
  }

  Future<void> next() => _advance();

  Future<void> previous() async {
    if (_player.position > const Duration(seconds: 4) || !hasPrevious) {
      await _player.seek(Duration.zero);
    } else {
      await _playAt(_index - 1);
    }
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  // ── audio_service sozlesmesi ──
  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => next();

  @override
  Future<void> skipToPrevious() => previous();

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'like') {
      final track = current;
      if (track != null) {
        await Library.instance.toggleLike(track);
        _publishMediaItem(track);
        _broadcast();
      }
    }
  }
}
