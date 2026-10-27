// lib/pages/player_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // [จำเป็น] สำหรับ MethodChannel, SystemNavigator
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/layout_model.dart';
import '../models/route_audio.dart';
import '../models/tts_lang_config.dart';
import '../services/api_service.dart';
import '../services/preload_service.dart';
import '../services/tts_service.dart';
import '../utils/device_util.dart';
import '../utils/rotation_manager.dart';
import '../utils/version_update.dart'; // [Added] Import VersionUpdater
import '../widgets/layout_renderer.dart';
import '../widgets/content_player.dart';
import 'setup_page.dart';

class PlayerPage extends StatefulWidget {
  final SignageLayout layout;
  final int busId;
  final int companyId;

  const PlayerPage({
    super.key, 
    required this.layout,
    required this.busId,
    required this.companyId
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  // Channel สำหรับคุยกับ Android (Kiosk Mode)
  static const platform = MethodChannel('com.example.signage_app/kiosk');

  bool _showControls = false;

  // Location Override State
  Timer? _locationPollTimer;
  String? _currentLocationId;
  String? _activeRoundId; // busround ที่โหลดเสียงไว้แล้ว
  bool _isFirstPoll = true; // เปิดแอปกลางรอบ ไม่ต้องประกาศต้อนรับซ้ำ

  // เก็บ List เพื่อรองรับการเล่นวนหลายไฟล์ใน Location เดียวกัน
  Map<String, List<dynamic>> _activeLocationOverrides = {};
  SignageWidget? _activeFullscreenOverride;

  // รายการแบบ 'once' ที่กำลังเล่น (เล่นครั้งเดียวจนจบ แม้รถจะออกจาก location แล้ว)
  Map<String, OnceOverride> _activeOnceOverrides = {};
  OnceOverride? _activeOnceFullscreen;
  int _onceSeq = 0; // ทำให้ key ไม่ซ้ำ เพื่อเล่นใหม่ทุกครั้งที่ถึง location

  // Auto Update State
  Timer? _updateCheckTimer;
  bool _isDownloadingUpdate = false;
  Timer? _apkUpdateTimer;
  bool _isCheckingAppUpdate = false;

  // Normal Playlist Fullscreen State
  String? _playlistFullscreenId;

  // layout ที่แทน {busno}/{com_id} ใน URL ด้วยรถคันนี้แล้ว (1 layout ใช้ได้หลายคัน)
  late final SignageLayout _layout = resolveBusVars(widget.layout, widget.busId, widget.companyId);

  String get _busApiUrl => 'https://public.bussing.app/bus-info/busround-active?busno=${widget.busId}&com_id=${widget.companyId}';

  @override
  void initState() {
    super.initState();
    print("🚀 Player Start: Bus ${widget.busId}, Com ${widget.companyId}");
    
    // 0. เปิด Kiosk Mode (ล็อคปุ่ม Home)
    // _setKioskMode(true);

    // 1. Check Location (30s)
    _locationPollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkBusLocation());

    // 2. Check Update (5m)
    _updateCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkForLayoutUpdate());

    WidgetsBinding.instance.addPostFrameCallback((_) {
        // เช็ค Location ทันที 1 รอบ (ไม่ต้องรอ 30 วิ)
        _checkBusLocation(); 
        
        // รอ 5 วินาที ให้วิดีโอเล่นนิ่งๆ ก่อน ค่อยเช็คอัปเดตแอป (กันแย่งเน็ต)
        Future.delayed(const Duration(seconds: 5), () {
             if (mounted) {
                 _checkForAppUpdate();
                 _apkUpdateTimer = Timer.periodic(
                   const Duration(minutes: 5),
                   (_) => _checkForAppUpdate(),
                 );
             }
        });
    });
  }

  @override
  void dispose() {
    // ปลดล็อค Kiosk Mode เมื่อออกจากหน้านี้ (เผื่อกรณีออกด้วยวิธีอื่น)
    // _setKioskMode(false);
    _apkUpdateTimer?.cancel();
    _locationPollTimer?.cancel();
    _updateCheckTimer?.cancel();
    TtsService().stopAll();
    super.dispose();
  }

  // ============================
  // 0. Kiosk Mode Logic
  // ============================
  Future<void> _setKioskMode(bool enable) async {
    try {
      if (enable) {
        await platform.invokeMethod('startKioskMode');
        print("🔒 Kiosk Mode Enabled");
      } else {
        await platform.invokeMethod('stopKioskMode');
        print("🔓 Kiosk Mode Disabled");
      }
    } on PlatformException catch (e) {
      print("⚠️ Kiosk Mode Error: ${e.message}");
    }
  }


