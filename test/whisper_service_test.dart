// Saf sözleşme testleri: speech_to_text / flutter_whisper_ggml plugin'lerine,
// cihaz mikrofonuna veya izin diyaloğuna BAĞLANMADAN çalışır.
// Gerçek servis yazıldığında yalnızca `SpeechService` uygulaması değişir;
// beklenen davranış bu dosyada kilitlidir.

import 'package:flutter_test/flutter_test.dart';

class RecognitionEvent {
  const RecognitionEvent(this.text, {required this.isFinal});

  final String text;
  final bool isFinal;
}

/// Minimal konuşma servisi sözleşmesi (mock'lanabilir yüzey).
abstract class SpeechService {
  Future<bool> initialize({required bool permissionGranted});
  List<String> get locales;
  Future<void> listen(void Function(RecognitionEvent) onResult);
  Future<void> stop();
  Future<void> cancel();
  bool get listening;
  String get partialText;
}

class FakeSpeechService implements SpeechService {
  FakeSpeechService({
    this.permissionGranted = true,
    this.availableLocales = const <String>['tr-TR', 'en-US'],
    this.script = const <RecognitionEvent>[],
  });

  final bool permissionGranted;
  final List<String> availableLocales;
  final List<RecognitionEvent> script;

  bool _initialized = false;
  bool _listening = false;
  String _partial = '';
  int _listenCalls = 0;

  @override
  List<String> get locales => List.unmodifiable(availableLocales);

  @override
  bool get listening => _listening;

  @override
  String get partialText => _partial;

  int get listenCalls => _listenCalls;

  @override
  Future<bool> initialize({required bool permissionGranted}) async {
    _initialized = permissionGranted && availableLocales.isNotEmpty;
    return _initialized;
  }

  @override
  Future<void> listen(void Function(RecognitionEvent) onResult) async {
    if (!_initialized) throw StateError('initialize() çağrılmadı');
    _listenCalls++;
    _listening = true;
    for (final event in script) {
      final text = normalizeTranscript(event.text);
      if (text.isEmpty) continue;
      _partial = text;
      onResult(event);
    }
  }

  @override
  Future<void> stop() async {
    _listening = false; // kısmi metin korunur; bırakınca arama yapılır.
  }

  @override
  Future<void> cancel() async {
    _listening = false;
    _partial = '';
  }
}

const int longPressThresholdMs = 250;

String normalizeTranscript(String raw) {
  final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.replaceAll(RegExp(r'[.,!?;:]+$'), '');
}

bool isLongPress(int heldMs) => heldMs >= longPressThresholdMs;

/// HomePage._onMicUp sözleşmesi: kısa dokunuş dinlemeyi açık bırakır,
/// uzun basış veya "zaten dinleniyor" durumu bırakınca gönderim ister.
bool shouldSubmitOnRelease({
  required bool listening,
  required bool stopOnUp,
  required int heldMs,
}) =>
    stopOnUp || isLongPress(heldMs);

bool shouldSubmitNow({
  required bool shouldSubmit,
  required bool listening,
}) =>
    shouldSubmit && listening;

String pickLocale(
  List<String> available,
  String preferred, {
  String system = '',
}) {
  if (preferred.isNotEmpty && available.contains(preferred)) return preferred;
  if (available.contains('tr-TR')) return 'tr-TR';
  if (system.isNotEmpty) return system;
  return available.isEmpty ? '' : available.first;
}

/// Final sonuç varsa o, yoksa son kısmi metin arama sorgusudur.
String queryFromEvents(List<RecognitionEvent> events) {
  var partial = '';
  for (final event in events) {
    final text = normalizeTranscript(event.text);
    if (text.isEmpty) continue;
    if (event.isFinal) return text;
    partial = text;
  }
  return partial;
}

String? submitOnce(String query, {bool alreadySubmitted = false}) {
  final normalized = normalizeTranscript(query);
  if (normalized.isEmpty || alreadySubmitted) return null;
  return normalized;
}

