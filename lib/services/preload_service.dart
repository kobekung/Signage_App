import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart'; // อย่าลืมใส่ crypto: ^3.0.3 ใน pubspec.yaml
import '../models/layout_model.dart';

class PreloadService {
  static Future<void> preloadAssets(
    SignageLayout layout,
    Function(String, int, int) onProgress,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final List<String> urls = _extractUrls(layout);
    
    int completed = 0;
    // แจ้งสถานะเริ่มต้น
    onProgress("Checking files...", 0, urls.length);

    for (var url in urls) {
      await _downloadFile(url, dir);
      completed++;
      onProgress(url, completed, urls.length);
    }
  }

  // ดึง URL จาก Widget ทั้งหมด
  static List<String> _extractUrls(SignageLayout layout) {
    Set<String> urls = {};
    for (var w in layout.widgets) {
      // 1. เช็ค property 'url'
      if (w.properties['url'] != null) urls.add(w.properties['url'].toString());
      
      // 2. เช็ค 'playlist'
      if (w.properties['playlist'] is List) {
        for (var item in w.properties['playlist']) {
          if (item['url'] != null) urls.add(item['url'].toString());
        }
      }
    }
    // กรองเอาเฉพาะ http (ไม่เอา blob)
    return urls.where((u) => u.startsWith('http')).toList();
  }

  static Future<File> _downloadFile(String url, Directory dir) async {
    // ใช้ MD5 hash ชื่อไฟล์เพื่อป้องกันปัญหายาวเกินหรืออักขระพิเศษ
    final filename = md5.convert(utf8.encode(url)).toString();
    
    // พยายามเดานามสกุลไฟล์
    String ext = "";
    if (url.contains('.')) {
        ext = ".${url.split('.').last.split('?').first}";
    }
    
    final file = File('${dir.path}/$filename$ext');

    // ถ้ามีไฟล์แล้ว ไม่ต้องโหลดใหม่
    if (await file.exists()) return file;

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
      }
    } catch (e) {
      print("Download Error: $e");
    }
    return file;
  }

  // ฟังก์ชันช่วยหาไฟล์ในเครื่อง
  static Future<File?> getCachedFile(String url) async {
    final dir = await getApplicationDocumentsDirectory();
    final filename = md5.convert(utf8.encode(url)).toString();
    try {
      final files = dir.listSync();
      for (var f in files) {
        // หาไฟล์ที่มีชื่อขึ้นต้นด้วย hash ที่เราเจนไว้
        if (f.path.contains(filename)) return File(f.path);
      }
    } catch (_) {}
    return null;
  }
}