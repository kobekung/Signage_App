// lib/utils/version_update.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:install_plugin/install_plugin.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signage_app/utils/downloadUI.dart';
import 'package:signage_app/utils/downloadprogressdialog.dart';

enum UpdateCheckResult {
  upToDate,
  softUpdateAvailable,
  forceUpdateRequired,
  failedOrAborted,
}

class VersionUpdater {
  static final _storage = const FlutterSecureStorage();
  static double? _lastPct;

  static Future<UpdateCheckResult> checkAndMaybeUpdate(
    BuildContext context, {
    bool silent = false,
  }) async {
    final base = dotenv.env['API_BASE_URL']?.trim() ?? '';
    final versionApi = '$base/companyDetail/signageApk';

    try {
      // อ่าน token / com_id
      final token = (await _storage.read(key: 'token'))?.trim();
      final comId = (await _storage.read(key: 'com_id'))?.trim();

      if (token == null || token.isEmpty || comId == null || comId.isEmpty) {
        if (!silent) _toast('ยังไม่พบ token หรือ com_id');
        return UpdateCheckResult.failedOrAborted;
      }

      final info = await PackageInfo.fromPlatform();

      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.json,
          validateStatus: (s) => s != null && s >= 200 && s < 500,
          headers: {
            'Authorization': 'Bearer $token',
            'com_id': comId, // Express จะ lowercase เป็น 'comid'
            'Accept': 'application/json',
          },
        ),
      );

      final res = await dio.get(versionApi);

      if (res.statusCode != 200) {
        if (!silent) _toast('เช็คเวอร์ชันล้มเหลว (HTTP ${res.statusCode})');
        return UpdateCheckResult.failedOrAborted;
      }

      final data = res.data is Map
          ? res.data as Map
          : json.decode(res.data as String) as Map;

      final minVersion = (data['min_supported_version'] ?? '')
          .toString()
          .trim();
      final latestVersion = (data['latest_version'] ?? '').toString().trim();
      final apkUrl = (data['apk_url'] ?? '').toString().trim();
      // final serverSha256 = (data['sha256'] ?? '').toString().trim(); // ถ้าจะใช้ตรวจไฟล์

      // เทียบเวอร์ชัน
      if (_isLower(info.version, minVersion)) {
        // บังคับอัปเดต
        await _showForceDialog(context, apkUrl, latestVersion, info.version);
        return UpdateCheckResult.forceUpdateRequired;
      } else if (_isLower(info.version, latestVersion)) {
        // มีอัปเดต (optional)
        if (!silent) {
          await _showSoftDialog(context, apkUrl, latestVersion);
        }
        return UpdateCheckResult.softUpdateAvailable;
      } else {
        if (!silent) _toast('เป็นเวอร์ชันล่าสุดแล้ว');
        return UpdateCheckResult.upToDate;
      }
    } catch (e) {
      // if (!silent) _toast('เชื่อมต่อเช็คเวอร์ชันไม่ได้: $e');
      return UpdateCheckResult.failedOrAborted;
    }
  }

  // ---------- UI helpers ----------

  static Future<void> _showForceDialog(
    BuildContext context,
    String apkUrl,
    String targetVersion,
    String currentVersion,
  ) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('บังคับอัปเดต'),
        content: Text(
          'เวอร์ชันปัจจุบัน: $currentVersion \n'
          'กรุณาอัปเดตเป็น $targetVersion เพื่อใช้งานต่อ\n',
        ),
        actions: [
          // TextButton(
          //   onPressed: () => Navigator.pop(context),
          //   child: const Text('ไม่ใช่ตอนนี้'),
          // ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _downloadAndInstall(context, apkUrl, targetVersion);
            },
            child: const Text('อัปเดตตอนนี้'),
          ),
        ],
      ),
    );
  }

  static Future<void> _showSoftDialog(
    BuildContext context,
    String apkUrl,
    String targetVersion,
  ) async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('มีเวอร์ชันใหม่'),
        content: Text('ต้องการอัปเดตเป็น $targetVersion หรือไม่'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ภายหลัง'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _downloadAndInstall(context, apkUrl, targetVersion);
            },
            child: const Text('อัปเดต'),
          ),
        ],
      ),
    );
  }

  // ---------- Core helpers ----------

  static bool _isLower(String a, String b) {
    if (b.isEmpty) return false;
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    while (pa.length < 3) pa.add(0);
    while (pb.length < 3) pb.add(0);
    for (var i = 0; i < 3; i++) {
      if (pa[i] < pb[i]) return true;
      if (pa[i] > pb[i]) return false;
    }
    return false;
  }

  static Future<void> _downloadAndInstall(
    BuildContext context, // 👈 เพิ่ม context
    String apkUrl,
    String version,
  ) async {
    if (apkUrl.isEmpty) {
      _toast('ไม่พบลิงก์ไฟล์อัปเดต');
      return;
    }
    final dio = Dio();

    try {
      final dir = await getApplicationSupportDirectory();
      final savePath = '${dir.path}/update_$version.apk';

      // เริ่ม UI
      DownloadUI.start();
      unawaited(
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => DownloadProgressDialog(
            title: 'กำลังอัปเดตเป็นเวอร์ชัน $version',
            percent: DownloadUI.percent,
            detail: DownloadUI.detail,
            onCancel: () {
              DownloadUI.cancel();
              Navigator.of(context).maybePop();
            },
          ),
        ),
      );

      // ยิงโหลด (อัปเดตตรง + throttle 100ms)
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
              total: total, // ถ้า total <= 0 จะกลายเป็นแถบ indeterminate ให้เอง
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

      await InstallPlugin.installApk(savePath);

      // ปิด Dialog
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        // ผู้ใช้กดยกเลิก
        _toast('ยกเลิกการดาวน์โหลด');
      } else {
        _toast('ดาวน์โหลดล้มเหลว: ${e.message}');
      }
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      _toast('ติดตั้งอัปเดตไม่สำเร็จ: $e');
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  static void _toast(String msg) {
    showSimpleNotification(Text(msg), background: Colors.black87);
  }
}
