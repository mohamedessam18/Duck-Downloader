import 'package:in_app_purchase/in_app_purchase.dart';

const monthlyPremiumProductId = 'duck_pro_monthly';
const yearlyPremiumProductId = 'duck_pro_yearly';
const premiumProductIds = <String>{
  monthlyPremiumProductId,
  yearlyPremiumProductId,
};

enum SubscriptionPlan { monthly, yearly }

extension SubscriptionPlanStoreId on SubscriptionPlan {
  String get productId => switch (this) {
    SubscriptionPlan.monthly => monthlyPremiumProductId,
    SubscriptionPlan.yearly => yearlyPremiumProductId,
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
