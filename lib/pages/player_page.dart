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
  bool _showControls = false;

  // Location Override State
  Timer? _locationPollTimer;
  String? _currentLocationId; 
  
  // [UPDATED] เปลี่ยน Value เป็น List เพื่อรองรับหลาย Item
  Map<String, List<dynamic>> _activeLocationOverrides = {}; 
  SignageWidget? _activeFullscreenOverride; 

  Timer? _updateCheckTimer;
  bool _isDownloadingUpdate = false;
  String? _playlistFullscreenId;

  String get _busApiUrl => 'https://public.bussing.app/bus-info/busround-active?busno=${widget.busId}&com_id=${widget.companyId}';
  // String get _busApiUrl => 'https://public.bussing.app/bus-info/busround-active?busno=10&com_id=4';

  @override
  void initState() {
    super.initState();
    print("🚀 Player Start: Bus ${widget.busId}, Com ${widget.companyId}");
    
    _locationPollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBusLocation());
    _checkBusLocation(); 

    _updateCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkForLayoutUpdate());
  }

  @override
  void dispose() {
    _locationPollTimer?.cancel();
    _updateCheckTimer?.cancel();
    super.dispose();
  }

  // ============================
  // 1. Location Logic (Updated for Multiple Items)
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
          
          // [FIX] ใช้ where เพื่อดึง "ทุกตัว" ที่ตรงกับ Location นี้ (ไม่ใช่แค่ตัวแรก)
          final matchItems = playlist.where(
            (item) => item['locationId'].toString() == locationId
          ).toList();

          if (matchItems.isNotEmpty) {
            print("✨ Location Match! Widget: ${widget.id}, Items: ${matchItems.length}");
            
            // แยกกรณี Fullscreen กับ In-Place
            final fullscreenItems = matchItems.where((i) => i['fullscreen'] == true).toList();
            final normalItems = matchItems.where((i) => i['fullscreen'] != true).toList();

            // ถ้ามีรายการที่เป็น Fullscreen ให้สร้าง Widget ครอบ
            if (fullscreenItems.isNotEmpty) {
               newFullscreen = SignageWidget(
                  id: "loc-full-$locationId", 
                  type: widget.type,
                  x: 0, y: 0, width: 0, height: 0,
                  // ส่ง playlist เป็น List ของ items ทั้งหมดที่เจอ
                  properties: { ...props, 'playlist': fullscreenItems, 'url': null }
               );
            }
            
            // ถ้ามีรายการปกติ ให้เก็บลง Map ไว้ส่งให้ Renderer
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
  // 2. Auto Update Logic (Same as before)
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
        onTap: () {
          setState(() => _showControls = !_showControls);
          if (_showControls) Future.delayed(const Duration(seconds: 3), () { if(mounted) setState(() => _showControls = false); });
        },
        child: Stack(
          children: [
            LayoutRenderer(
              layout: widget.layout,
              locationOverrides: _activeLocationOverrides,
              fullscreenWidgetId: _playlistFullscreenId,
              onWidgetFullscreen: _handleWidgetFullscreen,
            ),

            if (_activeFullscreenOverride != null)
              Container(
                color: Colors.black,
                child: SizedBox.expand(
                  child: ContentPlayer(
                    key: ValueKey("loc-full-${_currentLocationId}"), 
                    widget: _activeFullscreenOverride!,
                    isTriggerMode: false, // Loop playlist
                  ),
                ),
              ),

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
              
             if (_isDownloadingUpdate)
               Positioned(bottom: 10, left: 10, child: const CircularProgressIndicator(color: Colors.white))
          ],
        ),
      ),
    );
  }
}