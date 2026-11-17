import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'download_service.dart';
import 'models.dart';
import 'player_controller.dart';
import 'youtube_service.dart';

/// Quiet, device-only maintenance worker. It never shows UI errors and never
/// contacts a network service. Scans run on an adaptive interval: frequently
/// while problems are present, rarely when idle or in the background.
class RepairBot extends ChangeNotifier with WidgetsBindingObserver {
  RepairBot._();

  static final RepairBot instance = RepairBot._();

  static const Duration _idleInterval = Duration(seconds: 30);
  static const Duration _busyInterval = Duration(seconds: 10);
  static const Duration _backgroundInterval = Duration(seconds: 60);

  static const String _logFileName = 'repair_bot_logs.json';
  static const int _maxLogEntries = 500;

  Timer? _timer;
  bool _scanning = false;
  bool _foreground = true;
  int _consecutiveFailures = 0;
  int _fixCount = 0;
  DateTime? _lastFixAt;
  String? _lastIssue;

  bool get active => _timer?.isActive ?? false;
  bool get scanning => _scanning;
  int get fixCount => _fixCount;
  DateTime? get lastFixAt => _lastFixAt;
  String? get lastIssue => _lastIssue;

  static Future<void> start() async {
    final bot = instance;
    if (bot.active) return;

    WidgetsBinding.instance.addObserver(bot);
    try {
      final info = await PackageInfo.fromPlatform();
      PlatformInfo.appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    bot._schedule(bot._foreground ? _idleInterval : _backgroundInterval);
    bot.notifyListeners();
    unawaited(RepairBot._ensureLogFile());
  }

  static void stop() {
    final bot = instance;
    bot._timer?.cancel();
    bot._timer = null;
    WidgetsBinding.instance.removeObserver(bot);
    bot.notifyListeners();
  }

  void _schedule(Duration interval) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      if (_scanning) return;
      _scanning = true;
      unawaited(_scan());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule(
      _foreground
          ? (_consecutiveFailures > 0 ? _busyInterval : _idleInterval)
          : _backgroundInterval,
    );
    if (_foreground && !_scanning) {
      _scanning = true;
      unawaited(_scan());
    }
  }

  Future<void> _scan() async {
    try {
      final player = PlayerController.instance;

      // Playback failures: retry the current track once per scan.
      if (player.error != null && player.current != null) {
        _consecutiveFailures++;
        _lastIssue = player.error;
        await player.retry();
        _fixCount++;
        _lastFixAt = DateTime.now();
        if (_consecutiveFailures >= 3) {
          await _log('playback_unrecoverable', {
            'video_id': player.current!.id,
            'issue': player.error,
            'fix_attempts': _consecutiveFailures,
          });
        }
      } else if (player.current != null && _consecutiveFailures > 0) {
        _consecutiveFailures = 0;
        _schedule(_foreground ? _idleInterval : _backgroundInterval);
      }

      // Failed downloads are marked with a negative progress value.
      final progress = DownloadService.instance.downloadProgress;
      for (final entry in progress.entries) {
        if (entry.value >= 0) continue;
        _lastIssue = 'download_failed:${entry.key}';
        await _log('download_failed', {'video_id': entry.key, 'retry': true});
        unawaited(_retryDownload(entry.key));
      }

      // Report a link/search failure at most once every five minutes.
      final issue = _lastIssue;
      if (issue != null &&
          (issue.startsWith('link_') || issue.startsWith('search_'))) {
        final now = DateTime.now();
        if (_lastFixAt == null || now.difference(_lastFixAt!) > const Duration(minutes: 5)) {
          await _log(issue, {'auto_retry': true});
          _lastFixAt = now;
        }
      }

      if (_consecutiveFailures == 0 && _lastIssue != null) {
        _lastIssue = null;
      }
    } catch (_) {
      // The worker must never throw.
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  Future<void> _retryDownload(String videoId) async {
    try {
      Track? track;
      for (final candidate in PlayerController.instance.tracks) {
        if (candidate.id == videoId) {
          track = candidate;
          break;
        }
      }
      track ??= await YoutubeService.instance.trackById(videoId);
      await DownloadService.instance.download(track);
    } catch (_) {}
  }

  Future<void> _log(String type, Map<String, dynamic> extra) async {
    await _appendLog({
      'event_type': type,
      'platform': Platform.operatingSystem,
      'os': PlatformInfo.name,
      'app_version': PlatformInfo.appVersion,
      'ts': DateTime.now().toUtc().toIso8601String(),
      ...extra,
    });
  }

  /// Silent notification from another service (for example a failed link).
  Future<void> reportEvent(String type, Map<String, dynamic> extra) async {
    _lastIssue = type;
    notifyListeners();
    await _log(type, extra);
  }

  static Future<File> _logFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_logFileName');
  }

  /// Onarım kayıtlarını düz metin olarak döndürür; kullanıcıya hata
  /// ayrıntısı gösterilmez, yalnızca kopyalama seçeneği sunulur.
  static Future<String> readLogText() async {
    try {
      final file = await _logFile();
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  static Future<void> _ensureLogFile() async {
    try {
      final file = await _logFile();
      if (!await file.exists()) await file.writeAsString('[]');
    } catch (_) {}
  }

  static Future<void> _appendLog(Map<String, dynamic> entry) async {
    try {
      final file = await _logFile();
      var logs = <dynamic>[];
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is List) logs = decoded;
        }
      }
      logs.insert(0, entry);
      if (logs.length > _maxLogEntries) {
        logs = logs.sublist(0, _maxLogEntries);
      }
      await file.writeAsString(jsonEncode(logs));
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> getLogs() async {
    try {
      final file = await _logFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final data = jsonDecode(content);
          if (data is List) {
            return data.whereType<Map<String, dynamic>>().toList();
          }
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<void> clearLogs() async {
    try {
      final file = await _logFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Basic platform information without extra dependencies.
class PlatformInfo {
  PlatformInfo._();

  static String name = _detect();
  static String appVersion = '';

  static String _detect() => switch (Platform.operatingSystem) {
        'android' => 'android',
        'ios' => 'ios',
        'linux' => 'linux',
        'windows' => 'windows',
        'macos' => 'macos',
        'fuchsia' => 'fuchsia',
        _ => 'unknown',
      };
}
