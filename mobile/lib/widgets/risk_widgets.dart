import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Small pill showing a risk band with its colour.
class RiskBandChip extends StatelessWidget {
  final String band;
  const RiskBandChip(this.band, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.bandColor(band);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c),
      ),
      child: Text(band,
          style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

/// Horizontal probability bar (0..1) coloured by band.
class RiskBar extends StatelessWidget {
  final String label;
  final double value; // 0..1
  final String band;
  const RiskBar({super.key, required this.label, required this.value, this.band = 'MODERATE'});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.bandColor(band);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          Text('${(value * 100).toStringAsFixed(0)}%',
              style: TextStyle(color: c, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: value.clamp(0, 1),
            minHeight: 10,
            backgroundColor: Colors.grey.withOpacity(0.2),
            color: c,
          ),
        ),
      ],
    );
  }
}

/// Signed contribution bar for the explainability screen.
class DriverBar extends StatelessWidget {
  final String feature;
  final double share; // 0..1 magnitude
  final bool raisesRisk;
  const DriverBar({super.key, required this.feature, required this.share, required this.raisesRisk});

  @override
  Widget build(BuildContext context) {
    final c = raisesRisk ? AppTheme.bandCritical : AppTheme.bandLow;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(raisesRisk ? Icons.trending_up : Icons.trending_down, color: c, size: 18),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: Text(feature.replaceAll('_', ' '),
              overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          flex: 4,
          child: LinearProgressIndicator(
            value: share.clamp(0, 1),
            minHeight: 8,
            backgroundColor: Colors.grey.withOpacity(0.15),
            color: c,
          ),
        ),
      ]),
    );
  }
}
