// Denetim bulgusu: mevcut testler kendi fake tiplerini tanımlıyordu. Bu dosya
// GERÇEK üretim modüllerini import edip ajansal API sözleşmesini doğrular.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cloudtune/core/library.dart';
import 'package:cloudtune/core/room_service.dart';
import 'package:cloudtune/core/speech_service.dart';
import 'package:cloudtune/core/youtube_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('gerçek Library API: playlist ve tercih alanları mevcut', () async {
    final library = Library.instance;
    await library.init();
    expect(library.playlistMetas, isA<List<PlaylistMeta>>());
    expect(library.artistPlaylists, isA<List<PlaylistMeta>>());
    expect(library.avatarVersion, isA<int>());

    await library.setRepeatMode(1);
    expect(library.repeatMode, 1);
    // PlayerController ile aynı anahtar: çift kaynak oluşmasın.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ct.repeatMode'), 'all');
  });

  test('gerçek YoutubeService API: cache metotları ve kalite', () {
    final service = YoutubeService.instance;
    service.setQuality('low');
    expect(service.quality, anyOf('low', 'medium', 'high', 'lossless'));
    // Ağa çıkmaz; yalnızca bellek içi haritaları temizler.
    service.clearSearchCache();
    service.clearCache();
  });

  test('gerçek RoomService.normalizeCode MQTT topic için güvenli', () {
    expect(RoomService.normalizeCode(' ab12 '), 'AB12');
    expect(RoomService.normalizeCode('bad/code'), isEmpty);
    expect(RoomService.normalizeCode(''), isEmpty);
    expect(RoomService.normalizeCode('A' * 13), isEmpty);
  });

  test('gerçek RoomService: şifre normalize ve discovery payload', () {
    // Hem host hem katılan aynı normalize yolunu kullanır; büyük/küçük harf
    // anlamlıdır, yalnızca kenar boşlukları atılır.
    expect(RoomService.normalizePassword('  sifre  '), 'sifre');
    expect(RoomService.normalizePassword('Sifre'), 'Sifre');
    expect(RoomService.normalizePassword(''), '');

    final room = RoomDiscovery.fromJson(<String, dynamic>{
      'code': ' ab12 ',
      'hostId': 'host-1',
      'roomName': 'Oda',
      'memberCount': 3,
      'hasPassword': false,
      'hostName': 'Ali',
    });
    expect(room.code, 'AB12');
    expect(room.memberCount, 3);
    expect(room.hasPassword, isFalse);
    expect(room.toJson()['code'], 'AB12');
  });

  test('gerçek SpeechService sözleşmesi en az bu metotları sunar', () {
    final SpeechService speech = WhisperSpeechService();
    expect(speech.isListening, isFalse);
    expect(speech.lastTranscript, '');
    expect(speech.status, isNotNull);
    expect(speech.partialResults, isNotNull);
  });
}
