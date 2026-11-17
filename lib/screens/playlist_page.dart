import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import '../core/youtube_service.dart';
import '../ui/track_tile.dart';
import 'artist_page.dart';

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
    return _PlaylistResults(
      results[0] as PlaylistInfo?,
      results[1] as List<Track>,
    );
  }

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
              : (widget.initialTitle ?? 'Çalma listesi');

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: tracks.isEmpty ? 2 : tracks.length + 1,
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
                );
              }
              if (tracks.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Liste boş veya erişilemiyor.'),
                );
              }

              final track = tracks[i - 1];
              return TrackTile(
                track: track,
                queue: tracks,
                index: i - 1,
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
  });

  final String title;
  final String author;
  final String? cover;
  final int count;
  final VoidCallback? onPlay;

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
          const Divider(height: 28),
        ],
      ),
    );
  }
}
