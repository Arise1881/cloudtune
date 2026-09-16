import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/player_service.dart';
import '../widgets/artwork.dart';
import 'now_playing_screen.dart';
import 'playlist_screen.dart';

/// Kitaplık: İndirilenler / Beğeniler / Çalma Listeleri sekmeleri.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  /// Root içindeki sekmeye geçmek için kullanılır (Ana sayfa hızlı erişimi).
  static void openTab(BuildContext context, int tab) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LibraryScreen()),
    );
  }

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                const Text('Kitaplığın',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w800)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.settings_outlined,
                      color: AppColors.textSecondary),
                  onPressed: () =>
                      Navigator.of(context).pushNamed('/settings'),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabs,
            indicatorColor: AppColors.accentBright,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            dividerColor: Colors.transparent,
            tabs: const [
              Tab(icon: Icon(Icons.download_outlined), text: 'İndirilenler'),
              Tab(icon: Icon(Icons.favorite_outline), text: 'Beğeniler'),
              Tab(icon: Icon(Icons.queue_music), text: 'Çalma Listeleri'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _DownloadsTab(),
                _FavoritesTab(),
                _PlaylistsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ortak parçalar
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.text, this.hint});

  final IconData icon;
  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: AppColors.textSecondary),
          const SizedBox(height: 14),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 15)),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

String? _localArt(String songId) {
  try {
    final f = File(DownloadManager.instance.artPath(songId));
    return f.existsSync() ? f.path : null;
  } catch (_) {
    return null;
  }
}

Widget _listHeaderTile(
    BuildContext context, List<Song> songs, String title, String subtitle,
    {required IconData icon, required List<Color> colors}) {
  final player = context.read<PlayerService>();
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(6),
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 30),
            onPressed: () async {
              try {
                player.playQueue(songs);
                if (context.mounted) {
                  Navigator.of(context).push(NowPlayingScreen.route(context));
                }
              } catch (_) {}
            },
          ),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
            Text(subtitle,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
          ],
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// İndirilenler
// ---------------------------------------------------------------------------

class _DownloadsTab extends StatelessWidget {
  const _DownloadsTab();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final downloader = context.watch<DownloadManager>();
    final downloads = library.downloads;

