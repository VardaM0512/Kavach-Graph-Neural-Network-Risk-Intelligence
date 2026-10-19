import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/app_theme.dart';

// ------------------------------------------------------------ formatting
String fmtPd(num? p) {
  final v = (p ?? 0).toDouble() * 100;
  if (v < 1) return '${v.toStringAsFixed(2)}%';
  if (v < 10) return '${v.toStringAsFixed(1)}%';
  return '${v.toStringAsFixed(0)}%';
}

String fmtPp(num? d) {
  final v = (d ?? 0).toDouble() * 100;
  return '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(v.abs() < 1 ? 2 : 1)} pp';
}

String fmtCr(num? v) {
  final x = (v ?? 0).toDouble();
  if (x.abs() >= 100000) return '₹${(x / 100000).toStringAsFixed(2)} L cr';
  if (x.abs() >= 1000) return '₹${(x / 1000).toStringAsFixed(1)}k cr';
  return '₹${x.toStringAsFixed(0)} cr';
}

/// Ratio formatting by feature semantics.
String fmtRatio(String feature, num? v) {
  final x = (v ?? 0).toDouble();
  const pct = {'ebitda_margin', 'net_margin', 'return_on_assets', 'return_on_equity', 'fcf_margin',
    'revenue_growth_yoy', 'revenue_cagr_3y', 'promoter_pledge', 'working_capital_to_assets', 'debt_to_assets'};
  if (feature == 'margin_trend') return '${x >= 0 ? '+' : ''}${(x * 100).toStringAsFixed(1)} pp';
  if (pct.contains(feature)) return '${(x * 100).toStringAsFixed(1)}%';
  if (feature == 'cash_burn_months') return x >= 60 ? '60+ mo' : '${x.toStringAsFixed(0)} mo';
  return '${x.toStringAsFixed(2)}×';
}

// ------------------------------------------------------------ primitives
class Eyebrow extends StatelessWidget {
  final String text;
  final Color? color;
  const Eyebrow(this.text, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(), style: KType.label(color ?? context.k.muted));
}

/// Bordered section with an eyebrow title. The basic unit of every page.
class Panel extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;
  const Panel({super.key, this.title, this.subtitle, required this.child, this.trailing,
      this.padding = const EdgeInsets.all(18)});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return Container(
      decoration: BoxDecoration(color: k.surface, border: Border.all(color: k.line), borderRadius: BorderRadius.circular(6)),
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (title != null) ...[
          Row(children: [
            Expanded(child: Eyebrow(title!)),
            if (trailing != null) trailing!,
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: context.tt.bodySmall),
          ],
          const SizedBox(height: 14),
        ],
        child,
      ]),
    );
  }
}

class BandChip extends StatelessWidget {
  final String band;
  final bool dense;
  const BandChip(this.band, {super.key, this.dense = false});
  @override
  Widget build(BuildContext context) {
    final c = context.k.band(band);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 2 : 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3),
          border: Border.all(color: c.withValues(alpha: 0.45))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(context.t('band$band').toUpperCase(),
            style: KType.label(c).copyWith(fontSize: dense ? 9.5 : 10.5, letterSpacing: 0.8)),
      ]),
    );
  }
}

class RatingBadge extends StatelessWidget {
  final String rating;
  final double size;
  const RatingBadge(this.rating, {super.key, this.size = 13});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final ig = ['AAA', 'AA', 'A', 'BBB'].contains(rating);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: size * 0.5, vertical: size * 0.15),
      decoration: BoxDecoration(border: Border.all(color: ig ? k.lineStrong : k.faint), borderRadius: BorderRadius.circular(3)),
      child: Text(rating, style: KType.mono(ig ? k.text : k.muted, size, w: FontWeight.w700)),
    );
  }
}

class Kpi extends StatelessWidget {
  final String label;
  final String value;
  final String? delta;
  final Color? deltaColor;
  final Color? valueColor;
  final String? hint;
  const Kpi({super.key, required this.label, required this.value, this.delta, this.deltaColor, this.valueColor, this.hint});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Eyebrow(label),
      const SizedBox(height: 8),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(value, textDirection: TextDirection.ltr, style: KType.mono(valueColor ?? k.text, 28, w: FontWeight.w600)),
      ),
      if (delta != null) ...[
        const SizedBox(height: 4),
        Text(delta!, textDirection: TextDirection.ltr, style: KType.mono(deltaColor ?? k.muted, 12)),
      ],
      if (hint != null) ...[
        const SizedBox(height: 2),
        Text(hint!, style: context.tt.bodySmall),
      ],
    ]);
  }
}

