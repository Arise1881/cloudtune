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
import '../services/haptic_service.dart';
import '../services/assistant_service.dart';
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

  /// Ana sayfayı hemen yenile (yeni şarkılar getir)
  void refreshNow() {
    if (mounted) {
      setState(() {
        _refreshCounter++;
      });
    }
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
            const SliverToBoxAdapter(child: _AssistantBar()),
            const SliverToBoxAdapter(child: _MoodAssistant()),
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

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            greeting,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Yenile butonu - yeni şarkılar getir
              IconButton(
                tooltip: 'Yeni şarkılar',
                icon: const Icon(Icons.refresh, color: AppColors.accent),
                onPressed: () {
                  HapticService.instance.light();
                  setState(() {
                    _refreshCounter++;
                  });
                },
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
                icon: const Icon(Icons.person, color: AppColors.textSecondary),
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
        ],
      ),
    );
  }

  Widget _quickAccess(BuildContext context, LibraryStore library) {
    final recents = library.recents;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          _songCard(
            context,
            title: 'Dinleme Geçmişi',
            subtitle: '${recents.length} şarkı',
            icon: Icons.history,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      PlaylistScreen(title: 'Dinleme Geçmişi', songs: recents),
                ),
              );
            },
          ),
          const SizedBox(width: 12),
          _songCard(
            context,
            title: 'İndirilenler',
            subtitle: '${library.downloads.length} şarkı',
            icon: Icons.download,
            onTap: () {
              LibraryScreen.openTab(context, 0);
            },
          ),
          const SizedBox(width: 12),
          _songCard(
            context,
            title: 'Sonsuz Karışık',
            subtitle: 'Tekrarsız, saatlerce',
            icon: Icons.all_inclusive,
            onTap: () {
              context.read<PlayerService>().startInfiniteMix();
              Navigator.push(context, NowPlayingScreen.route(context));
            },
          ),
        ],
      ),
    );
  }

  Widget _songCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.accent, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios,
                  size: 16, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sesli komut benzeri asistan çubuğu: "çal X", ruh hali kelimesi veya
/// serbest arama. Gerçek LLM yok — kural tabanlı, katalogdan çeker.
class _AssistantBar extends StatefulWidget {
  const _AssistantBar();

  @override
  State<_AssistantBar> createState() => _AssistantBarState();
}

class _AssistantBarState extends State<_AssistantBar> {
  final TextEditingController _controller = TextEditingController();

  static const _suggestions = ['çal sarkaç', 'sakin müzik', 'odak şarkıları'];

  static const _moodKeywords = [
    ('mutlu', 'Mutlu'),
    ('enerjik', 'Enerjik'),
    ('sakin', 'Sakin'),
    ('hüzünlü', 'Hüzünlü'),
    ('huzunlu', 'Hüzünlü'),
    ('odak', 'Odak'),
    ('gece', 'Gece'),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(String raw, BuildContext ctx) async {
    final query = raw.trim();
    if (query.isEmpty) return;
    _controller.clear();
    FocusScope.of(ctx).unfocus();

    final lower = query.toLowerCase();
    String mood = '';
    for (final (kw, name) in _moodKeywords) {
      if (lower.contains(kw)) {
        mood = name;
        break;
      }
    }
    if (mood.isNotEmpty) {
      _openSearch(ctx, '$mood şarkılar', '$mood Çalma Listesi');
      return;
    }

    final playPrefix = lower.startsWith('çal ') ? 'çal ' : (lower.startsWith('play ') ? 'play ' : null);
    if (playPrefix != null) {
      final songQuery = query.substring(playPrefix.length);
      if (songQuery.isEmpty) return;
      final player = PlayerService.instance;
      try {
        final songs = await MusicService.instance
            .search(songQuery, limit: 12)
            .timeout(const Duration(seconds: 20));
        if (songs.isEmpty) {
          if (ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                content: Text('Sonuç bulunamadı'),
                duration: Duration(seconds: 2)));
          }
          return;
        }
        player.playForever(songs, startIndex: 0);
        if (ctx.mounted) {
          Navigator.push(ctx, NowPlayingScreen.route(ctx));
        }
      } catch (_) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
              content: Text('Şarkı çekilemedi, tekrar dene'),
              duration: Duration(seconds: 2)));
        }
      }
      return;
    }

    _openSearch(ctx, query, '“$query” Sonuçları');
  }

  void _openSearch(BuildContext ctx, String query, String title) {
    Navigator.push(
      ctx,
      MaterialPageRoute(
        builder: (_) => PlaylistScreen(
          title: title,
          songs: const [],
          fetcher: (limit) =>
              MusicService.instance.search(query, limit: limit),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            onSubmitted: (v) => _run(v, context),
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Asistana sor: "çal sarkaç", "sakin müzik"...',
              hintStyle: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.auto_awesome,
                  size: 18, color: AppColors.accent),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Consumer<AssistantService>(
                    builder: (context, assistant, _) {
                      return IconButton(
                        icon: Icon(
                          assistant.isListening ? Icons.mic : Icons.mic_none,
                          size: 18,
                          color: assistant.isListening ? AppColors.accent : AppColors.textSecondary,
                        ),
                        onPressed: () async {
                          if (assistant.isListening) {
                            await assistant.stopConversation();
                          } else {
                            await assistant.startConversation();
                          }
                        },
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.send,
                        size: 18, color: AppColors.textSecondary),
                    onPressed: () => _run(_controller.text, context),
                  ),
                ],
              ),
              filled: true,
              fillColor: AppColors.cardLight,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF3A3A3A)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF3A3A3A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: AppColors.accent),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _suggestions
                .map((s) => ActionChip(
                      label: Text(s,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                      side: const BorderSide(color: Color(0xFF3A3A3A)),
                      backgroundColor: AppColors.cardLight,
                      onPressed: () => _run(s, context),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}

/// Ruh hali asistanı: kullanıcı ruh halini seçer, uygun şarkılar listelenir.
/// Gerçek LLM yok — sorgu tabanlı, önerilen müzik açık katalogdan çekilir.
class _MoodAssistant extends StatelessWidget {
  const _MoodAssistant();

  static const _moods = [
    (Icons.sentiment_very_satisfied, 'Mutlu'),
    (Icons.bolt, 'Enerjik'),
    (Icons.spa, 'Sakin'),
    (Icons.music_note, 'Hüzünlü'),
    (Icons.psychology_alt, 'Odak'),
    (Icons.nightlight_round, 'Gece'),
  ];

  void _openMood(BuildContext context, String mood) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistScreen(
          title: '$mood Çalma Listesi',
          songs: const [],
          fetcher: (limit) =>
              MusicService.instance.search('$mood şarkılar', limit: limit),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ruh Haline Göre Keşfet',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _moods
                .map((m) => ActionChip(
                      avatar: Icon(m.$1, size: 18, color: AppColors.accent),
                      label: Text(m.$2),
                      onPressed: () => _openMood(context, m.$2),
                    ))
                .toList(),
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
              height: 200,
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
              height: 200,
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
            Text(
              song.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
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