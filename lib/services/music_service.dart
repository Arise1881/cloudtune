import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/search_content.dart';
import '../models/song.dart';

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

  /// Halka açık Invidious örnekleri — biri kapanırsa diğeri kullanılır.
  /// Canlılık 2026-09-17 ölçüldü: yalnız 200 dönen tutulur; ölü örnekler
  /// mobil veride 7sn'lik timeout zinciri yaratıyordu.
  static const List<String> _invidiousInstances = [
    'https://invidious.f5.si',
    'https://invidious.nerdvpn.de',
    'https://invidious.kavin.rocks',
    'https://inv.riverside.rocks',
    'https://invidious.myoxy.de',
    'https://invidious.projectsegfau.lt',
  ];

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

  /// Ayarlanmış akış sunucusu (proxy) taban adresi, ör. http://192.168.1.10:8800.
  /// YouTube 2025 sonrası tüm akışları po_token ile koruduğu için, kullanıcı
  /// kendi yt-dlp proxy'sini (melody-proxy/) buraya yazar. Boşsa yalnızca
  /// Invidious/InnerTube zinciri kullanılır.
  static String? proxyUrl;
  static const String _proxyKey = 'stream_proxy';

  /// Kayıtlı proxy adresini hafızadan yükler (uygulama açılışında çağrılır).
  /// Hiç kaydedilmemişse LAN'daki bilinen proxy hostlarını otomatik arar.
  static Future<void> loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_proxyKey)?.trim();
      final saved =
          (v == null || v.isEmpty) ? null : _stripTrailingSlash(v);
      proxyUrl = saved;
      if (saved == null) {
        proxyUrl = await _autoDiscover();
        if (proxyUrl != null) {
          await prefs.setString(_proxyKey, proxyUrl!);
        }
      }
    } catch (_) {}
  }

  /// Ayarlanan proxy bulunamazsa LAN'da bilinen host adlarını dener.
  static const List<String> _knownProxyHosts = [
    '10.0.2.2',
    '192.168.1.102',
    'melody-proxy.local',
  ];

  /// LAN proxy'sini sessizce arar; bulursa adresi döner, bulamazsa null.
  /// Tüm hostlar PARALEL denenir — sıralı deneme 4sn uygulama açılış zaman
  /// aşımını aşıyordu ve keşif yarıda ölüyordu.
  static Future<String?> _autoDiscover() async {
    final results = await Future.wait(_knownProxyHosts.map(_probeProxy));
    for (final base in results) {
      if (base != null) return base;
    }
    return null;
  }

  /// Tek host'a health ping atar. Başarılıysa base URL, değilse null döner.
  static Future<String?> _probeProxy(String host) async {
    final base = 'http://$host:8800';
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 1200);
      try {
        final req = await client
            .getUrl(Uri.parse('$base/health'))
            .timeout(const Duration(seconds: 2));
        final res = await req.close().timeout(const Duration(seconds: 2));
        await res.drain<void>().timeout(const Duration(seconds: 1));
        if (res.statusCode == HttpStatus.ok) {
          debugPrint('PROXY: otomatik keşif başarılı -> $base');
          return base;
        }
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('PROXY: $host bulunamadı ($e)');
    }
    return null;
  }

  /// Proxy adresini ayarlar ve kalıcı kaydeder. Boş/geçersiz → proxy kapalı.
  static Future<void> setProxy(String? url) async {
    final v = url?.trim() ?? '';
    proxyUrl = v.isEmpty ? null : _stripTrailingSlash(v);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (proxyUrl == null) {
        await prefs.remove(_proxyKey);
      } else {
        await prefs.setString(_proxyKey, proxyUrl!);
      }
    } catch (_) {}
  }

  static String _stripTrailingSlash(String v) =>
      v.replaceAll(RegExp(r'/+$'), '');

  /// Proxy üzerinden po_token destekli ses akış URL'leri. Dönmezse boş liste.
  Future<List<String>> _proxyStreamUrls(String videoId) async {
    final urls = <String>[];
    Future<void> addBase(String? base) async {
      if (base == null || base.isEmpty) return;
      final b = base.replaceAll(RegExp(r'/$'), '');
      // Hızlı sağlık kontrolü: tünel/proxy erişilebilir mi?
      // Geçici olarak her zaman ekle, sağlık kontrolü sorun yaratıyor olabilir
      // if (!await _baseReachable(b)) return;
      // En hızlı yol: sunucunun kendi akışını direkt dene. stream URL
      // çözümünü beklemek mobilde 5-10sn kaybettirirdi; üç format zinciri
      // her şarkıda en az birinin olmasını garanti eder.
      urls.add('$b/api/v1/relay?video_id=$videoId&format=140');
      urls.add('$b/api/v1/relay?video_id=$videoId&format=139');
      urls.add('$b/api/v1/relay?video_id=$videoId&format=251');
    }

    // Önce otomatik bulunan genel tünel (mobil verideki asıl kurtarıcı),
    // sonra kayıtlı LAN proxy'si. Yedek zincir ürettiği için adaylar
    // sırayla denenir: bir tanesi çalışırsa dinleyici döner.
    await addBase(await _autoTunnelUrl());
    await addBase(proxyUrl);
    return urls;
  }

  Future<bool> _baseReachable(String base) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final req = await client.getUrl(Uri.parse('$base/')).timeout(const Duration(seconds: 4));
      req.headers.set(HttpHeaders.userAgentHeader, _webUa);
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain();
      // Herhangi bir HTTP yanıtı gelmesi yeterli, 404 de erişilebilir demektir
      return res.statusCode >= 200 && res.statusCode < 600;
    } catch (_) {
      return false;
    }
  }

  /// Genel tünel adresi (trycloudflare) — sunucu bunu melody-dist/tunnel.txt
  /// dosyasında yayınlar; uygulama her ~6dk da bir tazeler. Böylece
  /// kullanıcının eli hiç değmez: mobil veride akış otomatik başlar.
  static String? _tunnelUrl;
  static DateTime? _tunnelFetchedAt;
  static bool _tunnelFetching = false;

  static Future<String?> _autoTunnelUrl() async {
    final now = DateTime.now();
    if (_tunnelUrl != null &&
        _tunnelFetchedAt != null &&
        now.difference(_tunnelFetchedAt!) < const Duration(seconds: 60)) {
      return _tunnelUrl;
    }
    if (_tunnelFetching) return _tunnelUrl;
    _tunnelFetching = true;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6);
      try {
        final req = await client.getUrl(Uri.parse(
            'https://raw.githubusercontent.com/Arise1881/melody-dist/main/tunnel.txt'));
        final res = await req.close().timeout(const Duration(seconds: 8));
        _tunnelFetchedAt = now;
        if (res.statusCode == HttpStatus.ok) {
          final body = await res.transform(utf8.decoder).join();
          final u = body.trim();
          if (u.startsWith('https://') || u.startsWith('http://')) {
            _tunnelUrl = u;
          }
        }
      } finally {
        client.close(force: true);
      }
    } catch (_) {}
    _tunnelFetching = false;
    return _tunnelUrl;
  }

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
  Future<dynamic> _invidious(String path) async {
    for (final base in _invidiousInstances) {
      final data = await _getJson('$base$path', timeout: const Duration(seconds: 7));
      if (data != null) return data;
    }
    throw StreamUnavailableException('Invidious örnekleri yanıt vermedi');
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

  /// Serbest video araması. InnerTube→Invidious→youtube_explode sırası.
  /// Tek bozuk sonuç listeyi çökertmez.
  Future<List<Song>> search(String query, {int limit = 25}) async {
    return _bounded(() async {
      // 0) Akış sunucusu (proxy) araması: yt-dlp ytsearch, öncelikli.
      final base = proxyUrl;
      if (base != null && base.isNotEmpty) {
        try {
          final data = await _getJson(
            '$base/api/v1/search?q=${Uri.encodeQueryComponent(query)}'
            '&limit=$limit',
            timeout: const Duration(seconds: 15),
          );
          if (data is Map && data['songs'] is List) {
            final songs = <Song>[];
            for (final it in data['songs'] as List) {
              if (it is! Map) continue;
              final id = it['videoId'];
              if (id is! String || id.isEmpty) continue;
              final secs = it['duration'] as num?;
              songs.add(Song(
                id: id,
                title: (it['title'] as String?) ?? query,
                artist: (it['channel'] as String?) ?? '',
                durationMs:
                    secs == null ? 0 : Duration(seconds: secs.toInt()).inMilliseconds,
                thumbnailUrl: (it['thumbnail'] as String?) ?? '',
              ));
              if (songs.length >= limit) break;
            }
            if (songs.isNotEmpty) return songs;
          }
        } catch (_) {}
      }

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
  /// 1) Invidious `/latest_version` redirect'leri (doğrudan googlevideo,
  ///    reklamsız) — doğrulanmış çalışan örnek.
  /// 2) InnerTube player.
  /// 3) Invidious videos endpoint'i.
  /// 4) youtube_explode manifest (son çare).
  Future<List<String>> streamUrlCandidates(String videoId) async {
    // 0) Ayarlanmış akış sunucusu (proxy): yt-dlp po_token çözümü, öncelikli.
    try {
      final proxy = await _proxyStreamUrls(videoId);
      if (proxy.isNotEmpty) return proxy;
    } catch (_) {}

    try {
      final latest = await _invidiousLatestWorking(videoId);
      if (latest.isNotEmpty) return latest;
    } catch (_) {}

    final urls = <String>[];
    void add(String u) {
      if (u.isNotEmpty && !urls.contains(u)) urls.add(u);
    }

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
      throw StreamUnavailableException('Akış çözülemedi');
    }

    // Türk mobil operatörleri googlevideo CDN bağlantısını IP düzeyinde
    // kısıtlayabiliyor. Doğrudan CDN adayları her zaman en sona; relay /
    // sunucu üzerinden giden adaylar (proxy, tünel, redirect) başa gelir.
    final inline = <String>[];
    final cdn = <String>[];
    for (final u in urls) {
      (u.contains('googlevideo') ? cdn : inline).add(u);
    }
    return [...inline, ...cdn];
  }

  /// Invidious `/latest_version` — her örnekte akış var mı diye HEAD atar,
  /// çalışan ilk örneğin itag URL'lerini döner (140=mp4, 139=düşük mp4,
  /// 251=opus). Redirect'i oynatıcı takip eder → doğrudan googlevideo akışı.
  Future<List<String>> _invidiousLatestWorking(String videoId) async {
    for (final base in _invidiousInstances) {
      if (await _rangeOk('$base/latest_version?id=$videoId&itag=140')) {
        return [
          '$base/latest_version?id=$videoId&itag=140',
          '$base/latest_version?id=$videoId&itag=139',
          '$base/latest_version?id=$videoId&itag=251',
        ];
      }
    }
    return const [];
  }

  /// Range isteği — URL gerçek bir medya dosyası mı (206/Content-Range)?
  /// HEAD yerine kısmi GET: bazı Invidious sunucuları HEAD'e 200/HTML dönüp
  /// yanlış pozitif üretiyordu.
  Future<bool> _rangeOk(String url) async {
    final t = const Duration(seconds: 5);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, _webUa);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final res = await req.close().timeout(t);
      final code = res.statusCode;
      final hasRange =
          res.headers.value(HttpHeaders.contentRangeHeader) != null;
      await res.drain<void>().catchError((_) {});
      return (code == HttpStatus.ok ||
              code == HttpStatus.partialContent) &&
          hasRange;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
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
    final chosen = <Map<String, dynamic>>[];
    for (final f in all) {
      final type = (f['type'] as String? ?? '')
          .toLowerCase()
          .replaceAll('audio/mp4;', 'audio/mp4') // gürültü normalization
          .contains('audio');
      final hasAudio = type ||
          (f['audioQuality'] as String?)?.isNotEmpty == true ||
          (f['bitrate'] as num?) != null;
      if (!hasAudio) continue;
      final url = f['url'] as String;
      if (!url.startsWith('https')) continue;
      chosen.add(f);
    }
    chosen.sort((a, b) {
      final aMp4 = (a['type'] as String).contains('mp4');
      final bMp4 = (b['type'] as String).contains('mp4');
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

  /// Şarkı radyosu: mevcut şarkıya benzer şarkılar bulur (YouTube Music tarzı).
  Future<List<Song>> radioFor(Song song) async {
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
  Future<List<Song>> playlistSongs(String playlistId,
      {int limit = 200}) async {
    try {
      final data = await _invidious('/api/v1/playlists/$playlistId');
      if (data is Map<String, dynamic>) {
        final videos = data['videos'];
        if (videos is List) {
          final songs = _songFromInvidiousList(videos)
              .where((s) => s.id.isNotEmpty)
              .take(limit)
              .toList();
          if (songs.isNotEmpty) return songs;
        }
      }
    } catch (_) {}

    return _bounded(() async {
      final songs = <Song>[];
      await for (final video in _yt.playlists.getVideos(playlistId)) {
        if (video.isLive) continue;
        try {
          songs.add(_videoToSong(video));
        } catch (_) {}
        if (songs.length >= limit) break;
      }
      return songs;
    });
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
    for (final base in _invidiousInstances) {
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
}