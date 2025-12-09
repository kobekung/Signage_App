import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import '../models/layout_model.dart';

class PreloadService {
  
  // ✅ ใช้ Internal Storage (Application Support) 
  // พื้นที่นี้เป็นของแอปโดยเฉพาะ เขียนได้แน่นอน 100% ไม่ต้องขอ Permission
  static Future<Directory> _getStorageDir() async {
    return await getApplicationSupportDirectory(); 
  }

  static Future<void> manageAssets(
    SignageLayout layout,
    Function(String, int, int) onProgress,
  ) async {
    final dir = await _getStorageDir();
    
    // สร้างโฟลเดอร์ media เก็บแยกเป็นสัดส่วน
    final mediaDir = Directory('${dir.path}/media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    
    print("📂 Storage Path: ${mediaDir.path}"); 

    final List<String> activeUrls = _extractUrls(layout);
    
    // 1. ลบไฟล์ขยะ (ไฟล์เก่าที่ไม่ได้ใช้แล้ว)
    await _cleanupUnusedFiles(mediaDir, activeUrls);
    
    // 2. ดาวน์โหลดไฟล์ใหม่
    int completed = 0;
    onProgress("Syncing...", 0, activeUrls.length);

    for (var url in activeUrls) {
      await _downloadFile(url, mediaDir);
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
    
    // ค้นหาไฟล์เดิม (ถ้ามีแล้วขนาด > 0 ถือว่าใช้ได้)
    try {
      final files = dir.listSync();
      for (var f in files) {
        if (f.path.contains(filenameHash)) {
          if ((f as File).lengthSync() > 0) {
             // print("✅ Cache Hit: ${f.path}");
             return f;
          } else {
             print("⚠️ Found empty file, deleting...");
             f.deleteSync(); // ลบไฟล์เสียทิ้ง
          }
        }
      }
    } catch (_) {}

    // ถ้าไม่มี หรือไฟล์เสีย ให้ดาวน์โหลดใหม่
    try {
      print("⬇️ Downloading: $url");
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        // หา Extension (ถ้า Video บังคับ .mp4 ไปเลยเพื่อความชัวร์)
        String ext = ".mp4"; 
        final contentType = response.headers['content-type'];
        if (contentType != null) {
           if (contentType.contains("image")) ext = ".jpg";
        } else if (url.contains('.')) {
           // พยายามแกะจาก url ถ้าไม่มี header
           ext = ".${url.split('.').last.split('?').first}";
        }
        
        final file = File('${dir.path}/$filenameHash$ext');
        await file.writeAsBytes(response.bodyBytes);
        print("✅ Saved: ${file.path} (${response.bodyBytes.length} bytes)");
        return file;
      } else {
        print("❌ Server Error: ${response.statusCode}");
      }
    } catch (e) {
      print("❌ Download Error: $e");
    }
    
    // คืนค่าไฟล์เปล่าๆ ไปก่อน (ContentPlayer จะจัดการต่อเองถ้าเปิดไม่ได้)
    return File('${dir.path}/$filenameHash.error'); 
  }

  static Future<void> _cleanupUnusedFiles(Directory dir, List<String> activeUrls) async {
    try {
      if (!await dir.exists()) return;

      final activeHashes = activeUrls.map((url) => md5.convert(utf8.encode(url)).toString()).toSet();
      
      final files = dir.listSync();
      for (var file in files) {
        if (file is File) {
          final filename = file.uri.pathSegments.last;
          // แยก hash ออกจากชื่อไฟล์ (ตัดนามสกุล)
          String fileHash = filename;
          if (filename.contains('.')) {
            fileHash = filename.split('.').first;
          }
          
          // ถ้าไฟล์ในเครื่อง ไม่ตรงกับ Hash ใน Playlist ใหม่ -> ลบ
          if (!activeHashes.contains(fileHash) && fileHash.length == 32) {
            print("🗑️ Cleaning up: $filename");
            await file.delete();
          }
        }
      }
    } catch (e) {
      print("Cleanup Error: $e");
    }
  }

  // ฟังก์ชันสำหรับ ContentPlayer เรียกใช้
  static Future<File?> getCachedFile(String url) async {
    final baseDir = await _getStorageDir();
    final dir = Directory('${baseDir.path}/media');
    
    final filename = md5.convert(utf8.encode(url)).toString();
    try {
      if (await dir.exists()) {
        final files = dir.listSync();
        for (var f in files) {
          // ต้องเช็คด้วยว่าไฟล์ไม่ว่างเปล่า
          if (f.path.contains(filename) && (f as File).lengthSync() > 0) {
            return f;
          }
        }
      }
    } catch (_) {}
    return null;
  }
}