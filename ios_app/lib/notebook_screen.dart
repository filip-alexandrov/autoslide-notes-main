import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'document_store.dart';
import 'ink.dart';
import 'library_screen.dart' show showRenameDialog;
import 'models.dart';
import 'page_canvas.dart';
import 'pdf_export.dart';
import 'slide_link.dart';

const _smoothingKey = 'smoothing';

const double _maxPageWidth = 1000;
const double _sidePadding = 8;
const double _pageGap = 12;

/// Space around each page that holds its "extend" buttons.
const double _band = 34;

/// How much one press of a +/− button grows or shrinks the page on that
/// side, in page units (a fresh page is 1000 units wide).
const double _resizeStep = 100;

/// Apple Pencil double-tap events from ios/Runner/AppDelegate.swift.
const _pencilChannel = MethodChannel('ipad_notes/pencil');

/// Window width from which the drawing tools fit in the same toolbar row
/// as the title and document actions (e.g. iPad landscape).
const double _singleRowMinWidth = 1100;
const double _toolRowHeight = 52;
const double _compactMaxWidth = 600;

const double _minZoom = 0.5;
const double _maxZoom = 4;

const _penColors = <int>[
  0xFF1A1A1A, // black
  0xFF1E5EFF, // blue
  0xFFE53935, // red
  0xFF2E7D32, // green
  0xFF8E24AA, // purple
];

const _highlighterColors = <int>[
  0xFFFFD600, // yellow
  0xFF76FF03, // green
  0xFFFF4081, // pink
  0xFF40C4FF, // blue
  0xFFFF9100, // orange
];

/// Width choices (page units) and the dot size shown for each.
const _penWidths = <(double, double)>[(2, 5), (3, 8), (6, 13)];
const _highlighterWidths = <(double, double)>[(12, 6), (18, 10), (28, 15)];

/// Editor for one note of the [library].
class NotebookScreen extends StatefulWidget {
  const NotebookScreen({
    super.key,
    required this.library,
    required this.noteId,
  });

