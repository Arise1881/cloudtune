// Tekrar modu için SAF enum/geçiş testleri. Flutter, audio_service veya
// PlayerController.instance gerekmez; gerçek enum yazıldığında bu sözleşme
// doğrudan ona uygulanır.

import 'package:flutter_test/flutter_test.dart';

enum RepeatMode { off, all, one }

const Map<RepeatMode, String> repeatLabels = <RepeatMode, String>{
  RepeatMode.off: 'Kapalı',
  RepeatMode.all: 'Tümünü tekrarla',
  RepeatMode.one: 'Tek parçayı tekrarla',
};

RepeatMode nextMode(RepeatMode mode) => switch (mode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };

/// Kuyruk sonunda hangi indise geçileceği. `one` aynı parçada kalır.
int nextIndex(RepeatMode mode, int current, int length) {
  if (length <= 0) return -1;
  if (current < 0 || current >= length) {
    return mode == RepeatMode.off ? -1 : 0;
  }
  if (mode == RepeatMode.one) return current;
  if (current + 1 < length) return current + 1;
  return mode == RepeatMode.all ? 0 : -1;
}

bool shouldAdvance(RepeatMode mode, {required bool hasNext}) =>
    hasNext || mode == RepeatMode.all;

bool shouldReplaySame(RepeatMode mode) => mode == RepeatMode.one;

RepeatMode repeatModeFromLabel(String? raw) {
  final value = (raw ?? '').toLowerCase();
  if (value.contains('kapal') ||
      value.contains('off') ||
      value.contains('devre dışı')) {
    return RepeatMode.off;
  }
  if (value.contains('tek parça') ||
      value.contains('tek parca') ||
      value.contains('one') ||
      value.contains('single')) {
    return RepeatMode.one;
  }
  if (value.contains('tüm') ||
      value.contains('tum') ||
      value.contains('all') ||
      value.contains('loop')) {
    return RepeatMode.all;
  }
  return RepeatMode.off;
}

void main() {
  group('enum geçişi', () {
    test('off -> all -> one -> off sırası', () {
      expect(nextMode(RepeatMode.off), RepeatMode.all);
      expect(nextMode(RepeatMode.all), RepeatMode.one);
      expect(nextMode(RepeatMode.one), RepeatMode.off);
    });

    test('üç dokunuştan sonra başlangıca dönüş', () {
      var mode = RepeatMode.off;
      for (var i = 0; i < 3; i++) {
        mode = nextMode(mode);
      }
      expect(mode, RepeatMode.off);
    });

    test('tüm modların etiketi var', () {
      for (final mode in RepeatMode.values) {
        expect(repeatLabels[mode], isNotNull);
        expect(repeatLabels[mode]!.trim(), isNotEmpty);
      }
    });
  });

  group('kuyruk indeksi', () {
    test('orta parçada sıradaki indeise geçilir', () {
      for (final mode in RepeatMode.values) {
        if (mode == RepeatMode.one) continue;
        expect(nextIndex(mode, 1, 4), 2);
      }
    });

    test('son parçada off durur, all başa döner', () {
      expect(nextIndex(RepeatMode.off, 3, 4), -1);
      expect(nextIndex(RepeatMode.all, 3, 4), 0);
      expect(nextIndex(RepeatMode.one, 3, 4), 3);
    });

    test('tek parça modu her zaman aynı indisi verir', () {
      expect(nextIndex(RepeatMode.one, 0, 5), 0);
      expect(nextIndex(RepeatMode.one, 4, 5), 4);
      expect(shouldReplaySame(RepeatMode.one), isTrue);
      expect(shouldReplaySame(RepeatMode.all), isFalse);
    });

    test('boş kuyruk ve geçersiz indeks güvenli', () {
      for (final mode in RepeatMode.values) {
        expect(nextIndex(mode, 0, 0), -1);
      }
      expect(nextIndex(RepeatMode.off, -1, 3), -1);
      expect(nextIndex(RepeatMode.all, 99, 3), 0);
    });
  });

  group('ilerleme kararı', () {
    test('sıradaki parça varsa mod fark etmeksizin ilerlenir', () {
      for (final mode in RepeatMode.values) {
        expect(shouldAdvance(mode, hasNext: true), isTrue);
      }
    });

    test('sıradaki yoksa yalnızca all ilerler', () {
      expect(shouldAdvance(RepeatMode.off, hasNext: false), isFalse);
      expect(shouldAdvance(RepeatMode.all, hasNext: false), isTrue);
      expect(shouldAdvance(RepeatMode.one, hasNext: false), isFalse);
    });
  });

  group('UI etiketinden mod çıkarımı', () {
    test('tooltip / content-desc varyasyonları', () {
      expect(repeatModeFromLabel('Tek parçayı tekrarla'), RepeatMode.one);
      expect(repeatModeFromLabel('repeat one'), RepeatMode.one);
      expect(repeatModeFromLabel('Tümünü tekrarla'), RepeatMode.all);
      expect(repeatModeFromLabel('repeat all / loop'), RepeatMode.all);
      expect(repeatModeFromLabel('Tekrar kapalı'), RepeatMode.off);
      expect(repeatModeFromLabel(null), RepeatMode.off);
    });
  });
}
