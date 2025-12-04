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

  // Location Trigger State
  Timer? _locationPollTimer;
  int? _lastLocationId;
  Map<String, dynamic> _activeInPlaceTriggers = {}; 
  SignageWidget? _activeFullscreenWidget; 

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
    
    // 1. Check Location (30s)
    _locationPollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBusLocation());
    _checkBusLocation(); 

    // 2. Check Update (5m)
    _updateCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkForLayoutUpdate());
  }

  @override
  void dispose() {
    _locationPollTimer?.cancel();
    _updateCheckTimer?.cancel();
    super.dispose();
  }

  // ============================
  // 1. Location Trigger Logic
  // ============================
  Future<void> _checkBusLocation() async {
    try {
      final response = await http.get(Uri.parse(_busApiUrl));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['status'] == true && json['data'] != null) {
          final locationId = json['data']['busround_location_now_id'];
          
          if (locationId != null && locationId != _lastLocationId) {
            print("📍 Bus Location Change: $locationId");
            _lastLocationId = locationId;
            _findAndTriggerContent(locationId.toString());
          }
        }
      }
    } catch (e) {
      print("⚠️ Location Poll Error: $e");
    }
  }

  void _findAndTriggerContent(String locationId) {
    Map<String, dynamic> newInPlaceTriggers = {};
    SignageWidget? newFullscreenWidget;

    for (final widget in widget.layout.widgets) {
      final props = widget.properties;
      if (props['playlist'] is List) {
        final playlist = props['playlist'] as List;
        final matchItem = playlist.firstWhere(
          (item) => item['locationId'].toString() == locationId, 
          orElse: () => null
        );

        if (matchItem != null) {
          print("✨ Trigger! Widget: ${widget.id}, Fullscreen: ${matchItem['fullscreen']}");
          
          if (matchItem['fullscreen'] == true) {
             newFullscreenWidget = SignageWidget(
                id: "trigger-full-${DateTime.now().millisecondsSinceEpoch}",
                type: widget.type,
                x: 0, y: 0, width: 0, height: 0,
                properties: { ...props, 'playlist': [matchItem], 'url': null }
             );
          } else {
            newInPlaceTriggers[widget.id] = matchItem;
          }
        }
      }
    }

    if (mounted) {
      setState(() {
        _activeInPlaceTriggers = newInPlaceTriggers;
        _activeFullscreenWidget = newFullscreenWidget;
      });
    }
  }

  void _onInPlaceFinished(String widgetId) {
    if (mounted) setState(() => _activeInPlaceTriggers.remove(widgetId));
  }

  void _onFullscreenTriggerFinished() {
    if (mounted) setState(() => _activeFullscreenWidget = null);
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
        await PreloadService.preloadAssets(newLayout, (_,__,___){});
        
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
  // 3. Playlist Fullscreen Logic
  // ============================
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
            // Main Layout Renderer
            LayoutRenderer(
              layout: widget.layout,
              inPlaceTriggers: _activeInPlaceTriggers,
              onInPlaceFinished: _onInPlaceFinished,
              fullscreenWidgetId: _playlistFullscreenId,
              onWidgetFullscreen: _handleWidgetFullscreen,
            ),

            // Trigger Fullscreen Overlay
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

            // Close Button
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
              
             // Update Loading Indicator
             if (_isDownloadingUpdate)
               Positioned(bottom: 10, left: 10, child: const CircularProgressIndicator(color: Colors.white))
          ],
        ),
      ),
    );
  }
}