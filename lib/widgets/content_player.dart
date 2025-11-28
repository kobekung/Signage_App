import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart'; // อย่าลืม pub get
import '../models/layout_model.dart';
import '../services/preload_service.dart';

class ContentPlayer extends StatefulWidget {
  final SignageWidget widget;
  const ContentPlayer({super.key, required this.widget});

  @override
  State<ContentPlayer> createState() => _ContentPlayerState();
}

class _ContentPlayerState extends State<ContentPlayer> {
  int _currentIndex = 0;
  List<dynamic> _playlist = [];
  Widget? _currentContent;
  Timer? _imageTimer;

  @override
  void initState() {
    super.initState();
    _initPlaylist();
  }

  @override
  void dispose() {
    _imageTimer?.cancel();
    super.dispose();
  }

  void _initPlaylist() {
    final props = widget.widget.properties;
    
    // แปลงให้เป็น Playlist เสมอ เพื่อลดความซับซ้อน
    if (props['playlist'] != null && (props['playlist'] as List).isNotEmpty) {
      _playlist = List.from(props['playlist']);
    } else if (props['url'] != null || props['text'] != null) {
      // กรณีมีแค่ item เดียว
      _playlist = [{
        'url': props['url'] ?? '',
        'text': props['text'] ?? props['content'],
        'type': widget.widget.type,
        'duration': 10,
        ...props // ใส่ props อื่นๆ เข้าไปด้วย (เช่น speed, direction)
      }];
    }

    _playNext();
  }

  void _playNext() async {
    if (!mounted) return;
    if (_playlist.isEmpty) return;

    // วนลูป index
    if (_currentIndex >= _playlist.length) {
      _currentIndex = 0;
    }

    final item = _playlist[_currentIndex];
    final type = item['type'] ?? widget.widget.type;
    // แปลง duration เป็น int (เผื่อมาเป็น string)
    int duration = 10;
    if (item['duration'] != null) {
      duration = int.tryParse(item['duration'].toString()) ?? 10;
    }

    Widget content;

    // --- CASE 1: VIDEO ---
    if (type == 'video') {
      final url = item['url'];
      File? cachedFile = await PreloadService.getCachedFile(url);
      
      content = _VideoItem(
        // ใช้ Key เพื่อบังคับให้สร้าง Player ใหม่เมื่อ URL หรือ Index เปลี่ยน
        key: ValueKey("$url-$_currentIndex"), 
        file: cachedFile, 
        url: url,
        isLooping: _playlist.length == 1, // ถ้ามีคลิปเดียวให้ Loop ในตัว Player เลย
        onFinished: () {
          // ถ้ามีหลายคลิป พอมันจบให้เรียก _playNext
          if (_playlist.length > 1) {
            _currentIndex++;
            _playNext();
          }
        }
      );
    } 
    
    // --- CASE 2: IMAGE ---
    else if (type == 'image') {
      final url = item['url'];
      File? cachedFile = await PreloadService.getCachedFile(url);
      
      content = cachedFile != null 
          ? Image.file(cachedFile, fit: BoxFit.cover)
          : Image.network(url, fit: BoxFit.cover);
      
      // ตั้งเวลาเปลี่ยนภาพ
      _imageTimer?.cancel();
      _imageTimer = Timer(Duration(seconds: duration), () {
        _currentIndex++;
        _playNext();
      });
    } 
    
    // --- CASE 3: WEBVIEW ---
    else if (type == 'webview') {
      final url = item['url'] ?? 'https://google.com';
      content = _WebviewItem(url: url);
      // Webview มักจะเปิดค้างไว้ ไม่เปลี่ยนหน้าเอง (เว้นแต่จะใส่ duration)
    }

    // --- CASE 4: TICKER (ตัววิ่ง) ---
    else if (type == 'ticker') {
      content = _TickerItem(
        text: item['text'] ?? '',
        color: item['textColor'] ?? item['color'] ?? '#ffffff',
        fontSize: item['fontSize'] ?? 24,
        speed: item['speed'] ?? 50,
      );
    }

    // --- CASE 5: TEXT (ธรรมดา) ---
    else {
      content = Center(
        child: Text(
          item['text'] ?? item['content'] ?? '',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: double.tryParse((item['fontSize'] ?? 24).toString()) ?? 24,
            color: _parseColor(item['color'] ?? '#ffffff'),
          ),
        ),
      );
    }

