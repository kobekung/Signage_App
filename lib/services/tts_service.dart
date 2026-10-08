import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_audio.dart';
import '../models/tts_lang_config.dart';
import '../utils/tts_engine_guard.dart';
import '../utils/tts_lang_store.dart';
import '../utils/tts_voice_picker.dart';

/// เสียงทั้งหมดที่จอ signage เล่นแทนแท็บเล็ตคนขับ (ยก flow มาจาก driver_system/tracking_page)
/// - เสียงประกาศสถานี: mp3 / TTS template / TTS ข้อความจาก BO ตาม audio_mode
/// - เสียง bg: playlist ของ route เล่นวน ปิดเสียงเป็น 0 ระหว่างประกาศ
/// - วิดีโอบนจอลดเสียงตาม [duckStream] ระหว่างประกาศ
class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  static const String _soundHost = 'https://mass-sound.bussing.app';
  static const String _prefsKey = 'tts_enabled';
  static const String _bgVolumeKey = 'bg_volume';

  /// เปิด/ปิดเสียงทั้งหมดออกจอ - ค่าเริ่มต้นปิด (ต้องเข้า Admin Menu เพื่อเปิด)
  /// ฟัง notifier นี้เพื่อ rebuild UI ปุ่มในเมนู
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// ระดับเสียง bg 0.0–1.0 (ตั้งใน Admin Menu)
  static final ValueNotifier<double> bgVolume = ValueNotifier<double>(1.0);

  /// ภาษา TTS ที่ใช้ประกาศ (เปิด/ปิดได้ใน Admin Menu)
  static final ValueNotifier<List<TtsLangConfig>> langs =
      ValueNotifier<List<TtsLangConfig>>(List.from(defaultTtsLanguages));

  /// โหลดค่าที่บันทึกไว้ตอนเปิดแอป
  static Future<void> loadSetting() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsKey) ?? false;
    bgVolume.value = prefs.getDouble(_bgVolumeKey) ?? 1.0;
    langs.value = await loadTtsLanguages();
  }

  /// ตั้งค่าเปิด/ปิด แล้วบันทึกลง local storage
  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
    if (value) {
      await _instance._startBg();
    } else {
      await _instance.stop();
      await _instance._stopBg();
    }
  }

  static Future<void> setBgVolume(double value) async {
    bgVolume.value = value.clamp(0.0, 1.0);
    await _instance._applyBgVolume();
  }

  /// บันทึกตอนปล่อย slider (ไม่เขียน prefs ทุกครั้งที่ลาก)
  static Future<void> saveBgVolume() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_bgVolumeKey, bgVolume.value);
  }

  static Future<void> setLangEnabled(String code, bool on) async {
    langs.value = [
      for (final l in langs.value) l.code == code ? l.copyWith(enabled: on) : l,
    ];
    await saveTtsLanguages(langs.value);
  }

  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  Player? _announcer; // mp3 ประกาศสถานี
  Player? _bg; // playlist เสียง bg
  bool _bgPlaying = false;
  Completer<void>? _mp3Done; // ใช้ตัดการรอ mp3 จบ เมื่อมีประกาศใหม่แทรก

  RouteAudio? _route;
  RouteAudio? get route => _route;
  int? _lastIndex;

  int _generation = 0; // เพิ่มทุกครั้งที่เริ่มประกาศใหม่ ประกาศเก่าที่ค้างอยู่จะเลิกเอง
  int _duckCount = 0; // จำนวนประกาศที่กำลังเล่น (> 0 = ปิด bg + ลดเสียงวิดีโอ)

  bool _isSpeaking = false;
  bool get isSpeaking => _isSpeaking;

  final _duckController = StreamController<bool>.broadcast();
  Stream<bool> get duckStream => _duckController.stream;

  /// เครื่องมี TTS engine ไหม (กล่อง Android บางรุ่นไม่มีเลย → ข้าม TTS ทันที ไม่รอจนหมดเวลา)
  bool _ttsAvailable = true;
  DateTime? _engineCheckedAt;

  Future<void> _checkTtsEngine() async {
    // เช็คซ้ำทุก 5 นาที เผื่อมีการลง engine เพิ่มทีหลัง
    final last = _engineCheckedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 5)) return;
    _engineCheckedAt = DateTime.now();
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final engines = await _tts.getEngines.timeout(const Duration(seconds: 3));
      _ttsAvailable = engines is List && engines.isNotEmpty;
    } catch (_) {
      _ttsAvailable = true; // เช็คไม่ได้ ให้ลองพูดตามปกติ
    }
    if (!_ttsAvailable) debugPrint("🔇 No TTS engine on this device — skipping TTS announcements");
  }

  Future<void> _initTts() async {
    await _checkTtsEngine();
    if (_ttsReady || !_ttsAvailable) return;
    await _tts.setLanguage("th-TH");
    await _tts.setSpeechRate(kDefaultTtsRate);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
    _ttsReady = true;
  }

  // ============================
  // Route / เสียง bg
  // ============================

  /// ตั้ง route ของรอบปัจจุบัน แล้วเริ่มเล่นเสียง bg ตาม playlist
  Future<void> setRoute(RouteAudio? audio) async {
    final sameBg = listEquals(_route?.bgSounds, audio?.bgSounds);
    _route = audio;
    _lastIndex = null;
    if (!sameBg) {
      await _stopBg();
      await _startBg();
    }
  }

  /// รอบจบแล้ว: หยุดเสียง bg
  Future<void> clearRoute() async {
    _route = null;
    _lastIndex = null;
    await _stopBg();
  }

  Future<void> _startBg() async {
    final files = _route?.bgSounds ?? const [];
    if (!enabled.value || files.isEmpty || _bgPlaying) return;
    try {
      final bg = _bg ??= Player();
      _bgPlaying = true;
      await bg.setPlaylistMode(PlaylistMode.loop);
      await bg.setVolume(_duckCount > 0 ? 0 : bgVolume.value * 100);
      await bg.open(
        Playlist([for (final f in files) Media("$_soundHost/sounds/$f")]),
        play: true,
      );
    } catch (e) {
      _bgPlaying = false;
      debugPrint("BG sound play failed: $e");
    }
  }

  Future<void> _stopBg() async {
    _bgPlaying = false;
    try {
      await _bg?.stop();
    } catch (_) {}
  }

  Future<void> _applyBgVolume() async {
    if (_duckCount > 0) return;
    try {
      await _bg?.setVolume(bgVolume.value * 100);
    } catch (_) {}
  }

  // ============================
  // ประกาศสถานี
  // ============================

  /// หาตำแหน่งสถานีใน route จาก id ที่คนขับส่งขึ้น server
  /// route วนกลับอาจมี id ซ้ำ จึงเทียบสถานีก่อน/ถัดไปด้วย
  int? resolveIndex(int nowId, {int? preId, int? nextId}) {
    final stations = _route?.stations ?? const <RouteAudioStation>[];
    final candidates = [
      for (var i = 0; i < stations.length; i++)
        if (stations[i].id == nowId) i,
    ];
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;

    int score(int i) {
      var s = 0;
      // คนขับส่ง pre/next แบบ clamp ไว้ที่หัว/ท้าย route
      final next = i + 1 < stations.length ? stations[i + 1].id : stations[i].id;
      final pre = i > 0 ? stations[i - 1].id : stations[i].id;
      if (nextId != null && next == nextId) s += 2;
      if (preId != null && pre == preId) s += 2;
      if (_lastIndex != null && i > _lastIndex!) s += 1;
      return s;
    }

    var best = candidates.first;
    for (final i in candidates.skip(1)) {
      if (score(i) > score(best)) best = i;
    }
    return best;
  }

  /// ประกาศสถานีตาม index ของ route (0 = ต้นทาง, สุดท้าย = ปลายทาง)
  Future<void> announceIndex(int index) async {
    final route = _route;
    if (!enabled.value || route == null) return;
    if (index < 0 || index >= route.stations.length) return;
    _lastIndex = index;
    // สถานีก่อนจุดคั่น (id 0) ต้องเล่นจนจบ ห้ามสถานีถัดไปตัด (ตรงกับที่แท็บเล็ตคนขับพักรอที่จุดคั่น)
    final beforeBreak =
        index + 1 < route.stations.length && route.stations[index + 1].id == 0;
    await _announce((gen) => _announceStation(route, index, gen), protect: beforeBreak);
  }

  /// ใช้ตอนโหลดข้อมูลเสียงของ route ไม่ได้ — พูดจาก template ด้วยชื่อจาก busround-active
  Future<void> announceByName({
    required String kind, // 'start' | 'end' | 'next'
    required String routeTh,
    required String routeEn,
    required String nameTh,
    required String nameEn,
    String lastTh = '',
    String lastEn = '',
  }) async {
    if (!enabled.value) return;
    await _announce((gen) => _speakTts(gen, (lang) {
          final th = lang.nameField == 'th';
          final routeName = th ? routeTh : routeEn;
          final name = th ? nameTh : nameEn;
          final last = th ? lastTh : lastEn;
          switch (kind) {
            case 'start':
              return lang.buildWelcome(route: routeName, first: name, last: last);
            case 'end':
              return lang.buildThankYou(route: routeName, last: name);
            default:
              return lang.buildNextStop(name: name);
          }
        }));
  }

  /// ประกาศที่ห้ามถูกตัด (สถานีก่อนจุดคั่น) ที่กำลังเล่นอยู่ — ประกาศใหม่ต้องรอจนจบ
  Future<void>? _protected;

  /// เริ่มประกาศใหม่: ตัดของเก่า, ปิด bg + ลดเสียงวิดีโอ ระหว่างเล่น แล้วเปิดกลับเมื่อจบ
  /// [protect] = ประกาศนี้ห้ามถูกประกาศถัดไปตัดกลางคัน
  Future<void> _announce(Future<void> Function(int gen) body, {bool protect = false}) async {
    final pending = _protected;
    if (pending != null) {
      await pending.timeout(const Duration(minutes: 5), onTimeout: () {});
    }
    final gen = ++_generation;
    await stop();
    if (gen != _generation) return;

    final guard = protect ? Completer<void>() : null;
    if (guard != null) _protected = guard.future;

    _duckCount++;
    if (_duckCount == 1) {
      _isSpeaking = true;
      _duckController.add(true);
      try {
        await _bg?.setVolume(0);
      } catch (_) {}
    }
    try {
      await _initTts();
      await body(gen);
    } catch (e) {
      debugPrint("Announcement failed: $e");
    } finally {
      if (guard != null) {
        guard.complete();
        if (identical(_protected, guard.future)) _protected = null;
      }
      _duckCount--;
      if (_duckCount == 0) {
        _isSpeaking = false;
        _duckController.add(false);
        await _applyBgVolume();
      }
    }
  }

  Future<void> _announceStation(RouteAudio route, int index, int gen) async {
    final stations = route.stations;
    final station = stations[index];
    final first = stations.first;
    final last = stations.last;

    if (index == 0) {
      if (route.modeStart == 'mp3') {
        if (route.mp3Start.isNotEmpty) {
          await _playUrlAndWait("$_soundHost/route_mp3/${route.mp3Start}?${route.mp3Version}");
        }
      } else if (route.modeStart == 'none') {
        await _speakTts(gen, (lang) {
          final th = lang.nameField == 'th';
          return lang.buildWelcome(
            route: th ? route.nameTh : route.nameEn,
            first: th ? first.nameTh : first.nameEn,
            last: th ? last.nameTh : last.nameEn,
          );
        });
      } else {
        // text mode — JSON {"th-TH":"...","ru-RU":"..."} หรือ plain string
        await _speakTts(gen, (lang) => _extractTts(route.ttsStart, lang.code));
      }
    } else if (index == stations.length - 1) {
      if (route.modeStop == 'mp3') {
        if (route.mp3Stop.isNotEmpty) {
          await _playUrlAndWait("$_soundHost/route_mp3/${route.mp3Stop}?${route.mp3Version}");
        }
      } else if (route.modeStop == 'none') {
        await _speakTts(gen, (lang) {
          final th = lang.nameField == 'th';
          return lang.buildThankYou(
            route: th ? route.nameTh : route.nameEn,
            last: th ? last.nameTh : last.nameEn,
          );
        });
      } else {
        await _speakTts(gen, (lang) => _extractTts(route.ttsStop, lang.code));
      }
    } else {
      if (station.mode == 'mp3') {
        if (station.mp3.isNotEmpty) {
          await _playUrlAndWait("$_soundHost/${station.mp3}?${station.mp3Version}");
        }
      } else if (station.mode == 'none') {
        await _speakTts(gen, (lang) => lang.buildNextStop(
              name: lang.nameField == 'th' ? station.nameTh : station.nameEn,
            ));
      } else {
        await _speakTts(gen, (lang) => _extractTts(station.ttsText, lang.code));
      }
    }
  }

  /// เล่น mp3 แล้วรอจนจบ / error / ถูกประกาศใหม่ตัด
  Future<void> _playUrlAndWait(String url) async {
    final player = _announcer ??= Player();
    final done = Completer<void>();
    _mp3Done = done;
    var started = false;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final subs = [
      player.stream.completed.listen((c) {
        if (c) finish();
      }),
      player.stream.playing.listen((p) {
        if (p) {
          started = true;
        } else if (started) {
          finish();
        }
      }),
      player.stream.error.listen((e) {
        debugPrint("Announcement mp3 error: $e");
        finish();
      }),
    ];
    try {
      await player.setVolume(100);
      await player.open(Media(url), play: true);
      // ไฟล์เปิดไม่ขึ้น (เน็ตหลุด) ไม่ให้ค้างปิดเสียง bg ไว้นาน
      Timer(const Duration(seconds: 15), () {
        if (!started) finish();
      });
      await done.future.timeout(const Duration(minutes: 5), onTimeout: () {});
    } catch (e) {
      debugPrint("Announcement mp3 failed: $e");
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      if (identical(_mp3Done, done)) _mp3Done = null;
    }
  }

  /// พูด TTS ทุกภาษาที่เปิดไว้ตามลำดับ
  Future<void> _speakTts(int gen, String Function(TtsLangConfig lang) getText) async {
    if (!_ttsAvailable) return;
    for (final lang in langs.value.where((l) => l.enabled)) {
      if (gen != _generation) return;
      final text = getText(lang);
      if (text.isEmpty) continue;
      // ✅ พูดผ่านตัวกันค้าง: ถ้า engine หลุดจะต่อใหม่แล้วพูดซ้ำเอง
      final finished = await TtsEngineGuard.speak(
        _tts,
        text,
        rate: lang.rate,
        prepare: () async {
          await _tts.setLanguage(lang.code);
          await _tts.setSpeechRate(lang.rate);
          await TtsVoicePicker.applyGender(_tts, localeCode: lang.code, gender: lang.gender);
        },
      );
      // ถูกขัดจังหวะ (สถานีใหม่) → ไม่ต้องพูดภาษาถัดไปของประโยคเก่า
      if (!finished) return;
    }
  }

  /// ดึงข้อความสำหรับ locale หนึ่งจาก tts_text (text mode เท่านั้น)
  /// - JSON {"th-TH":"...","en-US":"..."}: เล่นเฉพาะภาษาที่ BO ตั้งค่าไว้ ถ้าไม่มี → คืนว่าง (ไม่เล่น)
  /// - plain string (format เก่า): ถือเป็นภาษาแรกที่ตั้งค่าไว้เท่านั้น
  String _extractTts(String raw, String localeCode) {
    if (raw.isEmpty) return '';
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map.containsKey(localeCode)) return map[localeCode]?.toString() ?? '';
      final prefix = localeCode.split('-').first;
      for (final key in map.keys) {
        if (key.split('-').first == prefix) return map[key]?.toString() ?? '';
      }
      return '';
    } catch (_) {
      final firstCode = langs.value.isNotEmpty ? langs.value.first.code : 'th-TH';
      return localeCode == firstCode ? raw : '';
    }
  }

  /// หยุดเสียงประกาศที่เล่นอยู่ (ไม่หยุด bg)
  Future<void> stop() async {
    final done = _mp3Done;
    if (done != null && !done.isCompleted) done.complete();
    try {
      await _announcer?.stop();
    } catch (_) {}
    await TtsEngineGuard.stop(_tts);
  }

  /// ออกจากหน้า player: หยุดทุกเสียง
  Future<void> stopAll() async {
    _generation++;
    await stop();
    await clearRoute();
  }
}
