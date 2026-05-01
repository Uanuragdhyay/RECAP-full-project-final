// Crowd Monitoring Dashboard - Flutter Web
// Single-file production-style UI for FastAPI backend
// Backend: POST /upload  +  ws://127.0.0.1:8000/ws
//
// pubspec.yaml dependencies required:
//   flutter:
//     sdk: flutter
//   web_socket_channel: ^3.0.1
//   http: ^1.2.2
//   file_picker: ^8.1.4
//   video_player: ^2.9.2
//   fl_chart: ^0.69.0
//   google_fonts: ^6.2.1
//
// Run with:  flutter run -d chrome

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// =============================================================================
// CONFIG
// =============================================================================
const String kBackendBase = 'http://127.0.0.1:8000';
const String kBackendWs = 'ws://127.0.0.1:8000/ws';

// Frame size sent by backend (used to scale heatmap coordinates)
const double kFrameW = 640;
const double kFrameH = 360;

// Crowd thresholds
const int kSafeMax = 20;
const int kDenseMax = 60;

// Responsive breakpoints
const double kBpMobile = 640;
const double kBpTablet = 1024;
const double kBpDesktop = 1280;

// =============================================================================
// THEME TOKENS
// =============================================================================
class AppColors {
  // Premium SaaS background — deep navy with hints of indigo & teal,
  // brighter than pure black for a real production dashboard feel.
  static const bg = Color(0xFF0B1226);
  static const bgGradTop = Color(0xFF152042);
  static const bgGradMid = Color(0xFF0E1730);
  static const bgGradBottom = Color(0xFF080C1C);
  static const surface = Color(0xFF131B33);
  static const surfaceAlt = Color(0xFF1A2240);
  static const surfaceHi = Color(0xFF202B4E);
  static const border = Color(0xFF293356);
  static const borderHi = Color(0xFF364372);
  static const textPrimary = Color(0xFFE7ECF5);
  static const textSecondary = Color(0xFFB4BCD0);
  static const textMuted = Color(0xFF8892A6);

  static const accent = Color(0xFF6C8CFF);
  static const accentHi = Color(0xFF8AA3FF);
  static const accent2 = Color(0xFF22D3EE);
  static const accent3 = Color(0xFFA855F7);
  static const success = Color(0xFF22C55E);
  static const warn = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);
}

class AppRadius {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 18.0;
  static const xl = 22.0;
}

// =============================================================================
// RESPONSIVE HELPERS
// =============================================================================
enum ScreenSize { mobile, tablet, desktop, wide }

ScreenSize screenOf(double w) {
  if (w < kBpMobile) return ScreenSize.mobile;
  if (w < kBpTablet) return ScreenSize.tablet;
  if (w < kBpDesktop) return ScreenSize.desktop;
  return ScreenSize.wide;
}

double pad(ScreenSize s) {
  switch (s) {
    case ScreenSize.mobile:
      return 14;
    case ScreenSize.tablet:
      return 20;
    case ScreenSize.desktop:
      return 28;
    case ScreenSize.wide:
      return 36;
  }
}

double gap(ScreenSize s) =>
    s == ScreenSize.mobile ? 14 : (s == ScreenSize.tablet ? 18 : 22);

// =============================================================================
// MAIN
// =============================================================================
void main() {
  runApp(const CrowdApp());
}

