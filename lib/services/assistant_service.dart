import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'download_manager.dart';
import 'music_service.dart';
import 'player_service.dart';
import 'library_store.dart';

/// Sesli asistan servisi: konuşma tanıma + metin-okuma + komut işleme.
class AssistantService extends ChangeNotifier {
  AssistantService._();
  static final AssistantService instance = AssistantService._();

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isListening = false;
  bool get isListening => _isListening;

  bool _isSpeaking = false;
  bool get isSpeaking => _isSpeaking;

  String _lastResult = '';
  String get lastResult => _lastResult;

  StreamSubscription? _speechSub;

  // Sesli sohbet modu
  bool _conversationMode = false;
  bool get conversationMode => _conversationMode;
  
  String _conversationContext = '';
  Timer? _conversationTimer;

  /// Asistanı başlatır (konuşma tanıma ve TTS ayarları).
  Future<void> init() async {
    await _speech.initialize(onStatus: _onSpeechStatus, onError: _onSpeechError);
    await _configureTts();
  }

  Future<void> _configureTts() async {
    await _tts.setLanguage('tr-TR');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _tts.setStartHandler(() {
      _isSpeaking = true;
      notifyListeners();
    });
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      notifyListeners();
    });
    _tts.setErrorHandler((msg) {
      _isSpeaking = false;
      notifyListeners();
      debugPrint('TTS error: $msg');
    });
  }

  void _onSpeechStatus(String status) {
    if (status == 'done' || status == 'notListening') {
      _isListening = false;
      notifyListeners();
    }
  }

  void _onSpeechError(dynamic error) {
    _isListening = false;
    debugPrint('Speech error: $error');
    notifyListeners();
  }

  /// Dinlemeye başlar, sonuç callback ile döner.
  Future<void> startListening({Function(String)? onResult}) async {
    if (_isListening) return;
    _isListening = true;
    notifyListeners();

    _speechSub?.cancel();
    final listenOptions = SpeechListenOptions(
      localeId: 'tr_TR',
      listenMode: ListenMode.confirmation,
    );
    await _speech.listen(
      onResult: (result) {
        _lastResult = result.recognizedWords;
        notifyListeners();
        if (result.finalResult) {
          _processCommand(_lastResult);
          onResult?.call(_lastResult);
        }
      },
      listenOptions: listenOptions,
    ).catchError((e) {
      _isListening = false;
      debugPrint('Listen error: $e');
      notifyListeners();
    });
  }

  /// Dinlemeyi durdurur.
  Future<void> stopListening() async {
    await _speech.stop();
    _isListening = false;
    _conversationMode = false;
    _conversationTimer?.cancel();
    notifyListeners();
  }

  /// Sohbet modunu başlatır - sürekli dinler ve doğal konuşma sağlar.
  Future<void> startConversation() async {
    if (_conversationMode) return;
    _conversationMode = true;
    _conversationContext = '';
    notifyListeners();
    
    await speak('Merhaba! Size nasıl yardımcı olabilirim? Müzik çalar, arar veya kontrol edebilirim.');
    
    // Sürekli dinleme döngüsü
    _startConversationLoop();
  }

  /// Sohbet modunu durdurur.
  Future<void> stopConversation() async {
    _conversationMode = false;
    _conversationTimer?.cancel();
    await stopListening();
    await speak('Görüşürüz! Müzik dinlemeye devam edin.');
    notifyListeners();
  }

  /// Sohbet döngüsünü başlatır - cevap verildikten sonra tekrar dinler.
  Future<void> _startConversationLoop() async {
    if (!_conversationMode) return;
    
    await startListening(onResult: (result) async {
      if (!result.isEmpty) {
        _conversationContext += 'User: $result\n';
        await _processConversationCommand(result);
      }
      
      // Kısa bir süre sonra tekrar dinlemeye başla
      if (_conversationMode) {
        _conversationTimer = Timer(const Duration(seconds: 2), () {
          if (_conversationMode) {
            _startConversationLoop();
          }
        });
      }
    });
  }

  /// Doğal dil komutlarını işler - sohbet bağlamı ile.
  Future<void> _processConversationCommand(String command) async {
    final lower = command.toLowerCase().trim();
    debugPrint('Conversation command: $lower');
    
    // Sohbet bitirme komutları
    if (_containsAny(lower, ['tamam', 'sag ol', 'tesekkur', 'kapat', 'bitir', 'görüşürüz', 'dur'])) {
      await stopConversation();
      return;
    }
    
    // Mevcut komut işleme mantığını kullan
    await _processCommand(lower);
    
    // Sohbet bağlamını güncelle (son 5 komut)
    final lines = _conversationContext.split('\n').where((l) => l.isNotEmpty).toList();
    if (lines.length > 10) {
      _conversationContext = lines.skip(lines.length - 10).join('\n');
    }
  }

  /// Sadece müzikle ilgili sohbet için hızlı yanıt.
  Future<void> quickChat(String message) async {
    await speak(message);
    await Future.delayed(const Duration(milliseconds: 500));
    if (_conversationMode) {
      _startConversationLoop();
    }
  }

  /// Metni seslendirir.
  Future<void> speak(String text) async {
    if (_isSpeaking) await _tts.stop();
    await _tts.speak(text);
  }

  /// Komutu işler ve ilgili aksiyonu tetikler.
  Future<void> _processCommand(String command) async {
    final lower = command.toLowerCase().trim();
    debugPrint('Assistant command: $lower');

    final player = PlayerService.instance;
    final music = MusicService.instance;
    final library = LibraryStore.instance;

    // Basit anahtar kelime eşleşmesi
    if (_containsAny(lower, ['oynat', 'çalsın', 'başlat', 'play'])) {
      if (player.current != null) {
        player.togglePlayPause();
        await speak('Oynatılıyor');
      } else {
        await speak('Çalacak şarkı yok');
      }
    } else if (_containsAny(lower, ['durdur', 'pause', 'beklet'])) {
      player.togglePlayPause();
      await speak('Durduruldu');
    } else if (_containsAny(lower, ['sonraki', 'ileri', 'next', 'geç'])) {
      await player.next();
      await speak('Sonraki şarkı');
    } else if (_containsAny(lower, ['önceki', 'geri', 'previous', 'önceki şarkı'])) {
      await player.previous();
      await speak('Önceki şarkı');
    } else if (_containsAny(lower, ['ses', 'volume', 'yüksek', 'düşük'])) {
      // Ses kontrolü henüz PlayerService'te public değil
      await speak('Ses kontrolü şu anda desteklenmiyor');
    } else if (_containsAny(lower, ['ara', 'bul', 'search', 'find'])) {
      // Arama komutu: "ara [şarkı/sanatçı]"
      final query = lower.replaceAll(RegExp(r'(ara|bul|search|find)\s*'), '').trim();
      if (query.isNotEmpty) {
        await speak('$query aranıyor');
        final results = await music.search(query);
        if (results.isNotEmpty) {
          final song = results.first;
          // Şarkıyı çal
          player.playQueue([song], startIndex: 0);
          await speak('${song.title} çalınıyor');
        } else {
          await speak('Sonuç bulunamadı');
        }
      } else {
        await speak('Ne aramamı istiyorsun?');
      }
    } else if (_containsAny(lower, ['favorilere ekle', 'beğen', 'like'])) {
      if (player.current != null) {
        library.toggleFavorite(player.current!);
        await speak('Favorilere eklendi');
      }
    } else if (_containsAny(lower, ['indir', 'download', 'kaydet'])) {
      if (player.current != null) {
        await DownloadManager.instance.download(player.current!);
        await speak('İndirme başladı');
      }
    } else if (_containsAny(lower, ['ne çalıyor', 'şarkı ne', 'what is playing', 'hangi şarkı'])) {
      if (player.current != null) {
        await speak('Şu an ${player.current!.title}, ${player.current!.artist} çalıyor');
      } else {
        await speak('Henüz bir şarkı çalmıyor');
      }
    } else if (_containsAny(lower, ['karıştır', 'shuffle', 'rastgele'])) {
      player.toggleShuffle();
      await speak(player.shuffle ? 'Karıştırma açıldı' : 'Karıştırma kapatıldı');
    } else if (_containsAny(lower, ['tekrar', 'repeat', 'loop'])) {
      player.cycleRepeat();
      await speak('Tekrar modu ${_repeatLabel(player.repeat)}');
    } else if (_containsAny(lower, ['uyku', 'sleep', 'zamanlayıcı'])) {
      // Basit uyku zamanlayıcısı: 30 dakika
      player.startSleepTimer(const Duration(minutes: 30));
      await speak('Uyku zamanlayıcısı 30 dakika olarak ayarlandı');
    } else {
      await speak('Anlayamadım, tekrar eder misin?');
    }
  }

  String _repeatLabel(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return 'kapalı';
      case RepeatMode.all:
        return 'tümü';
      case RepeatMode.one:
        return 'tekrar';
    }
  }

  bool _containsAny(String text, List<String> keywords) {
    return keywords.any((k) => text.contains(k));
  }

  @override
  void dispose() {
    _speechSub?.cancel();
    _conversationTimer?.cancel();
    _speech.stop();
    _tts.stop();
    super.dispose();
  }
}