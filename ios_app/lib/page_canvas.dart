import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'ink.dart';
import 'models.dart';

enum DrawTool { pen, highlighter, eraser, lasso }

const double highlighterOpacity = 0.35;

class ToolSettings {
  const ToolSettings({
    this.tool = DrawTool.pen,
    this.penColor = 0xFF1A1A1A,
    this.highlighterColor = 0xFFFFD600,
    this.penWidth = 3,
    this.highlighterWidth = 18,
    this.fingerDraws = false,
    this.smoothing = Smoothing.medium,
  });

  final DrawTool tool;

  /// Pen and highlighter keep their own color and width, so switching tools
  /// doesn't lose either choice.
  final int penColor;
  final int highlighterColor;

  /// Widths in units of a [pageWidth]-wide page; scaled up on pages that
  /// were extended so ink looks the same size on screen.
  final double penWidth;
  final double highlighterWidth;

  /// When false, only the Apple Pencil draws and fingers scroll.
  final bool fingerDraws;

  final Smoothing smoothing;

  bool get isHighlighter => tool == DrawTool.highlighter;
  int get color => isHighlighter ? highlighterColor : penColor;
  double get strokeWidth => isHighlighter ? highlighterWidth : penWidth;

  /// Eraser reach around the Pencil tip, in page units (a stroke is hit
  /// when it passes within this distance plus half its own width).
  double get eraserRadius => 4;

  bool canDraw(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus ||
      (fingerDraws && kind == PointerDeviceKind.touch) ||
      kind == PointerDeviceKind.mouse; // Simulator / Mac debugging.

  ToolSettings copyWith({
    DrawTool? tool,
    int? penColor,
    int? highlighterColor,
    double? penWidth,
    double? highlighterWidth,
    bool? fingerDraws,
    Smoothing? smoothing,
  }) => ToolSettings(
    tool: tool ?? this.tool,
    penColor: penColor ?? this.penColor,
    highlighterColor: highlighterColor ?? this.highlighterColor,
    penWidth: penWidth ?? this.penWidth,
    highlighterWidth: highlighterWidth ?? this.highlighterWidth,
    fingerDraws: fingerDraws ?? this.fingerDraws,
    smoothing: smoothing ?? this.smoothing,
  );
}

/// Renders one page (background image + ink) and turns stylus input into
/// strokes. Fingers are left to the enclosing scroll view.
class PageCanvas extends StatefulWidget {
  const PageCanvas({
    super.key,
    required this.page,
    required this.imageFile,
    required this.settings,
    required this.onStrokeAdded,
    required this.onStrokesErased,
    this.onStrokesMoved,
  });

  final NotePage page;
  final File? imageFile;
  final ToolSettings settings;
  final void Function(NotePage page, Stroke stroke) onStrokeAdded;
  final void Function(NotePage page, List<Stroke> strokes) onStrokesErased;
  final void Function(NotePage page, List<Stroke> strokes, Offset delta)? onStrokesMoved;

  @override
  State<PageCanvas> createState() => _PageCanvasState();
}

enum _LassoMode { none, drawing, dragging }

class _PageCanvasState extends State<PageCanvas> {
  final _active = _ActiveStroke();
  final _lasso = _LassoState();
  int? _pointer;
  PointerDeviceKind? _pointerKind;
  bool _erasing = false;
  final List<Stroke> _erased = [];
  double _scale = 1;

  _LassoMode _lassoMode = _LassoMode.none;
  Offset _lastDragPage = Offset.zero;

  @override
  void initState() {
    super.initState();
    widget.page.addListener(_onPageChanged);
  }

  @override
  void dispose() {
    widget.page.removeListener(_onPageChanged);
    _active.dispose();
    _lasso.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PageCanvas old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page) {
      old.page.removeListener(_onPageChanged);
      widget.page.addListener(_onPageChanged);
      _lasso.clear();
    } else if (old.settings.tool == DrawTool.lasso &&
        widget.settings.tool != DrawTool.lasso) {
      _lasso.clear();
    }
  }

  void _onPageChanged() {
    if (_lasso.hasSelection && _lassoMode != _LassoMode.dragging) {
      final still =
          _lasso.selected.where(widget.page.strokes.contains).toList();
      if (still.isEmpty) {
        _lasso.clear();
      } else {
        _lasso.updateSelection(still);
      }
    }
  }

  Offset _toPage(Offset local) => local / _scale;

