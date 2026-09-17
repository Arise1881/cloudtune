import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Bu uygulamanın (Melody) kendi dağıtım manifest'i.
/// Musify ile hiçbir bağlantısı yoktur; yalnızca kendi repo'sundan beslenir.
// Manifest GitHub Pages üzerinden sunulur (raw.githubusercontent CDN'i birkaç
// dakika eski içerik dönebildiği için Pages daha güvenilirdir).
const String kUpdateManifestUrl =
    'https://arise1881.github.io/melody-dist/update.json';
const String kSourceUrl =
    'altstore://source?url=https://raw.githubusercontent.com/Arise1881/melody-dist/main/apps.json';

enum UpdatePlatform { android, linux, ios, unknown }

class UpdateInfo {
  final String version;
  final int versionCode;
  final String notes;
  final String? androidArm64Url;
  final String? androidUniversalUrl;
  final String? linuxDebUrl;
  final String? iosSourceUrl;
  bool get hasUpdate => true;

  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.notes,
    this.androidArm64Url,
    this.androidUniversalUrl,
    this.linuxDebUrl,
    this.iosSourceUrl,
  });
}

/// En son sürümü GitHub'dan alır, indirir ve platforma göre kurulumu başlatır.
class UpdateService extends ChangeNotifier {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  bool _checking = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  bool _updateAvailable = false;
  String? _latestVersion;
  String? _error;
  UpdateInfo? _latest;
  String _installedVersion = '0.0.0';

  /// Arka planda sessizce indirilen APK yolu (Android'de otomatik güncelleme).
  String? _preparedApkPath;
  bool get prepared => _preparedApkPath != null;

  Timer? _bgTimer;

  bool get checking => _checking;
  bool get downloading => _downloading;
  bool get updateAvailable => _updateAvailable;
  double get downloadProgress => _downloadProgress;
  String? get latestVersion => _latestVersion;
  String? get error => _error;
  String get installedVersion => _installedVersion;

  bool _initialized = false;

