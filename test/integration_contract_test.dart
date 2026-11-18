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

  test('gerçek SpeechService sözleşmesi en az bu metotları sunar', () {
    final SpeechService speech = WhisperSpeechService();
    expect(speech.isListening, isFalse);
    expect(speech.lastTranscript, '');
    expect(speech.status, isNotNull);
    expect(speech.partialResults, isNotNull);
  });
}
