import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/link_handler.dart';
import '../core/link_resolver.dart';
import '../core/theme_state.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/youtube_service.dart';
import '../screens/settings_screen.dart';
import 'mini_player.dart';

const Map<String, String> _sections = {
  'Türkçe Pop': 'türkçe pop müzik 2026',
  'Rap & Hip-Hop': 'türkçe rap hit şarkılar',
  'Rock': 'rock müzik en iyi şarkılar',
  'Lo-fi & Sakin': 'lofi chill müzik',
  'Dünya Hitleri': 'top global hits 2026',
};

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _input = TextEditingController();
  late final Map<String, Future<List<Track>>> _futures;

  List<Track>? _results;
  bool _busy = false;
  Track? _lastTrack;

  @override
  void initState() {
    super.initState();
    _futures = {
      for (final e in _sections.entries) e.key: _load(e.value),
    };
    PlayerController.instance.addListener(_onPlayerChanged);
  }

  void _onPlayerChanged() {
    final t = PlayerController.instance.current;
    if (t?.id != _lastTrack?.id) {
      _lastTrack = t;
      if (t != null) _reloadSections();
    }
  }

  void _reloadSections() {
    setState(() {
      _futures = {
        for (final e in _sections.entries) e.key: _load(e.value),
      };
    });
  }

  Future<List<Track>> _load(String query) =>
      YoutubeService.instance.search(query, limit: 15);

  @override
  void dispose() {
    PlayerController.instance.removeListener(_onPlayerChanged);
    _input.dispose();
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
    setState(() => _busy = true);
    try {
      if (YoutubeLinkResolver.isYoutubeLink(value)) {
        final error = await LinkHandler.open(value);
        if (error != null) _toast(error);
        if (error == null) _input.clear();
      } else {
        final found = await YoutubeService.instance.search(value);
        if (mounted) setState(() => _results = found);
        if (found.isEmpty) _toast('Sonuç bulunamadı.');
      }
    } catch (_) {
      _toast('Arama başarısız. İnternetini kontrol edip tekrar dene.');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(_greeting,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const Spacer(),
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
              child: _results != null ? _buildResults() : _buildSections(),
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
          child: ListView.builder(
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
                title: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(t.artist, maxLines: 1),
                onTap: () => PlayerController.instance.playQueue(results, i),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSections() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        for (final title in _sections.keys) _Section(title, _futures[title]!),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.future);
  final String title;
  final Future<List<Track>> future;

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
                  child: Text('Bu bölüm yüklenemedi.',
                      style: TextStyle(color: Colors.white54)),
                );
              }
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: tracks.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, i) => _Card(
                  track: tracks[i],
                  onTap: () => PlayerController.instance.playQueue(tracks, i),
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
  const _Card({required this.track, required this.onTap});
  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
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
