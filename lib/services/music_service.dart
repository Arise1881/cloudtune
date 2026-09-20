import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/music_source.dart';
import '../models/search_content.dart';
import '../models/song.dart';
import 'sources/audius_source.dart';
import 'sources/internet_archive_source.dart';

// ─── İstisna sınıfı ───
class StreamUnavailableException implements Exception {
  final String message;
  StreamUnavailableException(this.message);
  @override
  String toString() => "StreamUnavailableException: $message";
}

/// YouTube tabanlı müzik arama ve akış çözümleme servisi.
///
/// Çalma/arama akışı (reklamsız, doğrudan ses URL'leri):
///   1. InnerTube player API (youtubei/v1/player — çoklu client deneme)
///   2. Invidious ortak örnekleri (birden çok mirror, sırayla denenir)
///   3. youtube_explode_dart manifest (son çare)
class MusicService {
  MusicService._();
  static final MusicService instance = MusicService._();

  static const Duration _timeout = Duration(seconds: 30);
  static const String _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // ─── Ana sayfa önbelleği ───
  // Audius/IA istekleri tekrarlanmasın: aynı sorgu 10dk içinde bellekteki
  // sonucu döner. Ana sayfa açılışında (8+ küratör bölümü) ağ yükünü ve
  // bekleme süresini düşürür.
  static const Duration _homeCacheTtl = Duration(minutes: 10);
  static final Map<String, List<Song>> _homeCache = {};
  static final Map<String, DateTime> _homeCacheAt = {};

  /// Halka açık Invidious örnekleri — biri kapanırsa diğeri kullanılır.
  /// Canlılık 2026-09-18 ölçüldü: yalnız kısıtsız JSON dönen tutulur; ölü
  /// örnekler mobil veride 7sn'lik timeout zinciri yaratıyordu.
  /// Instance → bu instance `local=true` (kendi CDN'i üzerinden proxy akış)
  /// destekliyor mu? `local=true` googlevideo URL'sini instance'ın kendi
  /// host'una çevirir: Türk operatörlerinin googlevideo IP engelini bypass
  /// eder. darkness: EVET (206 audio/mp4 doğrulandı). f5.si: hayır (Anubis
  /// bot-koruması videoplayback yolunu HTML'ye çeviriyor). segfau: JSON hiç
  /// dönmüyor, local kapalı.
  static const Map<String, bool> _invidiousInstances = {
    'https://invidious.darkness.services': true,
    'https://invidious.ducks.party': true,
    'https://invidious.f5.si': false,
    'https://invidious.projectsegfau.lt': false,
  };

  /// Negatif önbellek: bir örnek son 10dk içinde yanıt vermediyse atlanır.
  static final Map<String, DateTime> _deadInvidious = {};

  /// Kullanıcının kendi Cloudflare Workers akış proxy'si
  /// (ör. `https://cloudtune-stream.<kullanıcı>.workers.dev`). Boşsa devre dışı.
  ///
  /// Proxy iki iş yapar: (1) `/v1/stream/{videoId}` ile ses URL'sini
  /// Cloudflare ağından çözer, (2) googlevideo akışını kendi üzerinden
  /// aktarır. Böylece Türk operatörlerinin googlevideo CDN IP engeli aşılır
  /// ve Invidious erişimi de gerektiğinde devreden çıkar.
  static final ValueNotifier<String?> proxyNotifier =
      ValueNotifier<String?>(null);
  static const String _kProxyUrl = 'stream_proxy_url';

  /// YouTube kaynağı açık mı? Varsayılan AÇIK (05-2026 isteği): birincil ve
  /// varsayılan kaynak YouTube; Audius + Internet Archive yedek kalır.
  static final ValueNotifier<bool> youtubeEnabledNotifier =
      ValueNotifier<bool>(true);
  static const String _kYoutubeEnabled = 'youtube_enabled';

  static bool get youtubeEnabled => youtubeEnabledNotifier.value;

