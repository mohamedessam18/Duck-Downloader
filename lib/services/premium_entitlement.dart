import 'package:in_app_purchase/in_app_purchase.dart';

const monthlyPremiumProductId = 'monthly_premium';
const yearlyPremiumProductId = 'yearly_premium';
const musicPremiumProductId = 'music_premium';
const premiumProductIds = <String>{
  monthlyPremiumProductId,
  yearlyPremiumProductId,
  musicPremiumProductId,
};

enum SubscriptionPlan { monthly, yearly, musicPremium }

extension SubscriptionPlanStoreId on SubscriptionPlan {
  String get productId => switch (this) {
    SubscriptionPlan.monthly => monthlyPremiumProductId,
    SubscriptionPlan.yearly => yearlyPremiumProductId,
    SubscriptionPlan.musicPremium => musicPremiumProductId,
  };
}

enum PremiumFeature {
  adFreeExperience,
  fasterProcessing,
  priorityFeatures,
  futurePremiumTools,
  earlyAccess,
  musicRemoval,
}

class PremiumEntitlement {
  const PremiumEntitlement({
    required this.isActive,
    this.productId,
    this.purchaseId,
    this.verifiedAt,
    Set<PremiumFeature>? features,
  }) : features = features ?? const {};

  const PremiumEntitlement.inactive()
    : isActive = false,
      productId = null,
      purchaseId = null,
      verifiedAt = null,
      features = const {};

  final bool isActive;
  final String? productId;
  final String? purchaseId;
  final DateTime? verifiedAt;
  final Set<PremiumFeature> features;

  bool allows(PremiumFeature feature) => isActive && features.contains(feature);
}

class SubscriptionProduct {
  const SubscriptionProduct({required this.plan, required this.details});

  final SubscriptionPlan plan;
  final ProductDetails details;

  String get id => details.id;
  String get title => details.title;
  String get description => details.description;
  String get localizedPrice => details.price;
}