  final NoteLibrary library;
  final String noteId;

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen>
    with WidgetsBindingObserver {
  DocumentStore? _store;
  NoteDocument? _doc;
  AutoSaver? _saver;
  SlideLink? _link;
  SharedPreferences? _prefs;

  final _scroll = ScrollController();
  ToolSettings _settings = const ToolSettings();

  /// Tool to return to when a Pencil double-tap leaves the eraser.
  DrawTool _toolBeforeEraser = DrawTool.pen;
  final _undo = <_Edit>[];
  final _redo = <_Edit>[];
  bool _exporting = false;
  bool _closing = false;
  int _currentPage = 0;

  // Pinch zoom: 1.0 = pages fit the screen width.
  final _hScroll = ScrollController();
  double _zoom = 1;
  Size _viewport = Size.zero;
  final _touches = <int, Offset>{};
  _PinchAnchor? _pinch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_updateCurrentPage);
    _pencilChannel.setMethodCallHandler((call) async {
      if (call.method == 'doubleTap') _togglePenEraser();
    });
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final store = widget.library.storeFor(widget.noteId);
    final doc = await store.load();
    widget.library.lastOpenedId = widget.noteId;
    final link = SlideLink(store: store, doc: doc, onSlideAdded: _onSlideAdded)
      ..addListener(() {
        if (mounted) setState(() {});
      });
    if (!mounted) return;
    final smoothing = Smoothing.values
        .asNameMap()[prefs.getString(_smoothingKey)];
    setState(() {
      _prefs = prefs;
      if (smoothing != null) {
        _settings = _settings.copyWith(smoothing: smoothing);
      }
      _store = store;
      _doc = doc;
      _saver = AutoSaver(store, doc);
      _link = link;
    });
    link.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pencilChannel.setMethodCallHandler(null);
    _link?.dispose();
    _saver?.flush();
    _saver?.dispose();
    _scroll.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iPadOS drops peer-to-peer links in the background; reconnect on return.
    if (state == AppLifecycleState.resumed) {
      _link?.start();
    } else if (state == AppLifecycleState.paused) {
      _link?.stop();
      _saver?.flush(thumbnail: true);
    } else if (state == AppLifecycleState.inactive) {
      _saver?.flush();
    }
  }

  // ---------------------------------------------------------------- layout

  double _pageWidthFor(double viewportWidth) =>
      math.min(viewportWidth - 2 * (_sidePadding + _band), _maxPageWidth);

  /// On-screen page width at [zoom].
  double _zoomedWidth([double? zoom]) =>
      _pageWidthFor(_viewport.width) * (zoom ?? _zoom);

  /// Width of the horizontally scrollable content at page width [w].
  double _contentWidth(double w) =>
      math.max(_viewport.width, w + 2 * (_sidePadding + _band));

  /// Top of page [index]'s list item, in list content coordinates.
  double _itemTop(int index, double w) {
    var y = _pageGap; // list top padding
    for (var i = 0; i < index; i++) {
      y += _itemExtent(_doc!.pages[i], w);
    }
    return y;
  }

  // ---------------------------------------------------------------- zoom

  void _onTouchDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 2) _startPinch();
  }

  void _onTouchMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_pinch != null) _updatePinch();
  }

  void _onTouchEnd(PointerEvent e) {
    if (_touches.remove(e.pointer) == null) return;
    if (_pinch != null && _touches.length < 2) {
      setState(() => _pinch = null);
    }
  }

  (Offset, double) _focalAndSpan() {
    final pts = _touches.values.take(2).toList();
    return ((pts[0] + pts[1]) / 2, (pts[0] - pts[1]).distance);
  }

  /// Remembers which document point is under the fingers, as a fraction of
  /// the page it is on, so it can be kept there while the zoom changes.
  void _startPinch() {
    final doc = _doc;
    if (doc == null || doc.pages.isEmpty || !_scroll.hasClients) return;
    final (focal, span) = _focalAndSpan();
    if (span < 1) return;
    final w = _zoomedWidth();
    final contentY = _scroll.offset + focal.dy;
    var index = 0;
    while (index < doc.pages.length - 1 && _itemTop(index + 1, w) <= contentY) {
      index++;
    }
    final page = doc.pages[index];
    final pageTop = _itemTop(index, w) + _band;
    final hOffset = _hScroll.hasClients ? _hScroll.offset : 0.0;
    final pageLeft = (_contentWidth(w) - w) / 2;
    setState(() {
      _pinch = _PinchAnchor(
        startZoom: _zoom,
        startSpan: span,
        pageIndex: index,
        fx: (hOffset + focal.dx - pageLeft) / w,
        fy: (contentY - pageTop) / (w * page.aspect),
      );
    });
  }

  void _updatePinch() {
    final pinch = _pinch!;
    final (focal, span) = _focalAndSpan();
    final zoom = (pinch.startZoom * span / pinch.startSpan).clamp(
      _minZoom,
      _maxZoom,
    );
    setState(() => _zoom = zoom);

    // Put the anchored document point back under the (possibly moved)
    // fingers. Offsets are set before layout; the new extents are applied
    // in the same frame.
    final w = _zoomedWidth();
    final page = _doc!.pages[pinch.pageIndex];
    final y =
        _itemTop(pinch.pageIndex, w) +
        _band +
        pinch.fy * w * page.aspect -
        focal.dy;
    _scroll.jumpTo(math.max(0, y));

    if (_hScroll.hasClients) {
      final cw = _contentWidth(w);
      final x = (cw - w) / 2 + pinch.fx * w - focal.dx;
      _hScroll.jumpTo(x.clamp(0.0, math.max(0.0, cw - _viewport.width)));
    }
  }

  void _deletePage(NotePage page) {
    final doc = _doc!;
    final index = doc.pages.indexOf(page);
    if (index < 0) return;
    _recordEdit(_Edit.deletePage(doc, page)..apply());
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Page ${index + 1} moved to the recycle bin'),
        behavior: SnackBarBehavior.floating,
        width: 360,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            // Only undo if the delete is still the latest edit.
            if (_undo.isNotEmpty && _undo.last.deletedPage == page) {
              _applyUndo();
            }
          },
        ),
      ),
    );
  }

  Future<void> _openRecycleBin() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RecycleBinSheet(
        doc: _doc!,
        store: _store!,
        onRestored: (page) {
          setState(() {});
          final index = _doc!.pages.indexOf(page);
          if (index >= 0) _jumpToPage(index);
        },
      ),
    );
    if (mounted) setState(() {});
  }

  void _togglePenEraser() {
    if (!mounted) return;
    setState(() {
      if (_settings.tool == DrawTool.eraser) {
        _settings = _settings.copyWith(tool: _toolBeforeEraser);
      } else {
        _toolBeforeEraser = _settings.tool;
        _settings = _settings.copyWith(tool: DrawTool.eraser);
      }
    });
  }

  void _resetZoom() {
    setState(() => _zoom = 1);
    if (_hScroll.hasClients) _hScroll.jumpTo(0);
    // Keep roughly the same page in view.
    final index = _currentPage;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _doc!.pages.isNotEmpty) {
        _scroll.jumpTo(
          math.min(
            _itemTop(index, _zoomedWidth()) - _pageGap,
            _scroll.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  double _itemExtent(NotePage p, double width) =>
      _band + width * p.aspect + _band + _pageGap;

  void _updateCurrentPage() {
    final doc = _doc;
    if (doc == null || !_scroll.hasClients) return;
    final width = _zoomedWidth();
    // The page whose area covers the vertical middle of the viewport.
    final probe = _scroll.offset + _scroll.position.viewportDimension / 2;
    var y = _pageGap;
    var index = 0;
    for (var i = 0; i < doc.pages.length; i++) {
      y += _itemExtent(doc.pages[i], width);
      index = i;
      if (y > probe) break;
    }
    if (index != _currentPage) setState(() => _currentPage = index);
  }

  void _jumpToPage(int index) {
    final doc = _doc;
    if (doc == null || !_scroll.hasClients) return;
    final width = _zoomedWidth();
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _itemExtent(doc.pages[i], width);
    }
    // Wait a frame so a just-appended page is included in maxScrollExtent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        math.min(offset, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    });
  }

  // ---------------------------------------------------------------- events

  void _onSlideAdded(NotePage page) {
    if (!mounted) return;
    // The page is appended at the end; the scroll offset is left untouched.
    setState(() {});
    final index = _doc!.pages.indexOf(page);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('New slide added as page ${index + 1}'),
        behavior: SnackBarBehavior.floating,
        width: 360,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Show',
          onPressed: () => _jumpToPage(index),
        ),
      ),
    );
  }

  void _recordEdit(_Edit edit) {
    _undo.add(edit);
    _redo.clear();
    _doc?.markDirty();
    setState(() {});
  }

  void _applyUndo() {
    if (_undo.isEmpty) return;
    final e = _undo.removeLast()..revert();
    _redo.add(e);
    _doc?.markDirty();
    setState(() {});
  }

  void _applyRedo() {
    if (_redo.isEmpty) return;
    final e = _redo.removeLast()..apply();
    _undo.add(e);
    _doc?.markDirty();
    setState(() {});
  }

  void _resizePage(NotePage page, PageSide side, {required bool grow}) {
    // Shrinking only removes white space, never part of the slide.
    final amount = grow
        ? _resizeStep
        : -math.min(_resizeStep, page.removableOn(side));
    if (amount == 0) return;
    final w = _zoomedWidth();
    final heightBefore = w * page.aspect;
    _recordEdit(_Edit.extend(page, side, amount)..apply());

    // The page grows/shrinks downward from its top. For the bottom edge,
    // scroll by the same amount so that edge (and its buttons) stays put
    // under the finger, mirroring how the top edge stays put for top resizes.
    if (side == PageSide.bottom && _scroll.hasClients) {
      final delta = w * page.aspect - heightBefore;
      _scroll.jumpTo(math.max(0, _scroll.offset + delta));
    }
  }

  void _addBlankPage() {
    final doc = _doc!;
    doc.appendPage(NotePage(id: DocumentStore.newPageId(), aspect: 1));
    setState(() {});
    _jumpToPage(doc.pages.length - 1);
  }

  Future<void> _exportPdf(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : box.localToGlobal(Offset.zero) & box.size;
    if (_doc!.pages.isEmpty) {
      _showError('Nothing to export yet.');
      return;
    }
    setState(() => _exporting = true);
    try {
      await _saver!.flush();
      final file = await exportPdf(_doc!, _store!);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      _showError('PDF export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Saves (with a fresh library preview) and returns to the library.
  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    _link?.stop();
    await _saver?.flush(thumbnail: true);
    widget.library.lastOpenedId = null;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _rename() async {
    final doc = _doc!;
    final title = await showRenameDialog(context, doc.title);
    if (title == null || title == doc.title) return;
    setState(() => doc.title = title);
    doc.markDirty();
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    if (doc == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return PopScope(
      // Leaving goes through _close so the note is saved first. This also
      // disables the iOS edge-swipe, which would fight with drawing.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: _buildScaffold(context, doc),
    );
  }

  Widget _buildScaffold(BuildContext context, NoteDocument doc) {
    return Scaffold(
      backgroundColor: const Color(0xFFE9E9EE),
      appBar: _buildToolbar(context, doc),
      body: Stack(
        children: [
          Listener(
            // Raw pointer tracking for pinch zoom; it doesn't compete with
            // the scroll views' gestures, it just freezes them while pinching.
            onPointerDown: _onTouchDown,
            onPointerMove: _onTouchMove,
            onPointerUp: _onTouchEnd,
            onPointerCancel: _onTouchEnd,
            child: ScrollConfiguration(
              behavior: _NotebookScrollBehavior(
                fingerDraws: _settings.fingerDraws,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _viewport = constraints.biggest;
                  final width = _zoomedWidth();
                  final physics = _pinch != null
                      ? const NeverScrollableScrollPhysics()
                      : null;
                  return SingleChildScrollView(
                    controller: _hScroll,
                    scrollDirection: Axis.horizontal,
                    physics: physics,
                    child: SizedBox(
                      width: _contentWidth(width),
                      height: constraints.maxHeight,
                      child: ListView.builder(
                        controller: _scroll,
                        physics: physics,
                        // Room after the last page so its bottom edge can
                        // be scrolled all the way up to the top.
                        padding: EdgeInsets.only(
                          top: _pageGap,
                          bottom: math.max(
                            0,
                            constraints.maxHeight - _band - _pageGap,
                          ),
                        ),
                        itemCount: doc.pages.length,
                        // Exact extents keep offsets stable when pages are
                        // appended and make zoom anchoring exact.
                        itemExtentBuilder: (i, _) => i < doc.pages.length
                            ? _itemExtent(doc.pages[i], width)
                            : null,
                        itemBuilder: (context, i) =>
                            _buildPage(doc.pages[i], i, width),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (_zoom != 1)
            Positioned(
              left: 16,
              bottom: 16,
              child: ActionChip(
                avatar: const Icon(Icons.zoom_out_map, size: 18),
                label: Text('${(_zoom * 100).round()}%'),
                tooltip: 'Reset zoom',
                onPressed: _resetZoom,
              ),
            ),
          if (doc.pages.isEmpty)
            const Center(
              child: Text(
                'No pages yet.\nScreenshots from the Mac appear here, '
                'or add a blank page from the toolbar.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black45, fontSize: 16),
              ),
            )
          else
            Positioned(
              right: 16,
              bottom: 16,
              // Purely informational; let taps reach page buttons under it.
              child: IgnorePointer(
                child: _PageIndicator(
                  current: math.min(_currentPage + 1, doc.pages.length),
                  total: doc.pages.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPage(NotePage page, int index, double width) {
    Widget extend(PageSide side) => _ResizeButtons(
      side: side,
      onGrow: () => _resizePage(page, side, grow: true),
      onShrink: page.removableOn(side) > 0
          ? () => _resizePage(page, side, grow: false)
          : null,
    );

    return SizedBox(
      height: _itemExtent(page, width),
      child: Column(
        children: [
          // Buttons are pinned to the page's top-left corner area so they
          // don't move when the page is resized.
          SizedBox(
            height: _band,
            width: width,
            child: Align(
              alignment: Alignment.centerLeft,
              child: extend(PageSide.top),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _band,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: extend(PageSide.left),
                ),
              ),
              Material(
                elevation: 2,
                child: SizedBox(
                  width: width,
                  child: PageCanvas(
                    key: ValueKey(page.id),
                    page: page,
                    imageFile: page.imageFile == null
                        ? null
                        : _store!.imageFile(page.imageFile!),
                    settings: _settings,
                    onStrokeAdded: (p, s) => _recordEdit(_Edit.add(p, [s])),
                    onStrokesErased: (p, s) => _recordEdit(_Edit.erase(p, s)),
                    onStrokesMoved: (p, strokes, delta) =>
                        _recordEdit(_Edit.moveStrokes(p, strokes, delta)),
                  ),
                ),
              ),
              SizedBox(
                width: _band,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: extend(PageSide.right),
                ),
              ),
            ],
          ),
          SizedBox(
            height: _band,
            width: width,
            child: Row(
              children: [
                extend(PageSide.bottom),
                const SizedBox(width: 20),
                _DeleteButton(
                  tooltip: page.slideId != null
                      ? 'Delete slide'
                      : 'Delete page',
                  onPressed: () => _deletePage(page),
                ),
                const Spacer(),
                Text(
                  page.slideId != null
                      ? '${index + 1} · slide'
                      : '${index + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.black45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildToolbar(BuildContext context, NoteDocument doc) {
    final s = _settings;
    final windowWidth = MediaQuery.sizeOf(context).width;
    final singleRow = windowWidth >= _singleRowMinWidth;
    // Slide Over and similar: document actions join the tool row.
    final compact = windowWidth < _compactMaxWidth;

    Widget toolButton(DrawTool tool, IconData icon, String tip) => IconButton(
      tooltip: tip,
      isSelected: s.tool == tool,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: s.tool == tool ? Colors.black12 : null,
      ),
      onPressed: () => setState(() => _settings = s.copyWith(tool: tool)),
    );

    final docActions = IconTheme.merge(
      data: const IconThemeData(color: Colors.black87),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: _undo.isEmpty ? null : _applyUndo,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: _redo.isEmpty ? null : _applyRedo,
          ),
          IconButton(
            tooltip: 'Add blank page',
            icon: const Icon(Icons.note_add_outlined),
            onPressed: _addBlankPage,
          ),
          Builder(
            builder: (btnContext) => IconButton(
              tooltip: 'Export PDF',
              icon: _exporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.picture_as_pdf_outlined),
              onPressed: _exporting ? null : () => _exportPdf(btnContext),
            ),
          ),
        ],
      ),
    );

    // Groups are spread evenly over all the width they get. Only in very
    // narrow windows (Slide Over) is the row scaled down to fit.
    final drawingToolsRow = IconTheme.merge(
      data: const IconThemeData(color: Colors.black87),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              toolButton(DrawTool.pen, Icons.edit, 'Pen'),
              toolButton(
                DrawTool.highlighter,
                Icons.border_color,
                'Highlighter',
              ),
              toolButton(DrawTool.eraser, Icons.auto_fix_normal, 'Eraser'),
              toolButton(DrawTool.lasso, Icons.highlight_alt, 'Lasso select'),
            ],
          ),
          // Colors and widths belong to the highlighter while it is selected,
          // otherwise to the pen (picking one from the eraser switches to pen).
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in s.isHighlighter ? _highlighterColors : _penColors)
                _ColorSwatch(
                  color: c,
                  selected:
                      c == (s.isHighlighter ? s.highlighterColor : s.penColor),
                  onTap: () => setState(
                    () => _settings = s.isHighlighter
                        ? s.copyWith(highlighterColor: c)
                        : s.copyWith(penColor: c, tool: DrawTool.pen),
                  ),
                ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (w, dot)
                  in s.isHighlighter ? _highlighterWidths : _penWidths)
                _WidthButton(
                  dot: dot,
                  color: s.isHighlighter ? s.highlighterColor : 0xDD000000,
                  selected:
                      w == (s.isHighlighter ? s.highlighterWidth : s.penWidth),
                  onTap: () => setState(
                    () => _settings = s.isHighlighter
                        ? s.copyWith(highlighterWidth: w)
                        : s.copyWith(penWidth: w),
                  ),
                ),
            ],
          ),
          PopupMenuButton<Smoothing>(
            tooltip: 'Smoothing: ${s.smoothing.label}',
            initialValue: s.smoothing,
            onSelected: (level) {
              setState(() => _settings = _settings.copyWith(smoothing: level));
              _prefs?.setString(_smoothingKey, level.name);
            },
            itemBuilder: (_) => [
              for (final level in Smoothing.values)
                CheckedPopupMenuItem(
                  value: level,
                  checked: level == s.smoothing,
                  child: Text('${level.label} smoothing'),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.gesture, size: 22),
                  Text(
                    s.smoothing.label,
                    style: const TextStyle(fontSize: 10, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          if (compact) docActions,
        ],
      ),
    );

    final drawingTools = LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: drawingToolsRow,
        ),
      ),
    );

    final title = InkWell(
      onTap: _rename,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: singleRow ? 220 : 400),
          child: Text(doc.title, overflow: TextOverflow.ellipsis),
        ),
      ),
    );

    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      elevation: 1,
      titleSpacing: 0,
      automaticallyImplyLeading: false,
      title: Row(
        children: [
          if (compact)
            IconButton(
              tooltip: 'Notes',
              onPressed: _closing ? null : _close,
              icon: const Icon(Icons.grid_view_rounded, size: 20),
            )
          else
            TextButton.icon(
              onPressed: _closing ? null : _close,
              icon: const Icon(Icons.grid_view_rounded, size: 20),
              label: const Text('Notes'),
            ),
          const SizedBox(width: 4),
          _StatusDot(link: _link!),
          const SizedBox(width: 8),
          // Tap the title to rename the note. With the tools in the same
          // row its width is capped so the tools always get their space;
          // otherwise it takes what is left next to the actions.
          if (singleRow) title else Flexible(child: title),
          if (singleRow) ...[
            const SizedBox(width: 12),
            Expanded(child: drawingTools),
          ],
        ],
      ),
      actions: [
        if (singleRow) const VerticalDivider(indent: 12, endIndent: 12),
        if (!compact) docActions,
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'finger':
                setState(
                  () => _settings = s.copyWith(fingerDraws: !s.fingerDraws),
                );
              case 'rename':
                _rename();
              case 'bin':
                _openRecycleBin();
            }
          },
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: 'finger',
              checked: s.fingerDraws,
              child: const Text('Draw with finger'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'bin',
              child: Text(
                doc.trash.isEmpty
                    ? 'Recycle bin'
                    : 'Recycle bin (${doc.trash.length})',
              ),
            ),
            const PopupMenuItem(value: 'rename', child: Text('Rename…')),
          ],
        ),
        const SizedBox(width: 4),
      ],
      // Narrower windows (e.g. portrait) give the drawing tools their own
      // full-width row so nothing has to scroll or get cut off.
      bottom: singleRow
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(_toolRowHeight),
              child: Container(
                height: _toolRowHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Color(0x14000000))),
                ),
                child: drawingTools,
              ),
            ),
    );
  }
}

