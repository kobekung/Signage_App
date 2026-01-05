// lib/utils/version_update.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:install_plugin/install_plugin.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// [Fixed] Import ไฟล์ที่อยู่ใน folder utils เดียวกัน ใช้ชื่อไฟล์ตรงๆ ได้เลย
import 'downloadUI.dart'; 
import 'downloadprogressdialog.dart';
import 'device_util.dart';

enum UpdateCheckResult {
  upToDate,
  softUpdateAvailable,
  forceUpdateRequired,
  failedOrAborted,
}

class VersionUpdater {
  static Future<UpdateCheckResult> checkAndMaybeUpdate(
    BuildContext context, {
    bool silent = false,
    String? specificUrl,
  }) async {
    // 1. เตรียม URL
    String base = specificUrl ?? '';
    if (base.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      base = prefs.getString('api_base_url') ?? dotenv.env['API_BASE_URL']?.trim() ?? '';
    }
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);

    if (base.isEmpty) {
      if (!silent) _toast('ไม่พบ API URL');
      return UpdateCheckResult.failedOrAborted;
    }

    final versionApi = '$base/companyDetail/signageApk';
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (s) => s != null && s < 500,
    ));

    try {
      if (!silent) _toast('กำลังตรวจสอบอัปเดต...');

      // 2. หา com_id จาก Device ID
      final deviceId = await DeviceUtil.getDeviceId();
      final comIdUrl = '$base/bus/comId/$deviceId';

      final comIdRes = await dio.get(comIdUrl);
      if (comIdRes.statusCode != 200) {
        if (!silent) _toast('ไม่พบข้อมูลเครื่อง (HTTP ${comIdRes.statusCode})');
        return UpdateCheckResult.failedOrAborted;
      }

      final comIdData = comIdRes.data is Map 
          ? comIdRes.data 
          : json.decode(comIdRes.data.toString());

      final busComId = comIdData['data']?['bus_com_id'];
      if (busComId == null) {
        if (!silent) _toast('ไม่พบ com_id ในระบบ');
        return UpdateCheckResult.failedOrAborted;
      }

      // 3. เช็คเวอร์ชัน
      final info = await PackageInfo.fromPlatform();
      
      final res = await dio.get(
        versionApi,
        options: Options(headers: {'com_id': busComId.toString()}),
      );

      if (res.statusCode != 200) {
        if (!silent) _toast('เช็คเวอร์ชันไม่ได้ (HTTP ${res.statusCode})');
        return UpdateCheckResult.failedOrAborted;
      }

      final data = res.data is Map ? res.data as Map : json.decode(res.data.toString()) as Map;
      final minVersion = (data['min_supported_version'] ?? '').toString().trim();
      final latestVersion = (data['latest_version'] ?? '').toString().trim();
      final apkUrl = (data['apk_url'] ?? '').toString().trim();

      // เทียบเวอร์ชัน
      if (_isLower(info.version, minVersion)) {
        await _showForceDialog(context, apkUrl, latestVersion, info.version);
        return UpdateCheckResult.forceUpdateRequired;
      } else if (_isLower(info.version, latestVersion)) {
        await _showSoftDialog(context, apkUrl, latestVersion);
        return UpdateCheckResult.softUpdateAvailable;
      } else {
        if (!silent) _showUpToDateDialog(context, info.version);
        return UpdateCheckResult.upToDate;
      }
    } catch (e) {
      if (!silent) _toast('Error: $e');
      print('Update Error: $e');
      return UpdateCheckResult.failedOrAborted;
    }
  }

  // ---------- UI helpers ----------

  static Future<void> _showUpToDateDialog(BuildContext context, String currentVersion) async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ตรวจสอบเวอร์ชัน'),
        content: Text('แอปเป็นเวอร์ชันล่าสุดแล้ว ($currentVersion)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ตกลง')),
        ],
      ),
    );
  }

  static Future<void> _showForceDialog(
    BuildContext context, String apkUrl, String targetVersion, String currentVersion
  ) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('ต้องอัปเดต'),
        content: Text('เวอร์ชันปัจจุบัน: $currentVersion\nกรุณาอัปเดตเป็น $targetVersion'),
        actions: [
          TextButton(
            onPressed: () {
               Navigator.pop(context);
               _downloadAndInstall(context, apkUrl, targetVersion);
            },
            child: const Text('อัปเดตเดี๋ยวนี้'),
          ),
        ],
      ),
    );
  }

  static Future<void> _showSoftDialog(
    BuildContext context, String apkUrl, String targetVersion
  ) async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('มีเวอร์ชันใหม่'),
        content: Text('พบเวอร์ชัน $targetVersion ต้องการอัปเดตไหม?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ภายหลัง')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _downloadAndInstall(context, apkUrl, targetVersion);
            },
            child: const Text('อัปเดต'),
          ),
        ],
      ),
    );
  }

  // ---------- Core helpers ----------

  static bool _isLower(String current, String target) {
    if (target.isEmpty) return false;
    final pa = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = target.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    while (pa.length < 3) pa.add(0);
    while (pb.length < 3) pb.add(0);
    for (var i = 0; i < 3; i++) {
      if (pa[i] < pb[i]) return true;
      if (pa[i] > pb[i]) return false;
    }
    return false;
  }

  static Future<void> _downloadAndInstall(
    BuildContext context, String apkUrl, String version
  ) async {
    if (apkUrl.isEmpty) {
      _toast('ลิงก์ดาวน์โหลดไม่ถูกต้อง');
      return;
    }
    final dio = Dio();

    try {
      final dir = await getApplicationSupportDirectory();
      final savePath = '${dir.path}/update_$version.apk';
      
      final file = File(savePath);
      if (await file.exists()) await file.delete();

      DownloadUI.start(); // เรียกใช้ไฟล์ DownloadUI.dart
      
      // แสดง Dialog Progress
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => DownloadProgressDialog( // เรียกใช้ไฟล์ DownloadProgressDialog.dart
          title: 'กำลังอัปเดต...',
          percent: DownloadUI.percent,
          detail: DownloadUI.detail,
          onCancel: () {
            DownloadUI.cancel();
            Navigator.of(context).maybePop();
          },
        ),
      );

      // เริ่มโหลด
      int lastRec = 0;
      int lastEmitMs = 0;
      final sw = Stopwatch()..start();

      await dio.download(
        apkUrl,
        savePath,
        cancelToken: DownloadUI.token(),
        onReceiveProgress: (rec, total) {
          final elapsedSec = sw.elapsedMilliseconds / 1000.0;
          final speedBps = elapsedSec > 0 ? (rec - lastRec) / elapsedSec : 0.0;
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          
          if (nowMs - lastEmitMs >= 100 || rec == total) {
            DownloadUI.update(
              received: rec,
              total: total,
              speedBytesPerSec: speedBps,
            );
            lastEmitMs = nowMs;
            lastRec = rec;
            sw.reset();
          }
        },
      );

      DownloadUI.done();
      DownloadUI.installing();

      // ปิด Dialog
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();

      // ติดตั้ง
      await InstallPlugin.installApk(savePath);

    } on DioException catch (e) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      if (!CancelToken.isCancel(e)) _toast('ดาวน์โหลดล้มเหลว: ${e.message}');
    } catch (e) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      _toast('ติดตั้งล้มเหลว: $e');
    }
  }

  static void _toast(String msg) {
    // ต้องมี OverlaySupport.global ใน main.dart ถึงจะทำงาน
    showSimpleNotification(Text(msg), background: Colors.black87);
  }
}