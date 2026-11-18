import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'download_service.dart';
import 'link_handler.dart';
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

  static const int _maxDownloadAttempts = 3;
  static const Duration _downloadCooldown = Duration(seconds: 60);
  static const int _maxPendingAttempts = 4;
  static const Duration _playbackUnrecoverableCooldown = Duration(minutes: 5);

  Timer? _timer;
  bool _started = false;
  bool _scanning = false;
  Future<void>? _scanFuture;
  bool _fullRepairRunning = false;
  Future<RepairReport>? _fullRepairFuture;
  bool _foreground = true;
  int _consecutiveFailures = 0;
  int _fixCount = 0;
  DateTime? _lastFixAt;
  String? _lastIssue;
  DateTime? _lastPlaybackUnrecoverableAt;

  final List<_PendingRepair> _pending = <_PendingRepair>[];
  final Map<String, int> _downloadAttempts = <String, int>{};
  final Map<String, DateTime> _nextDownloadAt = <String, DateTime>{};

  bool get active => _timer?.isActive ?? false;
  bool get scanning => _scanning;
  bool get fullRepairRunning => _fullRepairRunning;
  int get fixCount => _fixCount;
  DateTime? get lastFixAt => _lastFixAt;
  String? get lastIssue => _lastIssue;
  int get pendingCount => _pending.length;

  static Future<void> start() async {
    final bot = instance;
    if (bot._started) return;
    bot._started = true;

    WidgetsBinding.instance.addObserver(bot);
    try {
      final info = await PackageInfo.fromPlatform();
      PlatformInfo.appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    // stop() may have been called while PackageInfo was resolving.
    if (!bot._started) return;
    bot._schedule(bot._foreground ? _idleInterval : _backgroundInterval);
    bot.notifyListeners();
    unawaited(_ensureLogFile());
  }

  static void stop() {
    final bot = instance;
    bot._timer?.cancel();
    bot._timer = null;
    bot._started = false;
    WidgetsBinding.instance.removeObserver(bot);
    bot.notifyListeners();
  }

  /// Run a scan now. Concurrent callers share the in-flight scan future.
  Future<void> forceScan() async {
    final existing = _scanFuture;
    if (existing != null) {
      await existing;
      return;
    }
    await _runScan();
  }

  /// Kullanıcı tarafından tetiklenen tam onarım. Sessiz taramanın aksine
  /// bekleme sürelerini/deneme sınırlarını yok sayar, üç aşamayı sırayla
  /// zorla çalıştırır ve sonucu rapor + log olarak döndürür.
  /// Eşzamanlı çağrılar aynı raporu paylaşır.
  Future<RepairReport> runFullRepair() {
    final existing = _fullRepairFuture;
    if (existing != null) return existing;
    final future = _runFullRepair();
    _fullRepairFuture = future;
    return future;
  }

  Future<RepairReport> _runFullRepair() async {
    _fullRepairRunning = true;
    notifyListeners();
    try {
      // Sessiz tarama uçaksa çakışmamak için bitmesini bekle.
      final scan = _scanFuture;
      if (scan != null) await scan;

      final startedAt = DateTime.now();
      final stages = <RepairStageResult>[
        await _guardedStage('playback', _forcePlayback),
        await _guardedStage('downloads', _forceDownloads),
        await _guardedStage('pending', _forcePending),
      ];
      final report = RepairReport(
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        stages: stages,
      );
      // Raporun tamamı tek log kaydı olarak yazılır.
      await _log('full_repair_completed', report.toJson());
      return report;
    } finally {
      _fullRepairFuture = null;
      _fullRepairRunning = false;
      notifyListeners();
    }
  }

  /// Bir aşama patlarsa diğerlerini çalıştırmaya devam et; hata kullanıcıya
  /// gösterilmez, yalnızca loga yazılır.
  Future<RepairStageResult> _guardedStage(
    String name,
    Future<RepairStageResult> Function() stage,
  ) async {
    try {
      return await stage();
    } catch (e) {
      await _log('full_repair_stage_error', {
        'stage': name,
        'error': e.toString(),
      });
      return RepairStageResult(
        name: name,
        status: RepairStageStatus.problem,
        remaining: 1,
      );
    }
  }

  Future<RepairStageResult> _forcePlayback() async {
    final player = PlayerController.instance;
    final error = player.error;
    if (error == null) {
      return const RepairStageResult(
          name: 'playback', status: RepairStageStatus.skipped);
    }
    final track = player.current;
    if (track == null) {
      return const RepairStageResult(
          name: 'playback', status: RepairStageStatus.skipped);
    }

    _lastIssue = error;
    await player.retry();
    if (player.error == null) {
      _consecutiveFailures = 0;
      _lastPlaybackUnrecoverableAt = null;
      _fixCount++;
      _lastFixAt = DateTime.now();
      _schedule(_foreground ? _idleInterval : _backgroundInterval);
      await _log('full_repair_playback_repaired', {'video_id': track.id});
      return const RepairStageResult(
        name: 'playback',
        status: RepairStageStatus.success,
        fixed: 1,
      );
    }

    await _log('full_repair_playback_failed', {
      'video_id': track.id,
      'issue': player.error,
    });
    return const RepairStageResult(
      name: 'playback',
      status: RepairStageStatus.problem,
      remaining: 1,
    );
  }

  Future<RepairStageResult> _forceDownloads() async {
    final service = DownloadService.instance;
    final failureIds = service.failureIds;
    if (failureIds.isEmpty) {
      return const RepairStageResult(
          name: 'downloads', status: RepairStageStatus.skipped);
    }

    var fixed = 0;
    var remaining = 0;
    // Zorla mod: cooldown ve deneme sınırı yok, tüm kimlikler tek tek denenir.
    for (final id in failureIds) {
      final Track? track = service.failedTrack(id);
      var succeeded = false;
      try {
        await service.retryDownload(id);
        succeeded = service.savedPathOf(id) != null;
      } catch (_) {
        succeeded = false;
      }
      if (succeeded) {
        service.forgetFailure(id);
        _downloadAttempts.remove(id);
        _nextDownloadAt.remove(id);
        _fixCount++;
        _lastFixAt = DateTime.now();
        fixed++;
        await _log('full_repair_download_repaired', {
          'video_id': id,
          'title': track?.title,
        });
      } else {
        remaining++;
        // Sessiz tarama yine deneyebilsin: sayacı sıfırla, kısa cooldown ver.
        _downloadAttempts[id] = 0;
        _nextDownloadAt[id] = DateTime.now().add(_downloadCooldown);
        _lastIssue = 'download_failed:$id';
        await _log('full_repair_download_failed', {
          'video_id': id,
          'title': track?.title,
        });
      }
    }

    return RepairStageResult(
      name: 'downloads',
      status: remaining > 0 ? RepairStageStatus.problem : RepairStageStatus.success,
      fixed: fixed,
      remaining: remaining,
    );
  }

  Future<RepairStageResult> _forcePending() async {
    if (_pending.isEmpty) {
      return const RepairStageResult(
          name: 'pending', status: RepairStageStatus.skipped);
    }

    var fixed = 0;
    var remaining = 0;
    // Kopya üzerinde gez: başarılı öğeler listeden çıkarılacak.
    for (final item in _pending.toList(growable: false)) {
      late final bool success;
      if (item.type.startsWith('link_')) {
        success = await LinkHandler.open(item.payload);
      } else if (item.type.startsWith('search_')) {
        try {
          final results = await YoutubeService.instance.search(
            item.payload,
            limit: 5,
          );
          success = results.isNotEmpty;
        } catch (_) {
          success = false;
        }
      } else {
        _pending.remove(item);
        continue;
      }

      if (success) {
        _pending.remove(item);
        _fixCount++;
        _lastFixAt = DateTime.now();
        fixed++;
        await _log('full_repair_pending_repaired', {
          'type': item.type,
          'payload': item.payload,
        });
      } else {
        remaining++;
        // Kuyrukta kalsın; sessiz tarama normal backoff ile yeniden denesin.
        item.attempts = 0;
        item.nextAt = DateTime.now().add(_pendingBackoff(1));
        _lastIssue = item.type;
        await _log('full_repair_pending_failed', {
          'type': item.type,
          'payload': item.payload,
        });
      }
    }

    return RepairStageResult(
      name: 'pending',
      status: remaining > 0 ? RepairStageStatus.problem : RepairStageStatus.success,
      fixed: fixed,
      remaining: remaining,
    );
  }

  void _schedule(Duration interval) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      unawaited(_runScan());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    _foreground = state == AppLifecycleState.resumed;
    _schedule(
      _foreground
          ? (_consecutiveFailures > 0 ? _busyInterval : _idleInterval)
          : _backgroundInterval,
    );
    if (_foreground) unawaited(_runScan());
  }

  /// Single entry point for every scan trigger. Deduplicates overlapping runs.
  Future<void> _runScan() {
    final existing = _scanFuture;
    if (existing != null) return existing;

    _scanning = true;
    final future = _performScan();
    _scanFuture = future;
    return future;
  }

  Future<void> _performScan() async {
    try {
      await _scan();
    } catch (_) {
      // The worker must never throw.
    } finally {
      _scanFuture = null;
      _scanning = false;
      notifyListeners();
    }
  }

  Future<void> _scan() async {
    final now = DateTime.now();
    // Keep stages independent: one broken service must not starve the rest.
    try {
      await _repairPlayback(now);
    } catch (_) {}
    try {
      await _repairDownloads(now);
    } catch (_) {}
    try {
      await _repairPending(now);
    } catch (_) {}

    if (_consecutiveFailures == 0 && _pending.isEmpty) {
      _lastIssue = null;
    }
  }

  Future<void> _repairPlayback(DateTime now) async {
    final player = PlayerController.instance;
    final error = player.error;

    if (error == null) {
      // Reset only once the error is actually gone.
      if (_consecutiveFailures > 0 || _lastPlaybackUnrecoverableAt != null) {
        _consecutiveFailures = 0;
        _lastPlaybackUnrecoverableAt = null;
        _schedule(_foreground ? _idleInterval : _backgroundInterval);
      }
      return;
    }

    final track = player.current;
    if (track == null) return;

    _lastIssue = error;
    await player.retry();

    if (player.error == null) {
      _consecutiveFailures = 0;
      _lastPlaybackUnrecoverableAt = null;
      _fixCount++;
      _lastFixAt = DateTime.now();
      _schedule(_foreground ? _idleInterval : _backgroundInterval);
      await _log('playback_repaired', {'video_id': track.id});
      return;
    }

    _consecutiveFailures++;
    _schedule(_foreground ? _busyInterval : _backgroundInterval);

    if (_consecutiveFailures >= 3) {
      final loggedAt = _lastPlaybackUnrecoverableAt;
      if (loggedAt == null ||
          now.difference(loggedAt) >= _playbackUnrecoverableCooldown) {
        _lastPlaybackUnrecoverableAt = now;
        await _log('playback_unrecoverable', {
          'video_id': track.id,
          'issue': player.error,
          'fix_attempts': _consecutiveFailures,
        });
      }
    }
  }

  Future<void> _repairDownloads(DateTime now) async {
    final service = DownloadService.instance;
    final failureIds = service.failureIds;

    // A failure forgotten elsewhere must also clear our local backoff state.
    _downloadAttempts.removeWhere((id, _) => !failureIds.contains(id));
    _nextDownloadAt.removeWhere((id, _) => !failureIds.contains(id));

    for (final id in failureIds) {
      final next = _nextDownloadAt[id];
      if (next != null && now.isBefore(next)) continue;
      // Exhausted IDs stay dormant until the failure is forgotten.
      if ((_downloadAttempts[id] ?? 0) >= _maxDownloadAttempts) continue;

      final Track? t = service.failedTrack(id);
      final attempt = (_downloadAttempts[id] ?? 0) + 1;
      _lastIssue = 'download_failed:$id';
      await _log('download_failed', {
        'video_id': id,
        'title': t?.title,
        'attempt': attempt,
        'max_attempts': _maxDownloadAttempts,
        'retry': true,
      });

      var succeeded = false;
      try {
        await service.retryDownload(id);
        succeeded = service.savedPathOf(id) != null;
      } catch (_) {
        succeeded = false;
      }
      if (succeeded) {
        service.forgetFailure(id);
        _downloadAttempts.remove(id);
        _nextDownloadAt.remove(id);
        _fixCount++;
        _lastFixAt = DateTime.now();
        await _log('download_repaired', {
          'video_id': id,
          'title': t?.title,
        });
      } else {
        _downloadAttempts[id] = attempt;
        if (attempt >= _maxDownloadAttempts) {
          await _log('download_unrecoverable', {
            'video_id': id,
            'attempts': attempt,
          });
        } else {
          _nextDownloadAt[id] = DateTime.now().add(_downloadCooldown);
        }
      }
    }
  }

  Future<void> _repairPending(DateTime now) async {
    if (_pending.isEmpty) return;

    final due = _pending
        .where((item) => !now.isBefore(item.nextAt))
        .toList(growable: false);

    for (final item in due) {
      late final bool success;
      if (item.type.startsWith('link_')) {
        success = await LinkHandler.open(item.payload);
      } else if (item.type.startsWith('search_')) {
        try {
          final results = await YoutubeService.instance.search(
            item.payload,
            limit: 5,
          );
          success = results.isNotEmpty;
        } catch (_) {
          success = false;
        }
      } else {
        _pending.remove(item);
        continue;
      }

      if (success) {
        _pending.remove(item);
        _fixCount++;
        _lastFixAt = DateTime.now();
        await _log('repair_success', {
          'type': item.type,
          'payload': item.payload,
        });
        continue;
      }

      item.attempts++;
      if (item.attempts >= _maxPendingAttempts) {
        _pending.remove(item);
        await _log('repair_gave_up', {
          'type': item.type,
          'payload': item.payload,
          'attempts': item.attempts,
        });
      } else {
        item.nextAt = DateTime.now().add(_pendingBackoff(item.attempts));
        await _log('repair_retry', {
          'type': item.type,
          'payload': item.payload,
          'attempts': item.attempts,
        });
      }
    }
  }

  static Duration _pendingBackoff(int attempts) => switch (attempts) {
        1 => const Duration(minutes: 1),
        2 => const Duration(minutes: 5),
        3 => const Duration(minutes: 15),
        _ => const Duration(minutes: 15),
      };

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

    if (type.startsWith('link_') || type.startsWith('search_')) {
      final raw = type.startsWith('link_') ? extra['link'] : extra['query'];
      final payload = raw?.toString();
      if (payload != null && payload.isNotEmpty) {
        _pending.add(_PendingRepair(
          type: type,
          payload: payload,
          attempts: 0,
          nextAt: DateTime.now(),
        ));
      }
    }

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

