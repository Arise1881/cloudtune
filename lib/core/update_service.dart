import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// CloudTune OTA manifest'i (GitHub raw).
const String kUpdateManifestUrl =
    'https://raw.githubusercontent.com/Arise1881/cloudtune-dist/main/update.json';
const String kSourceUrl =
    'altstore://source?url=https://raw.githubusercontent.com/Arise1881/cloudtune-dist/main/apps.json';

enum UpdatePlatform { android, linux, ios, unknown }

class UpdateInfo {
  final String version;
  final int versionCode;
  final String notes;
  final String? androidArm64Url;
  final String? androidUniversalUrl;
  final String? linuxDebUrl;
  final String? iosSourceUrl;

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

/// En son sürümü GitHub'dan al, indir, kur (Android).
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

  String? _preparedApkPath;
  bool get prepared => _preparedApkPath != null;

  bool get checking => _checking;
  bool get downloading => _downloading;
  bool get updateAvailable => _updateAvailable;
  double get downloadProgress => _downloadProgress;
  String? get latestVersion => _latestVersion;
  String? get error => _error;
  String get installedVersion => _installedVersion;

  Future<void> init() async {
    try {
      final p = await PackageInfo.fromPlatform();
      _installedVersion = p.version;
    } catch (_) {}
    unawaited(checkForUpdate());
  }

  Future<void> checkForUpdate({bool force = false}) async {
    if (force || !_updateAvailable) {
      _checking = true;
      _error = null;
    }
    try {
      final manifest = await _fetchManifest();
      _latest = manifest;
      _latestVersion = manifest.version;
      final newer = _cmpVersion(manifest.version, _installedVersion) > 0;
      _updateAvailable = newer;
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
    final ver = (json['version'] ?? '0.0.0').toString();
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

  Future<String?> prepareDownload() async {
    if (_preparedApkPath != null) return _preparedApkPath;
    final info = _latest;
    if (info == null) return null;
    final url = info.androidArm64Url ?? info.androidUniversalUrl;
    if (url == null) return null;
    try {
      final path = await _download(url, 'cloudtune_update_${info.version}.apk');
      _preparedApkPath = path;
      notifyListeners();
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<String> applyUpdate() async {
    final info = _latest;
    if (info == null) return 'Güncelleme bilgisi yok.';
    if (_preparedApkPath != null) {
      final res = await OpenFilex.open(_preparedApkPath!);
      if (res.type != ResultType.done) {
        return 'Kurulum başlatılamadı. Dosya: $_preparedApkPath';
      }
      return 'İndirildi. Kurulum izninizi verin.';
    }
    final url = info.androidArm64Url ?? info.androidUniversalUrl;
    if (url == null) return 'Android için güncelleme bağlantısı yok.';
    final path = await _download(url, 'cloudtune_update.apk');
    if (path == null) return 'İndirme başarısız.';
    final res = await OpenFilex.open(path);
    if (res.type != ResultType.done) {
      return 'Kurulum başlatılamadı. Dosya: $path';
    }
    return 'İndirildi. Kurulum izninizi verin.';
  }

  Future<String?> _download(String url, String fileName) async {
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
        if (total > 0) _downloadProgress = received / total;
        notifyListeners();
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

  /// Semver karşılaştırması: build numarası tiebreaker ile.
  int _cmpVersion(String a, String b) {
    final baseA = a.split('+').first.split('.').map(int.tryParse).map((e) => e ?? 0).toList();
    final baseB = b.split('+').first.split('.').map(int.tryParse).map((e) => e ?? 0).toList();
    final buildA = int.tryParse(a.split('+').length > 1 ? a.split('+')[1] : '') ?? 0;
    final buildB = int.tryParse(b.split('+').length > 1 ? b.split('+')[1] : '') ?? 0;
    final len = baseA.length > baseB.length ? baseA.length : baseB.length;
    for (var i = 0; i < len; i++) {
      final x = i < baseA.length ? baseA[i] : 0;
      final y = i < baseB.length ? baseB[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    if (buildA != buildB) return buildA > buildB ? 1 : -1;
    return 0;
  }
}

/// Ana sayfa güncelleme banner'ı (v3.0 mimarisi).
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UpdateService.instance,
      builder: (context, _) {
        final update = UpdateService.instance;
        if (!update.updateAvailable) return const SizedBox.shrink();
        return Material(
          color: const Color(0xFF1DB954),
          child: InkWell(
            onTap: () => _showUpdateDialog(context, update),
            child: SafeArea(
              bottom: false,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.system_update_alt, color: Colors.black, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CloudTune ${update.latestVersion} yayınlandı',
                            style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          if (update.error != null)
                            Text(
                              update.error!,
                              style: const TextStyle(color: Colors.black, fontSize: 11),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.black, size: 22),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showUpdateDialog(BuildContext context, UpdateService update) async {
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF181818),
        title: const Text('Güncelleme mevcut',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: Text(
          'CloudTune ${update.latestVersion} sürümü yayınlandı.\n\nGüncellemek istiyor musun?',
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'dismiss'),
            child: const Text('Daha sonra'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'update'),
            child: const Text('Güncelle'),
          ),
        ],
      ),
    ) ?? 'dismiss';
    if (msg != 'update') return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(await update.applyUpdate())));
  }
}
