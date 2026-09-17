
import 'dart:async';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/search_content.dart';
import '../models/song.dart';

// ─── İstisna sınıfı ───
class StreamUnavailableException implements Exception {
  final String message;
  StreamUnavailableException(this.message);
  @override
  String toString() => "StreamUnavailableException: $message";
}

/// YouTube tabanlı müzik arama ve akış çözümleme servisi.
/// (Açık kaynak youtube_explode_dart kullanır.)
class MusicService {
  MusicService._();
  static final MusicService instance = MusicService._();

  static const Duration _timeout = Duration(seconds: 30);

  final YoutubeExplode _yt = YoutubeExplode();

  /// Geleceği zaman aşımlı sarmalar; ağ asılması sonsuz dönmez.
  Future<T> _bounded<T>(Future<T> Function() task) {
    return task().timeout(_timeout, onTimeout: () {
      throw TimeoutException('İstek zaman aşımına uğradı');
    });
  }

  // ─── Arama ───

  /// Serbest metin araması. Sonuçlar şarkı listesine dönüştürülür.
  /// Hatalı tek sonuç listedeki diğer şarkıları etkilemez (parçalı yükleme yok).
  Future<List<Song>> search(String query, {int limit = 25}) async {
    final results = await _bounded(() => _yt.search.search(query));
    final songs = <Song>[];
    for (final v in results) {
      if (v.isLive) continue;
      try {
        songs.add(_videoToSong(v));
      } catch (_) {}
      if (songs.length >= limit) break;
    }
    return songs;
  }

  /// Videoyu Song'a dönüştürür.
  Song _videoToSong(Video v) => Song(
        id: v.id.value,
        title: v.title,
        artist: v.author,
        thumbnailUrl: v.thumbnails.highResUrl,
        durationMs: v.duration?.inMilliseconds ?? 0,
      );

  // ─── Akış URL'leri ───

  /// Manifest'i çözer, ses akışlarını en iyiden en kötüye sıralar.
  Future<List<AudioOnlyStreamInfo>> _audioStreams(String videoId) async {
    final manifest = await _bounded(() => _yt.videos.streams.getManifest(videoId));
    final audio = manifest.audioOnly.toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return audio;
  }

  /// En iyi ses akış URL'sini çözer.
  Future<String> resolveStreamUrl(String videoId) async {
    final audio = await _audioStreams(videoId);
    if (audio.isEmpty) {
      throw StreamUnavailableException('Ses akışı bulunamadı');
    }
    return _preferred(audio).url.toString();
  }

  /// Oynatma/indirme için denenebilir akış URL adayları (en iyi önce).
  /// just_audio veya HttpClient biriyle çalışmazsa sıradakini dene.
  Future<List<String>> streamUrlCandidates(String videoId) async {
    final audio = await _audioStreams(videoId);
    if (audio.isEmpty) return const [];
    final urls = <String>[];
    void add(String u) {
      if (u.isNotEmpty && !urls.contains(u)) urls.add(u);
    }

    // Tercih: mp4 konteynerli en iyi ses → en iyi ses → son (düşük bitrate)
    add(_preferred(audio).url.toString());
    final anyMp4 = audio.where((s) => s.container.name == 'mp4');
    if (anyMp4.isNotEmpty) add(anyMp4.first.url.toString());
    for (final s in audio) {
      add(s.url.toString());
    }
    return urls;
  }

  AudioOnlyStreamInfo _preferred(List<AudioOnlyStreamInfo> audio) {
    return audio.firstWhere((s) => s.container.name == 'mp4',
        orElse: () => audio.first);
  }

  /// Belirtilen kalitede ses akış URL'sini çözer (YouTube Music benzeri).
  Future<String> resolveStreamUrlWithQuality(String videoId,
      {String quality = 'auto'}) async {
    // Cache'i kontrol et
    final cached = _streamUrlCache[videoId];
    if (cached != null) return cached;

    final audio = await _audioStreams(videoId);
    if (audio.isEmpty) {
      throw StreamUnavailableException('Ses akışı bulunamadı');
    }

    String result;
    switch (quality) {
      case 'high': // en yüksek bit hızı
        result = audio.first.url.toString();
      case 'medium': // orta ~128kbps
        final mid = audio.firstWhere(
          (s) =>
              s.bitrate.bitsPerSecond <= 160 * 1000 &&
              s.bitrate.bitsPerSecond >= 96 * 1000,
          orElse: () =>
              audio.length > 1 ? audio[audio.length ~/ 2] : audio.first,
        );
        result = mid.url.toString();
      case 'low': // ~48kbps
        final low = audio.firstWhere(
          (s) => s.bitrate.bitsPerSecond <= 64 * 1000,
          orElse: () => audio.last,
        );
        result = low.url.toString();
      default:
        final pick = audio.firstWhere(
          (s) => s.container.name == 'mp4',
          orElse: () => audio.first,
        );
        result = pick.url.toString();
    }

    _streamUrlCache[videoId] = result;
    return result;
  }

