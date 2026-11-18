import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_whisper_ggml/flutter_whisper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Sesli aramanın kullanıcıya gösterilecek durumu.
enum SpeechPhase {
  idle,
  preparing,
  recording,
  downloading,
  transcribing,
  done,
  error,
}

class SpeechStatus {
  const SpeechStatus(this.phase, {this.progress = 0, this.message = ''});

  final SpeechPhase phase;
  /// 0..1 arası model indirme ilerlemesi.
  final double progress;
  final String message;
}

/// Google/sistem tanıma servisine bağlı olmayan sesli arama sözleşmesi.
abstract class SpeechService {
  /// Cihaz/backend hazırlığı. İzin istemez, model indirmez.
  Future<bool> initialize();

  /// Mikrofon iznini kontrol eder, gerekirse ister.
  /// Yalnızca kullanıcı mikrofon düğmesine bastığında çağrılmalı.
  Future<bool> hasPermission();

  /// Kaydı başlatır. Model indirme/yükleme kayıtla paralel ilerler.
  Future<void> listen({required String locale, bool partialResults = true});

  /// Kaydı durdurur ve yerel Whisper ile metne çevrir.
  Future<void> stop();

  /// Aktif oturumu iptal eder, kaydı siler.
  Future<void> cancel();

  Future<void> dispose();

  /// Transkript parçaları (aralık sonuç + nihai metin).
  Stream<String> get partialResults;

  /// Model indirme ilerlemesi ve hata mesajları için UI akışı.
  Stream<SpeechStatus> get status;

  bool get isListening;

  /// En son tamamlanan transkript; `stop()` bitince okunur.
  String get lastTranscript;
}

/// whisper.cpp tabanlı, tamamen yerel/çevrimdışı transkripsiyon.
class WhisperSpeechService implements SpeechService {
  WhisperSpeechService();

  // Çok dilli (İngilizce özel DEĞİL) ve küçük model: Türkçe için gerekli.
  // Quantize edilmiş Q5_1 ~32 MB; ilk kullanımda indirilir, sonrası diskte cache.
  static const WhisperModel _model = WhisperModels.tinyQ5_1;
  static const _config = WhisperModelConfig(useGpu: false);

  final AudioRecorder _recorder = AudioRecorder();
  final StreamController<String> _partialController =
      StreamController<String>.broadcast();
  final StreamController<SpeechStatus> _statusController =
      StreamController<SpeechStatus>.broadcast();

  FlutterWhisper? _whisper;
  Future<FlutterWhisper>? _modelFuture;
  Object? _modelError;
  bool _recording = false;
  bool _disposed = false;
  int _session = 0;
  String? _wavPath;
  String _lastTranscript = '';
  String _languageCode = 'tr';

  /// Whisper'ın desteklediği diller. Uygulama dili bunlardan biri değilse
  /// transkripsiyon İngilizce model diliyle yapılır (arama yine çalışır).
  static const Set<String> _supportedLanguages = <String>{
    'af', 'am', 'ar', 'as', 'az', 'ba', 'be', 'bg', 'bn', 'bo', 'br', 'bs',
    'ca', 'cs', 'cy', 'da', 'de', 'el', 'en', 'es', 'et', 'eu', 'fa', 'fi',
    'fo', 'fr', 'gl', 'gu', 'ha', 'haw', 'he', 'hi', 'hr', 'ht', 'hu', 'hy',
    'id', 'is', 'it', 'ja', 'jw', 'ka', 'kk', 'km', 'kn', 'ko', 'la', 'lb',
    'lo', 'lt', 'lv', 'mg', 'mi', 'mk', 'ml', 'mn', 'mr', 'ms', 'mt', 'my',
    'ne', 'nl', 'nn', 'no', 'oc', 'pa', 'pl', 'ps', 'pt', 'ro', 'ru', 'sa',
    'sd', 'si', 'sk', 'sl', 'sm', 'sn', 'so', 'sq', 'sr', 'su', 'sv', 'sw',
    'ta', 'te', 'tg', 'th', 'tl', 'tr', 'tt', 'uk', 'ur', 'uz', 'vi', 'yi',
    'yo', 'zh',
  };

