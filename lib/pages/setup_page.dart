import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart'; // สำหรับ Clipboard
import '../services/api_service.dart';
import '../utils/device_util.dart'; // [NEW]
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
    // 1. ดึง Device ID อัตโนมัติ
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
      
      // ทดสอบเชื่อมต่อ
      final api = ApiService(url);
      // ลองเช็ค config ดู (ถ้า Server ตอบ 404 แปลว่ารถยังไม่ลงทะเบียน แต่ต่อ Server ได้)
      try {
        await api.fetchBusConfig(_myDeviceId);
      } catch (e) {
        // ถ้า Error เป็น 404 (Bus not registered) ถือว่าเชื่อมต่อ Server ได้ แต่ Admin ยังไม่แอพพรูฟ
        if (!e.toString().contains('not registered')) {
           throw e; // ถ้าเป็น Error อื่น (เช่น Connect timeout) ให้โยนต่อ
        }
      }
      
      // บันทึก URL
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_base_url', url);
      // ไม่ต้องบันทึก Device ID แล้ว เพราะดึงสดจากเครื่องตลอด

      if(mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoadingPage()));
      }

    } catch (e) {
      setState(() { _error = "Connection Error: $e"; });
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup Device')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ส่วนแสดง Device ID (ให้ Admin จดไปลงทะเบียน)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  const Text("YOUR DEVICE ID", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  SelectableText(
                    _myDeviceId, 
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _myDeviceId));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Copied!")));
                    }, 
                    icon: const Icon(Icons.copy, size: 16), 
                    label: const Text("Copy ID")
                  )
                ],
              ),
            ),
            const SizedBox(height: 30),

            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'API Base URL', 
                hintText: 'http://192.168.x.x:5000/api',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cloud)
              ),
            ),
            
            const SizedBox(height: 20),
            
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _saveAndConnect,
              icon: _isLoading 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
              label: const Text('Save & Start'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)),
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