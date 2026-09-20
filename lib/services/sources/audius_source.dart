import 'dart:convert';
import 'dart:io';

import '../../models/music_source.dart';
import '../../models/song.dart';

/// Audius sağlayıcısı — merkeziyetsiz, kullanıcı yüklemeli, açık müzik kataloğu.
///
/// API anahtarı GEREKMEZ. Tüm istekler `x-app-name` / `app_name` parametresiyle
/// anonimdir. Stream uçları 302 → CDN (Cloudflare) mp3'e yönlendirir; bu yönlendirme
/// tarayıcı/tarama 206 (range) destekler. Dinleme akışı için lisans, Audius'un
/// Creative Commons-uyumlu yükleme kuralları çerçevesinde içerik sahibi tarafından
/// sağlanır (API üzerinden "dinleme izni" kullanıcı tarafında çözülür).
///
/// Referans/Stream doğrulamaları (komut satırından) başarılıdır:
///   search/trending/related/user-tracks/stream(302→CDN mp3) — hepsi keyless.
class AudiusSource {
  AudiusSource(this._host);

  /// Varsayılan halka açık Audius API hostu — MusicService dispatcher'ı
  /// bu fabrikayı kullanır (yeni AudiusSource() çağrısı gerekmez).
  factory AudiusSource.defaultHost() => AudiusSource(_hostDefault);

  static const String _hostDefault =
      'discoveryprovider.audius.co';

  final String _host;

  static const String _appName = 'cloudtune';

  Future<dynamic> _getJson(String path,
      {Map<String, String>? query, Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 12);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final q = <String, String>{
        'app_name': _appName,
        ...?query,
      };
      final uri = Uri.https(_host, path, q);
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(t);
      if (res.statusCode != 200) {
        throw HttpException('Audius ${res.statusCode}', uri: uri);
      }
      final raw = await res.transform(utf8.decoder).join().timeout(t);
      return jsonDecode(raw);
    } finally {
      client.close(force: true);
    }
  }

  /// Adres listesi isteğe bağlı çoklu yapılandırma desteği için uç listesi.
  static Future<List<String>> discoverHosts() async {
    const fallback = ['api.audius.co'];
    try {
      final data = await _getJsonAnon('api.audius.co', '/', {});
      final list = data?['data'];
      if (list is List) {
        final hosts = <String>[];
        for (final h in list) {
          final host = h is Map ? h['host'] as String? : null;
          final clean = host?.replaceFirst(RegExp(r'^https?://'), '');
          if (clean != null && clean.isNotEmpty) hosts.add(clean);
        }
        if (hosts.isNotEmpty) return hosts;
      }
    } catch (_) {}
    return fallback;
  }

  static Future<dynamic> _getJsonAnon(String host, String path,
      Map<String, String> query) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.https(host, path, query);
      final res = await client.getUrl(uri).then((r) => r.close())
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final raw = await res.transform(utf8.decoder).join();
      return jsonDecode(raw);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Şarkı arama. Audius API'si kısmen "gated"/silinmiş içerik döndürebilir;
  /// bunları (stream çözülemez) sonuç listesinden atlarız.
  Future<List<Song>> search(String query, {int limit = 25}) async {
    final data = await _getJson('/v1/tracks/search',
        query: {'query': query, 'limit': '$limit'});
    return _tracksFrom(data);
  }

  /// Trend şarkılar (tüm türler, varsayılan).
  Future<List<Song>> trending({int limit = 12}) async {
    final data = await _getJson('/v1/tracks/trending',
        query: {'limit': '$limit'});
    return _tracksFrom(data);
  }

  /// User/artist arama → [SearchArtist]-uyumlu satırlar burada artist listesi olarak.
  Future<List<Song>> searchArtists(String query, {int limit = 15}) async {
    final data = await _getJson('/v1/users/search',
        query: {'query': query, 'limit': '$limit'});
    final docs = data?['data'];
    if (docs is! List) return const [];
    final out = <Song>[];
    for (final d in docs) {
      if (d is! Map<String, dynamic>) continue;
      final id = (d['id'] as String?) ?? '';
      final name = (d['name'] as String?) ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      out.add(Song(
        id: id,
        title: name,
        artist: 'Audius · Sanatçı',
        thumbnailUrl: _artwork(d),
        durationMs: 0,
        source: MusicSourceType.audius,
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Bir kullanıcının (artist) parça listesi.
  Future<List<Song>> userTracks(String userId, {int limit = 25}) async {
    final data =
        await _getJson('/v1/users/$userId/tracks', query: {'limit': '$limit'});
    return _tracksFrom(data);
  }

  /// Benzer/önerilen parçalar (radyo için de kullanılır).
  Future<List<Song>> relatedTracks(String trackId, {int limit = 12}) async {
    final data = await _getJson('/v1/tracks/$trackId/related',
        query: {'limit': '$limit'});
    return _tracksFrom(data);
  }

  /// Stream URL'si — 302 yönlendirmesini takip edip doğrudan CDN mp3 adresi döner.
  /// Keyless CDN erişimi Audius tarafından sağlandığı için proxy GEREKMEZ.
  Future<String> streamUrl({
    required String trackId,
    Duration? timeout,
  }) async {
    final t = timeout ?? const Duration(seconds: 15);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.https(_host, '/v1/tracks/$trackId/stream', {
        'app_name': _appName,
      });
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      final res = await req.close().timeout(t);
      final loc = res.headers.value(HttpHeaders.locationHeader);
      if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
        return loc;
      }
      // Yönlendirme yoksa HTTP durumu 200 — doğrudan bu adres.
      if (res.statusCode == 200) return uri.toString();
      throw HttpException('Audius stream ${res.statusCode}', uri: uri);
    } finally {
      client.close(force: true);
    }
  }

  List<Song> _tracksFrom(dynamic doc) {
    final docs = doc is Map<String, dynamic> ? (doc['data'] ?? doc['results']) : null;
    if (docs is! List) return const [];
    final out = <Song>[];
    for (final d in docs) {
      if (d is! Map<String, dynamic>) continue;
      final id = (d['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      final user = d['user'] is Map<String, dynamic>
          ? d['user'] as Map<String, dynamic>
          : null;
      final title = (d['title'] as String?) ?? '';
      final artist =
          (user?['name'] as String?) ?? (d['artist'] as String?) ?? '';
      final dur = (d['duration'] as num?) ?? 0;
      out.add(Song(
        id: id,
        title: title,
        artist: artist,
        thumbnailUrl: _artwork(d),
        durationMs: (dur * 1000).round(),
        source: MusicSourceType.audius,
      ));
      if (out.length >= 25) break;
    }
    return out;
  }

  String _artwork(Map<String, dynamic> d) {
    final art = d['artwork'];
    if (art is Map) {
      return (art['480x480'] as String?) ??
          (art['150x150'] as String?) ??
          (art['1000x1000'] as String?) ??
          '';
    }
    return (d['artworkUrl'] as String?) ?? '';
  }
}
