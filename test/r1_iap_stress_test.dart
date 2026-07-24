import 'dart:async';

import 'package:duck_downloader/services/premium_entitlement.dart';
import 'package:duck_downloader/services/premium_manager.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:duck_downloader/services/subscription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

class FakePurchaseDetails extends PurchaseDetails {
  FakePurchaseDetails({
    required String productID,
    required PurchaseStatus status,
    String? purchaseID,
    bool pendingCompletePurchase = true,
  }) : super(
         productID: productID,
         purchaseID: purchaseID ?? 'purchase_$productID',
         transactionDate: DateTime.now().millisecondsSinceEpoch.toString(),
         status: status,
         verificationData: PurchaseVerificationData(
           localVerificationData: 'local_data',
           serverVerificationData: 'server_data',
           source: 'fake',
         ),
       ) {
    this.pendingCompletePurchase = pendingCompletePurchase;
  }
}

class TestSubscriptionService implements SubscriptionService {
  final StreamController<List<PurchaseDetails>> controller =
      StreamController<List<PurchaseDetails>>.broadcast();

  final List<PurchaseDetails> completedPurchases = [];
  bool completePurchaseShouldFail = false;

  @override
  Stream<List<PurchaseDetails>> get purchaseUpdates => controller.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<SubscriptionProduct>> loadProducts() async => [];

  @override
  Future<void> buy(SubscriptionProduct product) async {}

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    if (completePurchaseShouldFail) {
      throw Exception('completePurchase store error');
    }
    completedPurchases.add(purchase);
  }
}

class TestPurchaseRepository implements PurchaseRepository {
  bool shouldThrowOnVerify = false;
  int verifyDelayMs = 0;
  final List<String> verifiedProductIds = [];
  PremiumEntitlement currentEntitlement = const PremiumEntitlement.inactive();

  @override
  PremiumEntitlement readEntitlement() => currentEntitlement;

  @override
  Future<PremiumEntitlement> verifyAndSave(PurchaseDetails purchase) async {
    if (verifyDelayMs > 0) {
      await Future.delayed(Duration(milliseconds: verifyDelayMs));
    }
    if (shouldThrowOnVerify) {
      throw Exception('Receipt validation failed: invalid signature');
    }
    verifiedProductIds.add(purchase.productID);
    currentEntitlement = PremiumEntitlement(
      isActive: true,
      productId: purchase.productID,
      purchaseId: purchase.purchaseID,
      verifiedAt: DateTime.now().toUtc(),
      features: const {PremiumFeature.adFreeExperience},
    );
    return currentEntitlement;
  }

  @override
  Future<void> clearEntitlement() async {
    currentEntitlement = const PremiumEntitlement.inactive();
  }
}

void main() {
  group('R1 In-App Purchase Stress Tests', () {
    late TestSubscriptionService subService;
    late TestPurchaseRepository repo;
    late PremiumManager manager;

    setUp(() {
      subService = TestSubscriptionService();
      repo = TestPurchaseRepository();
      manager = PremiumManager(subscriptions: subService, purchases: repo);
    });

    tearDown(() {
      manager.dispose();
      subService.controller.close();
    });

    test('Empirical Verification: completePurchase is NOT called when verifyAndSave throws an exception', () async {
      await manager.initialize();

      repo.shouldThrowOnVerify = true;

      final purchase = FakePurchaseDetails(
        productID: SubscriptionPlan.yearly.productId,
        status: PurchaseStatus.purchased,
        pendingCompletePurchase: true,
      );

      subService.controller.add([purchase]);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(subService.completedPurchases, isEmpty,
          reason: 'completePurchase must not be called when verifyAndSave throws an exception');

      expect(manager.isPremium, isFalse,
          reason: 'Entitlement must remain inactive when receipt verification fails');
      expect(manager.errorMessage, 'Receipt validation failed: invalid signature');
    });

    test('Empirical Verification: completePurchase IS called when verifyAndSave succeeds', () async {
      await manager.initialize();

      repo.shouldThrowOnVerify = false;

      final purchase = FakePurchaseDetails(
        productID: SubscriptionPlan.yearly.productId,
        status: PurchaseStatus.purchased,
        pendingCompletePurchase: true,
      );

      subService.controller.add([purchase]);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(subService.completedPurchases, hasLength(1));
      expect(subService.completedPurchases.first.productID, SubscriptionPlan.yearly.productId);
      expect(manager.isPremium, isTrue);
      expect(manager.errorMessage, isNull);
    });

    test('Empirical Stress Test: Rapid consecutive purchase stream events process sequentially in FIFO order without race conditions', () async {
      await manager.initialize();

      repo.shouldThrowOnVerify = false;
      repo.verifyDelayMs = 20;

      final p1 = FakePurchaseDetails(productID: SubscriptionPlan.monthly.productId, status: PurchaseStatus.purchased);
      final p2 = FakePurchaseDetails(productID: SubscriptionPlan.yearly.productId, status: PurchaseStatus.purchased);
      final p3 = FakePurchaseDetails(productID: SubscriptionPlan.monthly.productId, status: PurchaseStatus.purchased);
      final p4 = FakePurchaseDetails(productID: SubscriptionPlan.yearly.productId, status: PurchaseStatus.purchased);
      final p5 = FakePurchaseDetails(productID: SubscriptionPlan.monthly.productId, status: PurchaseStatus.purchased);

      subService.controller.add([p1]);
      subService.controller.add([p2]);
      subService.controller.add([p3]);
      subService.controller.add([p4]);
      subService.controller.add([p5]);

      await Future.delayed(const Duration(milliseconds: 250));

      expect(repo.verifiedProductIds, [
        SubscriptionPlan.monthly.productId,
        SubscriptionPlan.yearly.productId,
        SubscriptionPlan.monthly.productId,
        SubscriptionPlan.yearly.productId,
        SubscriptionPlan.monthly.productId,
      ], reason: 'Rapid stream events must be processed in strict FIFO order without race conditions or re-ordering');

      expect(subService.completedPurchases, hasLength(5));
      expect(subService.completedPurchases.map((p) => p.productID).toList(), repo.verifiedProductIds);
    });

    test('Empirical Verification: Empty purchase batch resets purchasePending state', () async {
      await manager.initialize();
      manager.purchasePending = true;

      subService.controller.add([]);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(manager.purchasePending, isFalse);
      expect(manager.statusMessage, 'No active purchases found to restore.');
    });
  });
}
