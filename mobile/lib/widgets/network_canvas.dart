import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../l10n/strings.dart';
import '../theme/app_theme.dart';
import 'kit.dart';

/// Interactive force-directed company network.
///
/// * nodes sized by revenue, coloured by PD (or by an override, for cascades)
/// * supply edges carry particles flowing in the direction goods move
/// * group (ownership / guarantee) edges are dashed, sector-peer edges dotted
/// * hover shows a company card and highlights its links; tap opens it
class NetworkCanvas extends StatefulWidget {
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final String? center;
  final Map<String, double>? riskOverride;
  final Set<String> failed;
  final void Function(String id, String name)? onOpen;
  final double height;
  const NetworkCanvas({super.key, required this.nodes, required this.edges, this.center, this.riskOverride,
      this.failed = const {}, this.onOpen, this.height = 460});

  @override
  State<NetworkCanvas> createState() => _NetworkCanvasState();
}

class _NetworkCanvasState extends State<NetworkCanvas> with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  final _pos = <String, Offset>{};
  final _vel = <String, Offset>{};
  double _temp = 1.0, _time = 0;
  Duration _last = Duration.zero;
  String? _hover;
  Size _size = const Size(800, 460);

  @override
  void initState() {
    super.initState();
    _seed();
    _ticker = createTicker(_tick)..start();
  }

  @override
  void didUpdateWidget(NetworkCanvas old) {
    super.didUpdateWidget(old);
    if (old.nodes.length != widget.nodes.length || old.center != widget.center) {
      _seed();
      _temp = 1.0;
    }
  }

  void _seed() {
    final rng = math.Random(widget.center.hashCode);
    final byDepth = <int, List<Map<String, dynamic>>>{};
    for (final n in widget.nodes) {
      byDepth.putIfAbsent((n['depth'] as int?) ?? 1, () => []).add(n);
    }
    for (final e in byDepth.entries) {
      final ring = e.key == 0 ? 0.0 : 0.22 * e.key;
      for (var i = 0; i < e.value.length; i++) {
        final a = i / e.value.length * math.pi * 2 + rng.nextDouble() * 0.3;
        _pos[e.value[i]['id']] = Offset(0.5 + ring * math.cos(a), 0.5 + ring * math.sin(a) * 0.9);
        _vel[e.value[i]['id']] = Offset.zero;
      }
    }
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    _time += dt;
    if (_temp > 0.02) {
      final ids = _pos.keys.toList();
      final f = {for (final id in ids) id: Offset.zero};
      final k = (ids.length < 16 ? 1.3 : 0.9) / math.sqrt(math.max(ids.length, 1));
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          var d = _pos[ids[i]]! - _pos[ids[j]]!;
          final dist = math.max(d.distance, 0.01);
          final rep = (k * k / dist) * 0.06;
          d = d / dist * rep;
          f[ids[i]] = f[ids[i]]! + d;
          f[ids[j]] = f[ids[j]]! - d;
        }
      }
      for (final e in widget.edges) {
        final a = e['source'], b = e['target'];
        if (!_pos.containsKey(a) || !_pos.containsKey(b)) continue;
        var d = _pos[b]! - _pos[a]!;
        final dist = math.max(d.distance, 0.01);
        final att = (dist * dist / k) * 0.5 * (e['type'] == 'SAME_INDUSTRY' ? 0.3 : 1.0);
        d = d / dist * att;
        f[a] = f[a]! + d;
        f[b] = f[b]! - d;
      }
      for (final id in ids) {
        if (id == widget.center) {
          _pos[id] = Offset.lerp(_pos[id]!, const Offset(0.5, 0.5), 0.2)!;
          continue;
        }
        final g = (const Offset(0.5, 0.5) - _pos[id]!) * 0.04;          // gravity
        _vel[id] = (_vel[id]! + (f[id]! + g) * dt * 4) * 0.82;
        var step = _vel[id]!;
        if (step.distance > 0.02 * _temp) step = step / step.distance * 0.02 * _temp;
        final p = _pos[id]! + step;
        _pos[id] = Offset(p.dx.clamp(0.04, 0.96), p.dy.clamp(0.06, 0.94));
      }
      _temp *= 0.992;
    }
    setState(() {});
  }

  Offset _px(String id) => Offset(_pos[id]!.dx * _size.width, _pos[id]!.dy * _size.height);

  String? _hit(Offset p) {
    String? best;
    var bd = 1e9;
    for (final id in _pos.keys) {
      final d = (_px(id) - p).distance;
      if (d < bd) {
        bd = d;
        best = id;
      }
    }
    return bd < 22 ? best : null;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final hoverNode = _hover == null ? null : widget.nodes.firstWhere((n) => n['id'] == _hover, orElse: () => {});
    return Container(
      height: widget.height,
      decoration: BoxDecoration(color: k.bg, border: Border.all(color: k.line), borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, c) {
        _size = Size(c.maxWidth, widget.height);
        return Stack(children: [
          Positioned.fill(
            child: MouseRegion(
              onHover: (e) {
                final h = _hit(e.localPosition);
                if (h != _hover) setState(() => _hover = h);
              },
              onExit: (_) => setState(() => _hover = null),
              cursor: _hover != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
              child: GestureDetector(
                onTapUp: (d) {
                  final h = _hit(d.localPosition);
                  if (h == null) return;
                  final n = widget.nodes.firstWhere((x) => x['id'] == h);
                  if (_hover != h) {
                    setState(() => _hover = h);           // touch: first tap shows card
                  } else {
                    widget.onOpen?.call(h, n['name'] ?? h);
                  }
                },
                child: CustomPaint(painter: _NetPainter(this, k)),
              ),
            ),
          ),
          Positioned(left: 12, bottom: 10, child: _Legend(k)),
          if (hoverNode != null && hoverNode.isNotEmpty)
            Positioned(
              right: 12, top: 12,
              child: Container(
                width: 240,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: k.raised.withValues(alpha: 0.96), border: Border.all(color: k.lineStrong),
                    borderRadius: BorderRadius.circular(6)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(hoverNode['name'] ?? hoverNode['id'], style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('${hoverNode['industry'] ?? ''} · ${hoverNode['id']}', style: context.tt.bodySmall),
                  const SizedBox(height: 10),
                  Row(children: [
                    Text(fmtPd(widget.riskOverride?[hoverNode['id']] ?? hoverNode['risk']),
                        style: KType.mono(k.forPd((widget.riskOverride?[hoverNode['id']] ?? hoverNode['risk'] as num).toDouble()), 20, w: FontWeight.w600)),
                    const Spacer(),
                    if (hoverNode['band'] != null) BandChip(hoverNode['band'], dense: true),
                  ]),
                  if (widget.onOpen != null) ...[
                    const SizedBox(height: 8),
                    Text('${context.t('open')} →', style: TextStyle(color: k.accent, fontSize: 12)),
                  ],
                ]),
              ),
            ),
        ]);
      }),
    );
  }
}

