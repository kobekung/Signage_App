// lib/pages/setup_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../utils/device_util.dart';
import '../utils/version_update.dart'; // [Added] Import VersionUpdater
import 'loading_page.dart';

class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _urlCtrl = TextEditingController();
  String _myDeviceId = "Loading...";
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInit();
  }

  Future<void> _loadInit() async {
    // ดึง UUID ที่เราทำใหม่
    String id = await DeviceUtil.getDeviceId();
    
    final prefs = await SharedPreferences.getInstance();
    String? savedUrl = prefs.getString('api_base_url');
    
    setState(() {
      _myDeviceId = id;
      _urlCtrl.text = savedUrl ?? dotenv.env['API_BASE_URL'] ?? '';
    });
  }

  Future<void> _saveAndConnect() async {
    setState(() { _isLoading = true; _error = null; });
    FocusScope.of(context).unfocus();

    try {
      String url = _urlCtrl.text.trim();
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      
      final api = ApiService(url);
      try {
        await api.fetchBusConfig(_myDeviceId);
      } catch (e) {
        if (!e.toString().contains('not registered')) {
           throw e;
        }
      }
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_base_url', url);

      if(mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoadingPage()));
      }

    } catch (e) {
      setState(() { _error = "Connection Error: $e"; });
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  // [New Function] ปุ่มกดเช็คอัปเดต
  Future<void> _checkUpdate() async {
    FocusScope.of(context).unfocus();
    // ใช้ URL จาก Text Field ปัจจุบันเลย
    String currentUrl = _urlCtrl.text.trim();
    if (currentUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter API URL first'))
      );
      return;
    }
    
    // เรียก VersionUpdater
    await VersionUpdater.checkAndMaybeUpdate(
      context, 
      silent: false, // ให้แสดง Toast/Dialog บอกสถานะ
      specificUrl: currentUrl // ส่ง URL นี้ไปใช้เลยไม่ต้องรอ Save
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup Device')),
      body: SingleChildScrollView( 
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- ส่วนแสดง Device ID และ QR Code ---
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white, 
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0,4))
                ]
              ),
              child: Column(
                children: [
                  const Text("DEVICE ID FOR REGISTRATION", 
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54)
                  ),
                  const SizedBox(height: 15),
                  
                  if (_myDeviceId != "Loading...")
                    QrImageView(
                      data: _myDeviceId,
                      version: QrVersions.auto,
                      size: 200.0,
                      backgroundColor: Colors.white,
                    ),
                  
                  const SizedBox(height: 15),
                  
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: _myDeviceId));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Copied ID!")));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(5)
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              _myDeviceId, 
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 16, 
                                fontWeight: FontWeight.bold, 
                                color: Colors.black87,
                                fontFamily: 'Courier',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.copy, size: 16, color: Colors.blue),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // -----------------------------------------

            const SizedBox(height: 30),

            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'API Base URL', 
                hintText: 'http://...',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cloud)
              ),
            ),
            
            const SizedBox(height: 20),
            
            // ปุ่ม Save & Start
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _saveAndConnect,
              icon: _isLoading 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
              label: const Text('Save & Start'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
              ),
            ),

            const SizedBox(height: 15),

            // [New Button] ปุ่ม Check Update
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _checkUpdate,
              icon: const Icon(Icons.system_update),
              label: const Text('Check for Update'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                foregroundColor: Colors.blueAccent,
                side: const BorderSide(color: Colors.blueAccent),
              ),
            ),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
              ),
          ],
        ),
      ),
    );
  }
}