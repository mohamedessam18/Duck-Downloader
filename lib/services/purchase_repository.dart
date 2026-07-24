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

  PremiumEntitlement readEntitlement() {
    final active = _box.get(_activeKey, defaultValue: false) as bool;
    if (!active) return const PremiumEntitlement.inactive();
    final productId = _box.get(_productIdKey) as String?;
    if (productId == null || !premiumProductIds.contains(productId)) {
      return const PremiumEntitlement.inactive();
    }
    final verifiedAtValue = _box.get(_verifiedAtKey) as String?;
    return PremiumEntitlement(
      isActive: true,
      productId: productId,
      purchaseId: _box.get(_purchaseIdKey) as String?,
      verifiedAt: verifiedAtValue == null
          ? null
          : DateTime.tryParse(verifiedAtValue),
      features: _featuresFor(productId),
    );
  }

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

  Set<PremiumFeature> _featuresFor(String productId) {
    if (!premiumProductIds.contains(productId)) return const {};
    return const {
      PremiumFeature.adFreeExperience,
      PremiumFeature.fasterProcessing,
      PremiumFeature.priorityFeatures,
      PremiumFeature.futurePremiumTools,
      PremiumFeature.earlyAccess,
    };
  }
}
