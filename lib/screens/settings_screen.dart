import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/library.dart';
import '../core/player_controller.dart';
import '../core/repair_bot.dart';
import '../core/settings_service.dart';
import '../core/theme_state.dart';
import '../core/update_service.dart';
import '../l10n/app_strings.dart';

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

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.settings),
        actions: [
          IconButton(
            tooltip: s.home,
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
              _ProfileCard(s: s),
              const SizedBox(height: 20),
              _SectionCard(
                icon: Icons.palette_outlined,
                title: s.appearance,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Text(
                      s.accentHint,
                      style:
                          TextStyle(color: AppPalette.textSubtle, fontSize: 12),
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
                            onTap: () => settings.setAccentColor(color),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _DropdownRow<ThemeMode>(
                    icon: Icons.brightness_6_outlined,
                    title: s.theme,
                    value: settings.themeMode,
                    items: [
                      DropdownMenuItem(
                          value: ThemeMode.dark, child: Text(s.themeDark)),
                      DropdownMenuItem(
                          value: ThemeMode.light, child: Text(s.themeLight)),
                      DropdownMenuItem(
                          value: ThemeMode.system, child: Text(s.themeSystem)),
                    ],
                    onChanged: (value) =>
                        settings.setThemeMode(value ?? ThemeMode.dark),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.nightlight),
                    title: Text(s.oledBlack),
                    subtitle: Text(s.oledHint),
                    value: settings.oledBlack,
                    onChanged: settings.setOledBlack,
                  ),
                  _DropdownRow<String>(
                    icon: Icons.app_shortcut_outlined,
                    title: s.appIcon,
                    subtitle: s.appIconHint,
                    value: settings.appIcon,
                    items: [
                      for (final entry in SettingsService.supportedAppIcons.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      final ok = await settings.setAppIcon(value);
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'Uygulama simgesi bu cihazda değiştirilemedi.')),
                        );
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SectionCard(
                icon: Icons.audiotrack,
                title: s.playback,
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.radio),
                    title: Text(s.endlessRadio),
                    subtitle: Text(s.endlessRadioHint),
                    value: Library.instance.radioEnabled,
                    onChanged: (value) {
                      Library.instance.setRadioEnabled(value);
                      PlayerController.instance.setRadioMode(value);
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.download_outlined),
                    title: Text(s.downloadToDevice),
                    subtitle: Text(s.downloadToDeviceHint),
                    value: Library.instance.downloadToDevice,
                    onChanged: Library.instance.setDownloadToDevice,
                  ),
                  _DropdownRow<String>(
                    icon: Icons.high_quality_outlined,
                    title: s.audioQuality,
                    value: settings.audioQuality,
                    items: [
                      for (final quality in SettingsService.audioQualities)
                        DropdownMenuItem(
                          value: quality,
                          child: Text(_qualityLabel(quality, s)),
                        ),
                    ],
                    onChanged: (value) async {
                      final quality = value ?? 'high';
                      await settings.setAudioQuality(quality);
                      // Motorun aktif URI'si ve medya oturumu bayat kalmasın.
                      await PlayerController.instance.setQuality(quality);
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.graphic_eq),
                    title: Text(s.equalizer),
                    subtitle: Text(s.equalizerHint),
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
                              label: Text(_eqLabel(preset, s)),
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
                title: s.language,
                children: [
                  _DropdownRow<String>(
                    icon: Icons.translate,
                    title: s.appLanguage,
                    subtitle: _languageSubtitle(settings.languageCode),
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
                title: s.system,
                children: [
                  ListTile(
                    leading: _RepairDot(active: RepairBot.instance.active),
                    title: Text(s.repairBot),
                    subtitle: Text(_repairStatus(s)),
                    trailing: TextButton(
                      onPressed: () async {
                        await RepairBot.instance.forceScan();
                        if (context.mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            SnackBar(content: Text(s.scanDone)),
                          );
                        }
                      },
                      child: Text(s.scanNow),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: RepairBot.instance.fullRepairRunning
                            ? null
                            : () => unawaited(_runFullRepair(context)),
                        icon: const Icon(Icons.healing_outlined),
                        label: Text(s.fullRepair),
                      ),
                    ),
                  ),
                  if (RepairBot.instance.fullRepairRunning)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.fullRepairRunning,
                              style: const TextStyle(fontSize: 12)),
                          const SizedBox(height: 6),
                          const LinearProgressIndicator(),
                        ],
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(s.repairLogs),
                    subtitle: Text(s.repairLogsHint),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showRepairLogs(context, s),
                  ),
                  ListTile(
                    leading: const Icon(Icons.history_toggle_off),
                    title: Text(s.clearListeningHistory),
                    subtitle: Text(s.clearListeningHistoryHint),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _confirmClearListeningHistory(context, s),
                  ),
                  ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: Text(s.updates),
                    subtitle: Text(_updateStatus(s)),
                    trailing: UpdateService.instance.checking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: () => _checkUpdates(context, s),
                  ),
                  if (UpdateService.instance.updateAvailable)
                    ListTile(
                      leading: Icon(Icons.download_for_offline_outlined,
                          color: ThemeState.value),
                      title: Text(s.updateInstall),
                      subtitle: UpdateService.instance.downloading
                          ? LinearProgressIndicator(
                              value: UpdateService.instance.downloadProgress,
                            )
                          : Text(s.updateInstallHint),
                      onTap: () => _installUpdate(context),
                    ),
                  ListTile(
                    leading: const Icon(Icons.music_note),
                    title: const Text('CloudTune'),
                    subtitle: Text(s.appTagline),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  String _repairStatus(AppStrings s) {
    final bot = RepairBot.instance;
    if (!bot.active) return s.repairIdle;
    if (bot.scanning) return s.repairScanning;
    final status = s.repairBackground(bot.fixCount);
    return bot.pendingCount > 0
        ? '$status · ${s.repairPending(bot.pendingCount)}'
        : status;
  }

  /// Tam onarım bitince aşama aşama sonucu gösterir.
  Future<void> _runFullRepair(BuildContext context) async {
    final report = await RepairBot.instance.runFullRepair();
    if (!context.mounted) return;
    await _showFullRepairResult(context, report);
  }

  Future<void> _showFullRepairResult(
      BuildContext context, RepairReport report) async {
    final s = AppStrings.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(s.fullRepairTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(report.hasRemaining
                    ? s.resultRemaining(report.remainingCount)
                    : s.resultClean),
                const SizedBox(height: 4),
                Text(s.resultFixed(report.fixedCount)),
                const SizedBox(height: 12),
                for (final stage in report.stages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(_stageSummary(s, stage)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(s.close),
            ),
          ],
        );
      },
    );
  }

  String _stageSummary(AppStrings s, RepairStageResult stage) {
    final name = switch (stage.name) {
      'playback' => s.stagePlayback,
      'downloads' => s.stageDownloads,
      'pending' => s.stagePending,
      _ => stage.name,
    };
    final status = switch (stage.status) {
      RepairStageStatus.success => s.statusSuccess,
      RepairStageStatus.problem => s.statusProblem,
      RepairStageStatus.skipped => s.statusSkipped,
    };
    return s.stageSummary(name, status, stage.fixed, stage.remaining);
  }

  Future<void> _showRepairLogs(BuildContext context, AppStrings s) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(s.repairLogs),
          content: SizedBox(
            width: double.maxFinite,
            child: FutureBuilder<String>(
              future: RepairBot.readLogText(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final text = snapshot.data ?? '';
                if (text.isEmpty) return Text(s.noLogs);
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
              child: Text(s.clear),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(s.close),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmClearListeningHistory(
      BuildContext context, AppStrings s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.clearListeningHistory),
        content: Text(s.clearListeningHistoryHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(s.close),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(s.clear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await Library.instance.clearHistory();
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(s.listeningHistoryCleared)),
    );
  }

  String _updateStatus(AppStrings s) {
    final update = UpdateService.instance;
    if (update.updateAvailable) return s.updateNewVersion(update.latestVersion);
    if (update.error != null) return s.updateCheckFailed;
    return s.updateInstalled(update.installedVersion);
  }

  Future<void> _checkUpdates(BuildContext context, AppStrings s) async {
    await UpdateService.instance.checkForUpdate(force: true);
    if (!context.mounted) return;
    final update = UpdateService.instance;
    final message = update.updateAvailable
        ? s.updateReady(update.latestVersion)
        : update.error != null
            ? s.updateCheckError
            : s.updateCurrent;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _installUpdate(BuildContext context) async {
    final update = UpdateService.instance;
    if (update.platform == UpdatePlatform.windows) {
      final message = await update.applyUpdate();
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }
    final path = await update.prepareDownload();
    if (path == null || !context.mounted) return;
    final message = await update.applyUpdate();
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

String _qualityLabel(String quality, AppStrings s) => switch (quality) {
      'low' => s.qualityLow,
      'medium' => s.qualityMedium,
      'high' => s.qualityHigh,
      'veryhigh' => s.qualityVeryHigh,
      _ => quality,
    };

/// Seçili dil her zaman görünür olsun. Çeviri kapsamı yalnızca Ayarlar
/// ekranı olduğu için, Türkçe/İngilizce dışındaki dillerde fallback'i açıkça
/// belirtiriz; kullanıcı seçimin "aktif olmadığını" sanmaz.
String _languageSubtitle(String code) {
  final name = SettingsService.supportedLanguages[code] ?? code;
  if (code == 'tr' || code == 'en') return '$name · $code';
  return '$name · $code · English UI';
}

String _eqLabel(String preset, AppStrings s) => switch (preset) {
      'bass' => s.eqBass,
      'treble' => s.eqTreble,
      'vocal' => s.eqVocal,
      'flat' => s.eqFlat,
      _ => s.eqNormal,
    };

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.s});

  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    // Accent burada okunur; outer build'de yakalanırsa profil kartı eski
    // renkte kalıyordu.
    final accent = ThemeState.value;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent.withValues(alpha: 0.32), AppPalette.card],
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CloudTune',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                SizedBox(height: 4),
                Text(s.profileTagline,
                    style:
                        TextStyle(color: AppPalette.textMuted, fontSize: 12)),
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
      color: AppPalette.cardAlt,
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
    this.subtitle,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
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
            color: selected ? AppPalette.text : Colors.transparent,
            width: 3,
          ),
        ),
        child: selected
            ? Icon(Icons.check, size: 20, color: AppPalette.text)
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
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)
        ],
      ),
    );
  }
}
