import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import '../models/layout_model.dart';

class PreloadService {
  
  // [NEW] ฟังก์ชันหา Path Downloads (เพิ่ม Logic สำหรับ Android Box)
  static Future<Directory> _getDownloadDir() async {
    if (Platform.isAndroid) {
      // 1. ลองขอ Path มาตรฐาน
      Directory? directory = await getDownloadsDirectory();
      
      // 2. ถ้าหาไม่เจอ (Android Box บางรุ่น) ให้ใช้ Path ตรงๆ
      if (directory == null) {
        directory = Directory('/storage/emulated/0/Download');
      }
      
      // 3. สร้างโฟลเดอร์ย่อยเก็บงานของเราโดยเฉพาะ (กันไปปนกับไฟล์อื่น)
      final appDir = Directory('${directory.path}/signage_assets');
      if (!await appDir.exists()) {
        await appDir.create(recursive: true);
      }
      return appDir;
    }
    // iOS หรืออื่นๆ ใช้ Documents เหมือนเดิม
    return await getApplicationDocumentsDirectory();
  }

  // 1. ฟังก์ชันหลักสำหรับ Preload และ Cleanup (ชื่อเดิม)
  static Future<void> manageAssets(
    SignageLayout layout,
    Function(String, int, int) onProgress,
  ) async {
    // เปลี่ยนจาก getApplicationDocumentsDirectory เป็นฟังก์ชันใหม่ของเรา
    final dir = await _getDownloadDir(); 
    
    final List<String> activeUrls = _extractUrls(layout);
    
    // 1.1 ลบไฟล์ขยะ
    await _cleanupUnusedFiles(dir, activeUrls);

    // 1.2 ดาวน์โหลดไฟล์ใหม่
    int completed = 0;
    onProgress("Checking files...", 0, activeUrls.length);

    for (var url in activeUrls) {
      await _downloadFile(url, dir);
      completed++;
      onProgress(url, completed, activeUrls.length);
    }
  }

  static List<String> _extractUrls(SignageLayout layout) {
    Set<String> urls = {};
    for (var w in layout.widgets) {
      if (w.properties['url'] != null) urls.add(w.properties['url'].toString());
      if (w.properties['playlist'] is List) {
        for (var item in w.properties['playlist']) {
          if (item['url'] != null) urls.add(item['url'].toString());
        }
      }
    }
    return urls.where((u) => u.startsWith('http')).toList();
  }

  static Future<File> _downloadFile(String url, Directory dir) async {
    final filenameHash = md5.convert(utf8.encode(url)).toString();
    
    // ค้นหาว่ามีไฟล์นี้อยู่แล้วหรือไม่
    try {
      final existingFiles = dir.listSync().where((f) => f.path.contains(filenameHash));
      if (existingFiles.isNotEmpty) {
        return File(existingFiles.first.path); 
      }
    } catch (_) {}

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        String ext = _getExtensionFromUrl(url);
        if (ext.isEmpty) {
           ext = _getExtensionFromHeader(response.headers['content-type']);
        }
        
        final file = File('${dir.path}/$filenameHash$ext');
        await file.writeAsBytes(response.bodyBytes);
        return file;
      }
    } catch (e) {
      print("Download Error: $e");
    }
    return File('${dir.path}/$filenameHash');
  }

  static Future<void> _cleanupUnusedFiles(Directory dir, List<String> activeUrls) async {
    try {
      final activeHashes = activeUrls.map((url) => md5.convert(utf8.encode(url)).toString()).toSet();
      
      final files = dir.listSync();
      for (var file in files) {
        if (file is File) {
          final filename = file.uri.pathSegments.last;
          final fileHash = filename.split('.').first; 
          
          if (!activeHashes.contains(fileHash) && filename.length >= 32) {
            print("Cleaning up unused file: $filename");
            await file.delete();
          }
        }
      }
    } catch (e) {
      print("Cleanup Error: $e");
    }
  }

  static String _getExtensionFromUrl(String url) {
    if (url.contains('.')) {
      final ext = url.split('.').last.split('?').first.toLowerCase();
      if (['jpg', 'jpeg', 'png', 'mp4', 'mov'].contains(ext)) {
        return '.$ext';
      }
    }
    return '';
  }

  static String _getExtensionFromHeader(String? contentType) {
    if (contentType == null) return '';
    if (contentType.contains('video/mp4')) return '.mp4';
    if (contentType.contains('image/jpeg')) return '.jpg';
    if (contentType.contains('image/png')) return '.png';
    return '';
  }

  // แก้ไข getCachedFile ให้ชี้ไปที่เดียวกับ manageAssets (ชื่อเดิม)
  static Future<File?> getCachedFile(String url) async {
    // ต้องเรียก directory เดียวกันเป๊ะๆ ไม่งั้นหาไม่เจอ
    final dir = await _getDownloadDir();
    
    final filename = md5.convert(utf8.encode(url)).toString();
    try {
      // เช็คก่อนว่ามีโฟลเดอร์ไหม
      if (await dir.exists()) {
        final files = dir.listSync();
        for (var f in files) {
          if (f.path.split('/').last.startsWith(filename)) return File(f.path);
        }
      }
    } catch (_) {}
    return null;
  }
}