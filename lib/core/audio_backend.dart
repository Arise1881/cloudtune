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

  /// Kaynağı açar açmaz `play()` kuyruğa alır. Dokunma→ses gecikmesinde
  /// `open()` sonrası ayrı `play()` çağrısı gereksiz tur yapıyordu.
  Future<void> openAndPlay(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async {
    await open(
      uri,
      headers: headers,
      initialPosition: initialPosition,
      tag: tag,
    );
    await play();
  }

  /// Dokunmadan önce görünen parçanın ilk saniyesini arka planda tamponlar.
  /// Varsayılan olarak desteklenmez; platform motoru hazırlık yapabilirse
  /// geçersiz kılar.
  Future<void> prepare(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async {}

  /// Hazırlanmış parça dokunulduysa tamponu sıfırlamadan çalar. `false`
  /// dönerse normal [openAndPlay] yolu kullanılır.
  Future<bool> openAndPlayIfPrepared(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async =>
      false;

  Future<void> setVolume(double value);

  /// Oda senkronunda küçük konum farklarını yumuşatmak için hız ayarı.
  Future<void> setSpeed(double value);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> applyEqualizer(bool enabled, String preset);
}

AudioBackend createAudioBackend() =>
    Platform.isLinux ? MediaKitAudioBackend() : JustAudioBackend();

/// Preset kazançları (dB). Android zinciri ve libmpv `af` zinciri aynı eğriyi
/// kullanır; 'normal'/'flat' düz kalır.
List<double> equalizerGains(String preset) => switch (preset) {
      'flat' || 'normal' => [0, 0, 0, 0, 0],
      'bass' => [8, 5, 0, -1, 1],
      'treble' => [-1, 0, 2, 6, 8],
      'vocal' => [-2, 1, 5, 3, 0],
      _ => [0, 0, 0, 0, 0],
    };

class JustAudioBackend implements AudioBackend {
  // Aktif motor + dokunma öncesi tamponlanmış motor havuzu. Hazır parça
  // seçildiğinde o motor aktife geçer; yeni akışın ilk paketini beklemeden
  // ses anında başlar. Farklı kartların hazırlığı birbirini iptal etmez.
  late AudioPlayer _active;
  final Map<String, AudioPlayer> _pool = <String, AudioPlayer>{};
  final Set<String> _preparing = <String>{};
  final Map<String, int> _tokens = <String, int>{};
  static const int _maxPrepared = 10;
  final Map<AudioPlayer, AndroidEqualizer> _equalizers =
      <AudioPlayer, AndroidEqualizer>{};

  final StreamController<bool> _playing = StreamController<bool>.broadcast();
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _duration =
      StreamController<Duration?>.broadcast();
  final StreamController<PlaybackStatus> _status =
      StreamController<PlaybackStatus>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  JustAudioBackend() {
    _active = _newPlayer();
    _bind(_active);
  }

  AudioPlayer _newPlayer() {
    AndroidEqualizer? equalizer;
    final player = Platform.isAndroid
        ? () {
            // Ekolayzer yalnızca Android zincirine eklenir; kapalıyken efekt
            // takılırsa bazı cihazlarda çizirti/underrun oluşuyordu.
            equalizer = AndroidEqualizer();
            return AudioPlayer(
              audioPipeline: AudioPipeline(androidAudioEffects: [equalizer!]),
              // Hazırlığı play()'e bırakır: setAudioSource tamponu beklemeden
              // döner, ilk ses karesi gelmeden önce oturum PLAYING'e geçer.
              useLazyPreparation: true,
              // just_audio varsayılan olarak header'ları 127.0.0.1 üzerinden
              // düz metin proxy ile gönderir. NSC cleartext kapalı olduğu için
              // bu, her parçada "Source error" üretiyordu. Android ExoPlayer
              // ve iOS AVPlayer header'ları doğrudan destekliyor.
              useProxyForRequestHeaders: false,
            );
          }()
        : AudioPlayer(
            useLazyPreparation: true,
            useProxyForRequestHeaders: false,
          );
    final eq = equalizer;
    if (eq != null) _equalizers[player] = eq;
    return player;
  }

  /// Yalnızca aktif motorun olayları dışarıya taşınır. Yedek motor tamponlanırken
  /// ürettiği konum/hata olayları arayüzü bozmasın.
  void _bind(AudioPlayer player) {
    player.playingStream.listen((value) {
      if (identical(player, _active)) _playing.add(value);
    });
    player.positionStream.listen((value) {
      if (identical(player, _active)) _position.add(value);
    });
    player.durationStream.listen((value) {
      if (identical(player, _active)) _duration.add(value);
    });
    player.playerStateStream.listen((state) {
      if (identical(player, _active)) _status.add(_mapState(state));
    });
    player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace _) {
        if (identical(player, _active)) _errors.add(error);
      },
    );
  }

  String _prepareKey(Uri uri, Duration? initialPosition) =>
      '${uri.toString()}@${initialPosition?.inMilliseconds ?? 0}';

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Stream<PlaybackStatus> get statusStream => _status.stream;

  @override
  Stream<Object> get errorStream => _errors.stream;

  @override
  bool get playing => _active.playing;

  @override
  Duration get position => _active.position;

  @override
  Duration get buffered => _active.bufferedPosition;

  @override
  double get speed => _active.speed;

  @override
  double get volume => _active.volume;

  @override
  PlaybackStatus get status => _mapState(_active.playerState);

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
      _active.setAudioSource(
        AudioSource.uri(uri, headers: headers, tag: tag),
        initialPosition: initialPosition,
        preload: false,
      );

  bool _current(String key, int token) => _tokens[key] == token;

  /// Görünen parçanın ilk saniyesini ayrı bir motorla arka planda tamponlar.
  /// Mikrofon sessiz tutulur; kullanıcı dokunana kadar duyulmaz.
  @override
  Future<void> prepare(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async {
    final key = _prepareKey(uri, initialPosition);
    if (_pool.containsKey(key) || _preparing.contains(key)) return;
    // Havuz dolunca eski hazırlıkları atma: kullanıcı genelde ilk gördüğü
    // kartlara dokunur, onların tamponunu korumak gecikmeyi asıl düşürüyor.
    if (_pool.length >= _maxPrepared || _preparing.length >= _maxPrepared) {
      return;
    }
    final token = (_tokens[key] ?? 0) + 1;
    _tokens[key] = token;
    _preparing.add(key);
    final player = _newPlayer();
    _bind(player);
    try {
      await player.setVolume(0);
      if (!_current(key, token)) return;
      await player.setAudioSource(
        AudioSource.uri(uri, headers: headers, tag: tag),
        initialPosition: initialPosition,
        preload: false,
      );
      if (!_current(key, token)) return;
      // load() kaynağı çalmadan getirmeye başlar; play()'den farklı olarak
      // mikrofona ses gitmez.
      await player
          .load()
          .timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
      if (!_current(key, token)) return;
      const need = Duration(milliseconds: 700);
      final deadline = DateTime.now().add(const Duration(milliseconds: 1500));
      while (
          player.bufferedPosition < need && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        if (!_current(key, token)) return;
      }
      if (player.bufferedPosition <= Duration.zero) return;
      await player.pause();
      if (_current(key, token)) {
        _pool[key] = player;
      }
    } catch (_) {
    } finally {
      _preparing.remove(key);
      if (_tokens[key] == token) _tokens.remove(key);
      if (!_pool.containsKey(key)) {
        _equalizers.remove(player);
        unawaited(player.dispose().catchError((Object _) {}));
      }
    }
  }

  @override
  Future<bool> openAndPlayIfPrepared(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async {
    final key = _prepareKey(uri, initialPosition);
    final incoming = _pool.remove(key);
    if (incoming == null) return false;
    // Havuzdayken kaynak hata veren/sonlanan bir motor `completed` durumunda
    // kalabilir. Aktif motora yükseltilirse bu bayat sinyal otomatik parça
    // geçişi tetikler. Böyle bir motoru kullanmayıp normal açılışa düş.
    if (_mapState(incoming.playerState) == PlaybackStatus.completed) {
      _equalizers.remove(incoming);
      unawaited(incoming.dispose().catchError((Object _) {}));
      return false;
    }
    final outgoing = _active;
    _tokens[key] = (_tokens[key] ?? 0) + 1;
    try {
      await incoming.setVolume(1);
      // Referansı önce değiştir: yeni motordan gelecek ilk olaylar arayüze
      // doğru aktif motor olarak yansır.
      _active = incoming;
      unawaited(outgoing.pause().catchError((Object _) {}).whenComplete(
          () => unawaited(outgoing.dispose().catchError((Object _) {}))));
      _equalizers.remove(outgoing);
      unawaited(incoming.play().catchError((Object _) {}));
      return true;
    } catch (_) {
      _active = outgoing;
      _pool[key] = incoming;
      return false;
    }
  }

  @override
  Future<void> openAndPlay(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async {
    // Gain'i kaynak değişiminden önce sabitle; sonradan setVolume() bazı
    // cihazlarda ilk parçayı sessiz bırakıyordu.
    await _active.setVolume(1);
    await _active.setAudioSource(
      AudioSource.uri(uri, headers: headers, tag: tag),
      initialPosition: initialPosition,
      // setAudioSource tamponu beklemesin; play() yüklemeyi başlatır.
      preload: false,
    );
    // Lazy preparation nedeniyle kaynak henüz tamponlanmamış olabilir; play()
    // çağrısı hazırlığı başlatır ve medya oturumu anında PLAYING olur.
    await play();
  }

  @override
  Future<void> setVolume(double value) => _active.setVolume(value);

  @override
  Future<void> setSpeed(double value) => _active.setSpeed(value);

  @override
  Future<void> play() async {
    // just_audio'da play() Future'ı parça bitene/pause olana kadar tamamlanmaz.
    // Komutu hemen iletip çalar akışını bloklamayız; hatalar errorStream'den
    // zaten bildiriliyor.
    unawaited(_active.play().catchError((Object _) {}));
  }

  @override
  Future<void> pause() => _active.pause();

  @override
  Future<void> seek(Duration position) => _active.seek(position);

  @override
  Future<void> applyEqualizer(bool enabled, String preset) async {
    for (final entry in _equalizers.entries) {
      final eq = entry.value;
      try {
        await eq.setEnabled(enabled);
        if (!enabled) continue;
        final bands = (await eq.parameters).bands;
        if (bands.isEmpty) continue;
        final gains = equalizerGains(preset);
        for (var i = 0; i < bands.length; i++) {
          await bands[i].setGain(gains[i % gains.length]);
        }
      } catch (_) {}
    }
  }
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

    // Parçalar arası ses seviyesi farkı (özellikle YouTube akışları) bazı
    // şarkıları duyulmaz kılıyordu. ReplayGain her parçada normalize edilir.
    unawaited(() async {
      try {
        await _setMpvProperty('audio-replay-gain-mode', 'track');
      } catch (_) {}
    }());
  }

  /// `Player.platform` yalnızca PlatformPlayer sözleşmesini açığa çıkarır;
  /// mpv özellikleri NativePlayer üzerinden ayarlanır.
  NativePlayer? get _nativePlayer {
    final platform = _player.platform;
    return platform is NativePlayer ? platform : null;
  }

  Future<void> _setMpvProperty(String name, String value) async {
    final native = _nativePlayer;
    if (native == null) return;
    await native.setProperty(name, value);
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
  Future<void> openAndPlay(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async {
    await open(
      uri,
      headers: headers,
      initialPosition: initialPosition,
      tag: tag,
    );
    await play();
  }

  // libmpv ikinci motorla tampon hazırlamıyor; normal açılış yolu kullanılır.
  @override
  Future<void> prepare(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async {}

  @override
  Future<bool> openAndPlayIfPrepared(
    Uri uri, {
    required Map<String, String> headers,
    Duration? initialPosition,
    Object? tag,
  }) async =>
      false;

  @override
  Future<void> setVolume(double value) =>
      _player.setVolume(value.clamp(0.0, 1.0).toDouble() * 100);

  @override
  Future<void> setSpeed(double value) =>
      _player.setRate(value.clamp(0.5, 2.0).toDouble());

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> applyEqualizer(bool enabled, String preset) async {
    try {
      await _setMpvProperty('audio-replay-gain-mode', 'track');
      if (!enabled) {
        await _setMpvProperty('af', '');
        await _player.setVolume(100);
        return;
      }

      // libmpv, FFmpeg `equalizer` filtresini `lavfi=[...]` ile uygular.
      // Beş bant: bas, alt-orta, orta, üst-orta, tiz.
      const frequencies = <int>[100, 400, 1600, 6000, 12000];
      final gains = equalizerGains(preset);
      final filters = <String>[
        for (var i = 0; i < frequencies.length; i++)
          'equalizer=f=${frequencies[i]}:t=q:w=1:g=${gains[i % gains.length]}',
      ];
      await _setMpvProperty('af', 'lavfi=[${filters.join(',')}]');
      await _player.setVolume(100);
    } catch (_) {
      // Eski libmpv yapılarında `af` desteklenmeyebilir; en azından
      // seviye_normalizasyonu ve gain 100 uygulanır.
      try {
        await _setMpvProperty('af', '');
        await _setMpvProperty('audio-replay-gain-mode', 'track');
        await _player.setVolume(100);
      } catch (_) {}
    }
  }
}
