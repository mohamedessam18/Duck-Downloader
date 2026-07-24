import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'premium_entitlement.dart';
import 'purchase_repository.dart';
import 'subscription_service.dart';

class PremiumManager extends ChangeNotifier {
  PremiumManager({
    required SubscriptionService subscriptions,
    required PurchaseRepository purchases,
  }) : _subscriptions = subscriptions,
       _purchases = purchases,
       entitlement = purchases.readEntitlement();

  final SubscriptionService _subscriptions;
  final PurchaseRepository _purchases;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  PremiumEntitlement entitlement;
  List<SubscriptionProduct> products = const [];
  bool storeAvailable = false;
  bool loadingProducts = false;
  bool purchasePending = false;
  String statusMessage = 'Choose a subscription plan.';
  String? errorMessage;

  bool get isPremium => entitlement.isActive;

  SubscriptionProduct? productFor(SubscriptionPlan plan) {
    for (final product in products) {
      if (product.plan == plan) return product;
    }
    return null;
  }

  bool hasFeature(PremiumFeature feature) => entitlement.allows(feature);

  Future<void> initialize() async {
    _purchaseSubscription ??= _subscriptions.purchaseUpdates.listen(
      _handlePurchaseUpdates,
      onError: (Object error) {
        errorMessage = _cleanError(error);
        purchasePending = false;
        notifyListeners();
      },
    );
    await refresh();
  }

  Future<void> refresh() async {
    loadingProducts = true;
    errorMessage = null;
    notifyListeners();
    try {
      entitlement = _purchases.readEntitlement();
      storeAvailable = await _subscriptions.isAvailable();
      if (!storeAvailable) {
        products = const [];
        statusMessage = 'Store subscriptions are not available on this device.';
        return;
      }
      products = await _subscriptions.loadProducts();
      if (products.isEmpty) {
        statusMessage =
            'Subscription products are not configured in the store yet.';
      } else if (isPremium) {
        statusMessage = 'Duck Premium is active.';
      } else {
        statusMessage = 'Choose a subscription plan.';
      }
    } catch (error) {
      errorMessage = _cleanError(error);
    } finally {
      loadingProducts = false;
      notifyListeners();
    }
  }

  Future<void> subscribe(SubscriptionPlan plan) async {
    final product = productFor(plan);
    if (product == null || purchasePending) return;
    purchasePending = true;
    errorMessage = null;
    statusMessage = 'Opening secure checkout...';
    notifyListeners();
    try {
      await _subscriptions.buy(product);
    } catch (error) {
      errorMessage = _cleanError(error);
    } finally {
      purchasePending = false;
      notifyListeners();
    }
  }

  Future<void> restorePurchases() async {
    if (purchasePending) return;
    purchasePending = true;
    errorMessage = null;
    statusMessage = 'Restoring purchases...';
    notifyListeners();
    try {
      await _subscriptions.restorePurchases();
      if (purchasePending && statusMessage == 'Restoring purchases...') {
        purchasePending = false;
        statusMessage = 'No active purchases found to restore.';
        notifyListeners();
      }
    } catch (error) {
      purchasePending = false;
      errorMessage = _cleanError(error);
      notifyListeners();
    }
  }

  final List<List<PurchaseDetails>> _purchaseUpdateQueue = [];
  bool _isProcessingPurchaseStream = false;

  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchases) async {
    _purchaseUpdateQueue.add(purchases);
    if (_isProcessingPurchaseStream) return;

    _isProcessingPurchaseStream = true;
    try {
      while (_purchaseUpdateQueue.isNotEmpty) {
        final currentBatch = _purchaseUpdateQueue.removeAt(0);
        await _processPurchaseBatch(currentBatch);
      }
    } finally {
      _isProcessingPurchaseStream = false;
    }
  }

  Future<void> _processPurchaseBatch(List<PurchaseDetails> purchases) async {
    if (purchases.isEmpty) {
      purchasePending = false;
      statusMessage = 'No active purchases found to restore.';
      notifyListeners();
      return;
    }
    bool handledAny = false;
    for (final purchase in purchases) {
      if (!premiumProductIds.contains(purchase.productID)) continue;
      handledAny = true;
      if (purchase.status == PurchaseStatus.pending) {
        purchasePending = true;
        statusMessage = 'Purchase pending...';
        notifyListeners();
        continue;
      }
      if (purchase.status == PurchaseStatus.error) {
        purchasePending = false;
        errorMessage = purchase.error?.message ?? 'Purchase failed.';
        notifyListeners();
        continue;
      }
      if (purchase.status == PurchaseStatus.canceled) {
        purchasePending = false;
        statusMessage = 'Purchase cancelled.';
        notifyListeners();
        continue;
      }
      try {
        entitlement = await _purchases.verifyAndSave(purchase);
        if (purchase.pendingCompletePurchase) {
          await _subscriptions.completePurchase(purchase);
        }
        statusMessage = purchase.status == PurchaseStatus.restored
            ? 'Duck Premium restored.'
            : 'Duck Premium is active.';
        errorMessage = null;
      } catch (error) {
        await _purchases.clearEntitlement();
        entitlement = const PremiumEntitlement.inactive();
        errorMessage = _cleanError(error);
      } finally {
        purchasePending = false;
        notifyListeners();
      }
    }
    if (!handledAny && purchasePending) {
      purchasePending = false;
      statusMessage = 'No active purchases found to restore.';
      notifyListeners();
    }
  }

  String _cleanError(Object error) {
    return error.toString().replaceFirst('Exception: ', '').trim();
  }

  @override
  void dispose() {
    _purchaseSubscription?.cancel();
    super.dispose();
  }
}
