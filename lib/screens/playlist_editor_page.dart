// ignore_for_file: avoid_dynamic_calls
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/download_service.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import '../core/youtube_service.dart';

/// ---------------------------------------------------------------------------
/// Uyumluluk katmanı
///
/// Library / DownloadService / YoutubeService üzerindeki yeni API'ler beklenen
/// sözleşmeyle gelir; eski sürümde çalışırken `NoSuchMethodError` yakalanıp
/// mevcut API'ye düşülür. Böylece bu ekranlar iki sürümle de derlenir.
/// ---------------------------------------------------------------------------

/// Bir yerel çalma listesinin UI'daki sade görünümü.
class PlaylistInfoView {
  const PlaylistInfoView({
    required this.id,
    required this.name,
    required this.tracks,
    this.source = 'manual',
  });

  final String id;
  final String name;
  final List<Track> tracks;

  /// `manual` | `artist` | `search` | `playlist`
  final String source;

  bool get isArtist => source == 'artist';

  String get sourceLabel => switch (source) {
        'artist' => 'Sanatçı',
        'search' => 'Arama',
        'playlist' => 'YouTube',
        _ => 'Özel',
      };

  IconData get sourceIcon => switch (source) {
        'artist' => Icons.person_outline,
        'search' => Icons.search,
        'playlist' => Icons.video_library_outlined,
        _ => Icons.queue_music,
      };
}

class ArtistPlaylistView {
  const ArtistPlaylistView({this.title, required this.tracks});

  final String? title;
  final List<Track> tracks;
}

class DownloadGroupView {
  const DownloadGroupView({
    required this.id,
    required this.name,
    required this.tracks,
    this.kind = 'search',
  });

  final String id;
  final String name;
  final List<Track> tracks;
  final String kind;

  bool get isArtist => kind == 'artist';

  String get kindLabel => isArtist ? 'Sanatçı' : 'Arama';

  IconData get kindIcon => isArtist ? Icons.person_outline : Icons.search;
}

PlaylistInfoView _playlistFromMeta(dynamic meta) {
  var id = '';
  var name = '';
  var source = 'manual';
  List<Track> tracks = const <Track>[];

  try {
    id = (meta.id ?? '').toString();
  } catch (_) {}
  try {
    name = (meta.name ?? '').toString();
  } catch (_) {}
  try {
    source = (meta.source ?? '').toString();
  } catch (_) {}
  try {
    final raw = meta.tracks;
    if (raw is List) tracks = raw.whereType<Track>().toList();
  } catch (_) {}

  if (id.isEmpty) id = name;
  if (name.isEmpty) name = id.isEmpty ? 'Çalma listesi' : id;
  return PlaylistInfoView(
    id: id,
    name: name,
    tracks: tracks,
    source: source.isEmpty ? 'manual' : source,
  );
}

/// Kitaplıktaki tüm listeler (yeni API varsa meta verisiyle birlikte).
List<PlaylistInfoView> readLibraryPlaylists() {
  final library = Library.instance;
  try {
    final value = (library as dynamic).playlistMetas;
    if (value is List) {
      return value.map(_playlistFromMeta).toList();
    }
  } catch (_) {}

  return library.playlistNames
      .map(
        (name) => PlaylistInfoView(
          id: name,
          name: name,
          tracks: library.getPlaylist(name),
        ),
      )
      .toList();
}

/// Yalnızca sanatçı kaynaklı listeler.
List<PlaylistInfoView> readArtistPlaylists() {
  final library = Library.instance;
  try {
    final value = (library as dynamic).artistPlaylists;
    if (value is List) return value.map(_playlistFromMeta).toList();
  } catch (_) {}
  return const <PlaylistInfoView>[];
}

