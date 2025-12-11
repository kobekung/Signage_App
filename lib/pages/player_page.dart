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
    _updateCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkForLayoutUpdate());
  }

  @override
  void dispose() {
    // ปลดล็อค Kiosk Mode เมื่อออกจากหน้านี้ (เผื่อกรณีออกด้วยวิธีอื่น)
    _setKioskMode(false);

    _locationPollTimer?.cancel();
    _updateCheckTimer?.cancel();
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
      
      final serverLayoutId = busConfig['id'];
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
  // 3. Fullscreen & UI Logic
  // ============================
  void _handleWidgetFullscreen(String widgetId, bool isFull) {
    if (isFull && _playlistFullscreenId != widgetId) {
      setState(() => _playlistFullscreenId = widgetId);
    } else if (!isFull && _playlistFullscreenId == widgetId) {
      setState(() => _playlistFullscreenId = null);
    }
  }

  // ฟังก์ชันแสดง Dialog ใส่รหัส
  void _showExitPinDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _PinExitDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ใช้ PopScope ดักปุ่ม Back
    return PopScope(
      canPop: false, 
      onPopInvoked: (didPop) {
        if (didPop) return;
        // เมื่อกด Back (หรือปุ่มรีโมท) ให้เรียก Dialog
        _showExitPinDialog();
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

              // Control Buttons (Close App)
              if (_showControls)
                Positioned(
                  top: 20, right: 20,
                  child: SafeArea(
                    child: FloatingActionButton(
                      backgroundColor: Colors.red.withOpacity(0.8),
                      child: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => _showExitPinDialog(), // เรียก Dialog เหมือนกัน
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
// 🔐 PIN Exit Dialog Widget
// ==========================================
class _PinExitDialog extends StatefulWidget {
  const _PinExitDialog({super.key});

  @override
  State<_PinExitDialog> createState() => _PinExitDialogState();
}

class _PinExitDialogState extends State<_PinExitDialog> {
  static const platform = MethodChannel('com.example.signage_app/kiosk');

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _timer;
  int _countdown = 10; 

  @override
  void initState() {
    super.initState();
    // Auto Focus ให้พิมพ์ได้เลย
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });

    // เริ่มนับถอยหลัง 10 วิ
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          if (_countdown > 0) {
            _countdown--;
          } else {
            // หมดเวลา -> ปิด Dialog (ยกเลิกการออก)
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

  void _onPinChanged(String value) async {
    if (value == '000000') { 
      _timer?.cancel();
      
      // 1. ปลดล็อค Kiosk Mode ก่อนออก (สำคัญมาก!)
      try {
        await platform.invokeMethod('stopKioskMode');
      } catch (e) {
        print("Error stopping kiosk mode: $e");
      }

      // 2. ปิดแอป
      if (mounted) {
        SystemNavigator.pop(); 
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      title: Row(
        children: [
          const Icon(Icons.lock_clock, color: Colors.red),
          const SizedBox(width: 10),
          Text("Exit App? ($_countdown)", style: const TextStyle(color: Colors.black)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Enter PIN '000000' to exit.", style: TextStyle(color: Colors.black54)),
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