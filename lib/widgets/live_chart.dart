import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One line in a [LiveLineChart]. Null values are gaps (no data that second).
class ChartSeries {
  const ChartSeries(this.name, this.color, this.values);

  final String name;
  final Color color;
  final List<double?> values;

  double? get last {
    for (var i = values.length - 1; i >= 0; i--) {
      if (values[i] != null) return values[i];
    }
    return null;
  }

  Iterable<double> get present => values.whereType<double>();
}

/// A moving line graph in the style of a gaming performance overlay: dark
/// panel, glowing line, filled area, the current value large, min/avg/max.
/// The newest value is at the right edge; [capacity] points fill the width.
class LiveLineChart extends StatelessWidget {
  const LiveLineChart({
    super.key,
    required this.title,
    required this.unit,
    required this.series,
    required this.capacity,
    this.minY = 0,
    this.maxY,
    this.minRange = 1,
    this.digits = 1,
    this.footnote,
    this.height = 96,
  });

  final String title;
  final String unit;
  final List<ChartSeries> series;
  final int capacity;
  final double minY;

  /// Fixed top of the axis (e.g. 100 for %); otherwise it follows the data.
  final double? maxY;

  /// Smallest axis span when following the data, so noise is not magnified.
  final double minRange;
  final int digits;
  final String? footnote;
  final double height;

  static const Color panel = Color(0xFF0E141B);
  static const Color grid = Color(0xFF243140);
  static const Color text = Color(0xFFE6EDF3);
  static const Color muted = Color(0xFF8B9BAB);

  String _fmt(double? v) => v == null ? '–' : v.toStringAsFixed(digits);

  /// "HAR 1.23 ms": current value, large, in the series colour. Text.rich
  /// (not RichText) so it uses the app's font.
  Widget _value(ChartSeries s, TextStyle labelStyle, bool named) {
    return Text.rich(TextSpan(children: [
      if (named)
        TextSpan(
            text: '${s.name} ', style: labelStyle.copyWith(color: s.color)),
      TextSpan(
        text: _fmt(s.last),
        style: TextStyle(
            color: s.color,
            fontSize: 20,
            fontWeight: FontWeight.bold,
            fontFeatures: const [FontFeature.tabularFigures()]),
      ),
      TextSpan(text: ' $unit', style: labelStyle.copyWith(color: muted)),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final main = series.first;
    final values = main.present.toList();
    final mn = values.isEmpty ? null : values.reduce(math.min);
    final mx = values.isEmpty ? null : values.reduce(math.max);
    final avg =
        values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
    final allValues = [for (final s in series) ...s.present];
    final dataMax =
        allValues.isEmpty ? minY + minRange : allValues.reduce(math.max);
    final top = maxY ?? _niceCeil(math.max(dataMax * 1.15, minY + minRange));
    final labelStyle = Theme.of(context).textTheme.labelSmall!;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: main.color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(title.toUpperCase(),
                    style: labelStyle.copyWith(
                        color: muted,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600)),
              ),
              if (series.length == 1) _value(series.single, labelStyle, false),
            ],
          ),
          if (series.length > 1)
            Wrap(
              spacing: 16,
              children: [for (final s in series) _value(s, labelStyle, true)],
            ),
          const SizedBox(height: 6),
          SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(
              painter: _LinePainter(
                series: series,
                capacity: capacity,
                minY: minY,
                maxY: top,
                labelStyle: labelStyle.copyWith(color: muted, fontSize: 9),
                digits: digits,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text('min ${_fmt(mn)} · avg ${_fmt(avg)} · max ${_fmt(mx)}',
              style: labelStyle.copyWith(color: muted)),
          if (footnote != null)
            Text(footnote!, style: labelStyle.copyWith(color: muted)),
        ],
      ),
    );
  }

  static double _niceCeil(double v) {
    if (v <= 0) return 1;
    final mag = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in [1, 2, 2.5, 5, 10]) {
      if (m * mag >= v) return m * mag;
    }
    return 10 * mag;
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.series,
    required this.capacity,
    required this.minY,
    required this.maxY,
    required this.labelStyle,
    required this.digits,
  });

  final List<ChartSeries> series;
  final int capacity;
  final double minY;
  final double maxY;
  final TextStyle labelStyle;
  final int digits;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = LiveLineChart.grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    for (var i = 1; i < 6; i++) {
      final x = size.width * i / 6;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height),
          gridPaint..color = LiveLineChart.grid.withValues(alpha: 0.5));
    }
    final span = (maxY - minY) == 0 ? 1 : (maxY - minY);
    final step = capacity <= 1 ? size.width : size.width / (capacity - 1);
    for (var si = series.length - 1; si >= 0; si--) {
      final s = series[si];
      final n = s.values.length;
      final offset = capacity - n; // newest point at the right edge
      final paths = <Path>[];
      Path? current;
      final points = <Offset>[];
      for (var i = 0; i < n; i++) {
        final v = s.values[i];
        if (v == null) {
          current = null;
          continue;
        }
        final x = (offset + i) * step;
        final y =
            size.height - ((v - minY) / span).clamp(0.0, 1.0) * size.height;
        if (current == null) {
          current = Path()..moveTo(x, y);
          paths.add(current);
        } else {
          current.lineTo(x, y);
        }
        points.add(Offset(x, y));
      }
      if (si == 0) {
        // Filled area under the main line.
        for (final path in paths) {
          final bounds = path.getBounds();
          final fill = Path.from(path)
            ..lineTo(bounds.right, size.height)
            ..lineTo(bounds.left, size.height)
            ..close();
          canvas.drawPath(
            fill,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  s.color.withValues(alpha: 0.35),
                  s.color.withValues(alpha: 0.02)
                ],
              ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
          );
        }
      }
      final glow = Paint()
        ..color = s.color.withValues(alpha: 0.25)
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final line = Paint()
        ..color = s.color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      for (final path in paths) {
        canvas.drawPath(path, glow);
        canvas.drawPath(path, line);
      }
      if (points.isNotEmpty) {
        canvas.drawCircle(points.last, 3, Paint()..color = s.color);
      }
    }
    final top = TextPainter(
      text: TextSpan(text: maxY.toStringAsFixed(digits), style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    top.paint(canvas, const Offset(2, 1));
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}
