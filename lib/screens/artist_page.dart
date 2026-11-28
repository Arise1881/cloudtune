// ignore_for_file: avoid_dynamic_calls
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import '../ui/track_tile.dart';
import 'playlist_editor_page.dart';

/// Artist profile: a header followed by one continuous, scrollable list.
class ArtistPage extends StatefulWidget {
  const ArtistPage({
    super.key,
    required this.name,
    this.channelId,
    this.seedTrack,
  });

  final String name;
  final String? channelId;
  final Track? seedTrack;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  late Future<ArtistPlaylistView> _future;

  @override
  void initState() {
    super.initState();
    _future = fetchArtistPlaylist(
      channelId: widget.channelId ?? '',
      name: widget.name,
    );
  }

  String get _playlistName => '${widget.name} · Sanatçı Çalma Listesi';

  Future<void> _downloadAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final savedWithGroup = await recordArtistDownloadGroup(
      widget.channelId ?? '',
      _playlistName,
      tracks,
    );
    if (!savedWithGroup) await downloadTracks(tracks);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('${tracks.length} parça indirmeye alındı.')),
    );
  }

  Future<void> _saveToLibrary(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    await saveArtistPlaylistToLibrary(
      widget.channelId ?? '',
      _playlistName,
      tracks,
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$_playlistName kitaplığına kaydedildi.')),
    );
  }

  void _playSeparately(List<Track> tracks) {
    if (tracks.isEmpty) return;
    PlayerController.instance.playQueue(tracks, 0, radio: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: FutureBuilder<ArtistPlaylistView>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final tracks = snap.data?.tracks ?? const <Track>[];
          final cover = widget.seedTrack?.thumb ??
              (tracks.isNotEmpty ? tracks.first.thumb : null);
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: tracks.isEmpty ? 2 : tracks.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return _Header(
                  name: widget.name,
                  cover: cover,
                  trackCount: tracks.length,
                  onPlay: tracks.isEmpty
                      ? null
                      : () => PlayerController.instance.playQueue(tracks, 0),
                );
              }
              if (tracks.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Bu sanatçı için parça bulunamadı.'),
                );
              }
              if (i == 1) {
                return _ArtistPlaylistCard(
                  name: _playlistName,
                  count: tracks.length,
                  onPlay: () => _playSeparately(tracks),
                  onDownload: () => _downloadAll(tracks),
                  onSave: () => _saveToLibrary(tracks),
                );
              }
              final track = tracks[i - 1];
              return TrackTile(
                track: track,
                queue: tracks,
                index: i - 1,
              );
            },
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.cover,
    required this.trackCount,
    required this.onPlay,
  });

  final String name;
  final String? cover;
  final int trackCount;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppPalette.card,
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.25),
                  blurRadius: 24,
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: cover == null
                ? Icon(Icons.person, size: 64, color: accent)
                : CachedNetworkImage(
                    imageUrl: cover!,
                    fit: BoxFit.cover,
                    memCacheWidth: 264,
                    memCacheHeight: 264,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    errorWidget: (_, __, ___) =>
                        Icon(Icons.person, size: 64, color: accent),
                  ),
          ),
          const SizedBox(height: 12),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            '$trackCount parça',
            style: TextStyle(color: AppPalette.textSubtle, fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Tümünü çal'),
            style: FilledButton.styleFrom(backgroundColor: accent),
          ),
          const Divider(height: 32),
        ],
      ),
    );
  }
}

class _ArtistPlaylistCard extends StatelessWidget {
  const _ArtistPlaylistCard({
    required this.name,
    required this.count,
    required this.onPlay,
    required this.onDownload,
    required this.onSave,
  });

  final String name;
  final int count;
  final VoidCallback onPlay;
  final VoidCallback onDownload;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;

    return Card(
      color: AppPalette.cardAlt,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: accent.withValues(alpha: 0.16),
                  child: Icon(Icons.person_outline, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sanatçı Çalma Listesi',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '$name · $count parça',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppPalette.textSubtle,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Ayrı çalma listesi olarak çal'),
                  style: FilledButton.styleFrom(backgroundColor: accent),
                ),
                OutlinedButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Tümünü indir'),
                  style: OutlinedButton.styleFrom(foregroundColor: accent),
                ),
                OutlinedButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.save_alt_outlined, size: 18),
                  label: const Text('Kitaplığıma kaydet'),
                  style: OutlinedButton.styleFrom(foregroundColor: accent),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
