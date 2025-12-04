import 'dart:convert';
import '../models/layout_model.dart';
import 'base_http_service.dart'; // [NEW]

class ApiService {
  // ไม่ต้องรับ baseUrl ใน constructor แล้ว เพราะ BaseHttpService จัดการให้
  // แต่อาจจะเก็บไว้ถ้าโค้ดเก่ามีการส่งค่ามา แต่เราจะไม่ใช้มัน
  ApiService([String? _]); 

  Future<Map<String, dynamic>> fetchBusConfig(String deviceId) async {
    try {
      // ใช้ BaseHttpService.get แทน
      final response = await BaseHttpService.get('/bus/device/$deviceId');
      return jsonDecode(response.body);
      
      // *หมายเหตุ: BaseHttpService จัดการ statusCode check ให้แล้วในระดับหนึ่ง
      // แต่ถ้าต้องการ Handle 404 เฉพาะจุด อาจต้อง try-catch เพิ่มเติม
    } catch (e) {
      throw Exception('Failed to fetch bus config: $e');
    }
  }

  Future<SignageLayout> fetchLayoutById(String id) async {
    try {
      final response = await BaseHttpService.get('/layouts/$id');
      return SignageLayout.fromJson(jsonDecode(response.body));
    } catch (e) {
       throw Exception('Error fetching layout: $e');
    }
  }

  Future<void> updateBusStatus(int busId, int activeVersion) async {
    try {
      await BaseHttpService.put(
        '/bus/$busId/ack',
        {'version': activeVersion},
      );
      print("✅ Reported status: Bus $busId is on version $activeVersion");
    } catch (e) {
      print("⚠️ Failed to report status: $e");
    }
  }

  Future<List<SignageLayout>> fetchLayouts() async {
    try {
      final response = await BaseHttpService.get('/layouts');
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((e) => SignageLayout.fromJson(e)).toList();
    } catch (e) {
      throw e;
    }
  }
}