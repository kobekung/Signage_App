import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class FileManager {
  // 1. ฟังก์ชันสำหรับหา Path ปัจจุบันของเครื่องเสมอ (ห้าม Hardcode)
  static Future<File> getLocalFile(String filename) async {
    // ใช้ getApplicationDocumentsDirectory หรือ Directory ที่คุณใช้เซฟไฟล์
    final directory = await getApplicationDocumentsDirectory(); 
    
    // เอา Path ปัจจุบัน + ชื่อไฟล์
    final path = p.join(directory.path, filename);
    return File(path);
  }

  // 2. ฟังก์ชันเช็คว่าไฟล์มีอยู่จริงไหม (Integrity Check)
  static Future<bool> isFileValid(String filename) async {
    if (filename.isEmpty) return false;
    final file = await getLocalFile(filename);
    return await file.exists();
  }
}