    if (mounted) {
      setState(() {
        _currentContent = content;
      });
    }
  }

  Color _parseColor(String? hex) {
    if (hex == null) return Colors.white;
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) { return Colors.white; }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      child: _currentContent ?? const SizedBox(),
    );
  }
}

// ==========================================
// Sub-Widgets (Video, Webview, Ticker)
// ==========================================

class _VideoItem extends StatefulWidget {
  final File? file;
  final String url;
  final bool isLooping;
  final VoidCallback onFinished;

  const _VideoItem({
    super.key, 
    this.file, 
    required this.url, 
    required this.isLooping,
    required this.onFinished
  });

  @override
  State<_VideoItem> createState() => _VideoItemState();
}

class _VideoItemState extends State<_VideoItem> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    if (widget.file != null) {
      _controller = VideoPlayerController.file(widget.file!);
    } else {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    }

    _controller.initialize().then((_) {
      if (mounted) {
        _controller.setLooping(widget.isLooping); // ตั้งค่า Loop ตรงนี้
        _controller.play();
        setState(() {});
      }
    });

    _controller.addListener(() {
      if (_controller.value.isInitialized && 
          !_controller.value.isPlaying && 
          _controller.value.position >= _controller.value.duration) {
        if (!widget.isLooping) {
           widget.onFinished();
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) return const Center(child: CircularProgressIndicator());
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: _controller.value.size.width,
        height: _controller.value.size.height,
        child: VideoPlayer(_controller),
      ),
    );
  }
}

class _WebviewItem extends StatefulWidget {
  final String url;
  const _WebviewItem({required this.url});

  @override
  State<_WebviewItem> createState() => _WebviewItemState();
}

class _WebviewItemState extends State<_WebviewItem> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}

class _TickerItem extends StatefulWidget {
  final String text;
  final String color;
  final dynamic fontSize;
  final dynamic speed;

  const _TickerItem({required this.text, required this.color, this.fontSize, this.speed});

  @override
  State<_TickerItem> createState() => _TickerItemState();
}

class _TickerItemState extends State<_TickerItem> with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  late AnimationController _animationController;
  
  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _animationController = AnimationController(
      vsync: this, 
      duration: const Duration(seconds: 10) // ค่าเริ่มต้น เดี๋ยวคำนวณใหม่
    );
    
    // เริ่มวิ่งหลังจากวาดเฟรมแรกเสร็จ
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
  }

  void _startScrolling() {
    if (!_scrollController.hasClients) return;
    
    double maxScroll = _scrollController.position.maxScrollExtent;
    double screenWidth = MediaQuery.of(context).size.width;
    // คำนวณเวลาตามความยาวข้อความและความเร็ว (speed ยิ่งมากยิ่งเร็ว -> เวลาต้องน้อย)
    // สูตรสมมติ: (ระยะทาง / speed) * factor
    double speedVal = double.tryParse(widget.speed.toString()) ?? 50;
    int durationSec = ((maxScroll + screenWidth) / speedVal).round();
    if (durationSec < 2) durationSec = 2;

    _animationController.duration = Duration(seconds: durationSec);
    
    // สร้าง Loop Animation
    _animationController.addListener(() {
      if (_scrollController.hasClients) {
        // คำนวณตำแหน่ง: วิ่งจากขวาไปซ้าย หรือซ้ายไปขวา
        // แบบง่าย: วิ่งจาก 0 ไปสุด
        double offset = _animationController.value * maxScroll;
        _scrollController.jumpTo(offset);
      }
    });

    _animationController.repeat(); 
  }

  @override
  void dispose() {
    _animationController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Color _parseColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) { return Colors.white; }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(), // ห้ามใช้นิ้วเลื่อน
        child: Row(
          children: [
            // เว้นว่างขอบจอก่อนเริ่ม
            SizedBox(width: MediaQuery.of(context).size.width), 
            Text(
              widget.text,
              style: TextStyle(
                fontSize: double.tryParse(widget.fontSize.toString()) ?? 24,
                color: _parseColor(widget.color),
                fontWeight: FontWeight.bold,
              ),
            ),
            // เว้นว่างท้ายข้อความ
            SizedBox(width: MediaQuery.of(context).size.width),
          ],
        ),
      ),
    );
  }
}