class CrowdApp extends StatelessWidget {
  const CrowdApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'Crowd Monitor',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: AppColors.bg,
        textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
          bodyColor: AppColors.textPrimary,
          displayColor: AppColors.textPrimary,
        ),
        colorScheme: base.colorScheme.copyWith(
          primary: AppColors.accent,
          secondary: AppColors.accent2,
          surface: AppColors.surface,
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: AppColors.surfaceHi,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          textStyle: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

// =============================================================================
// DASHBOARD
// =============================================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Backend
  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  bool _connected = false;
  bool _paused = false;
  bool _uploading = false;
  bool _analyzing = false;
  String? _statusMsg;
  double _densityScore = 0.0;

  // Video
  VideoPlayerController? _videoController;
  Uint8List? _videoBytes;
  String? _videoName;

  // Live data
  int _currentCount = 0;
  int _peakCount = 0;
  final List<FlSpot> _series = [];
  final List<int> _recent = []; // for trend
  List<Offset> _heatmap = [];
  final List<_AlertItem> _alerts = [];

  static const int _maxSeries = 80;

  @override
  void dispose() {
    _wsSub?.cancel();
    _channel?.sink.close();

    if (_videoController != null) {
      _videoController!.dispose();
      _videoController = null;
    }

    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Upload
  // ---------------------------------------------------------------------------
  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    if (file.bytes == null) return;

    // 🔥 STOP previous session FIRST (VERY IMPORTANT)
    _wsSub?.cancel();
    _channel?.sink.close();
    _channel = null;

    if (_videoController != null) {
      await _videoController!.pause();
      await _videoController!.dispose();
      _videoController = null; // 🔥 critical
    }

    setState(() {
      _uploading = true;
      _statusMsg = 'Uploading ${file.name}…';
      _videoBytes = file.bytes;
      _videoName = file.name;

      // 🔥 RESET UI STATE
      _series.clear();
      _recent.clear();
      _alerts.clear();
      _heatmap.clear();

      _currentCount = 0;
      _peakCount = 0;

      _analyzing = false;
      _connected = false;
      _paused = false;
    });

    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$kBackendBase/upload'),
      );

      req.files.add(
        http.MultipartFile.fromBytes(
          'file',
          file.bytes!,
          filename: file.name,
        ),
      );

      final resp = await req.send();
      final body = await resp.stream.bytesToString();

      if (resp.statusCode != 200) {
        throw Exception('Upload failed (${resp.statusCode}): $body');
      }

      // 🔥 SAFE video initialization
      await _initVideoFromBytes(file.bytes!);

      if (!mounted) return;

      setState(() {
        _statusMsg = 'Uploaded. Ready to analyze.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMsg = 'Upload error: $e');
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  Future<void> _initVideoFromBytes(Uint8List bytes) async {
    // 🔥 Dispose safely
    if (_videoController != null) {
      await _videoController!.pause();
      await _videoController!.dispose();
      _videoController = null; // VERY IMPORTANT
    }

    final blob = _makeBlobUrl(bytes, 'video/mp4');
    final controller = VideoPlayerController.networkUrl(Uri.parse(blob));

    await controller.initialize();

    // ❌ remove looping
    controller.setLooping(false);

    // 🔥 detect video end and stop
    controller.addListener(() {
      if (controller.value.position >= controller.value.duration &&
          !controller.value.isPlaying) {
        controller.pause();

        // 🔥 STOP ANALYSIS ALSO
        _channel?.sink.close();
        _wsSub?.cancel();

        setState(() {
          _connected = false;
          _analyzing = false;
          _statusMsg = 'Video finished.';
        });
        _pushAlert('Analysis finished', AlertLevel.info);
      }
    });

    // Assign AFTER init
    setState(() {
      _videoController = controller;
    });
  }

  String _makeBlobUrl(Uint8List bytes, String mime) {
    try {
      final b64 = base64Encode(bytes);
      return 'data:$mime;base64,$b64';
    } catch (_) {
      return '';
    }
  }

  // ---------------------------------------------------------------------------
  // WebSocket
  // ---------------------------------------------------------------------------
  void _startAnalysis() {
    if (_analyzing) return;
    _series.clear();
    _recent.clear();
    _alerts.clear();
    _peakCount = 0;
    _currentCount = 0;

    try {
      final ch = WebSocketChannel.connect(Uri.parse(kBackendWs));
      _channel = ch;
      _wsSub = ch.stream.listen(
        _onWsMessage,
        onError: (e) => _pushAlert('Connection error: $e', AlertLevel.danger),
        onDone: () {
          setState(() {
            _connected = false;
            _analyzing = false;
          });
        },
      );
      setState(() {
        _connected = true;
        _analyzing = true;
        _paused = false;
        _statusMsg = 'Streaming live analytics…';
      });
      _pushAlert('Analysis started', AlertLevel.info);
      _videoController?.play();
    } catch (e) {
      _pushAlert('Failed to connect: $e', AlertLevel.danger);
    }
  }

  void _togglePause() {
    if (!_connected) return;
    _paused = !_paused;
    _channel?.sink.add(_paused ? 'pause' : 'resume');
    if (_paused) {
      _videoController?.pause();
    } else {
      _videoController?.play();
    }
    setState(() {});
  }

  void _onWsMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      if (data['done'] == true) {
        _channel?.sink.close();
        _wsSub?.cancel();

        setState(() {
          _connected = false;
          _analyzing = false;
          _statusMsg = 'Stream finished.';
        });

        _pushAlert('Analysis complete', AlertLevel.info);
        return;
      }
      final count = (data['count'] as num?)?.toInt() ?? 0;
      final hm = (data['heatmap'] as List?) ?? const [];
      final points = <Offset>[];
      for (final p in hm) {
        if (p is List && p.length >= 2) {
          points.add(Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()));
        }
      }
      _ingest(count, points);
    } catch (_) {/* ignore malformed */}
  }

  void _ingest(int count, List<Offset> points) {
    final t = _series.isEmpty ? 0.0 : _series.last.x + 1;
    _series.add(FlSpot(t, count.toDouble()));
    if (_series.length > _maxSeries) _series.removeAt(0);

    _recent.add(count);
    if (_recent.length > 6) _recent.removeAt(0);

    final prev = _currentCount;
    _currentCount = count;

    if (count > _peakCount) _peakCount = count;

    // ================= 🔥 IMPROVED HEATMAP DISTRIBUTION =================
    List<Offset> expandedPoints = [];

    if (points.isNotEmpty) {
      final rand = math.Random();

      for (int i = 0; i < _currentCount; i++) {
        final base = points[i % points.length];
        double spreadX = rand.nextDouble() * kFrameW;
        double spreadY = base.dy + rand.nextDouble() * 30 - 15;
        spreadX = spreadX.clamp(0, kFrameW);
        spreadY = spreadY.clamp(0, kFrameH);
        expandedPoints.add(Offset(spreadX, spreadY));
      }
    }

    _heatmap = expandedPoints;

    _densityScore = points.length / 50.0;
    _densityScore = _densityScore.clamp(0.0, 2.0);

    if (_currentCount > kDenseMax || _densityScore > 1.2) {
      _pushAlert(
        'High crowd density detected ($_currentCount people)',
        AlertLevel.danger,
      );
    }

    if (prev > 0 && (_currentCount - prev) >= 15) {
      _pushAlert(
        'Sudden spike (+${_currentCount - prev})',
        AlertLevel.warn,
      );
    }

    if (_densityScore > 1.5 && _recent.length >= 3) {
      _pushAlert(
        'Crowd getting compressed (high density)',
        AlertLevel.warn,
      );
    }

    setState(() {});
  }

  void _pushAlert(String msg, AlertLevel level) {
    _alerts.add(_AlertItem(msg, level, DateTime.now()));
    if (_alerts.length > 30) {
      _alerts.removeAt(0);
    }
  }

  // ---------------------------------------------------------------------------
  // Derived
  // ---------------------------------------------------------------------------
  String get _statusLabel {
    if (_currentCount == 0) return 'No Crowd';
    if (_currentCount < 10 && _densityScore < 0.4) return 'Safe';
    if (_currentCount < 25 && _densityScore < 0.7) return 'Normal';
    if (_currentCount < 80 || _densityScore < 1.3) return 'Dense';
    return 'Overcrowded';
  }

  String _getStabilityLabel() {
    if (_recent.length < 4) return "Calculating";
    int volatility = 0;
    for (int i = 1; i < _recent.length; i++) {
      volatility += (_recent[i] - _recent[i - 1]).abs();
    }
    if (volatility < 10) return "Very Stable";
    if (volatility < 25) return "Moderate";
    return "Highly Unstable";
  }

  Color get _statusColor {
    if (_currentCount == 0) return AppColors.textMuted;
    if (_currentCount < 15 && _densityScore < 0.5) return AppColors.success;
    if (_currentCount < 50 && _densityScore < 1.0) return AppColors.accent;
    if (_currentCount < 100 || _densityScore < 1.4) return AppColors.warn;
    return AppColors.danger;
  }

  String get _trendLabel {
    if (_recent.length < 4) return 'Analyzing';
    int diff = _recent.last - _recent.first;
    if (diff >= 10) return 'Rising';
    if (diff <= -10) return 'Falling';
    int volatility = 0;
    for (int i = 1; i < _recent.length; i++) {
      volatility += (_recent[i] - _recent[i - 1]).abs();
    }
    if (volatility > 20) return 'Unstable';
    return 'Stable';
  }

  IconData get _trendIcon {
    switch (_trendLabel) {
      case 'Rising':
        return Icons.trending_up_rounded;
      case 'Falling':
        return Icons.trending_down_rounded;
      case 'Unstable':
        return Icons.sync_problem_rounded;
      case 'Analyzing':
        return Icons.hourglass_empty_rounded;
      default:
        return Icons.trending_flat_rounded;
    }
  }

  // ---------------------------------------------------------------------------
  // REAL-TIME AI-STYLE SUMMARY
  // Generated dynamically from live state — no hardcoded values.
  // ---------------------------------------------------------------------------
  String get _summaryHeadline {
    if (!_analyzing && _currentCount == 0 && _peakCount == 0) {
      return 'Awaiting live stream';
    }
    final status = _statusLabel;
    final trend = _trendLabel;
    if (status == 'Overcrowded') return 'Critical density detected';
    if (status == 'Dense' && trend == 'Rising') return 'Congestion building up';
    if (status == 'Dense') return 'Crowd density elevated';
    if (trend == 'Rising') return 'Activity trending upward';
    if (trend == 'Falling') return 'Crowd dispersing gradually';
    if (trend == 'Unstable') return 'Fluctuating crowd flow';
    if (status == 'Safe') return 'Conditions nominal';
    return 'Stable monitoring active';
  }

  String get _summaryText {
    if (!_analyzing && _currentCount == 0 && _peakCount == 0) {
      return 'Stream not started. Upload a video and begin analysis to see '
          'real-time crowd insights, density estimates and operational alerts.';
    }

    final status = _statusLabel;
    final trend = _trendLabel;
    final stability = _getStabilityLabel();
    final density = _densityScore;
    final densityWord = density < 0.4
        ? 'low'
        : density < 0.9
            ? 'moderate'
            : density < 1.4
                ? 'high'
                : 'critical';

    final parts = <String>[];

    // Line 1 — current state
    parts.add(
      'Crowd of $_currentCount currently observed with $densityWord density '
      '(score ${density.toStringAsFixed(2)}); status reads "$status".',
    );

    // Line 2 — trend / movement insight
    if (trend == 'Rising') {
      parts.add(
        'A rising trend is detected — congestion may build up if the inflow continues.',
      );
    } else if (trend == 'Falling') {
      parts.add(
        'Counts are easing off, suggesting the area is gradually clearing.',
      );
    } else if (trend == 'Unstable') {
      parts.add(
        'Movement is volatile; expect rapid shifts in occupancy over the next moments.',
      );
    } else if (trend == 'Stable') {
      parts.add('Flow is steady with no significant directional change.');
    } else {
      parts.add('Collecting samples to establish a reliable trend baseline.');
    }

    // Line 3 — peak / stability commentary
    if (_peakCount > 0 && _peakCount >= _currentCount * 1.3 && _currentCount > 0) {
      parts.add(
        'Peak load of $_peakCount reached earlier — this is a high-activity zone worth watching.',
      );
    } else if (_peakCount > 0) {
      parts.add(
        'Stability: $stability · session peak $_peakCount.',
      );
    }

    // Line 4 — recommended attention
    if (status == 'Overcrowded') {
      parts.add('Recommend immediate crowd-control measures.');
    } else if (status == 'Dense') {
      parts.add('Advise monitoring exits and limiting new entries.');
    }

    return parts.join(' ');
  }

  Color get _summaryAccent {
    switch (_statusLabel) {
      case 'Overcrowded':
        return AppColors.danger;
      case 'Dense':
        return AppColors.warn;
      case 'Safe':
        return AppColors.success;
      default:
        return AppColors.accent2;
    }
  }

  IconData get _summaryIcon {
    switch (_statusLabel) {
      case 'Overcrowded':
        return Icons.warning_amber_rounded;
      case 'Dense':
        return Icons.groups_2_rounded;
      case 'Safe':
        return Icons.verified_rounded;
      default:
        return Icons.auto_awesome_rounded;
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: [0.0, 0.55, 1.0],
            colors: [
              AppColors.bgGradTop,
              AppColors.bgGradMid,
              AppColors.bgGradBottom,
            ],
          ),
        ),
        child: Stack(
          children: [
            // Layered ambient lighting — premium dashboard feel
            Positioned(
              top: -160,
              left: -120,
              child: _ambientGlow(AppColors.accent.withOpacity(0.28), 520),
            ),
            Positioned(
              top: -60,
              right: -140,
              child: _ambientGlow(AppColors.accent3.withOpacity(0.22), 480),
            ),
            Positioned(
              bottom: -180,
              left: -100,
              child: _ambientGlow(AppColors.accent2.withOpacity(0.18), 540),
            ),
            Positioned(
              bottom: -120,
              right: -60,
              child: _ambientGlow(AppColors.accentHi.withOpacity(0.14), 420),
            ),
            // Soft top vignette for depth
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.center,
                      colors: [
                        Colors.white.withOpacity(0.03),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(builder: (context, c) {
                final size = screenOf(c.maxWidth);
                final p = pad(size);
                final g = gap(size);
                final isWide = size == ScreenSize.desktop ||
                    size == ScreenSize.wide;

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1600),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(p),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Header(
                            size: size,
                            connected: _connected,
                            paused: _paused,
                            analyzing: _analyzing,
                            uploading: _uploading,
                            videoName: _videoName,
                            onUpload: _pickAndUpload,
                            onStart: _startAnalysis,
                            onTogglePause: _togglePause,
                          ),
                          SizedBox(height: g),
                          _CrowdInsightsHeader(
                            count: _currentCount,
                            peak: _peakCount,
                            status: _statusLabel,
                            statusColor: _statusColor,
                            trend: _trendLabel,
                            trendIcon: _trendIcon,
                            connected: _connected,
                            analyzing: _analyzing,
                          ),
                          SizedBox(height: g),
                          isWide
                              ? LayoutBuilder(builder: (ctx, rc) {
                                  // Equal widths so both 16:9 AspectRatios
                                  // produce IDENTICAL inner heights — no
                                  // empty space below either card.
                                  final innerW = (rc.maxWidth - g) / 2;
                                  // 16:9 canvas + card chrome
                                  // (padding 18*2 = 36 + header 30 + spacer 14)
                                  final rowH = innerW * 9 / 16 + 80;
                                  return SizedBox(
                                    height: rowH,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Expanded(
                                            flex: 1, child: _videoCard()),
                                        SizedBox(width: g),
                                        Expanded(
                                            flex: 1, child: _heatmapCard()),
                                      ],
                                    ),
                                  );
                                })
                              : Column(
                                  children: [
                                    _videoCard(),
                                    SizedBox(height: g),
                                    _heatmapCard(),
                                  ],
                                ),
                          SizedBox(height: g),
                          isWide
                              ? IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(flex: 1, child: _chartCard()),
                                      SizedBox(width: g),
                                      Expanded(flex: 1, child: _alertsCard()),
                                    ],
                                  ),
                                )
                              : Column(
                                  children: [
                                    _chartCard(),
                                    SizedBox(height: g),
                                    _alertsCard(),
                                  ],
                                ),
                          SizedBox(height: g),
                          const _GuidanceCarousel(),
                          const SizedBox(height: 24),
                          if (_statusMsg != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: AppColors.surface.withOpacity(0.6),
                                borderRadius: BorderRadius.circular(10),
                                border:
                                    Border.all(color: AppColors.border),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.info_outline_rounded,
                                      size: 14,
                                      color: AppColors.textMuted),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      _statusMsg!,
                                      style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ambientGlow(Color color, double size) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withOpacity(0)],
          ),
        ),
      ),
    );
  }

  Widget _videoCard() {
    return _GlassCard(
      title: 'Video Playback',
      icon: Icons.videocam_rounded,
      accent: AppColors.accent,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF000000), Color(0xFF0A0E1A)],
              ),
            ),
            child: Builder(
              builder: (context) {
                final controller = _videoController;

                if (controller == null || !controller.value.isInitialized) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                AppColors.accent.withOpacity(0.2),
                                AppColors.accent2.withOpacity(0.1),
                              ],
                            ),
                            border: Border.all(
                                color: AppColors.accent.withOpacity(0.3)),
                          ),
                          child: const Icon(Icons.movie_outlined,
                              color: AppColors.accent2, size: 30),
                        ),
                        const SizedBox(height: 14),
                        const Text('Upload a video to begin',
                            style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 14,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(height: 4),
                        const Text('Supports MP4, MOV, AVI',
                            style: TextStyle(
                                color: AppColors.textMuted, fontSize: 11)),
                      ],
                    ),
                  );
                }

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: controller.value.size.width,
                        height: controller.value.size.height,
                        child: VideoPlayer(
                          controller,
                          key: ValueKey(controller),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      top: 12,
                      child: _LiveBadge(active: _analyzing && !_paused),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _heatmapCard() {
    return _GlassCard(
      title: 'Real-time Heatmap',
      icon: Icons.blur_on_rounded,
      accent: AppColors.danger,
      trailing: _LegendChips(),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: HeatmapView(points: _heatmap),
        ),
      ),
    );
  }

  Widget _chartCard() {
    return _GlassCard(
      title: 'People Detected per Frame',
      icon: Icons.show_chart_rounded,
      accent: AppColors.accent2,
      trailing:
          _GaugeMini(value: _currentCount, max: math.max(_peakCount, kDenseMax)),
      child: SizedBox(
        height: 240,
        child: _series.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.timeline_rounded,
                        color: AppColors.textMuted.withOpacity(0.5), size: 32),
                    const SizedBox(height: 10),
                    const Text('Waiting for stream…',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 13)),
                  ],
                ),
              )
            : LineChart(
                LineChartData(
                  minY: 0,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: AppColors.border.withOpacity(0.6),
                      strokeWidth: 1,
                      dashArray: [4, 6],
                    ),
                  ),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 32,
                        getTitlesWidget: (v, m) => Text(
                          v.toInt().toString(),
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 11),
                        ),
                      ),
                    ),
                    bottomTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => AppColors.surfaceHi,
                      tooltipRoundedRadius: 8,
                      getTooltipItems: (spots) => spots
                          .map((s) => LineTooltipItem(
                                '${s.y.toInt()} people',
                                const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600),
                              ))
                          .toList(),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _series,
                      isCurved: true,
                      curveSmoothness: 0.35,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      gradient: const LinearGradient(
                        colors: [AppColors.accent2, AppColors.accent],
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            AppColors.accent.withOpacity(0.35),
                            AppColors.accent.withOpacity(0.0),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
              ),
      ),
    );
  }

  Widget _alertsCard() {
    return _GlassCard(
      title: 'Alerts & Summary',
      icon: Icons.insights_rounded,
      accent: AppColors.warn,
      trailing: _alerts.isEmpty
          ? null
          : Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.warn.withOpacity(0.15),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.warn.withOpacity(0.4)),
              ),
              child: Text('${_alerts.length}',
                  style: const TextStyle(
                      color: AppColors.warn,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ----- Real-time AI summary panel -----
          _SummaryPanel(
            headline: _summaryHeadline,
            body: _summaryText,
            accent: _summaryAccent,
            icon: _summaryIcon,
            live: _analyzing && _connected && !_paused,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                width: 4,
                height: 14,
                decoration: BoxDecoration(
                  color: AppColors.warn,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Recent Alerts',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 220,
            child: _alerts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.notifications_off_outlined,
                            color: AppColors.textMuted.withOpacity(0.5),
                            size: 30),
                        const SizedBox(height: 8),
                        const Text('No alerts yet',
                            style: TextStyle(
                                color: AppColors.textMuted, fontSize: 12)),
                      ],
                    ),
                  )
                : ListView.separated(
                    reverse: false,
                    itemCount: _alerts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) =>
                        _AlertTile(item: _alerts[_alerts.length - 1 - i]),
                  ),
          ),
        ],
      ),
    );
  }

  // Crowd Insights moved to top header. Bottom section is now the auto-scrolling
  // safety guidance carousel (see _GuidanceCarousel below).
}

