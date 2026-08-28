import 'package:duck_downloader/services/premium_entitlement.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive_test/hive_test.dart';

/// A stored entitlement decides who pays and who does not, so the rules around
/// it are worth pinning down: a flag alone must not buy premium forever, and a
/// user who paid must not be cut off the moment they lose signal.
void main() {
  late Box box;
  late PurchaseRepository repo;

  setUp(() async {
    await setUpTestHive();
    box = await Hive.openBox('premium-test');
    repo = PurchaseRepository(box);
  });

  tearDown(() async => tearDownTestHive());

  Future<void> store({
    required bool active,
    String productId = monthlyPremiumProductId,
    DateTime? verifiedAt,
  }) async {
    await box.put('subscriptionActive', active);
    await box.put('subscriptionProductId', productId);
    await box.put('subscriptionPurchaseId', 'purchase-1');
    if (verifiedAt != null) {
      await box.put('subscriptionVerifiedAt', verifiedAt.toIso8601String());
    }
  }

  final now = DateTime.now().toUtc();

  test('a fresh verification is premium', () async {
    await store(active: true, verifiedAt: now.subtract(const Duration(hours: 2)));
    expect(repo.readEntitlement().isActive, isTrue);
  });

  test('stays premium through the grace window', () async {
    // Six days offline is exactly what the window is for.
    await store(active: true, verifiedAt: now.subtract(const Duration(days: 6)));
    expect(repo.readEntitlement().isActive, isTrue);
  });

  test('lapses once the grace window has passed', () async {
    // Nothing revokes a subscription locally, so age is the only signal that
    // one may have ended.
    await store(active: true, verifiedAt: now.subtract(const Duration(days: 8)));
    expect(repo.readEntitlement().isActive, isFalse);
  });

  test('a flag with no timestamp buys nothing', () async {
    // The shape a hand-edited box would have: active set, nothing else.
    await box.put('subscriptionActive', true);
    await box.put('subscriptionProductId', monthlyPremiumProductId);
    expect(repo.readEntitlement().isActive, isFalse);
  });

  test('a future timestamp is rejected rather than trusted', () async {
    // Winding the clock forward would otherwise hold the window open for good.
    await store(active: true, verifiedAt: now.add(const Duration(days: 30)));
    expect(repo.readEntitlement().isActive, isFalse);
  });

  test('a small forward clock skew is tolerated', () async {
    // Real devices drift, and a couple of hours must not cost a paying user
    // their subscription.
    await store(active: true, verifiedAt: now.add(const Duration(hours: 3)));
    expect(repo.readEntitlement().isActive, isTrue);
  });

  test('an unknown product buys nothing', () async {
    await store(
      active: true,
      productId: 'duck_pro_lifetime_free',
      verifiedAt: now,
    );
    expect(repo.readEntitlement().isActive, isFalse);
  });

  test('inactive stays inactive however fresh the timestamp', () async {
    await store(active: false, verifiedAt: now);
    expect(repo.readEntitlement().isActive, isFalse);
  });

  test('a lifetime purchase never ages out', () async {
    // The grace window exists because a subscription can lapse. A one-time
    // purchase cannot, so a user who paid once and then spent a year offline
    // must still have what they bought.
    await store(
      active: true,
      productId: lifetimePremiumProductId,
      verifiedAt: now.subtract(const Duration(days: 400)),
    );
    expect(repo.readEntitlement().isActive, isTrue);
  });

  test('a lifetime purchase still rejects a moved clock', () async {
    // Exempt from expiry is not exempt from sanity.
    await store(
      active: true,
      productId: lifetimePremiumProductId,
      verifiedAt: now.add(const Duration(days: 30)),
    );
    expect(repo.readEntitlement().isActive, isFalse);
  });

  test('subscriptions still lapse while lifetime does not', () async {
    final stale = now.subtract(const Duration(days: 30));

    await store(active: true, productId: monthlyPremiumProductId, verifiedAt: stale);
    expect(repo.readEntitlement().isActive, isFalse, reason: 'monthly lapses');

    await store(active: true, productId: lifetimePremiumProductId, verifiedAt: stale);
    expect(repo.readEntitlement().isActive, isTrue, reason: 'lifetime does not');
  });

  test('clearing removes every trace', () async {
    await store(active: true, verifiedAt: now);
    await repo.clearEntitlement();
    final entitlement = repo.readEntitlement();
    expect(entitlement.isActive, isFalse);
    expect(entitlement.productId, isNull);
  });
}
