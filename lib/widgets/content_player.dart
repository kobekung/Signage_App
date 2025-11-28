import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/layout_model.dart';
import '../services/preload_service.dart';

class ContentPlayer extends StatefulWidget {
  final SignageWidget widget;
  const ContentPlayer({super.key, required this.widget});

  @override
  State<ContentPlayer> createState() => _ContentPlayerState();
}

class _ContentPlayerState extends State<ContentPlayer> {
  // Logic การเล่น Playlist
  int _currentIndex = 0;
  List<dynamic> _playlist = [];
  Widget? _currentContent;

  @override
  void initState() {
    super.initState();
    _initPlaylist();
  }

  void _initPlaylist() {
    final props = widget.widget.properties;
    
    // แปลง Single URL เป็น Playlist เพื่อให้ logic เหมือนกัน
    if (props['url'] != null) {
      _playlist = [{
        'url': props['url'],
        'type': widget.widget.type,
        'duration': 10 // Default duration
      }];
    } else if (props['playlist'] != null) {
      _playlist = List.from(props['playlist']);
    }

    _playNext();
  }

  void _playNext() async {
    if (_playlist.isEmpty) return;
    if (_currentIndex >= _playlist.length) _currentIndex = 0;

    final item = _playlist[_currentIndex];
    final url = item['url'];
    final type = item['type'] ?? widget.widget.type;
    final duration = (item['duration'] ?? 10) as int;

    // หาไฟล์ในเครื่องก่อน
    File? cachedFile = await PreloadService.getCachedFile(url);
    
    Widget content;
    if (type == 'video') {
      content = _VideoItem(
        file: cachedFile, 
        url: url, 
        onFinished: _playNext
      );
    } else if (type == 'image') {
      content = cachedFile != null 
          ? Image.file(cachedFile, fit: BoxFit.cover)
          : Image.network(url, fit: BoxFit.cover);
      
      // ตั้งเวลาเปลี่ยนภาพ
      Future.delayed(Duration(seconds: duration), _playNext);
    } else {
      // Text / Clock / Etc.
      content = Center(
        child: Text(
          widget.widget.properties['content'] ?? widget.widget.properties['text'] ?? '',
          style: TextStyle(
            fontSize: (widget.widget.properties['fontSize'] ?? 24).toDouble(),
            color: _parseColor(widget.widget.properties['color'] ?? '#ffffff'),
          ),
        ),
      );
    }

    if (mounted) {
      setState(() {
        _currentContent = content;
      });
      if (type != 'video') _currentIndex++; // Video เปลี่ยน index เมื่อเล่นจบ
    }
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
      width: double.infinity,
      height: double.infinity,
      child: _currentContent ?? const SizedBox(),
    );
  }
}

class _VideoItem extends StatefulWidget {
  final File? file;
  final String url;
  final VoidCallback onFinished;

  const _VideoItem({this.file, required this.url, required this.onFinished});

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
      _controller.play();
      setState(() {});
    });

    _controller.addListener(() {
      if (_controller.value.position >= _controller.value.duration) {
        widget.onFinished();
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