import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'async_helpers.dart';
import 'models.dart';
import 'settings_service.dart';

/// YouTube oturumu/robot doğrulaması istediğinde atılır.
class AudioBlocked implements Exception {
  const AudioBlocked(this.id, this.reason);

  final String id;
  final String reason;

  @override
  String toString() {
    final detail = reason.isEmpty ? '' : ' ($reason)';
    return 'Bu ses akışı şu anda oynatılamıyor$detail. Lütfen tekrar deneyin.';
  }
}

/// Tek bir arama sorgusunun sonuçları ve alınma zamanı.
class _CachedSearch {
  const _CachedSearch(this.results, this.at);

  final List<Track> results;
  final DateTime at;
}

/// Kalite seçiminin gerçek itag kısıtı ve bitrate eğilimi.
class _QualitySpec {
  const _QualitySpec(this.itags, this.preferHighestBitrate);

  final List<int> itags;
  final bool preferHighestBitrate;
}

/// Sanatçı şarkılarının ayrı bir çalma listesi olarak sunulması için model.
/// UI bu değeri doğrudan çalma listesi detayına bağlayabilir.
class ArtistPlaylist {
  const ArtistPlaylist({
    this.info,
    this.tracks = const <Track>[],
  });

  final PlaylistInfo? info;
  final List<Track> tracks;
}

/// Arama, liste, sanatçı ve ses akışı çözümlemesi.
/// Önce doğrudan YouTube'a bakılır; robot doğrulaması/engel durumunda
/// birden fazla herkese açık Invidious örneğine yedeklenir. Arayüzde aracı
/// ayarı yoktur.
class YoutubeService {
  YoutubeService._() {
    unawaited(_watchConnectivity());
  }

  static final YoutubeService instance = YoutubeService._();

  final YoutubeExplode _yt = YoutubeExplode();

  static const Duration _requestTimeout = Duration(seconds: 6);
  static const Duration _invTimeout = Duration(seconds: 6);
  static const Duration _playlistTimeout = Duration(seconds: 15);
  static const Duration _resolveTimeout = Duration(seconds: 20);
  static const Duration _cacheTtl = Duration(minutes: 15);
  static const Duration _searchTtlWifi = Duration(minutes: 10);
  static const Duration _searchTtlMobile = Duration(minutes: 30);
  static const Duration _uriValidationTtl = Duration(seconds: 30);

  static const int _maxSearchResults = 50;
  static const int _maxSearchEntries = 40;

  /// Sırayla denen herkese açık Invidious örnekleri.
  static const List<String> _invBases = [
    'https://yt.chocolatemoo53.com',
    'https://yewtu.be',
    'https://inv.nadeko.net',
    'https://invidious.privacyredirect.com',
  ];

  bool _mobileData = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// Mobil veride arama/öneri yanıtları daha uzun önbellekte tutulur ve daha
  /// az yedek sunucuya başvurulur. Ses çözümlemesi kaliteyi düşürmez.
  bool get mobileData => _mobileData;

  static Duration searchTtlFor({required bool mobileData}) =>
      mobileData ? _searchTtlMobile : _searchTtlWifi;

  static int invBaseCount({required bool mobileData}) =>
      mobileData ? 2 : _invBases.length;

  /// Arama sonuçları görünürken ısıtılacak adres sayısı. Mobil veride
  /// istek sayısını sınırlar, Wi-Fi'de dokunma anında çözüm kalmaz.
  static int prefetchLimit({required bool mobileData}) => mobileData ? 5 : 10;

  Duration get searchTtl => searchTtlFor(mobileData: _mobileData);

  List<String> get _activeInvBases => _invBases
      .take(invBaseCount(mobileData: _mobileData))
      .toList(growable: false);

  Future<void> _watchConnectivity() async {
    try {
      final connectivity = Connectivity();
      final initial = await connectivity.checkConnectivity();
      _setConnectivity(initial);
      await _connectivitySub?.cancel();
      _connectivitySub =
          connectivity.onConnectivityChanged.listen(_setConnectivity);
    } catch (_) {
      _mobileData = false;
    }
  }

