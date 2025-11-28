import 'dart:convert';
import 'package:http/http.dart' as http;
import '../signage/template_model.dart';

class ApiService {
  final String baseUrl;

  ApiService(this.baseUrl);

  // ดึงรายการ Layout ทั้งหมด
  Future<List<SignageLayout>> fetchLayouts() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/layouts'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => SignageLayout.fromJson(e)).toList();
      } else {
        throw Exception('Failed to load layouts: ${response.statusCode}');
      }
    } catch (e) {
      print("API Error: $e");
      throw e;
    }
  }

  // ดึง Layout รายตัว
  Future<SignageLayout> fetchLayoutById(String id) async {
    final response = await http.get(Uri.parse('$baseUrl/layouts/$id'));
    if (response.statusCode == 200) {
      // แปลง JSON ให้เป็น Object
      final Map<String, dynamic> json = jsonDecode(response.body);
      return SignageLayout.fromJson(json);
    } else {
      throw Exception('Failed to load layout');
    }
  }
}