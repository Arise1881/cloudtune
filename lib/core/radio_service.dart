import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// radio-browser.info üzerindeki Türkiye istasyonları.
///
/// "Tüm Türk radyoları" sabit bir liste değil, güncel topluluk kataloğudur.
/// İstasyonlar çevrimiçi kontrol sonucuna göre filtrelenir; HLS/M3U8 ve
/// doğrudan MP3/AAC akışları aynı şekilde oynatılabilir.
class RadioStation {
  const RadioStation({
    required this.id,
    required this.name,
    required this.streamUrl,
    this.homepage = '',
    this.favicon = '',
    this.tags = '',
    this.state = '',
    this.codec = '',
    this.bitrate = 0,
    this.votes = 0,
    this.clickCount = 0,
    this.hls = false,
  });

  final String id;
  final String name;
  final String streamUrl;
  final String homepage;
  final String favicon;
  final String tags;
  final String state;
  final String codec;
  final int bitrate;
  final int votes;
  final int clickCount;
  final bool hls;

  /// Katalog logosu yoksa radyo kataloğunun kendi logosu kullanılır.
  /// Google favicon servisine istek gönderilmez.
  String get logoUrl {
    if (favicon.isNotEmpty) return favicon;
    return 'https://www.radio-browser.info/favicon.ico';
  }

  String get subtitle {
    final parts = <String>[];
    if (tags.isNotEmpty) {
      parts.addAll(tags
          .split(',')
          .map((tag) => tag.trim())
          .where(
            (tag) => tag.isNotEmpty,
          )
          .take(2));
    }
    if (state.isNotEmpty && !parts.contains(state)) parts.add(state);
    if (parts.isEmpty) parts.add('Türkiye');
    if (bitrate > 0) parts.add('$bitrate kbps');
    return parts.take(4).join(' · ');
  }

  Track toTrack() => Track(
        id: 'radio:$id',
        title: name,
        artist: subtitle,
        sourceUrl: streamUrl,
        coverUrl: logoUrl,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'streamUrl': streamUrl,
        'homepage': homepage,
        'favicon': favicon,
        'tags': tags,
        'state': state,
        'codec': codec,
        'bitrate': bitrate,
        'votes': votes,
        'clickCount': clickCount,
        'hls': hls,
      };

  factory RadioStation.fromJson(Map<String, dynamic> json) => RadioStation(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        streamUrl: json['streamUrl']?.toString() ?? '',
        homepage: json['homepage']?.toString() ?? '',
        favicon: json['favicon']?.toString() ?? '',
        tags: json['tags']?.toString() ?? '',
        state: json['state']?.toString() ?? '',
        codec: json['codec']?.toString() ?? '',
        bitrate: (json['bitrate'] as num?)?.toInt() ?? 0,
        votes: (json['votes'] as num?)?.toInt() ?? 0,
        clickCount: (json['clickCount'] as num?)?.toInt() ?? 0,
        hls: json['hls'] == true || json['hls'].toString() == '1',
      );

  static RadioStation? fromApi(Map<String, dynamic> json) {
    final id = json['stationuuid']?.toString() ?? '';
    final url = (json['url_resolved']?.toString() ?? '').isNotEmpty
        ? json['url_resolved'].toString()
        : json['url']?.toString() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    if (id.isEmpty || url.isEmpty || name.isEmpty) return null;
    return RadioStation(
      id: id,
      name: name,
      streamUrl: url,
      homepage: json['homepage']?.toString() ?? '',
      favicon: json['favicon']?.toString() ?? '',
      tags: json['tags']?.toString() ?? '',
      state: json['state']?.toString() ?? '',
      codec: json['codec']?.toString() ?? '',
      bitrate: (json['bitrate'] as num?)?.toInt() ?? 0,
      votes: (json['votes'] as num?)?.toInt() ?? 0,
      clickCount: (json['clickcount'] as num?)?.toInt() ?? 0,
      hls: json['hls'].toString() == '1',
    );
  }
}

class TurkishRadioService extends ChangeNotifier {
  TurkishRadioService._();

  static final TurkishRadioService instance = TurkishRadioService._();

