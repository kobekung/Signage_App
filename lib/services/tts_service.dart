import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  bool _isSpeaking = false;
  bool get isSpeaking => _isSpeaking;

  final _duckController = StreamController<bool>.broadcast();
  Stream<bool> get duckStream => _duckController.stream;

  Future<void> _init() async {
    if (_initialized) return;
    await _tts.setLanguage("th-TH");
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      _isSpeaking = true;
      _duckController.add(true);
    });

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      _duckController.add(false);
    });

    _tts.setCancelHandler(() {
      _isSpeaking = false;
      _duckController.add(false);
    });

    _initialized = true;
  }

  Future<void> announceWelcome(String routeName, String stationName) async {
    await _init();
    await _tts.stop();
    await _tts.speak("ยินดีต้อนรับเข้าสู่เส้นทาง $routeName  ขณะนี้อยู่ที่สถานี $stationName");
  }

  Future<void> announceStation(String stationName) async {
    await _init();
    await _tts.stop();
    await _tts.speak("สถานีถัดไป $stationName");
  }

  Future<void> announceGoodbye(String routeName) async {
    await _init();
    await _tts.stop();
    await _tts.speak("ขอบคุณที่ใช้บริการ เส้นทาง $routeName");
  }

  Future<void> stop() async {
    await _tts.stop();
  }
}
