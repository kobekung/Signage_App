import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tts_lang_config.dart';

// ยกมาจาก driver_system — ภาษา TTS ที่เปิดใช้ เก็บแยกต่อเครื่อง
const _kKey = 'tts_languages';

Future<List<TtsLangConfig>> loadTtsLanguages() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kKey);
  if (raw == null) return List.from(defaultTtsLanguages);
  try {
    final list = jsonDecode(raw) as List;
    final stored = list.map((e) => TtsLangConfig.fromJson(e as Map<String, dynamic>)).toList();
    // merge ภาษา default ที่ยังไม่มีใน stored (เพิ่มต่อท้าย, disabled)
    final storedCodes = stored.map((e) => e.code).toSet();
    for (final def in defaultTtsLanguages) {
      if (!storedCodes.contains(def.code)) {
        stored.add(def);
      }
    }
    return stored;
  } catch (_) {
    return List.from(defaultTtsLanguages);
  }
}

Future<void> saveTtsLanguages(List<TtsLangConfig> langs) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kKey, jsonEncode(langs.map((e) => e.toJson()).toList()));
}
