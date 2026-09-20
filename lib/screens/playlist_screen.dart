import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/library_store.dart';
import '../services/player_service.dart';
import '../services/repair_bot_service.dart';
import '../widgets/artwork.dart';
import 'now_playing_screen.dart';
import 'song_actions.dart';

/// Bir bölümün/çalma listesinin şarkı listesi ekranı.
/// [fetcher] verilirse "Daha Fazla" ile sunucudan kademeli yükleme yapılır;
/// verilmezse [songs] durağan olarak gösterilir.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({
    super.key,
    required this.title,
    required this.songs,
    this.playlistName,
    this.fetcher,
  });

  final String title;
  final List<Song> songs;

  /// Kitaplıktaki bir çalma listesinden geldiyse dolu; silme desteği için.
  final String? playlistName;

  /// Sunucu çalma listesi yüklemesi: limit büyütülerek tekrar çağrılır.
  final Future<List<Song>> Function(int limit)? fetcher;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  /// Sunucudan çekilen kısmi liste; [widget.songs] başlangıç değeri.
  List<Song> _loaded = const [];
  int _limit = 30;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loaded = widget.songs;
    if (widget.fetcher != null) _fetchMore();
  }

  Future<void> _fetchMore() async {
    final fetcher = widget.fetcher;
    if (fetcher == null) return;
    setState(() => _loading = true);
    try {
      final more = await fetcher(_limit);
      // Kuyrukta zaten olan şarkıları tekrar ekleme (id bazlı).
      final known = _loaded.map((s) => s.id).toSet();
      final fresh = more.where((s) => !known.contains(s.id)).toList();
      if (!mounted) return;
      setState(() {
        _loaded = [..._loaded, ...fresh];
        _loading = false;
      });
    } catch (_) {
      unawaited(RepairBotService.instance.reportEvent(
          RepairEventType.playlistParseFailed,
          'Çalma listesi yüklenemedi: ${widget.title}',
          {'limit': _limit}));
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _loadMore() {
    if (_loading) return;
    _limit = (_limit * 2).clamp(30, 600);
    _fetchMore();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final library = context.watch<LibraryStore>();

    // Çalma listesindeki güncel içerik (ekleme/çıkarma sonrası yansır).
    final effective = widget.playlistName != null
        ? (library.playlists[widget.playlistName] ?? _loaded)
        : _loaded;
    final hasFetcher = widget.fetcher != null;
    final isPlayingThis = player.current != null &&
        effective.any((s) => s.id == player.current!.id);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            backgroundColor: AppColors.gradientTop,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
              onPressed: () => Navigator.of(context).pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
              centerTitle: true,
              background: _HeaderBackground(
                  songs: effective, title: widget.title),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          isPlayingThis ? AppColors.accentBright : AppColors.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 26),
                    label: const Text('Çal',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    onPressed: effective.isEmpty
                        ? null
                        : () async {
                            try {
                              player.playQueue(effective);
                              if (context.mounted) {
                                Navigator.of(context)
                                    .push(NowPlayingScreen.route(context));
                              }
                            } catch (_) {}
                          },
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.white.withValues(alpha: .3)),
                      foregroundColor: AppColors.textPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    icon: const Icon(Icons.shuffle, size: 20),
                    label: const Text('Karıştır',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    onPressed: effective.isEmpty
                        ? null
                        : () async {
                            try {
                              if (!player.shuffle) player.toggleShuffle();
                              player.playQueue(effective);
                              if (context.mounted) {
                                Navigator.of(context)
                                    .push(NowPlayingScreen.route(context));
                              }
                            } catch (_) {}
                          },
                  ),
                ],
              ),
            ),
          ),
          if (hasFetcher && _loading && effective.isEmpty)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (effective.isEmpty)
            const SliverFillRemaining(
              child: Center(
                child: Text('Bu liste boş',
                    style: TextStyle(color: AppColors.textSecondary)),
              ),
            )
          else
            SliverList.builder(
              itemCount: effective.length +
                  (widget.playlistName != null ? 1 : 0) +
                  (hasFetcher ? 1 : 0),
              itemBuilder: (context, i) {
                // Çalma listesi satırı: listeden çıkarma aksiyonu.
                if (i == effective.length && widget.playlistName != null) {
                  return const SizedBox(height: 80);
                }
                // "Daha Fazla" butonu listenin sonunda.
                if (i >= effective.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: _loading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : OutlinedButton.icon(
                              onPressed: _loadMore,
                              icon: const Icon(Icons.keyboard_arrow_down),
                              label: const Text('Daha Fazla'),
                            ),
                    ),
                  );
                }
                final song = effective[i];
                final isCurrent = player.current?.id == song.id;
                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  leading: Artwork(url: song.thumbnailUrl, size: 48),
                  title: Text(song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: isCurrent
                              ? AppColors.accentBright
                              : AppColors.textPrimary,
                          fontWeight: FontWeight.w600)),
                  subtitle: Text('${song.artist} • ${song.durationLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textSecondary)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          library.isDownloaded(song.id)
                              ? Icons.download_done
                              : Icons.download_outlined,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                        tooltip: library.isDownloaded(song.id)
                            ? 'İndirilenlerde'
                            : 'İndir',
                        onPressed: () => downloadWithToast(context, song),
                      ),
                      if (widget.playlistName != null)
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline,
                              size: 20, color: AppColors.textSecondary),
                          onPressed: () => library
                              .removeFromPlaylist(widget.playlistName!, song.id),
                        ),
                    ],
                  ),
                  onTap: () async {
                    try {
                      await player.playSmart(effective, i);
                      if (context.mounted) {
                        Navigator.of(context)
                            .push(NowPlayingScreen.route(context));
                      }
                    } catch (_) {}
                  },
                );
              },
            ),
        ],
      ),
    );
  }
}

class _HeaderBackground extends StatelessWidget {
  const _HeaderBackground({required this.songs, required this.title});

  final List<Song> songs;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 52),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.gradientTop, Color(0xFF16301F)],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: songs.isNotEmpty
                ? Artwork(url: songs.first.thumbnailUrl, size: 120, radius: 8)
                : Container(
                    width: 120,
                    height: 120,
                    color: AppColors.card,
                    child: const Icon(Icons.music_note,
                        size: 40, color: AppColors.textSecondary)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        height: 1.1)),
                const SizedBox(height: 6),
                Text('${songs.length} şarkı • CloudTune Mix',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
