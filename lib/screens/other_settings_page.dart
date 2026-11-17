import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/backup_service.dart';
import '../core/lyrics_service.dart';
import '../core/player_controller.dart';
import '../core/repair_bot.dart';
import '../core/settings_service.dart';
import '../core/youtube_service.dart';

/// Musify'in "Diğerlerİ" bölümündeki araçların CloudTune karşılığı.
/// Tüm işlemler yereldir; hiçbir sunucuya veri gönderilmez.
class OtherSettingsPage extends StatefulWidget {
  const OtherSettingsPage({super.key});

  @override
  State<OtherSettingsPage> createState() => _OtherSettingsPageState();
}

class _OtherSettingsPageState extends State<OtherSettingsPage> {
  String? _lyricsDir;
  String? _backupDir;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPaths());
  }

  Future<void> _loadPaths() async {
    final lyrics = await LyricsService.instance.directoryPath();
    final backup = await BackupService.instance.backupDirectoryPath();
    if (!mounted) return;
    setState(() {
      _lyricsDir = lyrics;
      _backupDir = backup;
    });
  }

  Future<void> _createBackup() async {
    setState(() => _busy = true);
    final path = await BackupService.instance.writeBackupFile();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          path == null ? 'Yedek oluşturulamadı.' : 'Yedek kaydedildi.',
        ),
      ),
    );
  }

  Future<void> _restoreBackup() async {
    setState(() => _busy = true);
    final ok = await BackupService.instance.restoreLatest();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(ok ? 'Yedek geri yüklendi.' : 'Yedek bulunamadı.')),
    );
  }

  void _clearCache() {
    BackupService.instance.clearImageCache();
    YoutubeService.instance.clearCache();
    unawaited(LyricsService.instance.clearCache());
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Önbellek temizlendi.')),
    );
  }

  Future<void> _copyLogs() async {
    final text = await RepairBot.readLogText();
    if (text.isEmpty || !mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Kayıtlar kopyalandı.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final player = PlayerController.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Diğer ayarlar')),
      body: ListenableBuilder(
        listenable: Listenable.merge([settings, player]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const _Title('Şarkı sözleri'),
            SwitchListTile(
              secondary: const Icon(Icons.lyrics_outlined),
              title: const Text('Senkronize sözleri göster'),
              subtitle: const Text(
                'Oynatıcıda sözler düğmesi görünür. Yerel .lrc dosyaları okunur.',
              ),
              value: settings.syncedLyrics,
              onChanged: (value) => settings.setSyncedLyrics(value),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Söz dosyası klasörü'),
              subtitle: Text(_lyricsDir ?? 'Hazırlanıyor…'),
              trailing: IconButton(
                tooltip: 'Kopyala',
                icon: const Icon(Icons.copy),
                onPressed: _lyricsDir == null
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: _lyricsDir!),
                      ),
              ),
            ),
            const Divider(),

            const _Title('Uyku zamanlayıcı'),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Süre bitince oynatma durur. Seçim cihazda saklanır.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            if (player.sleepTimerActive)
              ListTile(
                leading: const Icon(Icons.timer),
                title: const Text('Kalan süre'),
                subtitle: Text(_formatDuration(player.sleepRemaining)),
                trailing: TextButton(
                  onPressed: player.cancelSleepTimer,
                  child: const Text('İptal'),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final minutes in const <int>[0, 15, 30, 45, 60, 90])
                    ChoiceChip(
                      label: Text(minutes == 0 ? 'Kapalı' : '$minutes dk'),
                      selected: settings.sleepTimerMinutes == minutes &&
                          (minutes == 0 || player.sleepTimerActive),
                      onSelected: (_) {
                        unawaited(player.setSleepTimer(minutes));
                      },
                    ),
                ],
              ),
            ),
            const Divider(),

            const _Title('Yedekleme'),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('Yedek oluştur'),
              subtitle: Text(_backupDir ?? 'Hazırlanıyor…'),
              trailing: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _busy ? null : _createBackup,
            ),
            ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: const Text('Son yedeği geri yükle'),
              subtitle: const Text('Mevcut veriyle birleştirir.'),
              onTap: _busy ? null : _restoreBackup,
            ),
            const Divider(),

            const _Title('Bakım'),
            SwitchListTile(
              secondary: const Icon(Icons.badge_outlined),
              title: const Text('Ses kalitesi etiketi'),
              subtitle: const Text('Oynatıcıda seçili kaliteyi gösterir.'),
              value: settings.showQualityBadge,
              onChanged: (value) => settings.setShowQualityBadge(value),
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('Önbelleği temizle'),
              subtitle: const Text('Görseller, ses adresleri ve söz önbelleği.'),
              onTap: _clearCache,
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Onarım kayıtlarını kopyala'),
              subtitle: const Text('Yalnızca cihazda tutulan yerel kayıtlar.'),
              onTap: _copyLogs,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration? value) {
  if (value == null) return 'Zamanlayıcı kapalı';
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds kaldı';
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
          color: Colors.white54,
        ),
      ),
    );
  }
}
