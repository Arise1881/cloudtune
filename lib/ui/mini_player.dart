import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import 'cover_image.dart';
import 'player_page.dart';

bool _radioActive(Object player) {
  try {
    final value = (player as dynamic).radioMode;
    if (value is bool) return value;
  } catch (_) {}
  return false;
}

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
          color: AppPalette.card,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_radioActive(player))
                  Semantics(
                    label: 'Radyo modu açık',
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [
                          Colors.transparent,
                          ThemeState.value,
                          Colors.transparent,
                        ]),
                      ),
                    ),
                  ),
                _Progress(track: track),
                if (player.error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    color: Colors.red.withValues(alpha: 0.14),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline,
                            size: 16, color: Colors.redAccent),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Parça oynatılamadı · atlanmadı',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        TextButton(
                          onPressed: player.retry,
                          child: const Text('Tekrar dene'),
                        ),
                      ],
                    ),
                  ),
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PlayerPage()),
                  ),
                  child: SizedBox(
                    height: 62,
                    child: Row(
                      children: [
                        CoverImage(
                          url: track.thumb,
                          width: 62,
                          height: 62,
                          borderRadius: 0,
                          iconSize: 30,
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
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppPalette.textSubtle,
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
                            : IconButton(
                                iconSize: 32,
                                // Broadcast stream ilk durumu kaçırabiliyor;
                                // _broadcast() zaten notifyListeners() çağırır.
                                icon: Icon(player.playing
                                    ? Icons.pause
                                    : Icons.play_arrow),
                                onPressed: player.toggle,
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
        final total = (duration.data ?? track.duration)?.inMilliseconds ?? 0;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, position) {
            final pos = position.data?.inMilliseconds ?? 0;
            final value = total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
            return LinearProgressIndicator(
              value: value,
              minHeight: 2,
              backgroundColor: AppPalette.divider,
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
            color: liked ? ThemeState.value : AppPalette.textSubtle,
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