  /// Uygulama açılışında bir kez; arka planda sessizce kontrol eder ve
  /// sonraki güncellemeler için periyodik zamanlayıcı başlatır.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final p = await PackageInfo.fromPlatform();
      _installedVersion = p.version;
    } catch (_) {}
    // Açılışı bloklamaz.
    unawaited(_initCheck());
    // Arka plan OTA: 2 saatte bir sessiz kontrol + otomatik indirme.
    _bgTimer ??= Timer.periodic(const Duration(hours: 2), (_) {
      unawaited(_backgroundCycle());
    });
    notifyListeners();
  }

  Future<void> _initCheck() async {
    await checkForUpdate();
    if (_updateAvailable && _platform == UpdatePlatform.android) {
      await prepareDownload();
    }
  }

  /// Arka plan döngüsü: güncelleme varsa apk'yı sessizce indirir.
  Future<void> _backgroundCycle() async {
    await checkForUpdate();
    if (_updateAvailable && _platform == UpdatePlatform.android) {
      await prepareDownload();
    }
  }

  /// Android APK'yı arka planda sessizce indirir (kurulum onayını kullanıcı verir).
  Future<String?> prepareDownload() async {
    if (_platform != UpdatePlatform.android) return null;
    if (_preparedApkPath != null) return _preparedApkPath;
    final info = _latest;
    if (info == null) return null;
    final url = info.androidArm64Url ?? info.androidUniversalUrl;
    if (url == null) return null;
    try {
      final path = await _download(url, 'melody_update_${info.version}.apk');
      _preparedApkPath = path;
      notifyListeners();
      return path;
    } catch (_) {
      return null;
    }
  }

  UpdatePlatform get _platform {
    if (kIsWeb) return UpdatePlatform.unknown;
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isLinux) return UpdatePlatform.linux;
    if (Platform.isIOS || Platform.isMacOS) return UpdatePlatform.ios;
    return UpdatePlatform.unknown;
  }

  /// Manifest'i indirip sürüm karşılaştırması yapar.
  Future<void> checkForUpdate({bool force = false}) async {
    if (force || !_updateAvailable) {
      _checking = true;
      _error = null;
      notifyListeners();
    }

    try {
      final manifest = await _fetchManifest();
      _latest = manifest;
      _latestVersion = manifest.version;

      // Karşılaştırma semver (versionName) üzerinden yapılır.
      // NOT: versionCode, split (ABI) APK'larda farklı (örn. arm64 -> 2021,
      // universal -> 21) olduğundan güvenilir değildir.
      final newer = _cmpVersion(manifest.version, _installedVersion) > 0;
      _updateAvailable = newer && _platform != UpdatePlatform.unknown;
    } catch (e) {
      _error = e.toString();
      _updateAvailable = false;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<UpdateInfo> _fetchManifest() async {
    final resp = await http
        .get(Uri.parse(kUpdateManifestUrl))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('Güncelleme kontrolü başarısız (${resp.statusCode})');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final ver = (json['version'] ?? '0.0.0') as String;
    final code = (json['versionCode'] as num?)?.toInt() ?? 0;
    final notes = (json['notes'] as String?) ?? '';
    final plat = json['platforms'] as Map<String, dynamic>? ?? {};
    return UpdateInfo(
      version: ver,
      versionCode: code,
      notes: notes,
      androidArm64Url: plat['android-arm64'] as String?,
      androidUniversalUrl: plat['android-universal'] as String?,
      linuxDebUrl: plat['linux'] as String?,
      iosSourceUrl: plat['ios'] as String?,
    );
  }

  /// Kullanıcı "Güncelle" dediğinde platforma uygun indirme/kurulum yapar.
  Future<String> applyUpdate() async {
    final info = _latest;
    if (info == null) return 'Güncelleme bilgisi yok.';

    switch (_platform) {
      case UpdatePlatform.android:
        // Arka planda indirilmiş APK varsa doğrudan kurulumu başlat.
        if (_preparedApkPath != null) {
          final res = await OpenFilex.open(_preparedApkPath!);
          if (res.type != ResultType.done) {
            return 'Kurulum başlatılamadı. Dosya: $_preparedApkPath';
          }
          return 'İndirildi. Kurulum izninizi verin.';
        }
        final url = info.androidArm64Url ?? info.androidUniversalUrl;
        if (url == null) return 'Android için güncelleme bağlantısı yok.';
        final path = await _download(url, 'melody_update.apk');
        final res = await OpenFilex.open(path);
        if (res.type != ResultType.done) {
          return 'Kurulum başlatılamadı. Dosya: $path';
        }
        return 'İndirildi. Kurulum izninizi verin.';
      case UpdatePlatform.linux:
        final url = info.linuxDebUrl;
        if (url == null) return 'Linux için güncelleme bağlantısı yok.';
        final path = await _download(url, 'melody_update.deb');
        return 'İndirildi: $path — kurmak için:\nsudo apt install ./$path';
      case UpdatePlatform.ios:
        return 'iOS güncellemesi SideStore/AltStore üzerinden yapılır:\n$kSourceUrl';
      case UpdatePlatform.unknown:
        return 'Bu platform otomatik güncellemeyi desteklemiyor.';
    }
  }

  Future<String> _download(String url, String fileName) async {
    _downloading = true;
    _downloadProgress = 0;
    notifyListeners();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      if (file.existsSync()) file.deleteSync();

      final req = await http.Client().send(http.Request('GET', Uri.parse(url)));
      if (req.statusCode != 200) {
        throw Exception('İndirme başarısız (${req.statusCode})');
      }
      final total = req.contentLength ?? 0;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in req.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _downloadProgress = received / total;
          // Her parçada notify; UI güncellemeyi gösterecek.
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      _downloadProgress = 1;
      return file.path;
    } finally {
      _downloading = false;
      notifyListeners();
    }
  }

  /// Basit semver karşılaştırması: a>b -> 1, a==b -> 0, a<b -> -1
  int _cmpVersion(String a, String b) {
    final pa = a.split('.').map(int.tryParse).map((e) => e ?? 0).toList();
    final pb = b.split('.').map(int.tryParse).map((e) => e ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }
}