  /// Uygulama açılışında YouTube kaynak ayarını yükler.
  /// Varsayılan AÇIK (madde 7: YouTube birincil kaynak, kişisel kapatabilir).
  static Future<void> loadYoutubeEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      youtubeEnabledNotifier.value = prefs.getBool(_kYoutubeEnabled) ?? true;
    } catch (_) {
      youtubeEnabledNotifier.value = true;
    }
  }

  /// Kullanıcı tercihini kaydeder ve notifier'ı günceller.
  static Future<void> setYoutubeEnabled(bool enabled) async {
    youtubeEnabledNotifier.value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kYoutubeEnabled, enabled);
    } catch (_) {}
  }

  /// Varsayılan ücretsiz proxy (kullanıcının Cloudflare Workers hesabı).
  /// Kullanıcı ayarlardan silerse ayar `''` olarak saklanır ve proxy kapanır;
  /// hiç kayıt yoksa bu varsayılan kullanılır.
  static const String _defaultProxyUrl =
      'https://23d9da7b-178f-424a-8f7d-671c7708445b.cfargotunnel.com';

  static String? get proxyBaseUrl => proxyNotifier.value;

  /// Proxy URL'sini sabit biçime getirir (sonundaki `/` temizlenir).
  static String? get _proxyBase {
    final v = proxyNotifier.value?.trim();
    if (v == null || v.isEmpty) return null;
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  /// Uygulama açılışında kayıtlı proxy URL'sini yükler. Kayıt yoksa
  /// varsayılan ücretsiz proxy kullanılır; `''` kayıtlıysa proxy kapalıdır.
  static Future<void> loadStreamProxy() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(_kProxyUrl)) {
        proxyNotifier.value = _defaultProxyUrl;
        return;
      }
      final v = prefs.getString(_kProxyUrl);
      proxyNotifier.value = (v == null || v.trim().isEmpty) ? null : v.trim();
    } catch (_) {
      proxyNotifier.value = _defaultProxyUrl;
    }
  }

  /// Proxy URL'sini kaydeder. Boş değer proxy'yi kapatır (`''` olarak saklanır).
  static Future<void> setStreamProxy(String? url) async {
    final v = (url == null || url.trim().isEmpty) ? null : url.trim();
    proxyNotifier.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kProxyUrl, v ?? '');
    } catch (_) {}
  }

  /// googlevideo URL'sini `/stream/<base64url>` yoluna çevirir.
  static String _proxyEncodedStreamUrl(String proxy, String url) =>
      '$proxy/stream/${base64Url.encode(utf8.encode(url)).replaceAll('=', '')}';

  /// Innertube player deneme sırası: bazı videolar için bazı istemciler
  /// akış döndürmez, diğerleri döndürür.
  static const List<Map<String, Object>> _playerClients = [
    {'name': 'WEB', 'version': '2.20240101.00.00'},
    {'name': 'WEB_EMBEDDED_PLAYER', 'version': '1.20240101.00.00'},
    {'name': 'ANDROID', 'version': '19.09.37'},
    {'name': 'IOS', 'version': '19.09.3'},
    {'name': 'TVHTML5', 'version': '7.20240101.00.00'},
  ];

  final YoutubeExplode _yt = YoutubeExplode();


  Future<T> _bounded<T>(Future<T> Function() task) {
    return task().timeout(_timeout, onTimeout: () {
      throw TimeoutException('İstek zaman aşımına uğradı');
    });
  }

  // ─── HTTP yardımcıları ───

  /// GET isteği → JSON. Hata durumunda null.
  Future<dynamic> _getJson(String url, {Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 8);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, _webUa);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(t);
      if (res.statusCode != HttpStatus.ok) return null;
      final raw = await res.transform(utf8.decoder).join().timeout(t);
      return jsonDecode(raw);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// POST isteği → JSON. Hata durumunda null.
  Future<dynamic> _postJson(String url, Map<String, Object?> body,
      {Map<String, String>? extraHeaders, Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 12);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, _webUa);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      extraHeaders?.forEach(req.headers.set);
      req.write(jsonEncode(body));
      final res = await req.close().timeout(t);
      if (res.statusCode != HttpStatus.ok) return null;
      final raw = await res.transform(utf8.decoder).join().timeout(t);
      return jsonDecode(raw);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Invidious: sırayla tüm örnekleri dener, ilk başarılı yanıtı döner.
  /// `local=true` destekleyen örneklerde akış URL'leri instance üzerinden
  /// proxy'lenir (googlevideo bypass). Sorgu-string path'lerde otomatik eklenir.
  Future<dynamic> _invidious(String path) async {
    for (final entry in _invidiousInstances.entries) {
      final base = entry.key;
      if (_invidiousDead(base)) continue;
      final local = entry.value
          ? '${path.contains('?') ? '&' : '?'}local=true'
          : '';
      final data = await _getJson('$base$path$local',
          timeout: const Duration(seconds: 7));
      if (data != null) return data;
      _deadInvidious[base] = DateTime.now();
    }
    throw StreamUnavailableException('Invidious örnekleri yanıt vermedi');
  }

  static bool _invidiousDead(String base) {
    final t = _deadInvidious[base];
    if (t == null) return false;
    // Proxy (local=true) destekleyen örnekler yalnız rate-limit'e takılır:
    // birkaç saniyede düzelir, uzun kara liste tüm akışları googlevideo'ya
    // (engelli CDN) düşürür. Kısa pencere yeter.
    final proxy = _invidiousInstances[base] == true;
    final window = proxy
        ? const Duration(seconds: 15)
        : const Duration(minutes: 10);
    return DateTime.now().difference(t) < window;
  }

  /// Onarım botu API'si: negatif önbelleği boşaltıp Invidious örneklerini
  /// yeniden denenebilir yapar (örnek kısa süre önce kapandıysa yeniden açar).
  static void refreshDeadInvidious() {
    if (_deadInvidious.isEmpty) return;
    _deadInvidious.clear();
  }

  /// Negatif önbellek içinde OLMAYAN (kısa süre içinde canlı doğrulanmış) sayaç.
  static int _liveInvidiousCount() =>
      _invidiousInstances.keys.where((b) => !_invidiousDead(b)).length;

  /// Onarım botu API'si: Invidious örneklerinden birine hızlı ping.
  /// Döner: yanıt süresi (ms), örneklerin tümü erişilemezse -1.
  Future<int> pingInvidious() async {
    final sw = Stopwatch()..start();
    for (final base in _invidiousInstances.keys) {
      if (_invidiousDead(base)) continue;
      final data = await _getJson(
          '$base/api/v1/search?q=test&type=video',
          timeout: const Duration(seconds: 5));
      if (data != null) {
        _deadInvidious.remove(base);
        sw.stop();
        return sw.elapsedMilliseconds;
      }
      _deadInvidious[base] = DateTime.now();
    }
    return -1;
  }

  /// Onarım botu API'si: mevcut ana sayfa önbellek boyutu (giriş sayısı).
  static int get homeCacheSize => _homeCache.length;

  /// Onarım botu API'si: süresi dolmuş ana sayfa önbellek girişlerini temizler,
  /// silinen giriş sayısını döner. Önbellek zaten doluysa bot eskileri atar.
  static int pruneHomeCache() {
    final now = DateTime.now();
    final keysToRemove = <String>[];
    _homeCacheAt.forEach((key, time) {
      if (now.difference(time) > _homeCacheTtl) {
        keysToRemove.add(key);
      }
    });
    for (final key in keysToRemove) {
      _homeCache.remove(key);
      _homeCacheAt.remove(key);
    }
    return keysToRemove.length;
  }

  /// Onarım botu API'si: akış URL önbelleği boyutu.
  int get streamUrlCacheSize => _streamUrlCache.length;

  /// Onarım botu API'si: akış URL önbelleğini boşaltır (şiştiğinde).
  void clearStreamUrlCache() {
    _streamUrlCache.clear();
    _sourceStreamCache.clear();
  }

  /// InnerTube player: çoklu client dener, akış içeren ilk yanıtı döner.
  Future<Map<String, dynamic>?> _innerTubePlayer(String videoId) async {
    for (final client in _playerClients) {
      final name = client['name'] as String;
      final version = client['version'] as String;
      final contextClient = <String, Object?>{'clientName': name, 'clientVersion': version};
      contextClient['hl'] = 'tr';
      contextClient['gl'] = 'TR';
      if (name == 'ANDROID') {
        contextClient['androidSdkVersion'] = 30;
        contextClient['osName'] = 'Android';
        contextClient['osVersion'] = '13';
      } else if (name == 'IOS') {
        contextClient['osName'] = 'iPhone';
        contextClient['osVersion'] = '17.2.0';
      }
      final body = <String, Object?>{
        'context': {'client': contextClient},
        'videoId': videoId,
        'racyCheckOk': true,
        'contentCheckOk': true,
      };
      final data = await _postJson(
        'https://www.youtube.com/youtubei/v1/player',
        body,
        extraHeaders: {
          'Origin': 'https://www.youtube.com',
          'Referer': 'https://www.youtube.com/watch?v=$videoId',
          'X-YouTube-Client-Name': '1',
          'X-YouTube-Client-Version': version,
        },
        timeout: const Duration(seconds: 10),
      );
      if (data is Map<String, dynamic>) {
        final sd = data['streamingData'];
        if (sd is Map<String, dynamic> &&
            (sd['formats'] is List || sd['adaptiveFormats'] is List)) {
          return data;
        }
      }
    }
    return null;
  }

  // ─── Arama ───

  /// Kapak: her zaman resmi YouTube CDN'i (invidious kapakları kararsız).
  String _thumbFallback(String videoId) =>
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

  Song _songFrom(
      {required String id,
      required String title,
      required String author,
      int durationMs = 0,
      String? thumbnail}) {
    return Song(
      id: id,
      title: title,
      artist: author,
      thumbnailUrl: _thumbFallback(id),
      durationMs: durationMs,
      source: MusicSourceType.youtube,
    );
  }

  /// Invidious arama sonucunu Song'a çevirir.
  Song? _songFromInvidious(dynamic item) {
    if (item is! Map<String, dynamic>) return null;
    final id = item['videoId'] as String?;
    if (id == null || id.isEmpty) return null;
    final thumbs = item['videoThumbnails'];
    String thumb = '';
    if (thumbs is List && thumbs.isNotEmpty) {
      final first = thumbs.first as Map<String, dynamic>;
      thumb = first['url'] as String? ?? '';
    }
    return _songFrom(
      id: id,
      title: item['title'] as String? ?? '',
      author: item['author'] as String? ?? '',
      durationMs: (((item['lengthSeconds'] as num?) ?? 0) * 1000).round(),
      thumbnail: thumb,
    );
  }

  /// Ana sayfa öne çıkanlar: Audius trending (güncel, keyless) önce,
  /// Internet Archive ile tamamlanır. YouTube zincirine düşmez.
  /// Sonuç 10dk önbellekte tutulur — ana sayfa her karede aynı isteği
  /// tekrarlamaz (izleyici izlerken Home yeniden kurulabilir).
  Future<List<Song>> trending({int limit = 24}) async {
    final key = 'trending:$limit';
    final cached = _homeCache[key];
    if (cached != null &&
        DateTime.now().difference(_homeCacheAt[key] ?? DateTime(0)) <
            _homeCacheTtl) {
      return cached;
    }
    final out = <Song>[];
    try {
      final songs =
          await AudiusSource.defaultHost().trending(limit: limit);
      for (final s in songs) {
        if (out.length >= limit) break;
        out.add(s);
      }
    } catch (_) {}
    if (out.length < limit) {
      try {
        final songs =
            await InternetArchiveSource().trending(limit: limit - out.length);
        for (final s in songs) {
          if (out.length >= limit) break;
          out.add(s);
        }
      } catch (_) {}
    }
    _homeCache[key] = out;
    _homeCacheAt[key] = DateTime.now();
    return out;
  }

  /// Kaynak bilinçli serbest arama. YouTube birincil (varsayılan açık),
  /// bulunamazsa Audius + Internet Archive yedek (paralel). YouTube kapalıysa
  /// yalnızca yasal bulut katalog kullanılır.
  ///
  /// Audius ve Internet Archive PARALEL sorgulanır; ilk dolu sonuç kazanır.
  /// Sıralı 12s+15s beklemek yerine tek ağ turu süresiyle döner. Sonuçlar
  /// ana sayfa önbelleğinde 10dk tutulur.
  Future<List<Song>> search(String query, {int limit = 25}) async {
    final key = 'search:$query:$limit';
    final cached = _homeCache[key];
    if (cached != null &&
        DateTime.now().difference(_homeCacheAt[key] ?? DateTime(0)) <
            _homeCacheTtl) {
      return cached;
    }
    if (youtubeEnabled) {
      final yt = await _searchYoutube(query, limit: limit);
      if (yt.isNotEmpty) {
        _homeCache[key] = yt;
        _homeCacheAt[key] = DateTime.now();
        return yt;
      }
    }
    final songs = await _firstFilled([
      AudiusSource.defaultHost().search(query, limit: limit),
      InternetArchiveSource().search(query, limit: limit),
    ]);
    _homeCache[key] = songs;
    _homeCacheAt[key] = DateTime.now();
    return songs;
  }

  /// Birden çok kaynağı aynı anda sorgular, ilk dolu sonucu döner.
  /// Tümü boş/hata ise boş liste. İstekleri iptal etmez ama caller'ı
  /// en yavaş kaynak kadar beklemez.
  Future<List<Song>> _firstFilled(
      List<Future<List<Song>>> futures) async {
    final completer = Completer<List<Song>>();
    var pending = futures.length;
    void settle(Future<List<Song>> f) {
      f.then((songs) {
        if (!completer.isCompleted && songs.isNotEmpty) {
          completer.complete(songs);
          return songs;
        }
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.complete(const []);
        }
        return songs;
      }, onError: (_) {
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.complete(const []);
        }
      });
    }

    for (final f in futures) {
      settle(f);
    }
    return completer.future;
  }

  /// Eski YouTube arama zinciri (Invidious → InnerTube → youtube_explode).
  Future<List<Song>> _searchYoutube(String query, {int limit = 25}) async {
    return _bounded(() async {
      // 1) Invidious arama (type=video — yalnızca şarkı)
      try {
        final data = await _invidious(
            '/api/v1/search?q=${Uri.encodeQueryComponent(query)}&type=video');
        if (data is List) {
          final songs = <Song>[];
          for (final item in data) {
            final s = _songFromInvidious(item);
            if (s == null || s.id.isEmpty) continue;
            songs.add(s);
            if (songs.length >= limit) break;
          }
          if (songs.isNotEmpty) return songs;
        }
      } catch (_) {}

      // 2) InnerTube arama (youtube_explode ile aynı kanal, daha güncel)
      try {
        final data = await _postJson(
          'https://www.youtube.com/youtubei/v1/search',
          {
            'context': {
              'client': {
                'clientName': 'WEB',
                'clientVersion': '2.20240101.00.00',
                'hl': 'tr',
                'gl': 'TR',
              }
            },
            'query': query,
          },
          extraHeaders: {
            'Origin': 'https://www.youtube.com',
            'Referer': 'https://www.youtube.com/',
          },
          timeout: const Duration(seconds: 10),
        );
        final items = _extractInnertubeVideos(data);
        if (items.isNotEmpty) {
          return items.take(limit).toList();
        }
      } catch (_) {}

      // 3) youtube_explode
      final results = await _yt.search.search(query);
      final songs = <Song>[];
      for (final v in results) {
        if (v.isLive) continue;
        try {
          songs.add(_videoToSong(v));
        } catch (_) {}
        if (songs.length >= limit) break;
      }
      return songs;
    });
  }

  /// Innertube arama yanıtından videoRenderer'ları toplar (reklamları atlar).
  List<Song> _extractInnertubeVideos(dynamic data) {
    final out = <Song>[];
    if (data is! Map<String, dynamic>) return out;
    final stack = <dynamic>[data];
    var guard = 0;
    while (stack.isNotEmpty && guard < 100000) {
      guard++;
      final node = stack.removeLast();
      if (node is! Map<String, dynamic>) continue;
      for (final entry in node.entries) {
        final val = entry.value;
        if (entry.key == 'videoRenderer' && val is Map<String, dynamic>) {
          final id = val['videoId'] as String?;
          if (id == null || id.isEmpty) continue;
          final title = _text(val['title']);
          var author = _text(val['ownerText']);
          if (author.isEmpty) {
            final ob = val['ownerButton'];
            author = _text(ob is Map<String, dynamic> ? ob['channelName'] : null);
          }
          String thumb = '';
          final th = val['thumbnail'];
          if (th is Map<String, dynamic>) {
            final arr = th['thumbnails'];
            if (arr is List && arr.isNotEmpty) {
              final last = arr.last as Map<String, dynamic>;
              thumb = last['url'] as String? ?? '';
            }
          }
          final lenTxt = _text(val['lengthText']);
          out.add(_songFrom(
            id: id,
            title: title,
            author: author,
            durationMs: _parseLenSec(lenTxt) * 1000,
            thumbnail: thumb,
          ));
        } else if (entry.key == 'adSlotRenderer' || entry.key == 'playerAds') {
          continue;
        } else {
          stack.add(val);
        }
      }
    }
    return out;
  }

  /// Videoyu Song'a dönüştürür (youtube_explode).
  Song _videoToSong(Video v) => _songFrom(
        id: v.id.value,
        title: v.title,
        author: v.author,
        durationMs: v.duration?.inMilliseconds ?? 0,
        thumbnail: v.thumbnails.highResUrl,
      );

  String _text(dynamic renderer) {
    if (renderer == null) return '';
    if (renderer is String) return renderer;
    if (renderer is! Map<String, dynamic>) return '';
    final runs = renderer['runs'];
    if (runs is List) {
      return runs
          .map((r) => r is Map<String, dynamic> ? r['text'].toString() : '')
          .join();
    }
    final simple = renderer['simpleText'];
    if (simple is String) return simple;
    return '';
  }

  int _parseLenSec(String s) {
    final parts = s.split(':');
    if (parts.isEmpty) return 0;
    var sec = 0;
    for (final p in parts) {
      final n = int.tryParse(p.trim());
      if (n == null) return 0;
      sec = sec * 60 + n;
    }
    return sec;
  }

  // ─── Akış URL'leri ───

  /// Video için denenebilir ses akış URL'leri (en iyi önce).
  /// 1) Invidious videos API (adaptiveFormats) — birincil.
  /// 2) InnerTube player (po_token bulunmuyorsa boş döner).
  /// 3) Invidious videos endpoint'i (tekrar deneme).
  /// 4) youtube_explode manifest (son çare).
  /// Sonuç: aracı (proxyless) adaylar başa, googlevideo CDN'leri en sona.
  Future<List<String>> streamUrlCandidates(String videoId) async {
    final urls = <String>[];
    final proxy = _proxyBase;
    void add(String u) {
      if (u.isNotEmpty && !urls.contains(u)) urls.add(u);
    }

    // 0) Kullanıcı Cloudflare Workers proxy'si tanımlıysa: tek adres hem
    //    ses URL'sini çözer hem CDN'i proxy'ler. En hızlı ve en güvenilir yol.
    if (proxy != null) {
      add('$proxy/v1/stream/$videoId');
    }

    // 1) Invidious videos API (adaptiveFormats) — doğrulanmış, en hızlı yol.
    try {
      final latest = await _invidiousLatestWorking(videoId);
      for (final u in latest) {
        add(u);
      }
    } catch (_) {}

    // InnerTube player (en güncel; ses adaptif formatları)
    try {
      final p = await _innerTubePlayer(videoId);
      for (final u in _audioUrlsFromStreamingData(p?['streamingData'])) {
        add(u);
      }
    } catch (_) {}

    // Invidious videos (adaptiveFormats)
    try {
      final data = await _invidious(
          '/api/v1/videos/$videoId?fields=adaptiveFormats,formatStreams');
      if (data is Map<String, dynamic>) {
        for (final u in _audioUrlsFromInvidious(data)) {
          add(u);
        }
      }
    } catch (_) {}

    // youtube_explode manifest (son çare)
    try {
      final audio = await _audioStreams(videoId);
      for (final s in audio) {
        add(s.url.toString());
      }
    } catch (_) {}

    if (urls.isEmpty) {
      throw StreamUnavailableException(
          'Akış çözülemedi (Invidious: ${_liveInvidiousCount()}/${_invidiousInstances.length} kaynak canlı)');
    }

    // Türk mobil operatörleri googlevideo CDN bağlantısını IP düzeyinde
    // kısıtlayabiliyor. Sıralama:
    //   1. Proxy'lenmiş googlevideo adayları (Cloudflare Workers üzerinden)
    //   2. Aracı (invidious) inline adaylar
    //   3. Doğrudan googlevideo CDN adayları (en son çare)
    final proxied = <String>[];
    final inline = <String>[];
    final cdn = <String>[];
    for (final u in urls) {
      if (u.contains('googlevideo')) {
        cdn.add(u);
        if (proxy != null) proxied.add(_proxyEncodedStreamUrl(proxy, u));
      } else {
        inline.add(u);
      }
    }
    return [...proxied, ...inline, ...cdn];
  }

  /// Invidious videos API'den gerçek ses akış URL'lerini alır. `/latest_version`
  /// endpoint'i artık çoğu örnekte bot-challenge/companion sayfasına (302 HTML)
  /// düşüyor, o yüzden doğrudan adaptiveFormats JSON'u tercih edilir.
  /// `local=true` destekleyen örneklerde (darkness) URL'ler instance'ın kendi
  /// CDN'i üzerinden proxy'lenir: googlevideo IP engeli bypass edilir.
  Future<List<String>> _invidiousLatestWorking(String videoId) async {
    for (final entry in _invidiousInstances.entries) {
      final base = entry.key;
      if (_invidiousDead(base)) continue;
      final local = entry.value ? '&local=true' : '';
      final maxAttempts = entry.value ? 4 : 2;
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        if (attempt > 0) {
          await Future.delayed(Duration(milliseconds: 350 * attempt));
        }
        try {
          final data = await _getJson(
            '$base/api/v1/videos/$videoId?fields=adaptiveFormats$local',
            timeout: const Duration(seconds: 7),
          );
          if (data is Map<String, dynamic>) {
            final urls = _audioUrlsFromInvidious(data);
            if (urls.isNotEmpty) {
              // Başarılı: bu örneği canlı say, sıradaki aramalarda da dene.
              _deadInvidious.remove(base);
              return urls;
            }
            // Boş media: rate-limit'e takılmış olabilir — bir retry daha.
            continue;
          }
        } catch (_) {}
      }
      _deadInvidious[base] = DateTime.now();
    }
    return const [];
  }

  /// streamingData'dan ses URL'lerini çıkarır (en iyi önce, mp4/m4a tercih).
  List<String> _audioUrlsFromStreamingData(dynamic sd) {
    final out = <String>[];
    if (sd is! Map<String, dynamic>) return out;
    final all = <Map<String, dynamic>>[];
    for (final key in ['adaptiveFormats', 'formats']) {
      final list = sd[key];
      if (list is List) {
        for (final f in list) {
          if (f is Map<String, dynamic>) all.add(f);
        }
      }
    }
    final chosen = <Map<String, dynamic>>[];
    for (final f in all) {
      final mime = f['mimeType'] as String? ?? '';
      if (!mime.startsWith('audio/')) continue;
      final url = f['url'] as String?;
      if (url == null || !url.startsWith('https')) continue;
      chosen.add(f);
    }
    // Tümü sıralı: bitrate + mp4/m4a öncelik
    chosen.sort((a, b) {
      final aMp4 = (a['mimeType'] as String).contains('mp4');
      final bMp4 = (b['mimeType'] as String).contains('mp4');
      if (aMp4 != bMp4) return aMp4 ? -1 : 1;
      final aBr = (a['bitrate'] as num?) ?? 0;
      final bBr = (b['bitrate'] as num?) ?? 0;
      return bBr.compareTo(aBr);
    });
    for (final f in chosen) {
      out.add(f['url'] as String);
    }
    // Format içinde sesi olmayan tekli (itag 18) de ekle — son çare.
    for (final f in all) {
      final url = f['url'] as String?;
      if (url != null && url.startsWith('https') && !out.contains(url)) {
        out.add(url);
      }
    }
    return out;
  }

  List<String> _audioUrlsFromInvidious(Map<String, dynamic> data) {
    final out = <String>[];
    final all = <Map<String, dynamic>>[];
    for (final key in ['adaptiveFormats', 'formatStreams']) {
      final list = data[key];
      if (list is List) {
        for (final f in list) {
          if (f is Map<String, dynamic> && f['url'] is String) all.add(f);
        }
      }
    }
    // itag bazı Invidious sürümlerinde sayı, bazılarında string gelir.
    int? itagOf(Map<String, dynamic> f) {
      final v = f['itag'];
      if (v is String) return int.tryParse(v);
      if (v is num) return v.toInt();
      return null;
    }
    final chosen = <Map<String, dynamic>>[];
    for (final f in all) {
      // Eski Invidious: mimeType. Yeni Invidious: type. İkisi de olabilir.
      final raw = (f['mimeType'] ?? f['type'] ?? '').toString().toLowerCase();
      final isMp4 = raw.contains('mp4') || raw.contains('m4a');
      final itag = itagOf(f);
      final hasAudio = raw.contains('audio') ||
          (f['audioQuality'] as String?)?.isNotEmpty == true ||
          (f['audioChannels'] as num?) != null ||
          itag == 140 ||
          itag == 139 ||
          itag == 251 ||
          itag == 18;
      if (!hasAudio) continue;
      final url = f['url'] as String;
      if (!url.startsWith('https')) continue;
      f['_isMp4'] = isMp4;
      chosen.add(f);
    }
    chosen.sort((a, b) {
      final aMp4 = a['_isMp4'] == true;
      final bMp4 = b['_isMp4'] == true;
      if (aMp4 != bMp4) return aMp4 ? -1 : 1;
      final aBr = (a['bitrate'] as num?) ?? 0;
      final bBr = (b['bitrate'] as num?) ?? 0;
      return bBr.compareTo(aBr);
    });
    for (final f in chosen) {
      out.add(f['url'] as String);
    }
    return out;
  }

  /// En iyi ses akış URL'sini çözer.
  Future<String> resolveStreamUrl(String videoId) async {
    final c = await streamUrlCandidates(videoId);
    if (c.isEmpty) throw StreamUnavailableException('Ses akışı bulunamadı');
    return c.first;
  }

  /// Belirtilen kalitede ses akış URL'sini çözer (YouTube Music benzeri).
  void cacheStreamUrl(String videoId, String url) {
    if (url.isNotEmpty) _streamUrlCache[videoId] = url;
  }

  /// Kaliteye göre sıralı akış adayları döner: çalma motoru bir aday
  /// "source error" verirse sıradakini dener.
  Future<List<String>> streamCandidatesWithQuality(String videoId,
      {String quality = 'auto'}) async {
    final candidates = await streamUrlCandidates(videoId);
    if (candidates.isEmpty) {
      throw StreamUnavailableException('Ses akışı bulunamadı');
    }
    switch (quality) {
      case 'high':
      case 'ultra':
        return List.of(candidates);
      case 'medium':
        return [
          candidates[candidates.length ~/ 2],
          ...candidates,
        ];
      case 'low':
        return [
          candidates.last,
          ...candidates,
        ];
      default:
        return List.of(candidates);
    }
  }

  /// Kaynak bilinçli akış adayları: Song.source'a göre doğru kaynağa
  /// yönlendirir (Audius tek istek 302, Internet Archive metadata+seçim,
  /// YouTube eski sıralı zincir).
  Future<List<String>> streamCandidatesForSong(Song song,
      {String quality = 'auto'}) async {
    switch (song.source) {
      case MusicSourceType.audius:
        try {
          final url = await AudiusSource.defaultHost().streamUrl(trackId: song.id);
          return url.isEmpty ? const [] : [url];
        } catch (_) {
          return const [];
        }
      case MusicSourceType.internetArchive:
        try {
          return await InternetArchiveSource().streamCandidates(song);
        } catch (_) {
          return const [];
        }
      case MusicSourceType.youtube:
        if (!youtubeEnabled) return const [];
        return streamCandidatesWithQuality(song.id, quality: quality);
    }
  }

  /// Kaynak bilinçli tek URL çözümü: player ana girişi.
  Future<String> resolveStreamUrlForSong(Song song,
      {String quality = 'auto'}) async {
    final cacheKey = '${song.source.name}:${song.id}';
    final cached = _sourceStreamCache[cacheKey];
    if (cached != null) return cached;

    final candidates = await streamCandidatesForSong(song, quality: quality);
    if (candidates.isEmpty) {
      throw StreamUnavailableException('Ses akışı bulunamadı');
    }
    final url = switch (quality) {
      'low' => candidates.last,
      _ => candidates.first,
    };
    if (url.isNotEmpty) _sourceStreamCache[cacheKey] = url;
    return url;
  }

  Future<String> resolveStreamUrlWithQuality(String videoId,
      {String quality = 'auto'}) async {
    final cached = _streamUrlCache[videoId];
    if (cached != null) return cached;

    final candidates = await streamUrlCandidates(videoId);
    if (candidates.isEmpty) {
      throw StreamUnavailableException('Ses akışı bulunamadı');
    }

    String result;
    switch (quality) {
      case 'high':
      case 'ultra':
        result = candidates.first;
      case 'medium':
        result = candidates[candidates.length ~/ 2];
      case 'low':
        result = candidates.last;
      default:
        result = candidates.first;
    }

    _streamUrlCache[videoId] = result;
    return result;
  }

  Future<List<AudioOnlyStreamInfo>> _audioStreams(String videoId) async {
    final manifest = await _bounded(() => _yt.videos.streams.getManifest(videoId));
    final audio = manifest.audioOnly.toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return audio;
  }

  // ─── Radyo ───

  /// Şarkı radyosu: mevcut şarkıya benzer şarkılar bulur. Kaynak bilinçli:
  /// Audius → relatedTracks (hızlı), Internet Archive → aynı koleksiyon,
  /// YouTube → eski benzerlik araması.
  Future<List<Song>> radioFor(Song song) async {
    try {
      switch (song.source) {
        case MusicSourceType.audius:
          final related = await AudiusSource.defaultHost()
              .relatedTracks(song.id, limit: 20);
          if (related.isNotEmpty) {
            return related.where((s) => s.id != song.id).toList();
          }
        case MusicSourceType.internetArchive:
          final related = await InternetArchiveSource().radioForSong(song);
          if (related.isNotEmpty) {
            return related.where((s) => s.id != song.id).toList();
          }
        case MusicSourceType.youtube:
          break;
      }
    } catch (_) {}

    if (!youtubeEnabled) return const [];
    final query = '${song.title} ${song.artist}';
    final songs = await search('$query benzerleri', limit: 20);
    if (songs.isNotEmpty) {
      return songs.where((s) => s.id != song.id).toList();
    }
    return _songFromInvidiousList(await _invidiousSearchSafe(query))
        .where((s) => s.id != song.id)
        .toList();
  }

  Future<dynamic> _invidiousSearchSafe(String query) async {
    try {
      return await _invidious(
          '/api/v1/search?q=${Uri.encodeQueryComponent(query)}&type=video');
    } catch (_) {
      return const [];
    }
  }

  List<Song> _songFromInvidiousList(dynamic data) {
    if (data is! List) return const [];
    final songs = <Song>[];
    for (final item in data) {
      final s = _songFromInvidious(item);
      if (s != null && s.id.isNotEmpty) songs.add(s);
    }
    return songs;
  }

  /// Sanatçı diskografisini getirir. Invidious→Innertube→youtube_explode.
  Future<List<Song>> artistSongs(String artist, {int limit = 30}) async {
    return _bounded(() async {
      for (final query in ['$artist şarkıları', '$artist hit şarkılar', artist]) {
        try {
          final songs = await search(query, limit: limit);
          if (songs.isNotEmpty) return songs;
        } catch (_) {}
      }
      return const [];
    });
  }

  // ─── Sanatçı ve çalma listesi araması ───

  /// Sanatçı (kanal) araması. Invidious→youtube_explode.
  Future<List<SearchArtist>> searchArtists(String query, {int limit = 15}) async {
    try {
      final data = await _invidious(
          '/api/v1/search?q=${Uri.encodeQueryComponent(query)}&type=channel');
      if (data is List) {
        final artists = <SearchArtist>[];
        for (final item in data) {
          if (item is! Map<String, dynamic>) continue;
          final id = (item['channelId'] as String?) ?? (item['authorId'] as String?);
          if (id == null || id.isEmpty) continue;
          String thumb = '';
          final thumbs = item['authorThumbnails'];
          if (thumbs is List && thumbs.isNotEmpty) {
            final first = thumbs.first as Map<String, dynamic>;
            thumb = first['url'] as String? ?? '';
          }
          artists.add(SearchArtist(
            id: id,
            name: item['author'] as String? ?? '',
            thumbnailUrl: thumb,
          ));
          if (artists.length >= limit) break;
        }
        if (artists.isNotEmpty) return artists;
      }
    } catch (_) {}

    try {
      final results =
          await _bounded(() => _yt.search.search(query, filter: TypeFilters.channel));
      return results.whereType<SearchChannel>().take(limit).map((ch) {
        return SearchArtist(
          id: ch.id.value,
          name: ch.name,
          thumbnailUrl: ch.thumbnails.isNotEmpty
              ? ch.thumbnails.first.url.toString()
              : '',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Çalma listesi araması. Invidious→youtube_explode.
  Future<List<PlaylistInfo>> searchPlaylists(
      String query, {int limit = 15}) async {
    try {
      final data = await _invidious(
          '/api/v1/search?q=${Uri.encodeQueryComponent(query)}&type=playlist');
      if (data is List) {
        final playlists = <PlaylistInfo>[];
        for (final item in data) {
          if (item is! Map<String, dynamic>) continue;
          final id = item['playlistId'] as String?;
          if (id == null || id.isEmpty) continue;
          String thumb = '';
          final videos = item['videos'];
          if (videos is List && videos.isNotEmpty) {
            final first = _songFromInvidious(videos.first);
            thumb = first?.thumbnailUrl ?? '';
          }
          playlists.add(PlaylistInfo(
            id: id,
            title: item['title'] as String? ?? '',
            videoCount: ((item['videoCount'] as num?) ?? 0).toInt(),
            thumbnailUrl: thumb,
          ));
          if (playlists.length >= limit) break;
        }
        if (playlists.isNotEmpty) return playlists;
      }
    } catch (_) {}

    try {
      final results =
          await _bounded(() => _yt.search.search(query, filter: TypeFilters.playlist));
      return results.whereType<SearchPlaylist>().take(limit).map((pl) {
        return PlaylistInfo(
          id: pl.id.value,
          title: pl.title,
          videoCount: pl.videoCount,
          thumbnailUrl: pl.thumbnails.isNotEmpty
              ? pl.thumbnails.first.url.toString()
              : '',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Çalma listesi ID'sindeki şarkıları çözer. Invidious→youtube_explode.
  /// Invidious tek istekte ~100 şarkıda kesilebilir; eksik kalan şarkılar
  /// youtube_explode'un sürekli sayfalamasıyla tamamlanır (continuation).
  Future<List<Song>> playlistSongs(String playlistId,
      {int limit = 200}) async {
    final songs = <Song>[];
    try {
      final data = await _invidious('/api/v1/playlists/$playlistId');
      if (data is Map<String, dynamic> && data['videos'] is List) {
        songs.addAll(_songFromInvidiousList(data['videos'] as List)
            .where((s) => s.id.isNotEmpty));
      }
    } catch (_) {}

    if (songs.length >= limit) return songs.sublist(0, limit);

    // Continuation fallback: Invidious sonu verdiği yerde devam edilir.
    final known = songs.map((s) => s.id).toSet();
    await _bounded(() async {
      await for (final video in _yt.playlists.getVideos(playlistId)) {
        if (video.isLive) continue;
        try {
          final song = _videoToSong(video);
          if (known.add(song.id)) songs.add(song);
        } catch (_) {}
        if (songs.length >= limit) break;
      }
    });
    return songs;
  }

  /// YouTube / YouTube Music çalma listesi URL'sinden şarkıları çözer.
  ///   https://www.youtube.com/playlist?list=PLxxxx
  ///   https://music.youtube.com/playlist?list=PLxxxx
  ///   https://youtube.com/watch?v=...&list=PLxxxx (karma listeler)
  Future<List<Song>> importPlaylistUrl(String url) async {
    final listMatch = RegExp(r'[?&]list=([\w-]+)').firstMatch(url);
    var id = listMatch?.group(1);
    if (id == 'RDAM' || id == null || id.isEmpty) {
      throw const FormatException('Geçerli bir çalma listesi bağlantısı değil');
    }
    return playlistSongs(id);
  }

  // ─── Söz ───

  /// Şarkı sözlerini indirir. Önce YouTube altyazılarını (söz) dener.
  Future<String> fetchLyrics(Song song) async {
    try {
      final captions =
          await _bounded(() => _yt.videos.closedCaptions.getManifest(song.id));
      if (captions.tracks.isNotEmpty) {
        final track = captions.tracks.firstWhere(
          (t) => t.language.code == 'tr' || t.language.code == 'en',
          orElse: () => captions.tracks.first,
        );
        final info = await _bounded(() => _yt.videos.closedCaptions.get(track));
        final lines = info.captions
            .map((c) => c.text.replaceAll('\n', ' ').trim())
            .where((t) => t.isNotEmpty)
            .toList();
        return lines.join(' ');
      }
    } catch (_) {}

    // Invidious altyazı fallback (birden çok örnek denenir)
    try {
      final txt = await _invidiousCaption(song.id);
      if (txt.isNotEmpty) return txt;
    } catch (_) {}
    return '';
  }

  /// Invidious üzerinden altyazı (söz) metnini getirir.
  Future<String> _invidiousCaption(String videoId) async {
    for (final entry in _invidiousInstances.entries) {
      final base = entry.key;
      try {
        final data =
            await _getJson('$base/api/v1/captions/$videoId', timeout: const Duration(seconds: 7));
        if (data is! List || data.isEmpty) continue;
        Map<String, dynamic>? pick;
        for (final t in data) {
          if (t is! Map<String, dynamic>) continue;
          final lang = (t['language_code'] as String? ?? '').toLowerCase();
          if (lang == 'tr' || lang == 'en') {
            pick = t;
            break;
          }
        }
        pick ??= data.first is Map<String, dynamic> ? data.first as Map<String, dynamic> : null;
        final label = pick?['label'] as String?;
        if (label == null || label.isEmpty) continue;
        final txt = await _invidiousCaptionText(
            '$base/api/v1/captions/$videoId?label=${Uri.encodeQueryComponent(label)}');
        if (txt.isNotEmpty) return txt;
      } catch (_) {}
    }
    return '';
  }

  Future<String> _invidiousCaptionText(String url) async {
    final t = const Duration(seconds: 7);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, _webUa);
      final res = await req.close().timeout(t);
      if (res.statusCode != HttpStatus.ok) return '';
      final raw = await res.transform(utf8.decoder).join().timeout(t);
      final lines = raw
          .split('\n')
          .map((l) => l.trim())
          .where((l) =>
              l.isNotEmpty &&
              !l.startsWith('WEBVTT') &&
              !l.contains('-->') &&
              !RegExp(r'^\d{1,2}:\d{2}(:\d{2})?\s*$').hasMatch(l))
          .toList();
      return lines.join(' ');
    } catch (_) {
      return '';
    } finally {
      client.close(force: true);
    }
  }

  // ─── Önbellek ───

  final Map<String, String> _streamUrlCache = {};
  final Map<String, String> _sourceStreamCache = {};
}