/// Only lets fingers (and trackpads) scroll, so the Pencil is free to draw.
/// With "Draw with finger" enabled, touch is reserved for drawing too.
class _NotebookScrollBehavior extends MaterialScrollBehavior {
  const _NotebookScrollBehavior({required this.fingerDraws});

  final bool fingerDraws;

  @override
  Set<PointerDeviceKind> get dragDevices => {
    if (!fingerDraws) PointerDeviceKind.touch,
    PointerDeviceKind.trackpad,
  };
}

class _PinchAnchor {
  _PinchAnchor({
    required this.startZoom,
    required this.startSpan,
    required this.pageIndex,
    required this.fx,
    required this.fy,
  });

  final double startZoom;
  final double startSpan;

  /// Page under the fingers and the focal point's position on it
  /// (0..1 across its width / height; may lie outside for the margins).
  final int pageIndex;
  final double fx;
  final double fy;
}

/// An undoable change on one page.
class _Edit {
  _Edit._(this.apply, this.revert, {this.deletedPage});

  /// Deleting moves the page to the recycle bin; undo takes it back out.
  _Edit.deletePage(NoteDocument doc, NotePage page)
    : this._(() => doc.trashPage(page), () {
        final entry = doc.trashEntryFor(page);
        if (entry != null) doc.restorePage(entry);
      }, deletedPage: page);

