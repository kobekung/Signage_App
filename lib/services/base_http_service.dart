import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:awesome_dialog/awesome_dialog.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../main.dart'; // เพื่อใช้ navigatorKey

class BaseHttpService {
  static const storage = FlutterSecureStorage();

  // ฟังก์ชันหา Base URL (เลือกจาก Prefs ก่อน ถ้าไม่มีใช้ .env)
  static Future<String> _getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('api_base_url') ?? dotenv.env['API_BASE_URL'] ?? '';
  }

  // Helper สำหรับจัดการ Request และ Error
  static Future<http.Response> _handleRequest(Future<http.Response> Function() request) async {
    try {
      final response = await request();
      
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      } else if (response.statusCode == 401) {
        // Unauthorized Logic (ถ้ามี Login)
        _showErrorDialog('Unauthorized', 'Session expired. Please check configuration.');
        throw Exception('Unauthorized');
      } else {
        // Server Error
        print("API Error: ${response.statusCode} - ${response.body}");
        // ไม่โชว์ Dialog พร่ำเพรื่อสำหรับ Background Polling แต่ throw exception
        throw Exception('Server Error: ${response.statusCode}');
      }
    } catch (e) {
      print("Network Error: $e");
      // _showErrorDialog('Connection Error', e.toString()); // Optional: เปิดถ้าอยากให้เด้งเตือนทุกครั้งที่เน็ตหลุด
      rethrow;
    }
  }

  // แสดง Dialog
  static void _showErrorDialog(String title, String desc) {
    if (navigatorKey.currentContext != null) {
      AwesomeDialog(
        context: navigatorKey.currentContext!,
        dialogType: DialogType.error,
        animType: AnimType.bottomSlide,
        title: title,
        desc: desc,
        btnOkOnPress: () {},
      ).show();
    }
  }

  // --- Methods ---

  static Future<http.Response> get(String path) async {
    return _handleRequest(() async {
      final baseUrl = await _getBaseUrl();
      final token = await storage.read(key: 'token');
      // final comId = await storage.read(key: 'com_id'); // ถ้ามี

      final uri = Uri.parse('$baseUrl$path'); // path ควรเริ่มด้วย / เช่น /layouts
      print("GET: $uri");
      
      return await http.get(uri, headers: {
        if (token != null) 'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
    });
  }

  static Future<http.Response> post(String path, dynamic body) async {
    return _handleRequest(() async {
      final baseUrl = await _getBaseUrl();
      final token = await storage.read(key: 'token');
      
      final uri = Uri.parse('$baseUrl$path');
      print("POST: $uri");

      return await http.post(uri,
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body));
    });
  }

  static Future<http.Response> put(String path, dynamic body) async {
    return _handleRequest(() async {
      final baseUrl = await _getBaseUrl();
      final token = await storage.read(key: 'token');
      
      final uri = Uri.parse('$baseUrl$path');
      print("PUT: $uri");

      return await http.put(uri,
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body));
    });
  }

  static Future<http.Response> delete(String path) async {
    return _handleRequest(() async {
      final baseUrl = await _getBaseUrl();
      final token = await storage.read(key: 'token');
      
      final uri = Uri.parse('$baseUrl$path');
      
      return await http.delete(uri, headers: {
        if (token != null) 'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
    });
  }
}