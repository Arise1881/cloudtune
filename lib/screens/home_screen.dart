import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/connectivity_service.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';
import '../services/repair_bot_service.dart';
import '../services/room_service.dart';
import '../widgets/artwork.dart';
import '../widgets/song_tile.dart';
import 'library_screen.dart';
import 'now_playing_screen.dart';
import 'playlist_screen.dart';
import 'room_screen.dart';
import 'song_actions.dart';

/// Ana sayfa: selamlama, hızlı erişim kutucukları ve küratörlü bölümler.
/// Her 15 saniyede bir müzik listelerini yeniler.
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
    // Onarım botunu tetikle
    RepairBotService.instance.initialize();
    
    // Her 15 saniyede bir ana sayfayı yenile
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        setState(() {
          _refreshCounter++;
        });
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Ana sayfayı hemen yenile (yeni şarkılar getir).
  /// Önbellek boşaltılır: ana sayfa tuşuna her basışta TAZE şarkılar gelir.
  void refreshNow() {
    if (!mounted) return;
    MusicService.bustHomeCache();
    setState(() {
      _refreshCounter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<ConnectivityService>().isOffline;
    final library = context.watch<LibraryStore>();
    // Yenileme sayacı - her 15 saniyede bir artar
    final refreshTrigger = _refreshCounter;

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header(context)),
          if (offline) ...[
            const SliverToBoxAdapter(child: _OfflineHome()),
          ] else ...[
            SliverToBoxAdapter(child: _quickAccess(context, library)),
            SliverToBoxAdapter(child: _ForYouSection(refreshTrigger: refreshTrigger)),
            SliverToBoxAdapter(
              child: _TrendSection(
                title: 'Açık Katalogda Öne Çıkanlar',
                trending: true,
                refreshTrigger: refreshTrigger,
              ),
            ),
            for (final entry in curatedSections.entries) ...[
              const SliverToBoxAdapter(child: SizedBox(height: 4)),
              SliverToBoxAdapter(
                child: _TrendSection(
                  title: entry.key,
                  query: entry.value,
                  staggerMs: 250,
                  refreshTrigger: refreshTrigger,
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? 'İyi geceler'
        : hour < 12
            ? 'Günaydın'
            : hour < 18
                ? 'İyi günler'
                : 'İyi akşamlar';

    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.headlineMedium?.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Ne dinlemek istersin?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                ),
              ],
            ),
          ),
          Consumer<RoomService>(
            builder: (context, room, _) {
              final inRoom = room.roomId != null;
              return IconButton(
                tooltip: 'Odalar',
                icon: Icon(
                  inRoom ? Icons.groups : Icons.groups_outlined,
                  color: inRoom ? AppColors.accent : AppColors.textSecondary,
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RoomScreen(),
                    ),
                  );
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_outline,
                color: AppColors.textSecondary),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LibraryScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _quickAccess(BuildContext context, LibraryStore library) {
    final recents = library.recents;

    Widget pill(IconData icon, String label, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Material(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                height: 40,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: AppColors.accent),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        children: [
          pill(
            Icons.history,
            'Geçmiş',
            () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    PlaylistScreen(title: 'Dinleme Geçmişi', songs: recents),
              ),
            ),
          ),
          pill(
            Icons.download_outlined,
            'İndirilenler',
            () => LibraryScreen.openTab(context, 0),
          ),
          pill(
            Icons.all_inclusive,
            'Sonsuz Mix',
            () {
              context.read<PlayerService>().startInfiniteMix();
              Navigator.push(context, NowPlayingScreen.route(context));
            },
          ),
        ],
      ),
    );
  }
}

/// "Senin İçin": son dinlenen sanatçıdan taze öneriler.
/// Özelleştirme kalıcı geçmişten gelir; yeni şarkılar çekilir (tekrar yok).
class _ForYouSection extends StatefulWidget {
  const _ForYouSection({this.refreshTrigger});

  final int? refreshTrigger;

  @override
  State<_ForYouSection> createState() => _ForYouSectionState();
}

