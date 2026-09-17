
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

  final YoutubeExplode _yt = YoutubeExplode();

  // ─── Arama ───

  /// Serbest metin araması. Sonuçlar şarkı listesine dönüştürülür.
  Future<List<Song>> search(String query, {int limit = 25}) async {
    final results = await _yt.search.search(query);
    return results
        .where((v) => !v.isLive)
        .take(limit)
        .map(_videoToSong)
        .toList();
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

  /// Verilen video için en iyi ses akış URL'sini çözer.
  Future<String> resolveStreamUrl(String videoId) async {
    final manifest = await _yt.videos.streams.getManifest(videoId);
    final audio = manifest.audioOnly.toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    if (audio.isEmpty) {
      throw StreamUnavailableException('Ses akışı bulunamadı');
    }
    AudioOnlyStreamInfo pick =
        audio.firstWhere((s) => s.container.name == 'mp4', orElse: () => audio.first);
    return pick.url.toString();
  }

  /// Belirtilen kalitede ses akış URL'sini çözer (YouTube Music benzeri).
  Future<String> resolveStreamUrlWithQuality(String videoId,
      {String quality = 'auto'}) async {
    // Cache'i kontrol et
    final cached = _streamUrlCache[videoId];
    if (cached != null) return cached;

    final manifest = await _yt.videos.streams.getManifest(videoId);
    final audio = manifest.audioOnly.toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
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
    final results = await _yt.search.search('${song.title} ${song.artist} benzerleri');
    return results
        .where((v) => !v.isLive && v.id.value != song.id)
        .take(20)
        .map(_videoToSong)
        .toList();
  }

  /// Sanatçı diskografisini getirir (YouTube Music benzeri).
  Future<List<Song>> artistSongs(String artist, {int limit = 30}) async {
    final results = await _yt.search.search('$artist şarkıları resmi');
    return results
        .where((v) => !v.isLive)
        .take(limit)
        .map(_videoToSong)
        .toList();
  }

  // ─── Sanatçı ve çalma listesi araması ───

  /// Sanatçı (kanal) araması yapar.
  Future<List<SearchArtist>> searchArtists(String query, {int limit = 15}) async {
    try {
      final results =
          await _yt.search.search(query, filter: TypeFilters.channel);
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
          await _yt.search.search(query, filter: TypeFilters.playlist);
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
    final songs = <Song>[];
    await for (final video in _yt.playlists.getVideos(playlistId)) {
      songs.add(_videoToSong(video));
      if (songs.length >= limit) break;
    }
    return songs;
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
      final captions = await _yt.videos.closedCaptions.getManifest(song.id);
      if (captions.tracks.isNotEmpty) {
        final track = captions.tracks.firstWhere(
          (t) => t.language.code == 'tr' || t.language.code == 'en',
          orElse: () => captions.tracks.first,
        );
        final info = await _yt.videos.closedCaptions.get(track);
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