import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/layout_model.dart';
import '../services/api_service.dart';
import '../services/preload_service.dart';
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

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. ดึง Config
    final url = prefs.getString('api_base_url');
    final id = prefs.getString('selected_layout_id');

    // 2. ถ้าไม่มี Config ให้ไปหน้า Setup
    if (url == null || id == null) {
      if(!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage()));
      return;
    }

    try {
      // 3. ดึง Layout จาก API
      setState(() => _status = "Fetching Layout...");
      final api = ApiService(url);
      final layout = await api.fetchLayoutById(id);

      // 4. ดาวน์โหลดไฟล์
      setState(() => _status = "Downloading Media...");
      await PreloadService.preloadAssets(layout, (file, current, total) {
        if(mounted) {
          setState(() {
            _status = "Downloading $current/$total\n$file";
            _progress = total > 0 ? current / total : 0;
          });
        }
      });

      // 5. ไปหน้า Player
      if(!mounted) return;
      Navigator.pushReplacement(
        context, 
        MaterialPageRoute(builder: (_) => PlayerPage(layout: layout))
      );

    } catch (e) {
      // Error -> กลับไป Setup
      if(!mounted) return;
      showDialog(
        context: context, 
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text("Error"),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage())), 
              child: const Text("Setup")
            )
          ],
        )
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                value: _progress > 0 ? _progress : null,
                color: Colors.white,
              ),
              const SizedBox(height: 20),
              Text(
                _status, 
                style: const TextStyle(color: Colors.white, fontSize: 16), 
                textAlign: TextAlign.center
              ),
            ],
          ),
        ),
      ),
    );
  }
}