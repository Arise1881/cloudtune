import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/player_controller.dart';
import '../core/repair_bot.dart';
import '../core/settings_service.dart';
import '../core/theme_state.dart';
import '../core/update_service.dart';
import 'local_sync_page.dart';
import 'other_settings_page.dart';
import 'proxy_settings_page.dart';

/// Application preferences: appearance, playback, language and system tools.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const List<Color> accentOptions = [
    Color(0xFF1DB954),
    Color(0xFF1ED760),
    Color(0xFF00C853),
    Color(0xFF16A085),
    Color(0xFF00BCD4),
    Color(0xFF2196F3),
    Color(0xFF3F51B5),
    Color(0xFF7C4DFF),
    Color(0xFF9C27B0),
    Color(0xFFE91E63),
    Color(0xFFF44336),
    Color(0xFFFF5722),
    Color(0xFFFF9800),
    Color(0xFFFFC107),
    Color(0xFFCDDC39),
    Color(0xFF795548),
    Color(0xFF607D8B),
    Color(0xFFE0E0E0),
  ];

  static const Map<String, String> _qualityLabels = {
    'low': 'Düşük',
    'medium': 'Orta',
    'high': 'Yüksek',
    'veryhigh': 'Çok yüksek',
  };

  @override
  Widget build(BuildContext context) {
    final library = Library.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          library,
          ThemeState.accent,
          SettingsService.instance,
          RepairBot.instance,
          UpdateService.instance,
        ]),
        builder: (context, _) {
          final settings = SettingsService.instance;

          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              ListTile(
                leading: const Icon(Icons.home_outlined),
                title: const Text('Ana Sayfaya Dön'),
                onTap: () =>
                    Navigator.of(context).popUntil((route) => route.isFirst),
              ),
              const Divider(),

              const _SectionTitle('Görünüm'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Vurgu rengi uygulamanın tamamına uygulanır.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final color in accentOptions)
                      _ColorDot(
                        color: color,
                        selected: ThemeState.value == color,
                        onTap: () => ThemeState.set(color),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<ThemeMode>(
                    value: settings.themeMode,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('Koyu'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('Açık'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('Sistem'),
                      ),
                    ],
                    onChanged: (value) =>
                        settings.setThemeMode(value ?? ThemeMode.dark),
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.nightlight),
                title: const Text('OLED siyah arka plan'),
                subtitle: const Text(
                  'Koyu tema + saf siyah zemin (OLED tasarrufu).',
                ),
                value: settings.oledBlack,
                onChanged: (value) => settings.setOledBlack(value),
              ),
              const Divider(),

              const _SectionTitle('Çalma'),
              SwitchListTile(
                secondary: const Icon(Icons.radio),
                title: const Text('Sonsuz radyo'),
                subtitle:
                    const Text('Şarkı bitince benzer parçalarla devam eder.'),
                value: library.radioEnabled,
                onChanged: (value) {
                  library.setRadioEnabled(value);
                  PlayerController.instance.setRadioMode(value);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.download_outlined),
                title: const Text('Cihaza doğrudan indir'),
                subtitle: const Text(
                  'İndirilenler Download/CloudTune klasörüne kaydedilir.',
                ),
                value: library.downloadToDevice,
                onChanged: (value) => library.setDownloadToDevice(value),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: settings.audioQuality,
                    isExpanded: true,
                    items: [
                      for (final quality in SettingsService.audioQualities)
                        DropdownMenuItem(
                          value: quality,
                          child: Text(_qualityLabels[quality] ?? quality),
                        ),
                    ],
                    onChanged: (value) =>
                        settings.setAudioQuality(value ?? 'high'),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Ses kalitesi akış indirme/oyunculuk boyunca kullanılır.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.graphic_eq),
                title: const Text('Ekolayzer'),
                subtitle: const Text('Sesi artır / azalt (uygulama içi).'),
                value: settings.equalizerEnabled,
                onChanged: (value) => settings.setEqualizerEnabled(value),
              ),
              if (settings.equalizerEnabled)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in SettingsService.equalizerPresets)
                        ChoiceChip(
                          label: Text(_eqLabel(preset)),
                          selected: settings.equalizerPreset == preset,
                          onSelected: (selected) =>
                              settings.setEqualizerPreset(
                            selected ? preset : 'normal',
                          ),
                        ),
                    ],
                  ),
                ),
              const Divider(),

              const _SectionTitle('SponsorBlock'),
              SwitchListTile(
                secondary: const Icon(Icons.skip_next),
                title: const Text('Sponsor bölümlerini atla'),
                subtitle: const Text(
                  'Topluluk verisiyle işaretlenen bölümler otomatik geçilir.',
                ),
                value: settings.sponsorBlockEnabled,
                onChanged: (value) => settings.setSponsorBlockEnabled(value),
              ),
              if (settings.sponsorBlockEnabled)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry
                          in SettingsService.sponsorCategoryLabels.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected:
                              settings.sponsorCategories.contains(entry.key),
                          onSelected: (selected) => settings.setSponsorCategory(
                            entry.key,
                            selected,
                          ),
                        ),
                    ],
                  ),
                ),
              const Divider(),

              const _SectionTitle('Bağlantı ve araçlar'),
              ListTile(
                leading: const Icon(Icons.public),
                title: const Text('Proxy ayarları'),
                subtitle: const Text(
                  'Ses akışı için proxy sunucuları, sıralı kullanım, test.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(context, const ProxySettingsPage()),
              ),
              ListTile(
                leading: const Icon(Icons.devices_other),
                title: const Text('Yerel eşitleme'),
                subtitle: const Text(
                  'Aynı ağdaki CloudTune cihazlarını bul, eşleştir, veri aktar.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(context, const LocalSyncPage()),
              ),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Diğer ayarlar'),
                subtitle: const Text(
                  'Sözler, uyku zamanlayıcı, yedekleme, önbellek, kayıtlar.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(context, const OtherSettingsPage()),
              ),
              const Divider(),

              const _SectionTitle('Dil Desteği'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: settings.languageCode,
                    isExpanded: true,
                    items: [
                      for (final entry
                          in SettingsService.supportedLanguages.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) => settings.setLanguage(value ?? 'tr'),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Varsayılan dil: Türkçe. Uygulama yeniden başlatılmadan uygulanır.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const Divider(),

              const _SectionTitle('Sistem'),
              ListTile(
                leading: _RepairDot(active: RepairBot.instance.active),
                title: const Text('Onarım botu'),
                subtitle: Text(_repairStatus()),
              ),
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('Güncellemeler'),
                subtitle: Text(_updateStatus()),
                trailing: UpdateService.instance.checking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: () => _checkUpdates(context),
              ),
              if (UpdateService.instance.updateAvailable)
                ListTile(
                  leading: Icon(Icons.download_for_offline_outlined,
                      color: ThemeState.value),
                  title: const Text('Güncellemeyi indir ve kur'),
                  subtitle: UpdateService.instance.downloading
                      ? LinearProgressIndicator(
                          value: UpdateService.instance.downloadProgress,
                        )
                      : const Text('Yeni sürümü şimdi yükle'),
                  onTap: () => _installUpdate(context),
                ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.music_note),
                title: Text('CloudTune'),
                subtitle: Text('YouTube akışlı müzik çalar · reklamsız'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  String _repairStatus() {
    final bot = RepairBot.instance;
    if (!bot.active) return 'Beklemede';
    if (bot.scanning) return 'Denetleniyor…';
    return 'Arka planda etkin · ${bot.fixCount} onarım';
  }

  String _updateStatus() {
    final update = UpdateService.instance;
    if (update.updateAvailable) {
      return 'Yeni sürüm: ${update.latestVersion}';
    }
    if (update.error != null) return 'Kontrol edilemedi';
    return 'Kurulu sürüm: ${update.installedVersion}';
  }

  Future<void> _checkUpdates(BuildContext context) async {
    await UpdateService.instance.checkForUpdate(force: true);
    if (!context.mounted) return;

    final update = UpdateService.instance;
    final message = update.updateAvailable
        ? 'Yeni sürüm hazır: ${update.latestVersion}'
        : update.error != null
            ? 'Güncelleme kontrolü başarısız.'
            : 'Uygulama güncel.';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _installUpdate(BuildContext context) async {
    final update = UpdateService.instance;
    final path = await update.prepareDownload();
    if (path == null || !context.mounted) return;
    final message = await update.applyUpdate();
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

String _eqLabel(String preset) {
  switch (preset) {
    case 'bass':
      return 'Bas';
    case 'treble':
      return 'Tiz';
    case 'vocal':
      return 'Vokal';
    default:
      return 'Düz';
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        text,
        style: TextStyle(
          color: ThemeState.value,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: 3,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 20, color: Colors.black)
            : null,
      ),
    );
  }
}

class _RepairDot extends StatelessWidget {
  const _RepairDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF1ED760) : Colors.orangeAccent;
    return Container(
      width: 16,
      height: 16,
      margin: const EdgeInsets.only(left: 4, right: 4),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8),
        ],
      ),
    );
  }
}
