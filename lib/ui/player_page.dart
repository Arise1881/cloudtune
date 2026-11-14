import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/player_controller.dart';

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Şimdi çalıyor'),
        centerTitle: true,
      ),
      body: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final track = player.current;
          if (track == null) {
            return const Center(child: Text('Çalan şarkı yok.'));
          }
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CachedNetworkImage(
                          imageUrl: track.thumb,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.music_note, size: 96),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(track.artist,
                      style: const TextStyle(color: Colors.white54)),
                ),
                if (player.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(player.error!,
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
                const SizedBox(height: 12),
                StreamBuilder<Duration?>(
                  stream: player.durationStream,
                  builder: (context, durSnap) {
                    final total = durSnap.data ?? track.duration ?? Duration.zero;
                    return StreamBuilder<Duration>(
                      stream: player.positionStream,
                      builder: (context, posSnap) {
                        final pos = posSnap.data ?? Duration.zero;
                        final max = total.inMilliseconds.toDouble();
                        final value = pos.inMilliseconds
                            .toDouble()
                            .clamp(0.0, max > 0 ? max : 1.0);
                        return Column(
                          children: [
                            Slider(
                              value: value,
                              max: max > 0 ? max : 1.0,
                              onChanged: max > 0
                                  ? (v) => player
                                      .seek(Duration(milliseconds: v.round()))
                                  : null,
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_fmt(pos)),
                                  Text(_fmt(total)),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 40,
                      icon: const Icon(Icons.skip_previous),
                      onPressed: player.previous,
                    ),
                    const SizedBox(width: 12),
                    if (player.loading)
                      const SizedBox(
                        width: 72,
                        height: 72,
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else
                      StreamBuilder<bool>(
                        stream: player.playingStream,
                        builder: (context, snap) => IconButton.filled(
                          iconSize: 48,
                          icon: Icon((snap.data ?? false)
                              ? Icons.pause
                              : Icons.play_arrow),
                          onPressed: player.toggle,
                        ),
                      ),
                    const SizedBox(width: 12),
                    IconButton(
                      iconSize: 40,
                      icon: const Icon(Icons.skip_next),
                      onPressed: player.hasNext ? player.next : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }
}
