import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

import 'premium_entitlement.dart';
import './crash_reporting_service.dart';

class SubscriptionService {
  SubscriptionService({InAppPurchase? inAppPurchase})
    : _providedIap = inAppPurchase;

  final InAppPurchase? _providedIap;

  InAppPurchase get _iap => _providedIap ?? InAppPurchase.instance;
  Stream<List<PurchaseDetails>> get purchaseUpdates => _iap.purchaseStream;

  Future<bool> isAvailable() => _iap.isAvailable();

  Future<List<SubscriptionProduct>> loadProducts() async {
    final products = <SubscriptionProduct>[];
    try {
      final response = await _iap.queryProductDetails(premiumProductIds);
      if (response.error == null) {
        for (final details in response.productDetails) {
          final plan = _planFor(details.id);
          if (plan != null) {
            products.add(SubscriptionProduct(plan: plan, details: details));
          }
        }
      }
    } catch (error, stackTrace) {
      // An empty plan list looks identical to "no products configured", so a
      // store query that throws has to be reported or the paywall just looks
      // broken with no explanation.
      reportError(error, stackTrace, reason: 'iap-query-products');
    }

    products.sort((a, b) => a.plan.index.compareTo(b.plan.index));
    return products;
  }

  Future<void> buy(SubscriptionProduct product) {
    final purchaseParam = PurchaseParam(productDetails: product.details);
    return _iap.buyNonConsumable(purchaseParam: purchaseParam);
  }

  Future<void> restorePurchases() => _iap.restorePurchases();

  Future<void> completePurchase(PurchaseDetails purchase) {
    return _iap.completePurchase(purchase);
  }

  SubscriptionPlan? _planFor(String productId) {
    for (final plan in SubscriptionPlan.values) {
      if (plan.productId == productId) return plan;
    }
    return null;
  }
}
