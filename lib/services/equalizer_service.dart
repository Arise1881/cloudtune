import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum EqPreset { flat, pop, rock, jazz, classical, bassBoost, vocal }

/// 5 bantlı (60Hz, 230Hz, 910Hz, 3.6kHz, 14kHz) basitleştirilmiş
/// ekolayzer. just_audio'nun volume kontrolüyle bantlara ayrılmış
/// ses şiddeti ayarı yapar; gerçek EQ Android Equalizer effect'i
/// cihaza göre değişkenlik gösterdiği için basit ama etkili bir
/// yaklaşım kullanılır.
class EqualizerService extends ChangeNotifier {
  EqualizerService._();
  static final EqualizerService instance = EqualizerService._();

  // Bant değerleri: -12.0 … +12.0 dB aralığında (Flutter slider -12..12)
  static const List<double> bandFrequencies = [60, 230, 910, 3600, 14000];
  static const int bandCount = 5;
  static const double minDb = -12;
  static const double maxDb = 12;

  List<double> _bands = List.filled(bandCount, 0.0);
  EqPreset _preset = EqPreset.flat;
  bool _enabled = true;

  List<double> get bands => List.unmodifiable(_bands);
  EqPreset get preset => _preset;
  bool get enabled => _enabled;

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _enabled = _prefs?.getBool('eq_enabled') ?? true;
    final savedBands = _prefs?.getStringList('eq_bands');
    if (savedBands != null && savedBands.length == bandCount) {
      _bands = savedBands.map(double.parse).toList();
    }
    final presetIdx = _prefs?.getInt('eq_preset') ?? 0;
    _preset = EqPreset.values[presetIdx.clamp(0, EqPreset.values.length - 1)];
    notifyListeners();
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setStringList(
        'eq_bands', _bands.map((b) => b.toStringAsFixed(1)).toList());
    await _prefs?.setInt('eq_preset', _preset.index);
    await _prefs?.setBool('eq_enabled', _enabled);
  }

  /// EQ uygulanmış ses seviyesi çarpanını döndürür (0.3..1.0).
  /// PlayerService bu değeri oynatıcı volume'una uygular.
  double volumeMultiplier() {
    if (!_enabled) return 1.0;
    final avgDb = _bands.reduce((a, b) => a + b) / bandCount;
    // -12..+12 dB aralığını 0.65..1.0 volume aralığına çevir
    return (0.65 + (avgDb / maxDb) * 0.35).clamp(0.3, 1.0);
  }

  void setBand(int index, double value) {
    if (index < 0 || index >= bandCount) return;
    _bands[index] = value.clamp(minDb, maxDb);
    _preset = EqPreset.flat; // özel ayar → flat olur
    _save();
    notifyListeners();
  }

  void setPreset(EqPreset p) {
    _preset = p;
    _bands = _presetBands(p);
    _save();
    notifyListeners();
  }

  void toggleEnabled() {
    _enabled = !_enabled;
    _save();
    notifyListeners();
  }

  String presetLabel() => _presetLabel(_preset);

  String presetLabelFor(EqPreset p) => _presetLabel(p);

  static String _presetLabel(EqPreset p) => switch (p) {
        EqPreset.flat => 'Düz',
        EqPreset.pop => 'Pop',
        EqPreset.rock => 'Rock',
        EqPreset.jazz => 'Jazz',
        EqPreset.classical => 'Klasik',
        EqPreset.bassBoost => 'Bas Güçlendirme',
        EqPreset.vocal => 'Vokal',
      };

  static List<double> _presetBands(EqPreset p) => switch (p) {
        EqPreset.flat => [0, 0, 0, 0, 0],
        EqPreset.pop => [2, 5, 6, 4, 1],
        EqPreset.rock => [6, 3, -2, 4, 6],
        EqPreset.jazz => [4, 2, -2, 2, 5],
        EqPreset.classical => [5, 3, 0, 2, 4],
        EqPreset.bassBoost => [10, 7, 2, 0, -2],
        EqPreset.vocal => [-2, 0, 5, 4, 1],
      };
}
