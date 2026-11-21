import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import '../core/download_service.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import '../core/youtube_service.dart';
import 'cover_image.dart';

List<Track> _artistTracks(List<Track> queue, Track track) {
  final sameArtist =
      queue.where((item) => item.artist == track.artist).toList();
  return sameArtist.isEmpty ? <Track>[track] : sameArtist;
}

RelativeRect _menuRect(BuildContext context) {
  final box = context.findRenderObject() as RenderBox;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return RelativeRect.fill;
  return RelativeRect.fromRect(
    Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
}

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
    this.onSaveArtist,
    this.onDownloadAll,
    this.actionTracks,
  });

  final Track track;
  final List<Track> queue;
  final int index;
  final VoidCallback? onArtistTap;
  final Widget? trailing;

  /// İsteğe bağlı yeni aksiyonlar. Verilmezse kendi varsayılan
  /// davranışımız kullanılır; mevcut çağrılar değişiklik gerektirmez.
  final VoidCallback? onSaveArtist;
  final Future<void> Function()? onDownloadAll;
  final List<Track>? actionTracks;

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

        final targets = actionTracks ?? _artistTracks(queue, track);

        Future<void> showActions(BuildContext anchor) async {
          final messenger = ScaffoldMessenger.maybeOf(context);
          final result = await showMenu<String>(
            context: context,
            position: _menuRect(anchor),
            items: const [
              PopupMenuItem<String>(
                value: 'save',
                child: Row(
                  children: [
                    Icon(Icons.person_add_alt_1_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Sanatçı listesine kaydet'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'download',
                child: Row(
                  children: [
                    Icon(Icons.download_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Tümünü indir'),
                  ],
                ),
              ),
            ],
          );
          if (result == null || !context.mounted) return;

          if (result == 'save') {
            if (onSaveArtist != null) {
              onSaveArtist!();
              return;
            }
            final name = 'Sanatçı: ${track.artist}';
            await Library.instance.createPlaylist(name, targets);
            if (context.mounted) {
              messenger?.showSnackBar(
                SnackBar(
                  content: Text(
                      '"$name" listesine ${targets.length} parça kaydedildi.'),
                ),
              );
            }
            return;
          }

          if (onDownloadAll != null) {
            await onDownloadAll!();
            return;
          }
          var saved = 0;
          for (final item in targets) {
            try {
              final path = await DownloadService.instance.download(item);
              if (path != null) saved++;
            } catch (_) {}
          }
          if (context.mounted) {
            messenger?.showSnackBar(
              SnackBar(
                  content: Text('$saved/${targets.length} parça indirildi.')),
            );
          }
        }

        // Dokunma sinyali ListTile'a gitmeden önce adresi ısıt; çözüm ağda
        // sürerken kullanıcı parmak kaldırana kadar zaman kazanılır.
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) =>
              unawaited(YoutubeService.instance.prefetch(track.id)),
          child: ListTile(
            onTap: () => player.playQueue(queue, index),
            onLongPress: () => showActions(context),
            leading: CoverImage(
              url: track.thumb,
              width: 52,
              height: 52,
              borderRadius: 6,
              iconSize: 36,
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (trailing != null) trailing!,
                if (trailing == null) _LikeButton(track: track),
                _MoreButton(onTap: showActions),
              ],
            ),
          ),
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

class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.onTap});

  final void Function(BuildContext context) onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Diğer işlemler',
      iconSize: 20,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      icon: Icon(Icons.more_vert, color: AppPalette.textSubtle),
      onPressed: () => onTap(context),
    );
  }
}
