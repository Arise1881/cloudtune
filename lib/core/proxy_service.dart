import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'proxy_client_io.dart' if (dart.library.html) 'proxy_client_web.dart';

/// Kullanıcı tanımlı HTTP proxy ayarları.
///
/// Tüm değerler yalnızca cihazda saklanır. Okuma/yazma hatası olduğunda
/// sessizce varsayılan değerlerle devam edilir; kullanıcıya hata gösterilmez.
class ProxyService extends ChangeNotifier {
  ProxyService._();

  static final ProxyService instance = ProxyService._();

  static const String _keyEnabled = 'ct.proxy.enabled';
  static const String _keyServers = 'ct.proxy.servers';
  static const String _keySelected = 'ct.proxy.selectedIndex';
  static const String _keyLastUsed = 'ct.proxy.lastUsed';

  /// Kaydedilebilecek en fazla sunucu sayısı.
  static const int maxServers = 20;

  static const Duration _testTimeout = Duration(seconds: 4);
  static const String _testUrl = 'https://www.google.com';

  SharedPreferences? _prefs;
  Future<void>? _initFuture;

  bool _enabled = false;
  List<String> _servers = <String>[];
  int _selectedIndex = -1;
  String? _lastUsed;
  int _rotation = 0;

  bool get enabled => _enabled;
  List<String> get servers => List<String>.unmodifiable(_servers);
  int get selectedIndex => _selectedIndex;
  String? get lastUsed => _lastUsed;

  /// Kısa durum etiketi (ör. 'Kapalı', 'Otomatik · 3 sunucu').
  String get statusLabel {
    final count = _servers.length;
    if (!_enabled) return count == 0 ? 'Kapalı' : 'Kapalı · $count sunucu';
    if (count == 0) return 'Etkin · sunucu yok';
    if (_selectedIndex < 0 || _selectedIndex >= count) {
      return 'Otomatik · $count sunucu';
    }
    return 'Etkin · ${_servers[_selectedIndex]}';
  }

  /// Birden fazla çağrı aynı yükleme işini paylaşır.
  Future<void> init() => _initFuture ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      _enabled = prefs.getBool(_keyEnabled) ?? false;
      _servers = _normalizeServers(prefs.getStringList(_keyServers));
      _selectedIndex = prefs.getInt(_keySelected) ?? -1;
      _lastUsed = prefs.getString(_keyLastUsed);
      _clampSelection();
    } catch (_) {
      // Okunamazsa varsayılanlarla devam et.
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    await _saveBool(_keyEnabled, value);
  }

  Future<void> addServer(String address) async {
    final normalized = _normalizeServer(address);
    if (normalized == null) return;
    if (_servers.contains(normalized) || _servers.length >= maxServers) return;
    _servers.add(normalized);
    notifyListeners();
    await _saveServers();
  }

  Future<void> removeServer(int index) async {
    if (index < 0 || index >= _servers.length) return;
    _servers.removeAt(index);
    if (_selectedIndex == index) {
      _selectedIndex = -1;
    } else if (_selectedIndex > index) {
      _selectedIndex -= 1;
    }
    _clampSelection();
    notifyListeners();
    await _saveServers();
    await _saveInt(_keySelected, _selectedIndex);
  }

  /// -1 otomatik döndürme, aksi halde geçerli bir sunucu indeksi.
  Future<void> setSelected(int index) async {
    final next = (index >= 0 && index < _servers.length) ? index : -1;
    _selectedIndex = next;
    notifyListeners();
    await _saveInt(_keySelected, next);
  }

  /// Verilen adresin proxy olarak çalışıp çalışmadığını kısa bir istekle sınar.
  /// Hata, detay veya günlük üretmez; yalnızca true/false döner.
  Future<bool> testServer(String address) async {
    final uri = _parseServer(address);
    if (uri == null) return false;
    try {
      final client = ctProxiedClient(uri);
      try {
        final response = await client
            .head(Uri.parse(_testUrl))
            .timeout(_testTimeout);
        if (response.statusCode < 100 || response.statusCode > 599) {
          return false;
        }
      } finally {
        try {
          client.close();
        } catch (_) {}
      }
      final normalized = _normalizeServer(address);
      if (normalized != null) {
        _lastUsed = normalized;
        await _saveString(_keyLastUsed, normalized);
        notifyListeners();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Seçili sunucunun `host`, `port` adresi. Otomatik modda sırayla döner.
  Uri? currentUri() {
    if (_servers.isEmpty) return null;
    final index = (_selectedIndex >= 0 && _selectedIndex < _servers.length)
        ? _selectedIndex
        : _rotation++ % _servers.length;
    return _parseServer(_servers[index]);
  }

  void _clampSelection() {
    if (_selectedIndex < -1 || _selectedIndex >= _servers.length) {
      _selectedIndex = -1;
    }
  }

  List<String> _normalizeServers(List<String>? raw) {
    final result = <String>[];
    if (raw == null) return result;
    for (final item in raw) {
      final normalized = _normalizeServer(item);
      if (normalized == null || result.contains(normalized)) continue;
      result.add(normalized);
      if (result.length >= maxServers) break;
    }
    return result;
  }

  /// 'http://1.2.3.4:8080' veya '1.2.3.4:8080' -> '1.2.3.4:8080'.
  String? _normalizeServer(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;
    var candidate = trimmed;
    if (!candidate.contains('://')) candidate = 'http://$candidate';
    Uri? uri;
    try {
      uri = Uri.tryParse(candidate);
    } catch (_) {
      return null;
    }
    if (uri == null) return null;
    final host = uri.host;
    final port = uri.port;
    if (host.isEmpty || port < 1 || port > 65535) return null;
    return '$host:$port';
  }

  Uri? _parseServer(String address) {
    final normalized = _normalizeServer(address);
    if (normalized == null) return null;
    final colon = normalized.lastIndexOf(':');
    if (colon <= 0) return null;
    final host = normalized.substring(0, colon);
    final port = int.tryParse(normalized.substring(colon + 1));
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return Uri(host: host, port: port);
  }

  Future<SharedPreferences?> _store() async {
    final prefs = _prefs;
    if (prefs != null) return prefs;
    try {
      final loaded = await SharedPreferences.getInstance();
      _prefs = loaded;
      return loaded;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await _store();
    if (prefs == null) return;
    try {
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _saveInt(String key, int value) async {
    final prefs = await _store();
    if (prefs == null) return;
    try {
      await prefs.setInt(key, value);
    } catch (_) {}
  }

  Future<void> _saveString(String key, String value) async {
    final prefs = await _store();
    if (prefs == null) return;
    try {
      await prefs.setString(key, value);
    } catch (_) {}
  }

  Future<void> _saveServers() async {
    final prefs = await _store();
    if (prefs == null) return;
    try {
      await prefs.setStringList(_keyServers, _servers);
    } catch (_) {}
  }
}