// =============================================================================
// REAL-TIME SUMMARY PANEL
// AI-style operational insight derived from live state.
// =============================================================================
class _SummaryPanel extends StatelessWidget {
  final String headline;
  final String body;
  final Color accent;
  final IconData icon;
  final bool live;

  const _SummaryPanel({
    required this.headline,
    required this.body,
    required this.accent,
    required this.icon,
    required this.live,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withOpacity(0.16),
            accent.withOpacity(0.04),
            AppColors.surfaceAlt.withOpacity(0.6),
          ],
        ),
        border: Border.all(color: accent.withOpacity(0.35), width: 1),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.18),
            blurRadius: 24,
            spreadRadius: -6,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: LinearGradient(
                    colors: [accent, accent.withOpacity(0.6)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withOpacity(0.45),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'AI Summary',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _LivePulse(active: live, color: accent),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: Text(
              body,
              key: ValueKey(body),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textSecondary.withOpacity(0.95),
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LivePulse extends StatefulWidget {
  final bool active;
  final Color color;
  const _LivePulse({required this.active, required this.color});

  @override
  State<_LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<_LivePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.active ? widget.color : AppColors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final t = widget.active ? _c.value : 0.4;
            return Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c,
                boxShadow: [
                  BoxShadow(
                    color: c.withOpacity(0.5 * t + 0.2),
                    blurRadius: 8 * t + 2,
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(width: 5),
        Text(
          widget.active ? 'LIVE' : 'IDLE',
          style: TextStyle(
            color: c,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.0,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// LEGEND
// =============================================================================
class _LegendChips extends StatelessWidget {
  Widget _chip(Color c, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.withOpacity(0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.withOpacity(0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 6,
              height: 6,
              decoration:
                  BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: c, fontSize: 10, fontWeight: FontWeight.w600)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _chip(AppColors.success, 'Low'),
        _chip(AppColors.warn, 'Med'),
        _chip(AppColors.danger, 'High'),
      ],
    );
  }
}

// (InsightTile removed — Crowd Insights moved to top header.)

// =============================================================================
// HEADER + CONTROLS
// =============================================================================
class _Header extends StatelessWidget {
  final ScreenSize size;
  final bool connected, paused, analyzing, uploading;
  final String? videoName;
  final VoidCallback onUpload, onStart, onTogglePause;
  const _Header({
    required this.size,
    required this.connected,
    required this.paused,
    required this.analyzing,
    required this.uploading,
    required this.videoName,
    required this.onUpload,
    required this.onStart,
    required this.onTogglePause,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = size == ScreenSize.mobile;
    final isTablet = size == ScreenSize.tablet;

    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: isMobile ? 38 : 44,
          height: isMobile ? 38 : 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.accent, AppColors.accent2],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withOpacity(0.45),
                blurRadius: 22,
                spreadRadius: 1,
              )
            ],
          ),
          child: const Icon(Icons.radar_rounded, color: Colors.white),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Crowd Monitor',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: isMobile ? 19 : 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: AppColors.textPrimary,
                  )),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    videoName == null
                        ? Icons.fiber_manual_record_rounded
                        : Icons.movie_filter_rounded,
                    size: 11,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      videoName ?? 'Real-time analytics dashboard',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    final controls = Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _StatusPill(connected: connected, paused: paused),
        _GhostButton(
          icon: Icons.upload_rounded,
          label: uploading ? 'Uploading…' : 'Upload Video',
          onTap: uploading ? null : onUpload,
          loading: uploading,
          compact: isMobile,
        ),
        _PrimaryButton(
          icon: Icons.play_arrow_rounded,
          label: analyzing ? 'Analyzing' : 'Start Analysis',
          onTap: analyzing ? null : onStart,
          compact: isMobile,
        ),
        _GhostButton(
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          label: paused ? 'Resume' : 'Pause',
          onTap: connected ? onTogglePause : null,
          compact: isMobile,
        ),
      ],
    );

    final container = Container(
      padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 14 : 18, vertical: isMobile ? 14 : 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101627), Color(0xFF0B111E)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: (isMobile || isTablet)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                brand,
                const SizedBox(height: 14),
                controls,
              ],
            )
          : Row(
              children: [
                Expanded(child: brand),
                const SizedBox(width: 14),
                Flexible(child: controls),
              ],
            ),
    );

    return container;
  }
}

