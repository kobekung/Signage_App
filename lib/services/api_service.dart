import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/layout_model.dart';

class ApiService {
  final String baseUrl;

  ApiService(this.baseUrl);

  // [NEW] ดึง Config ของรถตาม Device ID
  // จะคืนค่า Map เช่น { "id": 1, "name": "Layout A" } หรือ Error ถ้าไม่เจอ
  Future<Map<String, dynamic>> fetchBusConfig(String deviceId) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/bus/device/$deviceId'));
      print('baseUrl ============================== : $baseUrl');
      print('deviceId ============================== : $deviceId');
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else if (response.statusCode == 404) {
        throw Exception('Bus Device ID not registered in system');
      } else {
        throw Exception('Server Error: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Connection failed: $e');
    }
  }

  // [2] ดึง Layout
  Future<SignageLayout> fetchLayoutById(String id) async {
    final response = await http.get(Uri.parse('$baseUrl/layouts/$id'));
    if (response.statusCode == 200) {
      return SignageLayout.fromJson(jsonDecode(response.body));
    }
    throw Exception('Failed to load layout');
  }

  // [3] [NEW] รายงานผลกลับไป Server (ว่าเล่น Version ไหนอยู่)
  Future<void> updateBusStatus(int busId, int activeVersion) async {
    try {
      // สมมติ Backend มี Route: PUT /api/buses/:id/ack
      // body: { "version": 123 }
      await http.put(
        Uri.parse('$baseUrl/bus/$busId/ack'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'version': activeVersion}),
      );
      print("✅ Reported status: Bus $busId is on version $activeVersion");
    } catch (e) {
      print("⚠️ Failed to report status: $e");
    }
  }
}