import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The sites Duck can sign into, and everything that differs between them.
///
/// This table used to be five `String.contains` chains scattered across the
/// browser screen and the controller, and they had drifted: the button that
/// opened the browser knew about four platforms, the navigation allow-list knew
/// about five, and Threads and Udemy fell through to a generic "Social" that
/// took the wrong code path. One table, read by everything, is the point.
enum SocialPlatform { instagram, threads, facebook, x, youtube, udemy }

class PlatformProfile {
  const PlatformProfile({
    required this.platform,
    required this.id,
    required this.label,
    required this.loginUrl,
    required this.hosts,
    this.authHosts = const [],
    required this.cookieUrls,
    required this.sessionCookies,
  });

  final SocialPlatform platform;

  /// Stable storage key. Never derive this from [label] — renaming X to
  /// Twitter or back would orphan everyone's saved session.
  final String id;

  final String label;

  /// Where the login screen starts. Deliberately the sign-in page and not the
  /// link the user pasted: the link is what failed, and landing on it again
  /// just shows the same wall.
  final String loginUrl;

  /// The hosts that identify this platform, matched as exact host or
  /// subdomain.
  ///
  /// These decide which platform a *link* belongs to, so they must not overlap
  /// between profiles and must not include a site merely passed through during
  /// sign-in. Listing facebook.com here for Instagram — which does redirect
  /// through it — would file every Facebook link under Instagram and send it
  /// the wrong session.
  ///
  /// Matching by `String.contains` would be a hole rather than a convenience:
  /// `evil-instagram.com.attacker.net` contains "instagram.com".
  final List<String> hosts;

  /// Extra hosts the sign-in flow is allowed to visit but does not own.
  ///
  /// Identity providers and consent screens live here. Blocking them cancels
  /// the login itself; owning them would mis-file other platforms' links.
  final List<String> authHosts;

  /// The origins whose cookies together make up this platform's session.
  final List<String> cookieUrls;

  /// Any one of these appearing means the user is signed in.
  ///
  /// This is what lets the login screen close itself instead of asking the
  /// user to decide when they are done.
  final Set<String> sessionCookies;

  static bool _matches(String host, List<String> domains) {
    for (final domain in domains) {
      if (host == domain || host.endsWith('.$domain')) return true;
    }
    return false;
  }

  /// True when a link on [host] belongs to this platform.
  bool ownsHost(String host) => _matches(host.toLowerCase(), hosts);

  /// True when the sign-in screen may navigate to [host].
  bool allowsNavigationTo(String host) {
    final lower = host.toLowerCase();
    return _matches(lower, hosts) || _matches(lower, authHosts);
  }
}

const _profiles = <SocialPlatform, PlatformProfile>{
  SocialPlatform.instagram: PlatformProfile(
    platform: SocialPlatform.instagram,
    id: 'instagram',
    label: 'Instagram',
    loginUrl: 'https://www.instagram.com/accounts/login/',
    hosts: ['instagram.com', 'cdninstagram.com'],
    authHosts: ['facebook.com'],
    cookieUrls: ['https://www.instagram.com', 'https://instagram.com'],
    sessionCookies: {'sessionid'},
  ),
  SocialPlatform.threads: PlatformProfile(
    platform: SocialPlatform.threads,
    id: 'threads',
    label: 'Threads',
    loginUrl: 'https://www.threads.net/login',
    hosts: ['threads.net', 'threads.com'],
    // Threads signs in through Instagram, so the login walks through
    // Instagram's domains without owning them.
    authHosts: ['instagram.com', 'cdninstagram.com', 'facebook.com'],
    // Threads signs in through Instagram, so the session lands on both
    // domains and reading only threads.net would capture half of it.
    cookieUrls: [
      'https://www.threads.net',
      'https://threads.net',
      'https://www.instagram.com',
    ],
    sessionCookies: {'sessionid'},
  ),
  SocialPlatform.facebook: PlatformProfile(
    platform: SocialPlatform.facebook,
    id: 'facebook',
    label: 'Facebook',
    loginUrl: 'https://m.facebook.com/login/',
    hosts: ['facebook.com', 'fb.watch', 'fbcdn.net'],
    authHosts: ['messenger.com'],
    cookieUrls: [
      'https://www.facebook.com',
      'https://m.facebook.com',
      'https://facebook.com',
    ],
    sessionCookies: {'c_user', 'xs'},
  ),
  SocialPlatform.x: PlatformProfile(
    platform: SocialPlatform.x,
    id: 'x',
    label: 'X',
    loginUrl: 'https://x.com/i/flow/login',
    hosts: ['x.com', 'twitter.com', 't.co', 'twimg.com'],
    cookieUrls: [
      'https://x.com',
      'https://twitter.com',
      'https://www.x.com',
    ],
    sessionCookies: {'auth_token'},
  ),
  SocialPlatform.youtube: PlatformProfile(
    platform: SocialPlatform.youtube,
    id: 'youtube',
    label: 'YouTube',
    loginUrl: 'https://accounts.google.com/ServiceLogin?service=youtube',
    hosts: ['youtube.com', 'youtu.be', 'ytimg.com'],
    // Google's sign-in is a different site, and cancelling it cancels
    // the only reason this screen exists for YouTube.
    authHosts: ['google.com', 'gstatic.com'],
    cookieUrls: [
      'https://www.youtube.com',
      'https://youtube.com',
      'https://m.youtube.com',
      'https://accounts.google.com',
      'https://google.com',
    ],
    sessionCookies: {'SAPISID', 'LOGIN_INFO', '__Secure-3PAPISID'},
  ),
  SocialPlatform.udemy: PlatformProfile(
    platform: SocialPlatform.udemy,
    id: 'udemy',
    label: 'Udemy',
    loginUrl: 'https://www.udemy.com/join/login-popup/',
    hosts: ['udemy.com', 'udemycdn.com'],
    cookieUrls: ['https://www.udemy.com', 'https://udemy.com'],
    sessionCookies: {'access_token', 'dj_session_id'},
  ),
};

