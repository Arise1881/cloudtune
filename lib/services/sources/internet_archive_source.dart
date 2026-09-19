import 'dart:convert';
import 'dart:io';

import '../../models/music_source.dart';
import '../../models/song.dart';

/// Sağlayıcı migrasyon dizisi (bağımsız var):

/// Audius — merkeziyetsiz, açık mp3 kataloğu, API anahtarsız (varsayılan, yasal).
/// Internet Archive — kamu malı/CC/etree canlı kayıtlar, API anahtarsız (yasal).
/// Internet Archive "Internet Archive Source" — aynı katalog, farklı sarmalayıcı.
/// YouTube — kişisel kullanım için opt-in (akışlar herkese açık değil).

/// Internet Archive kaynağı — kamu malı/CC lisanslı ses koleksiyonları.
///
/// API anahtarı GEREKMEZ. `advancedsearch.php` (solr) + `metadata/{id}` +
/// `download/{id}/{file}` uçlarını kullanır. Bu özellik İÇERİK SAHİBİNİN
/// koşullarına bağlıdır; IA kataloğu kamu malı ve CC lisanslı audio'yu içerir.
///
/// NOT: Bu sınıf Audius ile AYNI imzalıdır (search/trending/streamCandidates),
/// böylece MusicService her iki yasal kaynağı tek arayüzden kullanabilir.
class InternetArchiveSource {
  InternetArchiveSource();

  static const String _host = 'archive.org';
  static const String _searchPath = '/advancedsearch.php';
  static const String _metadataPath = '/metadata';
  static const String _downloadPath = '/download';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  Future<dynamic> _get(String path,
      {Map<String, String>? query, Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 15);
    try {
      final uri = query != null
          ? Uri.https(_host, path, query)
          : Uri.https(_host, path);
      final req = await _client.getUrl(uri);
      final res = await req.close().timeout(t);
      if (res.statusCode != 200) {
        throw HttpException('Internet Archive ${res.statusCode}', uri: uri);
      }
      final raw = await res.transform(utf8.decoder).join().timeout(t);
      return jsonDecode(raw);
    } finally {
      // _client yeniden kullanılır; bağlantı havuzu HTTP kapatır.
    }
  }

  /// Internet Archive araması — AudiusSource.search ile aynı imza.
  Future<List<Song>> search(String query, {int limit = 24}) async {
    final q = <String, String>{
      'q': 'title:($query) OR creator:($query)', 
      'fl[]': 'identifier,title,creator,year',
      'rows': '$limit',
      'output': 'json',
      'sort[]': 'downloads desc',
    };
    final d = await _get(_searchPath, query: q);
    return _fromSearchJson(d, query);
  }

  /// Popüler kamu malı/CC sesler — Home "Trend" için.
  Future<List<Song>> trending({int limit = 24}) async {
    final q = <String, String>{
      'q': 'mediatype:(audio) AND (collection:(etree_community) OR '
          'collection:(audio_music) OR collection:(prelinger))',
      'fl[]': 'identifier,title,creator,year',
      'rows': '$limit',
      'output': 'json',
      'sort[]': 'downloads desc',
    };
    final d = await _get(_searchPath, query: q);
    return _fromSearchJson(d, 'trending');
  }

  /// Radyo tabanı — aynı sanatçı/yaratıcıdan farklı IA item'ları.
  Future<List<Song>> radioForSong(Song s, {int limit = 12}) async {
    final base = s.artist.isNotEmpty ? s.artist : s.title;
    final q = <String, String>{
      'q': 'creator:($base) AND mediatype:(audio) AND NOT identifier:${s.id}',
      'fl[]': 'identifier,title,creator,year',
      'rows': '$limit',
      'output': 'json',
      'sort[]': 'downloads desc',
    };
    final d = await _get(_searchPath, query: q);
    return _fromSearchJson(d, s.id);
  }

  /// IA item'larının standardize edilmiş akış adayları — mp3 öncelikli.
  /// Dönüş: [canonicalUrl, alternateUrls...] (MusicService.resolveStreamUrl ile uyumlu).
  Future<List<String>> streamCandidates(Song s, {Duration? timeout}) async {
    final id = _cleanIdentifier(s.id);
    return _fileCandidates(id, timeout: timeout);
  }

  String _cleanIdentifier(String id) =>
      id.startsWith('ia:') ? id.substring(3) : id;

  Future<List<String>> _fileCandidates(String identifier,
      {Duration? timeout}) async {
    try {
      final m = await _get('$_metadataPath/$identifier', timeout: timeout);
      final files = (m as Map<String, dynamic>)['files'] as List<dynamic>? ?? [];
      final out = <String>[];
      for (final f in files) {
        final fm = (f as Map<String, dynamic>);
        final name = fm['name'] as String? ?? '';
        final format = fm['format'] as String? ?? '';
        final l = name.toLowerCase();
        if (l.endsWith('.mp3') && format.toUpperCase().contains('MP3')) {
          out.add('https://$_host$_downloadPath/$identifier/$name');
          if (out.length >= 4) break;
        }
      }
      for (final f in files) {
        final fm = (f as Map<String, dynamic>);
        final name = fm['name'] as String? ?? '';
        final l = name.toLowerCase();
        if (l.endsWith('.ogg') || l.endsWith('.vorbis')) {
          out.add('https://$_host$_downloadPath/$identifier/$name');
          if (out.length >= 5) break;
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  List<Song> _fromSearchJson(dynamic d, String query) {
    final out = <Song>[];
    try {
      final docs = (((d as Map<String, dynamic>)['response']
              as Map<String, dynamic>)['docs'] as List<dynamic>?)
          ?.cast<Map<String, dynamic>>();
      if (docs == null) return out;
      for (final doc in docs) {
        final id = '${doc['identifier'] ?? ''}';
        if (id.isEmpty) continue;
        final title = '${doc['title'] ?? ''}';
        final artist = '${doc['creator'] ?? ''}';
        out.add(Song(
          id: id,
          title: title,
          artist: artist.isEmpty ? 'Internet Archive' : artist,
          thumbnailUrl: 'https://$_host/services/img/$id',
          durationMs: 0,
          source: MusicSourceType.internetArchive,
        ));
      }
    } catch (_) {}
    return out;
  }
}
