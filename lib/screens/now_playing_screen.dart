import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/player_service.dart';
import 'lyrics_screen.dart';
import 'song_actions.dart';

/// Tam ekran "Şu An Çalıyor" ekranı (Spotify tarzı).
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  static Route<dynamic> route(BuildContext context) => PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => const NowPlayingScreen(),
        transitionsBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
              parent: animation, curve: Curves.easeOutCubic);
          return SlideTransition(
            position: Tween<Offset>(
                    begin: const Offset(0, 1), end: Offset.zero)
                .animate(curved),
            child: child,
          );
        },
      );

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.current;

    return Scaffold(
      body: song == null
          ? const Center(
              child: Text('Çalan şarkı yok',
                  style: TextStyle(color: AppColors.textSecondary)))
          : Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: _buildGradientColors(song),
                  stops: [0.0, 0.6],
                ),
              ),
              child: SafeArea(
          child: song == null
              ? const Center(
                  child: Text('Çalan şarkı yok',
                      style: TextStyle(color: AppColors.textSecondary)))
              : Column(
                  children: [
                    _topBar(context, player),
                    Expanded(child: _artwork(song)),
                    _titleRow(player, song),
                    _actionRow(context, player, song),
                    _progressBar(player, song),
                    _controls(player),
                    _footer(player),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, PlayerService player) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down,
                  size: 30, color: AppColors.textPrimary),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const Spacer(),
            Column(
              children: [
                Text('ŞUNU ÇALIYOR',
                    style: TextStyle(
                        color: AppColors.textSecondary.withValues(alpha: .8),
                        fontSize: 10,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.w700)),
                if (player.playingOffline)
                  const Row(children: [
                    Icon(Icons.offline_pin,
                        size: 12, color: AppColors.accentBright),
                    SizedBox(width: 4),
                    Text('ÇEVRİMDIŞI',
                        style: TextStyle(
                            color: AppColors.accentBright,
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w800)),
                  ]),
              ],
            ),
            const Spacer(),
            IconButton(
              icon:
                  const Icon(Icons.more_vert, color: AppColors.textPrimary),
              onPressed: () {
                final song = player.current;
                if (song != null) showSongActions(context, song);
              },
            ),
          ],
        ),
      );

  Widget _artwork(Song song) {
    String? localArt;
    try {
      final f = File(DownloadManager.instance.artPath(song.id));
      if (f.existsSync()) localArt = f.path;
    } catch (_) {}

    Widget image;
    if (localArt != null) {
      image = Image.file(File(localArt), fit: BoxFit.cover);
    } else if (song.thumbnailUrl.isNotEmpty) {
      image = CachedNetworkImage(
        imageUrl: song.thumbnailUrl,
        fit: BoxFit.cover,
        httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
        placeholder: (_, _) =>
            Container(color: AppColors.card),
        errorWidget: (_, _, _) => Container(color: AppColors.card),
      );
    } else {
      image = Container(color: AppColors.card);
    }

    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          child: Hero(
            tag: 'art-${song.id}',
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 30),
                ],
              ),
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(10), child: image),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleRow(PlayerService player, Song song) {
    final library = context.watch<LibraryStore>();
    final liked = library.isFavorite(song.id);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 15)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(liked ? Icons.favorite : Icons.favorite_border,
                color: liked ? AppColors.accentBright : AppColors.textSecondary,
                size: 26),
            onPressed: () => library.toggleFavorite(song),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(BuildContext context, PlayerService player, Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      child: Row(
        children: [
          _pillButton(
            icon: Icons.lyrics_outlined,
            label: 'Sözler',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => LyricsScreen(song: song, player: player)),
            ),
          ),
          const SizedBox(width: 8),
          _pillButton(
            icon: Icons.radio,
            label: 'Radyo',
            onTap: () => player.playRadio(song),
          ),
          const SizedBox(width: 8),
          _pillButton(
            icon: Icons.library_music_outlined,
            label: 'Sıra',
            onTap: () => _showQueue(context, player),
          ),
          const SizedBox(width: 8),
          _pillButton(
            icon: Icons.high_quality,
            label: player.qualityLabel(),
            onTap: () => _showQualityDialog(context, player),
          ),
        ],
      ),
    );
  }

  Future<void> _showQualityDialog(
      BuildContext context, PlayerService player) async {
    final selected = await showDialog<AudioQuality>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.card,
        title: const Text('Ses kalitesi',
            style: TextStyle(color: AppColors.textPrimary)),
        children: AudioQuality.values.map((q) {
          final selected = q == player.quality;
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, q),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: selected ? AppColors.accent : AppColors.textSecondary,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(
                  switch (q) {
                    AudioQuality.auto => 'Otomatik',
                    AudioQuality.high => 'Yüksek',
                    AudioQuality.medium => 'Orta',
                    AudioQuality.low => 'Düşük',
                    AudioQuality.ultra => 'Ultra',
                  },
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (selected != null) await player.setQuality(selected);
  }

  Widget _pillButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: AppColors.accentBright),
                const SizedBox(width: 6),
                Text(label,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 12)),
              ],
            ),
          ),
        ),
      );

  void _showQueue(BuildContext context, PlayerService player) {
    final queue = player.queue;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.85,
        minChildSize: 0.3,
        builder: (ctx, scrollController) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text('Sırada',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800)),
            ),
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 20),
                    child: Text('${queue.length} şarkı',
                        style: TextStyle(
                            color: AppColors.textSecondary.withValues(alpha: .7),
                            fontSize: 12)),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.shuffle, size: 20,
                        color: AppColors.textSecondary),
                    onPressed: player.toggleShuffle,
                  ),
                  IconButton(
                    tooltip: player.autoplay ? 'Otomatik oynatma açık' : 'Otomatik oynatma kapalı',
                    icon: Icon(Icons.auto_awesome,
                        size: 20,
                        color: player.autoplay
                            ? AppColors.accentBright
                            : AppColors.textSecondary),
                    onPressed: player.toggleAutoplay,
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: queue.length,
                itemBuilder: (ctx, i) {
                  final s = queue[i];
                  final isCurrent = i == player.index;
                  return ListTile(
                    leading: isCurrent
                        ? const Icon(Icons.graphic_eq,
                            color: AppColors.accentBright)
                        : const Icon(Icons.music_note_outlined,
                            color: AppColors.textSecondary),
                    title: Text(s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent
                              ? AppColors.accentBright
                              : AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w500,
                        )),
                    subtitle: Text(s.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      player.jumpTo(i);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressBar(PlayerService player, Song song) => StreamBuilder<
          Duration>(
      stream: player.player.positionStream,
      builder: (context, posSnap) {
        final duration = player.player.duration ??
            Duration(milliseconds: song.durationMs);
        final pos = posSnap.data ?? Duration.zero;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: AppColors.textPrimary,
                  inactiveTrackColor: AppColors.cardLight,
                  thumbColor: AppColors.textPrimary,
                  overlayColor: Colors.white24,
                ),
                child: Slider(
                  min: 0,
                  max: duration.inMilliseconds
                      .clamp(1, double.infinity)
                      .toDouble(),
                  value: pos.inMilliseconds
                      .clamp(0, duration.inMilliseconds)
                      .toDouble(),
                  onChanged: (v) =>
                      player.player.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(pos),
                      style: TextStyle(
                          color: AppColors.textSecondary.withValues(alpha: .7),
                          fontSize: 11)),
                  Text(_fmt(duration),
                      style: TextStyle(
                          color: AppColors.textSecondary.withValues(alpha: .7),
                          fontSize: 11)),
                ],
              ),
            ],
          ),
        );
      });

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:$m' : m}:$s';
  }

  Widget _controls(PlayerService player) {
    final repeatIcon = switch (player.repeat) {
      RepeatMode.off => Icons.repeat,
      RepeatMode.all => Icons.repeat,
      RepeatMode.one => Icons.repeat_one,
    };
    final repeatActive = player.repeat != RepeatMode.off;
    final playing = !player.isLoading && player.player.playing;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            iconSize: 26,
            icon: Icon(Icons.shuffle,
                color: player.shuffle
                    ? AppColors.accentBright
                    : AppColors.textSecondary),
            onPressed: player.toggleShuffle,
          ),
          IconButton(
            iconSize: 38,
            icon: const Icon(Icons.skip_previous, color: AppColors.textPrimary),
            onPressed: player.previous,
          ),
          Stack(
            alignment: Alignment.center,
            children: [
              GestureDetector(
                onTap: () {
                  if (!player.isLoading) player.togglePlayPause();
                },
                child: CircleAvatar(
                  radius: 27,
                  backgroundColor: AppColors.textPrimary,
                  child: playing
                      ? const Icon(Icons.pause_rounded,
                          size: 34, color: AppColors.background)
                      : const Icon(Icons.play_arrow_rounded,
                          size: 36, color: AppColors.background),
                ),
              ),
              if (player.isLoading)
                const SizedBox(
                  width: 60,
                  height: 60,
                  child: CircularProgressIndicator(
                      strokeWidth: 3, color: AppColors.accentBright),
                ),
            ],
          ),
          IconButton(
            iconSize: 38,
            icon: const Icon(Icons.skip_next, color: AppColors.textPrimary),
            onPressed: () => player.next(),
          ),
          IconButton(
            iconSize: 26,
            icon: Icon(repeatIcon,
                color: repeatActive ? AppColors.accentBright : AppColors.textSecondary),
            onPressed: player.cycleRepeat,
          ),
        ],
      ),
    );
  }

  List<Color> _buildGradientColors(Song song) {
    try {
      // Try to extract dominant colors from album art
      final artUrl = song.thumbnailUrl;
      if (artUrl.isNotEmpty && !artUrl.startsWith('http')) {
        // Local file - get average color
        return [AppColors.background, AppColors.surface];
      }
      // For network images, use a warm gradient based on the song title hash
      final hash = artUrl.hashCode;
      final warmColors = [
        const Color(0xFF1A1A2E),
        const Color(0xFF16213E),
        const Color(0xFF0F3460),
      ];
      final coolColors = [
        const Color(0xFFE8DAEF),
        const Color(0xFFF5C5C7),
        const Color(0xFFF1C40F),
      ];
      // Simple hash-based color selection
      if (hash % 2 == 0) return warmColors.sublist(0, 2);
      return coolColors.sublist(0, 2);
    } catch (_) {
      return [AppColors.gradientTop, AppColors.background];
    }
  }

  Widget _footer(PlayerService player) => StreamBuilder<PlayerState>(
        stream: player.player.playerStateStream,
        builder: (context, snap) {
          final playing = snap.data?.playing ?? false;
          return Padding(
            padding: const EdgeInsets.only(bottom: 18, top: 6),
            child: Icon(
              playing ? Icons.graphic_eq : Icons.music_note_outlined,
              color: AppColors.accentBright.withValues(alpha: playing ? 1 : .35),
              size: 22,
            ),
          );
        },
      );
}
