import 'dart:ffi' as ffi;

import 'package:cloudtune/core/repair_bot.dart';
import 'package:cloudtune/core/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final info = UpdateInfo(
    version: '3.0.55',
    versionCode: 256,
    notes: '',
    androidArm64Url: 'https://cdn/arm64.apk',
    androidArmv7Url: 'https://cdn/armv7.apk',
    androidX64Url: 'https://cdn/x64.apk',
    androidUniversalUrl: 'https://cdn/universal.apk',
    linuxDebUrl: 'https://cdn/linux.deb',
    windowsZipUrl: 'https://cdn/windows.zip',
    iosSourceUrl: 'altstore://source',
  );

  group('update artifact selection', () {
    test('Android ABI chooses matching APK, universal is fallback', () {
      expect(
        updateAssetUrl(
          info: info,
          platform: UpdatePlatform.android,
          abi: ffi.Abi.androidArm64,
        ),
        'https://cdn/arm64.apk',
      );
      expect(
        updateAssetUrl(
          info: info,
          platform: UpdatePlatform.android,
          abi: ffi.Abi.androidArm,
        ),
        'https://cdn/armv7.apk',
      );
      expect(
        updateAssetUrl(
          info: info,
          platform: UpdatePlatform.android,
          abi: ffi.Abi.current(),
        ),
        'https://cdn/universal.apk',
      );
    });

    test('Linux and Windows never download an Android APK', () {
      final linuxUrl = updateAssetUrl(
        info: info,
        platform: UpdatePlatform.linux,
        abi: ffi.Abi.current(),
      );
      final windowsUrl = updateAssetUrl(
        info: info,
        platform: UpdatePlatform.windows,
        abi: ffi.Abi.current(),
      );
      expect(linuxUrl, 'https://cdn/linux.deb');
      expect(windowsUrl, 'https://cdn/windows.zip');
      expect(
        updateAssetFileName(
          info: info,
          platform: UpdatePlatform.linux,
          abi: ffi.Abi.current(),
        ),
        endsWith('.deb'),
      );
      expect(
        updateAssetFileName(
          info: info,
          platform: UpdatePlatform.windows,
          abi: ffi.Abi.current(),
        ),
        endsWith('.zip'),
      );
    });

    test('iOS has no direct install artifact', () {
      expect(
        updateAssetUrl(
          info: info,
          platform: UpdatePlatform.ios,
          abi: ffi.Abi.current(),
        ),
        isNull,
      );
    });
  });

  group('playback repair backoff', () {
    final now = DateTime(2026, 11, 24, 12);

    test('delay grows exponentially and is capped', () {
      expect(playbackRetryDelay(0), Duration.zero);
      expect(playbackRetryDelay(1), const Duration(seconds: 15));
      expect(playbackRetryDelay(2), const Duration(seconds: 30));
      expect(playbackRetryDelay(3), const Duration(seconds: 60));
      expect(playbackRetryDelay(6), const Duration(minutes: 5));
    });

    bool retry({
      String? currentId,
      String? attemptedId,
      DateTime? nextAt,
      int attempts = 0,
      int maxAttempts = 3,
    }) {
      return shouldAutoRetryPlayback(
        currentTrackId: currentId,
        attemptedTrackId: attemptedId,
        now: now,
        nextAt: nextAt,
        attempts: attempts,
        maxAttempts: maxAttempts,
      );
    }

    test('changed track retries immediately', () {
      expect(
        retry(currentId: 'new', attemptedId: 'old', attempts: 3),
        isTrue,
      );
    });

    test('same track waits for cooldown and stops after max attempts', () {
      expect(
        retry(
          currentId: 'same',
          attemptedId: 'same',
          nextAt: now.add(const Duration(seconds: 10)),
          attempts: 1,
        ),
        isFalse,
      );
      expect(
        retry(
          currentId: 'same',
          attemptedId: 'same',
          nextAt: now.subtract(const Duration(seconds: 1)),
          attempts: 1,
        ),
        isTrue,
      );
      expect(
        retry(currentId: 'same', attemptedId: 'same', attempts: 3),
        isFalse,
      );
    });
  });
}
