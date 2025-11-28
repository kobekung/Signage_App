import 'dart:io';
import 'package:http/http.dart' as http;
import '../signage/template_model.dart'; // [สำคัญ] ใช้ Model ใหม่
import 'cache_manager.dart';

class PreloadService {
  // [สำคัญ] เปลี่ยน type ตรงนี้เป็น SignageLayout
  static Future<void> preloadTemplate({
    required SignageLayout layout, 
    required Function({
      required String url,
      required int index,
      required int totalCount,
      required int downloadedBytes,
      required int totalBytes,
    }) onProgress,
  }) async {
    final cacheDir = await CacheManager.getCacheDir();

    // 1. ดึง URL จาก Widget ทั้งหมดใน Layout
    final List<String> allMedia = [];
    
    for (final widget in layout.widgets) {
      final props = widget.properties;
      
      // หา URL จาก widget ประเภท image/video
      if (widget.type == 'image' || widget.type == 'video') {
        // กรณี Single URL
        if (props['url'] != null && props['url'].toString().isNotEmpty) {
          final url = props['url'].toString();
          if (_isMedia(url)) allMedia.add(url);
        }

        // กรณี Playlist
        if (props['playlist'] is List) {
          for (final item in props['playlist']) {
            if (item['url'] != null) {
              final url = item['url'].toString();
              if (_isMedia(url)) allMedia.add(url);
            }
          }
        }
      }
    }

    final total = allMedia.length;
    if (total == 0) return; // ถ้าไม่มีไฟล์ ก็จบเลย

    int index = 0;

    // 2. Cleanup ไฟล์เก่า
    final Set<String> usedFileNames = allMedia.map((url) {
      final ext = url.toLowerCase().contains(".mp4") ? ".mp4" : ".jpg";
      return "${url.hashCode}$ext";
    }).toSet();

    await CacheManager.cleanUnusedFiles(usedFileNames);
    await CacheManager.enforceCacheLimit();

    // 3. Download ไฟล์ใหม่
    for (final url in allMedia) {
      index++;
      await _download(
        url: url,
        dir: cacheDir,
        index: index,
        total: total,
        onProgress: onProgress,
      );
    }
  }

  static bool _isMedia(String url) {
    if (url.startsWith('blob:')) return false;
    final u = url.toLowerCase();
    return u.startsWith('http') && (
      u.endsWith(".jpg") || u.endsWith(".jpeg") || u.endsWith(".png") || u.endsWith(".mp4") || u.contains("uploads") || u.contains("picsum")
    );
  }

  static Future<void> _download({
    required String url,
    required Directory dir,
    required int index,
    required int total,
    required Function onProgress,
  }) async {
    String ext = ".jpg";
    if (url.toLowerCase().contains(".mp4")) ext = ".mp4";

    final fileName = "${url.hashCode}$ext";
    final file = File("${dir.path}/$fileName");

    if (await file.exists()) {
      onProgress(url: url, index: index, totalCount: total, downloadedBytes: 100, totalBytes: 100);
      return;
    }

    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await request.send();
      final totalBytes = response.contentLength ?? 0;
      int received = 0;

      final sink = file.openWrite();
      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress(url: url, index: index, totalCount: total, downloadedBytes: received, totalBytes: totalBytes);
      }
      await sink.close();
    } catch (e) {
      print("Download error: $e");
      if (await file.exists()) await file.delete();
    }
  }
}