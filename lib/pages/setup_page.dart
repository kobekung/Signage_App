import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/layout_model.dart';
import '../services/api_service.dart';
import 'loading_page.dart';

class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _urlCtrl = TextEditingController();
  List<SignageLayout> _layouts = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInit();
  }

  Future<void> _loadInit() async {
    final prefs = await SharedPreferences.getInstance();
    String? saved = prefs.getString('api_base_url');
    _urlCtrl.text = saved ?? dotenv.env['API_BASE_URL'] ?? '';
  }

  Future<void> _connect() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      String url = _urlCtrl.text.trim();
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      
      final api = ApiService(url);
      final layouts = await api.fetchLayouts();
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_base_url', url);

      setState(() { _layouts = layouts; });
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  void _select(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_layout_id', id);
    if(mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoadingPage()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Signage Setup')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(labelText: 'API URL', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _isLoading ? null : _connect,
              child: _isLoading ? const CircularProgressIndicator() : const Text('Connect'),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                itemCount: _layouts.length,
                itemBuilder: (context, index) {
                  final l = _layouts[index];
                  return ListTile(
                    title: Text(l.name),
                    subtitle: Text('${l.width}x${l.height}'),
                    trailing: const Icon(Icons.arrow_forward),
                    onTap: () => _select(l.id),
                  );
                },
              ),
            )
          ],
        ),
      ),
    );
  }
}