import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/player_controller.dart';
import 'player_page.dart';

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
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlayerPage()),
              ),
              child: SizedBox(
                height: 64,
                child: Row(
                  children: [
                    CachedNetworkImage(
                      imageUrl: track.thumb,
                      width: 64,
                      height: 64,
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
                          Text(track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          Text(
                            player.error ?? track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: player.error != null
                                  ? Colors.redAccent
                                  : Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (player.loading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      StreamBuilder<bool>(
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
          ),
        );
      },
    );
  }
}
