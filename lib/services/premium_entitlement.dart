import 'package:in_app_purchase/in_app_purchase.dart';

const monthlyPremiumProductId = 'duck_pro_monthly';
const yearlyPremiumProductId = 'duck_pro_yearly';

/// Bought once, kept forever.
///
/// A one-time product in Play, not a subscription, which is the distinction
/// the rest of this file exists to keep straight. Everything about renewal,
/// expiry and grace windows applies to the two above and to none of this one.
const lifetimePremiumProductId = 'duck_pro_lifetime';

/// The two that renew, and so the two that can lapse.
const subscriptionProductIds = <String>{
  monthlyPremiumProductId,
  yearlyPremiumProductId,
};

/// Everything the store is asked about, and everything that grants premium.
const premiumProductIds = <String>{
  ...subscriptionProductIds,
  lifetimePremiumProductId,
};

/// True when this product renews and can therefore stop being valid.
bool isRecurringProduct(String productId) =>
    subscriptionProductIds.contains(productId);

enum SubscriptionPlan { monthly, yearly, lifetime }

extension SubscriptionPlanStoreId on SubscriptionPlan {
  String get productId => switch (this) {
    SubscriptionPlan.monthly => monthlyPremiumProductId,
    SubscriptionPlan.yearly => yearlyPremiumProductId,
    SubscriptionPlan.lifetime => lifetimePremiumProductId,
  };
}

/// What paying actually buys.
///
/// Only what the app enforces belongs here. This list used to carry
/// `priorityFeatures`, `futurePremiumTools`, `earlyAccess` and `musicRemoval`
/// as well: every one of them was written into the entitlement on purchase and
/// then never read by anything. `musicRemoval` was worse than unused — the one
/// getter that asked for it could never be true, because the entitlement was
/// never given it. Music removal is free for everyone and needs no flag.
enum PremiumFeature {
  /// No banners, and no interstitial before a download starts.
  adFreeExperience,

  /// A higher ceiling on downloads running at once.
  ///
  /// This is what makes "Faster Downloads" on the paywall a true statement.
  /// It was granted and never read for as long as it existed, so a paying
  /// user's downloads ran at exactly the speed a free user's did.
  fasterProcessing,
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
