import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';

/// Kullanıcının cihazında sakladığı yerel çalma listeleri.
class MyPlaylistsPage extends StatelessWidget {
  const MyPlaylistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;

    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      appBar: AppBar(
        title: const Text('Çalma Listelerim'),
        backgroundColor: const Color(0xFF181818),
        actions: [
          IconButton(
            tooltip: 'Ana sayfa',
            icon: const Icon(Icons.home_outlined),
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Library.instance,
        builder: (context, _) {
          final names = Library.instance.playlistNames;
          if (names.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.playlist_play, size: 72, color: accent),
                  const SizedBox(height: 16),
                  const Text(
                    'Henüz çalma listesi yok.',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            itemCount: names.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final name = names[index];
              final tracks = Library.instance.getPlaylist(name);
              return _PlaylistCard(
                name: name,
                trackCount: tracks.length,
                accent: accent,
                onPlay: () => _playPlaylist(context, name, tracks),
                onDelete: () => _deletePlaylist(context, name),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _playPlaylist(
    BuildContext context,
    String name,
    List<Track> tracks,
  ) async {
    if (tracks.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Bu çalma listesi boş.')),
      );
      return;
    }
    await PlayerController.instance.playQueue(tracks, 0, radio: false);
  }

  Future<void> _deletePlaylist(BuildContext context, String name) async {
    await Library.instance.deletePlaylist(name);
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$name silindi.')),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.name,
    required this.trackCount,
    required this.accent,
    required this.onPlay,
    required this.onDelete,
  });

  final String name;
  final int trackCount;
  final Color accent;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF181818),
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: Icon(Icons.queue_music, color: accent),
        title: Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '$trackCount parça',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Çal',
              icon: Icon(Icons.play_arrow, color: accent),
              onPressed: onPlay,
            ),
            IconButton(
              tooltip: 'Sil',
              icon: const Icon(Icons.delete_outline, color: Colors.white70),
              onPressed: onDelete,
            ),
          ],
        ),
        onTap: onPlay,
      ),
    );
  }
}
