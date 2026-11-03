import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../activity_catalog.dart';
import '../services/timeline.dart';

/// Hour-by-hour picture of a day: a strip coloured by the activity seen
/// longest in each time bin, a thinner strip for the social signal, hour
/// ticks, and the details of the bin under the finger.
class DayTimeline extends StatefulWidget {
  const DayTimeline({super.key, required this.data, this.compact = false});

  final TimelineData data;

  /// Home version: thinner strips, no legend.
  final bool compact;

  @override
  State<DayTimeline> createState() => _DayTimelineState();
}

class _DayTimelineState extends State<DayTimeline> {
  int? _selected;

  @override
  void didUpdateWidget(covariant DayTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected != null && _selected! >= widget.data.bins.length) {
      _selected = null;
    }
  }

  void _select(Offset local, double width) {
    final n = widget.data.bins.length;
    if (n == 0 || width <= 0) return;
    final i = (local.dx / width * n).floor().clamp(0, n - 1);
    setState(() => _selected = i);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final harHeight = widget.compact ? 22.0 : 30.0;
    final socialHeight = widget.compact ? 8.0 : 12.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            key: const ValueKey('day-timeline'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _select(d.localPosition, width),
            onHorizontalDragUpdate: (d) => _select(d.localPosition, width),
            child: CustomPaint(
              size: Size(width, harHeight + socialHeight + 22),
              painter: _TimelinePainter(
                data: data,
                harHeight: harHeight,
                socialHeight: socialHeight,
                selected: _selected,
                empty: scheme.surfaceContainerHighest,
                tickColor: scheme.outline,
                selectColor: scheme.onSurface,
                labelStyle: textTheme.labelSmall!
                    .copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          );
        }),
        const SizedBox(height: 6),
        _details(context),
        if (!widget.compact && data.activities.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final l in data.activities) _legend(context, l),
            ],
          ),
        ],
      ],
    );
  }

  Widget _details(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final i = _selected;
    if (i == null) {
      return Text(
        widget.data.isEmpty
            ? 'No results in this period yet.'
            : 'Top strip: activity · thin strip: social signal. '
                'Tap or drag for details.',
        style: style,
      );
    }
    final b = widget.data.bins[i];
    final hm = DateFormat('HH:mm');
    final range = '${hm.format(b.start)}–${hm.format(b.end)}';
    if (b.isEmpty) return Text('$range · no data', style: style);
    final har = b.har.entries.toList()
      ..sort((a, c) => c.value.compareTo(a.value));
    final coughs = b.socialCounts['coughing'] ?? 0;
    final parts = [
      for (final e in har.take(2))
        '${displayName(e.key)} ${formatDuration(e.value)}',
      if (b.socialLabel != null) 'mostly ${displayName(b.socialLabel!)}',
      if (coughs > 0) '$coughs coughing results',
    ];
    return Text('$range · ${parts.join(' · ')}',
        key: const ValueKey('timeline-details'), style: style);
  }

  Widget _legend(BuildContext context, String label) {
    final info = labelInfo(label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
              color: info.color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(info.displayName, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.data,
    required this.harHeight,
    required this.socialHeight,
    required this.selected,
    required this.empty,
    required this.tickColor,
    required this.selectColor,
    required this.labelStyle,
  });

  final TimelineData data;
  final double harHeight;
  final double socialHeight;
  final int? selected;
  final Color empty;
  final Color tickColor;
  final Color selectColor;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final n = data.bins.length;
    if (n == 0) return;
    final w = size.width / n;
    final socialTop = harHeight + 3;
    final r = Radius.circular(harHeight / 4);
    // Backgrounds (rounded), so empty time reads as "not monitored".
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, harHeight), r),
        Paint()..color = empty);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(0, socialTop, size.width, socialHeight),
            Radius.circular(socialHeight / 2)),
        Paint()..color = empty);
    canvas.save();
    canvas.clipRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, harHeight), r));
    for (final b in data.bins) {
      final label = b.harLabel;
      if (label == null) continue;
      // Partly monitored bins are drawn lighter.
      final alpha = 0.35 + 0.65 * b.coverage;
      canvas.drawRect(Rect.fromLTWH(b.index * w, 0, w + 0.5, harHeight),
          Paint()..color = labelInfo(label).color.withValues(alpha: alpha));
    }
    canvas.restore();
    for (final b in data.bins) {
      final label = b.socialLabel;
      if (label == null) continue;
      // Social results while moving are unreliable: drawn faint.
      final alpha = b.moving ? 0.3 : 0.9;
      canvas.drawRect(
          Rect.fromLTWH(b.index * w, socialTop, w + 0.5, socialHeight),
          Paint()..color = labelInfo(label).color.withValues(alpha: alpha));
    }
    // Hour ticks and labels.
    final totalMinutes = data.end.difference(data.start).inMinutes;
    final stepHours = totalMinutes <= 3 * 60
        ? 1
        : totalMinutes <= 8 * 60
            ? 2
            : totalMinutes <= 14 * 60
                ? 3
                : 6;
    final tick = Paint()
      ..color = tickColor
      ..strokeWidth = 1;
    final labelTop = socialTop + socialHeight + 4;
    var t = DateTime(
        data.start.year, data.start.month, data.start.day, data.start.hour);
    if (t.isBefore(data.start)) t = t.add(const Duration(hours: 1));
    final span = data.end.difference(data.start).inMicroseconds;
    while (!t.isAfter(data.end)) {
      if (t.hour % stepHours == 0 || totalMinutes <= 3 * 60) {
        final x = size.width * t.difference(data.start).inMicroseconds / span;
        canvas.drawLine(Offset(x, labelTop - 3), Offset(x, labelTop), tick);
        final tp = TextPainter(
          text:
              TextSpan(text: DateFormat('HH:mm').format(t), style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        final dx = (x - tp.width / 2).clamp(0.0, size.width - tp.width);
        tp.paint(canvas, Offset(dx, labelTop));
      }
      t = t.add(const Duration(hours: 1));
    }
    final s = selected;
    if (s != null && s < n) {
      canvas.drawRect(
          Rect.fromLTWH(s * w, -2, w.clamp(2.0, double.infinity),
              socialTop + socialHeight + 4),
          Paint()
            ..color = selectColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) =>
      old.data != data || old.selected != selected || old.empty != empty;
}
