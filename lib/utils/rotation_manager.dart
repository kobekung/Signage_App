// lib/utils/rotation_manager.dart
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// จัดการการหมุนจอ (สำหรับป้ายที่ต้องการติดตั้งแนวตั้ง)
///
/// เก็บค่าไว้ใน local storage (SharedPreferences) key = 'screen_rotation'
/// เป็นจำนวน quarter turns: 0 = ปกติ (แนวนอน), 1 = 90°, 2 = 180°, 3 = 270°
class RotationManager {
  static const String _prefsKey = 'screen_rotation';

  /// ค่าปัจจุบัน (quarter turns) - ฟัง notifier นี้เพื่อ rebuild UI
  static final ValueNotifier<int> quarterTurns = ValueNotifier<int>(0);

  /// โหลดค่าที่บันทึกไว้ตอนเปิดแอป
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_prefsKey) ?? 0;
    quarterTurns.value = value % 4;
  }

  /// ตั้งค่าการหมุนใหม่ แล้วบันทึกลง local storage
  static Future<void> set(int turns) async {
    final normalized = turns % 4;
    quarterTurns.value = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey, normalized);
  }

  /// ป้ายกำกับสำหรับแสดงในเมนู
  static String labelFor(int turns) {
    switch (turns % 4) {
      case 1:
        return 'แนวตั้ง (หมุน 90°)';
      case 2:
        return 'แนวนอน กลับหัว (180°)';
      case 3:
        return 'แนวตั้ง (หมุน 270°)';
      default:
        return 'แนวนอน ปกติ (0°)';
    }
  }
}
