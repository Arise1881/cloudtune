import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library.dart';
import 'models.dart';

/// A CloudTune device seen on the local network through a UDP beacon.
class DiscoveredDevice {
  DiscoveredDevice({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String id;
  final String name;
  final String address;
  final int port;
  final DateTime lastSeen;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'address': address,
        'port': port,
        'lastSeen': lastSeen.millisecondsSinceEpoch,
      };

  factory DiscoveredDevice.fromJson(Map<String, dynamic> json) =>
      DiscoveredDevice(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        address: '${json['address'] ?? ''}',
        port: (json['port'] as num?)?.toInt() ?? 0,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(
          (json['lastSeen'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
      );
}

/// Peer-to-peer library sync restricted to the local area network.
///
/// Every operation is best-effort. Sockets, timers, HTTP handlers and storage
/// access are guarded so a failure never escapes to the caller and never
/// produces user-visible output.
class LocalSyncService extends ChangeNotifier {
  LocalSyncService._();

  static final LocalSyncService instance = LocalSyncService._();

  static const int discoveryPort = 45671;
  static const int httpPort = 45672;

  static const List<String> allCategories = <String>[
    'playlists',
    'history',
    'liked',
    'downloads',
    'settings',
  ];

  static const String _prefix = 'ct.sync.';
  static const String _kId = '${_prefix}id';
  static const String _kSuffix = '${_prefix}suffix';
  static const String _kEnabled = '${_prefix}enabled';
  static const String _kAutoSync = '${_prefix}autoSync';
  static const String _kDeviceName = '${_prefix}deviceName';
  static const String _kPairedIds = '${_prefix}pairedIds';
  static const String _kEndpoints = '${_prefix}endpoints';
  static const String _kLastSyncedAt = '${_prefix}lastSyncedAt';
  static const String _kCategories = '${_prefix}categories';

  static const Duration _pinLifetime = Duration(minutes: 5);
  static const Duration _deviceExpiry = Duration(seconds: 20);
  static const Duration _beaconInterval = Duration(seconds: 4);

  SharedPreferences? _prefs;
  bool _ready = false;
  bool _starting = false;
  int _startToken = 0;

  bool _enabled = false;
  bool _autoSync = false;
  bool _running = false;
  String _id = '';
  String _suffix = '';
  String _deviceName = 'CloudTune';
  String _currentPin = '';
  DateTime _pinIssuedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastSyncedAt;

  final Set<String> _pairedIds = <String>{};
  final Set<String> _categories = allCategories.toSet();
  final Map<String, String> _endpoints = <String, String>{};
  final List<DiscoveredDevice> _devices = <DiscoveredDevice>[];

  RawDatagramSocket? _discoverySocket;
  HttpServer? _server;
  Timer? _beaconTimer;
  Timer? _expiryTimer;

  final InternetAddress _broadcastAny = InternetAddress('255.255.255.255');
  final InternetAddress _broadcastSubnet = InternetAddress('192.255.255.255');

  bool get running => _running;
  bool get enabled => _enabled;
  bool get autoSync => _autoSync;
  String get id => _id;
  String get deviceName => _deviceName;
  String get currentPin => _currentPin;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  Set<String> get pairedIds => Set<String>.unmodifiable(_pairedIds);
  Set<String> get categories => Set<String>.unmodifiable(_categories);
  List<DiscoveredDevice> get devices => List<DiscoveredDevice>.unmodifiable(_devices);

  /// PIN split into two groups of three digits for legibility.
  String get pinLabel {
    final pin = _currentPin;
    if (pin.length < 6) return pin;
    return '${pin.substring(0, 3)} ${pin.substring(3, 6)}';
  }

  String get statusLabel {
    if (!_running) return 'Kapalı';
    if (_pairedIds.isNotEmpty) return 'Eşleşti: ${_pairedIds.length} cihaz';
    if (_devices.isNotEmpty) return '${_devices.length} cihaz bulundu';
    return 'Cihaz aranıyor';
  }

  /// Loads persisted settings. Safe to call repeatedly.
  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    try {
      _prefs = await SharedPreferences.getInstance();
      final prefs = _prefs!;

      _id = prefs.getString(_kId) ?? _randomHex(16);
      _suffix = prefs.getString(_kSuffix) ?? _randomHex(4).toUpperCase();
      _enabled = prefs.getBool(_kEnabled) ?? false;
      _autoSync = prefs.getBool(_kAutoSync) ?? false;
      _deviceName =
          prefs.getString(_kDeviceName) ?? 'CloudTune-$_suffix';

      _pairedIds.clear();
      final rawPaired = prefs.getString(_kPairedIds);
      if (rawPaired != null) {
        final decoded = jsonDecode(rawPaired);
        if (decoded is List) {
          for (final value in decoded) {
            if (value is String && value.isNotEmpty) _pairedIds.add(value);
          }
        }
      }

      _endpoints.clear();
      final rawEndpoints = prefs.getString(_kEndpoints);
      if (rawEndpoints != null) {
        final decoded = jsonDecode(rawEndpoints);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is String && value is String && value.isNotEmpty) {
              _endpoints[key] = value;
            }
          });
        }
      }

      _categories
        ..clear()
        ..addAll(allCategories);
      final rawCategories = prefs.getString(_kCategories);
      if (rawCategories != null) {
        final decoded = jsonDecode(rawCategories);
        if (decoded is List) {
          final stored = decoded.whereType<String>().toSet();
          if (stored.isNotEmpty) {
            _categories
              ..clear()
              ..addAll(stored.where(allCategories.contains));
          }
        }
      }

      final rawLastSync = prefs.getInt(_kLastSyncedAt);
      if (rawLastSync != null) {
        _lastSyncedAt = DateTime.fromMillisecondsSinceEpoch(rawLastSync);
      }

      await _saveString(_kId, _id);
      await _saveString(_kSuffix, _suffix);
    } catch (_) {
      // Corrupt or unavailable storage: fall back to in-memory defaults.
    }
    if (_id.isEmpty) _id = _randomHex(16);
    if (_suffix.isEmpty) _suffix = _randomHex(4).toUpperCase();
    if (_deviceName.isEmpty || _deviceName == 'CloudTune') {
      _deviceName = 'CloudTune-$_suffix';
    }
    _regeneratePin();
    notifyListeners();
  }

  /// Opens the discovery and HTTP sockets. Repeated calls do nothing.
  Future<void> start() async {
    if (_running || _starting) return;
    _starting = true;
    final token = ++_startToken;
    await init();
    if (token != _startToken) {
      _starting = false;
      return;
    }
    _regeneratePin();

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
      );
    } catch (_) {}
    if (token != _startToken) {
      try {
        socket?.close();
      } catch (_) {}
      _starting = false;
      return;
    }
    if (socket != null) {
      try {
        socket.broadcastEnabled = true;
        socket.listen(
          _onDatagram,
          onError: (Object error) {},
          cancelOnError: false,
        );
      } catch (_) {
        try {
          socket.close();
        } catch (_) {}
        socket = null;
      }
    }
    _discoverySocket = socket;

    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
    } catch (_) {}
    if (token != _startToken) {
      if (identical(_discoverySocket, socket)) _discoverySocket = null;
      try {
        socket?.close();
      } catch (_) {}
      if (server != null) {
        try {
          await server.close(force: true);
        } catch (_) {}
      }
      _starting = false;
      return;
    }
    if (server != null) {
      try {
        server.listen(
          _handleRequest,
          onError: (Object error) {},
          cancelOnError: false,
        );
      } catch (_) {
        try {
          await server.close(force: true);
        } catch (_) {}
        server = null;
      }
    }
    _server = server;

    _running = true;
    _beaconTimer?.cancel();
    _beaconTimer = Timer.periodic(_beaconInterval, (_) => _sendBeacon());
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(
      Duration(seconds: _deviceExpiry.inSeconds ~/ 4),
      (_) => _expireDevices(),
    );
    _sendBeacon();
    _starting = false;
    notifyListeners();
  }

  /// Closes all sockets and timers and forgets transient discoveries.
  Future<void> stop() async {
    _startToken++;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    try {
      _discoverySocket?.close();
    } catch (_) {}
    _discoverySocket = null;
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _devices.clear();
    _running = false;
    notifyListeners();
  }

  /// Emits a beacon right away, starting the service when necessary.
  Future<void> discoverOnce() async {
    if (!_running) {
      await start();
      return;
    }
    _sendBeacon();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _saveBool(_kEnabled, value);
    notifyListeners();
    if (value) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> setAutoSync(bool value) async {
    _autoSync = value;
    await _saveBool(_kAutoSync, value);
    notifyListeners();
    if (value && _running && _pairedIds.isNotEmpty) {
      unawaited(syncNow());
    }
  }

  Future<void> setDeviceName(String value) async {
    final clean = value.trim();
    _deviceName = clean.isEmpty ? 'CloudTune-$_suffix' : clean;
    await _saveString(_kDeviceName, _deviceName);
    _sendBeacon();
    notifyListeners();
  }

  Future<void> toggleCategory(String category) async {
    if (!allCategories.contains(category)) return;
    if (!_categories.remove(category)) _categories.add(category);
    await _saveString(_kCategories, jsonEncode(_categories.toList()));
    notifyListeners();
  }

  Future<void> forget(String id) async {
    if (id.isEmpty) return;
    final removedPair = _pairedIds.remove(id);
    final removedEndpoint = _endpoints.remove(id) != null;
    if (!removedPair && !removedEndpoint) return;
    await _persistPaired();
    await _persistEndpoints();
    notifyListeners();
  }

  Future<void> forgetAll() async {
    if (_pairedIds.isEmpty && _endpoints.isEmpty) return;
    _pairedIds.clear();
    _endpoints.clear();
    await _persistPaired();
    await _persistEndpoints();
    notifyListeners();
  }

  /// Pairs with [device] by presenting [pin] to its /pair endpoint.
  Future<bool> pair(DiscoveredDevice device, String pin) async {
    if (device.port <= 0 || pin.isEmpty) return false;
    final response = await _postJson(
      'http://${device.address}:${device.port}/pair',
      <String, dynamic>{
        'pin': pin,
        'id': _id,
        'name': _deviceName,
      },
    );
    if (response == null || response['ok'] != true) return false;
    final remoteId = '${response['id'] ?? device.id}';
    if (remoteId.isEmpty) return false;
    _endpoints[remoteId] = '${device.address}:${device.port}';
    await _persistEndpoints();
    await _addPaired(remoteId);
    _regeneratePin();
    return true;
  }

  /// Pushes the exported library to every paired device with a known address.
  Future<bool> syncNow() async {
    if (_pairedIds.isEmpty) return false;
    await init();
    final payload = exportData();
    var succeeded = false;
    final targets = <MapEntry<String, String>>[];
    for (final entry in _endpoints.entries) {
      if (_pairedIds.contains(entry.key) && entry.value.isNotEmpty) {
        targets.add(entry);
      }
    }
    for (final device in _devices) {
      if (!_pairedIds.contains(device.id) || device.port <= 0) continue;
      if (_endpoints.containsKey(device.id)) continue;
      targets.add(MapEntry<String, String>(device.id, '${device.address}:${device.port}'));
    }
    for (final target in targets) {
      final response = await _postJson(
        'http://${target.value}/sync',
        payload,
      );
      if (response == null) continue;
      try {
        mergeData(response);
      } catch (_) {}
      succeeded = true;
    }
    if (succeeded) {
      _lastSyncedAt = DateTime.now();
      await _saveInt(_kLastSyncedAt, _lastSyncedAt!.millisecondsSinceEpoch);
      notifyListeners();
    }
    return succeeded;
  }

  /// Serializes the categories currently enabled for syncing.
  Map<String, dynamic> exportData() {
    final result = <String, dynamic>{
      'app': 'cloudtune',
      'deviceId': _id,
      'deviceName': _deviceName,
      'version': 1,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
    };
    final library = Library.instance;

    if (_categories.contains('playlists')) {
      try {
        final playlists = <String, dynamic>{};
        for (final name in library.playlistNames) {
          playlists[name] = library
              .getPlaylist(name)
              .map((Track track) => track.toJson())
              .toList();
        }
        result['playlists'] = playlists;
      } catch (_) {}
    }

    if (_categories.contains('history')) {
      try {
        result['history'] = library
            .history
            .map((Track track) => track.toJson())
            .toList();
      } catch (_) {}
    }

    if (_categories.contains('liked')) {
      try {
        result['liked'] =
            library.liked.map((Track track) => track.toJson()).toList();
      } catch (_) {}
    }

    if (_categories.contains('downloads')) {
      try {
        // Only Track metadata: never file paths or audio bytes.
        result['downloads'] = _knownTracks(library)
            .map(
              (Track track) => <String, dynamic>{
                'id': track.id,
                'title': track.title,
                'artist': track.artist,
              },
            )
            .toList();
      } catch (_) {}
    }

    if (_categories.contains('settings')) {
      try {
        result['settings'] = <String, dynamic>{
          'linkHandler': library.linkHandlerEnabled,
          'downloadToDevice': library.downloadToDevice,
          'radio': library.radioEnabled,
          'searchHistory': library.searchHistory,
        };
      } catch (_) {}
    }

    return result;
  }

  /// Adds previously unknown entries from [data] into [Library.instance].
  void mergeData(Map<String, dynamic> data) {
    final library = Library.instance;

    if (_categories.contains('playlists') && data['playlists'] is Map) {
      try {
        final incoming = Map<dynamic, dynamic>.from(data['playlists'] as Map);
        incoming.forEach((key, value) {
          if (key is! String || key.trim().isEmpty) return;
          final tracks = _decodeTracks(value);
          if (tracks.isEmpty) return;
          final merged = <String, Track>{
            for (final track in library.getPlaylist(key)) track.id: track,
          };
          var changed = false;
          for (final track in tracks) {
            if (merged.containsKey(track.id)) continue;
            merged[track.id] = track;
            changed = true;
          }
          if (changed) {
            unawaited(library.createPlaylist(key, merged.values.toList()));
          }
        });
      } catch (_) {}
    }

    if (_categories.contains('history')) {
      try {
        final existing = library.history.map((Track t) => t.id).toSet();
        for (final track in _decodeTracks(data['history']).reversed) {
          if (!existing.add(track.id)) continue;
          unawaited(library.remember(track));
        }
      } catch (_) {}
    }

    if (_categories.contains('liked')) {
      try {
        for (final track in _decodeTracks(data['liked'])) {
          if (library.isLiked(track.id)) continue;
          unawaited(library.toggleLike(track));
        }
      } catch (_) {}
    }

    if (_categories.contains('downloads')) {
      try {
        // Library exposes no download registry; metadata-only entries are
        // recorded as already-known tracks without any file information.
        final existing = library.history.map((Track t) => t.id).toSet();
        for (final track in _decodeTracks(data['downloads'])) {
          if (!existing.add(track.id)) continue;
          unawaited(library.remember(track));
        }
      } catch (_) {}
    }

    if (_categories.contains('settings') && data['settings'] is Map) {
      try {
        final settings = Map<dynamic, dynamic>.from(data['settings'] as Map);
        final link = settings['linkHandler'];
        if (link is bool) unawaited(library.setLinkHandlerEnabled(link));
        final download = settings['downloadToDevice'];
        if (download is bool) unawaited(library.setDownloadToDevice(download));
        final radio = settings['radio'];
        if (radio is bool) unawaited(library.setRadioEnabled(radio));
        final queries = settings['searchHistory'];
        if (queries is List) {
          for (final query in queries) {
            if (query is String && query.trim().isNotEmpty) {
              unawaited(library.addSearchHistory(query));
            }
          }
        }
      } catch (_) {}
    }
  }

  // ---- discovery ---------------------------------------------------------

  void _sendBeacon() {
    final socket = _discoverySocket;
    if (socket == null) return;
    try {
      final bytes = utf8.encode(
        jsonEncode(<String, dynamic>{
          'app': 'cloudtune',
          'id': _id,
          'name': _deviceName,
          'port': httpPort,
        }),
      );
      try {
        socket.send(bytes, _broadcastAny, discoveryPort);
      } catch (_) {}
      try {
        socket.send(bytes, _broadcastSubnet, discoveryPort);
      } catch (_) {}
    } catch (_) {}
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _discoverySocket;
    if (socket == null) return;
    Datagram? datagram;
    try {
      datagram = socket.receive();
    } catch (_) {
      return;
    }
    if (datagram == null || datagram.data.isEmpty) return;

    Map<dynamic, dynamic>? beacon;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data, allowMalformed: true));
      if (decoded is Map) beacon = Map<dynamic, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    if (beacon == null || beacon['app'] != 'cloudtune') return;

    final remoteId = '${beacon['id'] ?? ''}';
    if (remoteId.isEmpty || remoteId == _id) return;
    final port = (beacon['port'] as num?)?.toInt() ?? 0;
    if (port <= 0) return;

    final address = datagram.address.address;
    final name = '${beacon['name'] ?? 'CloudTune'}';
    final index = _devices.indexWhere((DiscoveredDevice d) => d.id == remoteId);
    if (index >= 0) {
      final old = _devices[index];
      final recent =
          DateTime.now().difference(old.lastSeen).compareTo(_beaconInterval) < 0;
      if (recent &&
          old.name == name &&
          old.address == address &&
          old.port == port) {
        return;
      }
      _devices[index] =
          DiscoveredDevice(id: remoteId, name: name, address: address, port: port);
    } else {
      _devices.add(
        DiscoveredDevice(id: remoteId, name: name, address: address, port: port),
      );
    }
    _devices.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
  }

  void _expireDevices() {
    final now = DateTime.now();
    final before = _devices.length;
    _devices.removeWhere(
      (DiscoveredDevice device) =>
          now.difference(device.lastSeen).compareTo(_deviceExpiry) > 0,
    );
    if (_devices.length != before) notifyListeners();
  }

  // ---- HTTP endpoints ----------------------------------------------------

  void _handleRequest(HttpRequest request) {
    unawaited(_respond(request));
  }

  Future<void> _respond(HttpRequest request) async {
    final remoteAddress = request.connectionInfo?.remoteAddress.address ?? '';
    try {
      switch (request.uri.path) {
        case '/hello':
          await _writeJson(request.response, 200, <String, dynamic>{
            'app': 'cloudtune',
            'id': _id,
            'name': _deviceName,
            'port': httpPort,
            'paired': _pairedIds.length,
          });
          return;
        case '/capabilities':
          await _writeJson(request.response, 200, <String, dynamic>{
            'categories': _categories.toList(),
            'version': 1,
          });
          return;
        case '/pair':
          final body = await _readBody(request);
          final pin = '${body?['pin'] ?? ''}';
          final remoteId = '${body?['id'] ?? ''}';
          if (!_isPinValid(pin) || remoteId.isEmpty || remoteId == _id) {
            await _writeJson(
              request.response,
              200,
              <String, dynamic>{'ok': false},
            );
            return;
          }
          if (remoteAddress.isNotEmpty) {
            _endpoints[remoteId] = '$remoteAddress:$httpPort';
            await _persistEndpoints();
          }
          await _addPaired(remoteId);
          _regeneratePin();
          await _writeJson(request.response, 200, <String, dynamic>{
            'ok': true,
            'id': _id,
            'name': _deviceName,
            'port': httpPort,
          });
          return;
        case '/sync':
          final body = await _readBody(request);
          if (body != null) {
            try {
              mergeData(body);
            } catch (_) {}
            final remoteId = '${body['deviceId'] ?? ''}';
            if (remoteId.isNotEmpty &&
                remoteId != _id &&
                remoteAddress.isNotEmpty) {
              _endpoints[remoteId] = '$remoteAddress:$httpPort';
              await _persistEndpoints();
            }
          }
          await _writeJson(request.response, 200, exportData());
          return;
        default:
          await _writeJson(
            request.response,
            404,
            <String, dynamic>{'ok': false},
          );
          return;
      }
    } catch (_) {
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>?> _readBody(HttpRequest request) async {
    try {
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  Future<void> _writeJson(
    HttpResponse response,
    int status,
    Map<String, dynamic> body,
  ) async {
    try {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
      await response.close();
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _postJson(
    String url,
    Map<String, dynamic> payload,
  ) async {
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      final request = await client
          .postUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 4));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(const Duration(seconds: 4));
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 4))) {
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {} finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
    return null;
  }

  // ---- helpers -----------------------------------------------------------

  bool _isPinValid(String pin) {
    if (pin.isEmpty || pin != _currentPin) return false;
    final age = DateTime.now().difference(_pinIssuedAt).inMinutes;
    return age >= 0 && age < _pinLifetime.inMinutes;
  }

  void _regeneratePin() {
    try {
      _currentPin = (100000 + Random.secure().nextInt(900000)).toString();
      _pinIssuedAt = DateTime.now();
    } catch (_) {
      _currentPin = '000000';
      _pinIssuedAt = DateTime.now();
    }
  }

  Future<void> _addPaired(String remoteId) async {
    if (remoteId.isEmpty) return;
    _pairedIds.add(remoteId);
    await _persistPaired();
    notifyListeners();
  }

  Future<void> _persistPaired() =>
      _saveString(_kPairedIds, jsonEncode(_pairedIds.toList()));

  Future<void> _persistEndpoints() =>
      _saveString(_kEndpoints, jsonEncode(_endpoints));

  Future<void> _saveString(String key, String value) async {
    try {
      await _prefs?.setString(key, value);
    } catch (_) {}
  }

  Future<void> _saveBool(String key, bool value) async {
    try {
      await _prefs?.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _saveInt(String key, int value) async {
    try {
      await _prefs?.setInt(key, value);
    } catch (_) {}
  }

  String _randomHex(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(16))
        .map((int value) => value.toRadixString(16))
        .join();
  }

  List<Track> _decodeTracks(Object? value) {
    if (value is! List) return const <Track>[];
    final result = <Track>[];
    for (final item in value) {
      try {
        if (item is! Map) continue;
        final track = Track.fromJson(Map<String, dynamic>.from(item));
        if (track.id.isNotEmpty) result.add(track);
      } catch (_) {}
    }
    return result;
  }

  List<Track> _knownTracks(Library library) {
    final seen = <String>{};
    final result = <Track>[];
    void addAll(Iterable<Track> tracks) {
      for (final track in tracks) {
        if (track.id.isEmpty || !seen.add(track.id)) continue;
        result.add(track);
      }
    }

    addAll(library.history);
    addAll(library.liked);
    for (final name in library.playlistNames) {
      addAll(library.getPlaylist(name));
    }
    return result;
  }
}
