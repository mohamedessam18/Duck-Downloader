import 'package:in_app_purchase/in_app_purchase.dart';

const monthlyPremiumProductId = 'duck_pro_monthly';
const yearlyPremiumProductId = 'duck_pro_yearly';

/// Bought once, kept forever.
///
/// A one-time product in Play, not a subscription, which is the distinction
/// the rest of this file exists to keep straight. Everything about renewal,
/// expiry and grace windows applies to the two above and to none of this one.
const lifetimePremiumProductId = 'duck_pro_lifetime';

/// Studio: everything Premium has, plus music removal.
///
/// A higher tier rather than a parallel subscription, because someone who
/// wants music removal almost always wants an ad-free app too. Two separate
/// subscriptions would charge them twice for the overlap; a tier means Play
/// bills an existing Premium subscriber only the difference when they upgrade.
///
/// No lifetime plan here on purpose. Music removal costs GPU time on every
/// use, so a one-off payment for unlimited future separations is a bill with
/// no ceiling.
const monthlyStudioProductId = 'duck_studio_monthly';
const yearlyStudioProductId = 'duck_studio_yearly';

/// The products that grant music removal.
const studioProductIds = <String>{
  monthlyStudioProductId,
  yearlyStudioProductId,
};

/// Everything that renews, and so everything that can lapse.
const subscriptionProductIds = <String>{
  monthlyPremiumProductId,
  yearlyPremiumProductId,
  ...studioProductIds,
};

/// Everything the store is asked about, and everything that grants premium.
const premiumProductIds = <String>{
  ...subscriptionProductIds,
  lifetimePremiumProductId,
};

/// True when this product renews and can therefore stop being valid.
bool isRecurringProduct(String productId) =>
    subscriptionProductIds.contains(productId);

/// Which tier a product belongs to.
enum PremiumTier { premium, studio }

PremiumTier tierFor(String productId) =>
    studioProductIds.contains(productId) ? PremiumTier.studio : PremiumTier.premium;

enum SubscriptionPlan { monthly, yearly, lifetime, studioMonthly, studioYearly }

extension SubscriptionPlanStoreId on SubscriptionPlan {
  String get productId => switch (this) {
    SubscriptionPlan.monthly => monthlyPremiumProductId,
    SubscriptionPlan.yearly => yearlyPremiumProductId,
    SubscriptionPlan.lifetime => lifetimePremiumProductId,
    SubscriptionPlan.studioMonthly => monthlyStudioProductId,
    SubscriptionPlan.studioYearly => yearlyStudioProductId,
  };

  PremiumTier get tier => tierFor(productId);
}

/// What paying actually buys.
///
/// Only what the app enforces belongs here. This list used to carry
/// `priorityFeatures`, `futurePremiumTools` and `earlyAccess` as well: every
/// one of them was written into the entitlement on purchase and then never
/// read by anything.
enum PremiumFeature {
  /// No banners, and no interstitial before a download starts.
  adFreeExperience,

  /// A higher ceiling on downloads running at once.
  ///
  /// This is what makes "Faster Downloads" on the paywall a true statement.
  /// It was granted and never read for as long as it existed, so a paying
  /// user's downloads ran at exactly the speed a free user's did.
  fasterProcessing,

  /// Separating the vocals out of a track without watching ads for it.
  ///
  /// Studio only. A free user still gets the feature — they pay for each run
  /// with rewarded ads and are held to a shorter file, because every run costs
  /// real GPU time and two ads in a low-eCPM market do not cover a long one.
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

  /// Already formatted for the user's country by the store — never build a
  /// price string by hand, the currency and its placement are not ours.
  String get localizedPrice => details.price;

  /// The same amount as a number, for comparing plans against each other.
  ///
  /// The only honest way to say what the yearly plan saves: work it out from
  /// what the store is actually charging in this country, rather than printing
  /// a percentage someone typed in once and that no longer matches.
  double get rawPrice => details.rawPrice;

  PremiumTier get tier => plan.tier;
}
