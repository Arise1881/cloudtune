import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../services/connectivity_service.dart';
import '../services/download_manager.dart';
import '../services/equalizer_service.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';
import '../services/theme_service.dart';
import 'equalizer_screen.dart';

/// Ayarlar ekranı: tema, vurgu rengi, kalite, ekolayzer, otomatik çalma.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final themeService = context.watch<ThemeService>();
    final player = context.watch<PlayerService>();
    final eq = context.watch<EqualizerService>();
    final connectivity = context.watch<ConnectivityService>();
    final isDark = themeService.isDark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
        backgroundColor: themeService.accent,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Görünüm'),
            _toggleTile(
              title: 'Karanlık Mod',
              subtitle: 'Açık/koyu tema arasında geçiş yap',
              value: isDark,
              onChanged: (_) => themeService.toggleMode(),
            ),
            const SizedBox(height: 8),
            _sectionTitle('Vurgu Rengi'),
            const SizedBox(height: 4),
            _accentSelector(themeService),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _toggleTile(
                title: 'Emoji Desteği',
                subtitle: 'Emoji ile şarkı isimlerini göster',
                value: themeService.emojiEnabled,
                onChanged: themeService.setEmojiEnabled,
                showDivider: false,
              ),
            ),
            const SizedBox(height: 8),
            _sectionTitle('Çalma'),
            _dropdownTile(
              title: 'Ses Kalitesi',
              subtitle: 'YouTube Music benzeri dinamik kalite',
              value: player.qualityLabel(),
              items: QualityItems.items,
              onChanged: (label) =>
                  player.setQuality(QualityItems.qualityFor(label)),
            ),
            const SizedBox(height: 8),
            _toggleTile(
              title: 'Otomatik Devam',
              subtitle: 'Şarkı bitince benzer şarkılar otomatik çalsın',
              value: player.autoplay,
              onChanged: (_) => player.toggleAutoplay(),
              showDivider: false,
            ),
            const SizedBox(height: 16),
            _sectionTitle('Oynatma Hızı'),
            const SizedBox(height: 4),
            _speedSelector(player),
            const SizedBox(height: 16),
            _toggleTile(
              title: 'Crossfade',
              subtitle: 'Şarkı geçişlerinde yumuşak ses geçişi',
              value: player.crossfadeEnabled,
              onChanged: player.setCrossfadeEnabled,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Text('Süre: ${player.crossfadeSeconds} sn',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                  Expanded(
                    child: Slider(
                      min: 2,
                      max: 10,
                      divisions: 8,
                      value: player.crossfadeSeconds.toDouble(),
                      label: '${player.crossfadeSeconds} sn',
                      activeColor: AppColors.accent,
                      onChanged: (v) =>
                          player.setCrossfadeSeconds(v.round()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _sectionTitle('Depolama'),
            _StorageTile(),
            const SizedBox(height: 16),
            _sectionTitle('Ekolayzer'),
            _dropdownTile(
              title: 'Hazır Ayar',
              subtitle: 'Ses karakterini değiştir',
              value: eq.presetLabelFor(eq.preset),
              items: EqPreset.values
                  .map((p) => DropdownItem(eq.presetLabelFor(p), p.index))
                  .toList(),
              onChanged: (label) {
                eq.setPreset(EqPreset.values.firstWhere(
                    (p) => eq.presetLabelFor(p) == label));
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const EqualizerScreen()));
              },
            ),
            const SizedBox(height: 16),
            _sectionTitle('Bağlantı'),
            ValueListenableBuilder<String?>(
              valueListenable: MusicService.proxyNotifier,
              builder: (context, proxy, _) => _proxyTile(context, proxy),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _toggleTile(
                title: 'Çevrimdışı Mod',
                subtitle: 'Ağ kontrolünü yok say, yalnızca indirilenleri oynat',
                value: connectivity.forceOffline || connectivity.isOffline,
                onChanged: (v) {
                  connectivity.setForceOffline(v);
                  connectivity.retry();
                },
                showDivider: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Akış proxy'si (Cloudflare Workers) ayar satırı.
  Widget _proxyTile(BuildContext context, String? proxy) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.cloud_outlined, color: AppColors.textSecondary),
      title: const Text(
        'Akış Proxy URL',
        style: TextStyle(color: AppColors.textPrimary),
      ),
      subtitle: Text(
        proxy ??
            'Kapalı — ücretsiz Cloudflare Workers proxy adresi girerek '
                'googlevideo engelini aş',
        style: const TextStyle(color: AppColors.textSecondary),
      ),
      trailing: proxy != null
          ? IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: AppColors.textSecondary),
              tooltip: 'Proxy\'yi kaldır',
              onPressed: () => MusicService.setStreamProxy(null),
            )
          : const Icon(Icons.edit, color: AppColors.textSecondary),
      onTap: () => _editProxyDialog(context, proxy),
    );
  }

  Future<void> _editProxyDialog(BuildContext context, String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Akış Proxy URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ücretsiz Cloudflare Workers proxy adresin. Boş bırakırsan '
              'kapatılır.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autocorrect: false,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                hintText: 'https://melody-stream.xxxx.workers.dev',
                hintStyle: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    if (result != null) await MusicService.setStreamProxy(result);
  }

  Widget _speedSelector(PlayerService player) {    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    return Wrap(
      spacing: 8,
      children: speeds.map((s) {
        final selected = (player.speed - s).abs() < 0.01;
        return ChoiceChip(
          label: Text(s == 1.0 ? '1x' : '${s}x'),
          selected: selected,
          showCheckmark: false,
          selectedColor: AppColors.accent,
          backgroundColor: AppColors.card,
          labelStyle: TextStyle(
            color: selected ? Colors.white : AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
          side: BorderSide.none,
          onSelected: (_) => player.setSpeed(s),
        );
      }).toList(),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _accentSelector(ThemeService themeService) {
    return Row(
      children: List.generate(ThemeService.accentColors.length, (i) {
        final color = ThemeService.accentColors[i];
        final selected = themeService.accentIndex == i;
        return Padding(
          padding: const EdgeInsets.only(right: 12),
          child: GestureDetector(
            onTap: () => themeService.setAccentIndex(i),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Colors.white : Colors.transparent,
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: .5),
                    blurRadius: selected ? 8 : 2,
                    spreadRadius: selected ? 1 : 0,
                  ),
                ],
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white, size: 20)
                  : null,
            ),
          ),
        );
      }),
    );
  }

  Widget _toggleTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool showDivider = true,
  }) {
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            title,
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          subtitle: Text(
            subtitle,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.accent,
        ),
        if (showDivider)
          const Divider(height: 1, color: Color(0x1FFFFFFF)),
      ],
    );
  }

  Widget _dropdownTile({
    required String title,
    required String subtitle,
    required String value,
    required List<DropdownItem> items,
    required ValueChanged<String> onChanged,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style: const TextStyle(color: AppColors.textPrimary),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppColors.textSecondary),
      ),
      trailing: DropdownButton<String>(
        value: value,
        icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(12),
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
        items: items
            .map((e) => DropdownMenuItem(value: e.label, child: Text(e.label)))
            .toList(),
        onChanged: (v) => onChanged(v ?? value),
      ),
    );
  }
}