  static int _bucket(double px) => ((px / 512).ceil() * 512).clamp(512, 8192);

  /// How much larger this page is than a fresh one (1 unless extended).
  double get _unitScale => widget.page.width / pageWidth;

  // ---------------------------------------------------------------- pointer

  void _onDown(PointerDownEvent e) {
    if (_pointer != null &&
        _pointerKind == PointerDeviceKind.touch &&
        e.kind == PointerDeviceKind.touch) {
      _finish(commit: false);
      return;
    }
    if (_pointer != null || !widget.settings.canDraw(e.kind)) return;
    _pointer = e.pointer;
    _pointerKind = e.kind;
    final p = _toPage(e.localPosition);
    final invertedStylus = e.kind == PointerDeviceKind.invertedStylus;
    if (!invertedStylus && widget.settings.tool == DrawTool.lasso) {
      _handleLassoDown(p);
      return;
    }
    _erasing = widget.settings.tool == DrawTool.eraser || invertedStylus;
    if (_erasing) {
      _eraseAt(p);
    } else {
      final s = widget.settings;
      _active.start(
        Stroke(
          tool: s.tool == DrawTool.highlighter
              ? StrokeTool.highlighter
              : StrokeTool.pen,
          color: s.color,
          width: s.strokeWidth * _unitScale,
          points: [p],
        ),
        s.smoothing,
      );
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final p = _toPage(e.localPosition);
    if (_lassoMode != _LassoMode.none) {
      _handleLassoMove(p);
    } else if (_erasing) {
      _eraseAt(p);
    } else {
      _active.add(p);
    }
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    if (_lassoMode != _LassoMode.none) {
      _handleLassoUp(_toPage(e.localPosition));
      _pointer = null;
      return;
    }
    if (!_erasing) _active.end(_toPage(e.localPosition));
    _finish(commit: true);
  }

  void _onCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    if (_lassoMode != _LassoMode.none) {
      if (_lassoMode == _LassoMode.drawing) {
        _lasso.clear();
      } else {
        _lasso.updateDrag(Offset.zero);
      }
      _lassoMode = _LassoMode.none;
      _pointer = null;
      return;
    }
    _finish(commit: false);
  }

  void _finish({required bool commit}) {
    _pointer = null;
    if (_erasing) {
      if (_erased.isNotEmpty) {
        widget.onStrokesErased(widget.page, List.of(_erased));
        _erased.clear();
      }
      _erasing = false;
      return;
    }
    final stroke = _active.take();
    if (commit && stroke != null) {
      widget.page.addStroke(stroke);
      widget.onStrokeAdded(widget.page, stroke);
    }
  }

  // ---------------------------------------------------------------- eraser

  void _eraseAt(Offset p) {
    final r = widget.settings.eraserRadius * _unitScale;
    final hits = [
      for (final s in widget.page.strokes)
        if (_hits(s, p, r)) s,
    ];
    if (hits.isEmpty) return;
    widget.page.removeStrokes(hits);
    _erased.addAll(hits);
  }

  static bool _hits(Stroke s, Offset p, double r) {
    if (!s.bounds.inflate(r).contains(p)) return false;
    final tol = r + s.width / 2;
    final pts = s.points;
    if (pts.length == 1) return (pts.first - p).distance <= tol;
    for (var i = 1; i < pts.length; i++) {
      if (_segmentDistance(p, pts[i - 1], pts[i]) <= tol) return true;
    }
    return false;
  }

