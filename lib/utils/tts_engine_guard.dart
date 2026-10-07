import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'tts_voice_picker.dart';

/// ดูแลให้ TTS กลับมาพูดได้เอง เมื่อ engine ของ Android หลุดไประหว่างปิดจอนาน ๆ
///
/// ปัญหาเดิม: แอปนี้เป็นหน้า Home ไม่เคยถูกปิด พอปิดจอข้ามคืน Android จะตัดการเชื่อมต่อ
/// กับ TTS engine (Doze / engine ถูกอัปเดต / ถูกเคลียร์หน่วยความจำ)
/// ปลั๊กอิน flutter_tts พยายามเช็คการเชื่อมต่อด้วย reflection ซึ่ง Android รุ่นใหม่บล็อกไว้
/// จึงไม่รู้ว่าหลุด → คำสั่งพูดถูกพักรอไว้ตลอดไป เสียงเงียบจนกว่าจะบังคับหยุดแอป
///
/// วิธีแก้: (1) ต่อ engine ใหม่เองเมื่อกลับมาจากการปิดจอนาน ๆ
///          (2) ถ้าสั่งพูดแล้วค้างเกินเวลา ให้ต่อ engine ใหม่แล้วพูดซ้ำ 1 ครั้ง
class TtsEngineGuard {
  static const _idleBeforeReset = Duration(minutes: 2);
  static const _fallbackEngine = 'com.google.android.tts';

  static DateTime? _pausedAt;
  static bool _needsReset = false;
  static bool _resetting = false;

  /// เพิ่มขึ้นทุกครั้งที่แอปสั่งหยุดเสียงเอง ใช้แยก "ถูกขัดจังหวะโดยตั้งใจ"
  /// ออกจาก "engine ค้าง" (ทั้งสองกรณีปลั๊กอินคืนค่า 0 เหมือนกัน)
  static int _stopGeneration = 0;

  /// เรียกจากทุกที่ที่รับ lifecycle ได้ (เรียกซ้ำได้ ไม่มีผลเพิ่ม)
  static void onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _pausedAt;
      if (since != null && DateTime.now().difference(since) > _idleBeforeReset) {
        _needsReset = true;
      }
      _pausedAt = null;
    }
  }

  /// คืน true ครั้งเดียวหลังกลับมาจากการปิดจอนาน แล้วเคลียร์ธง
  static bool consumeNeedsReset() {
    final v = _needsReset;
    _needsReset = false;
    return v;
  }

  /// หยุดเสียงโดยตั้งใจ (ต้องใช้ตัวนี้แทน tts.stop() เพื่อไม่ให้ระบบพูดซ้ำ)
  static Future<void> stop(FlutterTts tts) async {
    _stopGeneration++;
    try {
      await tts.stop();
    } catch (_) {}
  }

  /// ต่อ TTS engine ใหม่ในแอปเดิม (เทียบเท่าการบังคับหยุดแอปแล้วเปิดใหม่ เฉพาะส่วนเสียง)
  static Future<bool> reset(FlutterTts tts) async {
    if (_resetting) return false;
    _resetting = true;
    try {
      String engine = _fallbackEngine;
      try {
        final e = await tts.getDefaultEngine.timeout(const Duration(seconds: 3));
        if (e is String && e.isNotEmpty) engine = e;
      } catch (_) {}

      await tts.setEngine(engine).timeout(const Duration(seconds: 8));
      TtsVoicePicker.clearCache();
      debugPrint('🔊 TTS engine reconnected ($engine)');
      return true;
    } catch (e) {
      debugPrint('🔇 TTS engine reset failed: $e');
      return false;
    } finally {
      _resetting = false;
    }
  }

  /// เวลาสูงสุดที่ยอมให้ประโยคหนึ่งพูดจบ (เผื่อไว้มาก เพื่อไม่ตัดประโยคยาว)
  static Duration _maxSpeakTime(String text, double rate) {
    final r = rate.clamp(0.1, 1.0);
    final seconds = 10 + (text.length * 0.25 / r).ceil();
    return Duration(seconds: seconds.clamp(10, 120));
  }

  /// พูดแบบมีตัวกันค้าง
  ///
  /// [prepare] จะถูกเรียกก่อนพูดทุกครั้ง (ตั้งภาษา/ความเร็ว/เสียง) เพราะหลังต่อ engine ใหม่
  /// ค่าพวกนี้จะหายไป ต้องตั้งซ้ำ
  ///
  /// คืน false ถ้าถูกสั่งหยุดกลางคัน (ผู้เรียกควรเลิกพูดประโยคถัดไป)
  static Future<bool> speak(
    FlutterTts tts,
    String text, {
    required Future<void> Function() prepare,
    double rate = 0.5,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final generation = _stopGeneration;
      await prepare();

      dynamic result;
      try {
        result = await tts.speak(text).timeout(_maxSpeakTime(text, rate));
      } on TimeoutException {
        // คำสั่งพูดค้าง = engine หลุด → ต่อใหม่แล้วลองอีกครั้ง
        if (generation != _stopGeneration) return false;
        debugPrint('⏱️ TTS speak timed out, reconnecting engine…');
        try {
          await tts.stop();
        } catch (_) {}
        await reset(tts);
        continue;
      } catch (e) {
        debugPrint('🔇 TTS speak error: $e');
        if (generation != _stopGeneration) return false;
        await reset(tts);
        continue;
      }

      if (result == 1) return true;

      // ได้ 0: ถ้าแอปสั่งหยุดเอง = ตั้งใจขัด ไม่ต้องพูดซ้ำ
      if (generation != _stopGeneration) return false;

      // ได้ 0 โดยไม่มีใครสั่งหยุด = สถานะ "กำลังพูด" ของปลั๊กอินค้าง → เคลียร์แล้วลองใหม่
      try {
        await tts.stop();
      } catch (_) {}
    }
    return true;
  }
}