class _StorageTile extends StatefulWidget {
  @override
  State<_StorageTile> createState() => _StorageTileState();
}

class _StorageTileState extends State<_StorageTile> {
  int? _bytes;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  Future<void> _recompute() async {
    final b = await DownloadManager.instance.totalSizeBytes();
    if (mounted) setState(() => _bytes = b);
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('İndirilenleri Sil'),
        content: const Text(
            'Tüm indirilen şarkılar ve kapak görselleri cihazdan silinecek. Bu işlem geri alınamaz.'),
        backgroundColor: AppColors.card,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    await DownloadManager.instance.clearAll();
    await _recompute();
    if (mounted) setState(() => _clearing = false);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final label = bytes == null
        ? 'Hesaplanıyor…'
        : 'İndirilenler: ${DownloadManager.instance.formatBytes(bytes)}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.sd_storage_outlined, color: AppColors.textSecondary),
      title: Text(label,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14)),
      trailing: TextButton(
        onPressed: _clearing ? null : _clearAll,
        child: _clearing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Temizle'),
      ),
    );
  }
}

class DropdownItem {
  final String label;
  final int index;
  const DropdownItem(this.label, this.index);
}


/// Ses kalitesi seçenekleri (etiketsiz değer eşlemesi).
class QualityItems {
  static const items = [
    DropdownItem('Otomatik', 0),
    DropdownItem('Ultra (lossless)', 1),
    DropdownItem('Yüksek (320kbps)', 2),
    DropdownItem('Orta (128kbps)', 3),
    DropdownItem('Düşük (48kbps)', 4),
  ];

  static AudioQuality qualityFor(String label) => switch (label) {
        'Ultra (lossless)' => AudioQuality.ultra,
        'Yüksek (320kbps)' => AudioQuality.high,
        'Orta (128kbps)' => AudioQuality.medium,
        'Düşük (48kbps)' => AudioQuality.low,
        _ => AudioQuality.auto,
      };
}