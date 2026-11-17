import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/download_service.dart';
import '../core/link_handler.dart';
import '../core/link_resolver.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/repair_bot.dart';
import '../core/room_service.dart';
import '../core/theme_state.dart';
import '../core/update_service.dart';
import '../core/youtube_service.dart';
import '../screens/artist_page.dart';
import '../screens/downloads_page.dart';
import '../screens/my_playlists_page.dart';
import '../screens/playlist_page.dart';
import '../screens/room_page.dart';
import '../screens/settings_screen.dart';
import 'mini_player.dart';

/// One horizontal recommendation row on the home feed.
class _FeedSource {
  const _FeedSource(this.title, this.query, {this.isPlaylist = false});

  final String title;
  final String query;
  final bool isPlaylist;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final SpeechToText _speech = SpeechToText();

  late List<_FeedSource> _feed;
  late Map<String, Future<List<Track>>> _feedFutures;

  Timer? _feedTimer;
  Timer? _playlistTimer;

  List<Track>? _results;
  bool _busy = false;
  bool _listening = false;
  bool _showHistory = false;
  bool _prefetched = false;
  bool _speechReady = false;
  bool _voiceSubmitDone = false;
  bool _voiceFallbackTried = false;
  bool _pausedForVoice = false;
  String _voiceLocale = 'tr-TR';
  Track? _lastTrack;

