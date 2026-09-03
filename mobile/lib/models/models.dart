/// Data models mirroring the FastAPI responses.

class CompanyCard {
  final String companyId;
  final String name;
  final String industry;
  final double distressProbability;
  final String riskBand;
  final double healthScore;

  CompanyCard({
    required this.companyId,
    required this.name,
    required this.industry,
    required this.distressProbability,
    required this.riskBand,
    required this.healthScore,
  });

  factory CompanyCard.fromJson(Map<String, dynamic> j) => CompanyCard(
        companyId: j['company_id'] ?? '',
        name: j['name'] ?? '',
        industry: j['industry'] ?? '',
        distressProbability: (j['distress_probability'] ?? 0).toDouble(),
        riskBand: j['risk_band'] ?? 'MODERATE',
        healthScore: (j['health_score'] ?? 0).toDouble(),
      );
}

class Prediction {
  final String companyId;
  final double distressProbability;
  final String riskBand;
  final Map<String, dynamic> multiHorizon;
  final double healthScore;
  final double networkContagion;

  Prediction.fromJson(Map<String, dynamic> j)
      : companyId = j['company_id'] ?? '',
        distressProbability = (j['distress_probability'] ?? 0).toDouble(),
        riskBand = j['risk_band'] ?? 'MODERATE',
        multiHorizon = Map<String, dynamic>.from(j['multi_horizon'] ?? {}),
        healthScore = (j['health_score'] ?? 0).toDouble(),
        networkContagion = (j['network_contagion'] ?? 0).toDouble();
}

class FeatureDriver {
  final String feature;
  final double contribution;
  final String direction;
  final double share;

  FeatureDriver.fromJson(Map<String, dynamic> j)
      : feature = j['feature'] ?? '',
        contribution = (j['contribution'] ?? 0).toDouble(),
        direction = j['direction'] ?? '',
        share = (j['share'] ?? 0).toDouble();
}
