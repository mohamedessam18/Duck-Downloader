import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/app_localizations.dart';
import '../services/platform_sessions.dart';

const _gold = Color(0xFFFFC52F);
const _dark = Color(0xFF101112);
const _panel = Color(0xFF1D1D1F);
const _muted = Color(0xFF9A9A9E);
const _good = Color(0xFF5BD08A);

/// Signs the user into one site, saves that session, and gets out of the way.
///
/// This replaces a screen that tried to be a browser *and* a scraper: it ran a
/// 240-line JavaScript extractor against whatever page was open, and only
/// synchronised cookies as a side effect of pressing its download button. Two
/// consequences shaped this rewrite. Signing in and pressing back — the
/// obvious thing to do — threw the login away, because nothing else saved it.
/// And for Threads every extraction path was closed off in code, so the
/// button's only possible answer was "no videos here".
///
/// The job now is exactly one thing: come back with a session or come back
/// with nothing. Extraction happens where it already worked, against the link
/// the user actually pasted.
class PlatformLoginScreen extends StatefulWidget {
  const PlatformLoginScreen({super.key, required this.platform});

  final SocialPlatform platform;

  @override
  State<PlatformLoginScreen> createState() => _PlatformLoginScreenState();
}

class _PlatformLoginScreenState extends State<PlatformLoginScreen> {
  /// A plain Chrome build string, without the `; wv` token Android puts in a
  /// WebView's own user agent.
  ///
  /// Google refuses OAuth from anything it can identify as an embedded
  /// browser — "This browser or app may not be secure" — and that token is how
  /// it identifies one. Signing into Google was therefore impossible here, on
  /// the platform whose whole reason for having a login is cookies.
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  /// How often the session check runs while the screen is open.
  ///
  /// Polled rather than hooked to page loads because several of these sites
  /// sign in over XHR and never navigate afterwards, so waiting for a load
  /// event means waiting forever.
  static const _pollInterval = Duration(milliseconds: 1200);

  late final PlatformProfile _profile = profileFor(widget.platform);
  final _sessions = const PlatformSessionStore();

  InAppWebViewController? _controller;
  Timer? _poll;
  double _progress = 0;
  bool _finishing = false;
  String? _blockedHost;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(_pollInterval, (_) => _checkForSession());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Reads this platform's cookies out of the WebView as a Netscape jar.
  ///
  /// Only the origins in the profile are read. Handing yt-dlp every cookie the
  /// WebView holds would send sites credentials belonging to other sites.
  Future<String> _harvest() async {
    final manager = CookieManager.instance();
    final byKey = <String, ({String domain, Cookie cookie})>{};

    for (final origin in _profile.cookieUrls) {
      try {
        final uri = WebUri(origin);
        for (final cookie in await manager.getCookies(url: uri)) {
          // Falling back to the origin's own host matters: a cookie with no
          // explicit domain belongs to the host that set it. The old code
          // defaulted every such cookie to "youtube.com", which quietly filed
          // Instagram's session under YouTube.
          final domain = cookie.domain ?? uri.host;
          byKey['$domain:${cookie.path ?? '/'}:${cookie.name}'] = (
            domain: domain,
            cookie: cookie,
          );
        }
      } catch (_) {}
    }

    if (byKey.isEmpty) return '';

    // Session cookies have no expiry, and a jar written with "0" is read back
    // as already expired. Far enough out to outlive the session itself.
    final fallbackExpiry =
        DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch ~/
        1000;

    final buffer = StringBuffer('# Netscape HTTP Cookie File\n');
    for (final entry in byKey.values) {
      final cookie = entry.cookie;
      final expiry = cookie.expiresDate == null
          ? fallbackExpiry
          : cookie.expiresDate! ~/ 1000;
      buffer.writeln(
        [
          entry.domain,
          entry.domain.startsWith('.') ? 'TRUE' : 'FALSE',
          cookie.path ?? '/',
          cookie.isSecure == true ? 'TRUE' : 'FALSE',
          expiry < 0 ? fallbackExpiry : expiry,
          cookie.name,
          cookie.value,
        ].join('\t'),
      );
    }
    return buffer.toString();
  }

  Future<bool> _hasSessionCookie() async {
    final manager = CookieManager.instance();
    for (final origin in _profile.cookieUrls) {
      try {
        for (final cookie in await manager.getCookies(url: WebUri(origin))) {
          if (_profile.sessionCookies.contains(cookie.name) &&
              cookie.value.trim().isNotEmpty) {
            return true;
          }
        }
      } catch (_) {}
    }
    return false;
  }

  Future<void> _checkForSession() async {
    if (_finishing || !mounted) return;
    if (!await _hasSessionCookie()) return;
    await _finish(requireSessionCookie: false);
  }

