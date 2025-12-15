import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:qr_flutter/qr_flutter.dart'; // [1] เพิ่ม Import QR Code
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
  String? _currentDeviceId; // [2] ตัวแปรเก็บ ID ไว้โชว์
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
    
    // ดึง URL
    String? url = prefs.getString('api_base_url');
    if (url == null || url.isEmpty) {
        url = dotenv.env['API_BASE_URL'];
        if (url != null && url.isNotEmpty) {
            await prefs.setString('api_base_url', url);
        }
    }
    
    // ดึง Device ID และเก็บใส่ตัวแปร State
    String deviceId = await DeviceUtil.getDeviceId();
    setState(() => _currentDeviceId = deviceId); // [3] อัปเดต ID เข้า State

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
        // [4] ถ้า Error เช็คว่าเป็นเพราะไม่ได้ลงทะเบียนหรือไม่
        if (e.toString().contains("not registered")) {
           _playOfflineOrRetry("Device Not Registered", retrySeconds: 10);
        } else {
           _playOfflineOrRetry("Connection Failed: $e");
        }
        return;
      }

      // ... (ส่วน Logic เดิม: โหลด Layout ฯลฯ) ...
      final serverLayoutId = busConfig['layout_id'] ?? busConfig['id'];
      final int busId = int.tryParse(busConfig['bus_id'].toString()) ?? 0;
      final int companyId = int.tryParse(busConfig['company_id'].toString()) ?? 0;
      final serverVersion = int.tryParse(busConfig['layout_version'].toString()) ?? 1;

      if (serverLayoutId == null) {
        setState(() => _status = "No layout assigned.\nWaiting for admin...");
        _retryTimer = Timer(const Duration(seconds: 15), _start);
        return;
      }

      // ... (โค้ดส่วน Update Cache และ Preload เดิมคงไว้เหมือนเดิม) ...
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
        await prefs.setString('cached_layout_id', serverLayoutId.toString());
        await prefs.setInt('cached_layout_version', serverVersion);
        await api.updateBusStatus(busId, serverVersion);
      } else {
        setState(() => _status = "Starting Player...");
        layout = await api.fetchLayoutById(serverLayoutId.toString());
      }

      if(!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PlayerPage(
          layout: layout, busId: busId, companyId: companyId
      )));

    } catch (e) {
       print("Critical Error: $e");
       _playOfflineOrRetry(e.toString());
    }
  }

  void _playOfflineOrRetry(String errorMsg, {int retrySeconds = 10}) {
    setState(() => _status = "$errorMsg\nRetrying in ${retrySeconds}s...");
    _retryTimer = Timer(Duration(seconds: retrySeconds), _start);
  }

  @override
  Widget build(BuildContext context) {
    // [5] ตรวจสอบว่า Error เกี่ยวกับการลงทะเบียนหรือไม่ เพื่อแสดง QR
    bool showQr = _status.contains("Not Registered") || _status.contains("not registered");

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ถ้าต้องแสดง QR ให้โชว์ QR แทน Loading
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
          
          // ปุ่มลับไปหน้า Setup (เหมือนเดิม)
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