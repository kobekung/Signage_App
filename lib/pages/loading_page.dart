import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    final deviceId = await DeviceUtil.getDeviceId();

    if (url == null) {
      if(!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage()));
      return;
    }

    try {
      final api = ApiService(url);
      setState(() => _status = "Checking Updates...");

      // 1. ถาม Server ว่าต้องเล่นอะไร
      final busConfig = await api.fetchBusConfig(deviceId);
      
      final serverLayoutId = busConfig['layout_id']; // ID ของ Layout ที่ผูกไว้
      final int serverVersion = busConfig['layout_version'] ?? 1; // เวอร์ชันล่าสุด
      final int busId = busConfig['bus_id'];
      final int companyId = busConfig['company_id'];

      if (serverLayoutId == null) {
        setState(() => _status = "No layout assigned.\nWaiting...");
        _retryTimer = Timer(const Duration(seconds: 15), _checkAndUpdate);
        return;
      }

      // 2. เทียบกับของเดิมในเครื่อง
      final String? localLayoutId = prefs.getString('cached_layout_id');
      final int localVersion = prefs.getInt('cached_layout_version') ?? 0;

      // เงื่อนไขการอัปเดต: (Layout เปลี่ยนคนละตัว) หรือ (ตัวเดิมแต่ Version ใหม่กว่า)
      bool needUpdate = (localLayoutId != serverLayoutId.toString()) || (serverVersion > localVersion);

      SignageLayout layout;

      if (needUpdate) {
        // --- กรณีต้องโหลดใหม่ ---
        setState(() => _status = "New Update Found (v$serverVersion)...");
        
        layout = await api.fetchLayoutById(serverLayoutId.toString());
        
        await PreloadService.preloadAssets(layout, (file, current, total) {
          if(mounted) setState(() {
            _status = "Downloading $current/$total";
            _progress = total > 0 ? current / total : 0;
          });
        });

        // บันทึกค่าใหม่ลงเครื่อง
        await prefs.setString('cached_layout_id', serverLayoutId.toString());
        await prefs.setInt('cached_layout_version', serverVersion);
        
        // [สำคัญ] แจ้ง Server ว่าอัปเดตเสร็จแล้ว
        await api.updateBusStatus(busId, serverVersion);

      } else {
        // --- กรณีเป็นตัวเดิม (ใช้ Cache) ---
        setState(() => _status = "Up to date. Loading...");
        // โหลด JSON เดิมมาเล่น (จริงๆ ควร Cache JSON ด้วย แต่ดึงใหม่ก็เร็วอยู่)
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
      print("Error: $e");
      setState(() => _status = "Connection Error. Retrying...");
      _retryTimer = Timer(const Duration(seconds: 10), _checkAndUpdate);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(value: _progress > 0 ? _progress : null, color: Colors.white),
            const SizedBox(height: 20),
            Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}