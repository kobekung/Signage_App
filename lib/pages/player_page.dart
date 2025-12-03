import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signage_app/services/api_service.dart';
import 'package:signage_app/services/preload_service.dart';
import '../models/layout_model.dart';
import '../widgets/layout_renderer.dart'; // เราจะแก้ไฟล์นี้ต่อ
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
  bool _showControls = false;
  Timer? _pollTimer;
  int? _lastLocationId;
  Timer? _updateCheckTimer;
  bool _isDownloadingBackground = false;
  
  // [NEW] เก็บ Trigger แบบ In-Place (Map<WidgetID, ItemData>)
  Map<String, dynamic> _activeInPlaceTriggers = {};
  
  // เก็บ Trigger แบบ Fullscreen (มีตัวเดียวพอ เพราะเต็มจอทับหมด)
  SignageWidget? _activeFullscreenWidget;
  Map<String, dynamic>? _activeFullscreenItem;

  // [NEW] สร้าง URL แบบ Dynamic
  String get _busApiUrl => 'https://public.bussing.app/bus-info/busround-active?busno=${widget.busId}&com_id=${widget.companyId}';
  // String get _busApiUrl => 'https://public.bussing.app/bus-info/busround-active?busno=9&com_id=4';

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBusLocation());
    _checkBusLocation();
    _updateCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkForUpdate());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // รับ Callback การขอ Fullscreen จาก Playlist ปกติ
  String? _playlistFullscreenId;
  void _handleWidgetFullscreen(String widgetId, bool isFull) {
    if (isFull && _playlistFullscreenId != widgetId) {
      setState(() => _playlistFullscreenId = widgetId);
    } else if (!isFull && _playlistFullscreenId == widgetId) {
      setState(() => _playlistFullscreenId = null);
    }
  }
  Future<void> _checkForUpdate() async {
    if (_isDownloadingBackground) return; // ถ้ากำลังโหลดอยู่ อย่าเพิ่งเช็คซ้ำ

    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString('api_base_url');
      final deviceId = prefs.getString('device_id');
      
      if (url == null || deviceId == null) return;

      final api = ApiService(url);
      final busConfig = await api.fetchBusConfig(deviceId); // เช็ค Config ล่าสุด

      final serverVersion = busConfig['layout_version'] ?? 0;
      final serverLayoutId = busConfig['layout_id'];
      
      // เทียบกับเวอร์ชันปัจจุบันที่เล่นอยู่ (จาก widget.layout.version)
      if (serverLayoutId != null && serverVersion > widget.layout.version) {
        print("New version found: $serverVersion (Current: ${widget.layout.version})");
        _performBackgroundUpdate(api, serverLayoutId.toString(), serverVersion, busConfig['bus_id']);
      }
    } catch (e) {
      print("Auto update check failed: $e");
    }
  }

  Future<void> _performBackgroundUpdate(ApiService api, String layoutId, int newVersion, int busId) async {
    setState(() => _isDownloadingBackground = true);

    try {
      // 1. โหลด Layout ใหม่มา (เบื้องหลัง)
      final newLayout = await api.fetchLayoutById(layoutId);
      
      // 2. โหลดไฟล์ Media ลงเครื่อง (เบื้องหลัง)
      await PreloadService.preloadAssets(newLayout, (file, current, total) {
         print("Background Downloading: $current/$total");
      });

      // 3. แจ้ง Server ว่าอัปเดตเสร็จแล้ว! (สำคัญ)
      await api.updateBusStatus(busId, newVersion);
      
      // 4. สลับหน้าจอไปเล่น Layout ใหม่ทันที
      if (mounted) {
        Navigator.pushReplacement(
          context, 
          MaterialPageRoute(builder: (_) => PlayerPage(
            layout: newLayout, // ใช้ตัวใหม่
            busId: widget.busId, 
            companyId: widget.companyId
          ))
        );
      }
    } catch (e) {
      print("Background update failed: $e");
    } finally {
      setState(() => _isDownloadingBackground = false);
    }
  }

  Future<void> _checkBusLocation() async {
    try {
      final response = await http.get(Uri.parse(_busApiUrl));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['status'] == true && json['data'] != null) {
          final locationId = json['data']['busround_location_now_id'];
          
          if (locationId != null && locationId != _lastLocationId) {
            print("Bus reached location: $locationId");
            _lastLocationId = locationId;
            _findAndTriggerContent(locationId.toString());
          }
        }
      }
    } catch (e) {
      print("Polling Error: $e");
    }
  }

  void _findAndTriggerContent(String locationId) {
    // ตัวแปรชั่วคราวเก็บ Trigger รอบนี้
    Map<String, dynamic> newInPlaceTriggers = {};
    SignageWidget? newFullscreenWidget;
    Map<String, dynamic>? newFullscreenItem;

    for (final widget in widget.layout.widgets) {
      final props = widget.properties;
      if (props['playlist'] is List) {
        final playlist = props['playlist'] as List;
        
        // หา Item ที่ตรงกับ Location นี้
        final matchItem = playlist.firstWhere(
          (item) => item['locationId'].toString() == locationId, 
          orElse: () => null
        );

        if (matchItem != null) {
          print("Trigger Found on Widget ${widget.id}: Item ${matchItem['id']}");
          
          if (matchItem['fullscreen'] == true) {
            // กรณี Fullscreen: สร้าง Widget จำลองสำหรับ Overlay
             newFullscreenItem = matchItem;
             newFullscreenWidget = SignageWidget(
                id: "trigger-full-${DateTime.now().millisecondsSinceEpoch}",
                type: widget.type,
                x: 0, y: 0, width: 0, height: 0,
                properties: {
                  ...props,
                  'playlist': [matchItem],
                  'url': null
                }
             );
          } else {
            // กรณี In-Place: เก็บลง Map เพื่อส่งให้ LayoutRenderer
            newInPlaceTriggers[widget.id] = matchItem;
          }
        }
      }
    }

    // อัปเดต State ทีเดียว
    if (newInPlaceTriggers.isNotEmpty || newFullscreenWidget != null) {
      if (mounted) {
        setState(() {
          _activeInPlaceTriggers = newInPlaceTriggers;
          _activeFullscreenWidget = newFullscreenWidget;
          _activeFullscreenItem = newFullscreenItem;
        });
      }
    }
  }

  // Callback เมื่อ In-Place Trigger เล่นจบ
  void _onInPlaceFinished(String widgetId) {
    if (mounted) {
      setState(() {
        _activeInPlaceTriggers.remove(widgetId); // ลบออกจาก Map กลับไปเล่นปกติ
      });
    }
  }

  // Callback เมื่อ Fullscreen Trigger เล่นจบ
  void _onFullscreenFinished() {
    if (mounted) {
      setState(() {
        _activeFullscreenWidget = null;
        _activeFullscreenItem = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
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
            // 1. Main Layout
            LayoutRenderer(
              layout: widget.layout,
              
              // ส่งข้อมูล Trigger แบบ In-Place ไปให้วาด
              inPlaceTriggers: _activeInPlaceTriggers,
              onInPlaceFinished: _onInPlaceFinished,
              
              // ข้อมูล Fullscreen ปกติ (ที่ไม่ใช่ Trigger)
              fullscreenWidgetId: _playlistFullscreenId,
              onWidgetFullscreen: _handleWidgetFullscreen,
            ),

            // 2. Trigger Fullscreen Overlay (ทับทุกอย่าง)
            if (_activeFullscreenWidget != null)
              _buildFullscreenOverlay(),

            // 3. ปุ่มย้อนกลับ
            if (_showControls)
              Positioned(
                top: 20, right: 20,
                child: SafeArea(
                  child: FloatingActionButton(
                    backgroundColor: Colors.red.withOpacity(0.8),
                    child: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage())),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullscreenOverlay() {
    return Container(
      color: Colors.black,
      child: SizedBox.expand(
        child: ContentPlayer(
          widget: _activeFullscreenWidget!,
          isTriggerMode: true,
          onFinished: _onFullscreenFinished,
        ),
      ),
    );
  }
}