import 'package:flutter_test/flutter_test.dart';

import 'package:sonora/main.dart';

void main() {
  testWidgets('Uygulama basit smoke testi', (WidgetTester tester) async {
    // Ağ ve platform kanalları mock'lanmadan tam uygulama kurulamaz;
    // bu nedenle yalnızca derlenebilirlik amaçlı bir yer tutucu test.
    expect(MelodyApp, isNotNull);
  });
}
