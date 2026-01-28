import 'package:flutter/material.dart';

class DownloadProgressDialog extends StatelessWidget {
  const DownloadProgressDialog({
    super.key,
    required this.title,
    required this.percent,
    required this.detail,
    required this.onCancel,
  });

  final String title;
  final ValueNotifier<double?> percent;
  final ValueNotifier<String> detail;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    // ❌ ลบ Dialog widget ออก
    // ✅ ใช้ Card หรือ Material แทน เพื่อให้จัดแต่งขนาดได้เอง
    return Material( 
      color: Colors.transparent,
      child: Card(
        elevation: 10, // ใส่เงาให้ดูลอยขึ้นมา
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          // กำหนดความกว้างให้เล็กลง เหมาะกับการอยู่มุมจอ
          width: 320, 
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, // จัดชิดซ้าย
            children: [
              Text(title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  )),
              const SizedBox(height: 12),

              // แถบ Progress + ตัวเลข %
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        height: 8, // ลดความสูงให้ดูมินิมอล
                        child: ValueListenableBuilder<double?>(
                          valueListenable: percent,
                          builder: (_, p, __) {
                            return LinearProgressIndicator(
                              value: p,
                              backgroundColor: Colors.grey[200],
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ValueListenableBuilder<double?>(
                    valueListenable: percent,
                    builder: (_, p, __) {
                      final pctTxt = p == null ? '...' : '${(p * 100).toStringAsFixed(0)}%';
                      return Text(
                        pctTxt,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // รายละเอียด
              ValueListenableBuilder<String>(
                valueListenable: detail,
                builder: (_, txt, __) => Text(
                  txt,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}