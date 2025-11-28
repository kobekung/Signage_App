import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/layout_model.dart';

class ApiService {
  final String baseUrl;

  ApiService(this.baseUrl);

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

  Future<SignageLayout> fetchLayoutById(String id) async {
    final response = await http.get(Uri.parse('$baseUrl/layouts/$id'));
    if (response.statusCode == 200) {
      return SignageLayout.fromJson(jsonDecode(response.body));
    }
    throw Exception('Layout not found');
  }
}