import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';

/// Single row used by every track list. Tapping plays the given queue at
/// [index]; the current track is highlighted with the active accent color.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.queue,
    required this.index,
    this.onArtistTap,
    this.trailing,
  });

  final Track track;
  final List<Track> queue;
  final int index;
  final VoidCallback? onArtistTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;

    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final isCurrent = player.current?.id == track.id;
        final titleStyle = TextStyle(
          color: isCurrent ? ThemeState.value : null,
          fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
        );

        final artist = Text(
          track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        );

        return ListTile(
          onTap: () => player.playQueue(queue, index),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CachedNetworkImage(
              imageUrl: track.thumb,
              width: 52,
              height: 52,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: AppPalette.card),
              errorWidget: (_, __, ___) =>
                  const Icon(Icons.music_note, size: 36),
            ),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
          subtitle: onArtistTap == null
              ? artist
              : GestureDetector(onTap: onArtistTap, child: artist),
          trailing: trailing ?? _LikeButton(track: track),
        );
      },
    );
  }
}

class _LikeButton extends StatelessWidget {
  const _LikeButton({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Library.instance,
      builder: (context, _) {
        final liked = Library.instance.isLiked(track.id);
        return IconButton(
          tooltip: 'Beğen',
          icon: Icon(
            liked ? Icons.favorite : Icons.favorite_border,
            color: liked ? ThemeState.value : AppPalette.textSubtle,
          ),
          onPressed: () => Library.instance.toggleLike(track),
        );
      },
    );
  }
}
