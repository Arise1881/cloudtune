import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/library_store.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';
import '../services/repair_bot_service.dart';
import '../widgets/artwork.dart';
import '../widgets/update_banner.dart';
import 'library_screen.dart';
import 'now_playing_screen.dart';
import 'playlist_screen.dart';

/// Ana sayfa: selamlama, Son Çalınanlar sade listesi, alt boşluk.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  Timer? _refreshTimer;
  int _refreshCounter = 0;

  @override
  void initState() {
    super.initState();
    RepairBotService.instance.initialize();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() => _refreshCounter++);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void refreshNow() {
    if (!mounted) return;
    MusicService.bustHomeCache();
    setState(() => _refreshCounter++);
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 6) return 'İyi geceler';
    if (h < 12) return 'Günaydın';
    if (h < 18) return 'İyi günler';
    return 'İyi akşamlar';
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: UpdateBanner()),

          // Sabit üst bar: selamlama + ikonlar (kaydırılmaz).
          SliverPersistentHeader(
            pinned: true,
            delegate: _HeaderDelegate(
              greeting: _greeting(),
              onRefresh: refreshNow,
            ),
          ),

          // Boşluk (header aşağıda kalsın diye).
          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // Son Çalınanlar (sade liste).
          const SliverToBoxAdapter(child: SizedBox(height: 4)),
          if (library.recents.isNotEmpty)
            SliverToBoxAdapter(
              child: _sectionRow(
                title: AppStrings.recentlyPlayed,
                subtitle: '${library.recents.length} şarkı',
                onAll: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlaylistScreen(
                      title: 'Son Çalınanlar',
                      songs: library.recents,
                      fetcher: (_) => Future.value(library.recents),
                    ),
                  ),
                ),
                children: _songChips(context, library.recents.take(6).toList()),
              ),
            ),

          // Alt boşluk (mini player için).
          const SliverToBoxAdapter(child: SizedBox(height: 90)),
        ],
      ),
    );
  }

  // ─── Şarkı kareleri (yatay) ───

  Widget _sectionRow({
    required String title,
    required String subtitle,
    required VoidCallback onAll,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextButton(
                onPressed: onAll,
                child: const Text(
                  'Tümünü gör',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 220,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: children,
          ),
        ),
      ],
    );
  }

  List<Widget> _songChips(BuildContext context, List<Song> songs) {
    final player = context.read<PlayerService>();
    return songs.map((s) {
      return GestureDetector(
        onTap: () {
          player.playQueue(songs, startIndex: songs.indexOf(s));
          Navigator.push(context, NowPlayingScreen.route(context));
        },
        child: SizedBox(
          width: 150,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Artwork(
                      url: s.thumbnailUrl,
                      size: 150,
                      radius: 10,
                    ),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        s.durationLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                s.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}

// ─── Sabit başlatma ───

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HeaderDelegate({
    required this.greeting,
    required this.onRefresh,
  });

  final String greeting;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  greeting,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Ne dinlemek istersin?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.accent, size: 22),
            tooltip: 'Yenile',
            onPressed: onRefresh,
          ),
          IconButton(
            icon: const Icon(Icons.person_outline, color: AppColors.textSecondary, size: 22),
            tooltip: 'Kütüphane',
            onPressed: () => LibraryScreen.openTab(context, 0),
          ),
        ],
      ),
    );
  }

  @override
  double get maxExtent => 100;

  @override
  double get minExtent => 80;

  @override
  bool shouldRebuild(covariant _HeaderDelegate old) =>
      old.greeting != greeting;
}