  void _setConnectivity(List<ConnectivityResult> results) {
    final hasMobile = results.contains(ConnectivityResult.mobile);
    final hasWifi = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    final next = hasMobile && !hasWifi;
    if (next == _mobileData) return;
    _mobileData = next;
    // Ağ değişince arama önbelleğinin TTL'i de değişir; eski kayıtlar yine
    // kendi yaşlarına göre değerlendirilir, ek istek yapılmaz.
  }

  final Map<String, Uri> _cache = {};
  final Map<String, DateTime> _cachedAt = {};
  final Map<String, DateTime> _uriCheckedAt = {};

  /// Aynı parça için prefetch ve oynatma tek URI çözümünü paylaşır. Böylece
  /// dokunma anında prefetch sürüyorsa ikinci ağ isteği açılmaz; oynatma
  /// doğrudan bekleyen future'a bağlanır.
  final Map<String, Future<Uri>> _resolving = {};
  final Map<String, String> _playability = {};
  final Map<String, _CachedSearch> _searchCache = {};
  final Map<String, List<Track>> _relatedCache = {};

  /// Null ise SettingsService değeri kullanılır; aksi halde kullanıcı
  /// [setQuality] ile servis seviyesinde kaliteyi değiştirmiştir.
  String? _qualityOverride;
  String? _lastQuality;

  /// 403/410/404 gibi durumlarda imzalı URI bayattır.
  static const Set<int> _staleUriStatuses = {403, 404, 410};

  /// Aktif ses kalitesi. `veryhigh` ayarı `lossless` olarak normalleştirilir.
  /// Ayar ekranından değişen kalite de burada yakalanıp URI önbelleğini
  /// geçersiz kılar.
  String get quality {
    final raw = _qualityOverride ??
        (SettingsService.instance.ready
            ? SettingsService.instance.audioQuality
            : 'high');
    final normalized = _normalizeQuality(raw);
    final previous = _lastQuality;
    if (previous != null && previous != normalized) {
      clearCache();
    }
    _lastQuality = normalized;
    return normalized;
  }

  /// Kaliteyi değiştirir ve çözülmüş URI önbelleğini geçersiz kılar.
  void setQuality(String value) {
    final next = _normalizeQuality(value);
    if (_qualityOverride == next) return;
    _qualityOverride = next;
    _lastQuality = next;
    clearCache();
  }

  static String _normalizeQuality(String value) {
    switch (value.toLowerCase().trim()) {
      case 'low':
        return 'low';
      case 'medium':
        return 'medium';
      case 'lossless':
      case 'veryhigh':
        return 'lossless';
      case 'high':
      default:
        return 'high';
    }
  }

  static const Map<String, _QualitySpec> _qualitySpec = {
    // Opus 48/64k veya m4a 128k.
    'low': _QualitySpec([249, 250, 140], false),
    // Opus ~160k (251) veya AAC 256k (141).
    'medium': _QualitySpec([251, 141], true),
    // 251 ve varsa en yüksek bitrate'li saf ses akışı.
    'high': _QualitySpec([251], true),
    // 141/251 öncelikli; yoksa en yüksek bitrate (hi-res/HDR) akışı.
    'lossless': _QualitySpec([141, 251], true),
  };

  /// Windows'ta just_audio Media Foundation kullanır; WebM/Opus (itag
  /// 249/250/251) genelde oynatılamaz. Yalnızca Windows'ta AAC itag'lerine
  /// (140/141) zorlanır, diğer platformların seçimi değişmez.
  static bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

  static _QualitySpec _specFor(String quality) {
    final base = _qualitySpec[quality] ?? _qualitySpec['high']!;
    if (!_isWindows) return base;
    final itags = switch (quality) {
      'low' => const <int>[140],
      'medium' => const <int>[140, 141],
      _ => const <int>[141, 140],
    };
    return _QualitySpec(itags, base.preferHighestBitrate);
  }

