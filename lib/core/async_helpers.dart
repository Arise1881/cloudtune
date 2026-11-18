import 'dart:async';

/// Verilen adayları aynı anda başlatır ve ilk **başarılı** (null olmayan)
/// sonucu döndürür. Tüm adaylar null veya hatalı biterse null döner.
///
/// Sıralı denen çözüm yollarında ilk aday 6 sn takıldığında sonraki adaylar
/// da aynı süre bekliyordu; eşzamanlı başlatma toplam gecikmeyi en yavaş
/// tek adayla sınırlar. Kazanan dışındaki future'lar arka planda tamamlanır;
/// hataları burada yakalanır, böylece unhandled error oluşmaz.
Future<T?> firstSuccess<T>(Iterable<Future<T?>> candidates) async {
  final futures = candidates.toList();
  if (futures.isEmpty) return null;

  final completer = Completer<T?>();
  var pending = futures.length;
  for (final future in futures) {
    future
        .then(
          (value) {
            if (value != null && !completer.isCompleted) {
              completer.complete(value);
            }
          },
          onError: (Object _) {},
        )
        .whenComplete(() {
          pending--;
          if (pending == 0 && !completer.isCompleted) completer.complete(null);
        });
  }
  return completer.future;
}
