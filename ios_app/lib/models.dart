import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Pages are laid out in "page units": a new page is [pageWidth] units wide
/// (extending a side makes it wider/taller). Stroke points are stored in these
/// units so annotations stay aligned when the on-screen size changes
/// (rotation, split view) and when exporting to PDF.
const double pageWidth = 1000;

/// Height / width of a blank page (A4 portrait).
const double a4Aspect = 297 / 210;

enum StrokeTool { pen, highlighter }

class Stroke {
  Stroke({
    required this.tool,
    required this.color,
    required this.width,
    List<Offset>? points,
  }) : points = points ?? [];

  final StrokeTool tool;
  final int color;
  final double width;
  final List<Offset> points;

  void translate(Offset delta) {
    for (var i = 0; i < points.length; i++) {
      points[i] += delta;
    }
  }

  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var minX = points.first.dx, maxX = minX;
    var minY = points.first.dy, maxY = minY;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(width / 2);
  }

  Map<String, dynamic> toJson() => {
    'tool': tool.name,
    'color': color,
    'width': width,
    // Flattened [x0, y0, x1, y1, ...] rounded to 0.1 units to keep files small.
    'points': [
      for (final p in points) ...[
        (p.dx * 10).round() / 10,
        (p.dy * 10).round() / 10,
      ],
    ],
  };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final flat = (json['points'] as List).cast<num>();
    return Stroke(
      tool: StrokeTool.values.byName(json['tool'] as String),
      color: json['color'] as int,
      width: (json['width'] as num).toDouble(),
      points: [
        for (var i = 0; i + 1 < flat.length; i += 2)
          Offset(flat[i].toDouble(), flat[i + 1].toDouble()),
      ],
    );
  }
}

enum PageSide { left, top, right, bottom }

/// A single page of the notebook: either blank or backed by a slide image.
///
/// A page starts [pageWidth] units wide with the slide image filling it.
/// [extend] adds white space on one side; strokes and the image keep their
/// position relative to each other.
class NotePage extends ChangeNotifier {
  NotePage({
    required this.id,
    required double aspect,
    this.imageFile,
    this.slideId,
    List<Stroke>? strokes,
  }) : width = pageWidth,
       height = pageWidth * aspect,
       imageRect = imageFile == null
           ? null
           : Rect.fromLTWH(0, 0, pageWidth, pageWidth * aspect),
       strokes = strokes ?? [];

  NotePage._({
    required this.id,
    required this.width,
    required this.height,
    required this.imageRect,
    required this.imageFile,
    required this.slideId,
    required this.strokes,
  });

  final String id;

  /// Page size in page units.
  double width;
  double height;

  /// Where the slide image sits on the page, in page units.
  Rect? imageRect;

  /// File name (relative to the notebook's image directory) of the slide image.
  final String? imageFile;

  /// Server-side slide id, if this page came from the Mac.
  final int? slideId;

  final List<Stroke> strokes;

  /// height / width
  double get aspect => height / width;

  /// Grows the page by [amount] units on [side] (negative shrinks, used by
  /// undo). Content is shifted so it stays where it was relative to the
  /// opposite side.
  void extend(PageSide side, double amount) {
    var shift = Offset.zero;
    switch (side) {
      case PageSide.left:
        width += amount;
        shift = Offset(amount, 0);
      case PageSide.right:
        width += amount;
      case PageSide.top:
        height += amount;
        shift = Offset(0, amount);
      case PageSide.bottom:
        height += amount;
    }
    if (shift != Offset.zero) {
      imageRect = imageRect?.shift(shift);
      for (final s in strokes) {
        for (var i = 0; i < s.points.length; i++) {
          s.points[i] += shift;
        }
      }
    }
    notifyListeners();
  }

  /// Smallest size a blank page can be shrunk to, in page units.
  static const double minSize = 200;

  /// How much white space can be removed on [side] without cutting into
  /// the slide image (or, for blank pages, below [minSize]).
  double removableOn(PageSide side) {
    final r = imageRect;
    if (r == null) {
      final size = (side == PageSide.left || side == PageSide.right)
          ? width
          : height;
      return math.max(0, size - minSize);
    }
    final margin = switch (side) {
      PageSide.left => r.left,
      PageSide.right => width - r.right,
      PageSide.top => r.top,
      PageSide.bottom => height - r.bottom,
    };
    // Guard against float noise from repeated extend/shrink.
    return margin < 0.01 ? 0 : margin;
  }

  void addStroke(Stroke s) {
    strokes.add(s);
    notifyListeners();
  }

  void removeStrokes(Iterable<Stroke> toRemove) {
    final set = toRemove.toSet();
    strokes.removeWhere(set.contains);
    notifyListeners();
  }

  void insertStrokes(Iterable<Stroke> toAdd) {
    strokes.addAll(toAdd);
    notifyListeners();
  }