  String get _whisperLanguage =>
      _supportedLanguages.contains(_languageCode) ? _languageCode : 'en';

  @override
  Stream<String> get partialResults => _partialController.stream;

  @override
  Stream<SpeechStatus> get status => _statusController.stream;

  @override
  bool get isListening => _recording;

  @override
  String get lastTranscript => _lastTranscript;

  void _emit(SpeechPhase phase, {double progress = 0, String message = ''}) {
    if (_disposed || _statusController.isClosed) return;
    _statusController.add(
      SpeechStatus(phase, progress: progress, message: message),
    );
  }

  bool _active(int session) => !_disposed && session == _session;

  @override
  Future<bool> initialize() async {
    if (_disposed) return false;
    // Sistem konuşma tanıma servisi aranmaz; model ilk kayıtta yüklenir.
    // Native whisper.cpp, web'de WASM backend kullanılır.
    return true;
  }

  @override
  Future<bool> hasPermission() async {
    if (_disposed) return false;
    // Web'de izni tarayıcı getUserMedia akışı ister, bizim dialogumuz yok.
    if (kIsWeb) return true;
    try {
      final status = await Permission.microphone.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) return false;
      final result = await Permission.microphone.request();
      return result.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Modeli tek sefer yükler; aynı oturumda tekrar indirme yapılmaz.
  Future<FlutterWhisper> _ensureModel() {
    final cached = _modelFuture;
    if (cached != null) return cached;

    final future = FlutterWhisper.loadModel(
      model: _model,
      config: _config,
      onDownloadProgress: (p) => _emit(
        SpeechPhase.downloading,
        progress: p.fraction,
        message: 'Whisper modeli indiriliyor %${p.percent}',
      ),
      onModelProgress: (p) {
        if (p > 0 && p < 100) {
          _emit(
            SpeechPhase.downloading,
            message: 'Whisper modeli yükleniyor %$p',
          );
        }
      },
    );
    _modelFuture = future;
    // Başarısız indirme sonraki denemede tekrar yapılabilsin.
    // ignore: unawaited_futures
    final session = _session;
    future.then<void>(
      (_) {
        // İptal edilen oturumun indirmesi sonuçlansa bile cache'e bağlanmaz;
        // sonraki deneme diskteki model dosyasını yeniden kullanır.
        if (identical(_modelFuture, future) && _session != session) {
          _modelFuture = null;
        }
      },
      onError: (Object e, StackTrace s) {
        if (identical(_modelFuture, future)) {
          _modelFuture = null;
          _modelError = e;
        }
      },
    );
    return future;
  }

  @override
  Future<void> listen({
    required String locale,
    bool partialResults = true,
  }) async {
    if (_disposed) return;
    final session = ++_session;
    _languageCode = locale.toLowerCase().split('-').first;
    _lastTranscript = '';
    _modelError = null;
    _wavPath = null;
    _emit(SpeechPhase.preparing, message: 'Sesli arama hazırlanıyor…');

    if (kIsWeb) {
      // Web'de record path'i yok sayılır; stop() blob URL döndürür.
      _wavPath = 'cloudtune-voice.wav';
    } else {
      final dir = await getTemporaryDirectory();
      _wavPath =
          '${dir.path}/cloudtune_voice_${DateTime.now().microsecondsSinceEpoch}.wav';
    }
    if (!_active(session)) return;

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _wavPath!,
      );
    } catch (e) {
      _emit(SpeechPhase.error, message: _recordErrorMessage(e));
      rethrow;
    }
    if (!_active(session)) {
      // Kayıt başladıktan sonra iptal edildiyse hemen bırak.
      unawaited(_recorder.cancel());
      return;
    }

    _recording = true;
    _emit(SpeechPhase.recording, message: 'Dinleniyor…');

