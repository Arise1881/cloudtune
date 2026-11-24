import 'package:cloudtune/core/player_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldAutoAdvanceOnCompleted', () {
    bool check({
      bool opening = false,
      bool loading = false,
      bool advancing = false,
      bool recovering = false,
      bool hasError = false,
      Duration? duration = const Duration(minutes: 3),
      Duration position = Duration.zero,
      Duration? lastActivePosition,
    }) {
      return shouldAutoAdvanceOnCompleted(
        opening: opening,
        loading: loading,
        advancing: advancing,
        recovering: recovering,
        hasError: hasError,
        duration: duration,
        position: position,
        lastActivePosition: lastActivePosition,
      );
    }

    test('gerçek şarkı sonunda geçiş yapılır', () {
      expect(
        check(position: const Duration(minutes: 3)),
        isTrue,
      );
    });

    test('motor konumu sıfırlasa da son bilinen konum kullanılır', () {
      expect(
        check(position: Duration.zero,
            lastActivePosition: const Duration(minutes: 3)),
        isTrue,
      );
    });

    test('hata sonrası bayat completed sinyali geçiş yapmaz', () {
      expect(check(position: const Duration(seconds: 42)), isFalse);
      expect(
        check(
          position: Duration.zero,
          lastActivePosition: const Duration(seconds: 42),
        ),
        isFalse,
      );
    });

    test('hata, yükleme, kurtarma veya açılış sırasında geçiş yapmaz', () {
      final atEnd = const Duration(minutes: 3);
      expect(check(position: atEnd, hasError: true), isFalse);
      expect(check(position: atEnd, loading: true), isFalse);
      expect(check(position: atEnd, opening: true), isFalse);
      expect(check(position: atEnd, advancing: true), isFalse);
      expect(check(position: atEnd, recovering: true), isFalse);
    });

    test('süresi bilinmeyen akışta geçiş yapmaz', () {
      expect(
        check(duration: null, position: const Duration(minutes: 3)),
        isFalse,
      );
    });
  });
}
