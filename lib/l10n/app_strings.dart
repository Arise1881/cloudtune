import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';

import '../core/settings_service.dart';

/// Ayarlar ekranı için hafif yerelleştirme.
/// Türkçe ve İngilizce tam çeviri vardır; diğer diller İngilizceye düşer.
/// Ağır bir JSON/ARB katmanı veya `flutter_localizations` bağımlılığı gerekmez.
class AppStrings {
  const AppStrings(this.languageCode);

  final String languageCode;

  /// Desteklenen tüm diller için `Locale` listesi. Tek kaynak:
  /// [SettingsService.supportedLanguages].
  static final List<Locale> supportedLocales = List<Locale>.unmodifiable(
    SettingsService.supportedLanguages.keys.map((code) => Locale(code)),
  );

  static const Map<String, String> turkish = <String, String>{
    'settings': 'Ayarlar',
    'home': 'Ana sayfa',
    'appearance': 'Görünüm',
    'accentHint': 'Vurgu rengi uygulamanın tamamına uygulanır.',
    'theme': 'Tema',
    'themeDark': 'Koyu',
    'themeLight': 'Açık',
    'themeSystem': 'Sistem',
    'oledBlack': 'OLED siyah arka plan',
    'oledHint': 'Koyu temada saf siyah zemin.',
    'playback': 'Çalma',
    'endlessRadio': 'Sonsuz radyo',
    'endlessRadioHint': 'Şarkı bitince benzer parçalarla devam eder.',
    'downloadToDevice': 'Cihaza doğrudan indir',
    'downloadToDeviceHint':
        'İndirilenler Download/CloudTune klasörüne kaydedilir.',
    'audioQuality': 'Ses kalitesi',
    'qualityLow': 'Düşük',
    'qualityMedium': 'Orta',
    'qualityHigh': 'Yüksek',
    'qualityVeryHigh': 'Çok yüksek',
    'equalizer': 'Ekolayzer',
    'equalizerHint': 'Sesi artır / azalt.',
    'eqBass': 'Bas',
    'eqTreble': 'Tiz',
    'eqVocal': 'Vokal',
    'eqFlat': 'Düz',
    'eqNormal': 'Normal',
    'language': 'Dil',
    'appLanguage': 'Uygulama dili',
    'system': 'Sistem',
    'repairBot': 'Onarım botu',
    'repairIdle': 'Beklemede',
    'repairScanning': 'Denetleniyor…',
    'repairBackground': 'Arka planda etkin · {fixes} onarım',
    'repairPending': '{pending} bekliyor',
    'scanNow': 'Şimdi tara',
    'scanDone': 'Onarım taraması tamamlandı.',
    'fullRepair': 'Tam onarımı çalıştır',
    'fullRepairHint': 'Tüm aşamaları zorla çalıştırır.',
    'fullRepairRunning': 'Tam onarım çalışıyor…',
    'fullRepairTitle': 'Tam onarım sonucu',
    'repairLogs': 'Onarım kayıtları',
    'repairLogsHint': 'Son onarım olaylarını görüntüle.',
    'noLogs': 'Kayıt yok.',
    'clear': 'Temizle',
    'close': 'Kapat',
    'updates': 'Güncellemeler',
    'updateNewVersion': 'Yeni sürüm: {version}',
    'updateCheckFailed': 'Kontrol edilemedi',
    'updateInstalled': 'Kurulu sürüm: {version}',
    'updateReady': 'Yeni sürüm hazır: {version}',
    'updateCheckError': 'Güncelleme kontrolü başarısız.',
    'updateCurrent': 'Uygulama güncel.',
    'updateInstall': 'Güncellemeyi indir ve kur',
    'updateInstallHint': 'Yeni sürümü şimdi yükle',
    'appTagline': 'YouTube akışlı müzik çalar · reklamsız',
    'profileTagline': 'Müziğini sen yönet · reklamsız, odaklı, hızlı',
    'stagePlayback': 'Oynatma',
    'stageDownloads': 'İndirmeler',
    'stagePending': 'Bekleyen işler',
    'statusSuccess': 'Tamam',
    'statusProblem': 'Sorunlu',
    'statusSkipped': 'Atlandı',
    'resultFixed': 'Giderilen sorun: {count}',
    'resultRemaining': 'Kalan sorun: {count}',
    'resultClean': 'Kalan sorun yok.',
    'stageSummary': '{stage}: {status} · {fixed} giderildi, {remaining} kaldı',
  };