    // İlk kullanımda model indirmesi kayıtla paralel ilerler; kullanıcı
    // konuşurken indirme ilerlemesi arama çubuğunun altında görünür.
    unawaited(_preloadModel(session));
  }

  Future<void> _preloadModel(int session) async {
    try {
      final whisper = await _ensureModel();
      if (!_active(session)) return;
      _whisper = whisper;
      if (_recording) {
        _emit(SpeechPhase.recording, message: 'Dinleniyor…');
      }
    } catch (e) {
      if (!_active(session)) return;
      _modelError ??= e;
      _emit(
        SpeechPhase.error,
        message: 'Whisper modeli yüklenemedi. İnternet bağlantısını kontrol edin.',
      );
    }
  }

  @override
  Future<void> stop() async {
    if (!_recording && _wavPath == null) return;
    final session = _session;
    _recording = false;

    String? path;
    try {
      path = await _recorder.stop().timeout(const Duration(seconds: 8));
    } catch (e) {
      _emit(SpeechPhase.error, message: _recordErrorMessage(e));
      return;
    }
    if (!_active(session)) return;

    if (_modelError != null) {
      _emit(
        SpeechPhase.error,
        message: 'Whisper modeli yüklenemedi. İnternet bağlantısını kontrol edin.',
      );
      return;
    }

    FlutterWhisper whisper;
    try {
      whisper = await _ensureModel();
    } catch (_) {
      _emit(
        SpeechPhase.error,
        message: 'Whisper modeli yüklenemedi. İnternet bağlantısını kontrol edin.',
      );
      return;
    }
    if (!_active(session)) return;
    _whisper = whisper;

    final input = path ?? _wavPath;
    if (input == null) {
      _emit(SpeechPhase.error, message: 'Ses kaydı alınamadı.');
      return;
    }

    _emit(SpeechPhase.transcribing, message: 'Ses metne çevriliyor…');
    try {
      final result = await whisper.transcribeFile(
        input,
        config: WhisperTranscribeConfig(language: _whisperLanguage, threads: 4),
        onSegment: (segment) {
          if (_partialController.isClosed) return;
          _partialController.add(segment.text);
        },
      );
      if (!_active(session)) return;
      final text = result.text.trim();
      if (text.isNotEmpty) {
        _lastTranscript = text;
        if (!_partialController.isClosed) _partialController.add(text);
      }
      _emit(SpeechPhase.done);
    } catch (_) {
      if (!_active(session)) return;
      _emit(
        SpeechPhase.error,
        message: 'Ses metne çevrilemedi. Tekrar deneyin.',
      );
    }
  }

  @override
  Future<void> cancel() async {
    _session++;
    _recording = false;
    // Model henüz yüklenmediyse bekleyen future'ı bırak; iptal sonrası yeni
    // bir arama diskteki (varsa kısmi) model dosyasından devam eder.
    if (_whisper == null) _modelFuture = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.cancel().timeout(const Duration(seconds: 4));
      }
    } catch (_) {}
    _lastTranscript = '';
    _emit(SpeechPhase.idle);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _session++;
    _recording = false;
    try {
      await _recorder.dispose();
    } catch (_) {}
    final whisper = _whisper;
    _whisper = null;
    if (whisper != null) {
      try {
        await whisper.dispose();
      } catch (_) {}
    }
    _disposed = true;
    await _partialController.close();
    await _statusController.close();
  }

  /// Platforma göre anlaşılır kayıt hatası mesajı.
  String _recordErrorMessage(Object error) {
    final text = error.toString();
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return "Linux'ta mikrofon kaydı için parecord, pactl ve ffmpeg kurulu olmalı.";
    }
    if (kIsWeb) {
      return 'Tarayıcı mikrofon izni vermedi veya kayıt desteklenmiyor.';
    }
    if (text.toLowerCase().contains('permission')) {
      return 'Mikrofon izni gerekli.';
    }
    return 'Ses kaydı başlatılamadı.';
  }
}
