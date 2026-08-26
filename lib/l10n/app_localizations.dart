import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    final loc = Localizations.of<AppLocalizations>(context, AppLocalizations);
    if (loc != null) return loc;
    final ambientLocale = Localizations.maybeLocaleOf(context);
    if (ambientLocale != null && ambientLocale.languageCode.startsWith('ar')) {
      return AppLocalizations(const Locale('ar'));
    }
    return AppLocalizations(ambientLocale ?? const Locale('en'));
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static final Map<String, Map<String, String>> _localizedValues = {
    'en': {
      'appName': 'Duck Downloader',
      'quickShareTitle': 'Duck Quick Download ⚡',
      'homeTab': 'HOME',
      'imagesTab': 'IMAGES',
      'videosTab': 'VIDEOS',
      'audiosTab': 'AUDIOS',
      'all': 'ALL',
      'songs': 'SONGS',
      'folders': 'FOLDERS',
      'favorites': 'FAVORITES',
      'playlists': 'PLAYLISTS',
      'searchTab': 'Browser',
      'vaultTab': 'Vault',
      'settingsTab': 'Settings',
      'searchPlaceholder': 'Paste link or search...',
      'pasteLinkAutoDetect': 'Paste Link & Auto Detect',
      'quickDownload': 'QUICK DOWNLOAD',
      'myStorage': 'MY STORAGE',
      'noDownloadsYet': 'No downloaded items yet.',
      'noImagesYet': 'No downloaded images yet.',
      'noVideosYet': 'No downloaded videos yet.',
      'noAudiosYet': 'No downloaded audios yet.',
      'noFoldersFound': 'No folders found on device.',
      'scanFolders': 'Scan Storage Folders',
      'newPlaylist': 'NEW PLAYLIST',
      'noPlaylistsYet': 'No playlists created yet.',
      'createPlaylist': 'Create Playlist',
      'playlistName': 'Playlist Name',
      'linkDetectedClipboard': 'Link Detected in Clipboard',
      'downloadLinkNow': 'Would you like to download this link now?',
      'downloadNow': 'DOWNLOAD NOW',
      'dismiss': 'DISMISS',
      'playlistDetected': 'Playlist Detected',
      'downloadSingle': 'Download Single Video',
      'downloadFullPlaylist': 'Download Full Playlist',
      'selectFormat': 'Select Download Quality',
      'videoHD': '🎥 Video HD (1080p / 720p)',
      'audioMP3': '🎵 Audio MP3 (320kbps)',
      'images': 'Images / Photos',
      'analyzingQualities': 'Analyzing available qualities... ⚡',
      'downloadingInBackground': 'Downloading in background... 🚀',
      'adultContentBlocked': 'Adult content is blocked',
      'downloadFailed': 'Download failed',
      'downloadFinished': 'Download completed',
      'copiedToClipboard': 'Link copied to clipboard',
      'enterPin': 'Enter PIN',
      'setPin': 'Set Security PIN',
      'incorrectPin': 'Incorrect PIN',
      'decoyVault': 'Decoy Vault',
      'clearCache': 'Clear Cache',
      'cacheCleared': 'Cache cleared successfully',
      'storageLocation': 'Storage Path',
      'autoDetectClipboard': 'Auto-detect Clipboard',
      'backgroundPlayback': 'Background Playback',
      'darkMode': 'Dark Mode',
      'sleepTimer': 'Sleep Timer',
      'playbackSpeed': 'Playback Speed',
      'shuffle': 'Shuffle',
      'loop': 'Loop',
      'trim': 'Trim Media',
      'delete': 'Delete',
      'cancel': 'Cancel',
      'confirm': 'Confirm',
      'save': 'Save',
      'onbSkip': 'Skip',
      'onbNext': 'Next',
      'onbStart': 'Get Started',
      'onbFeaturesTitle': 'Everything, in one tap',
      'onbFeaturesBody': 'Paste a link from YouTube, Instagram, TikTok, X, Facebook or Reddit — Duck picks the best quality and pulls it down.',
      'onbFeatureQuality': 'Pick your quality, video or audio only',
      'onbFeatureClipboard': 'Copy a link and Duck offers to grab it',
      'onbFeatureLibrary': 'Your whole media library, browsable in app',
      'onbVaultTitle': 'A vault only you can open',
      'onbVaultBody': 'Move anything private into the Vault and it is encrypted on your device with AES-256. Locked behind your PIN or fingerprint.',
      'onbVaultPoint1': 'Encrypted on device — never uploaded anywhere',
      'onbVaultPoint2': 'Hidden from the gallery and other apps',
      'onbVaultPoint3': 'Set it up any time from the Vault tab',
      'onbPermsTitle': 'Two things Duck needs',
      'onbPermsBody': 'Grant these and everything works. You can change your mind later in Settings.',
      'onbPermMediaTitle': 'Photos, video and audio',
      'onbPermMediaBody': 'To save your downloads and let you browse and edit your own files.',
      'onbPermNotifTitle': 'Notifications',
      'onbPermNotifBody': 'To show download progress and let you control playback.',
      'onbPermGrant': 'Allow',
      'onbPermGranted': 'Allowed',
      'onbPermDenied': 'Open Settings',
      'onbPermsSkipNote': 'You can skip this — Duck will ask again when it needs to.',
    },
    'ar': {
      'appName': 'Duck Downloader',
      'quickShareTitle': 'Duck Quick Download ⚡',
      'homeTab': 'الرئيسية',
      'imagesTab': 'الصور',
      'videosTab': 'الفيديوهات',
      'audiosTab': 'الصوتيات',
      'all': 'الكل',
      'songs': 'الأغاني',
      'folders': 'المجلدات',
      'favorites': 'المفضلة',
      'playlists': 'قوائم التشغيل',
      'searchTab': 'المتصفح',
      'vaultTab': 'الخزنة المشفرة',
      'settingsTab': 'الإعدادات',
      'searchPlaceholder': 'الصق الرابط أو ابحث هنا...',
      'pasteLinkAutoDetect': 'لصق الرابط والفحص التلقائي',
      'quickDownload': 'التحميل السريع',
      'myStorage': 'ملفاتي المحفوظة',
      'noDownloadsYet': 'لا توجد عناصر محملة حتى الآن.',
      'noImagesYet': 'لا توجد صور محملة حتى الآن.',
      'noVideosYet': 'لا توجد فيديوهات محملة حتى الآن.',
      'noAudiosYet': 'لا توجد ملفات صوتية محملة حتى الآن.',
      'noFoldersFound': 'لم يتم العثور على مجلدات على الجهاز.',
      'scanFolders': 'فحص مجلدات التخزين',
      'newPlaylist': 'قائمة تشغيل جديدة',
      'noPlaylistsYet': 'لم يتم إنشاء أي قائمة تشغيل بعد.',
      'createPlaylist': 'إنشاء قائمة تشغيل',
      'playlistName': 'اسم قائمة التشغيل',
      'linkDetectedClipboard': 'تم كشف رابط في الحافظة',
      'downloadLinkNow': 'هل ترغب في تحميل هذا الرابط الآن؟',
      'downloadNow': 'تحميل الآن',
      'dismiss': 'تجاهل',
      'playlistDetected': 'تم كشف قائمة تشغيل (Playlist)',
      'downloadSingle': 'تحميل الفيديو الحالي فقط',
      'downloadFullPlaylist': 'تحميل قائمة التشغيل بالكامل',
      'selectFormat': 'اختر جودة التحميل',
      'videoHD': '🎥 فيديو عالية الدقة HD (1080p / 720p)',
      'audioMP3': '🎵 صوت عالي الجودة MP3 (320kbps)',
      'images': 'الصور',
      'analyzingQualities': 'جاري تحليل الجودات المتاحة... ⚡',
      'downloadingInBackground': 'جاري التحميل في الخلفية... 🚀',
      'adultContentBlocked': 'تم حظر المحتوى المخصص للبالغين',
      'downloadFailed': 'عذراً، فشل التحميل',
      'downloadFinished': 'تم اكتمال التحميل بنجاح 🎉',
      'copiedToClipboard': 'تم نسخ الرابط إلى الحافظة',
      'enterPin': 'أدخل رمز PIN',
      'setPin': 'تعيين رمز الحماية PIN',
      'incorrectPin': 'رمز PIN غير صحيح',
      'decoyVault': 'الخزنة التمويهية (Decoy)',
      'clearCache': 'مسح التخزين المؤقت',
      'cacheCleared': 'تم مسح التخزين المؤقت بنجاح',
      'storageLocation': 'مسار حفظ الملفات',
      'autoDetectClipboard': 'الكشف التلقائي عن الحافظة',
      'backgroundPlayback': 'التشغيل في الخلفية',
      'darkMode': 'الوضع الداكن (Dark Mode)',
      'sleepTimer': 'مؤقت الإيقاف التلقائي',
      'playbackSpeed': 'سرعة التشغيل',
      'shuffle': 'التشغيل العشوائي',
      'loop': 'تكرار التشغيل',
      'trim': 'قص وتعديل الميديا',
      'delete': 'حذف',
      'cancel': 'إلغاء',
      'confirm': 'تأكيد',
      'save': 'حفظ',
      'onbSkip': 'تخطي',
      'onbNext': 'التالي',
      'onbStart': 'يلا نبدأ',
      'onbFeaturesTitle': 'كل حاجة بضغطة واحدة',
      'onbFeaturesBody': 'الصق أي لينك من يوتيوب أو إنستجرام أو تيك توك أو إكس أو فيسبوك أو ريديت — و Duck يختار أعلى جودة وينزّلها.',
      'onbFeatureQuality': 'اختار الجودة، فيديو كامل أو صوت بس',
      'onbFeatureClipboard': 'انسخ لينك و Duck يعرض عليك تحميله',
      'onbFeatureLibrary': 'مكتبة الميديا بتاعتك كلها جوّه التطبيق',
      'onbVaultTitle': 'خزنة مالهاش غير مفتاحك',
      'onbVaultBody': 'حطّ اللي عايزه يفضل خاص في الخزنة، ويتشفّر على جهازك بـ AES-256. مقفولة بالـ PIN أو ببصمتك.',
      'onbVaultPoint1': 'التشفير على جهازك — مفيش حاجة بتترفع لأي مكان',
      'onbVaultPoint2': 'مخفية عن معرض الصور وعن أي تطبيق تاني',
      'onbVaultPoint3': 'تقدر تظبّطها في أي وقت من تبويب الخزنة',
      'onbPermsTitle': 'حاجتين Duck محتاجهم',
      'onbPermsBody': 'وافق عليهم وكل حاجة هتشتغل. تقدر تغيّر رأيك بعدين من الإعدادات.',
      'onbPermMediaTitle': 'الصور والفيديو والصوت',
      'onbPermMediaBody': 'عشان نحفظ تحميلاتك ونخليك تتصفّح وتعدّل ملفاتك.',
      'onbPermNotifTitle': 'الإشعارات',
      'onbPermNotifBody': 'عشان نوريك تقدّم التحميل وتتحكم في التشغيل.',
      'onbPermGrant': 'اسمح',
      'onbPermGranted': 'تم',
      'onbPermDenied': 'افتح الإعدادات',
      'onbPermsSkipNote': 'تقدر تعدّيها — Duck هيسألك تاني لما يحتاجها.',
    },
  };

  String translate(String key) {
    final lang = locale.languageCode;
    if (_localizedValues.containsKey(lang) &&
        _localizedValues[lang]!.containsKey(key)) {
      return _localizedValues[lang]![key]!;
    }
    // Fallback to English
    return _localizedValues['en']?[key] ?? key;
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['en', 'ar'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