  @override
  void initState() {
    super.initState();
    Library.instance.addListener(_onLibraryChanged);
    PlayerController.instance.addListener(_onPlayerChanged);
    _prepareFeed();

    _feedTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && _results == null) setState(_reloadFeeds);
    });
    _playlistTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _results == null) _syncPlaylistSources();
    });
  }

  @override
  void dispose() {
    Library.instance.removeListener(_onLibraryChanged);
    PlayerController.instance.removeListener(_onPlayerChanged);
    unawaited(_restorePlaybackAfterVoice());
    unawaited(_speech.cancel());
    _feedTimer?.cancel();
    _playlistTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _prepareFeed() {
    final library = Library.instance;
    final sources = <_FeedSource>[];

    final top = library.topArtist;
    if (top != null) {
      sources.add(_FeedSource('$top senin için', '$top en iyi şarkılar'));
    }

    final liked = library.liked;
    if (liked.isNotEmpty && liked.first.artist.isNotEmpty) {
      sources.add(
        _FeedSource(
          '${liked.first.artist} & benzerleri',
          '${liked.first.artist} benzer sanatçılar',
        ),
      );
    }

    for (final name in library.playlistNames) {
      sources.add(_FeedSource(name, name, isPlaylist: true));
    }

    sources.addAll(const [
      _FeedSource('🇹🇷 Türkçe Pop', 'türkçe pop müzik 2026'),
      _FeedSource('🎤 Türkçe Rap & Hip-Hop', 'türkçe rap hit şarkılar'),
      _FeedSource('🎸 Rock', 'rock müzik en iyi şarkılar'),
      _FeedSource('🌙 Lo-fi & Chill', 'lofi chill müzik'),
      _FeedSource('🌍 Dünya Hitleri', 'top global hits 2026'),
      _FeedSource('🎵 Akustik', 'akustik türkçe şarkılar'),
      _FeedSource('🎧 90\'lar ve 2000\'ler', '90lar 2000ler türkçe şarkılar'),
      _FeedSource('💃 Dans & Elektronik', 'dans elektronik müzik 2026'),
    ]);

    _feed = sources;
    _reloadFeeds();
  }

  void _reloadFeeds() {
    _feedFutures = {
      for (final source in _feed)
        source.title: _load(source.query, isPlaylist: source.isPlaylist),
    };
  }

  void _syncPlaylistSources() {
    final names = Library.instance.playlistNames.toSet();
    final shown = _feed
        .where((source) => source.isPlaylist)
        .map((source) => source.title)
        .toSet();

    for (final name in names) {
      if (!shown.contains(name)) {
        _feed.add(_FeedSource(name, name, isPlaylist: true));
      }
    }
    _feed.removeWhere(
      (source) => source.isPlaylist && !names.contains(source.title),
    );
    setState(_reloadFeeds);
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    setState(_prepareFeed);
  }

  void _onPlayerChanged() {
    final track = PlayerController.instance.current;
    if (track?.id == _lastTrack?.id) return;
    _lastTrack = track;
    if (track != null && mounted) setState(_buildFeed);
  }

  Future<List<Track>> _load(String query, {bool isPlaylist = false}) async {
    if (isPlaylist) {
      final saved = Library.instance.getPlaylist(query);
      if (saved.isNotEmpty) {
        _prefetchOnce(saved.first.id);
        return saved;
      }
      return YoutubeService.instance.search(query, limit: 15);
    }

    final tracks = await YoutubeService.instance.search(query, limit: 15);
    if (tracks.isNotEmpty) _prefetchOnce(tracks.first.id);
    return tracks;
  }

  void _prefetchOnce(String id) {
    if (_prefetched) return;
    _prefetched = true;
    unawaited(YoutubeService.instance.prefetch(id));
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 6) return 'İyi geceler';
    if (hour < 12) return 'Günaydın';
    if (hour < 18) return 'İyi günler';
    return 'İyi akşamlar';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _submit(String text) async {
    final value = text.trim();
    if (value.isEmpty) {
      setState(() => _results = null);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _showHistory = false);

    if (YoutubeLinkResolver.isYoutubeLink(value)) {
      final playlistId = YoutubeLinkResolver.playlistId(value);
      final videoId = YoutubeLinkResolver.videoId(value);
      if (playlistId != null && videoId == null) {
        _input.clear();
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PlaylistPage(id: playlistId)),
        );
        return;
      }

      final opened = await LinkHandler.open(value);
      if (opened) {
        _input.clear();
      } else {
        RepairBot.instance.reportEvent('link_open_failed', {'link': value});
      }
      return;
    }

    setState(() => _busy = true);
    try {
      final found = await YoutubeService.instance.search(value);
      if (mounted) setState(() => _results = found);
      if (found.isEmpty) _toast('Sonuç bulunamadı.');
      await Library.instance.addSearchHistory(value);
    } catch (_) {
      RepairBot.instance.reportEvent('search_failed', {'query': value});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _toast('Panoda bağlantı yok.');
      return;
    }
    _input.text = text;
    await _submit(text);
  }

  /// Mikrofon açıldığında duraklatılan müziği geri verir. `play()` toggle
  /// olduğu için PlayerController.resume() kullanılır.
  Future<void> _restorePlaybackAfterVoice() async {
    if (!_pausedForVoice) return;
    _pausedForVoice = false;
    try {
      await PlayerController.instance.resume();
    } catch (_) {}
  }

  Future<void> _stopVoice() async {
    try {
      await _speech.stop();
    } catch (_) {}
    unawaited(_restorePlaybackAfterVoice());
    if (mounted) setState(() => _listening = false);
  }

  void _onVoiceResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (text.isEmpty || !mounted) return;
    if (!result.finalResult) {
      _input.text = text;
      return;
    }
    if (_voiceSubmitDone) return;
    _voiceSubmitDone = true;
    _input.text = text;
    unawaited(_stopVoice());
    unawaited(_submit(text));
  }

  Future<void> _startListening(String localeId) async {
    _voiceLocale = localeId;
    try {
      // 7.x API'sinde listen() hata callback'i almaz; hata initialize()
      // sırasında verilen errorListener üzerinden gelir (bkz. _toggleVoice).
      await _speech.listen(
        onResult: _onVoiceResult,
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          partialResults: true,
          cancelOnError: false,
          pauseFor: const Duration(milliseconds: 700),
          listenFor: const Duration(seconds: 30),
        ),
      );
      if (mounted) setState(() => _listening = true);
    } catch (_) {
      if (!_voiceFallbackTried && localeId == 'tr-TR') {
        _voiceFallbackTried = true;
        await _startListening('');
        return;
      }
      _voiceError('Sesli arama başlatılamadı.');
      unawaited(_stopVoice());
    }
  }

  Future<void> _toggleVoice() async {
    if (_listening) {
      await _stopVoice();
      return;
    }

    if (!_speechReady) {
      // speech_to_text izni initialize() sırasında ister; hasPermission
      // yalnızca mevcut durumu okur. Bu yüzden önce initialize çağrılır.
      final available = await _speech.initialize(
        onError: (e) {
          // Bazı cihazlarda tr-TR ses verisi yoktur. Bir kez cihazın varsayılan
          // locale'ine düşerek sesli aramayı çalışır tut.
          if (!_voiceFallbackTried && _voiceLocale == 'tr-TR') {
            _voiceFallbackTried = true;
            unawaited(_startListening(''));
            return;
          }
          _voiceError(e.errorMsg);
          unawaited(_stopVoice());
        },
        onStatus: (s) {
          if (s == 'done' || s == 'notListening' || s == 'aborted') {
            if (mounted) setState(() => _listening = false);
            unawaited(_restorePlaybackAfterVoice());
          }
        },
      );
      if (!available) {
        final hasPermission = await _speech.hasPermission;
        _toast(
          hasPermission
              ? 'Sesli arama kullanılamıyor.'
              : 'Mikrofon izni gerekli.',
        );
        return;
      }
      _speechReady = true;
    }

    // Müzik çalarken mikrofon şarkıyı duyuyor, tanıma başarısız oluyordu.
    if (PlayerController.instance.playing) {
      await PlayerController.instance.pause();
      _pausedForVoice = true;
    }

    _voiceSubmitDone = false;
    _voiceFallbackTried = false;
    await _startListening('tr-TR');
  }

  void _voiceError(String msg) {
    _toast(msg);
    if (mounted) setState(() => _listening = false);
  }

  void _openArtist(Track track) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistPage(
          name: track.artist,
          channelId: track.artistId,
          seedTrack: track,
        ),
      ),
    );
  }

  void _playSaved(Track track) {
    PlayerController.instance.playQueue([track], 0, radio: false);
  }

  void _playAllSaved() {
    final tracks = DownloadService.instance.savedTracks;
    if (tracks.isNotEmpty) {
      PlayerController.instance.playQueue(tracks, 0, radio: false);
    }
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController(
      text: 'Çalma Listesi ${Library.instance.playlistNames.length + 1}',
    );
    final sources = <String, List<Track>>{
      'Çalındı': PlayerController.instance.tracks,
      'Beğenilenler': Library.instance.liked,
      'İndirilenler': DownloadService.instance.savedTracks,
    };
    final labels = sources.keys.toList();
    var selected = 0;

    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Çalma listesi oluştur'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Liste adı'),
            ),
            const SizedBox(height: 12),
            StatefulBuilder(
              builder: (context, setDialogState) => RadioGroup<int>(
                groupValue: selected,
                onChanged: (value) {
                  if (value != null) {
                    setDialogState(() => selected = value);
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      ListTile(
                        title: Text(labels[i]),
                        leading: Radio<int>(value: i),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('İptal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Oluştur'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name == null || name.isEmpty) return;
    final source = sources[labels[selected]]!;
    if (source.isEmpty) {
      _toast('Bu kaynakta şarkı yok.');
      return;
    }
    await Library.instance.createPlaylist(name, source);
    _toast('Liste oluşturuldu: $name');
  }

  void _returnHome() {
    setState(() {
      _results = null;
      _input.clear();
      _prepareFeed();
    });
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(),
            _searchArea(),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            _roomBanner(),
            Expanded(
              child: _results != null
                  ? _buildResults()
                  : ListenableBuilder(
                      listenable: DownloadService.instance,
                      builder: (context, _) => _buildFeed(),
                    ),
            ),
            const MiniPlayer(),
            _navBar(),
          ],
        ),
      ),
    );
  }

  Widget _navBar() {
    final accent = ThemeState.value;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF181818),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          _navItem(Icons.home, 'Ana Sayfa', true, accent, _returnHome),
          _navItem(Icons.groups, 'Odalar', false, accent, () => _openRooms()),
          _navItem(Icons.favorite_border, 'Kitaplığım', false, accent,
              () => _openRooms(tab: 1)),
          _navItem(Icons.settings_outlined, 'Ayarlar', false, accent, () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
          }),
        ],
      ),
    );
  }

  Widget _navItem(
    IconData icon,
    String label,
    bool active,
    Color accent,
    VoidCallback onTap,
  ) {
    final color = active ? accent : Colors.white60;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 10,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  void _openRooms({int tab = 0}) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RoomPage(initialTab: tab)),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
      child: Row(
        children: [
          Text(
            _greeting,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Çalma listesi oluştur',
            icon: const Icon(Icons.playlist_add),
            onPressed: _createPlaylist,
          ),
          IconButton(
            tooltip: 'Oluşturulan çalma listeleri',
            icon: const Icon(Icons.playlist_play),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MyPlaylistsPage()),
            ),
          ),
          IconButton(
            tooltip: 'İndirilenler',
            icon: const Icon(Icons.download),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadsPage()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchArea() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _submit,
                  onTap: () {
                    if (_input.text.isEmpty &&
                        Library.instance.searchHistory.isNotEmpty) {
                      setState(() => _showHistory = true);
                    }
                  },
                  decoration: InputDecoration(
                    hintText: 'Şarkı ara veya YouTube bağlantısı yapıştır',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: 'Panodan yapıştır',
                      icon: const Icon(Icons.content_paste),
                      onPressed: _busy ? null : _paste,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF242424),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: _listening ? 'Dinlemeyi durdur' : 'Sesle ara',
                icon: Icon(
                  _listening ? Icons.stop_circle : Icons.mic,
                  color: _listening ? ThemeState.value : null,
                ),
                onPressed: _toggleVoice,
              ),
            ],
          ),
          if (_showHistory && Library.instance.searchHistory.isNotEmpty)
            _searchHistory(),
        ],
      ),
    );
  }

  Widget _searchHistory() {
    final history = Library.instance.searchHistory;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                const Text(
                  'Arama geçmişi',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    Library.instance.clearSearchHistory();
                    setState(() => _showHistory = false);
                  },
                  child: const Text('Temizle'),
                ),
              ],
            ),
          ),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: history.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: Colors.white12),
            itemBuilder: (context, i) {
              final query = history[i];
              return ListTile(
                leading: const Icon(Icons.history, size: 20),
                title: Text(query, maxLines: 1),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    Library.instance.removeSearchHistory(i);
                    setState(() {});
                  },
                ),
                onTap: () {
                  _input.text = query;
                  _submit(query);
                },
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _roomBanner() {
    return ListenableBuilder(
      listenable: RoomService.instance,
      builder: (context, _) {
        final room = RoomService.instance;
        if (!room.inRoom) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Material(
            color: ThemeState.value.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RoomPage()),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(Icons.graphic_eq, color: ThemeState.value, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${room.roomName} · ${room.roomId} · '
                        '${room.members.length} cihaz',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Text('Odaya git', style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildResults() {
    final results = _results!;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _returnHome,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Ana sayfaya dön'),
          ),
        ),
        Expanded(
          child: results.isEmpty
              ? const Center(child: Text('Sonuç yok.'))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, i) {
                    final track = results[i];
                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CachedNetworkImage(
                          imageUrl: track.thumb,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.music_note, size: 40),
                        ),
                      ),
                      title: Text(
                        track.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: GestureDetector(
                        onTap: () => _openArtist(track),
                        child: Text(track.artist, maxLines: 1),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.radio),
                        tooltip: 'Radyo olarak çal',
                        onPressed: () => PlayerController.instance.playQueue(
                          results,
                          i,
                          radio: true,
                        ),
                      ),
                      onTap: () =>
                          PlayerController.instance.playQueue(results, i),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFeed() {
    final history = Library.instance.history;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        const UpdateBanner(),
        if (history.isNotEmpty)
          _HistoryStrip(history: history, onArtistTap: _openArtist),
        if (DownloadService.instance.savedTracks.isNotEmpty)
          _SavedStrip(
            tracks: DownloadService.instance.savedTracks,
            onTrackTap: _playSaved,
            onPlayAll: _playAllSaved,
          ),
        for (final source in _feed)
          _Section(
            title: source.title,
            future: _feedFutures[source.title] ?? _load(source.query),
            onArtistTap: _openArtist,
          ),
      ],
    );
  }
}