    return Column(
      children: [
        // Devam eden indirmeler.
        for (final entry in downloader.progress.entries)
          if (downloader.isDownloading(entry.key))
            ListTile(
              dense: true,
              leading: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('İndiriliyor… ${(entry.value * 100).round()}%',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13)),
            ),
        Expanded(
          child: downloads.isEmpty && downloader.progress.isEmpty
              ? _EmptyState(
                  icon: Icons.download_outlined,
                  text: 'İndirilen şarkı yok',
                  hint: 'Şarkıdaki indir simgesiyle çevrimdışı dinle')
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: downloads.length + 1,
                  separatorBuilder: (_, _) => const Divider(
                      indent: 16, endIndent: 16, height: 1, thickness: .5),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return _listHeaderTile(context, downloads, 'Tümünü çal',
                          '${downloads.length} şarkı çevrimdışı hazır',
                          icon: Icons.play_arrow_rounded,
                          colors: const [Color(0xFF1F3D2B), Color(0xFF2E5D41)]);
                    }
                    final song = downloads[i - 1];
                    final player = context.read<PlayerService>();
                    return ListTile(
                      leading: Artwork(
                          localPath: _localArt(song.id),
                          url: song.thumbnailUrl,
                          size: 50),
                      title: Text(song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textPrimary)),
                      subtitle: Text(song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textSecondary)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close,
                            color: AppColors.textSecondary, size: 20),
                        tooltip: 'İndirmeyi sil',
                        onPressed: () => downloader.delete(song),
                      ),
                      onTap: () async {
                        try {
                          await player.playSmart(downloads, i - 1);
                          if (context.mounted) {
                            Navigator.of(context)
                                .push(NowPlayingScreen.route(context));
                          }
                        } catch (_) {}
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Beğeniler
// ---------------------------------------------------------------------------

class _FavoritesTab extends StatelessWidget {
  const _FavoritesTab();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final favorites = library.favorites;

    if (favorites.isEmpty) {
      return _EmptyState(
        icon: Icons.favorite_border,
        text: 'Favori şarkın yok',
        hint: 'Şarkıdaki kalp simgesiyle beğen',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: favorites.length + 1,
      separatorBuilder: (_, _) =>
          const Divider(indent: 16, endIndent: 16, height: 1, thickness: .5),
      itemBuilder: (context, i) {
        if (i == 0) {
          return _listHeaderTile(context, favorites, 'Beğenilen Şarkılar',
              '${favorites.length} şarkı',
              icon: Icons.favorite,
              colors: const [Color(0xFF4C1B80), Color(0xFF9E7ACF)]);
        }
        final song = favorites[i - 1];
        final player = context.read<PlayerService>();
        return ListTile(
          leading: Artwork(url: song.thumbnailUrl, size: 50),
          title: Text(song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textPrimary)),
          subtitle: Text(song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textSecondary)),
          trailing: IconButton(
            icon: const Icon(Icons.favorite,
                color: AppColors.accentBright, size: 20),
            onPressed: () => library.toggleFavorite(song),
          ),
          onTap: () async {
            try {
              await player.playSmart(favorites, i - 1);
              if (context.mounted) {
                Navigator.of(context).push(NowPlayingScreen.route(context));
              }
            } catch (_) {}
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Çalma listeleri
// ---------------------------------------------------------------------------

class _PlaylistsTab extends StatefulWidget {
  const _PlaylistsTab();

  @override
  State<_PlaylistsTab> createState() => __PlaylistsTabState();
}

class __PlaylistsTabState extends State<_PlaylistsTab> {
  Future<void> _createDialog() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Yeni çalma listesi',
            style: TextStyle(color: AppColors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(hintText: 'Adı girin'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Oluştur')),
        ],
      ),
    );
    if (ok == true) {
      LibraryStore.instance.createPlaylist(controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final playlists = library.playlists;

    if (playlists.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _EmptyState(
              icon: Icons.library_music_outlined,
              text: 'Henüz çalma listesi yok'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Oluştur'),
            onPressed: _createDialog,
          ),
        ],
      );
    }

    return Stack(
      children: [
        ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: playlists.length + 1,
          itemBuilder: (context, i) {
            if (i == playlists.length) return const SizedBox(height: 64);
            final entry = playlists.entries.elementAt(i);
            return ListTile(
              leading: Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: AppColors.cardLight,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: entry.value.isNotEmpty
                    ? Artwork(url: entry.value.first.thumbnailUrl, size: 50, radius: 6)
                    : const Icon(Icons.music_note,
                        color: AppColors.textSecondary),
              ),
              title: Text(entry.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textPrimary)),
              subtitle: Text('${entry.value.length} şarkı',
                  style: const TextStyle(color: AppColors.textSecondary)),
              onLongPress: () => _showPlaylistActions(entry.key),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    PlaylistScreen(title: entry.key, songs: entry.value, playlistName: entry.key),
              )),
            );
          },
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.black,
            icon: const Icon(Icons.add, size: 20),
            label: const Text('Liste', style: TextStyle(fontWeight: FontWeight.w700)),
            onPressed: _createDialog,
          ),
        ),
      ],
    );
  }

  Future<void> _showPlaylistActions(String name) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined,
                  color: AppColors.textSecondary),
              title: const Text('Yeniden Adlandır',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: AppColors.textSecondary),
              title: const Text('Sil',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'rename') {
      await _renameDialog(name);
    } else if (action == 'delete') {
      await _confirmDelete(name);
    }
  }

  Future<void> _renameDialog(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Yeniden Adlandır',
            style: TextStyle(color: AppColors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(hintText: 'Adı girin'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Kaydet')),
        ],
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      final success =
          context.read<LibraryStore>().renamePlaylist(oldName, controller.text);
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bu isim kullanılıyor')),
        );
      }
    }
  }

  Future<void> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text('"$name" silinsin mi?',
            style: const TextStyle(color: AppColors.textPrimary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      LibraryStore.instance.deletePlaylist(name);
    }
  }
}
