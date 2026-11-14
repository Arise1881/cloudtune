import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'models.dart';
import 'youtube_service.dart';

class PlayerController extends ChangeNotifier {
  PlayerController._() {
    _player.playerStateStream.listen(_onPlayerState);
    _player.playbackEventStream.listen((_) {}, onError: _onPlaybackError);
  }
  static final PlayerController instance = PlayerController._();

  final AudioPlayer _player = AudioPlayer();

  List<Track> _queue = const [];
  int _index = -1;
  bool _loading = false;
  String? _error;
  bool _advancing = false;
  bool _recovering = false;

  List<Track> get queue => _queue;
  int get index => _index;
  bool get loading => _loading;
  String? get error => _error;
  Track? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  bool get hasNext => _index + 1 < _queue.length;
  bool get hasPrevious => _index > 0;

  Stream<bool> get playingStream => _player.playingStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  Future<void> playQueue(List<Track> tracks, int startIndex) async {
    if (tracks.isEmpty) return;
    _queue = List.unmodifiable(tracks);
    await _playAt(startIndex.clamp(0, tracks.length - 1));
  }

  Future<void> _playAt(int i, {Duration? resumeAt, bool retry = true}) async {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    _loading = true;
    _error = null;
    notifyListeners();

    final track = _queue[i];
    try {
      final uri = await YoutubeService.instance.audioUri(track.id);
      if (_index != i) return; // Kullanıcı bu sırada başka şarkıya geçti.
      await _player.setAudioSource(
        AudioSource.uri(
          uri,
          tag: MediaItem(
            id: track.id,
            title: track.title,
            artist: track.artist,
            artUri: Uri.parse(track.thumb),
            duration: track.duration,
          ),
        ),
        initialPosition: resumeAt,
      );
      _loading = false;
      notifyListeners();
      unawaited(_player.play());
    } catch (e) {
      if (_index != i) return;
      if (retry) {
        return _playAt(i, resumeAt: resumeAt, retry: false);
      }
      _loading = false;
      _error = 'Çalınamadı: ${_short(e)}';
      notifyListeners();
    }
  }

  String _short(Object e) {
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  void _onPlayerState(PlayerState state) {
    if (state.processingState == ProcessingState.completed && !_advancing) {
      _advancing = true;
      if (hasNext) {
        _playAt(_index + 1).whenComplete(() => _advancing = false);
      } else {
        _advancing = false;
      }
    }
  }

  /// Akış adresi süresi dolarsa aynı konumdan yeni adresle devam eder.
  Future<void> _onPlaybackError(Object error, StackTrace _) async {
    if (_recovering || current == null) return;
    _recovering = true;
    final position = _player.position;
    try {
      await _playAt(_index, resumeAt: position, retry: false);
    } finally {
      _recovering = false;
    }
  }

  Future<void> toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      unawaited(_player.play());
    }
  }

  Future<void> next() => _playAt(_index + 1);

  Future<void> previous() async {
    if (_player.position > const Duration(seconds: 4) || !hasPrevious) {
      await _player.seek(Duration.zero);
    } else {
      await _playAt(_index - 1);
    }
  }

  Future<void> seek(Duration position) => _player.seek(position);
}
