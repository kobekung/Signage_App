import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/layout_model.dart';
import '../services/api_service.dart';
import '../services/preload_service.dart';
import '../utils/device_util.dart'; // [NEW]
import 'player_page.dart';
import 'setup_page.dart';

class LoadingPage extends StatefulWidget {
  const LoadingPage({super.key});

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  String _status = "Starting...";
  double _progress = 0.0;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _checkAndUpdate();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkAndUpdate() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('api_base_url');
    
    // 1. ดึง Device ID สดๆ
    final deviceId = await DeviceUtil.getDeviceId();

    if (url == null) {
      if(!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage()));
      return;
    }

    try {
      final api = ApiService(url);

      // 2. เช็ค Config จาก Server
      setState(() => _status = "Checking for updates...");
      
      // สมมติ API: /buses/device/:id -> returns { "id": 1, "layout_id": 5, "updated_at": "2023-10-10T12:00:00Z" }
      Map<String, dynamic> busConfig;
      try {
        busConfig = await api.fetchBusConfig(deviceId);
      } catch (e) {
        // ถ้าต่อเน็ตไม่ได้ หรือ Server ล่ม -> ให้ลองเล่นของเก่า (Offline Mode)
        print("Network Error: $e");
        _playOfflineOrRetry(e.toString());
        return;
      }

      final serverLayoutId = busConfig['id']; // layout_id
      final serverUpdatedAt = busConfig['updated_at'];

      if (serverLayoutId == null) {
        setState(() => _status = "No layout assigned.\nDevice ID: $deviceId");
        _retryTimer = Timer(const Duration(seconds: 15), _checkAndUpdate);
        return;
      }

      // 3. เปรียบเทียบกับของเดิมในเครื่อง
      final localLayoutId = prefs.getString('cached_layout_id');
      final localUpdatedAt = prefs.getString('cached_updated_at');

      bool needUpdate = (localLayoutId != serverLayoutId.toString()) || 
                        (localUpdatedAt != serverUpdatedAt);

      if (needUpdate) {
        // === กรณีมีอัปเดต ===
        setState(() => _status = "New layout found. Downloading...");
        
        final layout = await api.fetchLayoutById(serverLayoutId.toString());
        
        await PreloadService.preloadAssets(layout, (file, current, total) {
          if(mounted) {
            setState(() {
              _status = "Syncing Media ($current/$total)";
              _progress = total > 0 ? current / total : 0;
            });
          }
        });

        // บันทึกสถานะล่าสุดเก็บไว้
        await prefs.setString('cached_layout_id', serverLayoutId.toString());
        await prefs.setString('cached_updated_at', serverUpdatedAt.toString());
        
        // บันทึก JSON ของ Layout เก็บไว้ด้วย (เผื่อ Offline คราวหน้า)
        // (ถ้าจะทำสมบูรณ์ ต้องแก้ model ให้มี toJson แต่ตอนนี้โหลดใหม่เอาก็ได้ถ้าระบบเน้น online)
        
        _goToPlayer(layout);

      } else {
        // === กรณีไม่มีอัปเดต (ใช้ของเดิม) ===
        setState(() => _status = "Up to date. Starting...");
        final layout = await api.fetchLayoutById(serverLayoutId.toString());
        // จริงๆ ควรโหลด JSON จาก local storage ถ้าจะ offline 100%
        // แต่ขั้นต้น ดึง JSON ใหม่ (เบาๆ) แต่ไฟล์ Media ใช้ Cache เดิมได้เลย
        
        _goToPlayer(layout);
      }

    } catch (e) {
       _playOfflineOrRetry(e.toString());
    }
  }

  void _playOfflineOrRetry(String errorMsg) {
    // TODO: ถ้ามีระบบ Save JSON ลงเครื่อง ให้โหลดจากไฟล์มาเล่นตรงนี้
    // ตอนนี้ให้ Retry ไปก่อน
    setState(() => _status = "Connection Error.\nRetrying in 10s...");
    _retryTimer = Timer(const Duration(seconds: 10), _checkAndUpdate);
  }

  void _goToPlayer(SignageLayout layout) {
    if(!mounted) return;
    Navigator.pushReplacement(
      context, 
      MaterialPageRoute(builder: (_) => PlayerPage(layout: layout))
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              value: _progress > 0 ? _progress : null,
              color: Colors.white,
            ),
            const SizedBox(height: 20),
            Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}