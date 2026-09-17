import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/player_service.dart';
import 'artist_screen.dart';
import 'lyrics_screen.dart';
import 'now_playing_screen.dart';

/// Şarkı indirir, sonucu bildirimle gösterir. Ekranlar arası ortak kullanım.
Future<void> downloadWithToast(BuildContext context, Song song) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final error = await DownloadManager.instance.download(song);
  messenger?.showSnackBar(SnackBar(
    content: Text(error == null
        ? '"${song.title}" indirildi'
        : 'İndirme başarısız: $error'),
  ));
}

/// Şarkı satırındaki ⋮ menüsünün açtığı aksiyon sayfası.
Future<void> showSongActions(BuildContext context, Song song) async {
  final library = LibraryStore.instance;
  final downloader = DownloadManager.instance;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: song.thumbnailUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: song.thumbnailUrl,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
                          errorWidget: (_, _, _) => Container(
                              width: 48, height: 48, color: AppColors.background),
                        )
                      : Container(width: 48, height: 48, color: AppColors.background),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          _ActionTile(
            icon: Icons.play_circle_fill,
            label: 'Şimdi çal',
            onTap: () async {
              Navigator.pop(sheetCtx);
              try {
                PlayerService.instance.playQueue([song]);
                if (context.mounted) {
                  Navigator.of(context).push(NowPlayingScreen.route(context));
                }
              } catch (_) {}
            },
          ),
          _ActionTile(
            icon: Icons.queue_music,
            label: 'Sıradaki olarak çal',
            onTap: () {
              Navigator.pop(sheetCtx);
              _insertNext(context, song);
            },
          ),
          _ActionTile(
            icon: Icons.lyrics_outlined,
            label: 'Şarkı sözlerini gör',
            onTap: () {
              Navigator.pop(sheetCtx);
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => LyricsScreen(song: song)));
            },
          ),
          ListenableBuilder(
            listenable: PlayerService.instance,
            builder: (context, _) => _ActionTile(
              icon: Icons.radio,
              label: 'Şarkı radyosu başlat',
              onTap: () {
                Navigator.pop(sheetCtx);
                final player = PlayerService.instance;
                player.playRadio(song);
                if (context.mounted) {
                  Navigator.of(context).push(NowPlayingScreen.route(context));
                }
              },
            ),
          ),
          _ActionTile(
            icon: Icons.person_outline,
            label: 'Sanatçı sayfası',
            onTap: () {
              Navigator.pop(sheetCtx);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ArtistScreen(name: song.artist)));
            },
          ),
          _ActionTile(
            icon: Icons.playlist_add,
            label: 'Çalma listesine ekle',
            onTap: () async {
              await _addToPlaylist(context, song);
            },
          ),
          ListenableBuilder(
            listenable: library,
            builder: (context, _) => _ActionTile(
              icon: library.isFavorite(song.id)
                  ? Icons.favorite
                  : Icons.favorite_border,
              color:
                  library.isFavorite(song.id) ? AppColors.accentBright : null,
              label: library.isFavorite(song.id)
                  ? 'Beğenilerden kaldır'
                  : 'Beğenilere ekle',
              onTap: () {
                library.toggleFavorite(song);
              },
            ),
          ),
          ListenableBuilder(
            listenable: Listenable.merge([library, downloader]),
            builder: (context, _) {
              final downloaded = library.isDownloaded(song.id);
              final downloading = downloader.isDownloading(song.id);
              final progress = downloader.progress[song.id];
              return _ActionTile(
                icon: downloaded
                    ? Icons.download_done
                    : downloading
                        ? Icons.downloading
                        : Icons.download_outlined,
                color: downloaded ? AppColors.accentBright : null,
                label: downloaded
                    ? 'İndirildi — sil'
                    : downloading
                        ? 'İndiriliyor ${(progress != null ? (progress * 100).round() : 0)}%'
                        : 'Çevrimdışı dinlemek için indir',
                enabled: !downloading,
                onTap: () async {
                  if (downloaded) {
                    await downloader.delete(library.downloadedSong(song.id)!);
                  } else {
                    // Bottom sheet açık kalır; indirme ilerlemesi gösterilir.
                    await downloadWithToast(context, song);
                  }
                },
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

}

void _insertNext(BuildContext context, Song song) {
  final player = PlayerService.instance;
  player.playNextUp(song);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('"${song.title}" sıradaki olarak eklendi')));
}

Future<void> _addToPlaylist(BuildContext context, Song song) async {
  final library = LibraryStore.instance;
  final playlists = library.playlists;

  if (playlists.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Önce bir çalma listesi oluşturmalısın')));
    return;
  }

  final selected = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Çalma listesine ekle',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
          ),
          const Divider(color: Colors.white12, height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: playlists.keys
                  .map((name) => ListTile(
                        leading: const Icon(Icons.playlist_play,
                            color: AppColors.textSecondary),
                        title: Text(name,
                            style:
                                const TextStyle(color: AppColors.textPrimary)),
                        onTap: () => Navigator.pop(sheetCtx, name),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );

  if (selected != null) {
    library.addToPlaylist(selected, song);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('"${song.title}" "$selected" listesine eklendi')));
    }
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      leading: Icon(icon, color: color ?? AppColors.textSecondary),
      title: Text(label,
          style:
              const TextStyle(color: AppColors.textPrimary, fontSize: 15)),
      onTap: enabled ? onTap : null,
    );
  }
}
