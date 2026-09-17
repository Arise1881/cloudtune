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
import '../widgets/artwork.dart';
import '../widgets/song_tile.dart';
import 'artist_screen.dart';
import 'now_playing_screen.dart';
import 'playlist_screen.dart';
import 'song_actions.dart';

enum _SearchTab { songs, artists, playlists }

/// Arama ekranı: debounce'lu canlı arama + sesli arama + kategoriler.
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
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(q));
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
      setState(() => _error = 'Arama başarısız oldu. Bağlantını kontrol et.');
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
        _snack('Sesli arama bu cihazda kullanılamıyor.');
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
      _snack('Sesli arama başlatılamadı.');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<ConnectivityService>().isOffline;

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Text(AppStrings.appName,
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              readOnly: offline,
              enabled: !offline,
              onChanged: _onQueryChanged,
              onSubmitted: (q) => _search(q),
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: Colors.black87, fontSize: 15),
              cursorColor: Colors.black54,
              decoration: InputDecoration(
                hintText:
                    offline ? 'Çevrimdışıyken arama kapalı' : AppStrings.searchHint,
                hintStyle: const TextStyle(color: AppColors.textSecondary),
                prefixIcon:
                    const Icon(Icons.search, color: AppColors.textSecondary),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_micSupported)
                      IconButton(
                        tooltip: _isListening
                            ? 'Dinleniyor…'
                            : 'Sesli ara (mikrofon)',
                        icon: Icon(_isListening ? Icons.mic : Icons.mic_none,
                            size: 20,
                            color: _isListening
                                ? AppColors.accent
                                : AppColors.textSecondary),
                        onPressed: _toggleListening,
                      ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 20, color: AppColors.textSecondary),
                      onPressed: () {
                        _controller.clear();
                        _onQueryChanged('');
                      },
                    ),
                  ],
                ),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (!offline && _controller.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
    );
  }

  Widget _tabChip(_SearchTab tab, String label, IconData icon, int count) {
    final selected = _tab == tab;
    return ChoiceChip(
      selected: selected,
      avatar: Icon(icon, size: 16, color: selected ? AppColors.background : null),
      label: Text('$label ($count)'),
      labelStyle: TextStyle(
          fontSize: 12,
          color: selected ? AppColors.background : AppColors.textSecondary),
      selectedColor: AppColors.accent,
      backgroundColor: AppColors.card,
      showCheckmark: false,
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
      if (_recent.isEmpty) {
        return _message(icon: Icons.music_note_outlined, text: AppStrings.emptySearch);
      }
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Son aramalar',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              TextButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.remove('recent_searches');
                  setState(() => _recent = []);
                },
                child: const Text('Temizle'),
              ),
            ],
          ),
          ..._recent.map((q) => ListTile(
                leading: const Icon(Icons.history,
                    color: AppColors.textSecondary),
                title: Text(q,
                    style: const TextStyle(color: AppColors.textPrimary)),
                onTap: () {
                  _controller.text = q;
                  _search(q);
                },
              )),
        ],
      );
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

  Widget _buildSongs() {
    if (_results.isEmpty) {
      return _message(icon: Icons.search_off, text: AppStrings.noResults);
    }
    final player = context.read<PlayerService>();
    final downloads = context.watch<DownloadManager>();
    final library = context.watch<LibraryStore>();
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final song = _results[i];
        final isCurrent = player.current?.id == song.id;
        final isDownloaded = library.isDownloaded(song.id);
        final progress = downloads.progress[song.id];
        return SongTile(
          song: song,
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
              downloads.download(song).catchError((_) {});
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

  Widget _buildArtists() {
    final artists = _artists;
    if (artists.isEmpty) {
      return _message(icon: Icons.person_search, text: 'Sanatçı bulunamadı');
    }
    return ListView.builder(
      itemCount: artists.length,
      itemBuilder: (_, i) {
        final a = artists[i];
        return ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.cardLight,
            backgroundImage:
                a.thumbnailUrl.isNotEmpty ? NetworkImage(a.thumbnailUrl) : null,
            child: a.thumbnailUrl.isEmpty
                ? const Icon(Icons.person, color: AppColors.textSecondary)
                : null,
          ),
          title: Text(a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
          subtitle: const Text('Sanatçı',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
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

  Widget _buildPlaylists() {
    final playlists = _playlists;
    if (playlists.isEmpty) {
      return _message(icon: Icons.queue_music, text: 'Çalma listesi bulunamadı');
    }
    return ListView.builder(
      itemCount: playlists.length,
      itemBuilder: (_, i) {
        final p = playlists[i];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Artwork(url: p.thumbnailUrl, size: 44),
            ),
          ),
          title: Text(p.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
          subtitle: Text('${p.videoCount} şarkı',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          trailing: const Icon(Icons.play_circle_outline,
              color: AppColors.textSecondary),
          onTap: () async {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Çalma listesi yükleniyor…'),
              duration: Duration(seconds: 1),
            ));
            try {
              final songs = await MusicService.instance
                  .playlistSongs(p.id)
                  .timeout(const Duration(seconds: 30));
              if (!mounted) return;
              if (songs.isEmpty) {
                _snack('Çalma listesi boş.');
                return;
              }
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PlaylistScreen(
                  title: p.title,
                  songs: songs,
                ),
              ));
            } catch (_) {
              if (mounted) _snack('Çalma listesi yüklenemedi.');
            }
          },
        );
      },
    );
  }

  void _showDownloadedSnack() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Bu şarkı zaten indirildi.'),
        duration: Duration(seconds: 2),
      ));
  }

  Widget _offlineState() =>
      _message(icon: Icons.cloud_off_outlined, text: AppStrings.offlineMessage);

  Widget _message({required IconData icon, required String text}) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: AppColors.textSecondary),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 15)),
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