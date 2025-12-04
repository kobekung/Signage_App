import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/layout_model.dart';

class ApiService {
  final String baseUrl;

  ApiService([String? url]) 
      : baseUrl = url ?? dotenv.env['API_BASE_URL'] ?? '';

  // [1] ดึง Config ของรถตาม Device ID
  Future<Map<String, dynamic>> fetchBusConfig(String deviceId) async {
    try {
      if (baseUrl.isEmpty) {
        throw Exception("API_BASE_URL is missing in .env");
      }

      // [FIX] เปลี่ยนจาก /bus เป็น /buses (เติม s)
      final uri = Uri.parse('$baseUrl/bus/device/$deviceId');
      print('Fetching Config from: $uri');
      
      final response = await http.get(uri);
      print('Response Status Code: ${response.statusCode}');
      print('Response Body: ${response.body}');
      
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

  // [2] ดึง Layout รายตัว (อันนี้ layouts ถูกแล้ว)
  Future<SignageLayout> fetchLayoutById(String id) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/layouts/$id'));
      if (response.statusCode == 200) {
        return SignageLayout.fromJson(jsonDecode(response.body));
      }
      throw Exception('Failed to load layout (Status: ${response.statusCode})');
    } catch (e) {
       throw Exception('Error fetching layout: $e');
    }
  }

  // [3] รายงานผลกลับไป Server
  Future<void> updateBusStatus(int busId, int activeVersion) async {
    try {
      // [FIX] เปลี่ยนจาก /bus เป็น /buses (เติม s)
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

  // (Optional) ดึง Layout ทั้งหมด
  Future<List<SignageLayout>> fetchLayouts() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/layouts'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => SignageLayout.fromJson(e)).toList();
      }
      throw Exception('Failed to load layouts: ${response.statusCode}');
    } catch (e) {
      throw e;
    }
  }
}