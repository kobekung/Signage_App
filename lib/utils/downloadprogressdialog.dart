import 'package:flutter/material.dart';

class DownloadProgressDialog extends StatelessWidget {
  const DownloadProgressDialog({
    super.key,
    required this.title,
    required this.percent, // 0.0..1.0 หรือ null (indeterminate)
    required this.detail,  // ข้อความรายละเอียด เช่น "12.3 / 45.7 MB • 1.2 MB/s"
    required this.onCancel,
  });

  final String title;
  final ValueNotifier<double?> percent;
  final ValueNotifier<String> detail;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  )),
              const SizedBox(height: 16),

              // % ตัวใหญ่
              ValueListenableBuilder<double?>(
                valueListenable: percent,
                builder: (_, p, __) {
                  final pctTxt =
                      p == null ? '…' : '${(p * 100).toStringAsFixed(0)}%';
                  return Text(
                    pctTxt,
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),

              // แถบความคืบหน้า
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 12,
                  child: ValueListenableBuilder<double?>(
                    valueListenable: percent,
                    builder: (_, p, __) {
                      return LinearProgressIndicator(
                        value: p, // null = indeterminate
                        minHeight: 12,
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // รายละเอียด: MB / MB • MB/s
              ValueListenableBuilder<String>(
                valueListenable: detail,
                builder: (_, txt, __) => Text(
                  txt,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ),
              const SizedBox(height: 16),

              // Row(
              //   mainAxisAlignment: MainAxisAlignment.end,
              //   children: [
              //     TextButton(onPressed: onCancel, child: const Text('ยกเลิก')),
              //   ],
              // ),
            ],
          ),
        ),
      ),
    );
  }
}
