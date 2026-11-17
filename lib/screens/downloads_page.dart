import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/download_service.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';

/// Cihazdaki indirmeler, başarısız indirmeler ve devam eden indirmeler.
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.accent.value;

    return Scaffold(
      backgroundColor: AppPalette.scaffold,
      appBar: AppBar(
        title: const Text('İndirilenler'),
        backgroundColor: AppPalette.surface,
        foregroundColor: AppPalette.text,
      ),
      body: ListenableBuilder(
        listenable: DownloadService.instance,
        builder: (context, _) {
          final service = DownloadService.instance;
          final saved = service.savedTracks;
          final failures = service.failureIds;
          final active = service.downloadProgress.entries
              .where((entry) => entry.value >= 0 && entry.value < 1)
              .toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _sectionHeader(
                'Cihazdaki müzikler',
                accent,
                action: saved.isEmpty
                    ? null
                    : TextButton.icon(
                        onPressed: () => PlayerController.instance.playQueue(
                          saved,
                          0,
                          radio: false,
                        ),
                        icon: Icon(Icons.play_arrow, size: 18, color: accent),
                        label: Text(
                          'Tümünü çal',
                          style: TextStyle(color: accent),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: accent,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
              ),
              const SizedBox(height: 8),
              if (saved.isEmpty)
                _empty('Cihazda kayıtlı müzik yok.', Icons.download_outlined)
              else
                for (var i = 0; i < saved.length; i++)
                  _savedTile(saved[i], saved, i, accent, context, service),
              const SizedBox(height: 24),
              if (failures.isNotEmpty) ...[
                _sectionHeader(
                  'Başarısız indirmeler (${failures.length})',
                  accent,
                ),
                const SizedBox(height: 8),
                for (final id in failures) _failureTile(service, id, accent),
              ] else
                _empty('Başarısız indirme yok.', Icons.check_circle_outline),
              if (active.isNotEmpty) ...[
                const SizedBox(height: 24),
                _sectionHeader(
                  'Devam eden indirmeler (${active.length})',
                  accent,
                ),
                const SizedBox(height: 8),
                for (final entry in active)
                  _activeTile(entry.key, entry.value, accent),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(String title, Color accent, {Widget? action}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        if (action != null) action,
      ],
    );
  }

  Widget _savedTile(
    Track track,
    List<Track> queue,
    int index,
    Color accent,
    BuildContext context,
    DownloadService service,
  ) {
    return Card(
      color: AppPalette.cardAlt,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: _thumb(track, accent),
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: AppPalette.textSubtle, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Çal',
              icon: Icon(Icons.play_arrow, color: accent),
              onPressed: () => PlayerController.instance.playQueue(
                queue,
                index,
                radio: false,
              ),
            ),
            IconButton(
              tooltip: 'İndirmeyi sil',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _delete(context, service, track.id),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failureTile(DownloadService service, String id, Color accent) {
    final reason = service.failureReason(id) ?? 'Bilinmeyen hata';
    return Card(
      color: AppPalette.cardAlt,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.red.withValues(alpha: 0.14),
          child: const Icon(Icons.error_outline, color: Colors.redAccent),
        ),
        title: Text(
          _titleFor(id),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          reason,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.redAccent, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Yeniden dene',
              icon: Icon(Icons.refresh, color: accent),
              onPressed: () => service.retryDownload(id),
            ),
            IconButton(
              tooltip: 'Listeden kaldır',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => service.forgetFailure(id),
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeTile(String id, double value, Color accent) {
    final progress = value.clamp(0.0, 1.0);
    return Card(
      color: AppPalette.cardAlt,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.downloading, size: 18, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _titleFor(id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(progress * 100).round()}%',
                  style: TextStyle(color: accent, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: AppPalette.divider,
              color: accent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb(Track track, Color accent) {
    Widget fallback() => Container(
          width: 48,
          height: 48,
          color: AppPalette.cardRaised,
          child: Icon(Icons.music_note, color: accent, size: 24),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: track.thumb,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback(),
        errorWidget: (_, __, ___) => fallback(),
      ),
    );
  }

  Widget _empty(String message, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        children: [
          Icon(icon, color: AppPalette.iconFaint, size: 28),
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(color: AppPalette.textFaint, fontSize: 13),
          ),
        ],
      ),
    );
  }

  String _titleFor(String id) {
    final tracks = PlayerController.instance.tracks;
    final index = tracks.indexWhere((track) => track.id == id);
    return index >= 0 ? tracks[index].title : id;
  }

  Future<void> _delete(
    BuildContext context,
    DownloadService service,
    String id,
  ) async {
    await service.deleteDownload(id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('İndirme silindi.')),
    );
  }
}
