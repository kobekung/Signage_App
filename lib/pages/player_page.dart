// lib/pages/player_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart'; // [Added] ต้อง import อันนี้
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/layout_model.dart';
import '../services/api_service.dart';
import '../services/preload_service.dart';
import '../utils/device_util.dart';
import '../utils/version_update.dart';
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
  static const platform = MethodChannel('com.example.signage_app/kiosk');

  bool _showControls = false;
  
  // Refresh Key: เอาไว้สั่ง Reload หน้าจอตอนเน็ตมา
  int _refreshKey = 0; 

  // Network State
  StreamSubscription? _netSubscription;

  // Timers
  Timer? _locationPollTimer;
  Timer? _updateCheckTimer;
  
  // Logic State
  String? _currentLocationId; 
  Map<String, List<dynamic>> _activeLocationOverrides = {}; 
  SignageWidget? _activeFullscreenOverride; 
  bool _isDownloadingUpdate = false;
  String? _playlistFullscreenId;

  String get _busApiUrl => 'https://public.bussing.app/bus-info/busround-active?busno=${widget.busId}&com_id=${widget.companyId}';

  @override
  void initState() {
    super.initState();
    print("🚀 Player Start: Bus ${widget.busId}, Com ${widget.companyId}");
    
    _setKioskMode(true);

    // 1. เริ่มฟังสถานะเน็ต (Internet Listener)
    _initConnectivityListener();

    // 2. Timers
    _locationPollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBusLocation());
    _checkBusLocation(); 

    _updateCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkForLayoutUpdate());
  }

  @override
  void dispose() {
    _setKioskMode(false);
    _locationPollTimer?.cancel();
    _updateCheckTimer?.cancel();
    _netSubscription?.cancel(); // อย่าลืม cancel
    super.dispose();
  }

  // ============================
  // 0. Connectivity Logic (New)
  // ============================
  void _initConnectivityListener() {
    _netSubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      // เช็คว่ามีการเชื่อมต่อเน็ตหรือไม่ (WiFi, Mobile, Ethernet)
      bool isConnected = results.any((r) => r != ConnectivityResult.none);
      
      if (isConnected) {
        print("⚡ Internet Restored! Reloading content...");
        
        // 1. เช็คอัปเดตทันที
        _checkForLayoutUpdate();

        // 2. รีโหลดหน้าจอ (เพื่อให้ WebView ที่ค้าง error โหลดใหม่)
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _refreshKey++; // เปลี่ยน Key -> บังคับ Rebuild Widget
            });
          }
        });
      } else {
        print("⚠️ Internet Lost");
      }
    });
  }

  // ============================
  // 1. Kiosk & Location
  // ============================
  Future<void> _setKioskMode(bool enable) async {
    try {
      if (enable) {
        await platform.invokeMethod('startKioskMode');
      } else {
        await platform.invokeMethod('stopKioskMode');
      }
    } on PlatformException catch (e) {
      print("⚠️ Kiosk Mode Error: ${e.message}");
    }
  }

  Future<void> _checkBusLocation() async {
    try {
      // ถ้าไม่มีเน็ต ไม่ต้องยิง API ให้ error เล่น
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none) && connectivity.length == 1) return;

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
          final matchItems = playlist.where((item) => item['locationId'].toString() == locationId).toList();

          if (matchItems.isNotEmpty) {
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
    }

    if (mounted) {
      setState(() {
        _activeLocationOverrides = newOverrides;
        _activeFullscreenOverride = newFullscreen;
      });
    }
  }

  // ============================
  // 2. Auto Update Logic (Robust)
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
      
      final String? cachedJson = prefs.getString('cached_layout_json');
      final int localVersion = widget.layout.version;
      
      // เงื่อนไข: ID เปลี่ยน OR เวอร์ชันใหม่ OR (เวอร์ชันเท่า แต่ Cache หาย)
      final bool isDifferentLayout = serverLayoutId.toString() != widget.layout.id;
      final bool isNewerVersion = serverVersion > localVersion;
      final bool isCacheMissing = (serverVersion == localVersion) && (cachedJson == null || cachedJson.isEmpty);

      if (serverLayoutId != null && (isDifferentLayout || isNewerVersion || isCacheMissing)) {
        print("📢 Update Found: V.$serverVersion (Reloading...)");
        setState(() => _isDownloadingUpdate = true);
        
        // Load & Cache
        final newLayout = await api.fetchLayoutById(serverLayoutId.toString());
        await PreloadService.manageAssets(newLayout, (_,__,___){});
        
        await prefs.setString('cached_layout_json', jsonEncode(newLayout.toJson())); 
        await prefs.setString('cached_layout_id', serverLayoutId.toString());
        await prefs.setInt('cached_layout_version', serverVersion);
        
        await api.updateBusStatus(widget.busId, serverVersion);

        if (mounted) {
          Navigator.pushReplacement(context, PageRouteBuilder(
            pageBuilder: (_,__,___) => PlayerPage(layout: newLayout, busId: widget.busId, companyId: widget.companyId),
            transitionDuration: Duration.zero
          ));
        }
      } else {
        print("✅ Layout is up-to-date.");
      }
    } catch (e) {
      print("⚠️ Auto-update skipped (Offline or Error): $e");
    } finally {
      if (mounted) setState(() => _isDownloadingUpdate = false);
    }
  }

  void _handleWidgetFullscreen(String widgetId, bool isFull) {
    if (isFull && _playlistFullscreenId != widgetId) {
      setState(() => _playlistFullscreenId = widgetId);
    } else if (!isFull && _playlistFullscreenId == widgetId) {
      setState(() => _playlistFullscreenId = null);
    }
  }

  Future<void> _handleAdminMenu() async {
    final String? action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _AdminMenuDialog(),
    );

    if (action == 'exit') {
       await _setKioskMode(false);
       if (mounted) SystemNavigator.pop();
    } else if (action == 'update') {
       if (mounted) await VersionUpdater.checkAndMaybeUpdate(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, 
      onPopInvoked: (didPop) {
        if (didPop) return;
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
                key: ValueKey("main-renderer-$_refreshKey"), // [Key] เปลี่ยนค่าเพื่อ Reload Webview
                layout: widget.layout,
                locationOverrides: _activeLocationOverrides,
                fullscreenWidgetId: _playlistFullscreenId,
                onWidgetFullscreen: _handleWidgetFullscreen,
              ),

              // Location Fullscreen Overlay
              if (_activeFullscreenOverride != null)
                Container(
                  color: Colors.black,
                  child: SizedBox.expand(
                    child: ContentPlayer(
                      key: ValueKey("loc-full-${_currentLocationId}-$_refreshKey"), 
                      widget: _activeFullscreenOverride!,
                      isTriggerMode: false,
                    ),
                  ),
                ),

              // Control Buttons
              if (_showControls)
                Positioned(
                  top: 20, right: 20,
                  child: SafeArea(
                    child: FloatingActionButton(
                      backgroundColor: Colors.red.withOpacity(0.8),
                      child: const Icon(Icons.settings, color: Colors.white),
                      onPressed: () => _handleAdminMenu(),
                    ),
                  ),
                ),
                
               if (_isDownloadingUpdate)
                 Positioned(bottom: 10, left: 10, child: const CircularProgressIndicator(color: Colors.white))
            ],
          ),
        ),
      ),
    );
  }
}

// ... (ส่วน _AdminMenuDialog คงเดิม ไม่ต้องแก้) ...
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

  @override
  Widget build(BuildContext context) {
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
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context, 'update'),
              icon: const Icon(Icons.system_update),
              label: const Text('Check for App Update'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 15),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context, 'exit'),
              icon: const Icon(Icons.exit_to_app),
              label: const Text('Exit Application'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
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