  static const Map<String, String> english = <String, String>{
    'settings': 'Settings',
    'home': 'Home',
    'appearance': 'Appearance',
    'accentHint': 'Accent color applies throughout the app.',
    'theme': 'Theme',
    'themeDark': 'Dark',
    'themeLight': 'Light',
    'themeSystem': 'System',
    'oledBlack': 'OLED black background',
    'oledHint': 'Pure black background in dark theme.',
    'playback': 'Playback',
    'endlessRadio': 'Endless radio',
    'endlessRadioHint': 'Keeps playing similar tracks when a song ends.',
    'downloadToDevice': 'Download directly to device',
    'downloadToDeviceHint': 'Downloads are saved to the Download/CloudTune folder.',
    'audioQuality': 'Audio quality',
    'qualityLow': 'Low',
    'qualityMedium': 'Medium',
    'qualityHigh': 'High',
    'qualityVeryHigh': 'Very high',
    'equalizer': 'Equalizer',
    'equalizerHint': 'Boost or cut the sound.',
    'eqBass': 'Bass',
    'eqTreble': 'Treble',
    'eqVocal': 'Vocal',
    'eqFlat': 'Flat',
    'eqNormal': 'Normal',
    'language': 'Language',
    'appLanguage': 'App language',
    'system': 'System',
    'repairBot': 'Repair bot',
    'repairIdle': 'Idle',
    'repairScanning': 'Scanning…',
    'repairBackground': 'Active in background · {fixes} repairs',
    'repairPending': '{pending} pending',
    'scanNow': 'Scan now',
    'scanDone': 'Repair scan completed.',
    'fullRepair': 'Run full repair',
    'fullRepairHint': 'Forces every stage to run.',
    'fullRepairRunning': 'Running full repair…',
    'fullRepairTitle': 'Full repair result',
    'repairLogs': 'Repair logs',
    'repairLogsHint': 'View recent repair events.',
    'noLogs': 'No logs.',
    'clear': 'Clear',
    'close': 'Close',
    'updates': 'Updates',
    'updateNewVersion': 'New version: {version}',
    'updateCheckFailed': 'Check failed',
    'updateInstalled': 'Installed version: {version}',
    'updateReady': 'New version ready: {version}',
    'updateCheckError': 'Update check failed.',
    'updateCurrent': 'App is up to date.',
    'updateInstall': 'Download and install update',
    'updateInstallHint': 'Install the new version now',
    'appTagline': 'Streaming music player from YouTube · ad-free',
    'profileTagline': 'You run your music · ad-free, focused, fast',
    'stagePlayback': 'Playback',
    'stageDownloads': 'Downloads',
    'stagePending': 'Pending tasks',
    'statusSuccess': 'Done',
    'statusProblem': 'Problem',
    'statusSkipped': 'Skipped',
    'resultFixed': 'Problems fixed: {count}',
    'resultRemaining': 'Problems remaining: {count}',
    'resultClean': 'No problems remaining.',
    'stageSummary': '{stage}: {status} · {fixed} fixed, {remaining} left',
  };

  Map<String, String> get _map => languageCode == 'tr' ? turkish : english;

  String _t(String key) => _map[key] ?? english[key] ?? key;

  /// `{name}` biçimindeki yer tutucuları doldurur.
  String format(String key, Map<String, String> values) {
    var text = _t(key);
    for (final entry in values.entries) {
      text = text.replaceAll('{${entry.key}}', entry.value);
    }
    return text;
  }

