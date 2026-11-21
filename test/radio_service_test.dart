import 'package:flutter_test/flutter_test.dart';
import 'package:cloudtune/core/radio_service.dart';

void main() {
  group('Türk radyo kataloğu', () {
    test('API istasyonu doğrudan akış Track olarak çevrilir', () {
      final station = RadioStation.fromApi(<String, dynamic>{
        'stationuuid': 'abc-123',
        'name': '  Test Radyo  ',
        'url': 'https://example.test/live',
        'url_resolved': 'https://example.test/live.mp3',
        'favicon': 'https://example.test/logo.png',
        'tags': 'pop,rock',
        'state': 'İstanbul',
        'codec': 'MP3',
        'bitrate': 128,
        'clickcount': 42,
        'hls': 0,
      });

      expect(station, isNotNull);
      expect(station!.id, 'abc-123');
      expect(station.name, 'Test Radyo');
      expect(station.streamUrl, 'https://example.test/live.mp3');

      final track = station.toTrack();
      expect(track.id, 'radio:abc-123');
      expect(track.sourceUrl, 'https://example.test/live.mp3');
      expect(track.coverUrl, 'https://example.test/logo.png');
      expect(track.duration, isNull);
      expect(station.subtitle, contains('pop'));
      expect(station.subtitle, contains('İstanbul'));
      expect(station.subtitle, contains('128 kbps'));
    });

    test('çözümlenmiş URL yoksa ham URL kullanılır', () {
      final station = RadioStation.fromApi(<String, dynamic>{
        'stationuuid': 'raw-1',
        'name': 'Ham Radyo',
        'url': 'http://stream.test/radio',
        'url_resolved': '',
      });

      expect(station?.streamUrl, 'http://stream.test/radio');
    });

    test(
        'favicon yoksa domain logosu, homepage yoksa katalog logosu kullanılır',
        () {
      final withHome = RadioStation(
        id: 'logo-1',
        name: 'Logo Radyo',
        streamUrl: 'https://live.test/stream',
        homepage: 'https://radyo.example.com/',
      );
      expect(withHome.logoUrl,
          'https://www.google.com/s2/favicons?domain=radyo.example.com&sz=128');
      expect(withHome.toTrack().coverUrl, withHome.logoUrl);

      final noHome = RadioStation(
        id: 'logo-2',
        name: 'Logosuz Radyo',
        streamUrl: 'https://live.test/stream',
      );
      expect(noHome.logoUrl, 'https://www.radio-browser.info/favicon.ico');
    });

    test('eksik kimlik, adres veya adım istasyonu reddedilir', () {
      expect(
        RadioStation.fromApi(<String, dynamic>{
          'stationuuid': '',
          'name': 'Radyo',
          'url': 'https://x.test',
        }),
        isNull,
      );
      expect(
        RadioStation.fromApi(<String, dynamic>{
          'stationuuid': 'id',
          'name': 'Radyo',
          'url': '',
        }),
        isNull,
      );
      expect(
        RadioStation.fromApi(<String, dynamic>{
          'stationuuid': 'id',
          'name': ' ',
          'url': 'https://x.test',
        }),
        isNull,
      );
    });

    test('JSON cache turu korunur', () {
      final station = RadioStation(
        id: 'cached-1',
        name: 'Cache Radyo',
        streamUrl: 'https://cache.test/live',
        favicon: 'https://cache.test/logo.png',
        bitrate: 64,
      );

      final restored = RadioStation.fromJson(station.toJson());
      expect(restored.id, station.id);
      expect(restored.name, station.name);
      expect(restored.streamUrl, station.streamUrl);
      expect(restored.bitrate, 64);
    });
  });
}
