import 'dart:async';
import 'dart:convert'; // [NEW] เพิ่ม Import นี้
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/layout_model.dart';
import '../services/api_service.dart';
import '../services/preload_service.dart';
import '../utils/device_util.dart';
import 'player_page.dart';
import 'setup_page.dart';

class LoadingPage extends StatefulWidget {
  const LoadingPage({super.key});

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  String _status = "Initializing...";
  double _progress = 0.0;
  String? _currentDeviceId;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  // [NEW] ฟังก์ชันสำหรับพยายามเล่นแบบ Offline
  Future<bool> _tryPlayOffline() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? cachedJson = prefs.getString('cached_layout_json');
      
      if (cachedJson != null && cachedJson.isNotEmpty) {
        setState(() => _status = "Offline Mode: Loading cached layout...");
        print("⚠️ Network Error. Loading cached layout...");
        
        final layout = SignageLayout.fromJson(jsonDecode(cachedJson));
        
        if (!mounted) return false;
        // กรณี Offline เราอาจจะไม่มี busId/companyId ล่าสุด ให้ใส่ 0 หรือค่า default ไปก่อน
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PlayerPage(
            layout: layout, busId: 0, companyId: 0
        )));
        return true;
      }
    } catch (e) {
      print("❌ Failed to load offline layout: $e");
    }
    return false;
  }

  Future<void> _start() async {
    final prefs = await SharedPreferences.getInstance();
    
    // ดึง URL
    String? url = prefs.getString('api_base_url');
    if (url == null || url.isEmpty) {
        url = dotenv.env['API_BASE_URL'];
        if (url != null && url.isNotEmpty) {
            await prefs.setString('api_base_url', url);
        }
    }
    
    // ดึง Device ID
    String deviceId = await DeviceUtil.getDeviceId();
    setState(() => _currentDeviceId = deviceId);

    if (url == null || url.isEmpty) {
      if(!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage()));
      return;
    }

    try {
      final api = ApiService(url);
      setState(() => _status = "Connecting...");
      
      // ดึง Config
      Map<String, dynamic> busConfig;
      try {
        busConfig = await api.fetchBusConfig(deviceId);
      } catch (e) {
        // [MODIFIED] ถ้า Error ให้ลองเล่น Offline ก่อน
        if (e.toString().contains("not registered")) {
           _playOfflineOrRetry("Device Not Registered", retrySeconds: 10);
        } else {
           // ลองเล่น Offline ก่อน ถ้าไม่ได้ค่อย Retry
           bool playedOffline = await _tryPlayOffline();
           if (!playedOffline) {
             _playOfflineOrRetry("Connection Failed: $e");
           }
        }
        return;
      }

      final serverLayoutId = busConfig['layout_id'] ?? busConfig['id'];
      final int busId = int.tryParse(busConfig['bus_id'].toString()) ?? 0;
      final int companyId = int.tryParse(busConfig['company_id'].toString()) ?? 0;
      final serverVersion = int.tryParse(busConfig['layout_version'].toString()) ?? 1;

      if (serverLayoutId == null) {
        setState(() => _status = "No layout assigned.\nWaiting for admin...");
        _retryTimer = Timer(const Duration(seconds: 15), _start);
        return;
      }

      final String? localLayoutId = prefs.getString('cached_layout_id');
      final int localVersion = prefs.getInt('cached_layout_version') ?? 0;
      bool needUpdate = (localLayoutId != serverLayoutId.toString()) || (serverVersion > localVersion);
      SignageLayout layout;

      if (needUpdate) {
        setState(() => _status = "Updating Content (v$serverVersion)...");
        layout = await api.fetchLayoutById(serverLayoutId.toString());
        await PreloadService.manageAssets(layout, (file, current, total) {
          if(mounted) setState(() {
            _status = "Downloading $current/$total";
            _progress = total > 0 ? current / total : 0;
          });
        });
        
        // Save Cache
        await prefs.setString('cached_layout_id', serverLayoutId.toString());
        await prefs.setInt('cached_layout_version', serverVersion);
        await prefs.setString('cached_layout_json', jsonEncode(layout.toJson())); // [NEW] บันทึก Layout JSON
        
        await api.updateBusStatus(busId, serverVersion);
      } else {
        setState(() => _status = "Starting Player...");
        layout = await api.fetchLayoutById(serverLayoutId.toString());
        
        // [NEW] บันทึก Layout JSON เผื่อไว้เสมอ (กรณี Cache เก่ายังไม่มี JSON)
        await prefs.setString('cached_layout_json', jsonEncode(layout.toJson()));
      }

      if(!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PlayerPage(
          layout: layout, busId: busId, companyId: companyId
      )));

    } catch (e) {
       print("Critical Error: $e");
       // [MODIFIED] ลองเล่น Offline ในกรณี Error อื่นๆ
       bool playedOffline = await _tryPlayOffline();
       if (!playedOffline) {
          _playOfflineOrRetry(e.toString());
       }
    }
  }

  void _playOfflineOrRetry(String errorMsg, {int retrySeconds = 10}) {
    setState(() => _status = "$errorMsg\nRetrying in ${retrySeconds}s...");
    _retryTimer = Timer(Duration(seconds: retrySeconds), _start);
  }

  @override
  Widget build(BuildContext context) {
    bool showQr = _status.contains("Not Registered") || _status.contains("not registered");

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (showQr && _currentDeviceId != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10)
                    ),
                    child: QrImageView(
                      data: _currentDeviceId!,
                      version: QrVersions.auto,
                      size: 200.0,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SelectableText(
                    "ID: $_currentDeviceId",
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                ] else ...[
                  CircularProgressIndicator(value: _progress > 0 ? _progress : null, color: Colors.white),
                ],

                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Text(
                    _status, 
                    textAlign: TextAlign.center, 
                    style: TextStyle(
                      color: showQr ? Colors.redAccent : Colors.white70,
                      fontSize: 16
                    )
                  ),
                ),
              ],
            ),
          ),
          
          Positioned(
            top: 0, right: 0,
            child: GestureDetector(
              onDoubleTap: () {
                 _retryTimer?.cancel();
                 Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage()));
              },
              child: Container(width: 80, height: 80, color: Colors.transparent),
            ),
          )
        ],
      ),
    );
  }
}