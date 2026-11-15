import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Cloudflare yedek kanali. Uygulama once dogrudan YouTube'a baglanir;
/// yalnizca dogrudan akis basarisiz olursa buraya duser. Hicbir durumda
/// kullaniciya baglanti/hata bilgisi gosterilmez.
class CloudflareFallback {
  CloudflareFallback._();

  /// Akis aktarma (relay) uclari. Sirasiyla denenir.
  static const List<String> streamBases = [
    'https://cloudtune-stream.cloudtune-5b3.workers.dev',
    'https://stream.cloudtune.app',
  ];

  static const String repairLogUrl =
      'https://cloudtune-repair.cloudtune-5b3.workers.dev/api/repair-log';

  static const Duration _timeout = Duration(seconds: 8);

  /// Video kimligi icin yedek ses adresi. Bulunamazsa null.
  static Future<Uri?> audioUrl(String videoId) async {
    for (final base in streamBases) {
      try {
        final res = await http
            .get(Uri.parse('$base/v1/resolve?id=$videoId'))
            .timeout(_timeout);
        if (res.statusCode != 200) continue;
        final data = jsonDecode(res.body);
        final url = data is Map ? (data['url'] ?? data['audio']) : null;
        if (url is String && url.isNotEmpty) return Uri.tryParse(url);
      } catch (_) {
        // Sessizce sonraki uca gec.
      }
    }
    return null;
  }

  /// Onarim kaydi / cihaz raporu. Basarisiz olsa bile uygulama etkilenmez.
  static Future<bool> report(Map<String, dynamic> payload) async {
    for (final url in [repairLogUrl]) {
      try {
        final res = await http
            .post(
              Uri.parse(url),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode(payload),
            )
            .timeout(_timeout);
        if (res.statusCode >= 200 && res.statusCode < 300) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Cihaz bilgisi (hassas veri yok: platform, surum, model).
  static Map<String, dynamic> deviceInfo(Map<String, dynamic> extra) => {
        'platform': defaultTargetPlatform.name,
        'os': PlatformInfo.name,
        'app_version': PlatformInfo.appVersion,
        'ts': DateTime.now().toUtc().toIso8601String(),
        ...extra,
      };
}

/// platform paketine bagimlilik eklemeden temel bilgiler.
class PlatformInfo {
  PlatformInfo._();
  static String name = _detect();
  static String appVersion = '';

  static String _detect() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }
}