  _Edit.add(NotePage page, List<Stroke> strokes)
    : this._(
        () => page.insertStrokes(strokes),
        () => page.removeStrokes(strokes),
      );

  _Edit.erase(NotePage page, List<Stroke> strokes)
    : this._(
        () => page.removeStrokes(strokes),
        () => page.insertStrokes(strokes),
      );

  _Edit.extend(NotePage page, PageSide side, double amount)
    : this._(() => page.extend(side, amount), () => page.extend(side, -amount));

  _Edit.moveStrokes(NotePage page, List<Stroke> strokes, Offset delta)
    : this._(
        () => page.translateStrokes(strokes, delta),
        () => page.translateStrokes(strokes, -delta),
      );

  final VoidCallback apply;
  final VoidCallback revert;
  final NotePage? deletedPage;
}

const _controlBorder = Color(0x1F000000);
const _controlShadow = [
  BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2)),
];

/// A "+" / "−" pill next to a page edge: adds or removes white space on
/// that side. Horizontal on the top/bottom edges, vertical on the sides.
class _ResizeButtons extends StatelessWidget {
  const _ResizeButtons({
    required this.side,
    required this.onGrow,
    required this.onShrink,
  });

  final PageSide side;
  final VoidCallback onGrow;

  /// Null when there is no white space left to remove on this side.
  final VoidCallback? onShrink;

