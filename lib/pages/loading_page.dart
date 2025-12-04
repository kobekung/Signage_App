import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // [NEW] Import
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

  Future<void> _start() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. ลองดึง URL จากเครื่อง
    String? url = prefs.getString('api_base_url');
    
    // [NEW] ถ้าไม่มีในเครื่อง ให้ดึงจาก .env แล้วบันทึกลงเครื่องเลย (Auto Setup)
    if (url == null || url.isEmpty) {
        url = dotenv.env['API_BASE_URL'];
        if (url != null && url.isNotEmpty) {
            print("⚙️ Auto-Setup: Found URL in .env: $url");
            await prefs.setString('api_base_url', url);
        }
    }
    
    // ดึง Device ID
    String deviceId = await DeviceUtil.getDeviceId();
    // ถ้าได้ค่า 'unknown...' ให้ลองเอาจากที่เคยเซฟไว้ (เผื่อเครื่องมีปัญหาชั่วคราว)
    if (deviceId.contains('unknown') || deviceId.contains('failed')) {
         deviceId = prefs.getString('device_id') ?? deviceId;
    } else {
         // ถ้าได้ค่าจริง ให้บันทึกทับไปเลย
         await prefs.setString('device_id', deviceId);
    }

    // ถ้าสุดท้ายแล้วยังไม่มี URL (เช่น ลืมใส่ใน .env) ค่อยไปหน้า Setup
    if (url == null || url.isEmpty) {
      if(!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage()));
      return;
    }

    try {
      final api = ApiService(url);
      setState(() => _status = "Connecting ($deviceId)...");
      
      // 1. ดึง Config
      Map<String, dynamic> busConfig;
      try {
        busConfig = await api.fetchBusConfig(deviceId);
        print("✅ Bus Config: $busConfig");
      } catch (e) {
        print("Fetch Config Error: $e");
        _playOfflineOrRetry("Connection Failed: $e");
        return;
      }

      final serverLayoutId = busConfig['layout_id'] ?? busConfig['id'];
      final int busId = int.tryParse(busConfig['bus_id'].toString()) ?? 0;
      final int companyId = int.tryParse(busConfig['company_id'].toString()) ?? 0;
      final serverVersion = int.tryParse(busConfig['layout_version'].toString()) ?? 1;

      if (serverLayoutId == null) {
        // ยังไม่ผูก Layout -> รอ 15 วิ แล้วเช็คใหม่ (Auto Retry)
        setState(() => _status = "No layout assigned.\nWaiting for admin...");
        _retryTimer = Timer(const Duration(seconds: 15), _start);
        return;
      }

      // 2. เปรียบเทียบ Cache
      final String? localLayoutId = prefs.getString('cached_layout_id');
      final int localVersion = prefs.getInt('cached_layout_version') ?? 0;
      
      bool needUpdate = (localLayoutId != serverLayoutId.toString()) || (serverVersion > localVersion);

      SignageLayout layout;

      if (needUpdate) {
        // โหลดใหม่
        setState(() => _status = "Updating Content (v$serverVersion)...");
        layout = await api.fetchLayoutById(serverLayoutId.toString());
        
        await PreloadService.preloadAssets(layout, (file, current, total) {
          if(mounted) setState(() {
            _status = "Downloading $current/$total";
            _progress = total > 0 ? current / total : 0;
          });
        });

        await prefs.setString('cached_layout_id', serverLayoutId.toString());
        await prefs.setInt('cached_layout_version', serverVersion);
        await api.updateBusStatus(busId, serverVersion);
      } else {
        // ของเดิม
        setState(() => _status = "Starting Player...");
        layout = await api.fetchLayoutById(serverLayoutId.toString());
      }

      if(!mounted) return;
      
      Navigator.pushReplacement(
        context, 
        MaterialPageRoute(builder: (_) => PlayerPage(
          layout: layout,
          busId: busId,
          companyId: companyId
        ))
      );

    } catch (e) {
       print("Critical Error: $e");
       _playOfflineOrRetry(e.toString());
    }
  }

  void _playOfflineOrRetry(String errorMsg) {
    // สำหรับ TV: ให้ Auto Retry ตลอดไป
    setState(() => _status = "Error: $errorMsg\nRetrying in 10s...");
    _retryTimer = Timer(const Duration(seconds: 10), _start);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(value: _progress > 0 ? _progress : null, color: Colors.white),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Text(
                    _status, 
                    textAlign: TextAlign.center, 
                    style: const TextStyle(color: Colors.white70)
                  ),
                ),
              ],
            ),
          ),
          
          // [Hidden Button] ปุ่มลับสำหรับกดไปหน้า Setup (เผื่อเทส)
          // แตะที่มุมขวาบนของจอ
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onDoubleTap: () => Navigator.pushReplacement(
                  context, MaterialPageRoute(builder: (_) => const SetupPage())),
              child: Container(
                width: 80, 
                height: 80, 
                color: Colors.transparent, // มองไม่เห็น
              ),
            ),
          )
        ],
      ),
    );
  }
}