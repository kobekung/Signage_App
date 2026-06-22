// lib/pages/player_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // [จำเป็น] สำหรับ MethodChannel, SystemNavigator
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/layout_model.dart';
import '../services/api_service.dart';
import '../services/preload_service.dart';
import '../services/tts_service.dart';
import '../utils/device_util.dart';
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
  
  // เก็บ List เพื่อรองรับการเล่นวนหลายไฟล์ใน Location เดียวกัน
  Map<String, List<dynamic>> _activeLocationOverrides = {}; 
  SignageWidget? _activeFullscreenOverride; 

  // Auto Update State
  Timer? _updateCheckTimer;
  bool _isDownloadingUpdate = false;
  Timer? _apkUpdateTimer;
  bool _isCheckingAppUpdate = false;

  // Normal Playlist Fullscreen State
  String? _playlistFullscreenId;

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
    TtsService().stop();
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

          if (locationId != _currentLocationId) {
            print("📍 Location Changed: $_currentLocationId -> $locationId");
            _currentLocationId = locationId;
            _updateContentForLocation(locationId);
            _announceTts(data, locationId);
          }
        }
      }
    } catch (e) {
      print("⚠️ Location Poll Error: $e");
    }
  }

  void _announceTts(Map<String, dynamic> data, String? locationId) {
    if (locationId == null) return;

    final routeArray = (data['route_array'] as String?)
        ?.split(',')
        .map((e) => e.trim())
        .toList() ?? [];
    final terminalId = data['terminal_id']?.toString();
    final routeNameTh = data['route_name_th']?.toString() ?? '';
    final locationNow = data['location_now']?.toString() ?? '';

    if (routeArray.isEmpty) return;

    if (locationId == routeArray.first) {
      TtsService().announceWelcome(routeNameTh, locationNow);
    } else if (locationId == terminalId) {
      TtsService().announceGoodbye(routeNameTh);
    } else {
      TtsService().announceStation(locationNow);
    }
  }

  void _updateContentForLocation(String? locationId) {
    Map<String, List<dynamic>> newOverrides = {};
    SignageWidget? newFullscreen;

    if (locationId != null) {
      for (final widget in widget.layout.widgets) {
        final props = widget.properties;
        if (props['playlist'] is List) {
          final playlist = props['playlist'] as List;
          
          // ดึงทุกรายการที่ตรงกับ Location นี้มา (เพื่อให้เล่นวนได้หลายไฟล์)
          final matchItems = playlist.where(
            (item) => item['locationId'].toString() == locationId
          ).toList();

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
      });
    }
  }

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
      builder: (context) => const _AdminMenuDialog(),
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
                layout: widget.layout,
                locationOverrides: _activeLocationOverrides, // ส่ง List ของ Location items
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
class _AdminMenuDialog extends StatefulWidget {
  const _AdminMenuDialog();

  @override
  State<_AdminMenuDialog> createState() => _AdminMenuDialogState();
}

class _AdminMenuDialogState extends State<_AdminMenuDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _timer;
  int _countdown = 10;
  bool _isUnlocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });

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
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onPinChanged(String value) {
    if (value == '000000') {
      _timer?.cancel();
      setState(() {
        _isUnlocked = true;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    // ----------------------------------------
    // [View 2] หน้าเมนู Admin (เมื่อใส่รหัสถูก)
    // ----------------------------------------
    if (_isUnlocked) {
      return AlertDialog(
        backgroundColor: Colors.white,
        title: const Row(
          children: [
            Icon(Icons.admin_panel_settings, color: Colors.blue),
            SizedBox(width: 10),
            Text("Admin Menu", style: TextStyle(color: Colors.black)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ปุ่ม Check Update
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context, 'update'),
              icon: const Icon(Icons.system_update),
              label: const Text('Check for App Update'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
            const SizedBox(height: 10),
            
            // ปุ่ม Exit App (ปกติ)
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context, 'exit'),
              icon: const Icon(Icons.exit_to_app),
              label: const Text('Exit Application'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
             const SizedBox(height: 10),

             // ✅ 2. ปุ่มล้าง Admin (เรียกฟังก์ชันที่สร้างไว้ข้อ 1)
             ElevatedButton.icon(
              onPressed: _clearOwnerAndExit, // ไม่แดงแล้ว
              icon: const Icon(Icons.delete_forever),
              label: const Text('CLEAR ADMIN & EXIT'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, // สีแดงเตือน
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Close"),
          ),
        ],
      );
    }

    // ----------------------------------------
    // [View 1] หน้าใส่ PIN (ค่าเริ่มต้น)
    // ----------------------------------------
    return AlertDialog(
      // ... (ส่วนใส่ PIN เหมือนเดิม) ...
      backgroundColor: Colors.white,
      title: Row(
        children: [
          const Icon(Icons.lock_clock, color: Colors.red),
          const SizedBox(width: 10),
          Text("Admin Access ($_countdown)", style: const TextStyle(color: Colors.black)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Enter PIN to access menu.", style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 15),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: _onPinChanged,
            style: const TextStyle(color: Colors.black, fontSize: 24, letterSpacing: 5),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'PIN',
              counterText: "",
            ),
            maxLength: 6,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
      ],
    );
  }
}
