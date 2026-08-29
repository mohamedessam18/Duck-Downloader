import 'package:duck_downloader/l10n/app_localizations.dart';
import 'package:duck_downloader/services/premium_entitlement.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every string the paywall renders.
const _paywallKeys = <String>[
  'payTitleDuckPremium', 'payTitleDuckStudio', 'badgePlans',
  'paySubtitleFree', 'paySubtitleActive',
  'payTierPremium', 'payTierStudio',
  'payBenefitAdFree', 'payBenefitFaster', 'payBenefitMusic',
  'payPlanMonthly', 'payPlanYearly', 'payPlanLifetime', 'payPlanLifetimeNote',
  'paySave', 'payCtaSubscribe', 'payCtaUpgrade', 'payCtaBuy',
  'payCurrentPlan', 'payOwnedEverything', 'payRestore', 'payNoProducts',
  'payStudioIncludes',
];

void main() {
  group('plans and tiers line up with the store', () {
    test('every plan maps to a distinct product id', () {
      final ids = SubscriptionPlan.values.map((p) => p.productId).toList();
      expect(ids.toSet().length, ids.length, reason: 'two plans share an id');
    });

    test('every plan the sheet offers is one the store is asked about', () {
      // A plan missing from premiumProductIds is queried by nobody, comes back
      // null, and silently disappears from the sheet.
      for (final plan in SubscriptionPlan.values) {
        expect(
          premiumProductIds.contains(plan.productId),
          isTrue,
          reason: '${plan.name} is not in premiumProductIds',
        );
      }
    });

    test('plans land in the tier their id belongs to', () {
      expect(SubscriptionPlan.monthly.tier, PremiumTier.premium);
      expect(SubscriptionPlan.yearly.tier, PremiumTier.premium);
      expect(SubscriptionPlan.lifetime.tier, PremiumTier.premium);
      expect(SubscriptionPlan.studioMonthly.tier, PremiumTier.studio);
      expect(SubscriptionPlan.studioYearly.tier, PremiumTier.studio);
    });

    test('only Studio plans grant music removal', () {
      for (final plan in SubscriptionPlan.values) {
        expect(
          studioProductIds.contains(plan.productId),
          plan.tier == PremiumTier.studio,
          reason: '${plan.name} is on the wrong side of the tier split',
        );
      }
    });

    test('Studio has no lifetime plan', () {
      // Every run costs GPU time, so a one-off payment for unlimited future
      // separations is a bill with no ceiling.
      final studioPlans = SubscriptionPlan.values
          .where((p) => p.tier == PremiumTier.studio);
      expect(
        studioPlans.every(isRecurringProduct2),
        isTrue,
        reason: 'a Studio plan that never renews would be sold once and used '
            'forever',
      );
    });

    test('lifetime never ages out, subscriptions do', () {
      expect(isRecurringProduct(lifetimePremiumProductId), isFalse);
      for (final id in studioProductIds) {
        expect(isRecurringProduct(id), isTrue);
      }
      expect(isRecurringProduct(monthlyPremiumProductId), isTrue);
      expect(isRecurringProduct(yearlyPremiumProductId), isTrue);
    });
  });

  group('the paywall speaks both languages', () {
    final english = AppLocalizations(const Locale('en'));
    final arabic = AppLocalizations(const Locale('ar'));

    /// Names, not sentences. A product is called the same thing in every
    /// language, and "translating" a brand is how you end up with two names
    /// for one thing in the store and in the app.
    const brandNames = {
      'payTitleDuckPremium',
      'payTitleDuckStudio',
      'badgePlans',
      'payTierPremium',
      'payTierStudio',
    };

    test('every key has text in both', () {
      for (final key in _paywallKeys) {
        expect(english.translate(key), isNot(key), reason: '$key: no English');
        expect(arabic.translate(key), isNot(key), reason: '$key: no Arabic');
      }
    });

    test('everything that is prose is actually translated', () {
      for (final key in _paywallKeys.where((k) => !brandNames.contains(k))) {
        expect(
          arabic.translate(key),
          isNot(english.translate(key)),
          reason: '$key falls back to English',
        );
      }
    });

    test('product names stay the same in both languages', () {
      for (final key in brandNames) {
        expect(arabic.translate(key), english.translate(key), reason: key);
      }
    });

    test('the placeholders the sheet substitutes survive translation', () {
      // A benefit line that loses {premium} prints "downloads at once instead
      // of" with the numbers missing.
      for (final l10n in [english, arabic]) {
        expect(l10n.translate('payBenefitFaster'), contains('{premium}'));
        expect(l10n.translate('payBenefitFaster'), contains('{free}'));
        expect(l10n.translate('paySave'), contains('{percent}'));
      }
    });
  });
}

/// `isRecurringProduct` over a plan rather than an id.
bool isRecurringProduct2(SubscriptionPlan plan) =>
    isRecurringProduct(plan.productId);