/// Hairline-separated grid of KPIs that reflows on narrow screens.
class KpiStrip extends StatelessWidget {
  final List<Widget> items;
  const KpiStrip(this.items, {super.key});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 900 ? items.length : (c.maxWidth > 520 ? 2 : 2);
      final w = c.maxWidth / cols;
      return Container(
        decoration: BoxDecoration(color: k.surface, border: Border.all(color: k.line), borderRadius: BorderRadius.circular(6)),
        child: Wrap(children: [
          for (var i = 0; i < items.length; i++)
            Container(
              width: w - (i % cols == cols - 1 ? 2 : 0),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(border: Border(
                right: BorderSide(color: i % cols == cols - 1 ? Colors.transparent : k.line),
                bottom: BorderSide(color: i < items.length - cols ? k.line : Colors.transparent),
              )),
              child: items[i],
            ),
        ]),
      );
    });
  }
}

class DeltaText extends StatelessWidget {
  final double delta; // probability delta
  final double size;
  const DeltaText(this.delta, {super.key, this.size = 12});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final c = delta > 0.0005 ? k.critical : delta < -0.0005 ? k.low : k.muted;
    final arrow = delta > 0.0005 ? '▲' : delta < -0.0005 ? '▼' : '■';
    return Text('$arrow ${fmtPp(delta)}', textDirection: TextDirection.ltr, style: KType.mono(c, size));
  }
}

class PageHeader extends StatelessWidget {
  final String eyebrow, title;
  final String? body;
  final List<Widget> actions;
  const PageHeader({super.key, required this.eyebrow, required this.title, this.body, this.actions = const []});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.end,
          runSpacing: 12, spacing: 24, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Eyebrow(eyebrow, color: context.k.accent),
            const SizedBox(height: 10),
            Text(title, style: context.tt.headlineMedium),
            if (body != null) ...[
              const SizedBox(height: 10),
              Text(body!, style: context.tt.bodyMedium?.copyWith(color: context.k.muted)),
            ],
          ]),
        ),
        if (actions.isNotEmpty) Wrap(spacing: 10, runSpacing: 10, children: actions),
      ]),
    );
  }
}

// ------------------------------------------------------------ async states
class LoadingBlock extends StatefulWidget {
  final double height;
  const LoadingBlock({super.key, this.height = 160});
  @override
  State<LoadingBlock> createState() => _LoadingBlockState();
}

class _LoadingBlockState extends State<LoadingBlock> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: k.line),
          gradient: LinearGradient(
            begin: Alignment(-1 + 3 * _c.value - 1, 0), end: Alignment(3 * _c.value - 1, 0),
            colors: [k.surface, k.raised, k.surface],
          ),
        ),
      ),
    );
  }
}

class ErrorBlock extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const ErrorBlock(this.error, this.onRetry, {super.key});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return Panel(
      child: Column(children: [
        Icon(Icons.portable_wifi_off_rounded, color: k.muted),
        const SizedBox(height: 10),
        Text(context.t('apiDown'), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text('$error', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRetry, child: Text(context.t('retry'))),
      ]),
    );
  }
}

/// FutureBuilder with Kavach loading / error states and a retry hook.
class Async<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  final VoidCallback onRetry;
  final double loadingHeight;
  const Async({super.key, required this.future, required this.builder, required this.onRetry, this.loadingHeight = 320});

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: future,
        builder: (context, s) {
          if (s.hasError) return ErrorBlock(s.error!, onRetry);
          if (!s.hasData) return LoadingBlock(height: loadingHeight);
          return builder(context, s.data as T);
        },
      );
}

/// Responsive two-column helper: side by side on wide screens, stacked on narrow.
class Cols extends StatelessWidget {
  final List<Widget> children;
  final List<int>? flex;
  final double breakpoint;
  final double gap;
  const Cols(this.children, {super.key, this.flex, this.breakpoint = 900, this.gap = 16});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < breakpoint) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: gap), children[i]],
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(flex: flex?[i] ?? 1, child: children[i]),
          ],
        ]);
      });
}
