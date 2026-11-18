// ignore_for_file: avoid_dynamic_calls
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import 'playlist_editor_page.dart';

/// Kullanıcının cihazında sakladığı yerel çalma listeleri.
class MyPlaylistsPage extends StatefulWidget {
  const MyPlaylistsPage({super.key});

  @override
  State<MyPlaylistsPage> createState() => _MyPlaylistsPageState();
}

class _MyPlaylistsPageState extends State<MyPlaylistsPage> {
  /// Yeni API kalıcı sıra sağlamadığında ekranın kendi sırası.
  List<String> _order = const <String>[];

  List<PlaylistInfoView> _ordered(List<PlaylistInfoView> source) {
    final byId = <String, PlaylistInfoView>{
      for (final playlist in source) playlist.id: playlist,
    };
    final result = <PlaylistInfoView>[];
    for (final id in _order) {
      final playlist = byId.remove(id);
      if (playlist != null) result.add(playlist);
    }
    result.addAll(byId.values);
    _order = result.map((playlist) => playlist.id).toList();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;

    return Scaffold(
      backgroundColor: AppPalette.surface,
      appBar: AppBar(
        title: const Text('Çalma Listelerim'),
        backgroundColor: AppPalette.surface,
        actions: [
          IconButton(
            tooltip: 'Yeni çalma listesi',
            icon: const Icon(Icons.add),
            onPressed: _createPlaylist,
          ),
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
          final all = readLibraryPlaylists();
          final artistIds = readArtistPlaylists().map((p) => p.id).toSet();
          final artists =
              all.where((p) => p.isArtist || artistIds.contains(p.id)).toList();
          final searches = all
              .where((p) =>
                  !p.isArtist &&
                  !artistIds.contains(p.id) &&
                  p.source == 'search')
              .toList();
          final custom = _ordered(
            all
                .where((p) =>
                    !p.isArtist &&
                    !artistIds.contains(p.id) &&
                    p.source != 'search')
                .toList(),
          );

          if (custom.isEmpty && searches.isEmpty && artists.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.playlist_play, size: 72, color: accent),
                  const SizedBox(height: 16),
                  Text(
                    'Henüz çalma listesi yok.',
                    style: TextStyle(color: AppPalette.textMuted, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _createPlaylist,
                    icon: const Icon(Icons.add),
                    label: const Text('Çalma listesi oluştur'),
                    style: FilledButton.styleFrom(backgroundColor: accent),
                  ),
                ],
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
            children: [
              if (custom.isNotEmpty) ...[
                _sectionHeader('Çalma listelerim', '${custom.length} liste'),
                const SizedBox(height: 8),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: custom.length,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex -= 1;
                    if (newIndex < 0 || newIndex >= custom.length) return;
                    setState(() {
                      final moved = custom.removeAt(oldIndex);
                      custom.insert(newIndex, moved);
                      _order = custom.map((p) => p.id).toList();
                    });
                  },
                  itemBuilder: (context, index) {
                    final playlist = custom[index];
                    return _PlaylistCard(
                      key: ValueKey(playlist.id),
                      playlist: playlist,
                      accent: accent,
                      reorderable: true,
                      onPlay: () => _playPlaylist(context, playlist),
                      onEdit: () => _openEditor(context, playlist),
                      onRename: () => _renamePlaylist(context, playlist),
                      onDelete: () => _confirmDelete(context, playlist),
                    );
                  },
                ),
              ],
              if (searches.isNotEmpty) ...[
                const SizedBox(height: 20),
                _sectionHeader('Arama listeleri', '${searches.length} liste'),
                const SizedBox(height: 8),
                for (final playlist in searches)
                  _PlaylistCard(
                    playlist: playlist,
                    accent: accent,
                    onPlay: () => _playPlaylist(context, playlist),
                    onEdit: () => _openEditor(context, playlist),
                    onRename: () => _renamePlaylist(context, playlist),
                    onDelete: () => _confirmDelete(context, playlist),
                  ),
              ],
              if (artists.isNotEmpty) ...[
                const SizedBox(height: 20),
                _sectionHeader(
                  'Sanatçı çalma listeleri',
                  '${artists.length} liste',
                ),
                const SizedBox(height: 8),
                for (final playlist in artists)
                  _PlaylistCard(
                    playlist: playlist,
                    accent: accent,
                    onPlay: () => _playPlaylist(context, playlist),
                    onEdit: () => _openEditor(context, playlist),
                    onRename: () => _renamePlaylist(context, playlist),
                    onDelete: () => _confirmDelete(context, playlist),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(String title, String trailing) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          trailing,
          style: TextStyle(color: AppPalette.textSubtle, fontSize: 12),
        ),
      ],
    );
  }

  Future<void> _playPlaylist(
    BuildContext context,
    PlaylistInfoView playlist,
  ) async {
    if (playlist.tracks.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Bu çalma listesi boş.')),
      );
      return;
    }
    await PlayerController.instance.playQueue(
      playlist.tracks,
      0,
      radio: false,
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    PlaylistInfoView playlist,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaylistEditorPage(playlist: playlist),
      ),
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController(
      text: 'Çalma Listesi ${readLibraryPlaylists().length + 1}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('Yeni çalma listesi'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Liste adı',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Oluştur'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    final clean = name.trim();
    if (clean.isEmpty) return;
    await createPlaylist(clean, const <Track>[]);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$clean oluşturuldu.')),
    );
  }

  Future<void> _renamePlaylist(
    BuildContext context,
    PlaylistInfoView playlist,
  ) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('Listeyi adlandır'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Yeni ad',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    final clean = name.trim();
    if (clean.isEmpty || clean == playlist.name) return;
    await renamePlaylist(playlist, clean);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    PlaylistInfoView playlist,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('Listeyi sil'),
        content: Text('${playlist.name} silinecek. Emin misin?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await deletePlaylist(playlist);
    if (!context.mounted) return;
    _order.removeWhere((id) => id == playlist.id);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('${playlist.name} silindi.')),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    super.key,
    required this.playlist,
    required this.accent,
    required this.onPlay,
    required this.onEdit,
    required this.onRename,
    required this.onDelete,
    this.reorderable = false,
  });

  final PlaylistInfoView playlist;
  final Color accent;
  final VoidCallback onPlay;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final bool reorderable;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppPalette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: Stack(
          alignment: Alignment.bottomRight,
          children: [
            Icon(playlist.sourceIcon, color: accent, size: 28),
            if (reorderable)
              Icon(Icons.drag_indicator,
                  size: 14, color: AppPalette.iconFaint),
          ],
        ),
        title: Text(
          playlist.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Row(
          children: [
            Text(
              '${playlist.tracks.length} parça',
              style: TextStyle(color: AppPalette.textMuted, fontSize: 12),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                playlist.sourceLabel,
                style: TextStyle(color: accent, fontSize: 10),
              ),
            ),
          ],
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
              tooltip: 'Düzenle',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
            PopupMenuButton<String>(
              tooltip: 'Diğer',
              onSelected: (value) {
                if (value == 'rename') onRename();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Adlandır')),
                PopupMenuItem(value: 'delete', child: Text('Sil')),
              ],
            ),
          ],
        ),
        onTap: onPlay,
      ),
    );
  }
}
