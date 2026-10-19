import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';

/// The landing-page animation: a living corporate network in which defaults
/// periodically happen and the shock visibly travels along dependencies,
/// stressing neighbours and occasionally knocking one over too. Tap a node to
/// default it yourself.
class HeroNetwork extends StatefulWidget {
  final int seed;
  const HeroNetwork({super.key, this.seed = 7});
  @override
  State<HeroNetwork> createState() => _HeroNetworkState();
}

class _Node {
  Offset base;
  final double phase, radius, baseline;
  final int cluster;
  final String? tag;
  double stress = 0;   // 0 healthy .. 1 defaulted
  double ring = -1;    // pulse progress, <0 = none
  bool failed = false;
  double failedAt = 0;
  _Node(this.base, this.phase, this.radius, this.baseline, this.cluster, this.tag);
}

class _Edge {
  final int a, b;
  final double w;
  _Edge(this.a, this.b, this.w);
}

class _Particle {
  final int from, to, depth;
  final double strength;
  double t = 0;
  _Particle(this.from, this.to, this.strength, this.depth);
}

class _HeroNetworkState extends State<HeroNetwork> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _nodes = <_Node>[];
  final _edges = <_Edge>[];
  final _adj = <List<int>>[];
  final _particles = <_Particle>[];
  late final math.Random _rng;
  double _time = 0, _nextShock = 1.2;
  Duration _last = Duration.zero;
  Size _size = Size.zero;
  Offset? _hover;

  static const _tags = ['STL·07', 'PWR·12', 'EPC·03', 'AUTO·21', 'CEM·05', 'TXT·14', 'LOG·09', 'RLTY·02', 'CHEM·11', 'FMCG·04'];

  @override
  void initState() {
    super.initState();
    _rng = math.Random(widget.seed);
    _build();
    _ticker = createTicker(_tick)..start();
  }

  void _build() {
    // clusters = sectors laid out on a loose ring; hubs sit near cluster centres
    const nClusters = 7;
    final centres = List.generate(nClusters, (i) {
      final a = i / nClusters * math.pi * 2 + 0.4;
      return Offset(0.5 + 0.30 * math.cos(a), 0.5 + 0.32 * math.sin(a));
    });
    var tagIdx = 0;
    for (var c = 0; c < nClusters; c++) {
      final n = 12 + _rng.nextInt(7);
      for (var i = 0; i < n; i++) {
        final hub = i == 0;
        final r = hub ? 0.0 : 0.03 + _rng.nextDouble() * 0.11;
        final a = _rng.nextDouble() * math.pi * 2;
        final p = centres[c] + Offset(math.cos(a) * r * 1.25, math.sin(a) * r);
        _nodes.add(_Node(p, _rng.nextDouble() * 6.28, hub ? 5.5 : 1.8 + _rng.nextDouble() * 2.4,
            _rng.nextDouble() * 0.18, c, hub && tagIdx < _tags.length ? _tags[tagIdx++] : null));
      }
    }
    for (var i = 0; i < _nodes.length; i++) {
      _adj.add([]);
    }
    void link(int a, int b, double w) {
      if (a == b || _adj[a].contains(b)) return;
      _edges.add(_Edge(a, b, w));
      _adj[a].add(b);
      _adj[b].add(a);
    }
    // nearest neighbours inside the cluster + hub spokes + cross-sector supply links
    for (var i = 0; i < _nodes.length; i++) {
      final d = <MapEntry<int, double>>[];
      for (var j = 0; j < _nodes.length; j++) {
        if (j != i && _nodes[j].cluster == _nodes[i].cluster) {
          d.add(MapEntry(j, (_nodes[i].base - _nodes[j].base).distance));
        }
      }
      d.sort((x, y) => x.value.compareTo(y.value));
      for (final e in d.take(2)) {
        link(i, e.key, 0.3 + _rng.nextDouble() * 0.5);
      }
    }
    final hubs = [for (var i = 0; i < _nodes.length; i++) if (_nodes[i].radius > 5) i];
    for (var i = 0; i < _nodes.length; i++) {
      final h = hubs[_nodes[i].cluster];
      if (_rng.nextDouble() < 0.55) link(i, h, 0.5 + _rng.nextDouble() * 0.4);
    }
    for (var k = 0; k < 26; k++) {
      final a = _rng.nextInt(_nodes.length);
      final b = hubs[_rng.nextInt(hubs.length)];
      if (_nodes[a].cluster != _nodes[b].cluster) link(a, b, 0.35 + _rng.nextDouble() * 0.5);
    }
  }

  void _default(int i) {
    final n = _nodes[i];
    if (n.failed) return;
    n.failed = true;
    n.failedAt = _time;
    n.stress = 1;
    n.ring = 0;
    for (final j in _adj[i]) {
      if (!_nodes[j].failed) {
        final w = _edges.firstWhere((e) => (e.a == i && e.b == j) || (e.a == j && e.b == i)).w;
        _particles.add(_Particle(i, j, w, 1));
      }
    }
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    _time += dt;

    if (_time > _nextShock) {
      // prefer well-connected firms: their failures make the best story
      final cands = List.generate(_nodes.length, (i) => i)..sort((a, b) => _adj[b].length.compareTo(_adj[a].length));
      final pick = cands[_rng.nextInt(math.min(18, cands.length))];
      _default(pick);
      _nextShock = _time + 3.4 + _rng.nextDouble() * 1.6;
    }

    for (final p in List.of(_particles)) {
      p.t += dt * 0.85;
      if (p.t >= 1) {
        _particles.remove(p);
        final n = _nodes[p.to];
        if (n.failed) continue;
        n.stress = math.min(1, n.stress + p.strength * (0.75 / p.depth));
        if (n.stress > 0.78 && p.depth < 3) {
          _default(p.to);
        } else if (p.depth < 2 && n.stress > 0.35) {
          for (final j in _adj[p.to]) {
            if (j != p.from && !_nodes[j].failed && _rng.nextDouble() < 0.5) {
              _particles.add(_Particle(p.to, j, p.strength * 0.5, p.depth + 1));
            }
          }
        }
      }
    }
    for (final n in _nodes) {
      if (n.ring >= 0) n.ring += dt * 0.7;
      if (n.ring > 1) n.ring = -1;
      if (n.failed && _time - n.failedAt > 5.5) n.failed = false; // recovery / resolution
      if (!n.failed) n.stress += (n.baseline - n.stress) * dt * 0.28;
    }
    setState(() {});
  }

  Offset _pos(_Node n) {
    final drift = Offset(math.sin(_time * 0.25 + n.phase) * 0.006, math.cos(_time * 0.21 + n.phase * 1.3) * 0.006);
    final p = n.base + drift;
    return Offset(p.dx * _size.width, p.dy * _size.height);
  }

  void _tap(Offset local) {
    var best = -1;
    var bd = 1e9;
    for (var i = 0; i < _nodes.length; i++) {
      final d = (_pos(_nodes[i]) - local).distance;
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    if (best >= 0 && bd < 60) _default(best);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _size = Size(c.maxWidth, c.maxHeight);
      return MouseRegion(
        cursor: SystemMouseCursors.precise,
        onHover: (e) => _hover = e.localPosition,
        onExit: (_) => _hover = null,
        child: GestureDetector(
          onTapDown: (d) => _tap(d.localPosition),
          child: CustomPaint(
            size: _size,
            painter: _HeroPainter(this, context.k),
          ),
        ),
      );
    });
  }
}

