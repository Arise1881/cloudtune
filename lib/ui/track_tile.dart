import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';

/// Tek satirlik sarki ogesi. Tum listeler (calma listesi, sanatci,
/// arama, oda) bu bileseni kullanir; boylece sayfa tek akis halinde
/// kaydirilir.
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
        return ListTile(
          onTap: () => player.playQueue(queue, index),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CachedNetworkImage(
              imageUrl: track.thumb,
              width: 52,
              height: 52,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: const Color(0xFF242424)),
              errorWidget: (_, __, ___) =>
                  const Icon(Icons.music_note, size: 36),
            ),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isCurrent ? ThemeState.accent.value : null,
              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          subtitle: Text(
            track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: trailing ??
              ListenableBuilder(
                listenable: Library.instance,
                builder: (context, _) => IconButton(
                  tooltip: 'Begen',
                  icon: Icon(
                    Library.instance.isLiked(track.id)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: Library.instance.isLiked(track.id)
                        ? ThemeState.accent.value
                        : Colors.white54,
                  ),
                  onPressed: () => Library.instance.toggleLike(track),
                ),
              ),
        );
      },
    );
  }
}
