import 'package:hive/hive.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'premium_entitlement.dart';

class PurchaseRepository {
  PurchaseRepository(this._box);

  final Box _box;

  static const _activeKey = 'subscriptionActive';
  static const _productIdKey = 'subscriptionProductId';
  static const _purchaseIdKey = 'subscriptionPurchaseId';
  static const _verifiedAtKey = 'subscriptionVerifiedAt';

  /// How long a stored *subscription* is trusted without the store confirming it.
  ///
  /// Does not apply to the lifetime product, which cannot lapse. A
  /// subscription is not a purchase: it lapses, it gets cancelled, it fails
  /// to renew. Nothing here can see any of that happen, so a flag written once
  /// and never questioned grants premium forever. The store is asked again on
  /// every launch, and this is how long the last answer stands while that is
  /// in flight or impossible.
  ///
  /// Long enough to be generous to someone who paid and then spent a week
  /// somewhere without signal. Short enough that a lapsed subscription does
  /// not outlive it by much.
  static const graceWindow = Duration(days: 7);

  PremiumEntitlement readEntitlement() {
    final value = _box.get(_activeKey);
    final active = value is bool ? value : false;
    if (!active) return const PremiumEntitlement.inactive();
    final productId = _box.get(_productIdKey) as String?;
    if (productId == null || !premiumProductIds.contains(productId)) {
      return const PremiumEntitlement.inactive();
    }

    final verifiedAtValue = _box.get(_verifiedAtKey) as String?;
    final verifiedAt = verifiedAtValue == null
        ? null
        : DateTime.tryParse(verifiedAtValue);

    // No timestamp at all means the record predates this check, or was written
    // by something other than a real purchase. Neither is worth trusting.
    if (verifiedAt == null) return const PremiumEntitlement.inactive();

    // A timestamp in the future is not a clock that drifted; it is a clock
    // that was moved, which is exactly how you would try to hold a grace
    // window open indefinitely. This one applies to every product: nothing
    // legitimate is verified tomorrow.
    final now = DateTime.now().toUtc();
    if (verifiedAt.isAfter(now.add(const Duration(hours: 12)))) {
      return const PremiumEntitlement.inactive();
    }

    // The grace window only makes sense for something that can lapse.
    //
    // A subscription is re-checked because it renews, gets cancelled, or fails
    // to charge, and age is the only local signal any of that happened. A
    // lifetime purchase does none of those things: it was bought once and is
    // owned. Ageing it out would take away, after a week without signal,
    // something the user paid for precisely so they would never think about it
    // again.
    if (isRecurringProduct(productId) &&
        now.difference(verifiedAt) > graceWindow) {
      return const PremiumEntitlement.inactive();
    }

    return PremiumEntitlement(
      isActive: true,
      productId: productId,
      purchaseId: _box.get(_purchaseIdKey) as String?,
      verifiedAt: verifiedAt,
      features: _featuresFor(productId),
    );
  }

  /// Records a purchase the store has reported as active.
  ///
  /// The checks below are shape checks, not proof. Nothing here contacts
  /// Google: `serverVerificationData` is carried through untouched and only
  /// tested for being non-empty, so a forged PurchaseDetails would pass. The
  /// only thing that can actually verify a subscription is the Play Developer
  /// API, called from a server holding a service-account key. That key cannot
  /// ship inside the app, which is why this cannot be fixed on the client.
  ///
  /// What that leaves is a client that is honest with honest users and does
  /// not pretend to be more. The realistic loss is a rooted device editing the
  /// Hive box directly, which no amount of client-side code prevents.
  ///
  /// The backend already exists. Wiring `serverVerificationData` through it
  /// and having it answer active/inactive is the fix, and this comment stays
  /// until it does.
  Future<PremiumEntitlement> verifyAndSave(PurchaseDetails purchase) async {
    if (!premiumProductIds.contains(purchase.productID)) {
      throw StateError('Unknown subscription product: ${purchase.productID}.');
    }
    if (purchase.status != PurchaseStatus.purchased &&
        purchase.status != PurchaseStatus.restored) {
      throw StateError('Purchase is not active.');
    }
    if (purchase.verificationData.serverVerificationData.trim().isEmpty) {
      throw StateError('The store did not provide verification data.');
    }

    final entitlement = PremiumEntitlement(
      isActive: true,
      productId: purchase.productID,
      purchaseId: purchase.purchaseID,
      verifiedAt: DateTime.now().toUtc(),
      features: _featuresFor(purchase.productID),
    );
    await _box.put(_activeKey, true);
    await _box.put(_productIdKey, entitlement.productId);
    await _box.put(_purchaseIdKey, entitlement.purchaseId);
    await _box.put(_verifiedAtKey, entitlement.verifiedAt!.toIso8601String());
    return entitlement;
  }

  Future<void> clearEntitlement() async {
    await _box.put(_activeKey, false);
    await _box.delete(_productIdKey);
    await _box.delete(_purchaseIdKey);
    await _box.delete(_verifiedAtKey);
  }

  /// What a given product actually unlocks.
  ///
  /// Studio is a superset of Premium rather than a separate list, so a feature
  /// added to Premium later cannot be accidentally missing from the tier that
  /// costs more.
  Set<PremiumFeature> _featuresFor(String productId) {
    if (!premiumProductIds.contains(productId)) return const {};
    const premium = {
      PremiumFeature.adFreeExperience,
      PremiumFeature.fasterProcessing,
    };
    if (tierFor(productId) == PremiumTier.studio) {
      return const {...premium, PremiumFeature.musicRemoval};
    }
    return premium;
  }
}