  static bool _windowsPlayableFormat(Map format) {
    if (!_isWindows) return true;
    final mime =
        (format['mimeType'] ?? format['type'] ?? '').toString().toLowerCase();
    if (mime.contains('webm') ||
        mime.contains('opus') ||
        mime.contains('ogg')) {
      return false;
    }
    final container = (format['container'] ?? '').toString().toLowerCase();
    return !container.contains('webm') && !container.contains('ogg');
  }

  static bool _windowsPlayableStream(dynamic stream) {
    if (!_isWindows) return true;
    final container = stream.container?.toString().toLowerCase() ?? '';
    if (container.contains('webm') || container.contains('ogg')) return false;
    final codec = stream.audioCodec?.toString().toLowerCase() ?? '';
    return !codec.contains('opus');
  }

  /// Invidious örneklerini eşzamanlı dener; ilk başarılı JSON döner.
  /// Sıralı denemede ilk üç örnek yanıt vermediğinde arama/öneri de 18 sn
  /// bekliyordu; artık en yavaş tek örnek kadar sürer.
  Future<dynamic> _invGet(String path) => firstSuccess<dynamic>([
        for (final base in _activeInvBases) _invGetBase(base, path),
      ]);

  Future<dynamic> _invGetBase(String base, String path) async {
    try {
      final response =
          await http.get(Uri.parse('$base$path')).timeout(_invTimeout);
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
    final artistId =
        (rawAuthorId is String && rawAuthorId.isNotEmpty) ? rawAuthorId : null;

    Duration? duration;
    final rawLength = m['lengthSeconds'];
    final seconds = rawLength is num
        ? rawLength.toInt()
        : int.tryParse(rawLength?.toString() ?? '');
    if (seconds != null && seconds > 0) duration = Duration(seconds: seconds);

    String? coverUrl;
    final thumbs = m['videoThumbnails'] ?? m['thumbnails'];
    if (thumbs is List) {
      String urlOf(dynamic t) =>
          t is Map ? (t['url']?.toString() ?? '') : (t is String ? t : '');
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

  Track _fromVideo(Video video) {
    // Kapak URL'ini açıkça taşı: transit/yedek kaynaklarda `Track.thumb`
    // varsayılan YouTube host'una erişilemediğinde görsel boş kalıyordu.
    // Liste/küçük kapak için mqdefault yeterli; büyük player görseli de
    // Track.artwork üzerinden orijinal adresi kullanabilir.
    final thumb = video.thumbnails.mediumResUrl;
    return Track(
      id: video.id.value,
      title: video.title,
      artist: video.author,
      duration: video.duration,
      artistId: video.channelId.value.isEmpty ? null : video.channelId.value,
      coverUrl: thumb.isEmpty ? null : thumb,
    );
  }

  /// Arama sonuçları 10 dakika önbellekte tutulur. [refresh] yalnızca
  /// pull-to-refresh gibi kullanıcı kaynaklı yenilemelerde true geçilir.
  Future<List<Track>> search(
    String query, {
    int limit = 24,
    bool refresh = false,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const <Track>[];

    final key = q.toLowerCase();
    if (!refresh) {
      final cached = _searchCache[key];
      if (cached != null && DateTime.now().difference(cached.at) <= searchTtl) {
        return cached.results.take(limit).toList();
      }
    }

    final results = await _fetchSearch(q);
    _searchCache[key] = _CachedSearch(
      List<Track>.unmodifiable(results),
      DateTime.now(),
    );
    if (_searchCache.length > _maxSearchEntries) {
      _searchCache.remove(_searchCache.keys.first);
    }
    return results.take(limit).toList();
  }

  Future<List<Track>> _fetchSearch(String q) async {
    try {
      final videos = await _yt.search.search(q).timeout(_requestTimeout);
      final found = videos
          .map(_fromVideo)
          .where((track) => track.id.isNotEmpty && track.title.isNotEmpty)
          .take(_maxSearchResults)
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
          .take(_maxSearchResults)
          .toList();
    }
    return const <Track>[];
  }

  /// Arama önbelleğini tamamen temizler (pull-to-refresh için kullanılabilir).
  void clearSearchCache() {
    _searchCache.clear();
    _relatedCache.clear();
  }

  Future<Track> trackById(String id) async {
    try {
      final video = await _yt.videos.get(id).timeout(_requestTimeout);
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

    throw StateError(
        'Video bilgisine ulaşılamadı. Bağlantınızı kontrol edip tekrar deneyin.');
  }

  Future<void> _collectPlaylistVideos(
    String id,
    List<Track> tracks,
    int limit,
  ) async {
    await for (final video in _yt.playlists.getVideos(id)) {
      final track = _fromVideo(video);
      if (track.id.isEmpty || track.title.trim().isEmpty) continue;
      tracks.add(track);
      if (tracks.length >= limit) break;
    }
  }

  Future<List<Track>> playlist(
    String id, {
    int limit = 200,
    String? seed,
  }) async {
    final tracks = <Track>[];
    try {
      await _collectPlaylistVideos(id, tracks, limit).timeout(_playlistTimeout);
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
          if (track == null || track.id.isEmpty || track.title.trim().isEmpty) {
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
      final info = await _yt.playlists.get(id).timeout(_requestTimeout);
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
        final rawThumb =
            data['thumbnailUrl'] ?? data['thumbnail'] ?? data['image'];
        String? thumb;
        if (rawThumb is String && rawThumb.isNotEmpty) {
          thumb = rawThumb;
        } else if (rawThumb is Map) {
          thumb = rawThumb['url']?.toString();
        } else if (data['videoThumbnails'] is List) {
          for (final item in data['videoThumbnails'] as List) {
            if (item is Map && item['url']?.toString().isNotEmpty == true) {
              thumb = item['url']?.toString();
              break;
            }
          }
        }
        return PlaylistInfo(
          id: data['playlistId']?.toString() ?? id,
          title: title,
          author: author.isEmpty ? 'Bilinmeyen' : author,
          thumbUrl: thumb,
        );
      }
    }
    return null;
  }

  /// İlgili videolar: youtube_explode, InnerTube `next`, birden fazla
  /// Invidious örneği ve son başarılı sonuçlar sırasıyla denenir.
  /// Hiçbir kaynak yanıt vermezse istisna fırlatmaz, boş liste döner.
  Future<List<Track>> related(String videoId, {int limit = 30}) async {
    if (videoId.isEmpty || limit <= 0) return const <Track>[];

    try {
      final collected = <Track>[];
      final seen = <String>{};

      void addAll(Iterable<Track> items) {
        for (final track in items) {
          if (track.id.isEmpty || track.title.isEmpty) continue;
          if (seen.add(track.id)) collected.add(track);
        }
      }

      // 1) youtube_explode önerileri.
      try {
        final video = await _yt.videos.get(videoId).timeout(_requestTimeout);
        final related =
            await _yt.videos.getRelatedVideos(video).timeout(_requestTimeout);
        if (related != null) addAll(related.map(_fromVideo));
      } catch (_) {}

      // 2) InnerTube `next` yanıtı.
      addAll(await _relatedFromInnerTube(videoId, limit: limit));

      // 3) Her Invidious örneği ayrı ayrı denenir.
      addAll(await _invRecommended(videoId, limit));

      // 4) Önceki sonuçlar yalnızca tüm canlı kaynaklar boşsa kullanılır.
      if (collected.isEmpty) {
        addAll(_relatedCache[videoId] ?? const <Track>[]);
      }
      if (collected.isEmpty) return const <Track>[];

      _relatedCache[videoId] =
          List<Track>.unmodifiable(collected.take(_maxSearchResults));
      if (_relatedCache.length > _maxSearchEntries) {
        _relatedCache.remove(_relatedCache.keys.first);
      }

      // Oturum başına 50 parça sınırı radyoyu susturuyordu. Tekrar eden
      // parçaları çalar kendi kuyruğunda zaten ayıklıyor; burada tüm sonuçlar
      // döndürülür, böylece her yeni tohum parça kuyruğu büyütmeye devam eder.
      return collected.take(limit).toList();
    } catch (_) {
      return const <Track>[];
    }
  }

  Future<List<Track>> _relatedFromInnerTube(
    String videoId, {
    required int limit,
  }) async {
    for (final spec in _clients) {
      try {
        final response = await _innerTubePost(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/next'
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
            'context': {'client': spec['client']},
            'videoId': videoId,
          }),
        );
        if (response.statusCode != 200) continue;
        final data = jsonDecode(response.body);
        if (data is! Map) continue;
        final found = <Track>[];
        _collectVideoRenderers(data, found, limit);
        if (found.isNotEmpty) return found;
      } catch (_) {
        continue;
      }
    }
    return const <Track>[];
  }

  /// InnerTube `next` ağacındaki video/compactVideo/gridVideo renderer'larını
  /// derinlemesine toplar.
  void _collectVideoRenderers(
    Object? node,
    List<Track> out,
    int limit,
  ) {
    if (out.length >= limit) return;
    if (node is List) {
      for (final item in node) {
        if (out.length >= limit) return;
        _collectVideoRenderers(item, out, limit);
      }
      return;
    }
    if (node is! Map) return;

    final renderer = node['videoRenderer'] ??
        node['compactVideoRenderer'] ??
        node['gridVideoRenderer'];
    if (renderer is Map) {
      final id = renderer['videoId']?.toString() ?? '';
      final title = _textOf(renderer['title']);
      if (id.isNotEmpty && title.isNotEmpty) {
        final author = _textOf(renderer['ownerText']);
        out.add(Track(
          id: id,
          title: title,
          artist: author.isEmpty ? 'Bilinmeyen' : author,
        ));
      }
    }

    for (final value in node.values) {
      if (out.length >= limit) return;
      _collectVideoRenderers(value, out, limit);
    }
  }

  static String _textOf(Object? node) {
    if (node is String) return node.trim();
    if (node is! Map) return '';
    final simple = node['simpleText']?.toString().trim() ?? '';
    if (simple.isNotEmpty) return simple;
    final runs = node['runs'];
    if (runs is List) {
      return runs
          .map((run) => run is Map ? (run['text']?.toString() ?? '') : '')
          .join()
          .trim();
    }
    return '';
  }

  Future<List<Track>> _invRecommended(String videoId, int limit) async {
    final out = <Track>[];
    final seen = <String>{};
    final path = '/api/v1/videos/${Uri.encodeComponent(videoId)}';
    for (final base in _activeInvBases) {
      if (out.length >= limit) break;
      try {
        final response =
            await http.get(Uri.parse('$base$path')).timeout(_invTimeout);
        if (response.statusCode != 200) continue;
        final data = jsonDecode(response.body);
        if (data is! Map) continue;
        final recommendations = data['recommendedVideos'];
        if (recommendations is! List) continue;
        for (final item in recommendations.whereType<Map>()) {
          final track = _trackFromInv(item);
          if (track == null || track.id.isEmpty) continue;
          if (seen.add(track.id)) out.add(track);
          if (out.length >= limit) break;
        }
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  Future<void> _collectUploads(
    String channelId,
    List<Track> tracks,
    int limit,
  ) async {
    await for (final video in _yt.channels.getUploads(ChannelId(channelId))) {
      tracks.add(_fromVideo(video));
      if (tracks.length >= limit) break;
    }
  }

  /// Eski imza korunur; metadata'lı yeni API [artistPlaylist].
  Future<List<Track>> artistTracks(
    String name, {
    String? channelId,
    int limit = 60,
    bool refresh = false,
  }) async {
    if (channelId != null && channelId.isNotEmpty) {
      try {
        final tracks = <Track>[];
        await _collectUploads(channelId, tracks, limit)
            .timeout(_playlistTimeout);
        if (tracks.isNotEmpty) return tracks;
      } catch (_) {}
    }
    return search('$name en iyi şarkılar', limit: limit, refresh: refresh);
  }

  /// Sanatçı şarkılarını, UI'da ayrı çalma listesi olarak gösterilebilecek
  /// [PlaylistInfo] metadata'sıyla birlikte döner.
  Future<ArtistPlaylist> artistPlaylist(
    String channelId, {
    String? name,
    String? query,
  }) async {
    final id = channelId.trim();
    final cleanName = name?.trim() ?? '';
    final cleanQuery = query?.trim() ?? '';
    final title = cleanName.isNotEmpty
        ? cleanName
        : (cleanQuery.isNotEmpty ? cleanQuery : 'Sanatçı çalma listesi');
    List<Track> tracks = const <Track>[];
    if (id.isNotEmpty) {
      tracks = await artistTracks(title, channelId: id, limit: 60);
    }
    if (tracks.isEmpty && cleanQuery.isNotEmpty) {
      tracks = await search(cleanQuery, limit: 60);
    }
    final info = PlaylistInfo(
      id: id.isEmpty ? (cleanQuery.isNotEmpty ? cleanQuery : title) : id,
      title: title,
      author: title,
      thumbUrl: tracks.isEmpty ? null : tracks.first.thumb,
    );
    return ArtistPlaylist(
      info: info,
      tracks: List<Track>.unmodifiable(tracks),
    );
  }

  Uri? _cached(String id) {
    final uri = _cache[id];
    final at = _cachedAt[id];
    if (uri == null || at == null) return null;
    if (DateTime.now().difference(at) > _cacheTtl) {
      _dropUri(id);
      return null;
    }
    return uri;
  }

  void _dropUri(String id) {
    _cache.remove(id);
    _cachedAt.remove(id);
    _uriCheckedAt.remove(id);
  }

  void _remember(String id, Uri uri) {
    _cache[id] = uri;
    _cachedAt[id] = DateTime.now();
    _uriCheckedAt[id] = DateTime.now();
  }

  /// İmzalı URI'nin hâlâ geçerli olup olmadığını kontrol eder.
  ///
  /// YouTube imzalı googlevideo adresleri HEAD isteğine sık sık 403 döndürür;
  /// bu yüzden doğrulamayı atlarız, TTL zaten yeniden çözümü garanti eder.
  /// Diğer hostlarda 1 baytlık Range-GET, HEAD'den daha güvenilirdir.
  Future<bool> _isUriUsable(Uri uri) async {
    if (uri.host.endsWith('googlevideo.com')) return true;
    try {
      final response = await http.get(
        uri,
        headers: const <String, String>{'Range': 'bytes=0-0'},
      ).timeout(_requestTimeout);
      return !_staleUriStatuses.contains(response.statusCode);
    } catch (_) {
      return true;
    }
  }

  /// Tüm önbelleği temizler: çözülmüş ses adresleri, arama ve ilgili-parça
  /// sonuçları. Kullanıcı "önbelleği temizle" ya da kalite değiştirince
  /// bayat sonuçlar kalmaması için hepsi sıfırlanır.
  void clearCache() {
    _cache.clear();
    _cachedAt.clear();
    _uriCheckedAt.clear();
    _resolving.clear();
    _playability.clear();
    clearSearchCache();
  }

  /// Aynı parçanın çözümünü paylaşır: arka plandaki prefetch ile kullanıcı
  /// dokunması aynı future'ı bekler. İkinci YouTube isteği açılmaz.
  Future<Uri> uriFor(String id) {
    final running = _resolving[id];
    if (running != null) return running;
    late final Future<Uri> future;
    future = audioUri(id).whenComplete(() {
      if (identical(_resolving[id], future)) _resolving.remove(id);
    });
    _resolving[id] = future;
    return future;
  }

  /// Sonraki parçanın adresini arka planda ısıtır.
  Future<void> prefetch(String id) async {
    if (id.isEmpty || _cached(id) != null) return;
    try {
      await uriFor(id);
    } catch (_) {
      // Sessiz: kullanıcıya bağlantı bilgisi gösterilmez.
    }
  }

  /// Görünen arama/ liste satırlarını sınırlı sayıda ısıtır.
  Future<void> prefetchVisible(Iterable<String> ids) async {
    final targets = <String>{};
    for (final id in ids) {
      if (id.isEmpty || _cached(id) != null) continue;
      targets.add(id);
    }
    final limit = prefetchLimit(mobileData: mobileData);
    final selected = targets.take(limit).toList(growable: false);
    if (selected.isEmpty) return;
    await Future.wait(
      selected.map(prefetch),
      eagerError: false,
    );
  }

  /// Çözülmüş akış adresi. Önbellekte varsa doğrulayıp kullanır,
  /// bayatsa (403/410/404) anında invalide edip yeniden çözer.
  Future<Uri> audioUri(String id) async {
    final cached = _cached(id);
    if (cached != null) {
      final checked = _uriCheckedAt[id];
      final needsCheck = checked == null ||
          DateTime.now().difference(checked) > _uriValidationTtl;
      if (!needsCheck || await _isUriUsable(cached)) {
        _uriCheckedAt[id] = DateTime.now();
        return cached;
      }
      _dropUri(id);
    }
    return _resolve(id);
  }

  /// Eski çağrılar için uyumluluk takma adı.
  Future<Uri> fastUri(String id) => audioUri(id);

  /// Önbelleği atlayıp doğrudan çözümü farklı yollarla yeniden dener.
  Future<Uri?> forceDirect(String id) async {
    if (id.isEmpty) return null;
    _dropUri(id);
    _playability.remove(id);

    // 1) Tüm InnerTube istemcileri + Invidious ile taze çözüm.
    try {
      final uri = await _resolve(id).timeout(_resolveTimeout);
      if (await _isUriUsable(uri)) {
        _remember(id, uri);
        return uri;
      }
      _dropUri(id);
    } catch (_) {}

    // 2) Playability durumu sıfırlanmış ikinci geçiş.
    _playability.remove(id);
    try {
      final uri = await innerTube(id).timeout(_resolveTimeout);
      if (uri != null && await _isUriUsable(uri)) {
        _remember(id, uri);
        return uri;
      }
    } catch (_) {}

    // 3) youtube_explode manifest yedeği (kaliteye göre itag seçimi).
    try {
      final manifest = await _yt.videos.streamsClient
          .getManifest(id)
          .timeout(_resolveTimeout);
      final streams = manifest.audioOnly.toList();
      final playable =
          streams.where(_windowsPlayableStream).toList(growable: false);
      final itags = _specFor(quality).itags;
      for (final itag in itags) {
        for (final stream in playable) {
          if (stream.tag != itag) continue;
          if (await _isUriUsable(stream.url)) {
            _remember(id, stream.url);
            return stream.url;
          }
        }
      }
      playable.sort((a, b) => quality == 'low'
          ? a.bitrate.compareTo(b.bitrate)
          : b.bitrate.compareTo(a.bitrate));
      for (final stream in playable) {
        if (await _isUriUsable(stream.url)) {
          _remember(id, stream.url);
          return stream.url;
        }
      }
    } catch (_) {}

    return null;
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
    throw StateError(
        'Ses akışına ulaşılamadı. Bağlantınızı kontrol edip tekrar deneyin.');
  }

  Future<http.Response> _innerTubePost(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) =>
      http.post(url, headers: headers, body: body).timeout(_requestTimeout);

  /// Doğrudan InnerTube isteğiyle oynatılabilir ses adresini bulur.
  /// İstemciler eşzamanlı başlatılır; ilk çalışan yanıt kullanılır. Sıralı
  /// denemede ilk istemci 6 sn takıldığında parça açılışı 30 sn'ye çıkıyordu.
  Future<Uri?> innerTube(String id) async {
    final quality = this.quality;
    final spec = _specFor(quality);

    _playability.remove(id);
    final uri = await firstSuccess<Uri>([
      for (final client in _clients) _innerTubeClient(client, id, spec),
    ]);
    if (uri != null) return uri;

    // Son çare: birden fazla Invidious örneğinden local=true akış adresleri.
    final inv = await _invGet(
      '/api/v1/videos/${Uri.encodeComponent(id)}?local=true',
    );
    if (inv is Map) {
      final formats = <Map>[
        ...(inv['formatStreams'] as List? ?? const []).whereType<Map>(),
        ...(inv['adaptiveFormats'] as List? ?? const []).whereType<Map>(),
      ];
      final picked = await _pickAudioUri(formats, spec);
      if (picked != null) return picked;
    }

    // Çözülemezse null: oynatıcı aynı parçada hata gösterir, atlama yapmaz.
    return null;
  }

  /// Tek InnerTube istemcisi. Hata/engel durumunda null döner; diğer
  /// istemciler aynı anda çalışmaya devam eder.
  Future<Uri?> _innerTubeClient(
    Map<String, dynamic> client,
    String id,
    _QualitySpec spec,
  ) async {
    try {
      final response = await _innerTubePost(
        Uri.parse(
          'https://www.youtube.com/youtubei/v1/player'
          '?key=${client['key']}&prettyPrint=false',
        ),
        headers: {
          'content-type': 'application/json',
          'accept-language': 'en-US,en;q=0.9',
          'x-youtube-client-name': client['name'],
          'x-youtube-client-version': client['version'],
          'user-agent': client['ua'],
        },
        body: jsonEncode({
          'context': {
            'client': client['client'],
            'thirdParty': {'embedUrl': 'https://www.youtube.com'},
          },
          'videoId': id,
          'contentCheckOk': true,
          'racyCheckOk': true,
        }),
      );

      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is! Map) return null;

      final status = data['playabilityStatus'];
      if (status is Map && status['status'] is String) {
        final value = status['status'] as String;
        if (value != 'OK') {
          _playability[id] = value;
          return null;
        }
      }

      final streaming = data['streamingData'];
      if (streaming is! Map) return null;
      final formats = <Map>[
        ...(streaming['adaptiveFormats'] as List? ?? const []).whereType<Map>(),
        ...(streaming['formats'] as List? ?? const []).whereType<Map>(),
      ];
      return await _pickAudioUri(formats, spec);
    } catch (_) {
      // Bir istemci başarısızsa diğerleri devam eder.
      return null;
    }
  }

  static bool _isAudioFormat(Map format) {
    final mime = (format['mimeType'] ?? format['type'] ?? '').toString();
    if (mime.startsWith('audio/')) return true;
    final container = format['container']?.toString() ?? '';
    return container.startsWith('audio/');
  }

  static int? _itagOf(Map format) {
    final value = format['itag'];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static int _bitrateOf(Map format) {
    final value = format['bitrate'] ?? format['averageBitrate'] ?? 0;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static Uri? _uriOf(Map format) {
    final url = format['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    return Uri.tryParse(url);
  }

  /// Kalite kısıtına uyan ilk geçerli URI'yı döner. Eşleşme yoksa
  /// `low` en düşük, diğer seçenekler en yüksek bitrate'e düşer (hi-res/HDR).
  Future<Uri?> _pickAudioUri(List<Map> formats, _QualitySpec spec) async {
    final audio =
        formats.where(_isAudioFormat).where(_windowsPlayableFormat).toList();
    for (final itag in spec.itags) {
      for (final format in audio) {
        if (_itagOf(format) != itag) continue;
        final uri = _uriOf(format);
        if (uri != null && await _isUriUsable(uri)) return uri;
      }
    }
    if (audio.isEmpty) return null;
    audio.sort((a, b) => spec.preferHighestBitrate
        ? _bitrateOf(b).compareTo(_bitrateOf(a))
        : _bitrateOf(a).compareTo(_bitrateOf(b)));
    for (final format in audio) {
      final uri = _uriOf(format);
      if (uri != null && await _isUriUsable(uri)) return uri;
    }
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
}