class _StatusPill extends StatelessWidget {
  final bool connected, paused;
  const _StatusPill({required this.connected, required this.paused});

  @override
  Widget build(BuildContext context) {
    final color = !connected
        ? AppColors.textMuted
        : (paused ? AppColors.warn : AppColors.success);
    final label = !connected ? 'Offline' : (paused ? 'Paused' : 'Live');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(color: color, pulsing: connected && !paused),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3)),
        ],
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final Color color;
  final bool pulsing;
  const _Dot({required this.color, required this.pulsing});
  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final s = widget.pulsing
            ? (0.6 + 0.4 * math.sin(_c.value * math.pi * 2))
            : 1.0;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: widget.pulsing
                ? [
                    BoxShadow(
                        color: widget.color.withOpacity(0.6 * s),
                        blurRadius: 10,
                        spreadRadius: 2)
                  ]
                : null,
          ),
        );
      },
    );
  }
}

// =============================================================================
// CROWD INSIGHTS HEADER (premium metrics row)
// =============================================================================
class _CrowdInsightsHeader extends StatelessWidget {
  final int count, peak;
  final String status, trend;
  final Color statusColor;
  final IconData trendIcon;
  final bool connected;
  final bool analyzing;
  const _CrowdInsightsHeader({
    required this.count,
    required this.peak,
    required this.status,
    required this.statusColor,
    required this.trend,
    required this.trendIcon,
    required this.connected,
    required this.analyzing,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final isMobile = c.maxWidth < 640;
      return Container(
        padding: EdgeInsets.all(isMobile ? 16 : 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfaceHi.withOpacity(0.85),
              AppColors.surface.withOpacity(0.55),
            ],
          ),
          border: Border.all(color: AppColors.borderHi.withOpacity(0.7)),
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withOpacity(0.10),
              blurRadius: 32,
              spreadRadius: -6,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: AppColors.accent3.withOpacity(0.06),
              blurRadius: 40,
              spreadRadius: -10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title bar
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.accent3, AppColors.accent],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent3.withOpacity(0.45),
                        blurRadius: 18,
                        spreadRadius: 0,
                      )
                    ],
                  ),
                  child: const Icon(Icons.insights_rounded,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Crowd Insights',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: isMobile ? 16 : 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Live overview of crowd density, trend & safety status',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isMobile)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: (analyzing
                              ? AppColors.success
                              : AppColors.textMuted)
                          .withOpacity(0.12),
                      border: Border.all(
                        color: (analyzing
                                ? AppColors.success
                                : AppColors.textMuted)
                            .withOpacity(0.35),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: analyzing
                                ? AppColors.success
                                : AppColors.textMuted,
                            boxShadow: analyzing
                                ? [
                                    BoxShadow(
                                      color: AppColors.success
                                          .withOpacity(0.7),
                                      blurRadius: 8,
                                    )
                                  ]
                                : null,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          analyzing ? 'LIVE' : 'IDLE',
                          style: TextStyle(
                            color: analyzing
                                ? AppColors.success
                                : AppColors.textMuted,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            // Cards
            LayoutBuilder(builder: (_, cc) {
              final cols = cc.maxWidth >= 1000
                  ? 4
                  : (cc.maxWidth >= 700 ? 4 : (cc.maxWidth >= 460 ? 2 : 1));
              const g = 14.0;
              final w = (cc.maxWidth - g * (cols - 1)) / cols;
              Widget cell(Widget child) => SizedBox(width: w, child: child);
              return Wrap(
                spacing: g,
                runSpacing: g,
                children: [
                  cell(_StatCard(
                    icon: Icons.groups_2_rounded,
                    label: 'Current Crowd',
                    value: count.toString(),
                    accent: AppColors.accent,
                  )),
                  cell(_StatCard(
                    icon: Icons.shield_rounded,
                    label: 'Status',
                    value: status,
                    accent: statusColor,
                  )),
                  cell(_StatCard(
                    icon: trendIcon,
                    label: 'Trend',
                    value: trend,
                    accent: AppColors.accent2,
                  )),
                  cell(_StatCard(
                    icon: Icons.bolt_rounded,
                    label: 'Peak Count',
                    value: peak.toString(),
                    accent: AppColors.warn,
                  )),
                ],
              );
            }),
          ],
        ),
      );
    });
  }
}

