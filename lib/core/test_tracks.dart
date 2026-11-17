import 'dart:math';

import 'models.dart';

/// Emülator doğrulama havuzu: 15 bağımsız, doğrudan çalınan parça.
///
/// YouTube bu IP'de robot doğrulaması uyguladığı için test kaynakları
/// SoundHelix üzerinden alınır. Amaç oynatıcıyı, ses çıkışını ve parça
/// geçişlerini gerçek 15 farklı parçada sınamaktır. Normal arama/oynatma
/// akışı YouTube bağlantılarını kullanmaya devam eder.
class TestTracks {
  TestTracks._();

  static const String _base =
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-';

  static const List<Track> tracks = [
    Track(
      id: 'cttest01',
      title: 'SoundHelix Song 1',
      artist: 'SoundHelix',
      sourceUrl: '${_base}1.mp3',
    ),
    Track(
      id: 'cttest02',
      title: 'SoundHelix Song 2',
      artist: 'SoundHelix',
      sourceUrl: '${_base}2.mp3',
    ),
    Track(
      id: 'cttest03',
      title: 'SoundHelix Song 3',
      artist: 'SoundHelix',
      sourceUrl: '${_base}3.mp3',
    ),
    Track(
      id: 'cttest04',
      title: 'SoundHelix Song 4',
      artist: 'SoundHelix',
      sourceUrl: '${_base}4.mp3',
    ),
    Track(
      id: 'cttest05',
      title: 'SoundHelix Song 5',
      artist: 'SoundHelix',
      sourceUrl: '${_base}5.mp3',
    ),
    Track(
      id: 'cttest06',
      title: 'SoundHelix Song 6',
      artist: 'SoundHelix',
      sourceUrl: '${_base}6.mp3',
    ),
    Track(
      id: 'cttest07',
      title: 'SoundHelix Song 7',
      artist: 'SoundHelix',
      sourceUrl: '${_base}7.mp3',
    ),
    Track(
      id: 'cttest08',
      title: 'SoundHelix Song 8',
      artist: 'SoundHelix',
      sourceUrl: '${_base}8.mp3',
    ),
    Track(
      id: 'cttest09',
      title: 'SoundHelix Song 9',
      artist: 'SoundHelix',
      sourceUrl: '${_base}9.mp3',
    ),
    Track(
      id: 'cttest10',
      title: 'SoundHelix Song 10',
      artist: 'SoundHelix',
      sourceUrl: '${_base}10.mp3',
    ),
    Track(
      id: 'cttest11',
      title: 'SoundHelix Song 11',
      artist: 'SoundHelix',
      sourceUrl: '${_base}11.mp3',
    ),
    Track(
      id: 'cttest12',
      title: 'SoundHelix Song 12',
      artist: 'SoundHelix',
      sourceUrl: '${_base}12.mp3',
    ),
    Track(
      id: 'cttest13',
      title: 'SoundHelix Song 13',
      artist: 'SoundHelix',
      sourceUrl: '${_base}13.mp3',
    ),
    Track(
      id: 'cttest14',
      title: 'SoundHelix Song 14',
      artist: 'SoundHelix',
      sourceUrl: '${_base}14.mp3',
    ),
    Track(
      id: 'cttest15',
      title: 'SoundHelix Song 15',
      artist: 'SoundHelix',
      sourceUrl: '${_base}15.mp3',
    ),
  ];

  /// Her çağrıda farklı sıra üretir; liste uzunluğu daima 15'tir.
  static List<Track> shuffled() {
    final list = List<Track>.of(tracks)..shuffle(Random.secure());
    return List<Track>.unmodifiable(list);
  }
}
