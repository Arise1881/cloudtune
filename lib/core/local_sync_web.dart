import 'package:flutter/foundation.dart';

/// Web mirror of [DiscoveredDevice] used when `dart:io` is unavailable.
/// Instances carry the same data but never represent a real socket peer.
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

/// No-op web implementation of the LAN sync service.
///
/// Flutter web cannot open raw datagram sockets or bind a local HTTP server,
/// so every operation reports an inactive or failed result without side effects.
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

  bool _enabled = false;
  bool _autoSync = false;
  String _deviceName = 'CloudTune';
  final Set<String> _pairedIds = <String>{};
  final Set<String> _categories = allCategories.toSet();

  bool get running => false;
  bool get enabled => _enabled;
  bool get autoSync => _autoSync;
  String get id => '';
  String get deviceName => _deviceName;
  String get currentPin => '';
  String get pinLabel => '';
  DateTime? get lastSyncedAt => null;
  Set<String> get pairedIds => Set<String>.unmodifiable(_pairedIds);
  Set<String> get categories => Set<String>.unmodifiable(_categories);
  List<DiscoveredDevice> get devices => const <DiscoveredDevice>[];
  String get statusLabel => 'Kapalı';

  Future<void> init() async {}
  Future<void> start() async {}
  Future<void> stop() async {}
  Future<void> discoverOnce() async {}

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
  }

  Future<void> setAutoSync(bool value) async {
    _autoSync = value;
    notifyListeners();
  }

  Future<void> setDeviceName(String value) async {
    final clean = value.trim();
    _deviceName = clean.isEmpty ? 'CloudTune' : clean;
    notifyListeners();
  }

  Future<void> toggleCategory(String category) async {
    if (!allCategories.contains(category)) return;
    if (!_categories.remove(category)) _categories.add(category);
    notifyListeners();
  }

  Future<void> forget(String id) async {
    if (_pairedIds.remove(id)) notifyListeners();
  }

  Future<void> forgetAll() async {
    if (_pairedIds.isEmpty) return;
    _pairedIds.clear();
    notifyListeners();
  }

  Future<bool> pair(DiscoveredDevice device, String pin) async => false;

  Future<bool> syncNow() async => false;

  Map<String, dynamic> exportData() => <String, dynamic>{
        'app': 'cloudtune',
        'deviceId': '',
        'deviceName': _deviceName,
        'version': 1,
      };

  void mergeData(Map<String, dynamic> data) {}
}
