import 'package:duck_downloader/services/ad_service.dart';
import 'package:duck_downloader/services/music_removal_service.dart';
import 'package:duck_downloader/services/premium_entitlement.dart';
import 'package:duck_downloader/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// An ad service that answers without touching the SDK.
class FakeAds implements AdService {
  FakeAds({this.ready = true, this.earns = true});

  bool ready;
  bool earns;
  int shown = 0;
  int preloads = 0;

  @override
  bool get isRewardedReady => ready;

  @override
  void preloadRewarded() => preloads++;

  @override
  Future<bool> showRewardedAd() async {
    shown++;
    return earns;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PremiumEntitlement _entitlement(Set<PremiumFeature> features) {
  return PremiumEntitlement(
    isActive: features.isNotEmpty,
    productId: features.contains(PremiumFeature.musicRemoval)
        ? monthlyStudioProductId
        : monthlyPremiumProductId,
    verifiedAt: DateTime.now().toUtc(),
    features: features,
  );
}

void main() {
  group('who gets it', () {
    test('Studio grants music removal, Premium does not', () {
      final service = MusicRemovalService(ads: FakeAds());

      expect(
        service.hasStudio(_entitlement({
          PremiumFeature.adFreeExperience,
          PremiumFeature.fasterProcessing,
        })),
        isFalse,
      );
      expect(
        service.hasStudio(_entitlement({
          PremiumFeature.adFreeExperience,
          PremiumFeature.fasterProcessing,
          PremiumFeature.musicRemoval,
        })),
        isTrue,
      );
      expect(service.hasStudio(const PremiumEntitlement.inactive()), isFalse);
    });

    test('Studio is a superset — it never loses a Premium feature', () {
      // Guards the tier that costs more against quietly missing something the
      // cheaper one has.
      const studio = {
        PremiumFeature.adFreeExperience,
        PremiumFeature.fasterProcessing,
        PremiumFeature.musicRemoval,
      };
      const premium = {
        PremiumFeature.adFreeExperience,
        PremiumFeature.fasterProcessing,
      };
      expect(studio.containsAll(premium), isTrue);
    });
  });

  group('length limits', () {
    final service = MusicRemovalService(ads: FakeAds());

    test('free runs stop at five minutes, Studio at fifteen', () {
      expect(
        service.maxDurationFor(hasStudio: false),
        MusicRemovalService.freeMaxDuration,
      );
      expect(
        service.maxDurationFor(hasStudio: true),
        MusicRemovalService.studioMaxDuration,
      );

      // A ten-minute file: too long free, fine on Studio.
      const ten = Duration(minutes: 10);
      expect(
        service.checkDuration(duration: ten, hasStudio: false).block,
        MusicRemovalBlock.tooLong,
      );
      expect(
        service.checkDuration(duration: ten, hasStudio: true).isAllowed,
        isTrue,
      );
    });

    test('an unknown length is allowed through', () {
      // Plenty of sources never report one, and the worker has its own
      // ceiling — refusing here would block ordinary files for no reason.
      expect(
        service.checkDuration(duration: null, hasStudio: false).isAllowed,
        isTrue,
      );
    });

    test('the worker ceiling is mirrored, not invented', () {
      // DUCK_MAX_DURATION_SECONDS is 900 in process-worker/app/main.py.
      expect(MusicRemovalService.studioMaxDuration.inSeconds, 900);
    });
  });

  group('paying with ads', () {
    test('Studio watches nothing', () async {
      final ads = FakeAds();
      final service = MusicRemovalService(ads: ads);

      final decision = await service.collectPayment(
        entitlement: _entitlement({PremiumFeature.musicRemoval}),
      );

      expect(decision.isAllowed, isTrue);
      expect(ads.shown, 0);
    });

    test('a free run costs exactly two finished ads', () async {
      final ads = FakeAds();
      final service = MusicRemovalService(ads: ads);
      final watched = <int>[];

      final decision = await service.collectPayment(
        entitlement: const PremiumEntitlement.inactive(),
        onProgress: (n, _) => watched.add(n),
      );

      expect(decision.isAllowed, isTrue);
      expect(ads.shown, MusicRemovalService.freeRunAdCount);
      expect(watched, [1, 2]);
    });

    test('closing the first ad stops there — no partial credit', () async {
      final ads = FakeAds(earns: false);
      final service = MusicRemovalService(ads: ads);

      final decision = await service.collectPayment(
        entitlement: const PremiumEntitlement.inactive(),
      );

      expect(decision.isAllowed, isFalse);
      expect(decision.block, MusicRemovalBlock.adsNotWatched);
      // The second ad is never shown to someone who closed the first.
      expect(ads.shown, 1);
    });

    test('an empty ad inventory is a refusal, not a free pass', () async {
      final ads = FakeAds(ready: false);
      final service = MusicRemovalService(ads: ads);

      final decision = await service.collectPayment(
        entitlement: const PremiumEntitlement.inactive(),
      );

      expect(decision.isAllowed, isFalse);
      expect(decision.block, MusicRemovalBlock.adsUnavailable);
      expect(ads.shown, 0);
    });

    test('an unshowable ad is told apart from a skipped one', () {
      final service = MusicRemovalService(ads: FakeAds());
      // The two read very differently to the user: one is their doing, the
      // other is ours, and blaming them for our empty inventory is a message
      // they cannot act on.
      expect(
        service.messageKeyFor(MusicRemovalBlock.adsUnavailable, hasStudio: false),
        isNot(
          service.messageKeyFor(
            MusicRemovalBlock.adsNotWatched,
            hasStudio: false,
          ),
        ),
      );
    });
  });

  group('reading the duration the extractor sent', () {
    test('bare seconds', () {
      expect(MusicRemovalService.parseDuration('225'), const Duration(seconds: 225));
      expect(
        MusicRemovalService.parseDuration('225.5'),
        const Duration(milliseconds: 225500),
      );
    });

    test('mm:ss and hh:mm:ss', () {
      expect(
        MusicRemovalService.parseDuration('3:45'),
        const Duration(minutes: 3, seconds: 45),
      );
      expect(
        MusicRemovalService.parseDuration('1:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
    });

    test('nonsense reads as unknown rather than as zero', () {
      // Zero would be "shorter than every limit" and would wave anything
      // through.
      for (final value in [null, '', '  ', 'N/A', '0', '-5', 'a:b']) {
        expect(
          MusicRemovalService.parseDuration(value),
          isNull,
          reason: 'parsed "$value"',
        );
      }
    });
  });

  group('the copy the user reads', () {
    final english = AppLocalizations(const Locale('en'));
    final arabic = AppLocalizations(const Locale('ar'));

    const keys = [
      'musicRemovalTitle', 'musicRemovalSubtitle', 'musicRemovalNote',
      'musicRemovalWatchAds', 'musicRemovalSubscribe', 'musicRemovalAdProgress',
      'musicRemovalSuffix', 'musicRemovalQueued', 'musicRemovalNeedsSource',
      'musicRemovalTooLongFree', 'musicRemovalTooLongStudio',
      'musicRemovalAdsNotWatched', 'musicRemovalAdsUnavailable',
    ];

    test('every string exists in both languages', () {
      for (final key in keys) {
        expect(english.translate(key), isNot(key), reason: '$key: no English');
        final ar = arabic.translate(key);
        expect(ar, isNot(key), reason: '$key: no Arabic');
        expect(ar, isNot(english.translate(key)), reason: '$key: not translated');
      }
    });

    test('the numbers the sheet fills in survive translation', () {
      // A gate that says "watch  ads" or a limit with no minutes in it is
      // worse than no message at all.
      for (final l10n in [english, arabic]) {
        expect(l10n.translate('musicRemovalWatchAds'), contains('{count}'));
        expect(l10n.translate('musicRemovalNote'), contains('{minutes}'));
        expect(l10n.translate('musicRemovalTooLongFree'), contains('{minutes}'));
        expect(l10n.translate('musicRemovalAdProgress'), contains('{watched}'));
        expect(l10n.translate('musicRemovalAdProgress'), contains('{total}'));
      }
    });

    test('the two ad failures do not say the same thing', () {
      // One is the user closing an ad, the other is us having none to show.
      for (final l10n in [english, arabic]) {
        expect(
          l10n.translate('musicRemovalAdsNotWatched'),
          isNot(l10n.translate('musicRemovalAdsUnavailable')),
        );
      }
    });
  });
}
