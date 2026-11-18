// ignore_for_file: avoid_dynamic_calls
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import '../core/youtube_service.dart';
import '../ui/track_tile.dart';
import 'artist_page.dart';
import 'playlist_editor_page.dart';

/// Playlist detail: a header followed by one continuous, scrollable list.
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key, required this.id, this.initialTitle});

  final String id;
  final String? initialTitle;

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistResults {
  const _PlaylistResults(this.info, this.tracks);

  final PlaylistInfo? info;
  final List<Track> tracks;
}

class _PlaylistPageState extends State<PlaylistPage> {
  late Future<_PlaylistResults> _future;
  ArtistPlaylistView? _artist;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_PlaylistResults> _load() async {
    final results = await Future.wait([
      YoutubeService.instance.playlistInfo(widget.id),
      YoutubeService.instance.playlist(widget.id, limit: 300),
    ]);
    final info = results[0] as PlaylistInfo?;
    final tracks = results[1] as List<Track>;

    // Sanatçı listesi ikinci planda yüklenir; ana liste bloke olmaz.
    final artistId = tracks.isEmpty ? null : tracks.first.artistId;
    if (artistId != null && artistId.isNotEmpty) {
      unawaited(
        fetchArtistPlaylist(
          channelId: artistId,
          name: info?.author.isNotEmpty == true
              ? info!.author
              : (tracks.isEmpty ? widgetName : tracks.first.artist),
        ).then((view) {
          if (!mounted || view.tracks.isEmpty) return;
          setState(() => _artist = view);
        }).catchError((_) {}),
      );
    }

    return _PlaylistResults(info, tracks);
  }

  String get widgetName => widget.initialTitle ?? 'Çalma listesi';

  void _openArtist(Track track) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistPage(
          name: track.artist,
          channelId: track.artistId,
          seedTrack: track,
        ),
      ),
    );
  }

  Future<void> _downloadAll(String title, List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final savedWithGroup = await recordSearchDownloadGroup(title, tracks);
    if (!savedWithGroup) await downloadTracks(tracks);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('${tracks.length} parça indirmeye alındı.')),
    );
  }

  Future<void> _saveToLibrary(String title, List<Track> tracks) async {
    if (tracks.isEmpty) return;
    await saveSearchPlaylistToLibrary(title, tracks);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$title kitaplığına kaydedildi.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.initialTitle ?? 'Çalma listesi')),
      body: FutureBuilder<_PlaylistResults>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snap.data;
          final tracks = data?.tracks ?? const <Track>[];
          final title = data?.info?.title.isNotEmpty == true
              ? data!.info!.title
              : widgetName;
          final hasArtist = _artist != null && _artist!.tracks.isNotEmpty;
          final artistTracks = hasArtist ? _artist!.tracks : <Track>[];
          final baseCount = tracks.isEmpty ? 2 : tracks.length + 1;

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: baseCount + (hasArtist ? 1 + artistTracks.length : 0),
            itemBuilder: (context, i) {
              if (i == 0) {
                return _Header(
                  title: title,
                  author: data?.info?.author ?? '',
                  cover: tracks.isNotEmpty
                      ? tracks.first.thumb
                      : data?.info?.thumb,
                  count: tracks.length,
                  onPlay: tracks.isEmpty
                      ? null
                      : () => PlayerController.instance.playQueue(tracks, 0),
                  onDownload:
                      tracks.isEmpty ? null : () => _downloadAll(title, tracks),
                  onSave: tracks.isEmpty
                      ? null
                      : () => _saveToLibrary(title, tracks),
                );
              }
              if (tracks.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Liste boş veya erişilemiyor.'),
                );
              }
              if (i < baseCount) {
                final track = tracks[i - 1];
                return TrackTile(
                  track: track,
                  queue: tracks,
                  index: i - 1,
                  onArtistTap: () => _openArtist(track),
                );
              }
              if (i == baseCount) {
                return _ArtistSectionHeader(
                  title: _artist?.title ?? title,
                  count: artistTracks.length,
                  onPlay: () => PlayerController.instance.playQueue(
                    artistTracks,
                    0,
                    radio: false,
                  ),
                  onDownload: () => _downloadAll(
                    _artist?.title ?? title,
                    artistTracks,
                  ),
                  onSave: () => _saveToLibrary(
                    '${_artist?.title ?? title} - Sanatçı',
                    artistTracks,
                  ),
                );
              }
              final track = artistTracks[i - baseCount - 1];
              return TrackTile(
                track: track,
                queue: artistTracks,
                index: i - baseCount - 1,
                onArtistTap: () => _openArtist(track),
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
    required this.title,
    required this.author,
    required this.cover,
    required this.count,
    required this.onPlay,
    this.onDownload,
    this.onSave,
  });

  final String title;
  final String author;
  final String? cover;
  final int count;
  final VoidCallback? onPlay;
  final VoidCallback? onDownload;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 168,
              height: 168,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
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
                  ? Icon(Icons.queue_music, size: 64, color: accent)
                  : CachedNetworkImage(
                      imageUrl: cover!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          Icon(Icons.queue_music, size: 64, color: accent),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (author.isNotEmpty)
            Text(author,
                style: TextStyle(color: AppPalette.textSubtle, fontSize: 12)),
          Text('$count parça',
              style: TextStyle(color: AppPalette.textSubtle, fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Tümünü çal'),
            style: FilledButton.styleFrom(backgroundColor: accent),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: onDownload,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Tümünü indir'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent.withValues(alpha: 0.5)),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onSave,
                icon: const Icon(Icons.save_alt_outlined, size: 18),
                label: const Text('Kitaplığıma kaydet'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent.withValues(alpha: 0.5)),
                ),
              ),
            ],
          ),
          const Divider(height: 28),
        ],
      ),
    );
  }
}

class _ArtistSectionHeader extends StatelessWidget {
  const _ArtistSectionHeader({
    required this.title,
    required this.count,
    required this.onPlay,
    required this.onDownload,
    required this.onSave,
  });

  final String title;
  final int count;
  final VoidCallback onPlay;
  final VoidCallback onDownload;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_outline, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sanatçı Çalma Listesi · $title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$count parça',
                style: TextStyle(color: AppPalette.textSubtle, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Ayrı çalma listesi olarak çal'),
                style: OutlinedButton.styleFrom(foregroundColor: accent),
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
          const Divider(height: 24),
        ],
      ),
    );
  }
}
