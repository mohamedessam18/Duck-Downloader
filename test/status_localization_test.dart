import 'package:duck_downloader/l10n/app_localizations.dart';
import 'package:duck_downloader/state/duck_status.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every status key the controller can set.
///
/// Hardcoded rather than scraped so that adding a key without translating it
/// is a failing test rather than a silent English string in an Arabic app.
const _statusKeys = <String>[
  'statusSignInRequired', 'statusSignedInRetrying', 'accountsCleared',
  'trashRestored', 'trashRestoreFailed',
  'statusTapDuck',
  'statusChooseImages', 'statusVaultIndexRebuilt', 'statusUnlockVaultFirst',
  'statusUnlockVaultBeforeMove', 'statusFileNotLocal', 'statusMovedToVault',
  'statusRestoredFromVault', 'statusConvertingToAudio',
  'statusConversionComplete', 'statusCreatingGif', 'statusGifCreated',
  'statusPrivateCannotShare', 'statusPlaylistDeleted', 'statusAddedToPlaylist',
  'statusRemovedFromPlaylist', 'statusChooseVideos', 'statusExtractingPlaylist',
  'statusFetchingYouTube', 'statusChooseVideoOrAudio',
  'statusTapDownloadForImage', 'statusStillBusy', 'statusCheckingLink',
  'statusDownloading', 'statusConvertingToM4a', 'statusPreparingRingtone',
  'statusTrimmingAudio', 'statusSettingRingtone', 'statusRingtoneSet',
  'statusPausing', 'statusDownloadPaused', 'statusNoFileUrl',
  'statusServerClosed', 'statusAutoDownloading', 'statusTrimmingFile', 'statusTrimComplete',
  'statusTooManyAttempts', 'statusVaultIndexRebuildFailed',
  'statusMoveToVaultFailed', 'statusVaultOpenFailed', 'statusPlaylistCreated',
  'statusYouTubeFailed', 'statusPlayFailed', 'statusGenericError', 'statusQueuedImages',
  'statusQueuedDownloads', 'statusQueuedImagesPartial',
  'statusQueuedDownloadsPartial', 'statusQueueFailedImages',
  'statusQueueFailedDownloads', 'statusAutoSaveOn', 'statusAutoSaveOff',
  'statusChooseAudioFormat', 'statusCrashReportsOn', 'statusCrashReportsOff',
  'statusBackendOutdated', 'statusComplete', 'statusCompleteSavedPictures',
  'statusCompleteSavedGallery', 'statusCompleteSaveFailed',
  'statusSavingGallery', 'statusSavingAudio', 'statusSavingImage',
  'statusSavedGallery', 'statusSavedAudio', 'statusSavedImage',
  'errorAdultBlocked', 'statusAdultCheckUnavailable', 'errorYouTubeBlocking',
  'errorExtractFailed', 'errorLoginRequired', 'errorUnsupportedLink',
  'errorConnection', 'errorDownloadFailed',
];

void main() {
  final english = AppLocalizations(const Locale('en'));
  final arabic = AppLocalizations(const Locale('ar'));

  test('every status key has English and Arabic text', () {
    final missingEnglish = <String>[];
    final missingArabic = <String>[];

    for (final key in _statusKeys) {
      // `translate` returns the key itself when it has no entry, and falls
      // back to English when only Arabic is missing — so comparing against
      // both is what actually catches an untranslated string.
      if (english.translate(key) == key) missingEnglish.add(key);
      final ar = arabic.translate(key);
      if (ar == key || ar == english.translate(key)) missingArabic.add(key);
    }

    expect(missingEnglish, isEmpty, reason: 'no English text');
    expect(missingArabic, isEmpty, reason: 'no Arabic text');
  });

  test('Arabic status text contains Arabic script', () {
    final arabicLetters = RegExp(r'[؀-ۿ]');
    for (final key in _statusKeys) {
      expect(
        arabicLetters.hasMatch(arabic.translate(key)),
        isTrue,
        reason: '$key has no Arabic letters in it',
      );
    }
  });

  test('placeholders survive into both languages', () {
    // A status that loses its {error} slot in translation renders a sentence
    // with the reason silently missing.
    const parameterised = {
      'statusTooManyAttempts': '{seconds}',
      'statusVaultIndexRebuildFailed': '{error}',
      'statusPlaylistCreated': '{name}',
      'statusQueuedImages': '{count}',
      'statusQueuedDownloadsPartial': '{failed}',
      'statusQueueFailedImages': '{failed}',
    };
    parameterised.forEach((key, placeholder) {
      expect(english.translate(key), contains(placeholder));
      expect(arabic.translate(key), contains(placeholder));
    });
  });

  test('DuckStatus fills placeholders and keeps literals alone', () {
    const status = DuckStatus.key(
      'statusTooManyAttempts',
      args: {'seconds': '30'},
    );
    expect(status.resolve(english), contains('30'));
    expect(status.resolve(arabic), contains('30'));
    expect(status.resolve(arabic), isNot(contains('{seconds}')));

    // Backend text has nothing to translate and must pass through untouched.
    const raw = DuckStatus.literal('Video unavailable in your region');
    expect(raw.resolve(arabic), 'Video unavailable in your region');
  });
}
