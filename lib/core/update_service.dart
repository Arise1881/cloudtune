import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

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
  final String? androidArmv7Url;
  final String? androidX64Url;
  final String? androidUniversalUrl;
  final String? linuxDebUrl;
  final String? iosSourceUrl;

  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.notes,
    this.androidArm64Url,
    this.androidArmv7Url,
    this.androidX64Url,
    this.androidUniversalUrl,
    this.linuxDebUrl,
    this.iosSourceUrl,
  });
}

/// Fetches the published manifest, compares versions and installs an APK.
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

  bool get checking => _checking;
  bool get downloading => _downloading;
  double get downloadProgress => _downloadProgress;
  bool get updateAvailable => _updateAvailable;
  String? get latestVersion => _latestVersion;
  String? get error => _error;
  String get installedVersion => _installedVersion;
  bool get prepared => _preparedApkPath != null;

  UpdatePlatform get platform => switch (Platform.operatingSystem) {
        'android' => UpdatePlatform.android,
        'linux' => UpdatePlatform.linux,
        'ios' => UpdatePlatform.ios,
        _ => UpdatePlatform.unknown,
      };

  Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _installedVersion = info.version;
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
      _updateAvailable = _cmpVersion(manifest.version, _installedVersion) > 0;
    } catch (e) {
      // Background failures are stored only; no error text is shown.
      _error = e.toString();
      _updateAvailable = false;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<UpdateInfo> _fetchManifest() async {
    final response = await http
        .get(Uri.parse(kUpdateManifestUrl))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('update check failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('invalid update manifest');
    }
    final platforms = data['platforms'] as Map<String, dynamic>? ?? {};
    return UpdateInfo(
      version: (data['version'] ?? '0.0.0').toString(),
      versionCode: (data['versionCode'] as num?)?.toInt() ?? 0,
      notes: (data['notes'] as String?) ?? '',
      androidArm64Url: platforms['android-arm64'] as String?,
      androidArmv7Url: platforms['android-armv7'] as String?,
      androidX64Url: platforms['android-x86_64'] as String?,
      androidUniversalUrl: platforms['android-universal'] as String?,
      linuxDebUrl: platforms['linux'] as String?,
      iosSourceUrl: platforms['ios'] as String?,
    );
  }

  /// Cihazın ABI'sine uygun APK'yı seçer. Evrensel paket her cihazda
  /// çalıştığı için son çare olarak kullanılır; eski/x86 cihazlara yanlış
  /// arm64 paketinin inmesini engeller.
  String? get _androidApkUrl {
    final info = _latest;
    if (info == null) return null;
    final specific = switch (ffi.Abi.current()) {
      ffi.Abi.androidArm64 => info.androidArm64Url,
      ffi.Abi.androidArm => info.androidArmv7Url,
      ffi.Abi.androidX64 => info.androidX64Url,
      ffi.Abi.androidIA32 => info.androidUniversalUrl,
      _ => null,
    };
    return specific ?? info.androidUniversalUrl ?? info.androidArm64Url;
  }

  /// Downloads the APK ahead of time so the dialog can install it instantly.
  Future<String?> prepareDownload() async {
    final existing = _preparedApkPath;
    if (existing != null) return existing;
    final info = _latest;
    if (info == null) return null;
    final url = _androidApkUrl;
    if (url == null) return null;
    final path = await _download(url, 'cloudtune_update_${info.version}.apk');
    if (path == null) return null;
    _preparedApkPath = path;
    notifyListeners();
    return path;
  }

  Future<String> applyUpdate() async {
    final info = _latest;
    if (info == null) return 'Güncelleme bilgisi yok.';

    var path = _preparedApkPath;
    if (path == null) {
      final url = _androidApkUrl;
      if (url == null) return 'Android için güncelleme bağlantısı yok.';
      path = await _download(url, 'cloudtune_update.apk');
      if (path == null) return 'İndirme başarısız.';
      _preparedApkPath = path;
    }

    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      return 'Kurulum başlatılamadı. Dosya: $path';
    }
    return 'İndirildi. Kurulum izninizi verin.';
  }

  Future<String?> _download(String url, String fileName) async {
    _downloading = true;
    _downloadProgress = 0;
    notifyListeners();

    final client = http.Client();
    IOSink? sink;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) await file.delete();

      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        throw StateError('download failed (${response.statusCode})');
      }

      final total = response.contentLength ?? 0;
      sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) _downloadProgress = received / total;
        notifyListeners();
      }
      await sink.close();
      sink = null;
      _downloadProgress = 1;
      return file.path;
    } catch (_) {
      return null;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      client.close();
      _downloading = false;
      notifyListeners();
    }
  }

  /// Compares semver cores first, then the `+build` suffix as a tiebreaker.
  static List<int> _core(String version) => version
      .split('+')
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();

  static int _build(String version) {
    final parts = version.split('+');
    return parts.length > 1 ? (int.tryParse(parts.last) ?? 0) : 0;
  }

  int _cmpVersion(String a, String b) {
    final left = _core(a);
    final right = _core(b);
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final x = i < left.length ? left[i] : 0;
      final y = i < right.length ? right[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    final buildA = _build(a);
    final buildB = _build(b);
    if (buildA != buildB) return buildA > buildB ? 1 : -1;
    return 0;
  }
}

/// Green home-screen banner that opens the update dialog.
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.system_update_alt,
                        color: Colors.black, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'CloudTune ${update.latestVersion} yayınlandı',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right,
                        color: Colors.black, size: 22),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showUpdateDialog(
    BuildContext context,
    UpdateService update,
  ) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: Text(
          'Güncelleme mevcut',
          style: TextStyle(color: AppPalette.text, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'CloudTune ${update.latestVersion} sürümü yayınlandı.\n\n'
          'Güncellemek istiyor musun?',
          style: TextStyle(color: AppPalette.textMuted, height: 1.4),
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
    );
    if (choice != 'update' || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(await update.applyUpdate())),
    );
  }
}