  /// Saves the session and closes, returning true to the caller.
  ///
  /// [requireSessionCookie] is false for the automatic path, which has already
  /// seen one. The manual button passes true so it can tell the user nothing
  /// was found rather than closing on an empty jar.
  Future<void> _finish({required bool requireSessionCookie}) async {
    if (_finishing) return;
    _finishing = true;

    final jar = await _harvest();
    final l10n = mounted ? AppLocalizations.of(context) : null;

    if (jar.trim().isEmpty ||
        (requireSessionCookie && !await _hasSessionCookie())) {
      _finishing = false;
      if (!mounted || l10n == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.translate('loginNoSessionYet'))),
      );
      return;
    }

    await _sessions.write(widget.platform, jar);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  bool _allows(WebUri uri) {
    final scheme = uri.scheme.toLowerCase();
    // `intent://`, `market://` and friends leave the app entirely. A login
    // screen has no business launching other apps.
    if (scheme != 'http' && scheme != 'https') return false;
    return _profile.allowsNavigationTo(uri.host);
  }

  String _withPlatform(AppLocalizations l10n, String key) =>
      l10n.translate(key).replaceAll('{platform}', _profile.label);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      // Back belongs to the page first. Without this, one back press from deep
      // inside a multi-step login abandoned the whole thing.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final controller = _controller;
        if (controller != null && await controller.canGoBack()) {
          await controller.goBack();
          return;
        }
        if (mounted) navigator.pop(false);
      },
      child: Scaffold(
        backgroundColor: _dark,
        appBar: AppBar(
          backgroundColor: _panel,
          foregroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.translate('cancel'),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          title: Text(
            _withPlatform(l10n, 'loginTitle'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          actions: const [
            Padding(
              padding: EdgeInsetsDirectional.only(end: 14),
              child: Icon(Icons.lock_outline, size: 20, color: _good),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(46),
            child: _Steps(l10n: l10n),
          ),
        ),
        body: Column(
          children: [
            SizedBox(
              height: 2,
              child: _progress >= 1
                  ? null
                  : LinearProgressIndicator(
                      value: _progress == 0 ? null : _progress,
                      color: _gold,
                      backgroundColor: Colors.white10,
                      minHeight: 2,
                    ),
            ),
            if (_blockedHost != null)
              _Notice(
                text: _withPlatform(l10n, 'loginBlockedHost'),
                onDismiss: () => setState(() => _blockedHost = null),
              ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_profile.loginUrl)),
                initialSettings: InAppWebViewSettings(
                  userAgent: _userAgent,
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  supportMultipleWindows: false,
                  javaScriptCanOpenWindowsAutomatically: false,
                  useShouldOverrideUrlLoading: true,
                  // Sign-in pages are the one place a saved password is worth
                  // offering, and turning it off here helps nobody.
                  clearCache: false,
                ),
                onWebViewCreated: (controller) => _controller = controller,
                onLoadStart: (_, _) {
                  // Reset per navigation. Left at 1 after the first page, the
                  // bar never moved again for the rest of the session.
                  if (mounted) setState(() => _progress = 0);
                },
                onProgressChanged: (_, progress) {
                  if (mounted) setState(() => _progress = progress / 100);
                },
                onLoadStop: (_, _) {
                  if (mounted) setState(() => _progress = 1);
                  unawaited(_checkForSession());
                },
                shouldOverrideUrlLoading: (_, action) async {
                  // Only main-frame navigations are the screen's business. On
                  // iOS this fires for iframes too, and cancelling those broke
                  // embedded captcha and consent frames — which is to say, the
                  // login itself.
                  if (action.isForMainFrame == false) {
                    return NavigationActionPolicy.ALLOW;
                  }
                  final uri = action.request.url;
                  if (uri == null || _allows(uri)) {
                    return NavigationActionPolicy.ALLOW;
                  }
                  if (mounted) setState(() => _blockedHost = uri.host);
                  return NavigationActionPolicy.CANCEL;
                },
                onCreateWindow: (_, _) async => false,
              ),
            ),
            _Footer(
              note: _withPlatform(l10n, 'loginPrivacyNote'),
              buttonLabel: l10n.translate('loginDoneButton'),
              onDone: () => _finish(requireSessionCookie: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where the user is, and what happens after they finish.
///
/// The old screen said nothing about why a login page had appeared inside a
/// downloader, which is a reasonable thing for someone to be suspicious about.
class _Steps extends StatelessWidget {
  const _Steps({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    const keys = ['loginStepSignIn', 'loginStepSave', 'loginStepContinue'];
    return Container(
      height: 46,
      color: _panel,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (var i = 0; i < keys.length; i++) ...[
            if (i > 0)
              const Expanded(
                child: Divider(color: Colors.white24, thickness: 1),
              ),
            _Step(index: i + 1, label: l10n.translate(keys[i]), active: i == 0),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.label, required this.active});

  final int index;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colour = active ? _gold : _muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? _gold : Colors.transparent,
            border: Border.all(color: colour, width: 1.4),
          ),
          child: Text(
            '$index',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: active ? const Color(0xFF151515) : _muted,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: colour,
          ),
        ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.note,
    required this.buttonLabel,
    required this.onDone,
  });

  final String note;
  final String buttonLabel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: _panel,
      padding: EdgeInsets.fromLTRB(
        14,
        12,
        14,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline, size: 18, color: _good),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              note,
              style: const TextStyle(
                color: _muted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: onDone,
            style: TextButton.styleFrom(foregroundColor: _gold),
            child: Text(
              buttonLabel,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.onDismiss});

  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _panel,
      padding: const EdgeInsetsDirectional.only(start: 14, end: 4),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, size: 18, color: _gold),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: _muted),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