List<Track> _currentTracks(PlaylistInfoView ref) {
  final library = Library.instance;
  try {
    final value = (library as dynamic).playlistMetas;
    if (value is List) {
      for (final meta in value) {
        try {
          if ((meta.id ?? '').toString() != ref.id) continue;
          final raw = meta.tracks;
          if (raw is List) return raw.whereType<Track>().toList();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return library.getPlaylist(ref.name);
}

bool _sameTracks(List<Track> a, List<Track> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

Future<void> createPlaylist(String name, List<Track> tracks) async {
  final library = Library.instance;
  try {
    await (library as dynamic).createPlaylist(name, tracks);
  } on NoSuchMethodError catch (_) {
    try {
      await (library as dynamic).createPlaylist(name);
    } on NoSuchMethodError catch (_) {
      // API yok: kullanıcıya haber verilmesi çağıran ekranın işi.
    }
  }
}

Future<void> renamePlaylist(PlaylistInfoView ref, String newName) async {
  final library = Library.instance;
  try {
    await (library as dynamic).renamePlaylist(ref.id, newName);
    return;
  } on NoSuchMethodError catch (_) {}

  final tracks = ref.tracks;
  await library.deletePlaylist(ref.id);
  await createPlaylist(newName, tracks);
}

Future<void> deletePlaylist(PlaylistInfoView ref) async {
  final library = Library.instance;
  try {
    await (library as dynamic).deletePlaylist(ref.id);
  } on NoSuchMethodError catch (_) {
    await library.deletePlaylist(ref.name);
  }
}

Future<void> addTrackToPlaylist(PlaylistInfoView ref, Track track) async {
  final library = Library.instance;
  try {
    await (library as dynamic).addToPlaylist(ref.id, track);
    return;
  } on NoSuchMethodError catch (_) {}
  await createPlaylist(ref.name, [...ref.tracks, track]);
}

Future<void> removeTrackFromPlaylist(PlaylistInfoView ref, int index) async {
  final library = Library.instance;
  try {
    await (library as dynamic).removeFromPlaylist(ref.id, index);
    return;
  } on NoSuchMethodError catch (_) {}
  final tracks = [...ref.tracks];
  if (index < 0 || index >= tracks.length) return;
  tracks.removeAt(index);
  await createPlaylist(ref.name, tracks);
}

/// Editördeki son listeyi kitaplığa işler.
Future<void> applyPlaylistEdits(
  PlaylistInfoView ref,
  List<Track> edited,
) async {
  final library = Library.instance;

  // Yeni API'de toplu yazma varsa en temiz yol bu.
  try {
    await (library as dynamic).replacePlaylist(ref.id, edited);
    return;
  } on NoSuchMethodError catch (_) {}
  try {
    await (library as dynamic).setPlaylistTracks(ref.id, edited);
  } on NoSuchMethodError catch (_) {
    // Parça parça eşitlemeye geç.
    try {
      await _syncGranular(ref, edited);
      return;
    } on NoSuchMethodError catch (_) {
      // Eski API: aynı anahtarı yeniden yazarak sırayı da korur.
      await createPlaylist(ref.name, edited);
    }
  }
}

Future<void> _syncGranular(PlaylistInfoView ref, List<Track> target) async {
  final library = Library.instance;

  outer:
  for (var step = 0; step < 500; step++) {
    final current = _currentTracks(ref);
    if (_sameTracks(current, target)) return;

    // 1) Hedefte olmayan parçaları çıkar.
    for (var i = current.length - 1; i >= 0; i--) {
      if (target.any((track) => track.id == current[i].id)) continue;
      await (library as dynamic).removeFromPlaylist(ref.id, i);
      continue outer;
    }

    // 2) Sırayı düzelt.
    for (var i = 0; i < target.length && i < current.length; i++) {
      if (current[i].id == target[i].id) continue;
      final from = current.indexWhere((track) => track.id == target[i].id);
      if (from > i) {
        await (library as dynamic).reorderPlaylist(ref.id, from, i);
        continue outer;
      }
    }

    // 3) Eksik parçaları ekle.
    for (final track in target) {
      if (current.any((item) => item.id == track.id)) continue;
      await (library as dynamic).addToPlaylist(ref.id, track);
      continue outer;
    }
    return;
  }
}

Future<void> saveArtistPlaylistToLibrary(
  String artistId,
  String name,
  List<Track> tracks,
) async {
  final library = Library.instance;
  try {
    await (library as dynamic).saveArtistPlaylist(artistId, name, tracks);
    return;
  } on NoSuchMethodError catch (_) {}
  await createPlaylist(name, tracks);
}

Future<void> saveSearchPlaylistToLibrary(
  String name,
  List<Track> tracks,
) async {
  final library = Library.instance;
  try {
    await (library as dynamic).saveSearchPlaylist(name, tracks);
    return;
  } on NoSuchMethodError catch (_) {}
  await createPlaylist(name, tracks);
}

Future<ArtistPlaylistView> fetchArtistPlaylist({
  required String channelId,
  required String name,
}) async {
  final youtube = YoutubeService.instance;
  if (channelId.isNotEmpty) {
    try {
      final result = await (youtube as dynamic)
          .artistPlaylist(channelId, name: name)
          .timeout(const Duration(seconds: 12));
      List<Track> tracks = const <Track>[];
      String? title;
      try {
        final raw = result.tracks;
        if (raw is List) tracks = raw.whereType<Track>().toList();
      } catch (_) {}
      try {
        title = (result.info?.title ?? '').toString();
      } catch (_) {}
      if (title?.isEmpty ?? true) title = name;
      if (tracks.isNotEmpty) {
        return ArtistPlaylistView(title: title, tracks: tracks);
      }
    } on NoSuchMethodError catch (_) {
      // Eski YoutubeService: sanatçı yüklemelerine düş.
    } catch (_) {
      // Ağ hatası: yine de eski yöntemi dene.
    }
  }

  final tracks = await youtube.artistTracks(name, channelId: channelId);
  return ArtistPlaylistView(title: name, tracks: tracks);
}

List<DownloadGroupView> readDownloadGroups() {
  final service = DownloadService.instance;
  try {
    final value = (service as dynamic).groups;
    if (value is Map) {
      return value.values
          .map((group) => _groupFromMeta(group, service))
          .whereType<DownloadGroupView>()
          .toList();
    }
    if (value is List) {
      return value
          .map((group) => _groupFromMeta(group, service))
          .whereType<DownloadGroupView>()
          .toList();
    }
  } catch (_) {}
  return const <DownloadGroupView>[];
}

DownloadGroupView? _groupFromMeta(dynamic group, DownloadService service) {
  var id = '';
  var name = '';
  var kind = '';
  List<Track> tracks = const <Track>[];

  try {
    id = (group.id ?? '').toString();
  } catch (_) {}
  try {
    name = (group.name ?? group.title ?? '').toString();
  } catch (_) {}
  try {
    kind = (group.kind ?? group.type ?? group.source ?? '').toString();
  } catch (_) {}
  if (kind.isEmpty) kind = id.startsWith('artist:') ? 'artist' : 'search';

  // Yeni API grup içinde yalnızca parça kimlikleri tutar.
  try {
    final raw = group.trackIds;
    if (raw is List) {
      final ids = raw.whereType<String>().toList();
      final byId = <String, Track>{
        for (final track in service.savedTracks) track.id: track,
      };
      for (final track in PlayerController.instance.tracks) {
        byId.putIfAbsent(track.id, () => track);
      }
      tracks = ids.map((trackId) => byId[trackId]).whereType<Track>().toList();
    }
  } catch (_) {}
  if (tracks.isEmpty) {
    try {
      final raw = group.tracks;
      if (raw is List) tracks = raw.whereType<Track>().toList();
    } catch (_) {}
  }

  if (id.isEmpty) id = name;
  if (name.isEmpty) name = id.isEmpty ? 'İndirme grubu' : id;
  return DownloadGroupView(id: id, name: name, tracks: tracks, kind: kind);
}

/// Yeni API grup kaydıyla birlikte indirmeyi de yapar; `true` dönerse ayrıca
/// [downloadTracks] çağrılmasına gerek yoktur.
Future<bool> recordArtistDownloadGroup(
  String artistId,
  String name,
  List<Track> tracks,
) async {
  final service = DownloadService.instance;
  try {
    await (service as dynamic).saveArtistPlaylist(artistId, name, tracks);
    return true;
  } on NoSuchMethodError catch (_) {
    return false;
  } catch (_) {
    return false;
  }
}

Future<bool> recordSearchDownloadGroup(
  String name,
  List<Track> tracks,
) async {
  final service = DownloadService.instance;
  try {
    await (service as dynamic).saveSearchPlaylist(name, tracks);
    return true;
  } on NoSuchMethodError catch (_) {
    return false;
  } catch (_) {
    return false;
  }
}

Future<void> downloadTracks(List<Track> tracks) async {
  if (tracks.isEmpty) return;
  final service = DownloadService.instance;
  try {
    await (service as dynamic).downloadAll(tracks);
    return;
  } on NoSuchMethodError catch (_) {
  } catch (_) {}

  for (final track in tracks) {
    await service.download(track);
  }
}

Future<void> deleteDownloadGroup(DownloadGroupView group) async {
  final service = DownloadService.instance;
  try {
    await (service as dynamic).deleteGroup(group.id);
    return;
  } on NoSuchMethodError catch (_) {}
  try {
    await (service as dynamic).removeGroup(group.id);
    return;
  } on NoSuchMethodError catch (_) {}

  for (final track in group.tracks) {
    await service.deleteDownload(track.id);
  }
}

/// ---------------------------------------------------------------------------
/// Playlist düzenleyici
/// ---------------------------------------------------------------------------

/// Bir çalma listesinin içeriğini sıralar, parça ekler/çıkarır ve kaydeder.
class PlaylistEditorPage extends StatefulWidget {
  const PlaylistEditorPage({
    super.key,
    required this.playlist,
  });

  final PlaylistInfoView playlist;

  @override
  State<PlaylistEditorPage> createState() => _PlaylistEditorPageState();
}

class _PlaylistEditorPageState extends State<PlaylistEditorPage> {
  late List<Track> _tracks;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tracks = List<Track>.from(widget.playlist.tracks);
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      if (newIndex < 0 || newIndex >= _tracks.length) return;
      final track = _tracks.removeAt(oldIndex);
      _tracks.insert(newIndex, track);
    });
  }

  Future<void> _addTrack(Track track) async {
    if (_tracks.any((item) => item.id == track.id)) return;
    setState(() => _tracks.add(track));
  }

  Future<void> _openAddSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppPalette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AddTrackSheet(
        excludeIds: _tracks.map((track) => track.id).toSet(),
        onAdd: _addTrack,
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await applyPlaylistEdits(widget.playlist, _tracks);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('${widget.playlist.name} kaydedildi.')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;

    return Scaffold(
      backgroundColor: AppPalette.scaffold,
      appBar: AppBar(
        title: Text('Düzenle: ${widget.playlist.name}'),
        backgroundColor: AppPalette.surface,
        actions: [
          IconButton(
            tooltip: 'Kaydet',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Icon(widget.playlist.sourceIcon, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(
                  '${_tracks.length} parça · ${widget.playlist.sourceLabel}',
                  style: TextStyle(color: AppPalette.textSubtle, fontSize: 12),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _openAddSheet,
                  icon: Icon(Icons.add, color: accent),
                  label: Text('Parça ekle', style: TextStyle(color: accent)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _tracks.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.queue_music, size: 56, color: accent),
                        const SizedBox(height: 12),
                        const Text('Bu liste henüz boş.'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _openAddSheet,
                          icon: const Icon(Icons.add),
                          label: const Text('Parça ekle'),
                          style: FilledButton.styleFrom(
                            backgroundColor: accent,
                          ),
                        ),
                      ],
                    ),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                    itemCount: _tracks.length,
                    onReorder: _reorder,
                    itemBuilder: (context, index) {
                      final track = _tracks[index];
                      return Card(
                        key: ValueKey(track.id),
                        color: AppPalette.cardAlt,
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          leading: ReorderableDragStartListener(
                            index: index,
                            child: Icon(
                              Icons.drag_indicator,
                              color: AppPalette.iconSubtle,
                            ),
                          ),
                          title: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppPalette.textSubtle,
                              fontSize: 12,
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: 'Listeden çıkar',
                            icon: const Icon(Icons.delete_outline),
                            color: Colors.redAccent,
                            onPressed: () {
                              setState(() => _tracks.removeAt(index));
                            },
                          ),
                          onTap: () => PlayerController.instance.playQueue(
                            _tracks,
                            index,
                            radio: false,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _AddTrackSheet extends StatefulWidget {
  const _AddTrackSheet({
    required this.excludeIds,
    required this.onAdd,
  });

  final Set<String> excludeIds;
  final ValueChanged<Track> onAdd;

  @override
  State<_AddTrackSheet> createState() => _AddTrackSheetState();
}

class _AddTrackSheetState extends State<_AddTrackSheet> {
  final _controller = TextEditingController();
  List<Track> _results = const <Track>[];
  String? _error;
  bool _searching = false;
  String? _selectedPlaylist;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _selectedPlaylist = null;
    });
    try {
      final found = await YoutubeService.instance.search(query, limit: 30);
      if (!mounted) return;
      setState(() => _results = found);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = const <Track>[];
        _error = 'Arama yapılamadı. Bağlantını kontrol et.';
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  List<Track> _libraryTracks() {
    final library = Library.instance;
    final seen = <String>{};
    final tracks = <Track>[];
    void addAll(Iterable<Track> source) {
      for (final track in source) {
        if (widget.excludeIds.contains(track.id)) continue;
        if (!seen.add(track.id)) continue;
        tracks.add(track);
      }
    }

    final selected = _selectedPlaylist;
    if (selected != null) {
      addAll(library.getPlaylist(selected));
    } else {
      addAll(library.liked);
      addAll(library.history);
    }
    return tracks.take(40).toList();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;
    final libraryTracks =
        _controller.text.trim().isEmpty ? _libraryTracks() : const <Track>[];
    final names = Library.instance.playlistNames;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'YouTube\'da parça ara',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: 'Ara',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _search,
                  ),
                  filled: true,
                  fillColor: AppPalette.input,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (names.isNotEmpty && _controller.text.trim().isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: DropdownButton<String?>(
                    value: _selectedPlaylist,
                    hint: const Text('Kitaplıktan: Beğenilenler / Geçmiş'),
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Beğenilenler / Geçmiş'),
                      ),
                      for (final name in names)
                        DropdownMenuItem<String?>(
                          value: name,
                          child: Text(name),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _selectedPlaylist = value),
                  ),
                ),
              ),
            const Divider(),
            Expanded(
              child: _searching
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppPalette.textMuted),
                            ),
                          ),
                        )
                      : _controller.text.trim().isEmpty
                          ? _trackList(libraryTracks, accent)
                          : _trackList(_results, accent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trackList(List<Track> tracks, Color accent) {
    if (tracks.isEmpty) {
      return const Center(child: Text('Eklenecek parça bulunamadı.'));
    }
    return ListView.separated(
      itemCount: tracks.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final track = tracks[index];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CachedNetworkImage(
              imageUrl: track.thumb,
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) =>
                  const Icon(Icons.music_note, size: 24),
            ),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: 'Ekle',
            icon: Icon(Icons.add_circle_outline, color: accent),
            onPressed: () {
              widget.onAdd(track);
              setState(() {
                if (_controller.text.trim().isNotEmpty) {
                  _results =
                      _results.where((item) => item.id != track.id).toList();
                }
              });
            },
          ),
          onTap: () {
            widget.onAdd(track);
            Navigator.of(context).pop();
          },
        );
      },
    );
  }
}
