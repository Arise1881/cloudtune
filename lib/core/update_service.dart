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

/// Birincil manifest adresi (eski sürümlerin de kullandığı sabit URL).
const String kUpdateManifestUrl =
    'https://raw.githubusercontent.com/Arise1881/cloudtune-dist/main/update.json';

/// Yedek adresler: raw CDN arızalanırsa veya 5 dk'lık cache bayatsa devreye girer.
const List<String> kUpdateManifestFallbacks = <String>[
  'https://arise1881.github.io/cloudtune-dist/update.json',
  'https://cloudtune.app/update.json',
];

const String kSourceUrl =
    'altstore://source?url=https://raw.githubusercontent.com/Arise1881/cloudtune-dist/main/apps.json';

const String kReleasePageUrl =
    'https://github.com/Arise1881/cloudtune-dist/releases/tag/cloudtune-latest';

/// Açık uygulamanın kendiliğinden yeni sürümü fark etmesi için kontrol aralığı.
const Duration kUpdateCheckInterval = Duration(hours: 6);

enum UpdatePlatform { android, linux, windows, ios, unknown }

/// Platform/ABI için doğru güncelleme dosyasını seçer.
///
/// Eski sürümlerde her platform Android APK'sını indiriyordu; Linux/Windows
/// kullanıcısı kurulum yerine APK dosyasını açmaya çalışıyordu. Saf fonksiyon
/// olduğu için test edilebilir; indirme yolu tek kaynaktan belirlenir.
String? updateAssetUrl({
  required UpdateInfo info,
  required UpdatePlatform platform,
  required ffi.Abi abi,
}) {
  switch (platform) {
    case UpdatePlatform.android:
      final specific = switch (abi) {
        ffi.Abi.androidArm64 => info.androidArm64Url,
        ffi.Abi.androidArm => info.androidArmv7Url,
        ffi.Abi.androidX64 => info.androidX64Url,
        ffi.Abi.androidIA32 => info.androidUniversalUrl,
        _ => null,
      };
      return specific ?? info.androidUniversalUrl ?? info.androidArm64Url;
    case UpdatePlatform.linux:
      return info.linuxDebUrl;
    case UpdatePlatform.windows:
      return info.windowsZipUrl;
    case UpdatePlatform.ios:
    case UpdatePlatform.unknown:
      return null;
  }
}

/// Seçilen dosyanın yerel adı. Aynı ad, hazırlanmış dosyanın doğrulanması
/// için de kullanılır; eski sürümden kalan yanlış uzantılı dosya asla kurulmaz.
String updateAssetFileName({
  required UpdateInfo info,
  required UpdatePlatform platform,
  required ffi.Abi abi,
}) {
  final version = info.version;
  return switch (platform) {
    UpdatePlatform.android => 'cloudtune_update_$version.apk',
    UpdatePlatform.linux =>
      'cloudtune_${version}_${info.versionCode}_amd64.deb',
    UpdatePlatform.windows => 'CloudTune-$version-windows.zip',
    UpdatePlatform.ios ||
    UpdatePlatform.unknown =>
      'cloudtune_update_$version.bin',
  };
}

class UpdateInfo {
  final String version;
  final int versionCode;
  final String notes;
  final String? androidArm64Url;
  final String? androidArmv7Url;
  final String? androidX64Url;
  final String? androidUniversalUrl;
  final String? linuxDebUrl;
  final String? windowsZipUrl;
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
    this.windowsZipUrl,
    this.iosSourceUrl,
  });
}

/// Fetches the published manifest, compares versions and installs an APK.
class UpdateService extends ChangeNotifier with WidgetsBindingObserver {
  UpdateService._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final UpdateService instance = UpdateService._();

