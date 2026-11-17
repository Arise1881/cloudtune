import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
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

  List<Track>? _results;
  List<Track> _artistTracks = const <Track>[];
  String? _artistName;
  bool _artistTracksLoading = false;
  int _searchGeneration = 0;
  bool _busy = false;
  bool _listening = false;
  bool _showHistory = false;
  bool _prefetched = false;
  bool _speechReady = false;
  bool _voiceSubmitDone = false;
  bool _pausedForVoice = false;
  bool _voiceStopOnUp = false;
  bool _voiceSubmitOnReady = false;
  String _voiceText = '';
  DateTime? _voicePressAt;
  String _lastQuery = '';
  Track? _lastTrack;

  @override
  void initState() {
    super.initState();
    Library.instance.addListener(_onLibraryChanged);
    PlayerController.instance.addListener(_onPlayerChanged);
    _prepareFeed();
  }

  @override
  void dispose() {
    Library.instance.removeListener(_onLibraryChanged);
    PlayerController.instance.removeListener(_onPlayerChanged);
    unawaited(_restorePlaybackAfterVoice());
    unawaited(_speech.cancel());
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
    if (names.length == shown.length && names.containsAll(shown)) return;

    setState(() {
      _feed.removeWhere(
        (source) => source.isPlaylist && !names.contains(source.title),
      );
      for (final name in names) {
        if (!shown.contains(name)) {
          _feed.add(_FeedSource(name, name, isPlaylist: true));
        }
      }
      _reloadFeeds();
    });
  }

  /// Çalma geçmişi/beğeni değişimi feed'i yeniden aratmaz. Kullanıcı içerik
  /// güncellemesini yalnızca yukarıdan aşağıya kaydırarak ister.
  void _onLibraryChanged() {
    if (!mounted || _results != null) return;
    _syncPlaylistSources();
  }

  Future<void> _refreshFeed() async {
    setState(_prepareFeed);
    try {
      await Future.wait(_feedFutures.values, eagerError: false)
          .timeout(const Duration(seconds: 12));
    } catch (_) {}
  }

  Future<void> _refreshResults() async {
    if (_lastQuery.isNotEmpty) await _submit(_lastQuery);
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
    _lastQuery = value;
    final generation = ++_searchGeneration;
    setState(() {
      _showHistory = false;
      _artistTracks = const <Track>[];
      _artistName = null;
      _artistTracksLoading = false;
    });

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
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _results = found);
      if (found.isEmpty) _toast('Sonuç bulunamadı.');
      await Library.instance.addSearchHistory(value);

      // "Çalma Listeleri ve Şarkılar" başlığı altında sanatçının tüm
      // parçaları gösterilir. Kanal ID varsa yüklemeler, yoksa sanatçı
      // araması kullanılır; arama sonuçları ayrıca korunur.
      if (found.isNotEmpty) {
        final seed = found.firstWhere(
          (t) => t.artistId != null && t.artistId!.isNotEmpty,
          orElse: () => found.first,
        );
        setState(() {
          _artistName = seed.artist;
          _artistTracksLoading = true;
        });
        unawaited(_loadArtistTracks(seed, generation));
      }
    } catch (_) {
      RepairBot.instance.reportEvent('search_failed', {'query': value});
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _loadArtistTracks(Track seed, int generation) async {
    try {
      final tracks = await YoutubeService.instance.artistTracks(
        seed.artist,
        channelId: seed.artistId,
        limit: 60,
      );
      if (!mounted || generation != _searchGeneration) return;
      final seen = <String>{
        for (final track in _results ?? const <Track>[]) track.id,
      };
      final extra = tracks
          .where((track) => track.id.isNotEmpty && seen.add(track.id))
          .toList();
      setState(() {
        _artistTracks = extra;
        _artistTracksLoading = false;
      });
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _artistTracksLoading = false);
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

  /// Mikrofonu tamamen bırakır. Tanıma bittikten sonra oturum açık kalırsa
  /// cihaz kullanıcı konuşmasa da sesi dinlemeye devam ediyordu.
  Future<void> _releaseVoice() async {
    try {
      await _speech.cancel().timeout(const Duration(seconds: 3));
    } catch (_) {}
    unawaited(_restorePlaybackAfterVoice());
    if (mounted) setState(() => _listening = false);
  }

  /// `submit=true` kullanıcı mikrofonu bıraktığında araç çubuğuna yazılan
  /// kısmi metni aratır. Konuşma zaten final sonuç ürettiyse tekrar arama
  /// yapılmaz (`_voiceSubmitDone`).
  Future<void> _stopVoice({bool submit = false}) async {
    final text = _voiceText.trim();
    try {
      await _speech.stop().timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _releaseVoice();
    if (submit && text.isNotEmpty && !_voiceSubmitDone) {
      _voiceSubmitDone = true;
      _input.text = text;
      unawaited(_submit(text));
    }
  }

  void _onVoiceResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (text.isNotEmpty) _voiceText = text;
    if (!mounted || !result.finalResult) return;
    if (_voiceSubmitDone) return;
    _voiceSubmitDone = true;
    final query = text.isEmpty ? _voiceText : text;
    if (query.isEmpty) return;
    _input.text = query;
    unawaited(_stopVoice());
    unawaited(_submit(query));
  }

  String _voiceErrorMessage(String code) => switch (code) {
        'error_no_match' => 'Konuşma algılanmadı. Tekrar deneyin.',
        'error_speech_timeout' => 'Konuşma algılanmadı. Tekrar deneyin.',
        'error_audio' => 'Mikrofon sesi alınamadı.',
        'error_network' ||
        'error_server' =>
          'Sesli arama sunucusuna ulaşılamadı.',
        'error_busy' => 'Sesli arama şu an meşgul.',
        'error_insufficient_permissions' => 'Mikrofon izni gerekli.',
        'error_client' => 'Sesli arama başlatılamadı.',
        _ => 'Sesli arama hatası: $code',
      };

  void _onVoiceError(SpeechRecognitionError error) {
    // Hata sonrası otomatik yeniden dinleme yok. Mikrofon yalnızca kullanıcı
    // düğmeye bastığında açılır.
    _voiceError(_voiceErrorMessage(error.errorMsg));
    unawaited(_stopVoice());
  }

  Future<void> _startListening(String localeId) async {
    try {
      // 7.x API'sinde listen() hata callback'i almaz; hata initialize()
      // sırasında verilen errorListener üzerinden gelir (bkz. _beginVoice).
      // Kısmi sonuçlar yalnızca dahili olarak tutulur; kullanıcı mikrofonu
      // bıraktığında arama başlatılır. Oturum tek cümleyle sınırlıdır, hata
      // durumunda kendiliğinden kapanır; arka planda dinleme yapılmaz.
      await _speech
          .listen(
            onResult: _onVoiceResult,
            listenOptions: SpeechListenOptions(
              localeId: localeId.isEmpty ? null : localeId,
              partialResults: true,
              cancelOnError: true,
              listenMode: ListenMode.search,
              autoPunctuation: false,
              pauseFor: const Duration(seconds: 2),
              listenFor: const Duration(seconds: 15),
            ),
          )
          .timeout(const Duration(seconds: 6));
      if (mounted) setState(() => _listening = true);
      // Mikrofon bırakılmış ama initialize/listen henüz tamamlanmamış olabilir.
      if (_voiceSubmitOnReady) {
        _voiceSubmitOnReady = false;
        unawaited(_stopVoice(submit: true));
      }
    } on TimeoutException {
      // Cihazda konuşma tanıma servisi yoksa/bağlanmıyorsa session sessizce
      // takılmasın; kullanıcıya anlaşılır mesaj gösterilsin.
      _voiceError('Sesli arama şu an kullanılamıyor.');
      unawaited(_releaseVoice());
    } catch (_) {
      _voiceError('Sesli arama başlatılamadı.');
      unawaited(_releaseVoice());
    }
  }

  /// Cihazda tr-TR tanıma dilinin kurulu olup olmadığını kontrol et. Kurulu
  /// değilse sistemin varsayılan dilini kullan; aksi halde sessiz timeout
  /// oluşuyor ve kullanıcı "çalışmıyor" sanıyor.
  Future<String> _pickVoiceLocale() async {
    try {
      final locales = await _speech
          .locales()
          .timeout(const Duration(seconds: 4), onTimeout: () => []);
      if (locales.any((l) => l.localeId == 'tr-TR')) return 'tr-TR';
      final system = await _speech
          .systemLocale()
          .timeout(const Duration(seconds: 4), onTimeout: () => null);
      return system?.localeId ?? '';
    } catch (_) {
      return 'tr-TR';
    }
  }

  Future<void> _beginVoice() async {
    if (_listening) return;

    if (!_speechReady) {
      // speech_to_text izni initialize() sırasında ister; hasPermission
      // yalnızca mevcut durumu okur. Bu yüzden önce initialize çağrılır.
      bool available;
      try {
        available = await _speech
            .initialize(
              onError: _onVoiceError,
              onStatus: (s) {
                if (s == 'done' || s == 'notListening' || s == 'aborted') {
                  unawaited(_releaseVoice());
                }
              },
            )
            .timeout(const Duration(seconds: 6));
      } on TimeoutException {
        _voiceError('Sesli arama şu an kullanılamıyor.');
        return;
      } catch (_) {
        _voiceError('Sesli arama başlatılamadı.');
        return;
      }
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
    _voiceText = '';
    final locale = await _pickVoiceLocale();
    await _startListening(locale);
  }

  /// Kısa dokunuş: dinlemeyi açık bırak, konuşma bitince otomatik ara.
  /// Uzun basış: bırakıldığında (_onMicUp) söyleneni ara.
  void _onMicDown() {
    _voicePressAt = DateTime.now();
    _voiceStopOnUp = _listening;
    if (!_listening) unawaited(_beginVoice());
  }

  void _onMicUp() {
    final started = _voicePressAt;
    _voicePressAt = null;
    final held =
        started == null ? 0 : DateTime.now().difference(started).inMilliseconds;
    final shouldStop = _voiceStopOnUp || held >= 250;
    _voiceStopOnUp = false;
    if (!shouldStop) return;
    if (_listening) {
      unawaited(_stopVoice(submit: true));
    } else {
      // İlk kullanımda izin diyaloğu/initialize gecikebilir; oturum açılır
      // açılmaz bırakma niyeti yerine getirilir.
      _voiceSubmitOnReady = true;
    }
  }

  void _onMicCancel() {
    _voicePressAt = null;
    _voiceStopOnUp = false;
    if (_listening) unawaited(_stopVoice(submit: true));
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
    _searchGeneration++;
    setState(() {
      _results = null;
      _artistTracks = const <Track>[];
      _artistName = null;
      _artistTracksLoading = false;
      _input.clear();
    });
    _syncPlaylistSources();
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
      decoration: BoxDecoration(
        color: AppPalette.surface,
        border: Border(top: BorderSide(color: AppPalette.divider)),
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
    final color = active ? accent : AppPalette.iconSubtle;
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
                    fillColor: AppPalette.card,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: _listening ? 'Dinlemeyi durdur' : 'Sesle ara',
                child: GestureDetector(
                  onTapDown: (_) => _onMicDown(),
                  onTapUp: (_) => _onMicUp(),
                  onTapCancel: _onMicCancel,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      _listening ? Icons.stop_circle : Icons.mic,
                      color: _listening ? ThemeState.value : null,
                    ),
                  ),
                ),
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
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Text(
                  'Arama geçmişi',
                  style: TextStyle(fontSize: 12, color: AppPalette.textSubtle),
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
                Divider(height: 1, color: AppPalette.divider),
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
    final hasArtistTracks = _artistTracks.isNotEmpty;
    final primary = hasArtistTracks ? _artistTracks : results;
    final showSearchSection = hasArtistTracks && results.isNotEmpty;
    final artist = _artistName ?? 'Sanatçı';
    final subtitle = _artistTracksLoading
        ? '$artist parçaları yükleniyor…'
        : hasArtistTracks
            ? '$artist · ${_artistTracks.length} parça'
            : _artistName != null
                ? '$artist · ek parça bulunamadı'
                : null;

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
          child: RefreshIndicator(
            onRefresh: _refreshResults,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 1 +
                  (primary.isEmpty ? 1 : primary.length) +
                  (showSearchSection ? 1 + results.length : 0),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _resultSectionHeader(
                    title: 'Çalma Listeleri ve Şarkılar',
                    subtitle: subtitle,
                    queue: primary,
                  );
                }

                var i = index - 1;
                if (primary.isEmpty) {
                  if (i == 0) {
                    return _artistTracksLoading
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Sonuç yok.'),
                          );
                  }
                  i--;
                }
                if (i < primary.length) {
                  return _resultTile(primary[i], primary, i);
                }
                i -= primary.length;
                if (showSearchSection) {
                  if (i == 0) {
                    return _resultSectionHeader(
                      title: 'Arama Sonuçları',
                      subtitle: '“$_lastQuery” için ${results.length} sonuç',
                      queue: results,
                    );
                  }
                  return _resultTile(results[i - 1], results, i - 1);
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _resultSectionHeader({
    required String title,
    String? subtitle,
    required List<Track> queue,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null && subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: AppPalette.textSubtle),
                    ),
                  ),
              ],
            ),
          ),
          if (queue.isNotEmpty)
            IconButton(
              icon: Icon(Icons.play_circle_fill, color: ThemeState.value),
              tooltip: 'Tümünü çal',
              onPressed: () =>
                  PlayerController.instance.playQueue(queue, 0, radio: false),
            ),
        ],
      ),
    );
  }

  Widget _resultTile(Track track, List<Track> queue, int index) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CachedNetworkImage(
          imageUrl: track.thumb,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => const Icon(Icons.music_note, size: 40),
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
          queue,
          index,
          radio: true,
        ),
      ),
      onTap: () => PlayerController.instance.playQueue(queue, index),
    );
  }

  Widget _buildFeed() {
    final history = Library.instance.history;
    return RefreshIndicator(
      onRefresh: _refreshFeed,
      child: ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
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
      ),
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
                onTap: () => PlayerController.instance.playQueue(history, i),
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
                return Center(
                  child:
                      Text('—', style: TextStyle(color: AppPalette.iconFaint)),
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
                  onTap: () => PlayerController.instance.playQueue(tracks, i),
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
                placeholder: (_, __) => Container(color: AppPalette.card),
                errorWidget: (_, __, ___) => Container(
                  color: AppPalette.card,
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
              style: TextStyle(color: AppPalette.textSubtle, fontSize: 12),
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