  String get settings => _t('settings');
  String get home => _t('home');
  String get appearance => _t('appearance');
  String get accentHint => _t('accentHint');
  String get theme => _t('theme');
  String get themeDark => _t('themeDark');
  String get themeLight => _t('themeLight');
  String get themeSystem => _t('themeSystem');
  String get oledBlack => _t('oledBlack');
  String get oledHint => _t('oledHint');
  String get playback => _t('playback');
  String get endlessRadio => _t('endlessRadio');
  String get endlessRadioHint => _t('endlessRadioHint');
  String get downloadToDevice => _t('downloadToDevice');
  String get downloadToDeviceHint => _t('downloadToDeviceHint');
  String get audioQuality => _t('audioQuality');
  String get qualityLow => _t('qualityLow');
  String get qualityMedium => _t('qualityMedium');
  String get qualityHigh => _t('qualityHigh');
  String get qualityVeryHigh => _t('qualityVeryHigh');
  String get equalizer => _t('equalizer');
  String get equalizerHint => _t('equalizerHint');
  String get eqBass => _t('eqBass');
  String get eqTreble => _t('eqTreble');
  String get eqVocal => _t('eqVocal');
  String get eqFlat => _t('eqFlat');
  String get eqNormal => _t('eqNormal');
  String get language => _t('language');
  String get appLanguage => _t('appLanguage');
  String get system => _t('system');
  String get repairBot => _t('repairBot');
  String get repairIdle => _t('repairIdle');
  String get repairScanning => _t('repairScanning');
  String repairBackground(int fixes) =>
      format('repairBackground', {'fixes': '$fixes'});
  String repairPending(int count) =>
      format('repairPending', {'pending': '$count'});
  String get scanNow => _t('scanNow');
  String get scanDone => _t('scanDone');
  String get fullRepair => _t('fullRepair');
  String get fullRepairHint => _t('fullRepairHint');
  String get fullRepairRunning => _t('fullRepairRunning');
  String get fullRepairTitle => _t('fullRepairTitle');
  String get repairLogs => _t('repairLogs');
  String get repairLogsHint => _t('repairLogsHint');
  String get noLogs => _t('noLogs');
  String get clear => _t('clear');
  String get close => _t('close');
  String get updates => _t('updates');
  String updateNewVersion(String? version) =>
      format('updateNewVersion', {'version': version ?? ''});
  String get updateCheckFailed => _t('updateCheckFailed');
  String updateInstalled(String version) =>
      format('updateInstalled', {'version': version});
  String updateReady(String? version) =>
      format('updateReady', {'version': version ?? ''});
  String get updateCheckError => _t('updateCheckError');
  String get updateCurrent => _t('updateCurrent');
  String get updateInstall => _t('updateInstall');
  String get updateInstallHint => _t('updateInstallHint');
  String get appTagline => _t('appTagline');
  String get profileTagline => _t('profileTagline');
  String get stagePlayback => _t('stagePlayback');
  String get stageDownloads => _t('stageDownloads');
  String get stagePending => _t('stagePending');
  String get statusSuccess => _t('statusSuccess');
  String get statusProblem => _t('statusProblem');
  String get statusSkipped => _t('statusSkipped');
  String resultFixed(int count) => format('resultFixed', {'count': '$count'});
  String resultRemaining(int count) =>
      format('resultRemaining', {'count': '$count'});
  String get resultClean => _t('resultClean');
  String stageSummary(String stage, String status, int fixed, int remaining) =>
      format('stageSummary', {
        'stage': stage,
        'status': status,
        'fixed': '$fixed',
        'remaining': '$remaining',
      });

  /// Context'ten yerelleştirme nesnesini alır.Delegate yüklenmemişse
  /// güvenli İngilizce fallback döner.
  static AppStrings of(BuildContext context) {
    return Localizations.of<AppStrings>(context, AppStrings) ??
        const AppStrings('en');
  }
}

/// [AppStrings] için hafif `LocalizationsDelegate`.
class AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const AppStringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      SettingsService.supportedLanguages.containsKey(locale.languageCode);

  @override
  Future<AppStrings> load(Locale locale) =>
      SynchronousFuture<AppStrings>(AppStrings(locale.languageCode));

  @override
  bool shouldReload(LocalizationsDelegate<AppStrings> old) => false;
}

/// `flutter_localizations` eklenmeden tüm dillerde Material/Cupertino
/// varsayılan (İngilizce) etiketlerini sağlar. Aksi halde TR gibi yerel
/// ayarlarda "delegate desteklenmiyor" debug uyarısı çıkar.
class AppMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const AppMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      SynchronousFuture<MaterialLocalizations>(
        const DefaultMaterialLocalizations(),
      );

  @override
  bool shouldReload(LocalizationsDelegate<MaterialLocalizations> old) => false;
}

class AppCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const AppCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      SynchronousFuture<CupertinoLocalizations>(
        const DefaultCupertinoLocalizations(),
      );

  @override
  bool shouldReload(LocalizationsDelegate<CupertinoLocalizations> old) => false;
}
