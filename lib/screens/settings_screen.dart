import 'dart:async';

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/player_controller.dart';
import '../core/repair_bot.dart';
import '../core/settings_service.dart';
import '../core/theme_state.dart';
import '../core/update_service.dart';

/// Uygulama tercihleri: görünüm, çalma, dil ve sistem.
/// Proxy, SponsorBlock, yerel eşitleme ve "diğerleri" araçları yoktur.
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
    final accent = ThemeState.accent.value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
        actions: [
          IconButton(
            tooltip: 'Ana sayfa',
            icon: const Icon(Icons.home_outlined),
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          Library.instance,
          ThemeState.accent,
          SettingsService.instance,
          RepairBot.instance,
          UpdateService.instance,
        ]),
        builder: (context, _) {
          final settings = SettingsService.instance;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _ProfileCard(accent: accent),
              const SizedBox(height: 20),
              _SectionCard(
                icon: Icons.palette_outlined,
                title: 'Görünüm',
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 10),
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
                  const SizedBox(height: 12),
                  _DropdownRow<ThemeMode>(
                    icon: Icons.brightness_6_outlined,
                    title: 'Tema',
                    value: settings.themeMode,
                    items: const [
                      DropdownMenuItem(
                          value: ThemeMode.dark, child: Text('Koyu')),
                      DropdownMenuItem(
                          value: ThemeMode.light, child: Text('Açık')),
                      DropdownMenuItem(
                          value: ThemeMode.system, child: Text('Sistem')),
                    ],
                    onChanged: (value) =>
                        settings.setThemeMode(value ?? ThemeMode.dark),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.nightlight),
                    title: const Text('OLED siyah arka plan'),
                    subtitle: const Text('Koyu temada saf siyah zemin.'),
                    value: settings.oledBlack,
                    onChanged: settings.setOledBlack,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SectionCard(
                icon: Icons.audiotrack,
                title: 'Çalma',
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.radio),
                    title: const Text('Sonsuz radyo'),
                    subtitle:
                        const Text('Şarkı bitince benzer parçalarla devam eder.'),
                    value: Library.instance.radioEnabled,
                    onChanged: (value) {
                      Library.instance.setRadioEnabled(value);
                      PlayerController.instance.setRadioMode(value);
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.download_outlined),
                    title: const Text('Cihaza doğrudan indir'),
                    subtitle: const Text(
                        'İndirilenler Download/CloudTune klasörüne kaydedilir.'),
                    value: Library.instance.downloadToDevice,
                    onChanged: Library.instance.setDownloadToDevice,
                  ),
                  _DropdownRow<String>(
                    icon: Icons.high_quality_outlined,
                    title: 'Ses kalitesi',
                    value: settings.audioQuality,
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
                  SwitchListTile(
                    secondary: const Icon(Icons.graphic_eq),
                    title: const Text('Ekolayzer'),
                    subtitle: const Text('Sesi artır / azalt.'),
                    value: settings.equalizerEnabled,
                    onChanged: (value) async {
                      await settings.setEqualizerEnabled(value);
                      unawaited(PlayerController.instance.refreshEqualizer());
                    },
                  ),
                  if (settings.equalizerEnabled)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (final preset in SettingsService.equalizerPresets)
                            ChoiceChip(
                              label: Text(_eqLabel(preset)),
                              selected: settings.equalizerPreset == preset,
                              onSelected: (selected) async {
                                await settings.setEqualizerPreset(
                                  selected ? preset : 'normal',
                                );
                                unawaited(
                                  PlayerController.instance.refreshEqualizer(),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _SectionCard(
                icon: Icons.language,
                title: 'Dil',
                children: [
                  _DropdownRow<String>(
                    icon: Icons.translate,
                    title: 'Uygulama dili',
                    value: settings.languageCode,
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
                ],
              ),
              const SizedBox(height: 16),
              _SectionCard(
                icon: Icons.build_outlined,
                title: 'Sistem',
                children: [
                  ListTile(
                    leading: _RepairDot(active: RepairBot.instance.active),
                    title: const Text('Onarım botu'),
                    subtitle: Text(_repairStatus()),
                    trailing: TextButton(
                      onPressed: () async {
                        await RepairBot.instance.forceScan();
                        if (context.mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            const SnackBar(
                                content: Text('Onarım taraması tamamlandı.')),
                          );
                        }
                      },
                      child: const Text('Şimdi tara'),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('Onarım kayıtları'),
                    subtitle: const Text('Son onarım olaylarını görüntüle.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showRepairLogs(context),
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
                          color: accent),
                      title: const Text('Güncellemeyi indir ve kur'),
                      subtitle: UpdateService.instance.downloading
                          ? LinearProgressIndicator(
                              value: UpdateService.instance.downloadProgress,
                            )
                          : const Text('Yeni sürümü şimdi yükle'),
                      onTap: () => _installUpdate(context),
                    ),
                  const ListTile(
                    leading: Icon(Icons.music_note),
                    title: Text('CloudTune'),
                    subtitle: Text('YouTube akışlı müzik çalar · reklamsız'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  String _repairStatus() {
    final bot = RepairBot.instance;
    if (!bot.active) return 'Beklemede';
    if (bot.scanning) return 'Denetleniyor…';
    final status = 'Arka planda etkin · ${bot.fixCount} onarım';
    return bot.pendingCount > 0 ? '$status · ${bot.pendingCount} bekliyor' : status;
  }

  Future<void> _showRepairLogs(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Onarım kayıtları'),
          content: SizedBox(
            width: double.maxFinite,
            child: FutureBuilder<String>(
              future: RepairBot.readLogText(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final text = snapshot.data ?? '';
                if (text.isEmpty) return const Text('Kayıt yok.');
                return SingleChildScrollView(child: Text(text));
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await RepairBot.clearLogs();
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
              child: const Text('Temizle'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Kapat'),
            ),
          ],
        );
      },
    );
  }

  String _updateStatus() {
    final update = UpdateService.instance;
    if (update.updateAvailable) return 'Yeni sürüm: ${update.latestVersion}';
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

String _eqLabel(String preset) => switch (preset) {
      'bass' => 'Bas',
      'treble' => 'Tiz',
      'vocal' => 'Vokal',
      'flat' => 'Düz',
      _ => 'Normal',
    };

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent.withValues(alpha: 0.32), const Color(0xFF242424)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: accent.withValues(alpha: 0.25),
            child: Icon(Icons.settings, color: accent),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CloudTune',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                SizedBox(height: 4),
                Text('Müziğini sen yönet · reklamsız, odaklı, hızlı',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;
    return Card(
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(title,
                    style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8)),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
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
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)],
      ),
    );
  }
}
