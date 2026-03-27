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
import '../utils/device_util.dart';
import '../utils/version_update.dart'; // [Added] Import VersionUpdater
import '../widgets/layout_renderer.dart';
import '../widgets/content_player.dart';
import 'loading_page.dart';
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
  bool _isCheckingLocation = false;
  
  // เก็บ List เพื่อรองรับการเล่นวนหลายไฟล์ใน Location เดียวกัน
  Map<String, List<dynamic>> _activeLocationOverrides = {}; 
  SignageWidget? _activeFullscreenOverride; 

  // Auto Update State
  Timer? _updateCheckTimer;
  bool _isDownloadingUpdate = false;

  // Periodic Restart (clear RAM)
  bool _pendingRestart = false;
  Timer? _restartCheckTimer;

  // Normal Playlist Fullscreen State
  String? _playlistFullscreenId;

  String get _busApiUrl => 'https://public.bussing.app/bus-info/busround-active?busno=${widget.busId}&com_id=${widget.companyId}';

  @override
  void initState() {
    super.initState();
    print("🚀 Player Start: Bus ${widget.busId}, Com ${widget.companyId}");
    
    // 0. เปิด Kiosk Mode (ล็อคปุ่ม Home)
    _setKioskMode(true);

    // 1. Check Location (30s)
    _locationPollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBusLocation());
    _checkBusLocation(); 

    // 2. Check Update (5m)
    _updateCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkForLayoutUpdate());

    // 3. ตั้ง flag restart ทุก 10 นาที (จะ restart จริงเมื่อ playlist ครบรอบ)
    // hard deadline +2 นาที กรณี single-video loop ที่ไม่มี cycle end
    _restartCheckTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (!mounted) return;
      _pendingRestart = true;
      Timer(const Duration(minutes: 2), () {
        if (mounted && _pendingRestart) _onPlaylistCycleComplete();
      });
    });
  }

  @override
  void dispose() {
    // ปลดล็อค Kiosk Mode เมื่อออกจากหน้านี้ (เผื่อกรณีออกด้วยวิธีอื่น)
    _setKioskMode(false);

    _locationPollTimer?.cancel();
    _updateCheckTimer?.cancel();
    _restartCheckTimer?.cancel();
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
    if (_isCheckingLocation) return;
    _isCheckingLocation = true;
    try {
      final response = await http.get(Uri.parse(_busApiUrl));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['status'] == true && json['data'] != null) {
          final locationIdRaw = json['data']['busround_location_now_id'];
          final locationId = locationIdRaw?.toString();
          
          if (locationId != _currentLocationId) {
            print("📍 Location Changed: $_currentLocationId -> $locationId");
            _currentLocationId = locationId;
            _updateContentForLocation(locationId);
          }
        }
      }
    } catch (e) {
      print("⚠️ Location Poll Error: $e");
    } finally {
      _isCheckingLocation = false;
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
  Future<void> _checkForLayoutUpdate() async {
    if (_isDownloadingUpdate) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString('api_base_url');
      final deviceId = await DeviceUtil.getDeviceId();
      if (url == null) return;

      final api = ApiService(url);
      final busConfig = await api.fetchBusConfig(deviceId);

      // ใช้ layout_id ก่อน ถ้าไม่มีค่อยใช้ id (ตรงกับ LoadingPage)
      final serverLayoutId = busConfig['layout_id'] ?? busConfig['id'];
      final int serverVersion = busConfig['layout_version'] ?? 0;

      final bool isDifferentLayout = serverLayoutId.toString() != widget.layout.id;
      final bool isNewerVersion = serverVersion > widget.layout.version;

      if (serverLayoutId != null && (isDifferentLayout || isNewerVersion)) {
        print("📢 Update Found: V.$serverVersion");
        setState(() => _isDownloadingUpdate = true);

        final newLayout = await api.fetchLayoutById(serverLayoutId.toString());
        await PreloadService.manageAssets(newLayout, (_,__,___){});

        await prefs.setString('cached_layout_id', serverLayoutId.toString());
        await prefs.setInt('cached_layout_version', serverVersion);
        await prefs.setString('cached_layout_json', jsonEncode(newLayout.toJson())); // sync cache
        await api.updateBusStatus(widget.busId, serverVersion);

        if (mounted) {
          Navigator.pushReplacement(context, PageRouteBuilder(
            pageBuilder: (_,__,___) => PlayerPage(layout: newLayout, busId: widget.busId, companyId: widget.companyId),
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
  // 3. Restart on Cycle Complete
  // ============================
  void _onPlaylistCycleComplete() {
    if (!_pendingRestart || !mounted) return;
    if (_isDownloadingUpdate) return; // รอ update โหลดเสร็จก่อน
    _pendingRestart = false;
    _restartCheckTimer?.cancel();
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoadingPage(),
        transitionDuration: Duration.zero,
      ),
    );
  }

  // ============================
  // 4. Fullscreen & UI Logic
  // ============================
  void _handleWidgetFullscreen(String widgetId, bool isFull) {
    if (isFull && _playlistFullscreenId != widgetId) {
      setState(() => _playlistFullscreenId = widgetId);
    } else if (!isFull && _playlistFullscreenId == widgetId) {
      setState(() => _playlistFullscreenId = null);
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
       await _setKioskMode(false);
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
      onPopInvoked: (didPop) {
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
                locationOverrides: _activeLocationOverrides,
                fullscreenWidgetId: _playlistFullscreenId,
                onWidgetFullscreen: _handleWidgetFullscreen,
                onCycleComplete: _onPlaylistCycleComplete,
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
                      backgroundColor: Colors.red.withOpacity(0.8),
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
  const _AdminMenuDialog({super.key});

  @override
  State<_AdminMenuDialog> createState() => _AdminMenuDialogState();
}

class _AdminMenuDialogState extends State<_AdminMenuDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _timer;
  int _countdown = 10; 
  bool _isUnlocked = false; // [Added] สถานะปลดล็อค (ถ้าใส่รหัสถูกจะเปลี่ยนหน้า)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });

    // เริ่มนับถอยหลัง 10 วิ (เฉพาะตอนยังไม่ปลดล็อค)
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          if (_isUnlocked) {
             timer.cancel(); // ถ้าปลดล็อคแล้ว ไม่ต้องนับ
             return;
          }

          if (_countdown > 0) {
            _countdown--;
          } else {
            // หมดเวลา -> ปิด Dialog
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
      _timer?.cancel(); // หยุดนับเวลาทันที
      setState(() {
        _isUnlocked = true; // [Key Logic] เปลี่ยนสถานะเป็น Unlock
      });
      // ไม่ต้องสั่ง pop หรือ SystemNavigator.pop() ที่นี่ รอ user กดปุ่มเลือกเอง
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
  style: ButtonStyle(
    padding: WidgetStateProperty.all(const EdgeInsets.symmetric(vertical: 15)),
    foregroundColor: WidgetStateProperty.all(Colors.white),

    // --- 1. จัดการสีพื้นหลัง ---
    backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      // เพิ่ม WidgetState.focused เข้าไปในเงื่อนไข
      if (states.contains(WidgetState.hovered) || 
          states.contains(WidgetState.pressed) || 
          states.contains(WidgetState.focused)) { // <--- สำคัญสำหรับรีโมททีวี
        return Colors.green; 
      }
      return Colors.blue; // สีปกติ
    }),

    // --- 2. จัดการสีเงา (Overlay) ---
    overlayColor: WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) {
        return Colors.green.shade600; 
      }
      return null;
    }),

    // --- 3. จัดการเงา (Elevation) ---
    elevation: WidgetStateProperty.resolveWith<double>((states) {
      if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) {
        return 10.0; // ลอยขึ้นเมื่อโฟกัส
      }
      return 2.0;
    }),

    // --- 4. (แนะนำเพิ่ม) เส้นขอบขาวเมื่อโฟกัส เพื่อให้เห็นชัดบนทีวี ---
    side: WidgetStateProperty.resolveWith<BorderSide>((states) {
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: Colors.white, width: 3); // ขอบขาวหนาๆ
      }
      return BorderSide.none;
    }),
  ),
),
            const SizedBox(height: 15),
            // ปุ่ม Exit App
            ElevatedButton.icon(
  onPressed: () => Navigator.pop(context, 'exit'),
  icon: const Icon(Icons.exit_to_app),
  label: const Text('Exit Application'),
  style: ButtonStyle(
    padding: WidgetStateProperty.all(const EdgeInsets.symmetric(vertical: 15)),
    foregroundColor: WidgetStateProperty.all(Colors.white),
    
    // จัดการสีพื้นหลัง:
    backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      // เพิ่ม WidgetState.focused เข้าไปสำหรับรีโมททีวี
      if (states.contains(WidgetState.hovered) || 
          states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.focused)) { // <--- เพิ่มตรงนี้ครับ
        return Colors.green; 
      }
      // สถานะปกติ -> เป็นสีแดง
      return Colors.red; 
    }),
    
    // (Optional) เพิ่มเส้นขอบตอน Focus ให้ชัดขึ้นไปอีก (Android TV นิยมทำ)
    side: WidgetStateProperty.resolveWith<BorderSide>((states) {
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: Colors.white, width: 3);
      }
      return BorderSide.none;
    }),
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