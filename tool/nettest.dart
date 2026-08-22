import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main() async {
  try {
    final r = await http
        .get(Uri.parse('https://www.youtube.com/'))
        .timeout(const Duration(seconds: 15));
    print('1) HTTPS temel baglanti: ${r.statusCode}');
  } catch (e) {
    print('1) HTTPS TEMEL HATA: $e');
  }

  try {
    final r = await http
        .get(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
          ),
        )
        .timeout(const Duration(seconds: 15));
    print('2) InnerTube API erisimi: ${r.statusCode}');
  } catch (e) {
    print('2) INNERTUBE HATA: $e');
  }

  try {
    final yt = YoutubeExplode();
    final res = await yt.search
        .search('eminem')
        .timeout(const Duration(seconds: 20));
    // ignore: avoid_print
    print('3) YT SEARCH (uygulamanin yontemi): ${res.length} sonuc');
    yt.close();
  } catch (e) {
    print('3) YT SEARCH HATA: $e');
  }
}
