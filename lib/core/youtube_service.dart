import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'models.dart';
import 'settings_service.dart';

/// YouTube oturumu/robot doğrulaması istediğinde atılır.
class AudioBlocked implements Exception {
  const AudioBlocked(this.id, this.reason);

  final String id;
  final String reason;

  @override
  String toString() => 'AudioBlocked($id, $reason)';
}

/// Arama, liste, sanatçı ve ses akışı çözümlemesi.
/// Önce doğrudan YouTube'a bakılır; robot doğrulaması/engel durumunda
/// herkese açık bir Invidious API'sine yedeklenir. Arayüzde aracı ayarı yoktur.
class YoutubeService {
  YoutubeService._();

  static final YoutubeService instance = YoutubeService._();

  final YoutubeExplode _yt = YoutubeExplode();

  static const Duration _requestTimeout = Duration(seconds: 5);
  static const Duration _invTimeout = Duration(seconds: 8);
  static const Duration _cacheTtl = Duration(minutes: 60);
  static const String _invBase = 'https://yt.chocolatemoo53.com';

  final Map<String, Uri> _cache = {};
  final Map<String, DateTime> _cachedAt = {};
  final Map<String, String> _playability = {};

  /// Herkese açık Invidious örneğine JSON isteği. Hata durumunda null döner.
  Future<dynamic> _invGet(String path) async {
    try {
      final response = await http
          .get(Uri.parse('$_invBase$path'))
          .timeout(_invTimeout);
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body);
    } catch (_) {
      return null;
    }
  }

  /// Invidious video/search kaydını [Track]'a çevirir. Geçersizse null.
  Track? _trackFromInv(Map m) {
    final id = (m['videoId'] ?? m['id'])?.toString() ?? '';
    final title = m['title']?.toString().trim() ?? '';
    if (id.isEmpty || title.isEmpty) return null;

    final author = m['author']?.toString().trim() ?? '';
    final rawAuthorId = m['authorId'];
    final artistId = (rawAuthorId is String && rawAuthorId.isNotEmpty)
        ? rawAuthorId
        : null;

    Duration? duration;
    final rawLength = m['lengthSeconds'];
    final seconds = rawLength is num
        ? rawLength.toInt()
        : int.tryParse(rawLength?.toString() ?? '');
    if (seconds != null && seconds > 0) duration = Duration(seconds: seconds);

    String? coverUrl;
    final thumbs = m['videoThumbnails'] ?? m['thumbnails'];
    if (thumbs is List) {
      String urlOf(dynamic t) => t is Map ? (t['url']?.toString() ?? '') : '';
      for (final quality in const ['medium', 'high', 'standard', 'default']) {
        for (final t in thumbs) {
          if (t is! Map || t['quality']?.toString() != quality) continue;
          final url = urlOf(t);
          if (url.isNotEmpty) {
            coverUrl = url;
            break;
          }
        }
        if (coverUrl != null) break;
      }
      coverUrl ??= thumbs.map(urlOf).firstWhere(
            (u) => u.isNotEmpty,
            orElse: () => '',
          );
      if (coverUrl.isEmpty) coverUrl = null;
    }

    return Track(
      id: id,
      title: title,
      artist: author.isEmpty ? 'Bilinmeyen' : author,
      duration: duration,
      artistId: artistId,
      coverUrl: coverUrl,
    );
  }

  Track _fromVideo(Video video) => Track(
        id: video.id.value,
        title: video.title,
        artist: video.author,
        duration: video.duration,
        artistId:
            video.channelId.value.isEmpty ? null : video.channelId.value,
      );

  Future<List<Track>> search(String query, {int limit = 24}) async {
    final q = query.trim();
    if (q.isEmpty) return const <Track>[];
    try {
      final videos = await _yt.search.search(q);
      final found = videos
          .map(_fromVideo)
          .where((track) => track.id.isNotEmpty && track.title.isNotEmpty)
          .take(limit)
          .toList();
      if (found.isNotEmpty) return found;
    } catch (_) {
      // Robot doğrulaması: Invidious aramasına geç.
    }

    final data = await _invGet(
      '/api/v1/search?q=${Uri.encodeQueryComponent(q)}&type=video',
    );
    if (data is List) {
      return data
          .whereType<Map>()
          .map(_trackFromInv)
          .whereType<Track>()
          .where((track) => track.id.isNotEmpty && track.title.isNotEmpty)
          .take(limit)
          .toList();
    }
    return const <Track>[];
  }

  Future<Track> trackById(String id) async {
    try {
      final video = await _yt.videos.get(id);
      return _fromVideo(video);
    } catch (_) {
      // Invidious video detayını dene.
    }

    final data = await _invGet('/api/v1/videos/${Uri.encodeComponent(id)}');
    if (data is Map) {
      final track = _trackFromInv(data);
      if (track != null) return track;
    }

    // Son çare: oEmbed yalnızca başlık/sanatçı/kapak verir.
    try {
      final watch = 'https://www.youtube.com/watch?v=$id';
      final response = await http
          .get(
            Uri.parse(
              'https://www.youtube.com/oembed'
              '?url=${Uri.encodeQueryComponent(watch)}&format=json',
            ),
          )
          .timeout(_requestTimeout);
      if (response.statusCode == 200) {
        final oembed = jsonDecode(response.body);
        if (oembed is Map) {
          final title = oembed['title']?.toString().trim() ?? '';
          if (title.isNotEmpty) {
            final author = oembed['author_name']?.toString().trim() ?? '';
            final thumb = oembed['thumbnail_url']?.toString() ?? '';
            return Track(
              id: id,
              title: title,
              artist: author.isEmpty ? 'Bilinmeyen' : author,
              coverUrl: thumb.isEmpty ? null : thumb,
            );
          }
        }
      }
    } catch (_) {}

    throw StateError('track-unavailable: $id');
  }

  Future<List<Track>> playlist(
    String id, {
    int limit = 200,
    String? seed,
  }) async {
    final tracks = <Track>[];
    try {
      await for (final video in _yt.playlists.getVideos(id)) {
        final track = _fromVideo(video);
        if (track.id.isEmpty || track.title.trim().isEmpty) continue;
        tracks.add(track);
        if (tracks.length >= limit) break;
      }
    } catch (_) {
      // Mix/Radyo listelerinde video kimliği yedek kaynak olur.
    }

    if (tracks.isEmpty) {
      final data = await _invGet(
        '/api/v1/playlists/${Uri.encodeComponent(id)}',
      );
      if (data is Map && data['videos'] is List) {
        for (final item in data['videos'] as List) {
          if (item is! Map) continue;
          final track = _trackFromInv(item);
          if (track == null ||
              track.id.isEmpty ||
              track.title.trim().isEmpty) {
            continue;
          }
          tracks.add(track);
          if (tracks.length >= limit) break;
        }
      }
    }

    if (tracks.isEmpty && seed != null) {
      return related(seed, limit: limit);
    }
    return tracks;
  }

  Future<PlaylistInfo?> playlistInfo(String id) async {
    try {
      final info = await _yt.playlists.get(id);
      return PlaylistInfo(
        id: info.id.value,
        title: info.title,
        author: info.author,
      );
    } catch (_) {
      // Invidious liste detayına geç.
    }

    final data = await _invGet(
      '/api/v1/playlists/${Uri.encodeComponent(id)}',
    );
    if (data is Map) {
      final title = data['title']?.toString().trim() ?? '';
      if (title.isNotEmpty) {
        final author = data['author']?.toString().trim() ?? '';
        return PlaylistInfo(
          id: data['playlistId']?.toString() ?? id,
          title: title,
          author: author.isEmpty ? 'Bilinmeyen' : author,
        );
      }
    }
    return null;
  }

  Future<List<Track>> related(String videoId, {int limit = 30}) async {
    try {
      final video = await _yt.videos.get(videoId);
      final related = await _yt.videos.getRelatedVideos(video);
      if (related != null && related.isNotEmpty) {
        return related.take(limit).map(_fromVideo).toList();
      }
    } catch (_) {
      // Invidious önerilerine geç.
    }

    final data = await _invGet(
      '/api/v1/videos/${Uri.encodeComponent(videoId)}',
    );
    if (data is Map && data['recommendedVideos'] is List) {
      return (data['recommendedVideos'] as List)
          .whereType<Map>()
          .map(_trackFromInv)
          .whereType<Track>()
          .where((track) => track.id.isNotEmpty && track.title.isNotEmpty)
          .take(limit)
          .toList();
    }
    return const <Track>[];
  }

  Future<List<Track>> artistTracks(
    String name, {
    String? channelId,
    int limit = 60,
  }) async {
    if (channelId != null && channelId.isNotEmpty) {
      try {
        final tracks = <Track>[];
        await for (final video
            in _yt.channels.getUploads(ChannelId(channelId))) {
          tracks.add(_fromVideo(video));
          if (tracks.length >= limit) break;
        }
        if (tracks.isNotEmpty) return tracks;
      } catch (_) {}
    }
    return search('$name en iyi şarkılar', limit: limit);
  }

  Uri? _cached(String id) {
    final uri = _cache[id];
    final at = _cachedAt[id];
    if (uri == null || at == null) return null;
    if (DateTime.now().difference(at) > _cacheTtl) {
      _cache.remove(id);
      _cachedAt.remove(id);
      return null;
    }
    return uri;
  }

  void _remember(String id, Uri uri) {
    _cache[id] = uri;
    _cachedAt[id] = DateTime.now();
  }

  /// Çözülmüş ses adresi önbelleğini tamamen temizler.
  void clearCache() {
    _cache.clear();
    _cachedAt.clear();
    _playability.clear();
  }

  /// Sonraki parçanın adresini arka planda ısıtır.
  Future<void> prefetch(String id) async {
    if (id.isEmpty || _cached(id) != null) return;
    try {
      await audioUri(id);
    } catch (_) {
      // Sessiz: kullanıcıya bağlantı bilgisi gösterilmez.
    }
  }

  /// Çözülmüş akış adresi. Önbellekte varsa onu kullanır, yoksa çözer.
  Future<Uri> audioUri(String id) {
    final cached = _cached(id);
    if (cached != null) return Future<Uri>.value(cached);
    return _resolve(id);
  }

  /// Eski çağrılar için uyumluluk takma adı.
  Future<Uri> fastUri(String id) => audioUri(id);

  /// Önbelleği atlayıp doğrudan çözümü yeniden dener.
  Future<Uri?> forceDirect(String id) async {
    _cache.remove(id);
    _cachedAt.remove(id);
    try {
      final uri = await audioUri(id);
      return uri;
    } catch (_) {
      return null;
    }
  }

  Future<Uri> _resolve(String id) async {
    final uri = await innerTube(id);
    if (uri != null) {
      _remember(id, uri);
      return uri;
    }
    final status = _playability[id];
    if (status != null && status.isNotEmpty && status != 'OK') {
      throw AudioBlocked(id, status);
    }
    throw StateError('audio-unavailable: $id');
  }

  Future<http.Response> _innerTubePost(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) =>
      http.post(url, headers: headers, body: body).timeout(_requestTimeout);

  /// Doğrudan InnerTube isteğiyle oynatılabilir ses adresini bulur.
  /// İstemci sırası, cihazda doğrulanmış olanlardan başlar.
  Future<Uri?> innerTube(String id) async {
    final settings = SettingsService.instance;
    final quality = settings.ready ? settings.audioQuality : 'high';
    final itags = _qualityItags[quality] ?? _qualityItags['high']!;

    _playability.remove(id);
    for (final spec in _clients) {
      try {
        final response = await _innerTubePost(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/player'
            '?key=${spec['key']}&prettyPrint=false',
          ),
          headers: {
            'content-type': 'application/json',
            'accept-language': 'en-US,en;q=0.9',
            'x-youtube-client-name': spec['name'],
            'x-youtube-client-version': spec['version'],
            'user-agent': spec['ua'],
          },
          body: jsonEncode({
            'context': {
              'client': spec['client'],
              'thirdParty': {'embedUrl': 'https://www.youtube.com'},
            },
            'videoId': id,
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
        );

        if (response.statusCode != 200) continue;

        final data = jsonDecode(response.body);
        if (data is! Map) continue;

        final status = data['playabilityStatus'];
        if (status is Map && status['status'] is String) {
          final value = status['status'] as String;
          if (value != 'OK') {
            _playability[id] = value;
            continue;
          }
        }

        final streaming = data['streamingData'];
        if (streaming is! Map) continue;

        final formats = <Map>[
          ...(streaming['adaptiveFormats'] as List? ?? const [])
              .whereType<Map>(),
          ...(streaming['formats'] as List? ?? const []).whereType<Map>(),
        ];

        final playable = formats.where((format) {
          final url = format['url'];
          return url is String && url.isNotEmpty;
        }).toList();
        if (playable.isEmpty) continue;

        for (final itag in itags) {
          for (final format in playable) {
            if (format['itag'] != itag) continue;
            final uri = Uri.tryParse(format['url'] as String);
            if (uri != null) return uri;
          }
        }

        // itag eşleşmezse ilk saf ses akışını kullan.
        for (final format in playable) {
          final mime = format['mimeType']?.toString() ?? '';
          if (!mime.startsWith('audio/')) continue;
          final uri = Uri.tryParse(format['url'] as String);
          if (uri != null) return uri;
        }
      } catch (_) {
        // Bir istemci başarısızsa sıradakine geç.
      }
    }

    // Son çare: Invidious local=true akış adresleri.
    final inv = await _invGet(
      '/api/v1/videos/${Uri.encodeComponent(id)}?local=true',
    );
    if (inv is Map) {
      final formats = <Map>[
        ...(inv['formatStreams'] as List? ?? const []).whereType<Map>(),
        ...(inv['adaptiveFormats'] as List? ?? const []).whereType<Map>(),
      ];
      final audio = formats.where((format) {
        final type = format['type']?.toString() ?? '';
        final url = format['url']?.toString() ?? '';
        return type.startsWith('audio/') && url.isNotEmpty;
      }).toList();

      for (final itag in itags) {
        for (final format in audio) {
          if (format['itag']?.toString() != itag.toString()) continue;
          final uri = Uri.tryParse(format['url'] as String);
          if (uri != null) return uri;
        }
      }
      for (final format in audio) {
        final uri = Uri.tryParse(format['url'] as String);
        if (uri != null) return uri;
      }
    }

    // Çözülemezse null: oynatıcı aynı parçada hata gösterir, atlama yapmaz.
    return null;
  }

  static const List<Map<String, dynamic>> _clients = [
    {
      'key': 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
      'name': 'ANDROID_VR',
      'version': '1.60.19',
      'client': {
        'clientName': 'ANDROID_VR',
        'clientVersion': '1.60.19',
        'deviceMake': 'Oculus',
        'deviceModel': 'Quest 3',
        'androidSdkVersion': 32,
        'osName': 'Android',
        'osVersion': '12',
      },
      'ua': 'com.google.android.apps.youtube.vr.oculus/1.60.19 '
          '(Linux; U; Android 12; GB) gzip',
    },
    {
      'key': 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
      'name': 'ANDROID',
      'version': '19.09.37',
      'client': {
        'clientName': 'ANDROID',
        'clientVersion': '19.09.37',
        'androidSdkVersion': 30,
        'osName': 'Android',
      },
      'ua': 'com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip',
    },
    {
      'key': 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
      'name': 'WEB',
      'version': '2.20241113.01.00',
      'client': {
        'clientName': 'WEB',
        'clientVersion': '2.20241113.01.00',
        'osName': 'Windows',
        'osVersion': '10',
        'deviceMake': 'Desktop',
        'deviceModel': 'Desktop',
      },
      'ua': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    },
    {
      'key': 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
      'name': 'IOS',
      'version': '19.46.4',
      'client': {
        'clientName': 'IOS',
        'clientVersion': '19.46.4',
        'osName': 'iOS',
        'osVersion': '17.6',
        'deviceMake': 'Apple',
        'deviceModel': 'iPhone',
      },
      'ua': 'com.google.ios.youtube/19.46.4 (iPhone15,2; U; CPU iOS 17_6 '
          'like Mac OS X) gzip',
    },
    {
      'key': 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
      'name': 'MWEB',
      'version': '2.20241113.01.00',
      'client': {
        'clientName': 'MWEB',
        'clientVersion': '2.20241113.01.00',
        'osName': 'Android',
        'osVersion': '14',
        'deviceMake': 'Mobile',
        'deviceModel': 'Mobile',
      },
      'ua': 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
    },
  ];

  static const Map<String, List<int>> _qualityItags = {
    'low': [139, 149, 249, 250, 251, 140, 600],
    'medium': [140, 250, 249, 251, 139, 149, 600],
    'high': [251, 140, 250, 249, 139, 149, 600],
    'veryhigh': [251, 140, 600, 250, 249, 139, 149],
  };
}