  // ─── Radyo ───

  /// Şarkı radyosu: mevcut şarkıya benzer şarkılar bulur (YouTube Music tarzı).
  Future<List<Song>> radioFor(Song song) async {
    final results = await _bounded(
        () => _yt.search.search('${song.title} ${song.artist} benzerleri'));
    final songs = <Song>[];
    for (final v in results) {
      if (v.isLive || v.id.value == song.id) continue;
      try {
        songs.add(_videoToSong(v));
      } catch (_) {}
      if (songs.length >= 20) break;
    }
    return songs;
  }

  /// Sanatçı diskografisini getirir (YouTube Music benzeri).
  /// Ana sorgu boş dönerse yalnızca sanatçı adıyla yeniden dener.
  Future<List<Song>> artistSongs(String artist, {int limit = 30}) async {
    for (final query in ['$artist şarkıları', '$artist hit şarkılar', artist]) {
      final results = await _bounded(() => _yt.search.search(query));
      final songs = <Song>[];
      for (final v in results) {
        if (v.isLive) continue;
        try {
          songs.add(_videoToSong(v));
        } catch (_) {}
        if (songs.length >= limit) break;
      }
      if (songs.isNotEmpty) return songs;
    }
    return const [];
  }

  // ─── Sanatçı ve çalma listesi araması ───

  /// Sanatçı (kanal) araması yapar.
  Future<List<SearchArtist>> searchArtists(String query, {int limit = 15}) async {
    try {
      final results =
          await _bounded(() => _yt.search.search(query, filter: TypeFilters.channel));
      return results.whereType<SearchChannel>().take(limit).map((ch) {
        return SearchArtist(
          id: ch.id.value,
          name: ch.name,
          thumbnailUrl: ch.thumbnails.isNotEmpty
              ? ch.thumbnails.first.url.toString()
              : '',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Çalma listesi araması yapar.
  Future<List<PlaylistInfo>> searchPlaylists(
      String query, {int limit = 15}) async {
    try {
      final results =
          await _bounded(() => _yt.search.search(query, filter: TypeFilters.playlist));
      return results.whereType<SearchPlaylist>().take(limit).map((pl) {
        return PlaylistInfo(
          id: pl.id.value,
          title: pl.title,
          videoCount: pl.videoCount,
          thumbnailUrl: pl.thumbnails.isNotEmpty
              ? pl.thumbnails.first.url.toString()
              : '',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Çalma listesi ID'sindeki şarkıları çözer.
  Future<List<Song>> playlistSongs(String playlistId,
      {int limit = 200}) async {
    return _bounded(() async {
      final songs = <Song>[];
      await for (final video in _yt.playlists.getVideos(playlistId)) {
        if (video.isLive) continue;
        try {
          songs.add(_videoToSong(video));
        } catch (_) {}
        if (songs.length >= limit) break;
      }
      return songs;
    });
  }

  /// YouTube / YouTube Music çalma listesi URL'sinden şarkıları çözer.
  /// Desteklenen formatlar:
  ///   https://www.youtube.com/playlist?list=PLxxxx
  ///   https://music.youtube.com/playlist?list=PLxxxx
  ///   https://youtube.com/watch?v=...&list=PLxxxx (karma listeler)
  Future<List<Song>> importPlaylistUrl(String url) async {
    final listMatch = RegExp(r'[?&]list=([\w-]+)').firstMatch(url);
    var id = listMatch?.group(1);
    if (id == 'RDAM' || id == null || id.isEmpty) {
      throw const FormatException('Geçerli bir çalma listesi bağlantısı değil');
    }
    return playlistSongs(id);
  }

  // ─── Söz ───

  /// Şarkı sözlerini indirir. Önce YouTube altyazılarını (söz) dener,
  /// bulunamazsa çeşitli söz kaynaklarından metin tabanlı veri çeker.
  Future<String> fetchLyrics(Song song) async {
    // 1) YouTube altyazısı (senkron söz)
    try {
      final captions =
          await _bounded(() => _yt.videos.closedCaptions.getManifest(song.id));
      if (captions.tracks.isNotEmpty) {
        final track = captions.tracks.firstWhere(
          (t) => t.language.code == 'tr' || t.language.code == 'en',
          orElse: () => captions.tracks.first,
        );
        final info = await _bounded(() => _yt.videos.closedCaptions.get(track));
        final lines = info.captions
            .map((c) => c.text.replaceAll('\n', ' ').trim())
            .where((t) => t.isNotEmpty)
            .toList();
        return lines.join(' ');
      }
    } catch (_) {}

    return '';
  }

  // ─── Önbellek ───

  final Map<String, String> _streamUrlCache = {};
}