/**
 * What the support assistant knows.
 *
 * Every entry here describes something the app actually does, checked against
 * the source rather than written from memory: the vault is AES-256 behind a
 * six-digit passcode because that is what VaultEncryptionService does, the
 * grace window is seven days because that is what PurchaseRepository allows.
 *
 * This is the whole reason the assistant does not use a language model. A model
 * asked about a niche app will fill gaps with plausible invention, and a
 * support bot that invents a refund policy is worse than no bot. Everything
 * below can be traced to a line of code or a real product decision, and the
 * assistant can only ever return one of these answers or admit it has none.
 */
export type Article = {
  id: string;
  question: string;
  answer: string;
  /** The same question and answer for Arabic speakers, who are most of them. */
  questionAr: string;
  answerAr: string;
  /** Extra words a person might use that the question itself does not contain. */
  keywords: string[];
  topic: "downloads" | "vault" | "premium" | "playback" | "files" | "general";
};

export const articles: Article[] = [
  // ── Downloads ─────────────────────────────────────────────────────────────
  {
    id: "supported-links",
    question: "Which links can Duck download?",
    answer:
      "Public posts from the major social platforms. Paste or copy a link and Duck reads what is available, then offers the qualities it found. Private accounts, anything behind a login, and DRM-protected or paid content are out of scope by design.",
    questionAr: "أي لينكات ينفع أحمّلها؟",
    answerAr:
      "المنشورات العامة على المنصات الكبيرة. انسخ أو الصق اللينك وDuck بيقرا اللي متاح ويعرض عليك الجودات. الحسابات الخاصة، وأي حاجة ورا تسجيل دخول، والمحتوى المدفوع أو المحمي بحقوق رقمية كلهم خارج نطاق التطبيق عن قصد.",
    keywords: ["support", "platform", "instagram", "tiktok", "facebook", "twitter", "x", "youtube", "reddit", "site", "url", "work with", "لينك", "رابط", "منصه", "انستجرام", "تيك", "فيس", "تويتر", "يوتيوب", "موقع", "بيشتغل", "يدعم"],
    topic: "downloads",
  },
  {
    id: "clipboard",
    question: "How does link detection work?",
    answer:
      "Copy a link anywhere on your phone and Duck offers to download it, without you opening the app first. You can switch this off under Settings, in the Downloads section.",
    questionAr: "كشف اللينكات بيشتغل إزاي؟",
    answerAr:
      "انسخ لينك في أي مكان على موبايلك وDuck يعرض عليك تحمّله، من غير ما تفتح التطبيق. تقدر تقفلها من الإعدادات، في قسم التحميلات.",
    keywords: ["clipboard", "copy", "detect", "automatic", "notification", "paste", "حافظه", "نسخ", "كشف", "تلقائي", "اشعار", "لصق"],
    topic: "downloads",
  },
  {
    id: "quality",
    question: "Can I choose the video quality?",
    answer:
      "Yes. After Duck reads a link it lists the qualities that link actually offers, up to the highest the source provides. For high-resolution video it downloads the video and audio separately and merges them, which is why the progress bar moves in stages.",
    questionAr: "أقدر أختار جودة الفيديو؟",
    answerAr:
      "أيوة. بعد ما Duck يقرا اللينك بيعرض الجودات اللي اللينك ده بيوفرها فعلاً، لحد أعلى حاجة موجودة. الجودات العالية بتتحمّل صوت وصورة منفصلين وبيتدمجوا، عشان كده البار بيتحرك على مراحل.",
    keywords: ["quality", "resolution", "1080", "4k", "hd", "size", "choose", "format", "جوده", "دقه", "حجم", "اختار", "صيغه"],
    topic: "downloads",
  },
  {
    id: "download-failed",
    question: "A download failed. What now?",
    answer:
      "Try the link again first: most failures are the source refusing a request that works seconds later. If it keeps failing, check the link opens in a browser without logging in. Duck cannot reach anything that needs an account.",
    questionAr: "التحميل فشل، أعمل إيه؟",
    answerAr:
      "جرب اللينك تاني الأول: أغلب حالات الفشل بتكون المصدر رفض طلب بيشتغل بعدها بثواني. لو فضل يفشل، اتأكد إن اللينك بيفتح في المتصفح من غير تسجيل دخول. Duck مش بيقدر يوصل لأي حاجة محتاجة حساب.",
    keywords: ["fail", "error", "not working", "broken", "stuck", "retry", "problem", "فشل", "خطا", "مشكله", "واقف", "مش بينزل", "بيقف"],
    topic: "downloads",
  },
  {
    id: "where-saved",
    question: "Where do my downloads go?",
    answer:
      "Into your device storage, under a Duck Downloader folder. With auto-save on, finished downloads are also copied into Photos and Music so your other apps can see them. Nothing is uploaded anywhere.",
    questionAr: "التحميلات بتروح فين؟",
    answerAr:
      "لتخزين جهازك، في مجلد Duck Downloader. ومع تفعيل الحفظ التلقائي بتتنسخ كمان في الصور والموسيقى عشان تطبيقاتك التانية تشوفها. مفيش حاجة بترفع لأي سيرفر.",
    keywords: ["where", "saved", "storage", "folder", "gallery", "location", "find", "auto-save", "فين", "اتحفظ", "مجلد", "معرض", "مكان", "الاقي"],
    topic: "files",
  },

  // ── Vault ─────────────────────────────────────────────────────────────────
  {
    id: "vault-what",
    question: "What is the Secure Vault?",
    answer:
      "A private folder inside the app. Files moved into it are encrypted on your device with AES-256 and unlocked by a six-digit passcode or your fingerprint. Names and thumbnails stay blurred until you tap the eye icon, so a glance over your shoulder shows nothing.",
    questionAr: "إيه هي الخزنة؟",
    answerAr:
      "مجلد خاص جوه التطبيق. الملفات اللي بتتنقل جواه بتتشفّر على جهازك بـ AES-256 وبتتفتح برمز ٦ خانات أو ببصمتك. الأسماء والصور بتفضل مموّهة لحد ما تضغط أيقونة العين، فحد واقف وراك مش هيشوف حاجة.",
    keywords: ["vault", "private", "hide", "secure", "lock", "encrypt", "secret", "خزنه", "خاص", "اخفي", "تشفير", "قفل", "سري"],
    topic: "vault",
  },
  {
    id: "vault-forgot",
    question: "I forgot my vault passcode.",
    answer:
      "The files stay encrypted and cannot be recovered. That is what makes it a vault: the key is derived on your device and never leaves it, so there is no server holding a copy and no reset link. Nobody, including us, can open it for you.",
    questionAr: "نسيت رمز الخزنة",
    answerAr:
      "الملفات بتفضل مشفّرة ومفيش طريقة لاستعادتها. ده اللي بيخليها خزنة: المفتاح بيتولّد على جهازك ومبيخرجش منه، فمفيش سيرفر ماسك نسخة ومفيش رابط إعادة تعيين. محدش يقدر يفتحها لك، ولا إحنا.",
    keywords: ["forgot", "lost", "reset", "recover", "passcode", "pin", "password", "locked out", "نسيت", "ضاع", "رمز", "باسورد", "استعاده", "مقفول", "مش بتفتح"],
    topic: "vault",
  },
  {
    id: "vault-locks",
    question: "Why does the vault lock itself?",
    answer:
      "It locks when the app goes to the background, and after two minutes without use. It will not lock while something is playing, so a long video is never interrupted.",
    questionAr: "ليه الخزنة بتقفل نفسها؟",
    answerAr:
      "بتقفل لما التطبيق يروح للخلفية، وبعد دقيقتين من غير استخدام. ومش بتقفل وحاجة شغالة، فالفيديو الطويل عمره ما هيتقطع.",
    keywords: ["lock", "closes", "timeout", "auto", "logout", "empty", "disappear", "بتقفل", "بتتقفل", "اختفت", "مهله"],
    topic: "vault",
  },
  {
    id: "vault-uninstall",
    question: "What happens to vault files if I uninstall?",
    answer:
      "They go with the app. Vault files are encrypted inside the app's own storage, so uninstalling deletes them and no backup exists. Move anything you want to keep out of the vault first.",
    questionAr: "لو مسحت التطبيق، الخزنة تروح فين؟",
    answerAr:
      "بتروح معاه. ملفات الخزنة مشفّرة جوه تخزين التطبيق نفسه، فإلغاء التثبيت بيمسحها ومفيش نسخة احتياطية. انقل أي حاجة مهمة برّه الخزنة الأول.",
    keywords: ["uninstall", "delete", "remove", "backup", "lose", "transfer", "new phone", "مسح", "الغاء", "تثبيت", "نسخه", "احتياطي", "موبايل جديد"],
    topic: "vault",
  },

  // ── Premium ───────────────────────────────────────────────────────────────
  {
    id: "premium-what",
    question: "What does Duck Premium include?",
    answer:
      "No ads, faster processing, and early access to new tools. Everything else, including downloading and the vault, is in the free version.",
    questionAr: "البريميوم فيه إيه؟",
    answerAr:
      "بدون إعلانات، ومعالجة أسرع، ووصول مبكر للأدوات الجديدة. كل حاجة تانية، بما فيها التحميل والخزنة، موجودة في النسخة المجانية.",
    keywords: ["premium", "pro", "paid", "subscription", "upgrade", "ads", "price", "cost", "buy", "بريميوم", "مدفوع", "ترقيه", "اعلانات", "سعر", "فلوس"],
    topic: "premium",
  },
  {
    id: "premium-restore",
    question: "I paid but Premium is not showing.",
    answer:
      "Open Duck Premium in the app and tap Restore Purchases, using the same Google account you paid with. If it still does not appear, message support with the account email and the app rechecks with the store.",
    questionAr: "دفعت والبريميوم مش ظاهر",
    answerAr:
      "افتح Duck Premium في التطبيق واضغط استعادة المشتريات، بنفس حساب جوجل اللي دفعت بيه. لو لسه مش ظاهر، كلّم الدعم بإيميل الحساب والتطبيق هيراجع مع المتجر.",
    keywords: ["restore", "not working", "paid", "missing", "gone", "lost", "purchase", "reinstall", "استعاده", "دفعت", "مش ظاهر", "ضاع", "اختفي", "شراء"],
    topic: "premium",
  },
  {
    id: "premium-cancel",
    question: "How do I cancel my subscription?",
    answer:
      "Through Google Play, not through Duck: open the Play Store, tap your profile, then Payments and subscriptions. Cancelling stops the next renewal and Premium stays active until the period you paid for ends.",
    questionAr: "إزاي ألغي الاشتراك؟",
    answerAr:
      "من متجر Play مش من Duck: افتح المتجر، اضغط على صورتك، بعدين المدفوعات والاشتراكات. الإلغاء بيوقف التجديد الجاي والبريميوم بيفضل شغال لحد ما المدة اللي دفعتها تخلص.",
    keywords: ["cancel", "unsubscribe", "stop", "refund", "billing", "renew", "money back", "الغاء", "الغي", "بطل", "اشتراك", "اوقف", "استرجاع", "فاتوره", "تجديد", "فلوسي"],
    topic: "premium",
  },
  {
    id: "premium-offline",
    question: "Does Premium work offline?",
    answer:
      "Yes. Duck rechecks with the store when it can, and Premium keeps working for a week between successful checks, so losing signal never costs you what you paid for.",
    questionAr: "البريميوم بيشتغل من غير نت؟",
    answerAr:
      "أيوة. Duck بيراجع مع المتجر لما يقدر، والبريميوم بيفضل شغال أسبوع بين كل مراجعة ناجحة، فانقطاع النت عمره ما هيضيّع حاجة دفعت فيها.",
    keywords: ["offline", "no internet", "airplane", "connection", "travel", "نت", "انترنت", "اوفلاين", "طياره", "سفر"],
    topic: "premium",
  },

  // ── Playback ──────────────────────────────────────────────────────────────
  {
    id: "background-audio",
    question: "Can I keep listening with the screen off?",
    answer:
      "Yes, and there is nothing to switch on. Leave the app or lock the screen while a video plays and the audio continues, with a notification carrying play and pause controls.",
    questionAr: "أقدر أسمع والشاشة مقفولة؟",
    answerAr:
      "أيوة، ومفيش حاجة تشغّلها. اطلع من التطبيق أو اقفل الشاشة والفيديو شغال، والصوت هيكمّل، ومعاه إشعار فيه أزرار تشغيل وإيقاف.",
    keywords: ["background", "screen off", "lock", "listen", "audio", "music", "continue", "minimize", "خلفيه", "الشاشه", "اسمع", "صوت", "موسيقي", "يكمل", "اصغر"],
    topic: "playback",
  },
  {
    id: "pip",
    question: "Does Duck support picture-in-picture?",
    answer:
      "Yes. Tap the picture-in-picture button in the player and the video shrinks into a floating window that stays on top while you use other apps.",
    questionAr: "فيه وضع نافذة صغيرة؟",
    answerAr:
      "أيوة. اضغط زرار نافذة داخل نافذة في المشغّل والفيديو هيصغّر لنافذة عايمة بتفضل فوق باقي التطبيقات.",
    keywords: ["pip", "picture in picture", "floating", "popup", "multitask", "small window", "نافذه", "عايمه", "صغيره", "تعدد", "مهام"],
    topic: "playback",
  },
  {
    id: "player-tools",
    question: "What can the player do?",
    answer:
      "Trim a clip, pull out the audio, make a GIF, change speed, and lock the controls so a stray touch does not pause anything. Gestures on the left and right edges control brightness and volume.",
    questionAr: "المشغّل بيعمل إيه؟",
    answerAr:
      "يقص مقطع، ويطلّع الصوت، ويعمل GIF، ويغيّر السرعة، ويقفل الأزرار عشان لمسة بالغلط ما توقفش حاجة. والسحب على حواف الشاشة بيتحكم في الإضاءة والصوت.",
    keywords: ["trim", "cut", "gif", "speed", "convert", "edit", "extract", "volume", "brightness", "tools", "قص", "اقطع", "سرعه", "تحويل", "تعديل", "اضاءه", "ادوات"],
    topic: "playback",
  },

  // ── Files ─────────────────────────────────────────────────────────────────
  {
    id: "file-management",
    question: "Can I manage files already on my phone?",
    answer:
      "Yes. The Folders tab browses every media folder on the device, not only what Duck downloaded, and you can rename, move and delete from there. Android asks for permission the first time, once, for the whole library.",
    questionAr: "أقدر أدير ملفات موجودة على موبايلي؟",
    answerAr:
      "أيوة. تبويب الفولدرات بيتصفح كل مجلدات الميديا على الجهاز، مش بس اللي Duck نزّله، وتقدر تعيد التسمية وتنقل وتمسح من هناك. أندرويد بيطلب الإذن أول مرة بس، للمكتبة كلها.",
    keywords: ["rename", "move", "delete", "organise", "organize", "folder", "manage", "browse", "existing", "اعاده", "تسميه", "نقل", "مسح", "تنظيم", "فولدر", "مجلد", "اداره"],
    topic: "files",
  },
  {
    id: "permission-denied",
    question: "Duck cannot see my folders.",
    answer:
      "Android is holding back media access. Open your phone's Settings, find Duck Downloader under Apps, and allow access to photos, videos and music. Then reopen the Folders tab.",
    questionAr: "Duck مش شايف الفولدرات",
    answerAr:
      "أندرويد مانع الوصول للميديا. افتح إعدادات موبايلك، دوّر على Duck Downloader في التطبيقات، واسمح بالوصول للصور والفيديوهات والصوتيات. وبعدين افتح تبويب الفولدرات تاني.",
    keywords: ["permission", "access", "denied", "empty", "no folders", "cannot see", "blank", "nothing", "اذن", "صلاحيه", "وصول", "مرفوض", "فاضي", "فاضيه", "فولدرات", "فولدر", "مجلدات", "مش شايف", "مفيش"],
    topic: "files",
  },

  // ── General ───────────────────────────────────────────────────────────────
  {
    id: "privacy",
    question: "What data does Duck collect?",
    answer:
      "Nothing about what you download. Files and links stay on your device. The app sends anonymous crash reports so bugs can be fixed, and you can switch that off under Settings, in the Privacy section. Ads in the free version are served by Google AdMob.",
    questionAr: "Duck بيجمع إيه من بياناتي؟",
    answerAr:
      "مفيش أي حاجة عن اللي بتحمّله. الملفات واللينكات بتفضل على جهازك. التطبيق بيبعت تقارير أعطال مجهولة عشان الباجات تتصلح، وتقدر تقفلها من الإعدادات في قسم الخصوصية. والإعلانات في النسخة المجانية من Google AdMob.",
    keywords: ["privacy", "data", "collect", "track", "personal", "gdpr", "information", "spy", "خصوصيه", "بيانات", "يجمع", "تتبع", "معلومات", "تجسس"],
    topic: "general",
  },
  {
    id: "platforms",
    question: "Is there an iPhone version?",
    answer:
      "Not yet. Duck is an Android app today. There is no release date for anything else worth promising.",
    questionAr: "فيه نسخة آيفون؟",
    answerAr:
      "لسه لأ. Duck تطبيق أندرويد دلوقتي. ومفيش تاريخ إصدار لأي حاجة تانية يستاهل الوعد بيه.",
    keywords: ["ios", "iphone", "apple", "windows", "pc", "desktop", "mac", "platform", "available", "ايفون", "ابل", "ويندوز", "كمبيوتر", "ماك", "منصه", "متاح"],
    topic: "general",
  },
  {
    id: "cost",
    question: "Is Duck free?",
    answer:
      "Yes. Every feature works in the free version, supported by ads. Premium removes the ads and speeds up processing.",
    questionAr: "Duck مجاني؟",
    answerAr:
      "أيوة. كل المميزات شغالة في النسخة المجانية، مدعومة بالإعلانات. والبريميوم بيشيل الإعلانات ويسرّع المعالجة.",
    keywords: ["free", "cost", "price", "pay", "money", "charge", "how much", "مجاني", "سعر", "ببلاش", "كام", "فلوس", "ادفع"],
    topic: "general",
  },
];