class _HistoryStrip extends StatelessWidget {
  const _HistoryStrip({required this.history, required this.onArtistTap});

  final List<Track> history;
  final ValueChanged<Track> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stripTitle(context, 'Dinlemeye devam et'),
        SizedBox(
          height: 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: history.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final track = history[i];
              return _ArtCard(
                track: track,
                width: 130,
                onTap: () =>
                    PlayerController.instance.playQueue(history, i),
                onLongPress: () => onArtistTap(track),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SavedStrip extends StatelessWidget {
  const _SavedStrip({
    required this.tracks,
    required this.onTrackTap,
    required this.onPlayAll,
  });

  final List<Track> tracks;
  final ValueChanged<Track> onTrackTap;
  final VoidCallback onPlayAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Row(
            children: [
              Text(
                'İndirilenler',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onPlayAll,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Tümünü çal'),
                style: TextButton.styleFrom(foregroundColor: ThemeState.value),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: tracks.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _ArtCard(
              track: tracks[i],
              width: 130,
              onTap: () => onTrackTap(tracks[i]),
            ),
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.future,
    required this.onArtistTap,
  });

  final String title;
  final Future<List<Track>> future;
  final ValueChanged<Track> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stripTitle(context, title),
        SizedBox(
          height: 208,
          child: FutureBuilder<List<Track>>(
            future: future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final tracks = snap.data;
              if (snap.hasError || tracks == null || tracks.isEmpty) {
                return const Center(
                  child: Text('—', style: TextStyle(color: Colors.white24)),
                );
              }
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: tracks.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, i) => _ArtCard(
                  track: tracks[i],
                  width: 150,
                  onTap: () =>
                      PlayerController.instance.playQueue(tracks, i),
                  onLongPress: () => onArtistTap(tracks[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ArtCard extends StatelessWidget {
  const _ArtCard({
    required this.track,
    required this.width,
    required this.onTap,
    this.onLongPress,
  });

  final Track track;
  final double width;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: track.thumb,
                width: width,
                height: width,
                fit: BoxFit.cover,
                placeholder: (_, __) =>
                    Container(color: const Color(0xFF242424)),
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xFF242424),
                  child: const Icon(Icons.music_note, size: 40),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _stripTitle(BuildContext context, String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
    child: Text(
      text,
      style: Theme.of(context)
          .textTheme
          .titleLarge
          ?.copyWith(fontWeight: FontWeight.w800),
    ),
  );
}