  static double _segmentDistance(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  // ---------------------------------------------------------------- lasso

  void _handleLassoDown(Offset p) {
    if (_lasso.hasSelection) {
      final bounds = _lasso.selectionBounds;
      if (bounds.inflate(10).contains(p)) {
        _lassoMode = _LassoMode.dragging;
        _lastDragPage = p;
        return;
      }
    }
    _lasso.clear();
    _lassoMode = _LassoMode.drawing;
    _lasso.startPath(p);
  }

  void _handleLassoMove(Offset p) {
    if (_lassoMode == _LassoMode.drawing) {
      _lasso.addPoint(p);
    } else if (_lassoMode == _LassoMode.dragging) {
      final delta = p - _lastDragPage;
      _lasso.updateDrag(_lasso.dragOffset + delta);
      _lastDragPage = p;
    }
  }

  void _handleLassoUp(Offset p) {
    if (_lassoMode == _LassoMode.drawing) {
      final polygon = List<Offset>.of(_lasso.path);
      if (polygon.length >= 3) {
        final selected = <Stroke>[];
        for (final s in widget.page.strokes) {
          if (_strokeIntersectsPolygon(s, polygon)) selected.add(s);
        }
        if (selected.isNotEmpty) {
          _lasso.finishSelection(selected);
        } else {
          _lasso.clear();
        }
      } else {
        _lasso.clear();
      }
    } else if (_lassoMode == _LassoMode.dragging) {
      final offset = _lasso.dragOffset;
      if (offset.distance > 0.5) {
        widget.page.translateStrokes(_lasso.selected, offset);
        _lasso.commitDrag();
        widget.onStrokesMoved
            ?.call(widget.page, List.of(_lasso.selected), offset);
      } else {
        _lasso.updateDrag(Offset.zero);
      }
    }
    _lassoMode = _LassoMode.none;
  }

  static bool _strokeIntersectsPolygon(Stroke stroke, List<Offset> polygon) {
    for (final p in stroke.points) {
      if (_pointInPolygon(p, polygon)) return true;
    }
    return false;
  }

  static bool _pointInPolygon(Offset point, List<Offset> polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      if ((polygon[i].dy > point.dy) != (polygon[j].dy > point.dy) &&
          point.dx <
              (polygon[j].dx - polygon[i].dx) *
                      (point.dy - polygon[i].dy) /
                      (polygon[j].dy - polygon[i].dy) +
                  polygon[i].dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final page = widget.page;
        _scale = width / page.width;
        final imageRect = page.imageRect;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onCancel,
          child: ClipRect(
            child: SizedBox(
              width: width,
              height: width * page.aspect,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.white),
                  if (widget.imageFile != null && imageRect != null)
                    Positioned.fromRect(
                      rect: Rect.fromLTWH(
                        imageRect.left * _scale,
                        imageRect.top * _scale,
                        imageRect.width * _scale,
                        imageRect.height * _scale,
                      ),
                      child: Image.file(
                        widget.imageFile!,
                        fit: BoxFit.fill,
                        cacheWidth: _bucket(imageRect.width * _scale * dpr),
                        gaplessPlayback: true,
                      ),
                    ),
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: _StrokesPainter(page, _scale, _lasso),
                    ),
                  ),
                  CustomPaint(painter: _ActivePainter(_active, _scale)),
                  CustomPaint(painter: _LassoPainter(_lasso, _scale)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActiveStroke extends ChangeNotifier {
  Stroke? stroke;

  final _stabilizer = InkStabilizer();

  Smoothing _level = Smoothing.medium;

  void start(Stroke s, Smoothing level) {
    stroke = s;
    _level = level;
    _stabilizer.reset(s.points.first, level);
    notifyListeners();
  }

  void add(Offset raw) {
    final s = stroke;
    if (s == null) return;
    final p = _stabilizer.add(raw);
    if (p == null) return;
    s.points.add(p);
    notifyListeners();
  }

  void end(Offset raw) {
    final s = stroke;
    if (s == null || (s.points.last - raw).distance < 0.5) return;
    s.points.add(raw);
  }

  /// Ends the stroke and returns it with the finishing smoothing applied.
  Stroke? take() {
    final s = stroke;
    if (s != null && _level.finishPasses > 0) {
      final smoothed = relax(s.points, _level.finishPasses);
      s.points
        ..clear()
        ..addAll(smoothed);
    }
    stroke = null;
    notifyListeners();
    return s;
  }
}

class _LassoState extends ChangeNotifier {
  final List<Offset> path = [];
  List<Stroke> selected = [];
  Rect selectionBounds = Rect.zero;
  bool hasSelection = false;
  Offset dragOffset = Offset.zero;

  void startPath(Offset p) {
    path.clear();
    path.add(p);
    notifyListeners();
  }

  void addPoint(Offset p) {
    path.add(p);
    notifyListeners();
  }

  void finishSelection(List<Stroke> strokes) {
    path.clear();
    selected = strokes;
    selectionBounds = _boundsOf(strokes);
    hasSelection = true;
    dragOffset = Offset.zero;
    notifyListeners();
  }

  void updateDrag(Offset offset) {
    dragOffset = offset;
    notifyListeners();
  }

  void commitDrag() {
    selectionBounds = _boundsOf(selected);
    dragOffset = Offset.zero;
    notifyListeners();
  }

  void updateSelection(List<Stroke> strokes) {
    selected = strokes;
    selectionBounds = _boundsOf(strokes);
    hasSelection = strokes.isNotEmpty;
    notifyListeners();
  }

  void clear() {
    path.clear();
    selected = [];
    selectionBounds = Rect.zero;
    hasSelection = false;
    dragOffset = Offset.zero;
    notifyListeners();
  }

  static Rect _boundsOf(List<Stroke> strokes) {
    if (strokes.isEmpty) return Rect.zero;
    var r = strokes.first.bounds;
    for (var i = 1; i < strokes.length; i++) {
      r = r.expandToInclude(strokes[i].bounds);
    }
    return r;
  }
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(this.page, this.scale, this.lasso)
    : super(repaint: Listenable.merge([page, lasso]));

  final NotePage page;
  final double scale;
  final _LassoState lasso;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    final selectedSet =
        lasso.hasSelection ? lasso.selected.toSet() : <Stroke>{};
    final offset = lasso.dragOffset;
    void paintMaybeOffset(Canvas canvas, Stroke s) {
      if (selectedSet.contains(s) && offset != Offset.zero) {
        canvas.save();
        canvas.translate(offset.dx, offset.dy);
        paintStroke(canvas, s);
        canvas.restore();
      } else {
        paintStroke(canvas, s);
      }
    }

    for (final s in page.strokes) {
      if (s.tool == StrokeTool.highlighter) paintMaybeOffset(canvas, s);
    }
    for (final s in page.strokes) {
      if (s.tool == StrokeTool.pen) paintMaybeOffset(canvas, s);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StrokesPainter old) =>
      old.page != page || old.scale != scale || old.lasso != lasso;
}

class _ActivePainter extends CustomPainter {
  _ActivePainter(this.active, this.scale) : super(repaint: active);

  final _ActiveStroke active;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = active.stroke;
    if (s == null) return;
    canvas.save();
    canvas.scale(scale);
    paintStroke(canvas, s);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ActivePainter old) =>
      old.active != active || old.scale != scale;
}

void paintStroke(Canvas canvas, Stroke s) {
  final color = Color(s.color);
  final paint = Paint()
    ..color = s.tool == StrokeTool.highlighter
        ? color.withValues(alpha: highlighterOpacity)
        : color
    ..strokeWidth = s.width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;

  final pts = s.points;
  if (pts.isEmpty) return;
  if (pts.length == 1) {
    canvas.drawCircle(
      pts.first,
      s.width / 2,
      paint..style = PaintingStyle.fill,
    );
    return;
  }
  final path = Path();
  traceSmooth(
    pts,
    moveTo: (p) => path.moveTo(p.dx, p.dy),
    cubicTo: (c1, c2, p) =>
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy),
  );
  canvas.drawPath(path, paint);
}

class _LassoPainter extends CustomPainter {
  _LassoPainter(this.lasso, this.scale) : super(repaint: lasso);

  final _LassoState lasso;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (lasso.path.length >= 2) _paintLassoPath(canvas);
    if (lasso.hasSelection) _paintSelectionBox(canvas);
  }

  void _paintLassoPath(Canvas canvas) {
    final path = Path();
    final first = lasso.path.first;
    path.moveTo(first.dx * scale, first.dy * scale);
    for (final p in lasso.path.skip(1)) {
      path.lineTo(p.dx * scale, p.dy * scale);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0x0D2196F3)
        ..style = PaintingStyle.fill,
    );
    _drawDashedPath(
      canvas,
      path,
      Paint()
        ..color = const Color(0xFF2196F3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _paintSelectionBox(Canvas canvas) {
    final bounds = lasso.selectionBounds.translate(
      lasso.dragOffset.dx,
      lasso.dragOffset.dy,
    );
    final screenBounds = Rect.fromLTRB(
      bounds.left * scale,
      bounds.top * scale,
      bounds.right * scale,
      bounds.bottom * scale,
    );
    final inflated = screenBounds.inflate(6);
    final rrect = RRect.fromRectAndRadius(inflated, const Radius.circular(4));

    canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0x0D2196F3)
        ..style = PaintingStyle.fill,
    );
    _drawDashedPath(
      canvas,
      Path()..addRRect(rrect),
      Paint()
        ..color = const Color(0xFF2196F3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  static void _drawDashedPath(Canvas canvas, Path path, Paint paint,
      {double dashLen = 6, double gapLen = 4}) {
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + dashLen, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_LassoPainter old) =>
      old.lasso != lasso || old.scale != scale;
}
