import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../constants.dart';
import '../models/search_content.dart';
import '../models/song.dart';
import '../services/connectivity_service.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';
import '../services/repair_bot_service.dart';
import '../widgets/artwork.dart';
import '../widgets/song_tile.dart';
import 'artist_screen.dart';
import 'now_playing_screen.dart';
import 'playlist_screen.dart';
import 'song_actions.dart';

enum _SearchTab { songs, artists, playlists }

/// Spotify klonu arama ekranı: canlı arama, son aramalar, kategoriler,
/// sesli arama ve Spotify kart görünümü.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;
  bool _speechInitialized = false;

  Timer? _debounce;
  List<Song> _results = [];
  List<SearchArtist> _artists = [];
  List<PlaylistInfo> _playlists = [];
  _SearchTab _tab = _SearchTab.songs;
  bool _searching = false;
  String? _error;
  List<String> _recent = [];

  bool get _micSupported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _recent = prefs.getStringList('recent_searches') ?? []);
  }

  Future<void> _saveRecent(String q) async {
    final prefs = await SharedPreferences.getInstance();
    _recent
      ..remove(q)
      ..insert(0, q);
    if (_recent.length > 8) _recent = _recent.sublist(0, 8);
    await prefs.setStringList('recent_searches', _recent);
    if (mounted) setState(() {});
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _results = [];
        _artists = [];
        _playlists = [];
        _error = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        MusicService.instance.search(query),
        MusicService.instance.searchArtists(query),
        MusicService.instance.searchPlaylists(query),
      ]);
      if (!mounted) return;
      setState(() {
        _results = results[0] as List<Song>;
        _artists = results[1] as List<SearchArtist>;
        _playlists = results[2] as List<PlaylistInfo>;
      });
      unawaited(_saveRecent(query));
    } catch (e) {
      if (!mounted) return;
      unawaited(RepairBotService.instance.reportEvent(
          RepairEventType.networkTimeout,
          'Arama başarısız: $query',
          {'query': query}));
      setState(() => _error = null);
      return;
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }
    try {
      if (!_speechInitialized) {
        _speechInitialized = await _speech.initialize();
      }
      if (!_speechInitialized) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Sesli arama bu cihazda kullanılamıyor.'),
            backgroundColor: AppColors.cardHover,
          ));
        }
        return;
      }
      setState(() => _isListening = true);
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 8),
        ),
        onResult: (result) {
          if (!mounted) return;
          if (result.finalResult) {
            final text = result.recognizedWords.trim();
            if (text.isNotEmpty) {
              _controller.text = text;
              _search(text);
              _focus.unfocus();
            }
            setState(() => _isListening = false);
          }
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isListening = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Sesli arama başlatılamadı.'),
        backgroundColor: AppColors.cardHover,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<ConnectivityService>().isOffline;
    final accent = AppColors.accent;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Arama çubuğu (sabit üst).
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  readOnly: offline,
                  enabled: !offline,
                  onChanged: _onQueryChanged,
                  onSubmitted: (q) => _search(q),
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                  cursorColor: accent,
                  decoration: InputDecoration(
                    hintText: offline
                        ? 'Çevrimdışıyken arama kapalı'
                        : AppStrings.searchHint,
                    hintStyle: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 15,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      color: AppColors.textSecondary,
                      size: 22,
                    ),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_micSupported)
                          IconButton(
                            tooltip: _isListening
                                ? 'Dinleniyor…'
                                : 'Sesli ara',
                            icon: Icon(
                              _isListening ? Icons.mic : Icons.mic_none,
                              size: 20,
                              color: _isListening ? accent : AppColors.textSecondary,
                            ),
                            onPressed: _toggleListening,
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            size: 20,
                            color: AppColors.textSecondary,
                          ),
                          onPressed: () {
                            _controller.clear();
                            _onQueryChanged('');
                          },
                        ),
                      ],
                    ),
                    filled: true,
                    fillColor: AppColors.card,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide(color: accent, width: 1.5),
                    ),
                  ),
                ),
              ),
            ),

            if (!offline && _controller.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(
                  children: [
                    _tabChip(_SearchTab.songs, 'Şarkılar', Icons.music_note,
                        _results.length),
                    const SizedBox(width: 8),
                    _tabChip(_SearchTab.artists, 'Sanatçılar', Icons.person,
                        _artists.length),
                    const SizedBox(width: 8),
                    _tabChip(_SearchTab.playlists, 'Çalma listeleri',
                        Icons.queue_music, _playlists.length),
                    const SizedBox(width: 8),
                    _tabChip(_SearchTab.songs, 'Albümler', Icons.album, 0),
                  ],
                ),
              ),

            Expanded(
              child: offline
                  ? _offlineState()
                  : _buildBody(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabChip(_SearchTab tab, String label, IconData icon, int count) {
    final selected = _tab == tab;
    final accent = AppColors.accent;
    return FilterChip(
      label: Text('$label ($count)',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          )),
      avatar: Icon(icon, size: 16, color: selected ? AppColors.background : null),
      selected: selected,
      selectedColor: accent,
      checkmarkColor: Colors.black,
      backgroundColor: AppColors.card,
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
      padding: EdgeInsets.zero,
      onSelected: (_) => setState(() => _tab = tab),
    );
  }

  Widget _buildBody() {
    if (_searching) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accentBright),
      );
    }
    if (_error != null) {
      return _message(icon: Icons.wifi_off_rounded, text: _error!);
    }
    if (_controller.text.isEmpty) {
      return _emptyState();
    }

    switch (_tab) {
      case _SearchTab.songs:
        return _buildSongs();
      case _SearchTab.artists:
        return _buildArtists();
      case _SearchTab.playlists:
        return _buildPlaylists();
    }
  }

  // ─── Boş durum (son aramalar + öneriler) ───

  Widget _emptyState() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_recent.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              'Son aramalar',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(width: 4),
              TextButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.remove('recent_searches');
                  setState(() => _recent = []);
                },
                child: const Text(
                  'Temizle',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          ..._recent.map((q) => _recentItem(q)),
        ] else ...[
          _message(
            icon: Icons.search_off,
            text: 'Aramak için bir şeyler yazın',
          ),
        ],
      ],
    );
  }

  Widget _recentItem(String q) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(
        Icons.history,
        color: AppColors.textSecondary,
        size: 20,
      ),
      title: Text(
        q,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      trailing: const Icon(
        Icons.access_time,
        color: AppColors.textSecondary,
        size: 16,
      ),
      onTap: () {
        _controller.text = q;
        _search(q);
      },
    );
  }

  // ─── Şarkılar ───

  Widget _buildSongs() {
    if (_results.isEmpty) {
      return _message(icon: Icons.search_off, text: AppStrings.noResults);
    }
    final player = context.read<PlayerService>();
    final library = context.watch<LibraryStore>();
    final downloads = context.watch<DownloadManager>();
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final song = _results[i];
        final isCurrent = player.current?.id == song.id;
        final isDownloaded = library.isDownloaded(song.id);
        final progress = downloads.progress[song.id];
        return SpotifySongTile(
          song: song,
          index: i,
          selected: isCurrent,
          downloadState: isDownloaded
              ? true
              : (downloads.isDownloading(song.id)
                  ? (progress ?? 0.0)
                  : const NoDownloadState()),
          onDownloadTap: () {
            if (isDownloaded) {
              _showDownloadedSnack();
            } else if (!downloads.isDownloading(song.id)) {
              downloadWithToast(context, song);
            }
          },
          onTap: () async {
            try {
              player.playQueue(_results, startIndex: i);
              if (!context.mounted) return;
              Navigator.of(context).push(NowPlayingScreen.route(context));
            } catch (_) {}
          },
          onMenuTap: () => showSongActions(context, song),
        );
      },
    );
  }

  // ─── Sanatçılar ───

  Widget _buildArtists() {
    if (_artists.isEmpty) {
      return _message(icon: Icons.person_search, text: 'Sanatçı bulunamadı');
    }
    return ListView.builder(
      itemCount: _artists.length,
      itemBuilder: (_, i) {
        final a = _artists[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: CircleAvatar(
            radius: 24,
            backgroundColor: AppColors.cardHover,
            backgroundImage:
                a.thumbnailUrl.isNotEmpty ? NetworkImage(a.thumbnailUrl) : null,
            child: a.thumbnailUrl.isEmpty
                ? const Icon(Icons.person, color: AppColors.textSecondary)
                : null,
          ),
          title: Text(
            a.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          subtitle: Text(
            a.subscriberLabel,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          trailing: Icon(
            Icons.play_circle_outline,
            color: AppColors.textSecondary,
            size: 24,
          ),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) =>
                  ArtistScreen(name: a.name, thumbnailUrl: a.thumbnailUrl),
            ));
          },
        );
      },
    );
  }

  // ─── Çalma listeleri ───

  Widget _buildPlaylists() {
    if (_playlists.isEmpty) {
      return _message(icon: Icons.queue_music, text: 'Çalma listesi bulunamadı');
    }
    return ListView.builder(
      itemCount: _playlists.length,
      itemBuilder: (_, i) {
        final p = _playlists[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Artwork(url: p.thumbnailUrl, size: 48),
            ),
          ),
          title: Text(
            p.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          subtitle: Text(
            '${p.videoCount} şarkı',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          trailing: Icon(
            Icons.play_circle_outline,
            color: AppColors.textSecondary,
            size: 24,
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PlaylistScreen(
              title: p.title,
              songs: const [],
              fetcher: (limit) => MusicService.instance
                  .playlistSongs(p.id, limit: limit)
                  .timeout(const Duration(seconds: 30)),
            ),
          )),
        );
      },
    );
  }

  void _showDownloadedSnack() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Bu şarkı zaten indirildi.'),
        backgroundColor: AppColors.cardHover,
        duration: Duration(seconds: 2),
      ));
  }

  Widget _offlineState() =>
      _message(icon: Icons.cloud_off_outlined, text: AppStrings.offlineMessage);

  Widget _message({required IconData icon, required String text}) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.textSecondary),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 15,
              ),
            ),
          ],
        ),
      );

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _speech.stop();
    super.dispose();
  }
}