  void translateStrokes(List<Stroke> toMove, Offset delta) {
    for (final s in toMove) {
      s.translate(delta);
    }
    notifyListeners();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'width': width,
    'height': height,
    if (imageRect != null)
      'imageRect': [
        imageRect!.left,
        imageRect!.top,
        imageRect!.width,
        imageRect!.height,
      ],
    if (imageFile != null) 'imageFile': imageFile,
    if (slideId != null) 'slideId': slideId,
    'strokes': [for (final s in strokes) s.toJson()],
  };

  factory NotePage.fromJson(Map<String, dynamic> json) {
    // Documents saved before pages could be extended only stored 'aspect'.
    final width = (json['width'] as num?)?.toDouble() ?? pageWidth;
    final height =
        (json['height'] as num?)?.toDouble() ??
        pageWidth * (json['aspect'] as num).toDouble();
    final imageFile = json['imageFile'] as String?;
    final r = (json['imageRect'] as List?)?.cast<num>();
    return NotePage._(
      id: json['id'] as String,
      width: width,
      height: height,
      imageRect: r != null
          ? Rect.fromLTWH(
              r[0].toDouble(),
              r[1].toDouble(),
              r[2].toDouble(),
              r[3].toDouble(),
            )
          : imageFile != null
          ? Rect.fromLTWH(0, 0, width, height)
          : null,
      imageFile: imageFile,
      slideId: json['slideId'] as int?,
      strokes: [
        for (final s in (json['strokes'] as List))
          Stroke.fromJson(s as Map<String, dynamic>),
      ],
    );
  }
}

/// A page in the note's recycle bin, with where it used to be.
class TrashedPage {
  TrashedPage({
    required this.page,
    required this.deletedAt,
    required this.index,
  });

  final NotePage page;
  final DateTime deletedAt;

  /// Position the page had, used when it is restored.
  final int index;

  Map<String, dynamic> toJson() => {
    'page': page.toJson(),
    'deletedAt': deletedAt.toIso8601String(),
    'index': index,
  };

  factory TrashedPage.fromJson(Map<String, dynamic> json) => TrashedPage(
    page: NotePage.fromJson(json['page'] as Map<String, dynamic>),
    deletedAt:
        DateTime.tryParse(json['deletedAt'] as String? ?? '') ?? DateTime.now(),
    index: json['index'] as int? ?? 0,
  );
}

class NoteDocument extends ChangeNotifier {
  NoteDocument({
    required this.title,
    List<NotePage>? pages,
    List<TrashedPage>? trash,
    DateTime? created,
  }) : pages = pages ?? [],
       trash = trash ?? [],
       created = created ?? DateTime.now();

  String title;
  final List<NotePage> pages;

  /// Deleted pages, newest first. Kept (with their slide images) until
  /// restored or deleted permanently.
  final List<TrashedPage> trash;
  DateTime created;

  void appendPage(NotePage page) {
    pages.add(page);
    notifyListeners();
  }

  void removePage(NotePage page) {
    pages.remove(page);
    notifyListeners();
  }

  void insertPage(int index, NotePage page) {
    pages.insert(index.clamp(0, pages.length), page);
    notifyListeners();
  }

  /// Moves [page] to the recycle bin.
  void trashPage(NotePage page) {
    final index = pages.indexOf(page);
    if (index < 0) return;
    pages.removeAt(index);
    trash.insert(
      0,
      TrashedPage(page: page, deletedAt: DateTime.now(), index: index),
    );
    notifyListeners();
  }

  /// Puts a page from the bin back where it was (or at the end if the note
  /// got shorter since).
  void restorePage(TrashedPage entry) {
    if (!trash.remove(entry)) return;
    pages.insert(entry.index.clamp(0, pages.length), entry.page);
    notifyListeners();
  }

  /// Bin entry holding [page], if any.
  TrashedPage? trashEntryFor(NotePage page) {
    for (final t in trash) {
      if (identical(t.page, page)) return t;
    }
    return null;
  }

  /// Removes [entry] from the bin for good.
  void purge(TrashedPage entry) {
    if (trash.remove(entry)) notifyListeners();
  }

  /// Image files still needed by pages or bin entries.
  Set<String> get referencedImages => {
    for (final p in pages)
      if (p.imageFile != null) p.imageFile!,
    for (final t in trash)
      if (t.page.imageFile != null) t.page.imageFile!,
  };

  /// Signals that page contents changed (used to trigger autosave).
  void markDirty() => notifyListeners();

  Map<String, dynamic> toJson() => {
    'version': 1,
    'title': title,
    'created': created.toIso8601String(),
    'pages': [for (final p in pages) p.toJson()],
    'trash': [for (final t in trash) t.toJson()],
  };

  factory NoteDocument.fromJson(Map<String, dynamic> json) => NoteDocument(
    title: json['title'] as String? ?? 'Notes',
    created: DateTime.tryParse(json['created'] as String? ?? ''),
    pages: [
      for (final p in (json['pages'] as List))
        NotePage.fromJson(p as Map<String, dynamic>),
    ],
    trash: [
      for (final t in (json['trash'] as List? ?? const []))
        TrashedPage.fromJson(t as Map<String, dynamic>),
    ],
  );
}
