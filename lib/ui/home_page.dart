import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/link_handler.dart';
import '../core/link_resolver.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/repair_bot.dart';
import '../core/theme_state.dart';
import '../core/update_service.dart';
import '../core/youtube_service.dart';
import '../screens/artist_page.dart';
import '../screens/playlist_page.dart';
import '../screens/room_page.dart';
import '../screens/settings_screen.dart';
import 'mini_player.dart';

class _Category {
  const _Category(this.title, this.query);
  final String title;
  final String query;
}

const List<_Category> _categories = [
  _Category('Türkçe Pop', 'türkçe pop müzik 2026'),
  _Category('Rap & Hip-Hop', 'türkçe rap hit şarkılar'),
  _Category('Rock', 'rock müzik en iyi şarkılar'),
  _Category('Lo-fi & Sakin', 'lofi chill müzik'),
  _Category('Dünya Hitleri', 'top global hits 2026'),
  _Category('Akustik', 'akustik türkçe şarkılar'),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late List<_Category> _feed;
  late Map<String, Future<List<Track>>> _futures;

  List<Track>? _results;
  bool _busy = false;
  Track? _lastTrack;

  @override
  void initState() {
    super.initState();
    Library.instance.addListener(_onLibraryChanged);
    PlayerController.instance.addListener(_onPlayerChanged);
    _buildFeed();
    RepairBot.start();
  }

  void _buildFeed() {
    final library = Library.instance;
    _feed = [..._categories];
    // Kisisel bolum: dinleme gecmisine gore en cok dinlenen sanatci.
    final top = library.topArtist;
    if (top != null) {
      _feed.insert(0, _Category('$top senin için', '$top en iyi şarkılar'));
    }
    final liked = library.liked;
    if (liked.isNotEmpty && liked.first.artist.isNotEmpty) {
      _feed.insert(
        0,
        _Category(
          '${liked.first.artist} & benzerleri',
          '${liked.first.artist} benzer sanatçılar',
        ),
      );
    }
    _futures = {for (final c in _feed) c.title: _load(c.query)};
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    setState(_buildFeed);
  }

  void _onPlayerChanged() {
    final t = PlayerController.instance.current;
    if (t?.id != _lastTrack?.id) {
      _lastTrack = t;
      // Calinan sarkinin sanatcisina gore akisi tazele.
      if (t != null && mounted) setState(_buildFeed);
    }
  }

  Future<List<Track>> _load(String query) =>
      YoutubeService.instance.search(query, limit: 15);

  @override
  void dispose() {
    Library.instance.removeListener(_onLibraryChanged);
    PlayerController.instance.removeListener(_onPlayerChanged);
    RepairBot.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit(String text) async {
    final value = text.trim();
    if (value.isEmpty) {
      setState(() => _results = null);
      return;
    }
    FocusScope.of(context).unfocus();
    if (YoutubeLinkResolver.isYoutubeLink(value)) {
      final playlistId = YoutubeLinkResolver.playlistId(value);
      final videoId = YoutubeLinkResolver.videoId(value);
      if (playlistId != null && videoId == null) {
        // Yalnizca calma listesi baglantisi: liste sayfasini ac.
        _input.clear();
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlaylistPage(id: playlistId),
          ),
        );
        return;
      }
      final ok = await LinkHandler.open(value);
      if (ok) {
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
    } catch (_) {
      // Sessiz yedek: onarim botu tekrar dener, kullaniciya bilgi gosterilmez.
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

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 6) return 'İyi geceler';
    if (h < 12) return 'Günaydın';
    if (h < 18) return 'İyi günler';
    return 'İyi akşamlar';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Text(_greeting,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Oda',
                    icon: const Icon(Icons.person_outline),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const RoomPage()),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                  ValueListenableBuilder<Color>(
                    valueListenable: ThemeState.accent,
                    builder: (context, color, _) =>
                        Icon(Icons.graphic_eq, color: color),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _input,
                textInputAction: TextInputAction.search,
                onSubmitted: _submit,
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
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _results != null ? _buildResults() : _buildFeedList(),
            ),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    final results = _results!;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() {
              _results = null;
              _input.clear();
            }),
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
                    final t = results[i];
                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CachedNetworkImage(
                          imageUrl: t.thumb,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.music_note, size: 40),
                        ),
                      ),
                      title: Text(t.title,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: GestureDetector(
                        onTap: () => _openArtist(t),
                        child: Text(t.artist, maxLines: 1),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.radio),
                        tooltip: 'Radyo olarak çal',
                        onPressed: () => PlayerController.instance
                            .playQueue(results, i, radio: true),
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

  Widget _buildFeedList() {
    final library = Library.instance;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final history = library.history;
        return ListView(
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            const UpdateBanner(),
            if (history.isNotEmpty)
              _HistoryStrip(history: history, onArtistTap: _openArtist),
            for (final c in _feed)
              _Section(
                title: c.title,
                future: _futures[c.title] ?? _load(c.query),
                onArtistTap: _openArtist,
              ),
          ],
        );
      },
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Text('Dinlemeye devam et',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
        ),
        SizedBox(
          height: 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: history.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final t = history[i];
              return SizedBox(
                width: 130,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () =>
                      PlayerController.instance.playQueue(history, i),
                  onLongPress: () => onArtistTap(t),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: CachedNetworkImage(
                          imageUrl: t.thumb,
                          width: 130,
                          height: 130,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: const Color(0xFF242424),
                            child: const Icon(Icons.music_note, size: 40),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
              );
            },
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
          child: Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
        ),
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
                itemBuilder: (context, i) => _Card(
                  track: tracks[i],
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

class _Card extends StatelessWidget {
  const _Card({
    required this.track,
    required this.onTap,
    required this.onLongPress,
  });
  final Track track;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 150,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: track.thumb,
                width: 150,
                height: 150,
                fit: BoxFit.cover,
                placeholder: (_, __) =>
                    Container(color: const Color(0xFF242424)),
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xFF242424),
                  child: const Icon(Icons.music_note, size: 48),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