  @override
  Widget build(BuildContext context) {
    final vertical = side == PageSide.left || side == PageSide.right;
    final divider = vertical
        ? const SizedBox(width: 16, child: Divider(height: 1, thickness: 1))
        : const SizedBox(
            height: 16,
            child: VerticalDivider(width: 1, thickness: 1),
          );
    final children = [
      _PillSegment(
        icon: Icons.add,
        tooltip: 'Add space (${side.name})',
        onTap: onGrow,
      ),
      divider,
      _PillSegment(
        icon: Icons.remove,
        tooltip: 'Remove space (${side.name})',
        onTap: onShrink,
      ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _controlBorder, width: 0.5),
        boxShadow: _controlShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(14),
        child: vertical
            ? Column(mainAxisSize: MainAxisSize.min, children: children)
            : Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _PillSegment extends StatelessWidget {
  const _PillSegment({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox.square(
          dimension: 28,
          child: Icon(
            icon,
            size: 16,
            color: enabled ? const Color(0xFF3A3A3C) : const Color(0x33000000),
          ),
        ),
      ),
    );
  }
}

/// Soft red pill for deleting a page or slide.
class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  static const _red = Color(0xFFD93025);

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xFFFDECEA),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.delete_outline_rounded, size: 16, color: _red),
                SizedBox(width: 4),
                Text(
                  'Delete',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _red,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.link});

  final SlideLink link;

  @override
  Widget build(BuildContext context) {
    final mac = link.peer ?? 'Mac';
    final (color, text) = switch (link.state) {
      LinkState.connected => (Colors.green, 'Connected to $mac'),
      LinkState.connecting => (
        Colors.orange,
        'Connecting to $mac… (approve this iPad in the Mac app)',
      ),
      LinkState.searching ||
      LinkState.off => (Colors.grey, 'Looking for the Mac app nearby…'),
    };
    return Tooltip(
      message: text,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final int color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: Color(color),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.black : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}

class _WidthButton extends StatelessWidget {
  const _WidthButton({
    required this.dot,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final double dot;
  final int color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? Colors.black12 : null,
        ),
        alignment: Alignment.center,
        child: Container(
          width: dot,
          height: dot,
          decoration: BoxDecoration(
            color: Color(color),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  const _PageIndicator({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        '$current / $total',
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}

/// Lists the note's deleted pages; each can be restored to where it was or
/// deleted for good (which also removes its slide image).
class _RecycleBinSheet extends StatefulWidget {
  const _RecycleBinSheet({
    required this.doc,
    required this.store,
    required this.onRestored,
  });

  final NoteDocument doc;
  final DocumentStore store;
  final void Function(NotePage page) onRestored;

  @override
  State<_RecycleBinSheet> createState() => _RecycleBinSheetState();
}

class _RecycleBinSheetState extends State<_RecycleBinSheet> {
  NoteDocument get doc => widget.doc;

  void _restore(TrashedPage entry) {
    doc.restorePage(entry);
    widget.onRestored(entry.page);
    if (doc.trash.isEmpty) {
      Navigator.pop(context);
    } else {
      setState(() {});
    }
  }

  Future<void> _purge(List<TrashedPage> entries) async {
    for (final e in entries) {
      doc.purge(e);
    }
    // Remove slide images nothing refers to any more.
    final used = doc.referencedImages;
    for (final e in entries) {
      final img = e.page.imageFile;
      if (img != null && !used.contains(img)) {
        await widget.store.deleteImage(img);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _confirmPurge(List<TrashedPage> entries) async {
    final all = entries.length == doc.trash.length && entries.length > 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(all ? 'Empty the recycle bin?' : 'Delete page forever?'),
        content: Text(
          all
              ? 'All ${entries.length} pages and their slides will be deleted '
                    'permanently.'
              : 'This page and its slide will be deleted permanently.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (ok == true) await _purge(entries);
  }

  @override
  Widget build(BuildContext context) {
    final trash = doc.trash;
    final height = MediaQuery.sizeOf(context).height * 0.75;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.delete_outline_rounded),
                const SizedBox(width: 8),
                Text(
                  'Recycle bin',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(width: 8),
                Text(
                  '${trash.length} page${trash.length == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.black54),
                ),
                const Spacer(),
                if (trash.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red[700],
                    ),
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('Empty bin'),
                    onPressed: () => _confirmPurge(List.of(trash)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: trash.isEmpty
                ? const Center(
                    child: Text(
                      'Deleted pages appear here and can be restored.',
                      style: TextStyle(color: Colors.black45),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 260,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.78,
                        ),
                    itemCount: trash.length,
                    itemBuilder: (_, i) => _BinTile(
                      entry: trash[i],
                      store: widget.store,
                      onRestore: () => _restore(trash[i]),
                      onDelete: () => _confirmPurge([trash[i]]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _BinTile extends StatelessWidget {
  const _BinTile({
    required this.entry,
    required this.store,
    required this.onRestore,
    required this.onDelete,
  });

  final TrashedPage entry;
  final DocumentStore store;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  static String _date(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final page = entry.page;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _controlBorder, width: 0.5),
        boxShadow: _controlShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              child: ColoredBox(
                color: const Color(0xFFF2F2F5),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    // Read-only preview: the page with its ink.
                    child: IgnorePointer(
                      child: FittedBox(
                        child: SizedBox(
                          width: 400,
                          child: Material(
                            elevation: 1,
                            child: PageCanvas(
                              page: page,
                              imageFile: page.imageFile == null
                                  ? null
                                  : store.imageFile(page.imageFile!),
                              settings: const ToolSettings(),
                              onStrokeAdded: (_, _) {},
                              onStrokesErased: (_, _) {},
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              '${page.slideId != null ? 'Slide' : 'Page'} · was page ${entry.index + 1}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Deleted ${_date(entry.deletedAt)}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      alignment: Alignment.centerLeft,
                    ),
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('Restore'),
                    onPressed: onRestore,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Delete forever',
                  icon: Icon(
                    Icons.delete_forever_outlined,
                    color: Colors.red[700],
                  ),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
