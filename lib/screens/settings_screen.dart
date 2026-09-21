import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import '../services/connectivity_service.dart';
import '../services/download_manager.dart';
import '../services/equalizer_service.dart';
import '../services/player_service.dart';
import '../services/repair_bot_service.dart';
import '../services/theme_service.dart';
import '../services/haptic_service.dart';
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
    final repairBot = context.watch<RepairBotService>();
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
            _sectionTitle('Görünüm'),
            _toggleTile(
              title: 'Karanlık Mod',
              subtitle: 'Açık/koyu tema arasında geçiş yap',
              value: isDark,
              onChanged: (_) {
                HapticService.instance.light();
                themeService.toggleMode();
              },
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
                onChanged: (v) { HapticService.instance.light(); themeService.setEmojiEnabled(v); },
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
              onChanged: (_) { HapticService.instance.light(); player.toggleAutoplay(); },
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
              onChanged: (v) { HapticService.instance.light(); player.setCrossfadeEnabled(v); },
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
            _sectionTitle('Destek'),
            _toggleTile(
              title: 'Onarım Botu',
              subtitle: repairBot.isActive
                  ? 'Aktif — arka planda sürekli koruyor'
                  : 'Kapalı — arıza sırasında otomatik düzeltme durdurulur',
              value: repairBot.isActive,
              onChanged: (v) { HapticService.instance.light(); repairBot.setActive(v); },
            ),
            if (repairBot.isActive) _RepairBotStatusPanel(status: repairBot.status),
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
            _sectionTitle('Çevrimdışı Mod'),
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

/// Onarım botunun canlı durumu: son tarama, onarımlar, el değmesi olayları.
class _RepairBotStatusPanel extends StatelessWidget {
  const _RepairBotStatusPanel({required this.status});
  final RepairBotStatus status;

  String _typeLabel(RepairEventType type) => switch (type) {
        RepairEventType.networkTimeout => 'Ağ zaman aşımı',
        RepairEventType.streamError => 'Akış hatası',
        RepairEventType.downloadFailed => 'İndirme hatası',
        RepairEventType.cacheCorrupted => 'Önbellek hatası',
        RepairEventType.proxyFailed => 'Ağ hatası',
        RepairEventType.searchEmpty => 'Boş arama',
        RepairEventType.playlistParseFailed => 'Çalma listesi hatası',
        RepairEventType.artistParseFailed => 'Sanatçı hatası',
      };

  String _time(DateTime t) {
    final local = t.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final lastScan = status.lastScan;
    final events = status.recentEvents;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.troubleshoot,
                  size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Text(
                lastScan == null
                    ? 'Son tarama: henüz yapılmadı'
                    : 'Son tarama: ${_time(lastScan)} (${lastScan.day}/${lastScan.month})',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _stat('Onarım', status.fixedCount),
              const SizedBox(width: 16),
              _stat('El değmesi', status.escalatedCount),
            ],
          ),
          if (status.lastError != null) ...[
            const SizedBox(height: 8),
            Text(
              'Son hata: ${status.lastError}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
          if (events.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...events.take(4).map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${_time(e.timestamp)}  ',
                          style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12)),
                      Expanded(
                        child: Text(
                          '${_typeLabel(e.type)} — ${e.message}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textPrimary, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Henüz arıza bildirilmedi — her şey yolunda.',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _showReportDialog(context),
              icon: const Icon(Icons.support_agent,
                  size: 16, color: AppColors.textSecondary),
              label: const Text('Uzaktan Onarım Raporu',
                  style: TextStyle(
                      color: AppColors.textPrimary, fontSize: 12)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF3A3A3A)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Son arıza raporunu gösterir; e-postayla gönderme veya panoya
  /// kopyalama imkânı sunar (CloudTune@hotmail.com'a uzaktan onarım).
  Future<void> _showReportDialog(BuildContext context) async {
    final report = await RepairBotService.instance.reportForEmail();
    final Map<String, dynamic> data = report ??
        {
          'durum': 'rapor yok',
          'son_tarama': status.lastScan?.toIso8601String(),
          'onarim': status.fixedCount,
          'el_degmesi': status.escalatedCount,
          'son_hata': status.lastError,
          'olaylar': status.recentEvents.take(5).map((e) => e.toJson()).toList(),
        };
    final body = JsonEncoder.withIndent('  ').convert(data);
    final mailTo = Uri(
      scheme: 'mailto',
      path: 'CloudTune@hotmail.com',
      queryParameters: {
        'subject': 'CloudTune Uzaktan Onarım Raporu',
        'body': body,
      },
    ).toString();

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.cardLight,
        title: const Text('Uzaktan Onarım Raporu',
            style: TextStyle(fontSize: 16, color: AppColors.textPrimary)),
        content: SingleChildScrollView(
          child: Text(body,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: body));
              if (dialogCtx.mounted) {
                Navigator.of(dialogCtx).pop();
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Rapor panoya kopyalandı'),
                  duration: Duration(seconds: 2),
                ));
              }
            },
            child: const Text('Panoya Kopyala'),
          ),
          TextButton(
            onPressed: () async {
              if (await canLaunchUrl(Uri.parse(mailTo))) {
                await launchUrl(Uri.parse(mailTo),
                    mode: LaunchMode.externalApplication);
              }
              if (dialogCtx.mounted) {
                Navigator.of(dialogCtx).pop();
              }
            },
            child: const Text('E-posta ile Gönder'),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value',
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
        ],
      );
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