  bool _disposed = false;
  Timer? _periodicCheck;
  DateTime? _lastCheck;
  bool _checking = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  bool _updateAvailable = false;
  String? _latestVersion;
  String? _error;
  UpdateInfo? _latest;
  String _installedVersion = '0.0.0';
  int _installedBuild = 0;
  Future<String?>? _downloadFuture;
  String? _downloadKey;
  String? _preparedApkPath;
  String? _preparedVersion;
  String? _preparedAssetName;

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
        'windows' => UpdatePlatform.windows,
        'ios' => UpdatePlatform.ios,
        _ => UpdatePlatform.unknown,
      };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || state != AppLifecycleState.resumed) return;
    final last = _lastCheck;
    // Uygulama uzun süre kapalı kaldıysa açılır açılmaz yeniden bak; aksi
    // halde son kontrolün üzerinden 6 saatten fazla geçtiyse kontrol et.
    if (last == null || DateTime.now().difference(last) >= kUpdateCheckInterval) {
      unawaited(checkForUpdate());
    }
  }

  Future<void> init() async {
    if (_disposed) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _installedVersion = info.version;
      _installedBuild = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {}
    _periodicCheck?.cancel();
    _periodicCheck = Timer.periodic(kUpdateCheckInterval, (_) {
      if (_disposed) return;
      unawaited(checkForUpdate());
    });
    unawaited(checkForUpdate());
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _periodicCheck?.cancel();
    _periodicCheck = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Yeni sürüm karşılaştırması hem semver hem build numarasını dikkate alır.
  /// Eski istemciler yalnızca `version` alanını okur; o alanı daima artırıyoruz.
  bool _isNewer(UpdateInfo info) {
    final byVersion = _cmpVersion(info.version, _installedVersion);
    if (byVersion != 0) return byVersion > 0;
    if (info.versionCode > 0 && _installedBuild > 0) {
      return info.versionCode > _installedBuild;
    }
    return false;
  }

  Future<void> checkForUpdate({bool force = false}) async {
    // Daha önce "güncelleme var" bayrağı açıkken koruma atlanıyordu; periyodik
    // ve elle kontrol aynı anda manifest işleyip hazırlanmış dosyayı silebiliyordu.
    if (_checking) return;
    _checking = true;
    _error = null;
    _lastCheck = DateTime.now();
    try {
      final manifest = await _fetchManifest();
      _latest = manifest;
      _latestVersion = manifest.version;
      _updateAvailable = _isNewer(manifest);
      // Yeni sürüm geldiyse önceki sürümden kalan dosyayı geçersiz kıl.
      if (_preparedApkPath != null && _preparedVersion != manifest.version) {
        await _invalidatePrepared();
      }
      _error = null;
    } catch (e) {
      // Background failures are stored only; no error text is shown.
      _error = e.toString();
      // Son başarılı manifest varsa bayrağı kapatmayalım; geçici CDN hatası
      // kullanıcıda "güncelleme yok" yanılgısı yaratmasın.
      final cached = _latest;
      if (cached != null) _updateAvailable = _isNewer(cached);
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<void> _invalidatePrepared() async {
    final old = _preparedApkPath;
    _preparedApkPath = null;
    _preparedVersion = null;
    _preparedAssetName = null;
    // İndirme sürüyorsa dosya üzerinde yazma tamamlanmadan silmeyiz; indirme
    // bitince zaten yeni sürüm kontrolü yapılır.
    if (old == null || _downloadFuture != null) return;
    try {
      final file = File(old);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<UpdateInfo> _fetchManifest() async {
    final urls = <String>[kUpdateManifestUrl, ...kUpdateManifestFallbacks];
    final stamp = DateTime.now().millisecondsSinceEpoch;
    Object? lastError;
    for (final base in urls) {
      try {
        // Cache-buster: raw GitHub 5 dk, Pages 10 dk önbelleğe alıyor.
        final uri = Uri.parse(base).replace(
          queryParameters: <String, String>{'t': '$stamp'},
        );
        final response = await http.get(uri).timeout(const Duration(seconds: 12));
        if (response.statusCode != 200) {
          throw StateError('update check failed (${response.statusCode})');
        }
        return _parseManifest(response.body);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('update check failed');
  }

  static UpdateInfo _parseManifest(String body) {
    final data = jsonDecode(body);
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
      windowsZipUrl: platforms['windows'] as String?,
      iosSourceUrl: platforms['ios'] as String?,
    );
  }

  String? get _assetUrl {
    final info = _latest;
    if (info == null) return null;
    return updateAssetUrl(
      info: info,
      platform: platform,
      abi: ffi.Abi.current(),
    );
  }

  String? get _assetFileName {
    final info = _latest;
    if (info == null) return null;
    return updateAssetFileName(
      info: info,
      platform: platform,
      abi: ffi.Abi.current(),
    );
  }

  /// Platforma uygun dosyayı önceden indirir; iOS doğrudan kurulum
  /// desteklemediği için yalnızca kaynak bağlantısı açılır.
  Future<String?> prepareDownload() async {
    final existing = _preparedApkPath;
    if (existing != null) return existing;
    final info = _latest;
    final url = _assetUrl;
    final name = _assetFileName;
    if (info == null || url == null || name == null) return null;
    final path = await _download(url, name);
    if (path == null) return null;
    // İndirme sürerken yeni manifest gelebilir; eski sürüm dosyasını hazır
    // olarak işaretlemeyiz.
    if (!identical(_latest, info)) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
      return null;
    }
    _preparedApkPath = path;
    _preparedVersion = info.version;
    _preparedAssetName = name;
    notifyListeners();
    return path;
  }

  Future<String> applyUpdate() async {
    final info = _latest;
    if (info == null) return 'Güncelleme bilgisi yok.';

    if (platform == UpdatePlatform.ios) {
      // iOS'ta doğrudan paket kurulamaz; AltStore kaynağını açıyoruz.
      final url = info.iosSourceUrl ?? kSourceUrl;
      final result = await OpenFilex.open(url);
      return result.type == ResultType.done
          ? 'AltStore kaynağı açıldı.'
          : 'Kaynak açılamadı: $url';
    }

    if (platform == UpdatePlatform.windows) {
      final ok = await _openExternalUrl(kReleasePageUrl);
      return ok
          ? 'GitHub sürüm sayfası açıldı. En güncel Windows kurulum dosyasını indirip kurabilirsiniz.'
          : 'Sürüm sayfası açılamadı: $kReleasePageUrl';
    }

    final url = _assetUrl;
    final name = _assetFileName;
    if (url == null || name == null) {
      return 'Bu platform için güncelleme bağlantısı yok.';
    }

    var path = _preparedApkPath;
    if (path == null ||
        _preparedVersion != info.version ||
        _preparedAssetName != name) {
      await _invalidatePrepared();
      path = await _download(url, name);
      if (path == null) return 'İndirme başarısız.';
      if (!identical(_latest, info)) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
        return 'Güncelleme değişti. Lütfen tekrar deneyin.';
      }
      _preparedApkPath = path;
      _preparedVersion = info.version;
      _preparedAssetName = name;
    }

    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      return 'Kurulum başlatılamadı. Dosya: $path';
    }
    return switch (platform) {
      UpdatePlatform.windows =>
        'Windows paketi indirildi. ZIP içindeki cloudtune.exe ile temiz kurulum yapın.',
      UpdatePlatform.linux => 'Paket indirildi. Kurulumu onaylayın.',
      _ => 'İndirildi. Kurulum izninizi verin.',
    };
  }

  /// Aynı dosya için eşzamanlı indirmeleri birleştirir; farklı dosyalar
  /// sırayla indirilir. Yarım kalan dosya hata durumunda silinir.
  Future<String?> _download(String url, String fileName) {
    final key = '$url|$fileName';
    final active = _downloadFuture;
    if (active != null) {
      if (_downloadKey == key) return active;
      return _downloadAfter(active, url, fileName);
    }
    return _startDownload(url, fileName, key);
  }

  Future<String?> _downloadAfter(
    Future<String?> active,
    String url,
    String fileName,
  ) async {
    try {
      await active;
    } catch (_) {}
    final next = _downloadFuture;
    if (next != null) return _downloadAfter(next, url, fileName);
    return _download(url, fileName);
  }

  Future<String?> _startDownload(String url, String fileName, String key) {
    late final Future<String?> future;
    future = _performDownload(url, fileName).whenComplete(() {
      if (identical(_downloadFuture, future)) {
        _downloadFuture = null;
        _downloadKey = null;
      }
    });
    _downloadFuture = future;
    _downloadKey = key;
    return future;
  }

  Future<String?> _performDownload(String url, String fileName) async {
    _downloading = true;
    _downloadProgress = 0;
    notifyListeners();

    final client = http.Client();
    IOSink? sink;
    File? target;
    try {
      final dir = await getApplicationDocumentsDirectory();
      target = File('${dir.path}/$fileName');
      if (await target.exists()) await target.delete();

      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        throw StateError('download failed (${response.statusCode})');
      }

      final total = response.contentLength ?? 0;
      sink = target.openWrite();
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) _downloadProgress = received / total;
        notifyListeners();
      }
      await sink.close();
      sink = null;
      _downloadProgress = 1;
      return target.path;
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
        sink = null;
      }
      if (target != null) {
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {}
      }
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

  Future<bool> _openExternalUrl(String url) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('cmd', ['/c', 'start', '', url]);
        return result.exitCode == 0;
      }
      if (Platform.isLinux) {
        final result = await Process.run('xdg-open', [url]);
        return result.exitCode == 0;
      }
      if (Platform.isMacOS) {
        final result = await Process.run('open', [url]);
        return result.exitCode == 0;
      }
      final result = await OpenFilex.open(url);
      return result.type == ResultType.done;
    } catch (_) {
      return false;
    }
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