class _HeroPainter extends CustomPainter {
  final _HeroNetworkState s;
  final KColors k;
  _HeroPainter(this.s, this.k);

  Color _stressColor(double stress) {
    if (stress < 0.25) return Color.lerp(k.muted, k.low, 0.45)!.withValues(alpha: 0.75);
    if (stress < 0.55) return Color.lerp(k.moderate, k.high, (stress - 0.25) / 0.3)!;
    return Color.lerp(k.high, k.critical, ((stress - 0.55) / 0.45).clamp(0, 1))!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // dot grid
    final grid = Paint()..color = k.line;
    for (double x = 12; x < size.width; x += 28) {
      for (double y = 12; y < size.height; y += 28) {
        canvas.drawCircle(Offset(x, y), 0.7, grid);
      }
    }
    final pos = [for (final n in s._nodes) s._pos(n)];

    // edges
    for (final e in s._edges) {
      final st = math.max(s._nodes[e.a].stress, s._nodes[e.b].stress);
      final hot = st > 0.3;
      final paint = Paint()
        ..strokeWidth = hot ? 1.1 : 0.7
        ..color = hot ? _stressColor(st).withValues(alpha: 0.35 + 0.3 * st) : k.lineStrong.withValues(alpha: 0.7);
      canvas.drawLine(pos[e.a], pos[e.b], paint);
    }

    // shock particles with short trails
    for (final p in s._particles) {
      final a = pos[p.from], b = pos[p.to];
      final c = p.depth == 1 ? k.critical : k.high;
      for (var i = 0; i < 6; i++) {
        final t = (p.t - i * 0.025).clamp(0.0, 1.0);
        canvas.drawCircle(Offset.lerp(a, b, t)!, 2.4 - i * 0.32,
            Paint()..color = c.withValues(alpha: (1 - i / 6) * 0.95));
      }
    }

    // nodes
    for (var i = 0; i < s._nodes.length; i++) {
      final n = s._nodes[i];
      final p = pos[i];
      final hovered = s._hover != null && (s._hover! - p).distance < 18;
      final col = n.failed ? k.critical : _stressColor(n.stress);
      if (n.stress > 0.3 || n.failed) {
        canvas.drawCircle(p, n.radius * 3.2,
            Paint()..color = col.withValues(alpha: 0.10 + 0.12 * n.stress)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      }
      if (n.ring >= 0) {
        canvas.drawCircle(p, n.radius + n.ring * 46,
            Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = k.critical.withValues(alpha: (1 - n.ring) * 0.8));
      }
      canvas.drawCircle(p, n.radius + (hovered ? 2 : 0), Paint()..color = col);
      if (n.radius > 5) {
        canvas.drawCircle(p, n.radius + 3.5, Paint()..style = PaintingStyle.stroke..strokeWidth = 0.8..color = col.withValues(alpha: 0.5));
      }
      if (n.tag != null || hovered) {
        final tp = TextPainter(
          text: TextSpan(text: n.tag ?? 'C${(i * 37 % 1500).toString().padLeft(4, '0')}',
              style: KType.mono(n.failed ? k.critical : k.muted, 9.5)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, p + Offset(n.radius + 6, -tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