class _ForYouSectionState extends State<_ForYouSection> {
  late Future<List<Song>> _future;
  String _seedArtist = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _ForYouSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTrigger != oldWidget.refreshTrigger) {
      setState(() {
        _seedArtist = '';
        _future = _delayedLoad();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final recents = library.recents;
    if (recents.isEmpty) return const SizedBox.shrink();

    final latest = recents.reversed.first;
    final seed = library.favoriteArtist.isNotEmpty
        ? library.favoriteArtist
        : latest.artist;
    if (seed != _seedArtist) {
      _seedArtist = seed;
      _future = _load(seed, recents);
    }
    return FutureBuilder<List<Song>>(
      future: _future,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <Song>[];
        if (snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError &&
            songs.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Senin İçin',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (songs.isNotEmpty)
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PlaylistScreen(
                            title: 'Senin İçin',
                            songs: const [],
                            fetcher: (limit) => MusicService.instance
                                .artistSongs(_seedArtist, limit: limit),
                          ),
                        ),
                      ),
                      child: Text(
                        'Tümünü gör',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 212,
              child: switch (snapshot.connectionState) {
                ConnectionState.waiting =>
                  const Center(child: CircularProgressIndicator()),
                ConnectionState.done when snapshot.hasError =>
                  const SizedBox.shrink(),
                _ => ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: songs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => _TrendCard(
                      song: songs[i],
                      onTap: () {
                        final player = context.read<PlayerService>();
                        player.playForever(songs, startIndex: i);
                        Navigator.push(
                            context, NowPlayingScreen.route(context));
                      },
                    ),
                  ),
              },
            ),
          ],
        );
      },
    );
  }

  Future<List<Song>> _load(String artist, List<Song> recents) async {
    try {
      final songs = await MusicService.instance.artistSongs(artist, limit: 8);
      final known = recents.map((s) => s.id).toSet();
      return songs.where((s) => !known.contains(s.id)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Song>> _delayedLoad() async {
    final library = context.read<LibraryStore>();
    final recents = library.recents;
    if (recents.isEmpty) return const [];
    final latest = recents.reversed.first;
    final seed = library.favoriteArtist.isNotEmpty
        ? library.favoriteArtist
        : latest.artist;
    return _load(seed, recents);
  }
}

/// Küratörlü bölüm: sorguyla şarkıları çeker, yatay kart listesi gösterir.
class _TrendSection extends StatefulWidget {
  const _TrendSection({
    required this.title,
    this.query,
    this.trending = false,
    this.staggerMs = 0,
    this.refreshTrigger,
  });

  final String title;

  /// Sorgu tabanlı bölüm (boş olabilir).
  final String? query;

  /// true ise MusicService.trending() kullanır (query yerine).
  final bool trending;

  /// Aynı anda çok sorgu gitmesin — bölümler sırayla yüklenir.
  final int staggerMs;

  /// Yenileme tetikleyicisi — değiştiğinde bölümü yeniden yükler.
  final int? refreshTrigger;

  @override
  State<_TrendSection> createState() => _TrendSectionState();
}

class _TrendSectionState extends State<_TrendSection> {
  late Future<List<Song>> _future;

  @override
  void initState() {
    super.initState();
    _future = _delayedLoad();
  }

  @override
  void didUpdateWidget(covariant _TrendSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTrigger != oldWidget.refreshTrigger) {
      setState(() {
        _future = _delayedLoad();
      });
    }
  }

  Future<List<Song>> _delayedLoad() async {
    if (widget.staggerMs > 0) {
      await Future.delayed(Duration(milliseconds: widget.staggerMs));
    }
    if (!mounted) return const [];
    List<Song> songs;
    try {
      songs = widget.trending
          ? await MusicService.instance.trending(limit: 12)
          : await MusicService.instance.search(widget.query ?? '', limit: 12);
    } catch (e) {
      // Sessiz: hata kullanıcıya gösterilmez, onarım botu kaydeder.
      unawaited(RepairBotService.instance.reportEvent(
          RepairEventType.networkTimeout,
          'Ana sayfa bölümü yüklenemedi: ${widget.title}',
          {'section': widget.title, 'query': widget.query ?? ''}));
      return const [];
    }
    return songs;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Song>>(
      future: _future,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <Song>[];
        // Kaynaklarda sonuç yoksa tüm bölümü gizle (başlık + kutu) —
        // "Şarkı bulunamadı" dolu ana sayfa hissi vermez, boşluk bırakmaz.
        if (snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError &&
            songs.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (songs.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PlaylistScreen(
                                title: widget.title,
                                songs: songs,
                                fetcher: widget.trending
                                    ? (limit) => MusicService.instance.trending(limit: limit)
                                    : (limit) => MusicService.instance.search(widget.query ?? '', limit: limit)),
                          ),
                        );
                      },
                      child: Text(
                        'Tümünü gör',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 212,
              child: switch (snapshot.connectionState) {
                ConnectionState.waiting =>
                  const Center(child: CircularProgressIndicator()),
                // Sessiz hata: bölüm gizlenir (onarım botu kaydetti).
                ConnectionState.done when snapshot.hasError => const SizedBox.shrink(),
                ConnectionState.done when songs.isEmpty => const Center(
                    child: Text(
                      'Şarkı bulunamadı',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                _ => ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: songs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => _TrendCard(
                      song: songs[i],
                      onTap: () {
                        final player = context.read<PlayerService>();
                        player.playForever(songs, startIndex: i);
                        Navigator.push(context, NowPlayingScreen.route(context));
                      },
                    ),
                  ),
              },
            ),
          ],
        );
      },
    );
  }
}

class _TrendCard extends StatefulWidget {
  const _TrendCard({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  State<_TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<_TrendCard> {
  @override
  void initState() {
    super.initState();
    DownloadManager.instance.addListener(_onDownloadChanged);
  }

  @override
  void dispose() {
    DownloadManager.instance.removeListener(_onDownloadChanged);
    super.dispose();
  }

  void _onDownloadChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final library = context.read<LibraryStore>();
    final downloadState = downloadStateFor(
        song, library, DownloadManager.instance);

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Artwork(url: song.thumbnailUrl, size: 140, radius: 10),
                ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 34, height: 34),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () => downloadWithToast(context, song),
                    icon: _downloadIcon(downloadState),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Expanded: kalan alanı doldurur → kart asla 212px'i aşamaz
            // (RenderFlex overflow imkansız).
            Expanded(
              child: Text(
                song.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.artist,
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
  }

  Widget _downloadIcon(dynamic downloadState) {
    if (downloadState is bool && downloadState == true) {
      return const Icon(Icons.download_done,
          size: 18, color: AppColors.accentBright);
    }
    if (downloadState is double) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
            value: downloadState, strokeWidth: 2.5),
      );
    }
    return const Icon(Icons.download_outlined,
        size: 18, color: AppColors.accentBright);
  }
}

/// Çevrimdışıyken ana sayfa: yalnızca indirilen şarkılar listelenir.
class _OfflineHome extends StatelessWidget {
  const _OfflineHome();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final downloads = library.downloads;

    if (downloads.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Henüz indirilen şarkı yok',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: min(5, downloads.length),
      itemBuilder: (context, index) {
        final song = downloads[index];
        return ListTile(
          leading: const Icon(Icons.file_download, color: AppColors.accent),
          title: Text(song.title),
          subtitle: Text('${song.durationLabel} • ${song.artist}'),
        );
      },
    );
  }
}