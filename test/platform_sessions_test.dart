import 'package:duck_downloader/services/platform_sessions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the platform keystore, which no test can reach.
class _FakeSecureStorage {
  final Map<String, String> values = {};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            switch (call.method) {
              case 'read':
                return values[args['key']];
              case 'write':
                values[args['key'] as String] = args['value'] as String;
                return null;
              case 'delete':
                values.remove(args['key']);
                return null;
              case 'readAll':
                return values;
              case 'deleteAll':
                values.clear();
                return null;
            }
            return null;
          },
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a link is matched by its host, never by substring', () {
    test('real links resolve to their platform', () {
      expect(
        profileForUrl('https://www.instagram.com/p/ABC/')?.platform,
        SocialPlatform.instagram,
      );
      expect(
        profileForUrl('https://x.com/user/status/1')?.platform,
        SocialPlatform.x,
      );
      expect(
        profileForUrl('https://youtu.be/dQw4w9WgXcQ')?.platform,
        SocialPlatform.youtube,
      );
      expect(
        profileForUrl('https://www.threads.net/@user/post/1')?.platform,
        SocialPlatform.threads,
      );
    });

    test('a lookalike host is not the platform', () {
      // The old code asked whether the whole URL *contained* "instagram.com",
      // so both of these read as Instagram and would have been handed that
      // account's session.
      expect(profileForUrl('https://evil.com/?next=instagram.com'), isNull);
      expect(profileForUrl('https://instagram.com.attacker.net/p/1'), isNull);
      expect(profileForUrl('https://notinstagram.com/p/1'), isNull);
    });

    test('sites Duck cannot sign into resolve to nothing', () {
      expect(profileForUrl('https://tiktok.com/@a/video/1'), isNull);
      expect(profileForUrl('https://reddit.com/r/a/comments/b'), isNull);
      expect(profileForUrl('not a url'), isNull);
      expect(profileForUrl(''), isNull);
    });

    test('platforms do not claim each other\'s links', () {
      // Instagram's sign-in redirects through facebook.com, which is why it
      // used to appear in Instagram's host list — and why every Facebook link
      // resolved to Instagram.
      expect(
        profileForUrl('https://www.facebook.com/watch/?v=1')?.platform,
        SocialPlatform.facebook,
      );
      expect(
        profileForUrl('https://www.instagram.com/p/1/')?.platform,
        SocialPlatform.instagram,
      );
      // Google is walked through for a YouTube sign-in but is not YouTube.
      expect(profileForUrl('https://accounts.google.com/signin'), isNull);
    });

    test('subdomains belong to their parent', () {
      expect(
        profileForUrl('https://scontent.cdninstagram.com/x.jpg')?.platform,
        SocialPlatform.instagram,
      );
      expect(
        profileForUrl('https://m.facebook.com/story')?.platform,
        SocialPlatform.facebook,
      );
    });
  });

  group('navigation is wider than ownership', () {
    test('a sign-in may walk through its identity provider', () {
      final youtube = profileFor(SocialPlatform.youtube);
      expect(youtube.allowsNavigationTo('accounts.google.com'), isTrue);
      expect(youtube.ownsHost('accounts.google.com'), isFalse);

      final threads = profileFor(SocialPlatform.threads);
      expect(threads.allowsNavigationTo('www.instagram.com'), isTrue);
      expect(threads.ownsHost('www.instagram.com'), isFalse);
    });

    test('an unrelated host is still refused', () {
      final instagram = profileFor(SocialPlatform.instagram);
      expect(instagram.allowsNavigationTo('example.com'), isFalse);
      expect(instagram.allowsNavigationTo('instagram.com.attacker.net'), isFalse);
    });
  });

  group('sessions are kept apart', () {
    late _FakeSecureStorage fake;
    late PlatformSessionStore store;

    setUp(() {
      fake = _FakeSecureStorage()..install();
      store = PlatformSessionStore(
        storage: const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        ),
      );
    });

    test('signing into one platform does not disturb another', () async {
      await store.write(SocialPlatform.youtube, 'youtube-jar');
      await store.write(SocialPlatform.instagram, 'instagram-jar');

      // The single-slot store this replaces wrote every platform to the same
      // key, so signing into Instagram silently ended the YouTube session.
      expect(await store.read(SocialPlatform.youtube), 'youtube-jar');
      expect(await store.read(SocialPlatform.instagram), 'instagram-jar');
      expect(fake.values.keys.toSet(), hasLength(2));
    });

    test('a request carries only its own platform cookies', () async {
      await store.write(SocialPlatform.youtube, 'youtube-jar');
      await store.write(SocialPlatform.instagram, 'instagram-jar');

      expect(
        await store.cookiesForUrl('https://www.instagram.com/p/1/'),
        'instagram-jar',
      );
      expect(
        await store.cookiesForUrl('https://youtu.be/abc'),
        'youtube-jar',
      );
    });

    test('a site with no session sends nothing', () async {
      await store.write(SocialPlatform.instagram, 'instagram-jar');
      expect(await store.cookiesForUrl('https://x.com/a/status/1'), isNull);
    });

    test('an unknown site never receives a session', () async {
      await store.write(SocialPlatform.instagram, 'instagram-jar');
      // Including one whose URL merely mentions a platform Duck knows.
      expect(
        await store.cookiesForUrl('https://evil.com/?ref=instagram.com'),
        isNull,
      );
      expect(await store.cookiesForUrl('https://tiktok.com/@a'), isNull);
    });

    test('signing out removes one session and leaves the rest', () async {
      await store.write(SocialPlatform.youtube, 'youtube-jar');
      await store.write(SocialPlatform.instagram, 'instagram-jar');

      await store.clear(SocialPlatform.instagram);
      expect(await store.read(SocialPlatform.instagram), isNull);
      expect(await store.read(SocialPlatform.youtube), 'youtube-jar');

      expect(await store.signedIn(), {SocialPlatform.youtube});
    });

    test('signing out of everything leaves nothing behind', () async {
      for (final platform in SocialPlatform.values) {
        await store.write(platform, 'jar');
      }
      await store.clearAll();
      expect(await store.signedIn(), isEmpty);
      expect(fake.values, isEmpty);
    });

    test('an empty jar is not a session', () async {
      await store.write(SocialPlatform.x, '   ');
      expect(await store.hasSession(SocialPlatform.x), isFalse);
    });
  });

  test('every platform has what the login screen needs', () {
    for (final profile in allPlatformProfiles) {
      expect(profile.sessionCookies, isNotEmpty, reason: profile.id);
      expect(profile.cookieUrls, isNotEmpty, reason: profile.id);
      expect(profile.hosts, isNotEmpty, reason: profile.id);
      // The login URL has to be inside the allow-list, or the screen cancels
      // its own first navigation.
      final host = Uri.parse(profile.loginUrl).host;
      expect(profile.allowsNavigationTo(host), isTrue, reason: profile.id);
    }
  });

  test('no two platforms claim the same host', () {
    final seen = <String, String>{};
    for (final profile in allPlatformProfiles) {
      for (final host in profile.hosts) {
        expect(
          seen.containsKey(host),
          isFalse,
          reason: '$host claimed by both ${seen[host]} and ${profile.id}',
        );
        seen[host] = profile.id;
      }
    }
  });
}
