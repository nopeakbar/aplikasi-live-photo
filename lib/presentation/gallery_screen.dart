import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

// ═══════════════════════════════════════════════════════════
// DATA MODEL
// ═══════════════════════════════════════════════════════════

class LivePhotoItem {
  final File photo;
  final File video;
  const LivePhotoItem({required this.photo, required this.video});
}

// ═══════════════════════════════════════════════════════════
// GALLERY SCREEN
// ═══════════════════════════════════════════════════════════

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<LivePhotoItem> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    setState(() => _isLoading = true);

    final dir = Directory('/storage/emulated/0/Pictures/Vetecam');
    if (!await dir.exists()) {
      setState(() => _isLoading = false);
      return;
    }

    final files = dir.listSync().whereType<File>().toList();

    // Ambil semua file .jpg (termasuk format lama dan format baru _MP.jpg)
    final jpgFiles = files.where((f) => f.path.endsWith('.jpg')).toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    final items = <LivePhotoItem>[];

    for (final jpg in jpgFiles) {
      final fileName = jpg.path.split('/').last;

      // FIX #3: Update parsing nama file sesuai konvensi _MP.jpg yang sudah diperbaiki.
      //
      // Format baru  : IMG_20260324_101530_MP.jpg  →  .VID_20260324_101530_MP.mp4
      // Format lama  : IMG_20260324_101530MP.jpg   →  .VID_20260324_101530MP.mp4  (backward compat)
      // Format biasa : IMG_20260324_101530.jpg     →  .VID_20260324_101530.mp4    (foto biasa, skip)
      String mp4FileName;

      if (fileName.contains('_MP.jpg')) {
        // Format baru (dengan underscore) — prioritas
        mp4FileName = fileName
            .replaceFirst('IMG_', '.VID_')
            .replaceFirst('_MP.jpg', '_MP.mp4');
      } else if (fileName.contains('MP.jpg')) {
        // Format lama (tanpa underscore) — backward compatibility
        mp4FileName = fileName
            .replaceFirst('IMG_', '.VID_')
            .replaceFirst('MP.jpg', 'MP.mp4');
      } else {
        // Foto biasa tanpa video — skip
        continue;
      }

      final mp4Path = '${jpg.parent.path}/$mp4FileName';
      final mp4 = File(mp4Path);

      if (await mp4.exists()) {
        items.add(LivePhotoItem(photo: jpg, video: mp4));
      } else {
        debugPrint('⏳ Video MP4 belum siap atau tidak ditemukan: $mp4Path');
      }
    }

    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Live Photos',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
        ),
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 0.3, color: Colors.white12),
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: Colors.white38,
                strokeWidth: 1.5,
              ),
            )
          : _items.isEmpty
          ? _buildEmpty()
          : _buildGrid(),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.motion_photos_off_outlined,
            color: Colors.white12,
            size: 56,
          ),
          const SizedBox(height: 16),
          const Text(
            'Belum ada Live Photo',
            style: TextStyle(color: Colors.white30, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return RefreshIndicator(
      onRefresh: _loadItems,
      backgroundColor: Colors.black87,
      color: Colors.white,
      child: GridView.builder(
        padding: const EdgeInsets.all(1),
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 1.5,
          mainAxisSpacing: 1.5,
        ),
        itemCount: _items.length,
        itemBuilder: (ctx, i) => LivePhotoTile(
          item: _items[i],
          onTap: () => _openFullScreen(ctx, i),
        ),
      ),
    );
  }

  void _openFullScreen(BuildContext ctx, int index) {
    Navigator.push(
      ctx,
      PageRouteBuilder(
        pageBuilder: (_, _, _) =>
            LivePhotoViewer(items: _items, initialIndex: index),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 280),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// GRID TILE — iOS Photos style
// ═══════════════════════════════════════════════════════════

class LivePhotoTile extends StatefulWidget {
  final LivePhotoItem item;
  final VoidCallback onTap;
  const LivePhotoTile({super.key, required this.item, required this.onTap});

  @override
  State<LivePhotoTile> createState() => _LivePhotoTileState();
}

class _LivePhotoTileState extends State<LivePhotoTile>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _ctrl;
  bool _isPlaying = false;
  late AnimationController _badgeAnim;
  late Animation<double> _badgeOpacity;

  @override
  void initState() {
    super.initState();
    _badgeAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _badgeOpacity = Tween(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _badgeAnim, curve: Curves.easeInOut));
  }

  Future<void> _startPlay() async {
    HapticFeedback.lightImpact();
    _ctrl = VideoPlayerController.file(widget.item.video);
    await _ctrl!.initialize();
    _ctrl!.setVolume(0);
    _ctrl!.setLooping(true);
    await _ctrl!.play();
    if (mounted) setState(() => _isPlaying = true);
  }

  Future<void> _stopPlay() async {
    await _ctrl?.pause();
    await _ctrl?.dispose();
    _ctrl = null;
    if (mounted) setState(() => _isPlaying = false);
  }

  @override
  void dispose() {
    _badgeAnim.dispose();
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPressStart: (_) => _startPlay(),
      onLongPressEnd: (_) => _stopPlay(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(widget.item.photo, fit: BoxFit.cover),
          if (_isPlaying && _ctrl != null && _ctrl!.value.isInitialized)
            VideoPlayer(_ctrl!),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 36,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x88000000), Colors.transparent],
                ),
              ),
            ),
          ),
          Positioned(
            top: 5,
            left: 5,
            child: FadeTransition(
              opacity: _badgeOpacity,
              child: _LiveBadge(small: true),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// FULL SCREEN VIEWER — iOS Live Photo behavior
// ═══════════════════════════════════════════════════════════

class LivePhotoViewer extends StatefulWidget {
  final List<LivePhotoItem> items;
  final int initialIndex;

  const LivePhotoViewer({
    super.key,
    required this.items,
    required this.initialIndex,
  });
  @override
  State<LivePhotoViewer> createState() => _LivePhotoViewerState();
}

class _LivePhotoViewerState extends State<LivePhotoViewer>
    with TickerProviderStateMixin {
  late PageController _pageCtrl;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageCtrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '${_currentIndex + 1} / ${widget.items.length}',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.white70,
          ),
        ),
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: PageView.builder(
        controller: _pageCtrl,
        itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (_, i) => _LivePhotoPage(item: widget.items[i]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// SINGLE LIVE PHOTO PAGE
// ═══════════════════════════════════════════════════════════

class _LivePhotoPage extends StatefulWidget {
  final LivePhotoItem item;
  const _LivePhotoPage({required this.item});
  @override
  State<_LivePhotoPage> createState() => _LivePhotoPageState();
}

class _LivePhotoPageState extends State<_LivePhotoPage>
    with TickerProviderStateMixin {
  VideoPlayerController? _videoCtrl;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _didFinish = false;

  late AnimationController _zoomCtrl;
  late Animation<double> _zoomAnim;
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  late AnimationController _badgePulse;
  late Animation<double> _badgeOpacity;

  late AnimationController _hintCtrl;
  late Animation<double> _hintOpacity;

  @override
  void initState() {
    super.initState();

    _zoomCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _zoomAnim = Tween<double>(
      begin: 1.0,
      end: 1.08,
    ).animate(CurvedAnimation(parent: _zoomCtrl, curve: Curves.fastOutSlowIn));
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn));
    _badgePulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _badgeOpacity = Tween<double>(
      begin: 0.6,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _badgePulse, curve: Curves.easeInOut));
    _hintCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0,
    );
    _hintOpacity = CurvedAnimation(parent: _hintCtrl, curve: Curves.easeOut);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_isPlaying) _hintCtrl.reverse();
    });
  }

  @override
  void dispose() {
    _videoCtrl?.dispose();
    _zoomCtrl.dispose();
    _fadeCtrl.dispose();
    _badgePulse.dispose();
    _hintCtrl.dispose();
    super.dispose();
  }

  Future<void> _startLive() async {
    if (_isLoading || _isPlaying) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _isLoading = true;
      _didFinish = false;
    });
    _zoomCtrl.forward();
    _hintCtrl.reverse();

    _videoCtrl?.dispose();
    _videoCtrl = VideoPlayerController.file(widget.item.video);
    await _videoCtrl!.initialize();
    _videoCtrl!.setVolume(1.0);
    _videoCtrl!.setLooping(false);
    _videoCtrl!.addListener(_onVideoTick);

    await _videoCtrl!.play();

    _fadeCtrl.forward();
    _badgePulse.repeat(reverse: true);
    if (mounted) {
      setState(() {
        _isPlaying = true;
        _isLoading = false;
      });
    }
  }

  void _onVideoTick() {
    if (_videoCtrl == null) return;
    final val = _videoCtrl!.value;
    if (val.position >= val.duration && !_didFinish) {
      _didFinish = true;
      _stopLive(autoStopped: true);
    }
  }

  Future<void> _stopLive({bool autoStopped = false}) async {
    if (!_isPlaying && !_isLoading) return;
    if (!autoStopped) HapticFeedback.lightImpact();

    await _videoCtrl?.pause();
    await _fadeCtrl.reverse();
    _zoomCtrl.reverse();
    _badgePulse.stop();
    _badgePulse.reset();
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isLoading = false;
      });
    }

    await Future.delayed(const Duration(milliseconds: 400));
    _videoCtrl?.dispose();
    _videoCtrl = null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _startLive(),
      onLongPressEnd: (_) => _stopLive(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _zoomAnim,
            builder: (_, child) =>
                Transform.scale(scale: _zoomAnim.value, child: child),
            child: Image.file(
              widget.item.photo,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),

          if (_videoCtrl != null && _videoCtrl!.value.isInitialized)
            AnimatedBuilder(
              animation: Listenable.merge([_fadeAnim, _zoomAnim]),
              builder: (_, child) => Opacity(
                opacity: _fadeAnim.value,
                child: Transform.scale(scale: _zoomAnim.value, child: child),
              ),
              child: Center(
                child: AspectRatio(
                  aspectRatio: _videoCtrl!.value.aspectRatio,
                  child: VideoPlayer(_videoCtrl!),
                ),
              ),
            ),

          if (_isLoading)
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  color: Colors.white70,
                  strokeWidth: 2,
                ),
              ),
            ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 56,
            left: 16,
            child: _isPlaying
                ? FadeTransition(
                    opacity: _badgeOpacity,
                    child: _LiveBadge(small: false),
                  )
                : _LiveBadge(small: false, staticOpacity: 0.85),
          ),

          Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar()),

          if (!_isPlaying)
            Positioned(
              bottom: 90,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _hintOpacity,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.motion_photos_on,
                          color: Colors.white60,
                          size: 13,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Tahan untuk memutar',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 20,
        top: 16,
        left: 20,
        right: 20,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          Text(
            _formatDate(widget.item.photo.lastModifiedSync()),
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          if (_isPlaying && _videoCtrl != null)
            _VideoProgressPill(controller: _videoCtrl!),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    return '${dt.day} ${months[dt.month]} ${dt.year}  '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ═══════════════════════════════════════════════════════════
// VIDEO PROGRESS PILL
// ═══════════════════════════════════════════════════════════

class _VideoProgressPill extends StatefulWidget {
  final VideoPlayerController controller;
  const _VideoProgressPill({required this.controller});
  @override
  State<_VideoProgressPill> createState() => _VideoProgressPillState();
}

class _VideoProgressPillState extends State<_VideoProgressPill> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final val = widget.controller.value;
    final total = val.duration.inMilliseconds;
    final pos = val.position.inMilliseconds;
    final pct = total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
    return Container(
      width: 80,
      height: 3,
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(2),
      ),
      child: FractionallySizedBox(
        widthFactor: pct,
        alignment: Alignment.centerLeft,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// LIVE BADGE WIDGET
// ═══════════════════════════════════════════════════════════

class _LiveBadge extends StatelessWidget {
  final bool small;
  final double staticOpacity;
  const _LiveBadge({required this.small, this.staticOpacity = 1.0});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: staticOpacity,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: small ? 5 : 8,
          vertical: small ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(small ? 0.55 : 0.65),
          borderRadius: BorderRadius.circular(small ? 4 : 6),
          border: Border.all(color: Colors.white24, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.motion_photos_on,
              color: Colors.white,
              size: small ? 9 : 12,
            ),
            SizedBox(width: small ? 3 : 4),
            Text(
              'LIVE',
              style: TextStyle(
                color: Colors.white,
                fontSize: small ? 8.5 : 11,
                fontWeight: FontWeight.w700,
                letterSpacing: small ? 0.8 : 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