PlatformProfile profileFor(SocialPlatform platform) => _profiles[platform]!;

List<PlatformProfile> get allPlatformProfiles => _profiles.values.toList();

/// The platform a link belongs to, or null when nothing here can sign into it.
///
/// Matching is on the parsed host, never on the raw URL. Substring matching a
/// URL means `https://evil.com/?x=instagram.com` reads as Instagram and would
/// hand that site's cookies to a stranger's server.
PlatformProfile? profileForUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  final host = uri?.host;
  if (host == null || host.isEmpty) return null;
  for (final profile in _profiles.values) {
    if (profile.ownsHost(host)) return profile;
  }
  return null;
}

/// Signed-in sessions, kept on this device and nowhere else.
///
/// These are account credentials, so they live in the same encrypted store as
/// the Vault key rather than in the plain Hive box the rest of the app uses.
/// They are also stored one platform per key: the previous single-slot design
/// meant signing into Instagram silently erased the YouTube session, because
/// both were written to the same place.
class PlatformSessionStore {
  const PlatformSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage;

  static const _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final FlutterSecureStorage _storage;

  static String _keyFor(SocialPlatform platform) =>
      'duck_session_${profileFor(platform).id}';

  Future<String?> read(SocialPlatform platform) async {
    try {
      final value = await _storage.read(key: _keyFor(platform));
      if (value == null || value.trim().isEmpty) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(SocialPlatform platform, String cookies) async {
    if (cookies.trim().isEmpty) return;
    try {
      await _storage.write(key: _keyFor(platform), value: cookies);
    } catch (_) {}
  }

  Future<void> clear(SocialPlatform platform) async {
    try {
      await _storage.delete(key: _keyFor(platform));
    } catch (_) {}
  }

  Future<void> clearAll() async {
    for (final platform in SocialPlatform.values) {
      await clear(platform);
    }
  }

  Future<bool> hasSession(SocialPlatform platform) async =>
      (await read(platform)) != null;

  Future<Set<SocialPlatform>> signedIn() async {
    final found = <SocialPlatform>{};
    for (final platform in SocialPlatform.values) {
      if (await hasSession(platform)) found.add(platform);
    }
    return found;
  }

  /// The cookies to send with a request for [url], and only those.
  ///
  /// A request for an Instagram post carries the Instagram session and nothing
  /// else. Sending the whole jar would hand every site the user is signed into
  /// to whichever one they happened to paste a link from.
  Future<String?> cookiesForUrl(String url) async {
    final profile = profileForUrl(url);
    if (profile == null) return null;
    return read(profile.platform);
  }
}

/// A request for the user to sign in, and the link to retry once they have.
///
/// The retry URL is carried here rather than re-derived later because the
/// whole point of the sign-in is to finish the download the user already
/// asked for. Losing it meant they had to paste the link a second time, which
/// is what happened whenever they backed out of the old browser.
class LoginRequest {
  const LoginRequest({required this.platform, required this.retryUrl});

  final SocialPlatform platform;
  final String retryUrl;

  PlatformProfile get profile => profileFor(platform);
}