  static const String _cacheKey = 'ct.turkish_radios.v1';
  static const int _pageSize = 1000;
  static const List<String> _mirrors = <String>[
    'https://de1.api.radio-browser.info',
    'https://fi1.api.radio-browser.info',
    'https://nl1.api.radio-browser.info',
  ];

  List<RadioStation> _all = <RadioStation>[];
  bool _loading = false;
  String? _error;
  Future<List<RadioStation>>? _future;

  List<RadioStation> get stations => List<RadioStation>.unmodifiable(_all);
  bool get loading => _loading;
  String? get error => _error;

  Future<List<RadioStation>> load({bool refresh = false}) {
    if (!refresh && _all.isNotEmpty) {
      return Future<List<RadioStation>>.value(stations);
    }
    final running = _future;
    if (running != null) return running;
    late final Future<List<RadioStation>> future;
    future = _load(refresh: refresh).whenComplete(() {
      if (identical(_future, future)) _future = null;
    });
    _future = future;
    return future;
  }

  Future<List<RadioStation>> _load({required bool refresh}) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      if (!refresh) {
        final cached = await _readCache();
        if (cached.isNotEmpty) {
          _all = cached;
          return stations;
        }
      }
      final fetched = await _fetchAll();
      if (fetched.isEmpty) throw const FormatException('Radyo listesi boş.');
      _all = fetched;
      await _writeCache(fetched);
      return stations;
    } catch (error) {
      _error = 'Radyo listesi alınamadı.';
      if (kDebugMode) debugPrint('CT radio load: $error');
      if (_all.isEmpty) {
        final cached = await _readCache();
        _all = cached;
        if (cached.isNotEmpty) _error = null;
      }
      return stations;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<List<RadioStation>> _fetchAll() async {
    Object? lastError;
    for (final base in _mirrors) {
      try {
        final uri = Uri.parse('$base/json/stations/search').replace(
          queryParameters: <String, String>{
            'countrycode': 'TR',
            'hidebroken': 'true',
            'lastcheckok': '1',
            'order': 'clickcount',
            'reverse': 'true',
            'limit': '$_pageSize',
            'offset': '0',
          },
        );
        final response = await http.get(
          uri,
          headers: <String, String>{
            'User-Agent': 'CloudTune/3.0.48 (TurkishRadioDirectory)',
            'Accept': 'application/json',
          },
        ).timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          throw StateError('HTTP ${response.statusCode}');
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! List) throw const FormatException('Geçersiz JSON.');
        final seen = <String>{};
        final result = <RadioStation>[];
        for (final item in decoded) {
          if (item is! Map<String, dynamic>) continue;
          final station = RadioStation.fromApi(item);
          if (station == null || !seen.add(station.id)) continue;
          result.add(station);
        }
        result.sort((a, b) {
          final byClicks = b.clickCount.compareTo(a.clickCount);
          return byClicks != 0
              ? byClicks
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
        return result;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('Radyo sunucusu yok.');
  }

  /// Kullanıcı bir istasyonu seçtiğinde popülerlik sayacını artırır.
  /// Oynatmayı bloklamaz; hata sessizce yok sayılır.
  void registerPlay(RadioStation station) {
    final uri = Uri.parse('${_mirrors.first}/json/url/${station.id}');
    unawaited(
      http
          .get(
            uri,
            headers: <String, String>{
              'User-Agent': 'CloudTune/3.0.48 (TurkishRadioDirectory)',
            },
          )
          .timeout(const Duration(seconds: 5))
          .catchError((Object _) => http.Response('', 500)),
    );
  }

  List<RadioStation> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return stations;
    return _all
        .where(
          (station) =>
              station.name.toLowerCase().contains(needle) ||
              station.tags.toLowerCase().contains(needle) ||
              station.state.toLowerCase().contains(needle),
        )
        .toList(growable: false);
  }

  Future<List<RadioStation>> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return <RadioStation>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <RadioStation>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(RadioStation.fromJson)
          .where((station) =>
              station.id.isNotEmpty && station.streamUrl.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return <RadioStation>[];
    }
  }

  Future<void> _writeCache(List<RadioStation> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode(list.map((station) => station.toJson()).toList()),
      );
    } catch (_) {}
  }
}
