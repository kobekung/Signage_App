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
      final response = await http.get(Uri.parse('$baseUrl/buses/device/$deviceId'));
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

  // ดึงรายการ Layout ทั้งหมด (เผื่อใช้)
  Future<List<SignageLayout>> fetchLayouts() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/layouts'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => SignageLayout.fromJson(e)).toList();
      }
      throw Exception('Server Error: ${response.statusCode}');
    } catch (e) {
      throw Exception('Connection failed: $e');
    }
  }

  // ดึงข้อมูล Layout รายตัว (พร้อม Widgets)
  Future<SignageLayout> fetchLayoutById(String id) async {
    final response = await http.get(Uri.parse('$baseUrl/layouts/$id'));
    if (response.statusCode == 200) {
      return SignageLayout.fromJson(jsonDecode(response.body));
    }
    throw Exception('Layout not found');
  }
}