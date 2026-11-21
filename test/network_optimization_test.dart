import 'package:flutter_test/flutter_test.dart';

import 'package:cloudtune/core/models.dart';
import 'package:cloudtune/core/room_service.dart';
import 'package:cloudtune/core/youtube_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mobil veri / Wi-Fi oda trafiği', () {
    test('kalp atışı mobil veride seyrek, komutlar anında kalır', () {
      expect(
        RoomService.stateInterval(mobileData: false),
        const Duration(seconds: 2),
      );
      expect(
        RoomService.stateInterval(mobileData: true),
        const Duration(seconds: 4),
      );
      expect(
        RoomService.presenceInterval(mobileData: false),
        const Duration(seconds: 8),
      );
      expect(
        RoomService.presenceInterval(mobileData: true),
        const Duration(seconds: 16),
      );
    });

    test('keşif, tam sıra ve saat ölçümü mobil veride daha seyrek', () {
      expect(
        RoomService.discoveryInterval(mobileData: false),
        const Duration(seconds: 5),
      );
      expect(
        RoomService.discoveryInterval(mobileData: true),
        const Duration(seconds: 10),
      );
      expect(RoomService.queueRefreshTicks(mobileData: false), 8);
      expect(RoomService.queueRefreshTicks(mobileData: true), 12);
      expect(RoomService.clockProbeTicks(mobileData: false), 4);
      expect(RoomService.clockProbeTicks(mobileData: true), 8);
    });
  });

  group('kapak indirme optimizasyonu', () {
    test('YouTube kapakları küçük varyanta indirgenir', () {
      const track = Track(
        id: 'abc',
        title: 'Test',
        artist: 'Test',
        coverUrl: 'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
      );
      expect(track.thumb, 'https://i.ytimg.com/vi/abc/mqdefault.jpg');
      expect(
        track.artwork,
        'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
      );

      const local = Track(
        id: 'local',
        title: 'Local',
        artist: 'Test',
        coverUrl: 'https://example.com/cover.jpg',
      );
      expect(local.thumb, 'https://example.com/cover.jpg');
    });

    test('çalma listesi kapak dağıtımı URL küçültür', () {
      const playlist = PlaylistInfo(
        id: 'pl',
        title: 'Liste',
        author: 'Test',
        thumbUrl: 'https://img.youtube.com/vi/xyz/hqdefault.jpg',
      );
      expect(playlist.thumb, 'https://img.youtube.com/vi/xyz/mqdefault.jpg');
    });
  });

  test('YouTube arama önbelleği mobil veride daha uzun yaşar', () {
    expect(
      YoutubeService.searchTtlFor(mobileData: false),
      const Duration(minutes: 10),
    );
    expect(
      YoutubeService.searchTtlFor(mobileData: true),
      const Duration(minutes: 30),
    );
    expect(YoutubeService.invBaseCount(mobileData: false), 4);
    expect(YoutubeService.invBaseCount(mobileData: true), 2);
  });

  test('dokunma gecikmesi için görünür adres prefetch sınırı ağa göre ayarlı',
      () {
    expect(YoutubeService.prefetchLimit(mobileData: false), 10);
    expect(YoutubeService.prefetchLimit(mobileData: true), 5);
  });
}
