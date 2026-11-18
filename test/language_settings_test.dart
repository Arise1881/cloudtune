import 'package:cloudtune/core/settings_service.dart';
import 'package:cloudtune/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.instance.init();
  });

  group('AppStrings', () {
    test('Türkçe ve İngilizce çeviriler', () {
      expect(const AppStrings('tr').settings, 'Ayarlar');
      expect(const AppStrings('en').settings, 'Settings');
      expect(const AppStrings('tr').fullRepair, 'Tam onarımı çalıştır');
      expect(const AppStrings('en').fullRepair, 'Run full repair');
    });

    test('diğer 26 dil İngilizceye düşer', () {
      for (final code in SettingsService.supportedLanguages.keys) {
        if (code == 'tr' || code == 'en') continue;
        expect(AppStrings(code).settings, 'Settings');
        expect(AppStrings(code).repairBot, 'Repair bot');
      }
      expect(SettingsService.supportedLanguages.length, 28);
    });

    test('çeviri haritaları aynı anahtarları içerir', () {
      expect(
        AppStrings.turkish.keys.toSet(),
        AppStrings.english.keys.toSet(),
      );
    });

    test('desteklenen locale listesi ayarlarla eşleşir', () {
      expect(AppStrings.supportedLocales.length, 28);
      expect(
        AppStrings.supportedLocales.map((e) => e.languageCode).toSet(),
        SettingsService.supportedLanguages.keys.toSet(),
      );
    });

    test('yer tutucular doldurulur', () {
      expect(const AppStrings('tr').repairPending(3), '3 bekliyor');
      expect(const AppStrings('en').repairPending(3), '3 pending');
      expect(const AppStrings('en').updateNewVersion('4.0'),
          'New version: 4.0');
    });
  });

  group('SettingsService dili', () {
    test('locale ve değişim bildirimi', () async {
      await SettingsService.instance.setLanguage('tr');
      expect(SettingsService.instance.locale, const Locale('tr'));

      var notified = 0;
      void listener() => notified++;
      SettingsService.instance.addListener(listener);
      await SettingsService.instance.setLanguage('en');
      SettingsService.instance.removeListener(listener);

      expect(SettingsService.instance.languageCode, 'en');
      expect(SettingsService.instance.locale, const Locale('en'));
      expect(notified, 1);
    });

    test('desteklenmeyen kod reddedilir', () async {
      await SettingsService.instance.setLanguage('tr');
      await SettingsService.instance.setLanguage('xx');
      expect(SettingsService.instance.languageCode, 'tr');
    });

    testWidgets('dil değişimi MaterialApp içindeki metni değiştirir',
        (tester) async {
      await SettingsService.instance.setLanguage('tr');
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: SettingsService.instance,
          builder: (context, _) {
            return MaterialApp(
              locale: SettingsService.instance.locale,
              supportedLocales: AppStrings.supportedLocales,
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                AppStringsDelegate(),
                AppMaterialLocalizationsDelegate(),
                AppCupertinoLocalizationsDelegate(),
              ],
              home: const _SettingsProbe(),
            );
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ayarlar'), findsOneWidget);
      await SettingsService.instance.setLanguage('en');
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);

      await SettingsService.instance.setLanguage('tr');
      await tester.pumpAndSettle();
    });
  });
}

class _SettingsProbe extends StatelessWidget {
  const _SettingsProbe();

  @override
  Widget build(BuildContext context) {
    return Text(AppStrings.of(context).settings);
  }
}
