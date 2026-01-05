// lib/utils/download_ui.dart
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

class DownloadUI {
  static final percent = ValueNotifier<double?>(0.0);
  static final detail  = ValueNotifier<String>('');
  static CancelToken? _token;

  static void start() {
    percent.value = 0.0;
    detail.value = '';
    _token = CancelToken();
  }

  static CancelToken token() => _token ?? (_token = CancelToken());

  static void update({
    required int received,
    required int total,
    required double speedBytesPerSec,
  }) {
    if (total <= 0) {
      percent.value = null;
      detail.value  = 'กำลังดาวน์โหลด…';
      return;
    }
    final p = received / total;
    percent.value = p.clamp(0.0, 1.0);

    String fmtBytes(int b) {
      const kb = 1024, mb = 1024 * 1024;
      if (b >= mb) return '${(b / mb).toStringAsFixed(1)} MB';
      if (b >= kb) return '${(b / kb).toStringAsFixed(1)} KB';
      return '$b B';
    }

    String fmtSpeed(double bps) {
      const mb = 1024.0 * 1024.0;
      const kb = 1024.0;
      if (bps >= mb) return '${(bps / mb).toStringAsFixed(1)} MB/s';
      if (bps >= kb) return '${(bps / kb).toStringAsFixed(1)} KB/s';
      return '${bps.toStringAsFixed(0)} B/s';
    }

    detail.value =
        '${fmtBytes(received)} / ${fmtBytes(total)} • ${fmtSpeed(speedBytesPerSec)}';
  }

  static void installing() {
    percent.value = null;
    detail.value  = 'กำลังติดตั้ง… โปรดรอสักครู่';
  }

  static void done() {
    percent.value = 1.0;
    detail.value  = 'ดาวน์โหลดเสร็จแล้ว';
  }

  static void cancel() {
    _token?.cancel('ผู้ใช้ยกเลิก');
  }
}
