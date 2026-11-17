import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'library.dart';
import 'models.dart';
import 'settings_service.dart';

/// Yedekleme ve geri yükleme. Tüm veri cihazda tutulur; hiçbir sunucuya
/// gönderilmez. Dosya biçimi sürümlenmiş düz JSON'dur.
class BackupService {
  BackupService._();

  static final BackupService instance = BackupService._();

  static const int _formatVersion = 1;

  Future<Directory> _backupDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/CloudTune/backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Kullanıcıya gösterilen yedek klasörün yolu.
  Future<String> backupDirectoryPath() async => (await _backupDir()).path;

  Map<String, dynamic> exportData() {
    final library = Library.instance;
    final settings = SettingsService.instance;
    return {
      'format': _formatVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'library': {
        'history': library.history.map((t) => t.toJson()).toList(),
        'liked': library.liked.map((t) => t.toJson()).toList(),
        'playlists': {
          for (final name in library.playlistNames)
            name: library.getPlaylist(name).map((t) => t.toJson()).toList(),
        },
        'searchHistory': library.searchHistory,
      },
      'settings': {
        'audioQuality': settings.audioQuality,
        'equalizer': settings.equalizerEnabled,
        'equalizerPreset': settings.equalizerPreset,
        'oledBlack': settings.oledBlack,
        'themeMode': settings.themeMode.name,
        'language': settings.languageCode,
        'sponsorBlock': settings.sponsorBlockEnabled,
        'sponsorCategories': settings.sponsorCategories,
        'syncedLyrics': settings.syncedLyrics,
        'qualityBadge': settings.showQualityBadge,
      },
    };
  }

  /// Yedeği cihazın belgeler dizinine yazar ve dosya yolunu döndürür.
  Future<String?> writeBackupFile() async {
    try {
      final dir = await _backupDir();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final file = File('${dir.path}/cloudtune-$stamp.json');
      await file.writeAsString(jsonEncode(exportData()));
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<List<FileSystemEntity>> listBackupFiles() async {
    try {
      final dir = await _backupDir();
      return dir.listSync().where((e) => e.path.endsWith('.json')).toList()
        ..sort((a, b) => b.path.compareTo(a.path));
    } catch (_) {
      return const <FileSystemEntity>[];
    }
  }

  /// En yeni yedek dosyasını geri yükler.
  Future<bool> restoreLatest() async {
    try {
      final files = await listBackupFiles();
      if (files.isEmpty) return false;
      return await restoreFromFile(files.first.path);
    } catch (_) {
      return false;
    }
  }

  /// Yedek dosyasını okuyup mevcut veriyle birleştirir.
  Future<bool> restoreFromFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return false;
      await importData(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Yedek/yerel eşitleme paketindeki veriyi mevcut kütüphaneye ekler.
  Future<void> importData(Map<dynamic, dynamic> data) async {
    final library = Library.instance;
    final rawLibrary = data['library'];
    if (rawLibrary is Map) {
      for (final value in _tracks(rawLibrary['history'])) {
        await library.remember(value);
      }
      for (final value in _tracks(rawLibrary['liked'])) {
        if (!library.isLiked(value.id)) await library.toggleLike(value);
      }
      final playlists = rawLibrary['playlists'];
      if (playlists is Map) {
        playlists.forEach((key, value) {
          if (key is! String || value is! List) return;
          final tracks = _tracks(value);
          if (tracks.isEmpty) return;
          final existing = library.getPlaylist(key);
          final merged = <Track>[...existing];
          final ids = merged.map((t) => t.id).toSet();
          for (final track in tracks) {
            if (ids.add(track.id)) merged.add(track);
          }
          unawaited(library.createPlaylist(key, merged));
        });
      }
      final searches = rawLibrary['searchHistory'];
      if (searches is List) {
        for (final value in searches) {
          if (value is String && value.trim().isNotEmpty) {
            await library.addSearchHistory(value);
          }
        }
      }
    }

    final rawSettings = data['settings'];
    if (rawSettings is Map) await _restoreSettings(rawSettings);
  }

  Future<void> _restoreSettings(Map<dynamic, dynamic> raw) async {
    final settings = SettingsService.instance;
    final quality = raw['audioQuality']?.toString();
    if (quality != null && SettingsService.audioQualities.contains(quality)) {
      await settings.setAudioQuality(quality);
    }
    if (raw['equalizer'] is bool) {
      await settings.setEqualizerEnabled(raw['equalizer'] as bool);
    }
    final preset = raw['equalizerPreset']?.toString();
    if (preset != null && SettingsService.equalizerPresets.contains(preset)) {
      await settings.setEqualizerPreset(preset);
    }
    if (raw['oledBlack'] is bool) {
      await settings.setOledBlack(raw['oledBlack'] as bool);
    }
    if (raw['sponsorBlock'] is bool) {
      await settings.setSponsorBlockEnabled(raw['sponsorBlock'] as bool);
    }
    if (raw['sponsorCategories'] is List) {
      final incoming = (raw['sponsorCategories'] as List)
          .whereType<String>()
          .where(SettingsService.sponsorCategoryLabels.containsKey)
          .toSet();
      if (incoming.isNotEmpty) {
        for (final category in SettingsService.defaultSponsorCategories) {
          await settings.setSponsorCategory(
            category,
            incoming.contains(category),
          );
        }
      }
    }
    if (raw['syncedLyrics'] is bool) {
      await settings.setSyncedLyrics(raw['syncedLyrics'] as bool);
    }
    if (raw['qualityBadge'] is bool) {
      await settings.setShowQualityBadge(raw['qualityBadge'] as bool);
    }
    final language = raw['language']?.toString();
    if (language != null && SettingsService.supportedLanguages.containsKey(language)) {
      await settings.setLanguage(language);
    }
  }

  static List<Track> _tracks(Object? raw) {
    if (raw is! List) return const <Track>[];
    final result = <Track>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final track = Track.fromJson(item);
        if (track.id.isNotEmpty) result.add(track);
      } catch (_) {}
    }
    return result;
  }

  /// Görsel önbelleğini temizler. Parça çözümleme önbelleği ayrıca
  /// `YoutubeService.clearCache()` ile temizlenir.
  void clearImageCache() {
    imageCache.clear();
    imageCache.clearLiveImages();
  }
}
