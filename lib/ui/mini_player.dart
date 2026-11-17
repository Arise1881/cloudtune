import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import 'player_page.dart';

/// Compact now-playing bar pinned above the page content.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;

    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final track = player.current;
        if (track == null) return const SizedBox.shrink();

        return Material(
          color: const Color(0xFF242424),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Progress(track: track),
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PlayerPage()),
                  ),
                  child: SizedBox(
                    height: 62,
                    child: Row(
                      children: [
                        CachedNetworkImage(
                          imageUrl: track.thumb,
                          width: 62,
                          height: 62,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.music_note),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _LikeButton(trackId: track.id),
                        player.loading
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : StreamBuilder<bool>(
                                stream: player.playingStream,
                                builder: (context, snap) => IconButton(
                                  iconSize: 32,
                                  icon: Icon((snap.data ?? false)
                                      ? Icons.pause
                                      : Icons.play_arrow),
                                  onPressed: player.toggle,
                                ),
                              ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (context, duration) {
        final total =
            (duration.data ?? track.duration)?.inMilliseconds ?? 0;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, position) {
            final pos = position.data?.inMilliseconds ?? 0;
            final value =
                total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
            return LinearProgressIndicator(
              value: value,
              minHeight: 2,
              backgroundColor: Colors.white12,
              color: ThemeState.value,
            );
          },
        );
      },
    );
  }
}

class _LikeButton extends StatelessWidget {
  const _LikeButton({required this.trackId});

  final String trackId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Library.instance,
      builder: (context, _) {
        final liked = Library.instance.isLiked(trackId);
        return IconButton(
          tooltip: 'Beğen',
          icon: Icon(
            liked ? Icons.favorite : Icons.favorite_border,
            color: liked ? ThemeState.value : Colors.white54,
          ),
          onPressed: () {
            final track = PlayerController.instance.current;
            if (track != null) Library.instance.toggleLike(track);
          },
        );
      },
    );
  }
}
