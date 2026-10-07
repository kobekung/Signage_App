import 'package:flutter_tts/flutter_tts.dart';

/// เลือก "เสียง" ของ TTS ตามภาษา + เพศที่ตั้งค่าไว้
///
/// Android ตั้งชื่อ voice แบบ `th-th-x-ptd#male_1-local` / `en-us-x-tpf#female_2-local`
/// จึงใช้วิธีดูคำว่า male/female ในชื่อ voice ของ locale นั้น
/// ถ้าเครื่องไม่มีเสียงเพศที่ขอ จะไม่เปลี่ยนอะไร (ใช้เสียงมาตรฐานของภาษานั้น)
class TtsVoicePicker {
  static List<Map<String, String>>? _cache;

  /// โหลดรายชื่อ voice จากเครื่องครั้งเดียวแล้วเก็บไว้
  static Future<List<Map<String, String>>> _voices(FlutterTts tts) async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final raw = await tts.getVoices;
      final list = <Map<String, String>>[];
      if (raw is List) {
        for (final v in raw) {
          if (v is Map) {
            final name = v['name']?.toString();
            final locale = v['locale']?.toString();
            if (name != null && locale != null) {
              list.add({'name': name, 'locale': locale});
            }
          }
        }
      }
      _cache = list;
      return list;
    } catch (_) {
      _cache = const [];
      return const [];
    }
  }

  /// ล้าง cache (เผื่อผู้ใช้ติดตั้งเสียงเพิ่มในเครื่อง)
  static void clearCache() => _cache = null;

  /// คืน true ถ้าตั้ง voice ตามเพศได้สำเร็จ
  static Future<bool> applyGender(
    FlutterTts tts, {
    required String localeCode,
    required String gender,
  }) async {
    if (gender != 'male' && gender != 'female') return false;

    final voices = await _voices(tts);
    if (voices.isEmpty) return false;

    final wantedLocale = localeCode.toLowerCase();
    final wantedPrefix = wantedLocale.split('-').first;

    // ตรง locale เป๊ะก่อน ถ้าไม่มีค่อยใช้ภาษาเดียวกันแต่คนละประเทศ
    final exact = voices.where((v) => v['locale']!.toLowerCase() == wantedLocale);
    final sameLang = voices.where(
        (v) => v['locale']!.toLowerCase().split('-').first == wantedPrefix);
    final candidates = exact.isNotEmpty ? exact : sameLang;
    if (candidates.isEmpty) return false;

    // ชื่อ voice ของ Android มักมี '#male_1' / '#female_2' อยู่ในนั้น
    final match = candidates.where(
      (v) => v['name']!.toLowerCase().contains(gender),
    );
    if (match.isEmpty) return false;

    try {
      final v = match.first;
      await tts.setVoice({'name': v['name']!, 'locale': v['locale']!});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// เพศของเสียงที่เครื่องนี้มีจริงสำหรับภาษาหนึ่ง (ใช้บอกผู้ใช้ในหน้าตั้งค่า)
  static Future<Set<String>> availableGenders(
    FlutterTts tts,
    String localeCode,
  ) async {
    final voices = await _voices(tts);
    final wantedPrefix = localeCode.toLowerCase().split('-').first;
    final result = <String>{};
    for (final v in voices) {
      if (v['locale']!.toLowerCase().split('-').first != wantedPrefix) continue;
      final name = v['name']!.toLowerCase();
      if (name.contains('female')) {
        result.add('female');
      } else if (name.contains('male')) {
        result.add('male');
      }
    }
    return result;
  }
}
