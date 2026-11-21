// Denetim bulgusu: mevcut testler kendi fake tiplerini tanımlıyordu. Bu dosya
// GERÇEK üretim modüllerini import edip ajansal API sözleşmesini doğrular.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cloudtune/core/library.dart';
import 'package:cloudtune/core/models.dart';
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

    // Temiz kurulum varsayılanı: işaretçi yazılır, sonsuz radyo açık gelir.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ct.fresh_defaults_v1'), isTrue);
    expect(prefs.getBool('ct.radio'), isTrue);
    expect(library.radioEnabled, isTrue);

    await library.setRepeatMode(1);
    expect(library.repeatMode, 1);
    // PlayerController ile aynı anahtar: çift kaynak oluşmasın.
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

  test('Whisper dili desteklenmeyen UI locale için auto algılamaya düşer', () {
    expect(WhisperSpeechService.whisperLanguageFor('tr-TR'), 'tr');
    expect(WhisperSpeechService.whisperLanguageFor('de'), 'de');
    // 'az' Whisper kataloğunda var; gerçekten desteklenmeyen bir kod kullan.
    expect(WhisperSpeechService.whisperLanguageFor('xx'), 'auto');
  });

  test('http/https/custom oda davet bağlantıları aynı kodu çözer', () {
    for (final link in <String>[
      'http://cloudtune.app/room/AB12?p=sifre',
      'https://cloudtune.app/room/AB12?p=sifre',
      'cloudtune://room/AB12?p=sifre',
    ]) {
      final invite = RoomService.parseInvite(link);
      expect(invite, isNotNull, reason: link);
      expect(invite!.code, 'AB12');
      expect(invite.password, 'sifre');
    }
    expect(RoomService.parseInvite('http://cloudtune.app/room/'), isNull);
  });

  test('oda state payload çalar kuyruğunu ve id bazlı dizini taşır', () {
    final first = Track(id: 'a', title: 'A', artist: 'X');
    final second = Track(id: 'b', title: 'B', artist: 'Y');
    final payload = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: <Track>[first, second],
      index: 9,
      positionMs: 1250,
      playing: true,
    );
    expect((payload['queue'] as List).length, 2);
    final playback = payload['playback'] as Map<String, dynamic>;
    expect(playback['id'], 'b');
    expect(playback['index'], 1);
    expect(playback['positionMs'], 1250);
    expect(playback['playing'], isTrue);
    // Yabancı/bozuk index gelse bile id doğru parçayı bulur.
    expect(
      RoomService.resolveStateIndex(
        <Track>[first, second],
        <String, dynamic>{'id': 'a', 'index': 99},
      ),
      0,
    );

    final stopped = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: const <Track>[],
      index: 0,
      positionMs: 0,
      playing: false,
    );
    final stoppedPlayback = stopped['playback'] as Map<String, dynamic>;
    expect(stoppedPlayback['stopped'], isTrue);
    expect(stoppedPlayback['id'], '');
  });

  test('oda state tekrar ve gecikmiş paketleri ayırt eder', () {
    final first = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: const <Track>[],
      index: 0,
      positionMs: 0,
      playing: false,
      seq: 4,
      sentAt: 1000,
      hostId: 'host-a',
    );
    final replay = Map<String, dynamic>.from(first);
    final newer = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: const <Track>[],
      index: 0,
      positionMs: 0,
      playing: false,
      seq: 5,
      sentAt: 1000,
      hostId: 'host-a',
    );
    final lateOldHost = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: const <Track>[],
      index: 0,
      positionMs: 0,
      playing: false,
      seq: 99,
      sentAt: 900,
      hostId: 'host-b',
    );
    final newHost = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: const <Track>[],
      index: 0,
      positionMs: 0,
      playing: false,
      seq: 1,
      sentAt: 1100,
      hostId: 'host-b',
    );

    expect(RoomService.isRemoteStateNewer(first, null), isTrue);
    expect(RoomService.isRemoteStateNewer(replay, first), isFalse);
    expect(RoomService.isRemoteStateNewer(newer, first), isTrue);
    expect(RoomService.isRemoteStateNewer(lateOldHost, newer), isFalse);
    expect(RoomService.isRemoteStateNewer(newHost, newer), isTrue);
  });

  test('host epoch, eski hostun geciken state paketini engeller', () {
    final oldEpoch = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: const <Track>[],
      index: 0,
      positionMs: 0,
      playing: false,
      seq: 999,
      sentAt: 999999,
      hostId: 'dead-host',
      epoch: 1,
    );
    final newEpoch = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: const <Track>[],
      index: 0,
      positionMs: 0,
      playing: false,
      seq: 1,
      sentAt: 1000,
      hostId: 'live-host',
      epoch: 2,
    );
    expect(RoomService.isRemoteStateNewer(oldEpoch, newEpoch), isFalse);
    expect(RoomService.isRemoteStateNewer(newEpoch, oldEpoch), isTrue);
  });

  test('aynı zaman ve sıradaki state tekrarı "yeni" sayılmaz', () {
    final state = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: const <Track>[],
      index: 0,
      positionMs: 0,
      playing: false,
      seq: 7,
      sentAt: 2000,
      hostId: 'host-a',
      epoch: 3,
    );
    final replay = Map<String, dynamic>.from(state);
    expect(RoomService.isRemoteStateNewer(replay, state), isFalse);
  });

  test('kalp atışı sırayı göndermez, queueRev/epoch taşır', () {
    final track = Track(id: 'a', title: 'A', artist: 'X');
    final tick = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: <Track>[track],
      index: 0,
      positionMs: 3000,
      playing: true,
      queueRev: 5,
      epoch: 2,
      includeQueue: false,
    );
    expect(tick['queue'], isNull);
    expect(tick['queueRev'], 5);
    expect(tick['epoch'], 2);
    // Eski istemciler queue null görünce mevcut listesini korur.
    final full = RoomService.buildStatePayload(
      roomName: 'Test',
      tracks: <Track>[track],
      index: 0,
      positionMs: 3000,
      playing: true,
      queueRev: 5,
    );
    expect((full['queue'] as List).length, 1);
  });

  test('clockOffset gidiş-dönüş gecikmesini telafi eder', () {
    // t0=1000 gönderildi, t1=1100 host'e vardı, t2=1100 cevap, t3=1200 yerel.
    // Ortalama gecikme 100 ms; host saati yerelden 0 ms ileride.
    expect(
      RoomService.clockOffset(t0: 1000, t1: 1100, t2: 1100, t3: 1200),
      0,
    );
    // Host saati 500 ms ilerideyse offset +500 çıkar.
    expect(
      RoomService.clockOffset(t0: 1000, t1: 1600, t2: 1600, t3: 1200),
      500,
    );
  });

  test('syncTargetMs konumu saate ve ağ gecikmesine göre taşır', () {
    final target = RoomService.syncTargetMs(
      positionMs: 10000,
      sentAt: 1000,
      nowMs: 2500,
      offsetMs: 0,
      playing: true,
    );
    expect(target, 11500);

    final paused = RoomService.syncTargetMs(
      positionMs: 10000,
      sentAt: 1000,
      nowMs: 2500,
      playing: false,
    );
    expect(paused, 10000);

    // Bozuk saat farkı varsa ham konum kullanılır.
    final bogus = RoomService.syncTargetMs(
      positionMs: 10000,
      sentAt: 1000,
      nowMs: 2500,
      offsetMs: 120000,
      playing: true,
    );
    expect(bogus, 10000);
  });

  test('komut zarfı benzersiz kimlik ve eylem taşır', () {
    final command = RoomService.buildCommand(
      id: 'client_123',
      action: 'play',
      payload: const <String, dynamic>{'from': 'ui'},
    );
    expect(command['id'], 'client_123');
    expect(command['action'], 'play');
    expect(command['from'], 'ui');
    expect(command['at'], isA<int>());
    expect(
      RoomService.commandId('client'),
      isNot(RoomService.commandId('client')),
    );
  });
}
