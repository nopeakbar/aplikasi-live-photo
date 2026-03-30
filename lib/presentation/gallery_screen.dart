import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import '../core/video_processor.dart';

// ═══════════════════════════════════════════════════════════
// DATA MODEL & ENUM
// ═══════════════════════════════════════════════════════════

class LivePhotoItem {
  final File photo;
  final File video;
  const LivePhotoItem({required this.photo, required this.video});
}

// TAMBAHAN: Enum untuk jenis efek Live Photo
enum LiveEffect { live, loop, bounce, longExposure, veteGrading }

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
      String mp4FileName;
      if (fileName.contains('_MP.jpg')) {
        // Format baru (dengan underscore)
        mp4FileName = fileName
            .replaceFirst('IMG_', '.VID_')
            .replaceFirst('_MP.jpg', '_MP.mp4');
      } else if (fileName.contains('MP.jpg')) {
        // Format lama (tanpa underscore)
        mp4FileName = fileName
            .replaceFirst('IMG_', '.VID_')
            .replaceFirst('MP.jpg', 'MP.mp4');
      } else {
        // Foto biasa tanpa video
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
        pageBuilder: (context, animation, secondaryAnimation) =>
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
    _ctrl!.setVolume(0); // Grid selalu mute
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
              child: const _LiveBadge(small: true),
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

  void _shareToInstagram() async {
    final String filePath = widget.items[_currentIndex].photo.path;
    final params = ShareParams(
      files: [XFile(filePath)],
      text: 'Cek Live Photo gue pakai Vetecam!',
    );
    await SharePlus.instance.share(params);
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
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share_rounded, size: 22),
            onPressed: _shareToInstagram,
          ),
          // TAMBAHAN: Tombol Trim/Edit (Kosmetik / Placeholder)
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Fitur Trim Video membutuhkan package video_editor',
                  ),
                ),
              );
            },
            child: const Text(
              'Edit',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
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
  // State untuk Efek & Audio
  LiveEffect _currentEffect = LiveEffect.live;
  bool _isMuted = false;
  // State untuk FFmpeg
  bool _isProcessingEffect = false;
  File? _processedVideoFile;
  File? _longExposureImageFile;

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
    if (_isLoading || _isPlaying || _isProcessingEffect) return;
    HapticFeedback.heavyImpact();

    setState(() {
      _isLoading = true;
      _didFinish = false;
    });

    _zoomCtrl.forward();
    _hintCtrl.reverse();

    _videoCtrl?.dispose();

    // Gunakan file hasil edit (Bounce atau Graded) jika ada, kalau tidak gunakan video asli
    final targetVideo = _processedVideoFile ?? widget.item.video;

    _videoCtrl = VideoPlayerController.file(targetVideo);
    await _videoCtrl!.initialize();

    _videoCtrl!.setVolume(_isMuted ? 0.0 : 1.0);
    // Atur looping otomatis untuk efek Loop dan Bounce
    _videoCtrl!.setLooping(
      _currentEffect == LiveEffect.loop || _currentEffect == LiveEffect.bounce,
    );

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
    // Cegah didFinish jika efeknya Loop atau Bounce
    if (val.position >= val.duration &&
        !_didFinish &&
        _currentEffect != LiveEffect.loop &&
        _currentEffect != LiveEffect.bounce) {
      _didFinish = true;
      _stopLive(autoStopped: true);
    }
  }

  Future<void> _stopLive({bool autoStopped = false}) async {
    // Jika efeknya Loop atau Bounce, video tidak berhenti saat layar dilepas
    if ((_currentEffect == LiveEffect.loop ||
            _currentEffect == LiveEffect.bounce) &&
        !autoStopped) {
      return;
    }

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

  void _showEffectsMenu(BuildContext context) {
    HapticFeedback.mediumImpact();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Efek Live Photo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildEffectOption(
                        LiveEffect.live,
                        'Live',
                        Icons.motion_photos_on,
                      ),
                      const SizedBox(width: 16),
                      _buildEffectOption(
                        LiveEffect.loop,
                        'Loop',
                        Icons.loop_rounded,
                      ),
                      const SizedBox(width: 16),
                      _buildEffectOption(
                        LiveEffect.bounce,
                        'Pantulkan',
                        Icons.compare_arrows_rounded,
                      ),
                      const SizedBox(width: 16),
                      _buildEffectOption(
                        LiveEffect.longExposure,
                        'Eksposur\nPanjang',
                        Icons.camera_enhance_rounded,
                      ),
                      const SizedBox(width: 16),
                      _buildEffectOption(
                        LiveEffect.veteGrading,
                        'Vete Grading',
                        Icons.color_lens_rounded,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEffectOption(LiveEffect effect, String title, IconData icon) {
    final isSelected = _currentEffect == effect;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _currentEffect = effect);
        Navigator.pop(context);
        _applyEffect(effect);
      },
      child: Column(
        children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.transparent,
                width: 2,
              ),
              color: isSelected ? Colors.white24 : Colors.white12,
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.white70,
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyEffect(LiveEffect effect) async {
    // Reset file efek sebelumnya dan atur status loading
    setState(() {
      _isProcessingEffect = true;
      _processedVideoFile = null;
      _longExposureImageFile = null;
    });

    if (effect == LiveEffect.live) {
      _videoCtrl?.setLooping(false);
      setState(() => _isProcessingEffect = false);
      _startLive();
    } else if (effect == LiveEffect.loop) {
      _videoCtrl?.setLooping(true);
      setState(() => _isProcessingEffect = false);
      _startLive(); // Otomatis main terus
    } else if (effect == LiveEffect.bounce) {
      // Panggil FFmpeg untuk bikin video reverse & digabung
      final bounceFile = await VideoProcessor.generateBounce(widget.item.video);

      if (bounceFile != null && mounted) {
        setState(() {
          _processedVideoFile = bounceFile;
          _isProcessingEffect = false;
        });
        _startLive();
      } else if (mounted) {
        setState(() => _isProcessingEffect = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gagal menerapkan efek Bounce.')),
        );
      }
    } else if (effect == LiveEffect.longExposure) {
      // Panggil FFmpeg untuk tmix frame menjadi satu gambar estetik
      final longExpFile = await VideoProcessor.generateLongExposure(
        widget.item.video,
      );

      if (longExpFile != null && mounted) {
        await _videoCtrl?.pause(); // Hentikan video jika sedang jalan
        setState(() {
          _longExposureImageFile = longExpFile;
          _isProcessingEffect = false;
          _isPlaying = false;
        });
      } else if (mounted) {
        setState(() => _isProcessingEffect = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gagal menerapkan efek Long Exposure.')),
        );
      }
    } else if (effect == LiveEffect.veteGrading) {
      // Panggil FFmpeg untuk nerapin color grading
      final gradedFile = await VideoProcessor.applyLUT(
        widget.item.video,
        'assets/luts/biru-vete1.png', // Pastikan nama ini sesuai dengan di pubspec lu
      );

      if (gradedFile != null && mounted) {
        setState(() {
          _processedVideoFile = gradedFile;
          _isProcessingEffect = false;
        });
        _startLive();
      } else if (mounted) {
        setState(() => _isProcessingEffect = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gagal menerapkan Vete Grading.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _startLive(),
      onLongPressEnd: (_) => _stopLive(),
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! < -300) {
          _showEffectsMenu(context);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Layer Gambar Asli
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

          // 2. Layer Efek Long Exposure (Gambar Tumpukan Frame)
          if (_currentEffect == LiveEffect.longExposure &&
              _longExposureImageFile != null)
            AnimatedBuilder(
              animation: _zoomAnim,
              builder: (_, child) =>
                  Transform.scale(scale: _zoomAnim.value, child: child),
              child: Image.file(
                _longExposureImageFile!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),

          // 3. Layer Video (Untuk Live Asli, Loop, atau Bounce)
          if (_videoCtrl != null &&
              _videoCtrl!.value.isInitialized &&
              _currentEffect != LiveEffect.longExposure)
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

          // 4. Loading Overlay FFmpeg Pemrosesan Efek
          if (_isProcessingEffect)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Memproses Efek...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

          // 5. Ikon Loading saat Play Video
          if (_isLoading && !_isProcessingEffect)
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

          // Posisi Ikon Live
          Positioned(
            top: MediaQuery.of(context).padding.top + 56,
            left: 16,
            child: _isPlaying
                ? FadeTransition(
                    opacity: _badgeOpacity,
                    child: const _LiveBadge(small: false),
                  )
                : const _LiveBadge(small: false, staticOpacity: 0.85),
          ),

          // Tombol Mute / Unmute
          Positioned(
            top: MediaQuery.of(context).padding.top + 50,
            right: 16,
            child: IconButton(
              icon: Icon(
                _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                color: Colors.white,
                size: 24,
                shadows: const [Shadow(color: Colors.black45, blurRadius: 4)],
              ),
              onPressed: () {
                setState(() {
                  _isMuted = !_isMuted;
                  if (_videoCtrl != null) {
                    _videoCtrl!.setVolume(_isMuted ? 0.0 : 1.0);
                  }
                });
              },
            ),
          ),

          Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar()),

          if (!_isPlaying &&
              _currentEffect != LiveEffect.loop &&
              _currentEffect != LiveEffect.bounce)
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
                          'Tahan atau Usap ke Atas',
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
