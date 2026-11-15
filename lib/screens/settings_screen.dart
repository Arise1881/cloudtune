import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/link_resolver.dart';
import '../core/player_controller.dart';
import '../core/repair_bot.dart';
import '../core/theme_state.dart';
import '../core/update_service.dart';

/// CloudTune ayarlari.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const List<Color> accentOptions = [
    Color(0xFF1DB954), // Spotify yesili
    Color(0xFF1ED760), // Acik yesil
    Color(0xFF00C853), // Zumrut
    Color(0xFF16A085), // Deniz yesili
    Color(0xFF00BCD4), // Turkuaz
    Color(0xFF2196F3), // Mavi
    Color(0xFF3F51B5), // Indigo
    Color(0xFF7C4DFF), // Mor
    Color(0xFF9C27B0), // Fuşya
    Color(0xFFE91E63), // Pembe
    Color(0xFFF44336), // Kirmizi
    Color(0xFFFF5722), // Kiremit
    Color(0xFFFF9800), // Turuncu
    Color(0xFFFFC107), // Amber
    Color(0xFFCDDC39), // Lime
    Color(0xFF795548), // Kahve
    Color(0xFF607D8B), // Gri mavi
    Color(0xFFE0E0E0), // Beyaz
  ];

  @override
  Widget build(BuildContext context) {
    final library = Library.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          library,
          ThemeState.accent,
          RepairBot.instance,
          UpdateService.instance,
        ]),
        builder: (context, _) {
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

              // ── Gorunum ──
              const _SectionTitle('Görünüm'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Vurgu rengi uygulamanin tamamina uygulanir.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final c in accentOptions)
                      _ColorDot(
                        color: c,
                        selected: ThemeState.accent.value == c,
                        onTap: () => ThemeState.set(c),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Divider(),

              // ── Calma ──
              const _SectionTitle('Çalma'),
              SwitchListTile(
                secondary: const Icon(Icons.radio),
                title: const Text('Sonsuz radyo'),
                subtitle: const Text(
                    'Sarki bitince benzer parcalarla devam eder.'),
                value: library.radioEnabled,
                onChanged: (v) {
                  library.setRadioEnabled(v);
                  PlayerController.instance.setRadioMode(v);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.download_outlined),
                title: const Text('Cihaza doğrudan indir'),
                subtitle: const Text(
                    'Indirilenler Download/CloudTune klasorune kaydedilir.'),
                value: library.downloadToDevice,
                onChanged: library.setDownloadToDevice,
              ),
              const Divider(),

              // ── Baglantilar ──
              const _SectionTitle('Bağlantılar'),
              SwitchListTile(
                secondary: const Icon(Icons.link),
                title: const Text('Desteklenen bağlantılar'),
                subtitle: Text(
                  library.linkHandlerEnabled
                      ? 'YouTube baglantilari uygulama icinde acilir.'
                      : 'Kapali: baglantilar uygulama icinde acilmaz.',
                ),
                value: library.linkHandlerEnabled,
                onChanged: library.setLinkHandlerEnabled,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final host in YoutubeLinkResolver.allowedHosts)
                      Chip(
                        label: Text(host),
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(
                          color: library.linkHandlerEnabled
                              ? ThemeState.accent.value.withValues(alpha: 0.6)
                              : Colors.white24,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(),

              // ── Sistem ──
              const _SectionTitle('Sistem'),
              ListTile(
                leading: _RepairDot(active: RepairBot.instance.active),
                title: const Text('Onarım botu'),
                subtitle: Text(
                  !RepairBot.instance.active
                      ? 'Beklemede'
                      : RepairBot.instance.scanning
                          ? 'Denetleniyor…'
                          : 'Arka planda etkin · ${RepairBot.instance.fixCount} onarim',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('Güncellemeler'),
                subtitle: Text(
                  UpdateService.instance.updateAvailable
                      ? 'Yeni surum: ${UpdateService.instance.latestVersion}'
                      : 'Kurulu surum: ${UpdateService.instance.installedVersion}',
                ),
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
                      color: ThemeState.accent.value),
                  title: const Text('Güncellemeyi indir ve kur'),
                  subtitle: UpdateService.instance.downloading
                      ? LinearProgressIndicator(
                          value: UpdateService.instance.downloadProgress,
                        )
                      : const Text('Yeni surumu simdi yukle'),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    final path =
                        await UpdateService.instance.prepareDownload();
                    if (path == null) return;
                    final msg = await UpdateService.instance.applyUpdate();
                    messenger?.showSnackBar(SnackBar(content: Text(msg)));
                  },
                ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.music_note),
                title: Text('CloudTune'),
                subtitle: Text('YouTube akisli muzik calar · reklamsiz'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _checkUpdates(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await UpdateService.instance.checkForUpdate(force: true);
    if (UpdateService.instance.updateAvailable) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
              'Yeni surum hazir: ${UpdateService.instance.latestVersion}'),
        ),
      );
    } else {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Uygulama güncel.')),
      );
    }
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
          color: ThemeState.accent.value,
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