class _StatCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  State<_StatCard> createState() => _StatCardState();
}

class _StatCardState extends State<_StatCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(18),
        transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
              color: _hover
                  ? widget.accent.withOpacity(0.5)
                  : AppColors.border),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surface,
              AppColors.surfaceAlt,
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: widget.accent.withOpacity(_hover ? 0.22 : 0.10),
              blurRadius: _hover ? 36 : 28,
              spreadRadius: -8,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    widget.accent.withOpacity(0.28),
                    widget.accent.withOpacity(0.06)
                  ],
                ),
                border: Border.all(color: widget.accent.withOpacity(0.4)),
              ),
              child: Icon(widget.icon, color: widget.accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.label,
                      style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.4)),
                  const SizedBox(height: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      widget.value,
                      key: ValueKey(widget.value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// GLASS CARD
// =============================================================================
class _GlassCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  final Color accent;
  const _GlassCard({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.accent = AppColors.accent2,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101627), Color(0xFF0B111E)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: accent.withOpacity(0.15),
                  border: Border.all(color: accent.withOpacity(0.3)),
                ),
                child: Icon(icon, size: 16, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: 0.2,
                    )),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

// =============================================================================
// HEATMAP
// =============================================================================
class HeatmapView extends StatelessWidget {
  final List<Offset> points;
  const HeatmapView({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          radius: 1.2,
          colors: [Color(0xFF0B1220), Color(0xFF05080F)],
        ),
      ),
      child: CustomPaint(
        painter: _HeatmapPainter(points: points),
        size: Size.infinite,
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  final List<Offset> points;
  _HeatmapPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = AppColors.border.withOpacity(0.4)
      ..strokeWidth = 1;
    const step = 32.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (points.isEmpty) return;

    final sx = size.width / kFrameW;
    final sy = size.height / kFrameH;

    final radius = math.min(size.width, size.height) * 0.09;

    for (final p in points) {
      final pos = Offset(p.dx * sx, p.dy * sy);
      final shader = ui.Gradient.radial(
        pos,
        radius,
        [
          AppColors.danger.withOpacity(0.85),
          AppColors.warn.withOpacity(0.55),
          AppColors.accent.withOpacity(0.0),
        ],
        [0.0, 0.5, 1.0],
      );
      final paint = Paint()
        ..shader = shader
        ..blendMode = BlendMode.plus;
      canvas.drawCircle(pos, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter old) => old.points != points;
}

// =============================================================================
// MINI GAUGE
// =============================================================================
class _GaugeMini extends StatelessWidget {
  final int value;
  final int max;
  const _GaugeMini({required this.value, required this.max});

  @override
  Widget build(BuildContext context) {
    final pct = max == 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    return SizedBox(
      width: 60,
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: pct),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              builder: (_, v, __) => CustomPaint(
                painter: _GaugePainter(progress: v),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$value',
                  style: GoogleFonts.spaceGrotesk(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const Text('live',
                  style:
                      TextStyle(color: AppColors.textMuted, fontSize: 9)),
            ],
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double progress;
  _GaugePainter({required this.progress});
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = 6.0;
    final r = math.min(size.width, size.height) / 2 - stroke;
    final c = rect.center;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = AppColors.border;
    canvas.drawCircle(c, r, track);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [AppColors.accent2, AppColors.accent, AppColors.danger],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2,
        2 * math.pi * progress, false, p);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) => old.progress != progress;
}

// =============================================================================
// LIVE BADGE
// =============================================================================
class _LiveBadge extends StatelessWidget {
  final bool active;
  const _LiveBadge({required this.active});
  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.danger : AppColors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _Dot(color: color, pulsing: active),
        const SizedBox(width: 6),
        Text(active ? 'LIVE' : 'IDLE',
            style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6)),
      ]),
    );
  }
}