/// Tam onarımda tek aşamanın sonucu: başarılı / sorunlu / atlanan + sayılar.
class RepairStageResult {
  const RepairStageResult({
    required this.name,
    required this.status,
    this.fixed = 0,
    this.remaining = 0,
  });

  /// `playback`, `downloads` veya `pending`.
  final String name;
  final RepairStageStatus status;
  final int fixed;
  final int remaining;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'stage': name,
        'status': status.name,
        'fixed': fixed,
        'remaining': remaining,
      };

  @override
  String toString() =>
      '$name:${status.name}(fixed=$fixed, remaining=$remaining)';
}

/// Tam onarımın toplu raporu. UI'da sonuç diyaloğu ve log kaydı için kullanılır.
class RepairReport {
  RepairReport({
    required this.startedAt,
    required this.finishedAt,
    required this.stages,
  });

  final DateTime startedAt;
  final DateTime finishedAt;
  final List<RepairStageResult> stages;

  int get fixedCount => stages.fold(0, (sum, stage) => sum + stage.fixed);
  int get remainingCount =>
      stages.fold(0, (sum, stage) => sum + stage.remaining);
  bool get hasRemaining => remainingCount > 0;
  Duration get duration => finishedAt.difference(startedAt);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'started_at': startedAt.toUtc().toIso8601String(),
        'finished_at': finishedAt.toUtc().toIso8601String(),
        'duration_ms': duration.inMilliseconds,
        'fixed': fixedCount,
        'remaining': remainingCount,
        'stages': [for (final stage in stages) stage.toJson()],
      };

  @override
  String toString() =>
      'RepairReport(fixed=$fixedCount, remaining=$remainingCount, '
      'duration=${duration.inMilliseconds}ms, stages=$stages)';
}

enum RepairStageStatus { success, problem, skipped }

class _PendingRepair {
  _PendingRepair({
    required this.type,
    required this.payload,
    required this.attempts,
    required this.nextAt,
  });

  final String type;
  final String payload;
  int attempts;
  DateTime nextAt;
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