void main() {
  group('servis sözleşmesi: izin ve yaşam döngüsü', () {
    test('izin reddedilirse initialize false ve dinleme başlamaz', () async {
      final service = FakeSpeechService(permissionGranted: false);
      final ok = await service.initialize(permissionGranted: false);
      expect(ok, isFalse);

      await expectLater(
        service.listen((_) {}),
        throwsA(isA<StateError>()),
      );
      expect(service.listenCalls, 0);
      expect(service.listening, isFalse);
    });

    test('izin varsa initialize true, script oynatılır', () async {
      final service = FakeSpeechService(script: const [
        RecognitionEvent('  lofi   chill  ', isFinal: false),
        RecognitionEvent('lofi chill.', isFinal: true),
      ]);
      expect(await service.initialize(permissionGranted: true), isTrue);

      final events = <RecognitionEvent>[];
      await service.listen(events.add);
      expect(service.listenCalls, 1);
      expect(events, hasLength(2));
      expect(service.listening, isTrue);
      expect(service.partialText, 'lofi chill');
    });

    test('stop kısmi metni korur, cancel temizler', () async {
      final service = FakeSpeechService(script: const [
        RecognitionEvent('tarkan', isFinal: false),
      ]);
      await service.initialize(permissionGranted: true);
      await service.listen((_) {});

      await service.stop();
      expect(service.listening, isFalse);
      expect(service.partialText, 'tarkan');

      await service.cancel();
      expect(service.partialText, isEmpty);
    });
  });

  group('locale seçimi', () {
    test('tercih edilen dil kuruluysa o kullanılır', () {
      expect(
        pickLocale(const ['tr-TR', 'en-US'], 'tr-TR'),
        'tr-TR',
      );
    });

    test('tr-TR yoksa sistem dili, o da yoksa ilk dil', () {
      expect(
        pickLocale(const ['en-US', 'de-DE'], 'tr-TR', system: 'de-DE'),
        'de-DE',
      );
      expect(
        pickLocale(const ['en-US', 'de-DE'], 'tr-TR'),
        'en-US',
      );
    });

    test('tanıma servisi yoksa boş döner', () {
      expect(pickLocale(const [], 'tr-TR'), isEmpty);
    });
  });

  group('sonuç -> arama sorgusu', () {
    test('kısmi sonuç biriketir, final sonuç kazanır', () {
      expect(
        queryFromEvents(const [
          RecognitionEvent('  daft  ', isFinal: false),
          RecognitionEvent('daft punk', isFinal: false),
          RecognitionEvent('Daft Punk.', isFinal: true),
        ]),
        'Daft Punk',
      );
      expect(
        queryFromEvents(const [
          RecognitionEvent('  lofi  chill  ', isFinal: false),
        ]),
        'lofi chill',
      );
      expect(queryFromEvents(const []), isEmpty);
    });

    test('boş metin ve çift gönderim engellenir', () {
      expect(normalizeTranscript('   \n  '), isEmpty);
      expect(submitOnce('   '), isNull);
      expect(submitOnce('tarkan'), 'tarkan');
      expect(
        submitOnce('tarkan', alreadySubmitted: true),
        isNull,
      );
    });
  });

  group('mikrofon jesti sözleşmesi', () {
    test('250ms altı kısa dokunuş gönderim istemez', () {
      expect(isLongPress(0), isFalse);
      expect(isLongPress(249), isFalse);
      expect(
        shouldSubmitOnRelease(listening: true, stopOnUp: false, heldMs: 120),
        isFalse,
      );
    });

    test('uzun basış veya dinleme sırasında bırakma gönderir', () {
      expect(isLongPress(250), isTrue);
      expect(isLongPress(900), isTrue);
      expect(
        shouldSubmitOnRelease(listening: true, stopOnUp: false, heldMs: 800),
        isTrue,
      );
      expect(
        shouldSubmitOnRelease(listening: false, stopOnUp: true, heldMs: 10),
        isTrue,
      );
      expect(
        shouldSubmitNow(
          shouldSubmit:
              shouldSubmitOnRelease(listening: false, stopOnUp: false, heldMs: 900),
          listening: false,
        ),
        isFalse,
      );
    });
  });
}