// =============================================================================
// ALERTS
// =============================================================================
enum AlertLevel { info, warn, danger }

class _AlertItem {
  final String message;
  final AlertLevel level;
  final DateTime time;
  _AlertItem(this.message, this.level, this.time);
}

class _AlertTile extends StatelessWidget {
  final _AlertItem item;
  const _AlertTile({required this.item});

  Color get _color {
    switch (item.level) {
      case AlertLevel.danger:
        return AppColors.danger;
      case AlertLevel.warn:
        return AppColors.warn;
      case AlertLevel.info:
        return AppColors.accent2;
    }
  }

  IconData get _icon {
    switch (item.level) {
      case AlertLevel.danger:
        return Icons.error_rounded;
      case AlertLevel.warn:
        return Icons.warning_amber_rounded;
      case AlertLevel.info:
        return Icons.info_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            _color.withOpacity(0.14),
            _color.withOpacity(0.04),
          ],
        ),
        border: Border.all(color: _color.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: _color.withOpacity(0.18),
            ),
            child: Icon(_icon, color: _color, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(item.message,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ),
          const SizedBox(width: 8),
          Text(_fmt(item.time),
              style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

// =============================================================================
// BUTTONS
// =============================================================================
class _PrimaryButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool compact;
  const _PrimaryButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.compact = false,
  });

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 14 : 18,
              vertical: widget.compact ? 11 : 12),
          transform:
              Matrix4.translationValues(0, _hover && !disabled ? -1 : 0, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: disabled
                  ? const [AppColors.surfaceAlt, AppColors.surfaceAlt]
                  : (_hover
                      ? const [AppColors.accentHi, AppColors.accent2]
                      : const [AppColors.accent, AppColors.accent2]),
            ),
            boxShadow: disabled
                ? null
                : [
                    BoxShadow(
                      color:
                          AppColors.accent.withOpacity(_hover ? 0.55 : 0.4),
                      blurRadius: _hover ? 24 : 18,
                      offset: const Offset(0, 6),
                    )
                  ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Text(widget.label,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

class _GhostButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  final bool compact;
  const _GhostButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.loading = false,
    this.compact = false,
  });

  @override
  State<_GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<_GhostButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 12 : 14,
              vertical: widget.compact ? 11 : 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: _hover && !disabled
                ? AppColors.surfaceHi
                : AppColors.surface,
            border: Border.all(
                color: disabled
                    ? AppColors.border
                    : (_hover
                        ? AppColors.accent.withOpacity(0.7)
                        : AppColors.accent.withOpacity(0.4))),
            boxShadow: _hover && !disabled
                ? [
                    BoxShadow(
                      color: AppColors.accent.withOpacity(0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    )
                  ]
                : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accent2),
              )
            else
              Icon(widget.icon,
                  size: 18,
                  color: disabled
                      ? AppColors.textMuted
                      : AppColors.textPrimary),
            const SizedBox(width: 8),
            Text(widget.label,
                style: TextStyle(
                    color: disabled
                        ? AppColors.textMuted
                        : AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

// =============================================================================
// SAFETY GUIDANCE CAROUSEL (auto-sliding, infinite)
// =============================================================================
class _GuidanceItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Color colorAlt;
  final List<String> tips;
  const _GuidanceItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.colorAlt,
    required this.tips,
  });
}

