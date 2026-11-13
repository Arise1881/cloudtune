import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../services/connectivity_service.dart';
import '../services/download_manager.dart';
import '../services/equalizer_service.dart';
import '../services/player_service.dart';
import '../services/theme_service.dart';
import '../services/haptic_service.dart';
import '../services/music_service.dart';
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
        actions: [
          IconButton(
            tooltip: 'Ana ekrana dön',
            icon: const Icon(Icons.home_outlined),
            onPressed: () => Navigator.of(context)
                .popUntil((r) => r.isFirst),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Görünüm', isDark),
            _toggleTile(
              title: 'Karanlık Mod',
              subtitle: 'Açık/koyu tema arasında geçiş yap',
              value: isDark,
              onChanged: (_) {
                HapticService.instance.light();
                themeService.toggleMode();
              },
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            _sectionTitle('Vurgu Rengi', isDark),
            const SizedBox(height: 4),
            _accentSelector(themeService),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _toggleTile(
                title: 'Emoji Desteği',
                subtitle: 'Emoji ile şarkı isimlerini göster',
                value: themeService.emojiEnabled,
                onChanged: (v) { HapticService.instance.light(); themeService.setEmojiEnabled(v); },
                showDivider: false,
                isDark: isDark,
              ),
            ),
            const SizedBox(height: 8),
            _sectionTitle('Çalma', isDark),
            _dropdownTile(
              title: 'Ses Kalitesi',
              subtitle: 'YouTube Music benzeri dinamik kalite',
              value: player.qualityLabel(),
              items: QualityItems.items,
              onChanged: (label) =>
                  player.setQuality(QualityItems.qualityFor(label)),
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            _toggleTile(
              title: 'Otomatik Devam',
              subtitle: 'Şarkı bitince benzer şarkılar otomatik çalsın',
              value: player.autoplay,
              onChanged: (_) { HapticService.instance.light(); player.toggleAutoplay(); },
              showDivider: false,
              isDark: isDark,
            ),
            const SizedBox(height: 16),
            _sectionTitle('Oynatma Hızı', isDark),
            const SizedBox(height: 4),
            _speedSelector(player),
            const SizedBox(height: 16),
            _toggleTile(
              title: 'Crossfade',
              subtitle: 'Şarkı geçişlerinde yumuşak ses geçişi',
              value: player.crossfadeEnabled,
              onChanged: (v) { HapticService.instance.light(); player.setCrossfadeEnabled(v); },
              isDark: isDark,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Text('Süre: ${player.crossfadeSeconds} sn',
                      style: TextStyle(
                          color: isDark ? AppColors.textSecondary : const Color(0xFF6B6B6B),
                          fontSize: 13)),
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
            _sectionTitle('Depolama', isDark),
            _StorageTile(),
            const SizedBox(height: 16),
            _sectionTitle('Ekolayzer', isDark),
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
              isDark: isDark,
            ),
            const SizedBox(height: 16),
            _sectionTitle('Bağlantı', isDark),
            const _StreamProxyField(),
            const SizedBox(height: 16),
            _sectionTitle('Çevrimdışı Mod', isDark),
            _toggleTile(
              title: 'Çevrimdışı Mod',
              subtitle: 'Sadece indirilen şarkıları çal',
              value: connectivity.forceOffline || connectivity.isOffline,
              onChanged: (v) {
                HapticService.instance.light();
                connectivity.setForceOffline(v);
                connectivity.retry();
              },
              showDivider: false,
              isDark: isDark,
            ),
            const SizedBox(height: 16),
            _sectionTitle('Hakkında', isDark),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.info_outline,
                  color: isDark ? AppColors.textSecondary : const Color(0xFF6B6B6B)),
              title: Text('CloudTune',
                  style: TextStyle(
                      color: isDark ? AppColors.textPrimary : const Color(0xFF111111))),
              subtitle: Text('Sürüm 2.2.69 · build 96',
                  style: TextStyle(
                      color: isDark ? AppColors.textSecondary : const Color(0xFF6B6B6B))),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'CloudTune',
                applicationVersion: '2.2.69 (build 96)',
                applicationIcon: const Icon(Icons.music_note,
                    color: AppColors.accent),
                children: [
                  const SizedBox(height: 8),
                  Text(
                    'YouTube destekli açık kaynak müzik çalar.\n'
                    'Android · iOS · Linux · Windows 11\n'
                    'Gizli Cloudflare proxy + onarım botu ile akış hataları otomatik düzeltilir.',
                    style: TextStyle(
                      color: isDark ? AppColors.textSecondary : Color(0xFF6B6B6B), fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            _toggleTile(
              title: 'Tüm ayarı sıfırla',
              subtitle: 'Tema, kalite ve bağlantı ayarlarını varsayıla döndür',
              value: false,
              onChanged: (_) async {
                await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppColors.card,
                    title: const Text('Ayarları sıfırla'),
                    content: const Text(
                        'Tüm tercihler varsayıla dönecek. İndirilenleriniz silinmez.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Vazgeç'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Sıfırla'),
                      ),
                    ],
                  ),
                );
              },
              showDivider: false,
              isDark: isDark,
            ),
          ],
        ),
      ),
    );
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

  Widget _sectionTitle(String title, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        title,
        style: TextStyle(
          color: isDark ? AppColors.textPrimary : const Color(0xFF111111),
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
    bool isDark = true,
    bool showDivider = true,
  }) {
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            title,
            style: TextStyle(
              color: isDark ? AppColors.textPrimary : const Color(0xFF111111),
            ),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(
              color: isDark ? AppColors.textSecondary : const Color(0xFF6B6B6B),
            ),
          ),
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.accent,
        ),
        if (showDivider)
          Divider(
            height: 1,
            color: isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
          ),
      ],
    );
  }

  Widget _dropdownTile({
    required String title,
    required String subtitle,
    required String value,
    required List<DropdownItem> items,
    required ValueChanged<String> onChanged,
    bool isDark = true,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style: TextStyle(
          color: isDark ? AppColors.textPrimary : const Color(0xFF111111),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: isDark ? AppColors.textSecondary : const Color(0xFF6B6B6B),
        ),
      ),
      trailing: DropdownButton<String>(
        value: value,
        icon: Icon(Icons.arrow_drop_down, color: isDark ? AppColors.textSecondary : const Color(0xFF6B6B6B)),
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(12),
        style: TextStyle(
          color: isDark ? AppColors.textPrimary : const Color(0xFF111111),
          fontSize: 14,
        ),
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
    final isDark = ThemeService.instance.isDark;
    final label = bytes == null
        ? 'Hesaplanıyor…'
        : 'İndirilenler: ${DownloadManager.instance.formatBytes(bytes)}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.sd_storage_outlined,
          color: isDark ? AppColors.textSecondary : const Color(0xFF6B6B6B)),
      title: Text(label,
          style: TextStyle(
              color: isDark ? AppColors.textPrimary : const Color(0xFF111111), fontSize: 14)),
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

/// "Bağlantı" bölümü: yalnızca akış proxy alanı. Açıklama yazısı YOK —
/// başlığın altında yalnızca düzenlenebilir alanı görürsünüz.
class _StreamProxyField extends StatefulWidget {
  const _StreamProxyField();

  @override
  State<_StreamProxyField> createState() => _StreamProxyFieldState();
}

class _StreamProxyFieldState extends State<_StreamProxyField> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: MusicService.streamProxyFieldValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    HapticService.instance.light();
    setState(() => _saving = true);
    final value = _controller.text.trim();
    await MusicService.setStreamProxy(value.isEmpty ? null : value);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ThemeService.instance.isDark;
    return TextField(
      controller: _controller,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        hintText: 'https://…workers.dev',
        prefixIcon: Icon(Icons.link,
            color: isDark ? AppColors.textSecondary : const Color(0xFF6B6B6B)),
        suffixIcon: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                tooltip: 'Bağlantıyı kaydet',
                icon: Icon(Icons.save_outlined,
                    color: isDark ? AppColors.textPrimary : const Color(0xFF111111)),
                onPressed: _save,
              ),
        filled: true,
        fillColor: isDark ? AppColors.card : const Color(0xFFF5F5F5),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
              color: isDark ? AppColors.card : const Color(0xFF9E9E9E), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
      style: TextStyle(
          color: isDark ? AppColors.textPrimary : const Color(0xFF111111), fontSize: 14),
      onSubmitted: (_) => _save(),
    );
  }
}