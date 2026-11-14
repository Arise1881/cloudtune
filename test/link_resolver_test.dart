import 'package:cloudtune/core/link_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = 'dQw4w9WgXcQ';

  group('izin verilen dört adres', () {
    test('youtu.be', () {
      expect(YoutubeLinkResolver.videoId('https://youtu.be/$id'), id);
      expect(YoutubeLinkResolver.videoId('https://youtu.be/$id?si=abc&t=10'), id);
    });
    test('m.youtube.com', () {
      expect(YoutubeLinkResolver.videoId('https://m.youtube.com/watch?v=$id'), id);
    });
    test('youtube.com', () {
      expect(YoutubeLinkResolver.videoId('https://youtube.com/watch?v=$id'), id);
    });
    test('www.youtube.com', () {
      expect(YoutubeLinkResolver.videoId('https://www.youtube.com/watch?v=$id'), id);
      expect(YoutubeLinkResolver.videoId('https://www.youtube.com/shorts/$id'), id);
      expect(YoutubeLinkResolver.videoId('https://www.youtube.com/embed/$id'), id);
    });
    test('şemasız yapıştırma', () {
      expect(YoutubeLinkResolver.videoId('youtu.be/$id'), id);
      expect(YoutubeLinkResolver.videoId('  www.youtube.com/watch?v=$id  '), id);
    });
  });

  group('reddedilenler', () {
    test('başka alan adları', () {
      expect(YoutubeLinkResolver.isYoutubeLink('https://music.youtube.com/watch?v=$id'), false);
      expect(YoutubeLinkResolver.isYoutubeLink('https://evil.com/watch?v=$id'), false);
      expect(YoutubeLinkResolver.isYoutubeLink('https://youtube.com.evil.com/watch?v=$id'), false);
      expect(YoutubeLinkResolver.videoId('https://evil.com/watch?v=$id'), isNull);
    });
    test('arama metni bağlantı sayılmaz', () {
      expect(YoutubeLinkResolver.isYoutubeLink('tarkan şımarık'), false);
      expect(YoutubeLinkResolver.isYoutubeLink('daft punk'), false);
      expect(YoutubeLinkResolver.isYoutubeLink(''), false);
    });
    test('geçersiz kimlik', () {
      expect(YoutubeLinkResolver.videoId('https://youtu.be/kisa'), isNull);
      expect(YoutubeLinkResolver.videoId('https://www.youtube.com/watch'), isNull);
    });
  });

  group('çalma listesi', () {
    test('list parametresi', () {
      const pl = 'PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf';
      expect(YoutubeLinkResolver.playlistId('https://www.youtube.com/playlist?list=$pl'), pl);
      expect(YoutubeLinkResolver.playlistId('https://youtu.be/$id?list=$pl'), pl);
      expect(YoutubeLinkResolver.videoId('https://www.youtube.com/watch?v=$id&list=$pl'), id);
    });
    test('izinsiz adreste null', () {
      expect(YoutubeLinkResolver.playlistId('https://evil.com/playlist?list=PLabcdefghij'), isNull);
    });
  });
}