const List<_GuidanceItem> _kGuidanceItems = [
  _GuidanceItem(
    title: 'Safe Crowd',
    subtitle: 'Low density · Free movement',
    icon: Icons.verified_user_rounded,
    color: AppColors.success,
    colorAlt: Color(0xFF10B981),
    tips: [
      'Maintain normal monitoring cadence',
      'Keep emergency exits visibly clear',
      'Log baseline metrics for the venue',
    ],
  ),
  _GuidanceItem(
    title: 'Normal Crowd',
    subtitle: 'Healthy flow · Stable movement',
    icon: Icons.groups_rounded,
    color: AppColors.accent,
    colorAlt: AppColors.accent2,
    tips: [
      'Continue periodic density sampling',
      'Verify staff presence at chokepoints',
      'Pre-stage signage for guided flow',
    ],
  ),
  _GuidanceItem(
    title: 'Dense Crowd',
    subtitle: 'Elevated density · Watch closely',
    icon: Icons.warning_amber_rounded,
    color: AppColors.warn,
    colorAlt: Color(0xFFFB923C),
    tips: [
      'Throttle inflow at entry gates',
      'Deploy ushers to redirect movement',
      'Open secondary corridors and exits',
    ],
  ),
  _GuidanceItem(
    title: 'Overcrowded',
    subtitle: 'Critical risk · Act immediately',
    icon: Icons.crisis_alert_rounded,
    color: AppColors.danger,
    colorAlt: Color(0xFFF43F5E),
    tips: [
      'Trigger emergency evacuation protocol',
      'Halt all new entries to the zone',
      'Alert on-ground responders & medics',
    ],
  ),
];