/// Spotify tarzı şarkı satırı (numara + kapak + başlık + sanatçı + süre).
class SpotifySongTile extends StatelessWidget {
  const SpotifySongTile({
    super.key,
    required this.song,
    required this.index,
    this.selected = false,
    this.downloadState,
    this.onDownloadTap,
    this.onTap,
    this.onMenuTap,
  });

  final Song song;
  final int index;
  final bool selected;
  final dynamic downloadState;
  final VoidCallback? onDownloadTap;
  final VoidCallback? onTap;
  final VoidCallback? onMenuTap;

  @override
  Widget build(BuildContext context) {
    final isDownloaded = downloadState is bool && downloadState == true;
    final isDownloading = downloadState is double;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.cardHover,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Artwork(
              url: song.thumbnailUrl,
              size: 44,
              radius: 6,
            ),
          ),
          if (selected)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.background,
                    width: 2,
                  ),
                ),
                child: const Icon(
                  Icons.play_circle_fill,
                  color: Colors.black,
                  size: 12,
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Text(
            '${index + 1}',
            style: TextStyle(
              color: selected ? AppColors.accent : AppColors.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
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
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDownloading)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                value: downloadState,
                strokeWidth: 2,
                valueColor: const AlwaysStoppedAnimation(AppColors.accent),
              ),
            )
          else if (isDownloaded)
            const Icon(
              Icons.download_done,
              color: AppColors.accent,
              size: 20,
            )
          else
            IconButton(
              icon: const Icon(
                Icons.add,
                color: AppColors.textSecondary,
                size: 20,
              ),
              onPressed: onDownloadTap,
              tooltip: AppStrings.addToPlaylist,
            ),
          const SizedBox(width: 4),
          Text(
            song.durationLabel,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              isDownloaded ? Icons.download_done : Icons.more_vert,
              color: AppColors.textSecondary,
              size: 20,
            ),
            onPressed: onMenuTap,
            tooltip: isDownloaded ? 'İndirildi' : 'Daha fazla',
          ),
        ],
      ),
      selected: selected,
      selectedTileColor: AppColors.cardHover,
      onTap: onTap,
      onLongPress: onMenuTap,
    );
  }
}
