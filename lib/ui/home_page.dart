import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import 'package:flutter/services.dart';

import '../core/download_service.dart';
import '../core/link_handler.dart';
import '../core/link_resolver.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/repair_bot.dart';
import '../core/room_service.dart';
import '../core/settings_service.dart';
import '../core/speech_service.dart';
import '../core/theme_state.dart';
import '../core/update_service.dart';
import '../core/youtube_service.dart';
import '../l10n/app_strings.dart';
import '../screens/artist_page.dart';
import '../screens/downloads_page.dart';
import '../screens/my_playlists_page.dart';
import '../screens/playlist_page.dart';
import '../screens/radio_page.dart';
import '../screens/room_page.dart';
import '../screens/settings_screen.dart';
import 'cover_image.dart';
import 'mini_player.dart';
import 'search_ui.dart';

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
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  // Yerel Whisper: sistem/Google sesli arama kullanılmaz.
  final SpeechService _speech = WhisperSpeechService();
  StreamSubscription<SpeechStatus>? _speechStatusSub;
  StreamSubscription<String>? _voiceResultSub;

  late List<_FeedSource> _feed;
  late Map<String, Future<List<Track>>> _feedFutures;

  List<Track>? _results;
  List<Track> _artistTracks = const <Track>[];
  String? _artistName;
  String? _artistId;
  bool _artistTracksLoading = false;
  int _searchGeneration = 0;
  bool _busy = false;
  bool _listening = false;
  bool _showHistory = false;
  // Temiz kurulum deneyimi: uygulama açılınca doğrudan ana sayfa görünür.
  int _tab = SearchNavBar.home;
  final Set<String> _prefetchedFeeds = <String>{};
  static const int _maxPrefetchedFeeds = 2;
  bool _speechReady = false;
  bool _speechBusy = false;
  bool _voiceSubmitDone = false;
  bool _pausedForVoice = false;
  bool _voiceStopOnUp = false;
  bool _voiceSubmitOnReady = false;
  String _voiceText = '';
  String _voiceStatus = '';
  DateTime? _voicePressAt;
  String _lastQuery = '';
  Track? _lastTrack;

  @override
  void initState() {
    super.initState();
    Library.instance.addListener(_onLibraryChanged);
    PlayerController.instance.addListener(_onPlayerChanged);
    // Model indirme ilerlemesi ve hata mesajları arama çubuğunda gösterilir.
    _speechStatusSub = _speech.status.listen(_onSpeechStatus);
    _voiceResultSub = _speech.partialResults.listen(_onVoiceResult);
    _prepareFeed();
  }

  @override
  void dispose() {
    Library.instance.removeListener(_onLibraryChanged);
    PlayerController.instance.removeListener(_onPlayerChanged);
    unawaited(_speechStatusSub?.cancel());
    unawaited(_voiceResultSub?.cancel());
    unawaited(_restorePlaybackAfterVoice());
    unawaited(_speech.dispose());
    _input.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _prepareFeed({bool refresh = false}) {
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
    _reloadFeeds(refresh: refresh);
  }

  void _reloadFeeds({bool refresh = false}) {
    // Arama sonuçları önbellekte tutulur; yalnızca pull-to-refresh gerçek
    // network isteği yapar. Diğer çağrılar (library bildirimi, feed kurulumu)
    // önbelleği kullanır.
    _feedFutures = {
      for (final source in _feed)
        source.title: _load(
          source.query,
          isPlaylist: source.isPlaylist,
          refresh: refresh,
        ),
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
    if (!mounted) return;
    if (_tab == SearchNavBar.search) {
      setState(() {});
      return;
    }
    if (_results != null) return;
    _syncPlaylistSources();
  }

  Future<void> _refreshFeed() async {
    // Aynı kapak URL'si cache'de kaldığı için yeni arama gelse bile eski
    // görsel görünüyordu. Yeni nesil anahtar tüm kartları taze indirir.
    CoverImage.refresh();
    setState(() => _prepareFeed(refresh: true));
    try {
      await Future.wait(_feedFutures.values, eagerError: false)
          .timeout(const Duration(seconds: 12));
    } catch (_) {}
  }

  Future<void> _refreshResults() async {
    if (_lastQuery.isNotEmpty) {
      await _submit(_lastQuery, refresh: true);
    }
  }

  void _onPlayerChanged() {
    final track = PlayerController.instance.current;
    if (track?.id == _lastTrack?.id) return;
    _lastTrack = track;
    if (track != null && mounted) setState(_buildFeed);
  }

  Future<List<Track>> _load(
    String query, {
    bool isPlaylist = false,
    bool refresh = false,
  }) async {
    if (isPlaylist) {
      final saved = Library.instance.getPlaylist(query);
      if (saved.isNotEmpty) {
        _prefetchFeed('playlist:$query', saved);
        return saved;
      }
      return YoutubeService.instance.search(
        query,
        limit: 15,
        refresh: refresh,
      );
    }

    final tracks = await YoutubeService.instance.search(
      query,
      limit: 15,
      refresh: refresh,
    );
    if (tracks.isNotEmpty) _prefetchFeed('query:$query', tracks);
    return tracks;
  }

  void _prefetchFeed(String key, List<Track> tracks) {
    if (_prefetchedFeeds.contains(key) ||
        _prefetchedFeeds.length >= _maxPrefetchedFeeds) {
      return;
    }
    _prefetchedFeeds.add(key);
    // URI ısıtması tüm feed'lerde ucuz; ses motoru tamponu ise yalnızca
    // ekranda görünen bölüm için yapılır. Aksi halde ilk feed havuzu doldurup
    // kullanıcının gördüğü kartlar tamponlanmadan kalıyordu.
    unawaited(
      YoutubeService.instance.prefetchVisible(tracks.map((t) => t.id)),
    );
  }

  /// Ana sayfadaki yatay kartlar da dokunma anında adres çözümü beklemesin.
  void _prefetchHomeCards(List<Track> history, List<Track> saved) {
    final cards = <Track>[...history, ...saved];
    unawaited(YoutubeService.instance.prefetchVisible(cards.map((t) => t.id)));
    unawaited(PlayerController.instance.prepareVisible(cards));
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

  Future<void> _submit(String text, {bool refresh = false}) async {
    final value = text.trim();
    if (value.isEmpty) {
      setState(() => _results = null);
      return;
    }

    FocusScope.of(context).unfocus();
    _lastQuery = value;
    final generation = ++_searchGeneration;
    setState(() {
      _tab = SearchNavBar.search;
      _showHistory = false;
      _artistTracks = const <Track>[];
      _artistName = null;
      _artistId = null;
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
      final found = await YoutubeService.instance.search(
        value,
        refresh: refresh,
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _results = found);
      // Sonuçlar ekrana gelir gelmez ilk satırların adreslerini ısıt; kullanıcı
      // hemen dokunduğunda URI çözümü ağ turunda beklemez.
      unawaited(
        YoutubeService.instance.prefetchVisible(found.map((t) => t.id)),
      );
      unawaited(PlayerController.instance.prepareVisible(found));
      if (found.isEmpty) _toast('Sonuç bulunamadı.');
      await Library.instance.addSearchHistory(value);

      // Sanatçının diğer parçaları yalnızca kullanıcı yukarıdan aşağıya
      // kaydırıp yenilediğinde eklenir. İlk aramada sonuçlar sabit kalır;
      // aratılan şarkı kendiliğinden başka parçalara dönüşmez.
      if (refresh && found.isNotEmpty) {
        final seed = found.firstWhere(
          (t) => t.artistId != null && t.artistId!.isNotEmpty,
          orElse: () => found.first,
        );
        setState(() {
          _artistName = seed.artist;
          _artistId = seed.artistId;
          _artistTracksLoading = true;
        });
        unawaited(_loadArtistTracks(seed, generation, refresh: true));
      }
    } catch (_) {
      RepairBot.instance.reportEvent('search_failed', {'query': value});
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  /// X ikonu: arama kutusunu ve sonuçları tamamen temizler.
  void _clearSearch() {
    _searchGeneration++;
    _input.clear();
    setState(() {
      _results = null;
      _artistTracks = const <Track>[];
      _artistName = null;
      _artistId = null;
      _artistTracksLoading = false;
      _showHistory = false;
      _lastQuery = '';
    });
    _searchFocus.requestFocus();
  }

  Future<void> _trackAction(
    String action,
    Track track,
    List<Track> queue,
    int index,
  ) async {
    switch (action) {
      case 'play':
        PlayerController.instance.playQueue(queue, index);
        break;
      case 'radio':
        PlayerController.instance.startRadio(queue, index);
        break;
      case 'artist':
        _openArtist(track);
        break;
      case 'like':
        await Library.instance.toggleLike(track);
        break;
      case 'download':
        _toast('İndiriliyor: ${track.title}');
        final path = await DownloadService.instance.download(track);
        _toast(path == null ? 'İndirilemedi: ${track.title}' : 'İndirildi.');
        break;
      case 'playlist':
        await _addToPlaylist(track);
        break;
    }
  }

  Future<void> _addToPlaylist(Track track) async {
    final metas = Library.instance.playlistMetas;
    if (metas.isEmpty) {
      _toast('Önce bir çalma listesi oluştur.');
      await _createPlaylist();
      return;
    }
    final selected = await showDialog<PlaylistMeta>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('Çalma listesine ekle'),
        children: [
          for (final meta in metas)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(meta),
              child: Text('${meta.name} · ${meta.tracks.length} parça'),
            ),
        ],
      ),
    );
    if (selected == null) return;
    await Library.instance.addToPlaylist(selected.id, track);
    _toast('${track.title} → ${selected.name}');
  }

  Future<void> _loadArtistTracks(
    Track seed,
    int generation, {
    bool refresh = false,
  }) async {
    try {
      final tracks = await YoutubeService.instance.artistTracks(
        seed.artist,
        channelId: seed.artistId,
        limit: 60,
        refresh: refresh,
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

  /// Arama sonucunda bulunan sanatçının parçalarını ayrı çalma listesi olarak
  /// kaydeder; indirmeyi tekrar tetiklemez (kitaplık listesi referanstır).
  Future<void> _saveArtistPlaylist() async {
    final artist = _artistName;
    if (artist == null || _artistTracks.isEmpty) {
      _toast('Kaydedilecek sanatçı parçası yok.');
      return;
    }
    try {
      await Library.instance.saveArtistPlaylist(
        _artistId ?? artist,
        artist,
        _artistTracks,
      );
      _toast('$artist listesi kitaplığa kaydedildi.');
    } catch (_) {
      _toast('Liste kaydedilemedi.');
    }
  }

  /// Sanatçı parçalarını toplu indirir ve indirme grubu olarak kaydeder.
  Future<void> _downloadArtistPlaylist() async {
    if (_artistTracks.isEmpty) {
      _toast('İndirilecek sanatçı parçası yok.');
      return;
    }
    _toast('${_artistTracks.length} parça indiriliyor…');
    try {
      final artist = _artistName ?? 'Sanatçı';
      await DownloadService.instance.saveArtistPlaylist(
        _artistId ?? artist,
        artist,
        _artistTracks,
      );
      _toast('$artist parçaları indirildi.');
    } catch (_) {
      _toast('İndirme tamamlanamadı.');
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

  /// Mikrofonu tamamen bırakır. Yerel oturum açık kalırsa kayıt devam
  /// etmesin diye servis oturumu iptal edilir.
  Future<void> _releaseVoice() async {
    try {
      await _speech.cancel().timeout(const Duration(seconds: 4));
    } catch (_) {}
    unawaited(_restorePlaybackAfterVoice());
    if (mounted) setState(() => _listening = false);
  }

  /// Kayıt durur → WAV → yerel Whisper transkripti → arama.
  /// Nihai metin `stop()` içinde üretilir ve serviste saklanır.
  Future<void> _stopVoice({bool submit = false}) async {
    final fallback = _voiceText.trim();
    try {
      // İlk kullanımda model indirmesi de bu süreye dahil olabilir.
      await _speech.stop().timeout(const Duration(seconds: 120));
    } catch (_) {}
    final transcript = _speech.lastTranscript.trim();
    final text = transcript.isNotEmpty ? transcript : fallback;
    _voiceText = text;
    await _releaseVoice();
    if (submit && text.isNotEmpty && !_voiceSubmitDone) {
      _voiceSubmitDone = true;
      _input.text = text;
      unawaited(_submit(text));
    }
  }

  /// Whisper parçaları arama kutusuna hazırlanır; arama yalnızca kullanıcı
  /// mikrofonu bıraktığında (kayıt durduktan sonra) tetiklenir.
  void _onVoiceResult(String text) {
    final value = text.trim();
    if (value.isNotEmpty) _voiceText = value;
  }

  String _voiceErrorMessage(String message) {
    if (message.trim().isEmpty) return 'Sesli arama hatası.';
    return message;
  }

  /// Servis hata akışı: otomatik yeniden dinleme yok; mikrofon yalnızca
  /// kullanıcı düğmeye bastığında açılır.
  void _onVoiceError(String message) {
    _voiceError(message);
  }

  void _onSpeechStatus(SpeechStatus status) {
    if (!mounted) return;
    setState(() => _voiceStatus = status.message);
    if (status.phase == SpeechPhase.error) _onVoiceError(status.message);
  }

  Future<void> _startListening() async {
    try {
      await _speech
          .listen(locale: SettingsService.instance.languageCode)
          .timeout(const Duration(seconds: 10));
      if (mounted) setState(() => _listening = true);
      // Mikrofon bırakılmış ama izin/kayıt başlangıcı gecikebilir.
      if (_voiceSubmitOnReady) {
        _voiceSubmitOnReady = false;
        unawaited(_stopVoice(submit: true));
      }
    } on TimeoutException {
      _voiceError('Ses kaydı başlatılamadı.');
    } catch (_) {
      // Ayrıntılı mesaj servisin hata akışından gelir; tekrar gösterilmez.
      unawaited(_releaseVoice());
    }
  }

  Future<void> _beginVoice() async {
    if (_listening || _speechBusy) return;
    _speechBusy = true;
    try {
      if (!_speechReady) {
        try {
          _speechReady =
              await _speech.initialize().timeout(const Duration(seconds: 6));
        } on TimeoutException {
          _voiceError('Sesli arama şu an kullanılamıyor.');
          return;
        } catch (_) {
          _voiceError('Sesli arama başlatılamadı.');
          return;
        }
        if (!_speechReady) {
          _voiceError('Sesli arama bu cihazda kullanılamıyor.');
          return;
        }
      }

      // Mikrofon izni YALNIZCA kullanıcı düğmeye bastığında istenir.
      bool granted;
      try {
        granted = await _speech.hasPermission().timeout(
              const Duration(seconds: 8),
              onTimeout: () => false,
            );
      } catch (_) {
        granted = false;
      }
      if (!granted) {
        _voiceError('Mikrofon izni gerekli.');
        return;
      }

      // Müzik çalarken mikrofon şarkıyı duyuyor, tanıma başarısız oluyordu.
      if (PlayerController.instance.playing) {
        await PlayerController.instance.pause();
        _pausedForVoice = true;
      }

      _voiceSubmitDone = false;
      _voiceText = '';
      await _startListening();
    } finally {
      _speechBusy = false;
    }
  }

  /// Kısa dokunuş: kayıt açık kalır, ikinci dokunuşta durur ve aranır.
  /// Uzun basış: bırakıldığında (_onMicUp) söyleneni arar.
  void _onMicDown() {
    _voicePressAt = DateTime.now();
    _voiceStopOnUp = _listening;
    if (!_listening && !_speechBusy) unawaited(_beginVoice());
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
    _toast(_voiceErrorMessage(msg));
    if (mounted) setState(() => _voiceStatus = '');
    unawaited(_releaseVoice());
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
      _tab = SearchNavBar.home;
      _showHistory = false;
      _results = null;
      _artistTracks = const <Track>[];
      _artistName = null;
      _artistId = null;
      _artistTracksLoading = false;
      _input.clear();
    });
    _syncPlaylistSources();
    // ListView yeni build edilmeden animateTo() çağrılırsa controller'ın
    // position'ı olmadığı için assertion fırlıyordu.
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final searching = _tab == SearchNavBar.search;
    return Scaffold(
      backgroundColor: AppPalette.surface,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (searching) const SearchTitle() else _header(),
            if (searching) _searchArea(),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            _roomBanner(),
            Expanded(
              child: searching
                  ? (_results != null ? _buildResults() : _searchLanding())
                  : ListenableBuilder(
                      listenable: DownloadService.instance,
                      builder: (context, _) => _buildFeed(),
                    ),
            ),
            const MiniPlayer(),
            SearchNavBar(selected: _tab, onTap: _onNavTap),
          ],
        ),
      ),
    );
  }

  void _onNavTap(int value) {
    if (value == SearchNavBar.library) {
      // Eski "Kitaplığım" davranışı: profil/avatar, beğeniler ve dinleme
      // geçmişi RoomPage'in kitaplık sekmesinde. Çalma listeleri arama
      // ekranındaki playlist kartlarından ve ana sayfa üstünden açılır.
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const RoomPage(initialTab: 1)),
      );
      return;
    }
    if (value == SearchNavBar.settings) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
      return;
    }
    if (value == SearchNavBar.home) {
      _returnHome();
      return;
    }
    setState(() => _tab = SearchNavBar.search);
    _searchFocus.requestFocus();
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
            tooltip: 'Şarkı ara',
            icon: const Icon(Icons.search),
            onPressed: () => _onNavTap(SearchNavBar.search),
          ),
          IconButton(
            tooltip: 'Odalar (Beta)',
            icon: const Icon(Icons.groups_outlined),
            onPressed: () => _openRooms(),
          ),
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
      padding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: SearchUi.fieldFill,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: Icon(Icons.search, color: Colors.white70, size: 22),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _searchFocus,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: SearchUi.titleAccent,
                    onSubmitted: _submit,
                    onChanged: (value) {
                      if (value.isEmpty && _results != null) _clearSearch();
                    },
                    onTap: () {
                      if (_input.text.isEmpty &&
                          Library.instance.searchHistory.isNotEmpty) {
                        setState(() => _showHistory = true);
                      }
                    },
                    decoration: const InputDecoration(
                      hintText: 'blued',
                      hintStyle: TextStyle(color: Colors.white54),
                      border: InputBorder.none,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _input,
                  builder: (context, value, _) {
                    if (value.text.isEmpty) return const SizedBox.shrink();
                    return IconButton(
                      tooltip: 'Temizle',
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: _clearSearch,
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Panodan yapıştır',
                  icon: const Icon(Icons.content_paste, color: Colors.white70),
                  onPressed: _busy ? null : _paste,
                ),
                Semantics(
                  button: true,
                  label: _listening ? 'Dinlemeyi durdur' : 'Sesle ara',
                  child: GestureDetector(
                    onTapDown: (_) => _onMicDown(),
                    onTapUp: (_) => _onMicUp(),
                    onTapCancel: _onMicCancel,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 10, 12, 10),
                      child: Icon(
                        _listening ? Icons.stop_circle : Icons.mic,
                        color:
                            _listening ? SearchUi.titleAccent : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Yerel Whisper modeli ilk kullanımda indirilir; ilerleme burada görünür.
          if (_voiceStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _voiceStatus,
                style: TextStyle(fontSize: 12, color: SearchUi.titleAccent),
              ),
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

  /// Arama kutusu boşken sanatçı/parça/playlist kartlarını hazır tutar.
  Widget _searchLanding() {
    final library = Library.instance;
    final recent = library.history.isNotEmpty ? library.history : library.liked;
    final seeds = SearchUi.artistSeeds(recent);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (library.searchHistory.isNotEmpty) _searchHistory(),
        _artistStrip(seeds),
        SearchSectionTitle(
          icon: Icons.music_note,
          title: 'Parçalar',
          trailing: recent.isEmpty ? null : '${recent.length}',
          onPlayAll: recent.isEmpty
              ? null
              : () =>
                  PlayerController.instance.playQueue(recent, 0, radio: false),
        ),
        if (recent.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Text('Aramak için yaz, yapıştır veya mikrofona bas.'),
          )
        else
          for (var i = 0; i < recent.length && i < 12; i++)
            _trackCard(recent[i], recent, i),
        _playlistSection(),
        _radioSection(seeds),
      ],
    );
  }

  Widget _buildResults() {
    final results = _results!;
    final seeds = SearchUi.artistSeeds(results);
    final hasArtistTracks = _artistTracks.isNotEmpty;
    // Aratılan parçalar her zaman listede kalır; yenilemeyle gelenler eklenir.
    final primary = SearchUi.mergedResults(results, _artistTracks);
    final artist = _artistName ?? 'Sanatçı';
    final subtitle = _artistTracksLoading
        ? '$artist parçaları yükleniyor…'
        : hasArtistTracks
            ? '$artist · +${_artistTracks.length} parça'
            : _artistName != null
                ? '$artist · ek parça bulunamadı'
                : null;

    return RefreshIndicator(
      onRefresh: _refreshResults,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _artistStrip(seeds),
          SearchSectionTitle(
            icon: Icons.music_note,
            title: 'Parçalar',
            trailing: subtitle ?? '${primary.length} parça',
            onPlayAll: primary.isEmpty
                ? null
                : () => PlayerController.instance
                    .playQueue(primary, 0, radio: false),
            onSave: hasArtistTracks ? _saveArtistPlaylist : null,
            onDownload: hasArtistTracks ? _downloadArtistPlaylist : null,
          ),
          if (_artistTracksLoading && primary.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (primary.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Text('Sonuç yok.'),
            )
          else
            for (var i = 0; i < primary.length; i++)
              _trackCard(primary[i], primary, i),
          _playlistSection(),
          _radioSection(seeds),
        ],
      ),
    );
  }

  Widget _trackCard(Track track, List<Track> queue, int index) {
    return SearchTrackCard(
      track: track,
      liked: Library.instance.isLiked(track.id),
      onAction: (action) =>
          unawaited(_trackAction(action, track, queue, index)),
    );
  }

  Widget _artistStrip(List<Track> seeds) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SearchSectionTitle(
          icon: Icons.person_outline,
          title: 'Artists',
          trailing: seeds.isEmpty ? null : '${seeds.length}',
        ),
        if (seeds.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Sanatçılar arama sonuçlarında görünür.',
              style: TextStyle(fontSize: 12),
            ),
          )
        else
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: seeds.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) => SearchArtistCard(
                seed: seeds[i],
                onTap: () => _openArtist(seeds[i]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _playlistSection() {
    final metas = Library.instance.playlistMetas;
    if (metas.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SearchSectionTitle(
          icon: Icons.playlist_play,
          title: 'Çalma Listeleri',
          trailing: '${metas.length}',
          onPlayAll: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MyPlaylistsPage()),
          ),
        ),
        for (final meta in metas.take(8))
          ListTile(
            leading: Icon(Icons.queue_music, color: SearchUi.titleAccent),
            title: Text(
              meta.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${meta.tracks.length} parça'),
            trailing: IconButton(
              tooltip: 'Listeyi aç',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyPlaylistsPage()),
              ),
            ),
            onTap: () {
              if (meta.tracks.isEmpty) {
                _toast('Bu çalma listesi boş.');
                return;
              }
              PlayerController.instance.playQueue(meta.tracks, 0, radio: false);
            },
          ),
      ],
    );
  }

  Widget _radioSection(List<Track> seeds) {
    if (seeds.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SearchSectionTitle(
          icon: Icons.radio,
          title: 'Radyolar',
        ),
        SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: seeds.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final seed = seeds[i];
              return SizedBox(
                width: 150,
                child: Material(
                  color: AppPalette.card,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => PlayerController.instance.startRadio(
                      _artistName == seed.artist && _artistTracks.isNotEmpty
                          ? _artistTracks
                          : [seed],
                      0,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.radio,
                              color: SearchUi.titleAccent, size: 26),
                          const SizedBox(height: 10),
                          Text(
                            seed.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'Radyo',
                            style: TextStyle(
                              color: AppPalette.textSubtle,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _radioDirectoryCard(BuildContext context) {
    final strings = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const RadioPage()),
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: AppPalette.cardRaised,
              child: Icon(Icons.radio, color: SearchUi.titleAccent),
            ),
            title: Text(
              strings.turkishRadio,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(strings.turkishRadioHint),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
      ),
    );
  }

  Widget _buildFeed() {
    final history = Library.instance.history;
    final saved = DownloadService.instance.savedTracks;
    _prefetchHomeCards(history, saved);
    return RefreshIndicator(
      onRefresh: _refreshFeed,
      child: ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          const UpdateBanner(),
          _radioDirectoryCard(context),
          if (history.isNotEmpty)
            _HistoryStrip(history: history, onArtistTap: _openArtist),
          if (saved.isNotEmpty)
            _SavedStrip(
              tracks: saved,
              onTrackTap: _playSaved,
              onPlayAll: _playAllSaved,
            ),
          for (final source in _feed)
            _Section(
              title: source.title,
              future: _feedFutures[source.title] ?? _load(source.query),
              onArtistTap: _openArtist,
              onTracks: (tracks) =>
                  unawaited(PlayerController.instance.prepareVisible(tracks)),
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
    this.onTracks,
  });

  final String title;
  final Future<List<Track>> future;
  final ValueChanged<Track> onArtistTap;
  final ValueChanged<List<Track>>? onTracks;

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
              // Yalnızca bu bölüm ekrana geldiğinde çalışır; görünmeyen
              // feed'ler ses motoru tamponunu boşa tüketmesin.
              onTracks?.call(tracks);
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
        onTapDown: (_) => unawaited(YoutubeService.instance.prefetch(track.id)),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CoverImage(
                url: track.thumb,
                width: width,
                height: width,
                borderRadius: 10,
                iconSize: 40,
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
