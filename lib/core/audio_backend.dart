import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
// `PlayerState` just_audio tarafında kullanılıyor; media_kit'teki aynı isimli
// modeli gizliyoruz.
import 'package:media_kit/media_kit.dart' hide PlayerState;

/// Platform-bağımsız oynatıcı durumu. `audio_service` eşlemesi çalar tarafında
/// yapılır; backend yalnızca kendi motorunun durumunu bildirir.
enum PlaybackStatus { idle, loading, buffering, ready, completed }

/// `PlayerController` tarafından kullanılan asgari ses motoru sözleşmesi.
///
/// Android/iOS: just_audio (ExoPlayer / AVPlayer).
/// Linux: media_kit + libmpv. just_audio'nun Linux implementasyonu yok;
/// doğrudan kullanıldığında `MissingPluginException` ve "parça oynatılamadı"
/// hatası oluşuyordu.
abstract class AudioBackend {
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<PlaybackStatus> get statusStream;
  Stream<Object> get errorStream;

  bool get playing;
  Duration get position;
  Duration get buffered;
  double get speed;
  double get volume;
  PlaybackStatus get status;

  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  });
  Future<void> setVolume(double value);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> applyEqualizer(bool enabled, String preset);
}

AudioBackend createAudioBackend() =>
    Platform.isLinux ? MediaKitAudioBackend() : JustAudioBackend();

class JustAudioBackend implements AudioBackend {
  late final AudioPlayer _player;
  AndroidEqualizer? _equalizer;
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  JustAudioBackend() {
    if (Platform.isAndroid) {
      // Ekolayzer yalnızca Android zincirine eklenir; kapalıyken efekt
      // takılırsa bazı cihazlarda çizirti/underrun oluşuyordu.
      _equalizer = AndroidEqualizer();
      _player = AudioPlayer(
        audioPipeline: AudioPipeline(androidAudioEffects: [_equalizer!]),
        useLazyPreparation: false,
      );
    } else {
      _player = AudioPlayer(useLazyPreparation: false);
    }

    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace _) => _errors.add(error),
    );
  }

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<PlaybackStatus> get statusStream =>
      _player.playerStateStream.map(_mapState);

  @override
  Stream<Object> get errorStream => _errors.stream;

  @override
  bool get playing => _player.playing;

  @override
  Duration get position => _player.position;

  @override
  Duration get buffered => _player.bufferedPosition;

  @override
  double get speed => _player.speed;

  @override
  double get volume => _player.volume;

  @override
  PlaybackStatus get status => _mapState(_player.playerState);

  static PlaybackStatus _mapState(PlayerState state) =>
      switch (state.processingState) {
        ProcessingState.idle => PlaybackStatus.idle,
        ProcessingState.loading => PlaybackStatus.loading,
        ProcessingState.buffering => PlaybackStatus.buffering,
        ProcessingState.ready => PlaybackStatus.ready,
        ProcessingState.completed => PlaybackStatus.completed,
      };

  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) =>
      _player.setAudioSource(
        AudioSource.uri(uri, headers: headers, tag: tag),
        initialPosition: initialPosition,
      );

  @override
  Future<void> setVolume(double value) => _player.setVolume(value);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> applyEqualizer(bool enabled, String preset) async {
    final eq = _equalizer;
    if (eq == null) return;
    try {
      await eq.setEnabled(enabled);
      if (!enabled) return;
      final bands = (await eq.parameters).bands;
      if (bands.isEmpty) return;
      final gains = _gains(preset);
      for (var i = 0; i < bands.length; i++) {
        await bands[i].setGain(gains[i % gains.length]);
      }
    } catch (_) {}
  }

  static List<double> _gains(String preset) => switch (preset) {
        'flat' => [0, 0, 0, 0, 0],
        'bass' => [8, 5, 0, -1, 1],
        'treble' => [-1, 0, 2, 6, 8],
        'vocal' => [-2, 1, 5, 3, 0],
        _ => [0, 0, 0, 0, 0],
      };
}

/// Linux ses motoru. `media_kit_libs_linux` paketi libmpv binary'sini
/// bundle'a koyar; harici mpv kurulumu gerekmez.
class MediaKitAudioBackend implements AudioBackend {
  late final Player _player;
  final StreamController<PlaybackStatus> _status =
      StreamController<PlaybackStatus>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  MediaKitAudioBackend() {
    MediaKit.ensureInitialized();
    _player = Player();

    _player.stream.playing.listen((_) => _emitStatus());
    _player.stream.buffering.listen((_) => _emitStatus());
    _player.stream.duration.listen((_) => _emitStatus());
    _player.stream.completed.listen((done) {
      if (done) {
        _status.add(PlaybackStatus.completed);
      } else {
        _emitStatus();
      }
    });
    _player.stream.error.listen((message) => _errors.add(message));
  }

  void _emitStatus() {
    if (!_status.isClosed) _status.add(_currentStatus);
  }

  PlaybackStatus get _currentStatus {
    final state = _player.state;
    if (state.completed) return PlaybackStatus.completed;
    if (state.buffering) return PlaybackStatus.buffering;
    if (state.playlist.medias.isEmpty) return PlaybackStatus.idle;
    return PlaybackStatus.ready;
  }

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration?> get durationStream =>
      _player.stream.duration.map<Duration?>((d) => d);

  @override
  Stream<PlaybackStatus> get statusStream => _status.stream;

  @override
  Stream<Object> get errorStream => _errors.stream;

  @override
  bool get playing => _player.state.playing;

  @override
  Duration get position => _player.state.position;

  @override
  Duration get buffered => _player.state.buffer;

  @override
  double get speed => _player.state.rate;

  @override
  double get volume => _player.state.volume / 100;

  @override
  PlaybackStatus get status => _currentStatus;

  @override
  Future<void> open(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async {
    // just_audio 0..1, libmpv 0..100 kullanır. Kaynak değişiminden önce
    // gain'i sabitle; aksi halde ilk parça sessiz açılabiliyordu.
    await _player.setVolume(100);
    await _player.open(
      Media(
        uri.toString(),
        httpHeaders: headers,
        start: initialPosition,
      ),
      play: false,
    );
  }

  @override
  Future<void> setVolume(double value) =>
      _player.setVolume(value.clamp(0.0, 1.0).toDouble() * 100);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> applyEqualizer(bool enabled, String preset) async {}
}
