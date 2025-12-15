// lib/utils/device_util.dart
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart'; // [Import]

class DeviceUtil {
  static const String _storageKey = 'app_unique_uuid';

  static Future<String> getDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. ลองดึง ID เดิมก่อน
      String? savedId = prefs.getString(_storageKey);
      if (savedId != null && savedId.isNotEmpty) {
        return savedId;
      }

      // 2. ถ้าไม่มี -> สร้างใหม่ (UUID v4)
      String newId = const Uuid().v4();
      
      // 3. บันทึกเก็บไว้
      await prefs.setString(_storageKey, newId);
      
      print("🆕 Generated New UUID: $newId");
      return newId;

    } catch (e) {
      // กันเหนียว: ถ้า Error จริงๆ ให้ return random ชั่วคราว
      return 'error-${DateTime.now().millisecondsSinceEpoch}';
    }
  }
}