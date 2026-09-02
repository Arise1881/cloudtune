import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import 'artwork.dart';

/// Şarkı satırı: kapak, başlık, sanatçı, süre + isteğe bağlı sağ aksiyon.
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.selected = false,
    this.trailing,
    this.onMenuTap,
    this.downloadState = const NoDownloadState(),
    this.onDownloadTap,
  });

  final Song song;
  final VoidCallback onTap;
  final bool selected;
  final Widget? trailing;
  final VoidCallback? onMenuTap;

  /// true=indirildi, false=indirme yok, double=ilerleme (0..1)
  final dynamic downloadState;
  final VoidCallback? onDownloadTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Stack(
        children: [
          Artwork(url: song.thumbnailUrl, size: 52),
          if (selected)
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.equalizer, color: AppColors.accentBright),
            ),
        ],
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: selected ? AppColors.accentBright : AppColors.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Flexible(
              child: Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            Text(' • ${song.durationLabel}',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ],
        ),
      ),
      trailing: trailing ?? _buildTrailing(),
      onTap: onTap,
    );
  }

  Widget? _buildTrailing() {
    // İndirme butonu
    if (onDownloadTap != null) {
      if (downloadState is bool && downloadState == true) {
        return IconButton(
          icon: const Icon(Icons.download_done, size: 20, color: AppColors.accent),
          onPressed: onDownloadTap,
          tooltip: 'İndirilenlerde',
        );
      }
      if (downloadState is double) {
        final p = downloadState as double;
        return Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(value: p, strokeWidth: 3),
            ),
            Text('${(p * 100).round()}%',
                style: const TextStyle(fontSize: 8, color: AppColors.textPrimary)),
          ],
        );
      }
      return IconButton(
        icon: const Icon(Icons.download_outlined,
            size: 22, color: AppColors.textSecondary),
        onPressed: onDownloadTap,
        tooltip: 'İndir',
      );
    }

    // ⋮ menüsü varsa onu göster
    if (onMenuTap != null) {
      return IconButton(
        icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
        onPressed: onMenuTap,
      );
    }
    return null;
  }
}

/// İndirme yok (durum yok).
class NoDownloadState {
  const NoDownloadState();
}

/// Bir şarkının indirme durumunu hesaplar: true=indirildi, double=ilerleme,
/// NoDownloadState=yok.
dynamic downloadStateFor(
  Song song,
  LibraryStore library,
  DownloadManager downloader,
) {
  if (library.isDownloaded(song.id)) return true;
  if (downloader.isDownloading(song.id)) {
    return downloader.progress[song.id] ?? 0.0;
  }
  return const NoDownloadState();
}