  // ============================
  // 1. Location Logic (Looping Support)
  // ============================
  Future<void> _checkBusLocation() async {
    try {
      final response = await http.get(Uri.parse(_busApiUrl));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['status'] == true && json['data'] != null) {
          final data = json['data'] as Map<String, dynamic>;
          final locationIdRaw = data['busround_location_now_id'];
          final locationId = locationIdRaw?.toString();

          final roundChanged = await _syncRoundAudio(data);

          if (locationId != _currentLocationId) {
            print("📍 Location Changed: $_currentLocationId -> $locationId");
            _currentLocationId = locationId;
            _updateContentForLocation(locationId);
            _announceTts(data, locationId);
          } else if (roundChanged && locationId == null && !_isFirstPoll) {
            // เริ่มรอบใหม่: แท็บเล็ตเล่นเสียงต้นทางโดยยังไม่ส่ง location ขึ้นมา → ประกาศต้อนรับเอง
            if (TtsService().route != null) {
              TtsService().announceIndex(0);
            }
          }
          _isFirstPoll = false;
        }
      }
    } catch (e) {
      print("⚠️ Location Poll Error: $e");
    }
  }

  /// รอบ/เส้นทางเปลี่ยน → โหลดข้อมูลเสียงของ route ใหม่, รอบจบ → หยุดเสียง bg
  /// คืน true ถ้าเป็นรอบใหม่
  Future<bool> _syncRoundAudio(Map<String, dynamic> data) async {
    final roundId = data['busround_id']?.toString();
    final routeId = int.tryParse(data['busround_route_id']?.toString() ?? '');
    final ended = data['busround_stop'] != null;

    if (ended) {
      if (_activeRoundId != null) {
        _activeRoundId = null;
        await TtsService().clearRoute();
      }
      return false;
    }
    if (roundId == _activeRoundId) return false;
    _activeRoundId = roundId;

    RouteAudio? audio;
    if (routeId != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final baseUrl = prefs.getString('api_base_url') ?? ApiService().baseUrl;
        final res = await http.get(Uri.parse(
            '$baseUrl/bussing/route-audio?route_id=$routeId&com_id=${widget.companyId}'));
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          if (body['status'] == true && body['data'] != null) {
            audio = RouteAudio.fromJson((body['data'] as Map).cast<String, dynamic>());
          }
        }
      } catch (e) {
        print("⚠️ Route audio load failed: $e");
      }
    }
    if (audio == null) {
      // โหลดรอบหน้าใหม่ (ประกาศจะใช้ชื่อสถานีจาก busround-active ไปก่อน)
      _activeRoundId = null;
    }
    await TtsService().setRoute(audio);
    return true;
  }

  void _announceTts(Map<String, dynamic> data, String? locationId) {
    final nowId = int.tryParse(locationId ?? '');
    if (nowId == null || nowId == 0) return;

    final tts = TtsService();
    if (tts.route != null) {
      final index = tts.resolveIndex(
        nowId,
        preId: int.tryParse(data['busround_location_pre_id']?.toString() ?? ''),
        nextId: int.tryParse(data['busround_location_next_id']?.toString() ?? ''),
      );
      if (index != null) {
        tts.announceIndex(index);
        return;
      }
    }

    // ไม่มีข้อมูลเสียงของ route → พูดจากชื่อสถานีแทน
    final routeArray = (data['route_array'] as String?)
        ?.split(',')
        .map((e) => e.trim())
        .toList() ?? [];
    if (routeArray.isEmpty) return;
    final terminalId = data['terminal_id']?.toString();
    final kind = locationId == routeArray.first
        ? 'start'
        : locationId == terminalId
            ? 'end'
            : 'next';
    tts.announceByName(
      kind: kind,
      routeTh: data['route_name_th']?.toString() ?? '',
      routeEn: data['route_name_en']?.toString() ?? data['route_name_th']?.toString() ?? '',
      nameTh: data['location_now']?.toString() ?? '',
      nameEn: data['location_now_en']?.toString() ?? '',
      lastTh: data['terminal_th']?.toString() ?? '',
      lastEn: data['terminal_th_en']?.toString() ?? '',
    );
  }

  void _updateContentForLocation(String? locationId) {
    Map<String, List<dynamic>> newOverrides = {};
    SignageWidget? newFullscreen;
    Map<String, OnceOverride> newOnce = {};
    OnceOverride? newOnceFullscreen;

    if (locationId != null) {
      for (final widget in _layout.widgets) {
        final props = widget.properties;
        if (props['playlist'] is List) {
          final playlist = props['playlist'] as List;

          // ดึงทุกรายการที่ตรงกับ Location นี้มา (เพื่อให้เล่นวนได้หลายไฟล์)
          final allMatchItems = playlist.where(
            (item) => item['locationId'].toString() == locationId
          ).toList();

          // แบบ 'once' → เล่นครั้งเดียวจบ
          final onceItems = allMatchItems.where(isOnceItem).toList();
          if (onceItems.isNotEmpty) {
            print("🎯 Once Match! Widget: ${widget.id}, Items: ${onceItems.length}");
            final seq = ++_onceSeq;
            final onceFull = onceItems.where((i) => i['fullscreen'] == true).toList();
            final onceNormal = onceItems.where((i) => i['fullscreen'] != true).toList();

            if (onceFull.isNotEmpty && newOnceFullscreen == null) {
              newOnceFullscreen = OnceOverride(
                key: "once-full-$locationId-$seq",
                widget: SignageWidget(
                  id: "once-full-$locationId",
                  type: widget.type,
                  x: 0, y: 0, width: 0, height: 0,
                  properties: { ...props, 'playlist': onceFull, 'url': null },
                ),
              );
            }
            if (onceNormal.isNotEmpty) {
              newOnce[widget.id] = OnceOverride(
                key: "once-${widget.id}-$locationId-$seq",
                widget: SignageWidget(
                  id: "${widget.id}-once-$locationId",
                  type: widget.type,
                  x: widget.x, y: widget.y, width: widget.width, height: widget.height,
                  properties: { ...props, 'playlist': onceNormal, 'url': null },
                ),
              );
            }
          }

          // แบบ 'loop' (เดิม) → วนเล่นระหว่างอยู่ที่ location
          final matchItems = allMatchItems.where((i) => !isOnceItem(i)).toList();

          if (matchItems.isNotEmpty) {
            print("✨ Location Match! Widget: ${widget.id}, Items: ${matchItems.length}");

            // แยกกรณี Fullscreen กับ In-Place
            final fullscreenItems = matchItems.where((i) => i['fullscreen'] == true).toList();
            final normalItems = matchItems.where((i) => i['fullscreen'] != true).toList();

            if (fullscreenItems.isNotEmpty) {
               newFullscreen = SignageWidget(
                  id: "loc-full-$locationId", 
                  type: widget.type,
                  x: 0, y: 0, width: 0, height: 0,
                  properties: { ...props, 'playlist': fullscreenItems, 'url': null }
               );
            }
            
            if (normalItems.isNotEmpty) {
              newOverrides[widget.id] = normalItems;
            }
          }
        }
      }
    } else {
      print("❌ Location Exited: Back to normal playlist");
    }

    if (mounted) {
      setState(() {
        _activeLocationOverrides = newOverrides;
        _activeFullscreenOverride = newFullscreen;
        // ตัวที่กำลังเล่นอยู่ให้เล่นต่อจนจบ ยกเว้น location ใหม่มีรายการ 'once' ของ widget เดียวกัน
        _activeOnceOverrides = {..._activeOnceOverrides, ...newOnce};
        if (newOnceFullscreen != null) _activeOnceFullscreen = newOnceFullscreen;
      });
    }
  }

  void _handleOnceFinished(String widgetId, String key) {
    if (!mounted || _activeOnceOverrides[widgetId]?.key != key) return;
    print("✅ Once finished: $widgetId");
    setState(() => _activeOnceOverrides = Map.of(_activeOnceOverrides)..remove(widgetId));
  }

  VoidCallback _onceFullscreenFinisher(String key) => () {
    if (!mounted || _activeOnceFullscreen?.key != key) return;
    print("✅ Once fullscreen finished");
    setState(() => _activeOnceFullscreen = null);
  };

  // ============================
  // 2. Auto Update Logic
  // ============================
  Future<void> _checkForAppUpdate() async {
    if (_isCheckingAppUpdate || !mounted) return;

    _isCheckingAppUpdate = true;
    try {
      await VersionUpdater.checkAndMaybeUpdate(
        context,
        silent: true,
        isAutoUpdate: true,
      );
    } finally {
      _isCheckingAppUpdate = false;
    }
  }

  Future<void> _checkForLayoutUpdate() async {
    if (_isDownloadingUpdate) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString('api_base_url');
      final deviceId = await DeviceUtil.getDeviceId();
      if (url == null) return;

      final api = ApiService(url);
      final busConfig = await api.fetchBusConfig(deviceId);
      
      final serverLayoutId = busConfig['id'];
      final int serverVersion = busConfig['layout_version'] ?? 0;
      // ✅ ใช้ bus_id จาก server เสมอ (กัน busId = 0 จาก offline mode)
      final int freshBusId = int.tryParse(busConfig['bus_id']?.toString() ?? '') ?? widget.busId;

      final bool isDifferentLayout = serverLayoutId.toString() != widget.layout.id;
      final bool isNewerVersion = serverVersion > widget.layout.version;

      if (serverLayoutId != null && (isDifferentLayout || isNewerVersion)) {
        print("📢 Update Found: V.$serverVersion");
        setState(() => _isDownloadingUpdate = true);
        
        final newLayout = await api.fetchLayoutById(serverLayoutId.toString());
        await PreloadService.manageAssets(newLayout, (_,__,___){});
        
        await prefs.setString('cached_layout_id', serverLayoutId.toString());
        await prefs.setInt('cached_layout_version', serverVersion);
        await prefs.setString('cached_layout_json', jsonEncode(newLayout.toJson()));
        await prefs.setInt('cached_bus_id', freshBusId); // ✅ อัพเดท cache
        await api.updateBusStatus(freshBusId, serverVersion); // ✅ ใช้ freshBusId

        if (mounted) {
          Navigator.pushReplacement(context, PageRouteBuilder(
            pageBuilder: (_,__,___) => PlayerPage(layout: newLayout, busId: freshBusId, companyId: widget.companyId),
            transitionDuration: Duration.zero
          ));
        }
      }
    } catch (e) {
      print("⚠️ Auto-update failed: $e");
    } finally {
      if (mounted) setState(() => _isDownloadingUpdate = false);
    }
  }

  // ============================
  // 3. Fullscreen & UI Logic
  // ============================
  void _handleWidgetFullscreen(String widgetId, bool isFull) {
    if (isFull && _playlistFullscreenId != widgetId) {
      setState(() => _playlistFullscreenId = widgetId);
    } else if (!isFull && _playlistFullscreenId == widgetId) {
      setState(() => _playlistFullscreenId = null);
    }
  }
    Future<void> _clearOwnerAndExit() async {
  try {
    const platform = MethodChannel('com.example.signage_app/kiosk');
    
    // 1. สั่งปลด Kiosk ก่อน (กันเหนียว)
    await platform.invokeMethod('stopKioskMode');
    
    // 2. สั่งล้าง Device Owner
    await platform.invokeMethod('clearDeviceOwner');
    
    print("✅ Device Owner Cleared! You can now uninstall the app.");
  } catch (e) {
    print("❌ Error clearing owner: $e");
  }

  // 3. ปิดแอป
  if (mounted) {
    SystemNavigator.pop();
  }
}

  // [Modified] เปลี่ยนชื่อฟังก์ชันจาก _showExitPinDialog เป็น _handleAdminMenu
  Future<void> _handleAdminMenu() async {
    // แสดง Dialog และรอผลลัพธ์ว่า User เลือกอะไร ('exit' หรือ 'update')
    final String? action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AdminMenuDialog(busId: widget.busId),
    );

    if (action == 'exit') {
       // ถ้าเลือก Exit -> ปิด Kiosk และออกแอพ
      //  await _setKioskMode(false);
       if (mounted) SystemNavigator.pop();
    } else if (action == 'update') {
       // ถ้าเลือก Update -> เรียก VersionUpdater
       if (mounted) {
         await VersionUpdater.checkAndMaybeUpdate(context);
       }
    }
  }

  @override
  Widget build(BuildContext context) {
    // ใช้ PopScope ดักปุ่ม Back
    return PopScope(
      canPop: false, 
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // เมื่อกด Back (หรือปุ่มรีโมท) ให้เรียก Admin Menu
        _handleAdminMenu();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: () {
            setState(() => _showControls = !_showControls);
            if (_showControls) Future.delayed(const Duration(seconds: 3), () { if(mounted) setState(() => _showControls = false); });
          },
          child: Stack(
            children: [
              // Main Renderer
              LayoutRenderer(
                layout: _layout,
                locationOverrides: _activeLocationOverrides, // ส่ง List ของ Location items
                onceOverrides: _activeOnceOverrides,
                onOnceFinished: _handleOnceFinished,
                fullscreenWidgetId: _playlistFullscreenId,
                onWidgetFullscreen: _handleWidgetFullscreen,
              ),

              // Location Fullscreen Overlay
              if (_activeFullscreenOverride != null)
                Container(
                  color: Colors.black,
                  child: SizedBox.expand(
                    child: ContentPlayer(
                      key: ValueKey("loc-full-${_currentLocationId}"),
                      widget: _activeFullscreenOverride!,
                      isTriggerMode: false, // Loop
                    ),
                  ),
                ),

              // Location Fullscreen Overlay แบบ 'once' (เล่นครั้งเดียวแล้วปิด)
              if (_activeOnceFullscreen != null)
                Container(
                  color: Colors.black,
                  child: SizedBox.expand(
                    child: ContentPlayer(
                      key: ValueKey(_activeOnceFullscreen!.key),
                      widget: _activeOnceFullscreen!.widget,
                      isTriggerMode: true,
                      onFinished: _onceFullscreenFinisher(_activeOnceFullscreen!.key),
                    ),
                  ),
                ),

              // Control Buttons (Hidden Menu)
              if (_showControls)
                Positioned(
                  top: 20, right: 20,
                  child: SafeArea(
                    child: FloatingActionButton(
                      backgroundColor: Colors.red.withValues(alpha: 0.8),
                      child: const Icon(Icons.settings, color: Colors.white), // เปลี่ยน Icon เป็น Settings ให้สื่อความหมาย
                      onPressed: () => _handleAdminMenu(), // เรียก Admin Menu
                    ),
                  ),
                ),
                
               // Update Indicator
               if (_isDownloadingUpdate)
                 Positioned(bottom: 10, left: 10, child: const CircularProgressIndicator(color: Colors.white))
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 🔐 Admin Menu Dialog (รวม PIN และ เมนู)
// ==========================================

// โทนสีของ Admin Menu
class _AdminColors {
  static const surface = Color(0xFF1B1D23);
  static const card = Color(0xFF252831);
  static const cardHover = Color(0xFF2E323D);
  static const border = Color(0xFF353946);
  static const textPrimary = Color(0xFFF2F3F5);
  static const textSecondary = Color(0xFF9AA0AE);
  static const accent = Color(0xFF4F8CFF);
  static const accent2 = Color(0xFF7B5CFF);
  static const success = Color(0xFF34C77B);
  static const warning = Color(0xFFFFB547);
  static const danger = Color(0xFFFF5A5F);
}

class _AdminMenuDialog extends StatefulWidget {
  final int busId;
  const _AdminMenuDialog({required this.busId});

  @override
  State<_AdminMenuDialog> createState() => _AdminMenuDialogState();
}

class _AdminMenuDialogState extends State<_AdminMenuDialog> {
  static const int _pinLength = 6;
  static const int _timeoutSeconds = 10;

  // ใช้แป้นตัวเลขใน dialog แทนคีย์บอร์ดระบบ — คีย์บอร์ดระบบไม่หมุนตามจอที่ตั้งหมุนไว้
  String _pin = '';
  final FocusNode _focusNode = FocusNode(); // รับปุ่มตัวเลขจากรีโมท/คีย์บอร์ดจริง
  Timer? _timer;
  int _countdown = _timeoutSeconds;
  bool _isUnlocked = false;
  bool _pinError = false;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });

    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = 'v${info.version} (${info.buildNumber})');
    }).catchError((_) {});

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          if (_isUnlocked) {
            timer.cancel();
            return;
          }
          if (_countdown > 0) {
            _countdown--;
          } else {
            timer.cancel();
            Navigator.of(context).pop();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _onPinChanged(String value) {
    if (value == '000000') {
      _timer?.cancel();
      setState(() {
        _pin = value;
        _isUnlocked = true;
      });
      return;
    }

    if (value.length >= _pinLength) {
      // รหัสผิด -> แจ้งเตือนแล้วล้างช่อง
      setState(() {
        _pinError = true;
        _pin = '';
      });
    } else {
      setState(() {
        _pin = value;
        if (value.isNotEmpty) _pinError = false;
      });
    }
  }

  void _pressDigit(String d) {
    if (_isUnlocked || _pin.length >= _pinLength) return;
    _onPinChanged(_pin + d);
  }

  void _pressBackspace() {
    if (_pin.isEmpty) return;
    _onPinChanged(_pin.substring(0, _pin.length - 1));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _isUnlocked) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ch = event.character;
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _pressDigit(ch);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
      _pressBackspace();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ✅ 1. ต้องวางฟังก์ชันนี้ไว้ตรงนี้ (ใน class State ก่อน build)
  Future<void> _clearOwnerAndExit() async {
    try {
      // ⚠️ เช็คชื่อ package ให้ตรงกับโปรเจกต์ (com.example.signage_app หรือ com.example.driver_system)
      const platform = MethodChannel('com.example.signage_app/kiosk');

      // 1. สั่งปลด Kiosk ก่อน
      await platform.invokeMethod('stopKioskMode');

      // 2. สั่งล้าง Device Owner (ถอนสิทธิ์ Admin)
      await platform.invokeMethod('clearDeviceOwner');

      print("✅ Device Owner Cleared!");
    } catch (e) {
      print("❌ Error clearing owner: $e");
    }

    // 3. ปิดแอป
    if (mounted) {
      SystemNavigator.pop();
    }
  }

  // ยืนยันก่อนล้าง Admin (กันกดพลาด)
  Future<void> _confirmClearOwner() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _AdminColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.warning_amber_rounded, color: _AdminColors.danger, size: 40),
        title: const Text('ล้างสิทธิ์ Admin?', style: TextStyle(color: _AdminColors.textPrimary)),
        content: const Text(
          'แอปจะออกจาก Kiosk Mode และถอนสิทธิ์ Device Owner\nหลังจากนี้สามารถถอนการติดตั้งแอปได้',
          textAlign: TextAlign.center,
          style: TextStyle(color: _AdminColors.textSecondary, height: 1.4),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ยกเลิก', style: TextStyle(color: _AdminColors.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _AdminColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ล้างและออก'),
          ),
        ],
      ),
    );
    if (ok == true) await _clearOwnerAndExit();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _AdminColors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: _AdminColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _isUnlocked ? 520 : 400),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: _isUnlocked ? _buildMenu(context) : _buildPinView(context),
        ),
      ),
    );
  }

  // ----------------------------------------
  // [View 1] หน้าใส่ PIN (ค่าเริ่มต้น)
  // ----------------------------------------
  Widget _buildPinView(BuildContext context) {
    final entered = _pin.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ไอคอนกุญแจ + วงนับถอยหลัง
          SizedBox(
            width: 84,
            height: 84,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: _countdown / _timeoutSeconds),
                    duration: const Duration(milliseconds: 900),
                    builder: (context, value, _) => CircularProgressIndicator(
                      value: value,
                      strokeWidth: 4,
                      backgroundColor: _AdminColors.border,
                      color: _countdown <= 3 ? _AdminColors.danger : _AdminColors.accent,
                    ),
                  ),
                ),
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (_pinError ? _AdminColors.danger : _AdminColors.accent).withValues(alpha: 0.15),
                  ),
                  child: Icon(
                    _pinError ? Icons.lock_outline : Icons.lock_rounded,
                    color: _pinError ? _AdminColors.danger : _AdminColors.accent,
                    size: 30,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Admin Access',
            style: TextStyle(color: _AdminColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            _pinError ? 'รหัสไม่ถูกต้อง ลองใหม่อีกครั้ง' : 'ใส่รหัส PIN เพื่อเข้าเมนู ($_countdown วิ)',
            style: TextStyle(
              color: _pinError ? _AdminColors.danger : _AdminColors.textSecondary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),

          // จุดแสดงจำนวนหลักที่กรอก
          Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _onKey,
            child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pinLength, (i) {
                  final filled = i < entered;
                  final active = i == entered;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 40,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _AdminColors.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _pinError
                            ? _AdminColors.danger
                            : active
                                ? _AdminColors.accent
                                : _AdminColors.border,
                        width: active ? 2 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: AnimatedScale(
                      scale: filled ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: _AdminColors.textPrimary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                }),
            ),
          ),
          const SizedBox(height: 20),

          // แป้นตัวเลข (หมุนตามจอ ต่างจากคีย์บอร์ดระบบ)
          SizedBox(
            width: 264,
            child: Column(
              children: [
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                  ['', '0', '<'],
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        for (final k in row)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: k.isEmpty
                                  ? const SizedBox(height: 52)
                                  : _PinKey(
                                      label: k,
                                      onTap: k == '<' ? _pressBackspace : () => _pressDigit(k),
                                    ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('ยกเลิก', style: TextStyle(color: _AdminColors.textSecondary, fontSize: 15)),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------
  // [View 2] หน้าเมนู Admin (เมื่อใส่รหัสถูก)
  // ----------------------------------------
  Widget _buildMenu(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 12, 20),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF233A6B), Color(0xFF2D2560)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(colors: [_AdminColors.accent, _AdminColors.accent2]),
                ),
                child: const Icon(Icons.admin_panel_settings_rounded, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Admin Menu',
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        'Bus #${widget.busId}',
                        if (_appVersion.isNotEmpty) _appVersion,
                      ].join('  •  '),
                      style: const TextStyle(color: Color(0xFFB9C2DA), fontSize: 13),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'ปิด',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
              ),
            ],
          ),
        ),

        // Body
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ----- การแสดงผล -----
                const _SectionLabel('การแสดงผล'),
                _AdminCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _CardTitle(
                        icon: Icons.screen_rotation_rounded,
                        color: _AdminColors.accent,
                        title: 'การหมุนจอ',
                        subtitle: 'เลือกทิศทางตามการติดตั้งจอ',
                      ),
                      const SizedBox(height: 14),
                      ValueListenableBuilder<int>(
                        valueListenable: RotationManager.quarterTurns,
                        builder: (context, current, _) {
                          return Row(
                            children: List.generate(4, (turns) {
                              return Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(left: turns == 0 ? 0 : 8),
                                  child: _RotationOption(
                                    turns: turns,
                                    selected: current == turns,
                                    onTap: () => RotationManager.set(turns),
                                  ),
                                ),
                              );
                            }),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // ----- เสียง -----
                const _SectionLabel('เสียง'),
                ValueListenableBuilder<bool>(
                  valueListenable: TtsService.enabled,
                  builder: (context, on, _) {
                    return _AdminCard(
                      onTap: () => TtsService.setEnabled(!on),
                      child: Row(
                        children: [
                          Expanded(
                            child: _CardTitle(
                              icon: on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                              color: on ? _AdminColors.success : _AdminColors.textSecondary,
                              title: 'เสียงออกจอ',
                              subtitle: on ? 'เปิดอยู่ — เสียงประกาศสถานี + เสียง bg' : 'ปิดอยู่',
                            ),
                          ),
                          Switch(
                            value: on,
                            activeColor: Colors.white,
                            activeTrackColor: _AdminColors.success,
                            inactiveThumbColor: _AdminColors.textSecondary,
                            inactiveTrackColor: _AdminColors.border,
                            onChanged: (v) => TtsService.setEnabled(v),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                _AdminCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ValueListenableBuilder<double>(
                        valueListenable: TtsService.bgVolume,
                        builder: (context, vol, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _CardTitle(
                              icon: Icons.music_note_rounded,
                              color: _AdminColors.accent2,
                              title: 'ระดับเสียง bg',
                              subtitle: '${(vol * 100).round()}% — ปิดเองระหว่างประกาศสถานี',
                            ),
                            Slider(
                              value: vol,
                              divisions: 20,
                              activeColor: _AdminColors.accent2,
                              inactiveColor: _AdminColors.border,
                              onChanged: TtsService.setBgVolume,
                              onChangeEnd: (_) => TtsService.saveBgVolume(),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      const _CardTitle(
                        icon: Icons.translate_rounded,
                        color: _AdminColors.accent,
                        title: 'ภาษาประกาศ (TTS)',
                        subtitle: 'ใช้กับสถานีที่ตั้งเป็นเสียงอ่านข้อความ',
                      ),
                      const SizedBox(height: 10),
                      ValueListenableBuilder<List<TtsLangConfig>>(
                        valueListenable: TtsService.langs,
                        builder: (context, langs, _) => Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final l in langs)
                              FilterChip(
                                label: Text(l.label),
                                selected: l.enabled,
                                showCheckmark: false,
                                labelStyle: TextStyle(
                                  color: l.enabled ? Colors.white : _AdminColors.textSecondary,
                                ),
                                backgroundColor: _AdminColors.surface,
                                selectedColor: _AdminColors.accent.withValues(alpha: 0.35),
                                side: BorderSide(
                                  color: l.enabled ? _AdminColors.accent : _AdminColors.border,
                                ),
                                onSelected: (v) => TtsService.setLangEnabled(l.code, v),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // ----- ระบบ -----
                const _SectionLabel('ระบบ'),
                _AdminCard(
                  onTap: () => Navigator.pop(context, 'update'),
                  child: const Row(
                    children: [
                      Expanded(
                        child: _CardTitle(
                          icon: Icons.system_update_rounded,
                          color: _AdminColors.accent,
                          title: 'ตรวจสอบอัปเดตแอป',
                          subtitle: 'ดาวน์โหลดและติดตั้งเวอร์ชันล่าสุด',
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: _AdminColors.textSecondary),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _AdminCard(
                  onTap: () => Navigator.pop(context, 'exit'),
                  child: const Row(
                    children: [
                      Expanded(
                        child: _CardTitle(
                          icon: Icons.logout_rounded,
                          color: _AdminColors.warning,
                          title: 'ออกจากแอป',
                          subtitle: 'ปิดแอปชั่วคราว',
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: _AdminColors.textSecondary),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // ----- Danger zone -----
                const _SectionLabel('อันตราย', color: _AdminColors.danger),
                // ✅ 2. ปุ่มล้าง Admin (เรียกฟังก์ชันที่สร้างไว้ข้อ 1)
                _AdminCard(
                  onTap: _confirmClearOwner,
                  borderColor: _AdminColors.danger.withValues(alpha: 0.5),
                  background: _AdminColors.danger.withValues(alpha: 0.08),
                  child: const Row(
                    children: [
                      Expanded(
                        child: _CardTitle(
                          icon: Icons.delete_forever_rounded,
                          color: _AdminColors.danger,
                          title: 'ล้างสิทธิ์ Admin และออก',
                          subtitle: 'ปลด Kiosk + Device Owner เพื่อถอนการติดตั้ง',
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: _AdminColors.danger),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------- ส่วนประกอบย่อยของ Admin Menu ----------

class _PinKey extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PinKey({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _AdminColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _AdminColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        focusColor: _AdminColors.accent.withValues(alpha: 0.25),
        child: SizedBox(
          height: 52,
          child: Center(
            child: label == '<'
                ? const Icon(Icons.backspace_outlined, color: _AdminColors.textSecondary, size: 22)
                : Text(
                    label,
                    style: const TextStyle(color: _AdminColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final Color color;
  const _SectionLabel(this.text, {this.color = _AdminColors.textSecondary});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2),
      ),
    );
  }
}

class _AdminCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color? borderColor;
  final Color? background;

  const _AdminCard({required this.child, this.onTap, this.borderColor, this.background});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? _AdminColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderColor ?? _AdminColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: _AdminColors.cardHover,
        focusColor: _AdminColors.accent.withValues(alpha: 0.18), // สำหรับรีโมท TV (D-pad)
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  const _CardTitle({required this.icon, required this.color, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(color: _AdminColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: _AdminColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// ตัวเลือกการหมุนจอ แสดงรูปจอจำลองตามทิศทาง
class _RotationOption extends StatelessWidget {
  final int turns;
  final bool selected;
  final VoidCallback onTap;

  const _RotationOption({required this.turns, required this.selected, required this.onTap});

  static const _names = ['แนวนอน', 'แนวตั้ง', 'กลับหัว', 'แนวตั้ง'];

  @override
  Widget build(BuildContext context) {
    final isPortrait = turns.isOdd;
    final color = selected ? _AdminColors.accent : _AdminColors.textSecondary;

    return Material(
      color: selected ? _AdminColors.accent.withValues(alpha: 0.14) : _AdminColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? _AdminColors.accent : _AdminColors.border,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        focusColor: _AdminColors.accent.withValues(alpha: 0.25),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // จอจำลอง
              SizedBox(
                height: 44,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: isPortrait ? 26 : 42,
                    height: isPortrait ? 42 : 26,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: color, width: 2),
                    ),
                    child: Transform.rotate(
                      angle: turns * 3.1415926535 / 2,
                      child: Icon(Icons.arrow_upward_rounded, size: 16, color: color),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${turns * 90}°',
                style: TextStyle(color: selected ? _AdminColors.textPrimary : _AdminColors.textSecondary, fontSize: 15, fontWeight: FontWeight.w700),
              ),
              Text(
                _names[turns],
                style: TextStyle(color: color, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