class _GuidanceCarousel extends StatefulWidget {
  const _GuidanceCarousel();

  @override
  State<_GuidanceCarousel> createState() => _GuidanceCarouselState();
}

class _GuidanceCarouselState extends State<_GuidanceCarousel> {
  late PageController _controller;
  Timer? _timer;
  int _page = 0;
  bool _hovered = false;

  static const int _virtualCount = 10000; // simulate infinite loop

  @override
  void initState() {
    super.initState();
    final start = (_virtualCount ~/ 2);
    _page = start;
    _controller = PageController(
      initialPage: start,
      viewportFraction: 0.9,
    );
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _hovered) return;
      if (!_controller.hasClients) return;
      _page = (_controller.page?.round() ?? _page) + 1;
      _controller.animateToPage(
        _page,
        duration: const Duration(milliseconds: 850),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final isMobile = c.maxWidth < 640;
      final isTablet = c.maxWidth >= 640 && c.maxWidth < 1024;
      final cardHeight = isMobile ? 230.0 : (isTablet ? 220.0 : 210.0);

      // Show 1 card on mobile, ~2 on tablet, ~3 on desktop
      final viewportFraction = isMobile
          ? 0.9
          : (isTablet ? 0.55 : 0.36);

      // Re-create controller if viewport changed materially.
      if ((_controller.viewportFraction - viewportFraction).abs() > 0.01) {
        final currentPage = _controller.hasClients
            ? (_controller.page?.round() ?? _page)
            : _page;
        _controller.dispose();
        _controller = PageController(
          initialPage: currentPage,
          viewportFraction: viewportFraction,
        );
      }

      return Container(
        padding: EdgeInsets.all(isMobile ? 14 : 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfaceHi.withOpacity(0.75),
              AppColors.surface.withOpacity(0.5),
            ],
          ),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: const LinearGradient(
                      colors: [AppColors.accent2, AppColors.accent],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent2.withOpacity(0.4),
                        blurRadius: 16,
                      )
                    ],
                  ),
                  child: const Icon(Icons.tips_and_updates_rounded,
                      color: Colors.white, size: 16),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Smart Safety Guidance',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const Text(
                        'Recommended actions by crowd density level',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.success.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: AppColors.success.withOpacity(0.3)),
                  ),
                  child: const Text(
                    'Be Safe',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: AppColors.success,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: SizedBox(
                height: cardHeight,
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _virtualCount,
                  padEnds: false,
                  onPageChanged: (i) =>
                      setState(() => _page = i),
                  itemBuilder: (_, i) {
                    final item =
                        _kGuidanceItems[i % _kGuidanceItems.length];
                    return AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        double t = 0;
                        if (_controller.position.haveDimensions) {
                          t = (_controller.page ?? _page.toDouble()) - i;
                        }
                        final scale =
                            (1 - (t.abs() * 0.06)).clamp(0.92, 1.0);
                        final opacity =
                            (1 - (t.abs() * 0.35)).clamp(0.45, 1.0);
                        return Center(
                          child: Opacity(
                            opacity: opacity,
                            child: Transform.scale(
                              scale: scale,
                              child: child,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: _GuidanceCard(item: item),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Indicators
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_kGuidanceItems.length, (i) {
                final active = (_page % _kGuidanceItems.length) == i;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOut,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 22 : 8,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    gradient: active
                        ? LinearGradient(colors: [
                            _kGuidanceItems[i].color,
                            _kGuidanceItems[i].colorAlt,
                          ])
                        : null,
                    color: active
                        ? null
                        : AppColors.border.withOpacity(0.7),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: _kGuidanceItems[i]
                                  .color
                                  .withOpacity(0.55),
                              blurRadius: 10,
                            )
                          ]
                        : null,
                  ),
                );
              }),
            ),
          ],
        ),
      );
    });
  }
}

class _GuidanceCard extends StatefulWidget {
  final _GuidanceItem item;
  const _GuidanceCard({required this.item});

  @override
  State<_GuidanceCard> createState() => _GuidanceCardState();
}

class _GuidanceCardState extends State<_GuidanceCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        transform: Matrix4.identity()..translate(0.0, _hover ? -3.0 : 0.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              item.color.withOpacity(_hover ? 0.22 : 0.16),
              item.colorAlt.withOpacity(0.05),
              AppColors.surface.withOpacity(0.6),
            ],
          ),
          border: Border.all(
            color: item.color.withOpacity(_hover ? 0.55 : 0.32),
          ),
          boxShadow: [
            BoxShadow(
              color: item.color.withOpacity(_hover ? 0.30 : 0.15),
              blurRadius: _hover ? 30 : 18,
              spreadRadius: -4,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Stack(
            children: [
              // Glow blob
              Positioned(
                right: -28,
                top: -28,
                child: Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        item.color.withOpacity(0.55),
                        item.color.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [item.color, item.colorAlt],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: item.color.withOpacity(0.55),
                                blurRadius: 16,
                              )
                            ],
                          ),
                          child:
                              Icon(item.icon, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              Text(
                                item.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: item.color,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      height: 1,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            item.color.withOpacity(0.0),
                            item.color.withOpacity(0.45),
                            item.color.withOpacity(0.0),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: item.tips
                            .map((tip) => Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      margin:
                                          const EdgeInsets.only(top: 5),
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: item.color,
                                        boxShadow: [
                                          BoxShadow(
                                            color: item.color
                                                .withOpacity(0.7),
                                            blurRadius: 6,
                                          )
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        tip,
                                        style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 12.5,
                                          height: 1.35,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ))
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
