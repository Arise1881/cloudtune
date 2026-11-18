import 'dart:async';

import 'package:cloudtune/core/async_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('firstSuccess boş aday listesinde null döner', () async {
    expect(await firstSuccess<String>(const []), isNull);
  });

  test('firstSuccess ilk başarıyı, sıra fark etmeksizin döndürür', () async {
    final slow = Completer<String?>();
    final fast = Completer<String?>();
    final result = firstSuccess<String?>([slow.future, fast.future]);

    fast.complete('hızlı');
    expect(await result, 'hızlı');
    slow.complete('yavaş');
  });

  test('firstSuccess hata ve null adayları yok sayar', () async {
    final failing = Completer<String?>();
    final empty = Completer<String?>();
    final good = Completer<String?>();
    final result = firstSuccess<String?>([
      failing.future,
      empty.future,
      good.future,
    ]);

    failing.completeError(StateError('bağlantı yok'));
    empty.complete(null);
    good.complete('çözüldü');
    expect(await result, 'çözüldü');
  });

  test('firstSuccess tüm adaylar başarısızsa null döner', () async {
    final first = Completer<String?>();
    final second = Completer<String?>();
    final result = firstSuccess<String?>([first.future, second.future]);

    first.completeError(StateError('hata'));
    second.complete(null);
    expect(await result, isNull);
  });

  test('firstSuccess bekleyen adayları beklemez', () async {
    final winner = Completer<int?>();
    final pending = Completer<int?>();
    var settled = false;
    final result = firstSuccess<int?>([pending.future, winner.future]);
    result.then((_) => settled = true);

    winner.complete(7);
    await result;
    await Future<void>.microtask(() {});
    expect(settled, isTrue);
    expect(pending.isCompleted, isFalse);
    pending.complete(null);
  });
}
