import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import '../core/youtube_service.dart';
import '../ui/track_tile.dart';

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
  late Future<List<Track>> _future;

  @override
  void initState() {
    super.initState();
    _future = YoutubeService.instance.artistTracks(
      widget.name,
      channelId: widget.channelId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: FutureBuilder<List<Track>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final tracks = snap.data ?? const <Track>[];
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
                      : () =>
                          PlayerController.instance.playQueue(tracks, 0),
                );
              }
              if (tracks.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Bu sanatçı için parça bulunamadı.'),
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
              color: const Color(0xFF242424),
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
            style: const TextStyle(color: Colors.white54, fontSize: 12),
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