class _Legend extends StatelessWidget {
  final KColors k;
  const _Legend(this.k);
  @override
  Widget build(BuildContext context) {
    Widget item(Widget sw, String label) => Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [sw, const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 11, color: k.muted))]),
        );
    return Wrap(children: [
      item(Container(width: 18, height: 2, color: k.muted), '${context.t('relationSuppliers')} → ${context.t('relationCustomers')}'),
      item(SizedBox(width: 18, child: CustomPaint(painter: _DashSwatch(k.accent))), context.t('relationGroup')),
      item(Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.critical))),
          context.t('bandCRITICAL')),
    ]);
  }
}

class _DashSwatch extends CustomPainter {
  final Color c;
  _DashSwatch(this.c);
  @override
  void paint(Canvas canvas, Size size) {
    for (double x = 0; x < 18; x += 6) {
      canvas.drawLine(Offset(x, 1), Offset(x + 3, 1), Paint()..color = c..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

class _NetPainter extends CustomPainter {
  final _NetworkCanvasState s;
  final KColors k;
  _NetPainter(this.s, this.k);

  double _risk(Map<String, dynamic> n) => s.widget.riskOverride?[n['id']] ?? (n['risk'] as num).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final w = s.widget;
    final hover = s._hover;
    final linked = <String>{};
    if (hover != null) {
      for (final e in w.edges) {
        if (e['source'] == hover) linked.add(e['target']);
        if (e['target'] == hover) linked.add(e['source']);
      }
    }
    for (final e in w.edges) {
      final a = e['source'] as String, b = e['target'] as String;
      if (!s._pos.containsKey(a) || !s._pos.containsKey(b)) continue;
      final pa = s._px(a), pb = s._px(b);
      final type = e['type'] as String;
      final active = hover == null || a == hover || b == hover;
      final weight = (e['weight'] as num).toDouble();
      final alpha = active ? 1.0 : 0.15;
      if (type == 'SAME_INDUSTRY') {
        _dotted(canvas, pa, pb, k.faint.withValues(alpha: 0.6 * alpha));
      } else if (type == 'OWNS' || type == 'BORROWS_FROM') {
        _dashed(canvas, pa, pb, k.accent.withValues(alpha: 0.75 * alpha), 1.4);
      } else {
        final stressed = w.failed.contains(a) || w.failed.contains(b);
        final col = stressed ? k.critical : k.lineStrong;
        canvas.drawLine(pa, pb, Paint()..color = col.withValues(alpha: (stressed ? 0.8 : 1) * alpha)..strokeWidth = 0.8 + 2.4 * weight);
        // goods flow: SUPPLIES a->b, CUSTOMER_OF a sells to b -> also a->b
        final n = (2 + weight * 4).round();
        for (var i = 0; i < n; i++) {
          final t = ((s._time * 0.22 + i / n) % 1.0);
          canvas.drawCircle(Offset.lerp(pa, pb, t)!, 1.6,
              Paint()..color = (stressed ? k.critical : k.muted).withValues(alpha: 0.9 * alpha));
        }
      }
    }
    for (final n in w.nodes) {
      final id = n['id'] as String;
      if (!s._pos.containsKey(id)) continue;
      final p = s._px(id);
      final r = 4 + math.sqrt(((n['revenue'] as num?) ?? 500).toDouble() / 120).clamp(0.0, 13.0);
      final risk = _risk(n);
      final col = w.failed.contains(id) ? k.critical : k.forPd(risk);
      final dim = hover != null && id != hover && !linked.contains(id);
      if (w.failed.contains(id)) {
        final pulse = (s._time * 0.9) % 1.0;
        canvas.drawCircle(p, r + 4 + pulse * 22,
            Paint()..style = PaintingStyle.stroke..strokeWidth = 1.4..color = k.critical.withValues(alpha: 1 - pulse));
      }
      if (risk >= 0.1 && !dim) {
        canvas.drawCircle(p, r * 2.4, Paint()..color = col.withValues(alpha: 0.14)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
      }
      canvas.drawCircle(p, r, Paint()..color = col.withValues(alpha: dim ? 0.25 : 1));
      if (id == w.center) {
        canvas.drawCircle(p, r + 5, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = k.text);
      }
      final few = w.nodes.length <= 24;
      if (id == hover || id == w.center || (!dim && (few || r > 11))) {
        final name = (n['name'] as String? ?? id).replaceAll(' Ltd', '');
        final tp = TextPainter(text: TextSpan(text: name, style: TextStyle(color: dim ? k.faint : k.text, fontSize: 11)),
            textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')..layout(maxWidth: 160);
        final at = p + Offset(r + 6, -tp.height / 2);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(at.dx - 3, at.dy - 1, tp.width + 6, tp.height + 2), const Radius.circular(2)),
            Paint()..color = k.bg.withValues(alpha: 0.8));
        tp.paint(canvas, at);
      }
    }
  }

  void _dashed(Canvas c, Offset a, Offset b, Color col, double w) {
    final d = b - a;
    final len = d.distance;
    if (len == 0) return;
    final u = d / len;
    for (double t = 0; t < len; t += 9) {
      c.drawLine(a + u * t, a + u * math.min(t + 5, len), Paint()..color = col..strokeWidth = w);
    }
  }

  void _dotted(Canvas c, Offset a, Offset b, Color col) {
    final d = b - a;
    final len = d.distance;
    if (len == 0) return;
    final u = d / len;
    for (double t = 0; t < len; t += 7) {
      c.drawCircle(a + u * t, 0.8, Paint()..color = col);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
