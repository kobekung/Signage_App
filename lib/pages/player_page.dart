import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
  // --- State สำหรับ Controls ---
  bool _showControls = false;

  // --- State สำหรับ Location Trigger ---
  Timer? _locationPollTimer;
  int? _lastLocationId;
  Map<String, dynamic> _activeInPlaceTriggers = {}; // เก็บ Trigger ที่แสดงในกรอบเดิม
  SignageWidget? _activeFullscreenWidget; // เก็บ Trigger ที่แสดงเต็มจอ

  // --- State สำหรับ Auto Update ---
  Timer? _updateCheckTimer;
  bool _isDownloadingUpdate = false;

  // --- State สำหรับ Normal Playlist Fullscreen ---
  String? _playlistFullscreenId;

  // URL API แบบ Dynamic
  String get _busApiUrl => 'https://public.bussing.app/bus-info/busround-active?busno=${widget.busId}&com_id=${widget.companyId}';

  @override
  void initState() {
    super.initState();
    print("🚀 Player Started | Bus: ${widget.busId} | Com: ${widget.companyId} | Ver: ${widget.layout.version}");

    // 1. เริ่มเช็คตำแหน่งรถ (ทุก 30 วินาที)
    _locationPollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBusLocation());
    _checkBusLocation(); // เช็คครั้งแรกทันที

    // 2. เริ่มเช็คเวอร์ชัน Layout (ทุก 5 นาที)
    _updateCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkForLayoutUpdate());
  }

  @override
  void dispose() {
    _locationPollTimer?.cancel();
    _updateCheckTimer?.cancel();
    super.dispose();
  }

  // ====================================================
  // 📍 ZONE: Location Trigger Logic
  // ====================================================
  Future<void> _checkBusLocation() async {
    try {
      final response = await http.get(Uri.parse(_busApiUrl));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['status'] == true && json['data'] != null) {
          final locationId = json['data']['busround_location_now_id'];
          
          // ถ้า Location เปลี่ยน หรือเพิ่งเริ่ม
          if (locationId != null && locationId != _lastLocationId) {
            print("📍 Bus reached location: $locationId");
            _lastLocationId = locationId;
            _findAndTriggerContent(locationId.toString());
          }
        }
      }
    } catch (e) {
      print("⚠️ Polling Error: $e");
    }
  }

  void _findAndTriggerContent(String locationId) {
    Map<String, dynamic> newInPlaceTriggers = {};
    SignageWidget? newFullscreenWidget;

    // วนหาในทุก Widget -> ทุก Playlist Item
    for (final widget in widget.layout.widgets) {
      final props = widget.properties;
      if (props['playlist'] is List) {
        final playlist = props['playlist'] as List;
        
        // หา Item ที่มี locationId ตรงกัน
        final matchItem = playlist.firstWhere(
          (item) => item['locationId'].toString() == locationId, 
          orElse: () => null
        );

        if (matchItem != null) {
          print("✨ Trigger Found on Widget ${widget.id}: Item URL ${matchItem['url']}");
          
          if (matchItem['fullscreen'] == true) {
            // สร้าง Widget จำลองสำหรับ Fullscreen Overlay
             newFullscreenWidget = SignageWidget(
                id: "trigger-full-${DateTime.now().millisecondsSinceEpoch}",
                type: widget.type,
                x: 0, y: 0, width: 0, height: 0,
                properties: {
                  ...props,
                  'playlist': [matchItem], // บังคับเล่นแค่ตัวนี้
                  'url': null
                }
             );
          } else {
            // เก็บลง Map สำหรับ In-Place
            newInPlaceTriggers[widget.id] = matchItem;
          }
        }
      }
    }

    // อัปเดต State
    if (newInPlaceTriggers.isNotEmpty || newFullscreenWidget != null) {
      if (mounted) {
        setState(() {
          if (newInPlaceTriggers.isNotEmpty) {
             _activeInPlaceTriggers = newInPlaceTriggers;
          }
          if (newFullscreenWidget != null) {
             _activeFullscreenWidget = newFullscreenWidget;
          }
        });
      }
    }
  }

  void _onInPlaceFinished(String widgetId) {
    if (mounted) {
      setState(() {
        _activeInPlaceTriggers.remove(widgetId);
      });
    }
  }

  void _onFullscreenTriggerFinished() {
    if (mounted) {
      setState(() {
        _activeFullscreenWidget = null;
      });
    }
  }

  // ====================================================
  // 🔄 ZONE: Auto Update Logic
  // ====================================================
  Future<void> _checkForLayoutUpdate() async {
    if (_isDownloadingUpdate) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString('api_base_url');
      final deviceId = await DeviceUtil.getDeviceId();
      
      if (url == null) return;

      final api = ApiService(url);
      final busConfig = await api.fetchBusConfig(deviceId);
      
      final serverLayoutId = busConfig['layout_id'];
      final int serverVersion = busConfig['layout_version'] ?? 0;
      
      // เปรียบเทียบ Version
      final bool isDifferentLayout = serverLayoutId.toString() != widget.layout.id;
      final bool isNewerVersion = serverVersion > widget.layout.version;

      if (serverLayoutId != null && (isDifferentLayout || isNewerVersion)) {
        print("📢 Update Found! V.$serverVersion (Current: V.${widget.layout.version})");
        _performBackgroundUpdate(api, serverLayoutId.toString(), serverVersion);
      }
    } catch (e) {
      print("⚠️ Auto-update check failed: $e");
    }
  }

  Future<void> _performBackgroundUpdate(ApiService api, String layoutId, int version) async {
    setState(() => _isDownloadingUpdate = true);

    try {
      // 1. โหลด Layout ใหม่
      final newLayout = await api.fetchLayoutById(layoutId);

      // 2. โหลดไฟล์ (Background)
      await PreloadService.preloadAssets(newLayout, (file, current, total) {
         // print("Background Downloading: $current/$total");
      });

      // 3. บันทึก Cache
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cached_layout_id', layoutId);
      await prefs.setInt('cached_layout_version', version);

      // 4. แจ้ง Server
      await api.updateBusStatus(widget.busId, version);

      // 5. Reload Page
      if (mounted) {
        print("🚀 Switching to new layout version...");
        Navigator.pushReplacement(
          context, 
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => PlayerPage(
              layout: newLayout,
              busId: widget.busId,
              companyId: widget.companyId
            ),
            transitionDuration: Duration.zero,
          )
        );
      }
    } catch (e) {
      print("❌ Background update failed: $e");
    } finally {
      if (mounted) setState(() => _isDownloadingUpdate = false);
    }
  }

  // ====================================================
  // 📺 ZONE: UI & Rendering
  // ====================================================
  
  // Callback จาก Playlist ปกติที่ขอ Fullscreen
  void _handleWidgetFullscreen(String widgetId, bool isFull) {
    if (isFull && _playlistFullscreenId != widgetId) {
      setState(() => _playlistFullscreenId = widgetId);
    } else if (!isFull && _playlistFullscreenId == widgetId) {
      setState(() => _playlistFullscreenId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // แตะหน้าจอเพื่อโชว์ปุ่มออก
        onTap: () {
          setState(() => _showControls = !_showControls);
          if (_showControls) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) setState(() => _showControls = false);
            });
          }
        },
        child: Stack(
          children: [
            // 1. Main Layout Renderer (จัดการ In-Place และ Normal Fullscreen)
            LayoutRenderer(
              layout: widget.layout,
              
              // Trigger Props
              inPlaceTriggers: _activeInPlaceTriggers,
              onInPlaceFinished: _onInPlaceFinished,
              
              // Normal Fullscreen Props
              fullscreenWidgetId: _playlistFullscreenId,
              onWidgetFullscreen: _handleWidgetFullscreen,
            ),

            // 2. Trigger Overlay (ทับสูงสุด เมื่อมี Trigger แบบ Fullscreen)
            if (_activeFullscreenWidget != null)
              Container(
                color: Colors.black,
                child: SizedBox.expand(
                  child: ContentPlayer(
                    widget: _activeFullscreenWidget!,
                    isTriggerMode: true,
                    onFinished: _onFullscreenTriggerFinished,
                  ),
                ),
              ),

            // 3. ปุ่มลับ Exit (มุมขวาบน)
            if (_showControls)
              Positioned(
                top: 20,
                right: 20,
                child: SafeArea(
                  child: FloatingActionButton(
                    backgroundColor: Colors.red.withOpacity(0.8),
                    child: const Icon(Icons.close, color: Colors.white),
                    onPressed: () {
                      Navigator.pushReplacement(
                        context, 
                        MaterialPageRoute(builder: (_) => const SetupPage())
                      );
                    },
                  ),
                ),
              ),
              
            // 4. Loading Indicator เล็กๆ มุมซ้ายล่าง (ตอนโหลดอัปเดต)
            if (_isDownloadingUpdate)
              Positioned(
                bottom: 10,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20)
                  ),
                  child: const Row(
                    children: [
                      SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                      SizedBox(width: 8),
                      Text("Updating...", style: TextStyle(color: Colors.white, fontSize: 10))
                    ],
                  ),
                ),
              )
          ],
        ),
      ),
    );
  }
}