import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/browser_image_candidate.dart';
import '../state/downloads_controller.dart';

const _gold = Color(0xFFFFC52F);
const _dark = Color(0xFF101112);
const _panel = Color(0xFF1D1D1F);
const _danger = Color(0xFFFF7A65);

class LockedSocialBrowserScreen extends StatefulWidget {
  const LockedSocialBrowserScreen({
    super.key,
    required this.initialUrl,
    required this.platform,
    required this.controller,
  });

  final String initialUrl;
  final String platform;
  final DuckDownloadsController controller;

  @override
  State<LockedSocialBrowserScreen> createState() =>
      _LockedSocialBrowserScreenState();
}

class _LockedSocialBrowserScreenState extends State<LockedSocialBrowserScreen> {
  InAppWebViewController? _controller;
  double _progress = 0;
  String? _blockedHost;
  bool _extracting = false;

  bool get _isInstagram => widget.platform.toLowerCase().contains('instagram') ||
      widget.platform.toLowerCase().contains('threads');

  bool get _isYouTube => widget.platform.toLowerCase().contains('youtube');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _dark,
      appBar: AppBar(
        backgroundColor: _panel,
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 0,
        title: const Text(
          'Duck Downloader',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _controller?.reload(),
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: const Color(0xFF151515),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: _extracting ? null : _extractImages,
              icon: _extracting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: const Text(
                'Download Media',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 1)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress,
              color: _gold,
              backgroundColor: Colors.white10,
              minHeight: 2,
            ),
          if (_blockedHost != null)
            MaterialBanner(
              backgroundColor: _panel,
              content: Text(
                'Blocked navigation outside Duck Downloader: $_blockedHost',
                style: const TextStyle(color: Colors.white),
              ),
              leading: const Icon(Icons.lock, color: _danger),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _blockedHost = null),
                  child: const Text('OK'),
                ),
              ],
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                thirdPartyCookiesEnabled: true,
                supportMultipleWindows: false,
                javaScriptCanOpenWindowsAutomatically: false,
                useShouldOverrideUrlLoading: true,
                mediaPlaybackRequiresUserGesture: false,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onProgressChanged: (_, progress) {
                if (mounted) setState(() => _progress = progress / 100);
              },
              shouldOverrideUrlLoading: (_, action) async {
                final uri = action.request.url;
                if (uri == null || _isAllowedNavigation(uri)) {
                  return NavigationActionPolicy.ALLOW;
                }
                if (mounted) setState(() => _blockedHost = uri.host);
                return NavigationActionPolicy.CANCEL;
              },
              onCreateWindow: (controller, createWindowAction) async => false,
            ),
          ),
        ],
      ),
    );
  }

  bool _isAllowedNavigation(WebUri uri) {
    final host = uri.host.toLowerCase();
    if (_isInstagram) {
      return host == 'instagram.com' ||
          host.endsWith('.instagram.com') ||
          host == 'threads.net' ||
          host.endsWith('.threads.net') ||
          host == 'threads.com' ||
          host.endsWith('.threads.com');
    }
    if (_isYouTube) {
      return host == 'youtube.com' ||
          host.endsWith('.youtube.com') ||
          host == 'youtu.be' ||
          host.endsWith('.youtu.be') ||
          host == 'google.com' ||
          host.endsWith('.google.com');
    }
    return host == 'x.com' ||
        host.endsWith('.x.com') ||
        host == 'twitter.com' ||
        host.endsWith('.twitter.com') ||
        host == 't.co';
  }

  Future<String> _getNetscapeCookiesForPlatform() async {
    try {
      final cookieManager = CookieManager.instance();
      final urlsToQuery = <String>[];

      final platformLower = widget.platform.toLowerCase();
      if (platformLower.contains('youtube')) {
        urlsToQuery.addAll([
          'https://youtube.com',
          'https://www.youtube.com',
          'https://m.youtube.com',
          'https://google.com',
          'https://accounts.google.com',
        ]);
      } else if (platformLower.contains('instagram') || platformLower.contains('threads')) {
        urlsToQuery.addAll([
          'https://instagram.com',
          'https://www.instagram.com',
          'https://threads.net',
          'https://www.threads.net',
        ]);
      } else if (platformLower.contains('facebook')) {
        urlsToQuery.addAll([
          'https://facebook.com',
          'https://www.facebook.com',
          'https://m.facebook.com',
        ]);
      } else if (platformLower.contains('x') || platformLower.contains('twitter')) {
        urlsToQuery.addAll([
          'https://twitter.com',
          'https://www.twitter.com',
          'https://x.com',
          'https://www.x.com',
        ]);
      } else {
        final currentUri = await _controller?.getUrl();
        if (currentUri != null) {
          urlsToQuery.add(currentUri.toString());
        }
        urlsToQuery.add(widget.initialUrl);
      }

      final allCookiesMap = <String, Cookie>{};
      for (final url in urlsToQuery) {
        try {
          final uri = WebUri(url);
          final cookies = await cookieManager.getCookies(url: uri);
          for (final cookie in cookies) {
            final domain = cookie.domain ?? uri.host;
            final key = '$domain:${cookie.name}';
            allCookiesMap[key] = cookie;
          }
        } catch (_) {}
      }

      if (allCookiesMap.isEmpty) return '';

      final sb = StringBuffer();
      sb.writeln('# Netscape HTTP Cookie File');
      for (final cookie in allCookiesMap.values) {
        final domain = cookie.domain ?? 'youtube.com';
        final flag = domain.startsWith('.') ? 'TRUE' : 'FALSE';
        final path = cookie.path ?? '/';
        final secure = cookie.isSecure == true ? 'TRUE' : 'FALSE';
        final expiration = cookie.expiresDate != null
            ? (cookie.expiresDate! ~/ 1000).toString()
            : (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 365 * 10).toString();
        final name = cookie.name;
        final value = cookie.value;
        sb.writeln('$domain\t$flag\t$path\t$secure\t$expiration\t$name\t$value');
      }
      return sb.toString();
    } catch (_) {
      return '';
    }
  }

  Future<void> _extractImages() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _extracting = true);
    try {
      final currentUri = await controller.getUrl();
      final currentUrl = currentUri?.toString() ?? widget.initialUrl;

      // 1. Sync cookies from WebView to Backend
      try {
        final cookiesText = await _getNetscapeCookiesForPlatform();
        if (cookiesText.trim().isNotEmpty) {
          await widget.controller.updateCookies(cookiesText);
        }
      } catch (_) {
        // Ignore cookie sync errors and proceed
      }

      if (_isYouTube) {
        if (mounted) {
          Navigator.of(context).pop(currentUrl);
          return;
        }
      }

      // 2. Try backend scraper first (now has access to the user's synced cookies)
      final platformLower = widget.platform.toLowerCase();
      final isThreads = platformLower.contains('threads');
      final isTwitter = platformLower.contains('x') || platformLower.contains('twitter');
      final isVideoOnly = isThreads || isTwitter;

      if (!isThreads) {
        try {
          final playlist = await widget.controller.extractPlaylist(widget.initialUrl);
          if (playlist.items.isNotEmpty) {
            var candidates = playlist.items.map((item) {
              return BrowserImageCandidate(
                url: item.url,
                title: item.title,
                thumbnail: item.thumbnail,
                isPreview: false,
                source: 'backend_api',
                isVideo: item.isVideo,
              );
            }).toList();

            if (isVideoOnly) {
              candidates = candidates.where((c) => c.isVideo).toList();
            }

            if (mounted) {
              if (candidates.isEmpty && isVideoOnly) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('This ${widget.platform} post does not contain any videos.'),
                  ),
                );
                return;
              }
              Navigator.of(context).pop(candidates);
              return;
            }
          }
        } catch (_) {
          // Fallback to JS DOM extraction if backend extraction fails
        }
      }

      // 3. Fallback: JS DOM extraction
      final result = await controller.evaluateJavascript(
        source: _extractScript,
      );
      final text = result?.toString() ?? '[]';
      debugPrint('RAW JS EXTRACTED: $text');
      final decoded = jsonDecode(text);
      var candidates = BrowserImageCandidate.normalizeAll(
        decoded is List ? decoded : const [],
      );

      if (isVideoOnly) {
        // Keep only videos, ignore images
        candidates = candidates.where((c) => c.isVideo).toList();
      }

      if (!mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isVideoOnly
                ? 'This ${widget.platform} post does not contain any videos.'
                : 'Could not find full-size images on this page.'),
          ),
        );
        return;
      }
      Navigator.of(context).pop(candidates);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read images from this page.')),
      );
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }
}

const _extractScript = r'''
(() => {
  const out = [];
  const candidatesMap = new Map();
  let order = 0;

  const getCleanPath = (url) => {
    try {
      const u = new URL(url);
      let path = u.pathname;
      path = path.replace(/\/s\d+x\d+\//g, '/').replace(/\/e\d+\//g, '/');
      const segments = path.split('/');
      const filename = segments[segments.length - 1];
      const base = filename.split('.')[0];
      return base;
    } catch (_) {
      return url;
    }
  };

  const add = (url, width, height, source, isPreview = false, slideIndex = null, isVideo = false) => {
    if (!url || typeof url !== 'string') return;
    try {
      const absolute = new URL(url.replace(/\\u0026/g, '&').replace(/\\/g, ''), location.href).href;
      const cleanPath = getCleanPath(absolute);
      
      const lower = absolute.toLowerCase();
      const computedIsVideo = isVideo || 
                              lower.includes('.mp4') || 
                              lower.includes('.m4v') || 
                              lower.includes('.mov') || 
                              lower.includes('video') ||
                              lower.includes('.webm') ||
                              lower.includes('.3gp');

      const candidate = {
        url: absolute,
        width: Number.isFinite(Number(width)) ? Number(width) : null,
        height: Number.isFinite(Number(height)) ? Number(height) : null,
        source,
        isPreview,
        order: order++,
        slideIndex: Number.isFinite(Number(slideIndex)) ? Number(slideIndex) : null,
        isVideo: computedIsVideo,
      };

      const existing = candidatesMap.get(cleanPath);
      if (existing) {
        if (candidate.isVideo && !existing.isVideo) {
          candidatesMap.set(cleanPath, candidate);
        } else if (!candidate.isVideo && existing.isVideo) {
          // Keep existing video!
        } else {
          const existingWidth = existing.width || 0;
          const newWidth = candidate.width || 0;
          if (newWidth > existingWidth) {
            candidatesMap.set(cleanPath, candidate);
          }
        }
      } else {
        candidatesMap.set(cleanPath, candidate);
      }
    } catch (_) {}
  };

  const parseSrcset = (srcset, source, slideIndex = null) => {
    if (!srcset || typeof srcset !== 'string') return;
    for (const part of srcset.split(',')) {
      const bits = part.trim().split(/\s+/);
      if (!bits[0]) continue;
      const widthHint = bits.find((bit) => /\d+w$/.test(bit));
      const width = widthHint ? Number(widthHint.replace('w', '')) : null;
      add(bits[0], width, null, source, false, slideIndex, false);
    }
  };

  const candidateFromImageNode = (img, source, slideIndex = null) => {
    if (!img) return;
    add(
      img.currentSrc || img.src,
      img.naturalWidth || img.width,
      img.naturalHeight || img.height,
      source,
      false,
      slideIndex,
      false,
    );
    parseSrcset(img.srcset, `${source}_srcset`, slideIndex);
  };

  const scanDom = (slideIndex = null) => {
    const mainContainer = document.querySelector('article') || document.querySelector('main') || document;

    mainContainer.querySelectorAll('img').forEach((img) => {
      candidateFromImageNode(img, 'img', slideIndex);
    });

    mainContainer.querySelectorAll('picture source[srcset], source[srcset]').forEach((source) => {
      parseSrcset(source.getAttribute('srcset'), 'picture_srcset', slideIndex);
    });

    mainContainer.querySelectorAll('video src, video source, video').forEach((vid) => {
      const src = vid.src || vid.getAttribute('src');
      if (src) {
        add(src, null, null, 'video', false, slideIndex, true);
      }
    });

    document.querySelectorAll('meta[property="og:image"], meta[name="twitter:image"], meta[property="og:image:secure_url"]').forEach((meta) => {
      add(meta.getAttribute('content'), null, null, 'meta_preview', true, slideIndex, false);
    });

    document.querySelectorAll('meta[property="og:video"], meta[property="og:video:secure_url"], meta[name="twitter:player"]').forEach((meta) => {
      add(meta.getAttribute('content'), null, null, 'meta_preview_video', true, slideIndex, true);
    });
  };

  const addImageObject = (node, source, slideIndex = null) => {
    if (!node || typeof node !== 'object') return;
    const candidates = node.candidates || node.additionalCandidates || node.resources || [];
    if (Array.isArray(candidates)) {
      candidates.forEach((candidate) => {
        add(
          candidate?.url || candidate?.src,
          candidate?.width || candidate?.config_width,
          candidate?.height || candidate?.config_height,
          source,
          false,
          slideIndex,
          false,
        );
      });
    }
    add(node.url || node.src || node.display_url || node.thumbnail_src, node.width, node.height, source, false, slideIndex, false);
  };

  const addVideoObject = (node, source, slideIndex = null) => {
    if (!node || typeof node !== 'object') return;
    const candidates = node.candidates || node.additionalCandidates || node.resources || [];
    if (Array.isArray(candidates)) {
      candidates.forEach((candidate) => {
        add(
          candidate?.url || candidate?.src,
          candidate?.width || candidate?.config_width,
          candidate?.height || candidate?.config_height,
          source,
          false,
          slideIndex,
          true,
        );
      });
    }
    if (Array.isArray(node)) {
      node.forEach((candidate) => {
        add(
          candidate?.url || candidate?.src,
          candidate?.width || candidate?.config_width,
          candidate?.height || candidate?.config_height,
          source,
          false,
          slideIndex,
          true,
        );
      });
    }
    add(node.url || node.src || node.display_url || node.video_url, node.width, node.height, source, false, slideIndex, true);
  };

  const walkJson = (value, source, state) => {
    if (!value || state.count > 25000) return;
    state.count++;
    if (Array.isArray(value)) {
      value.forEach((item, index) => walkJson(item, source, { count: state.count, slideIndex: state.slideIndex ?? index }));
      return;
    }
    if (typeof value !== 'object') return;

    const explicitIndex = value.carousel_index ?? value.carouselIndex ?? value.slide_index ?? value.index;
    const slideIndex = Number.isFinite(Number(explicitIndex)) ? Number(explicitIndex) : state.slideIndex;

    if (value.image_versions2) addImageObject(value.image_versions2, source, slideIndex);
    if (value.display_resources) addImageObject({ candidates: value.display_resources }, source, slideIndex);
    if (value.imageVersions) addImageObject(value.imageVersions, source, slideIndex);
    if (value.display_url || value.thumbnail_src) addImageObject(value, source, slideIndex);

    if (value.video_versions) addVideoObject(value.video_versions, source, slideIndex);
    if (value.videoVersions) addVideoObject(value.videoVersions, source, slideIndex);
    if (value.video_url) add(value.video_url, value.width, value.height, source, false, slideIndex, true);

    const children = value.carousel_media || value.edge_sidecar_to_children?.edges || value.children || value.items;
    if (Array.isArray(children)) {
      children.forEach((child, index) => {
        const media = child?.node || child;
        walkJson(media, source, { count: state.count, slideIndex: index });
      });
    }

    Object.keys(value).forEach((key) => {
      if (key === 'carousel_media' || key === 'children' || key === 'items') return;
      const child = value[key];
      if (child && typeof child === 'object') walkJson(child, source, { count: state.count, slideIndex });
    });
  };

  const scanPageData = () => {
    const scripts = Array.from(document.scripts).map((script) => script.textContent || '').filter(Boolean);
    scripts.forEach((text) => {
      if (!/(image_versions2|display_resources|carousel_media|edge_sidecar_to_children|display_url|cdninstagram|fbcdn|twimg|video)/i.test(text)) return;

      const jsonMatches = text.match(/\{[^<]{100,}\}/g) || [];
      jsonMatches.slice(0, 12).forEach((match) => {
        try {
          walkJson(JSON.parse(match), 'page_data', { count: 0, slideIndex: null });
        } catch (_) {}
      });

      const urlMatches = text.match(/https?:(?:\\?\/){2}[^"'\s<>)]+/g) || [];
      urlMatches.forEach((raw) => {
        const decoded = raw
          .replace(/\\u0026/g, '&')
          .replace(/\\/g, '');
        const lowerDecoded = decoded.toLowerCase();
        const looksVid = /\.(mp4|m4v|mov|webm|3gp)(\?|$)/i.test(lowerDecoded);
        if (looksVid) {
          add(decoded, null, null, 'page_data_video_url', false, null, true);
        }
      });
    });
  };

  const isVideoOnlyPlatform = window.location.hostname.includes('threads.net') || 
                              window.location.hostname.includes('threads.com') ||
                              window.location.hostname.includes('twitter.com') ||
                              window.location.hostname.includes('x.com');
  if (!isVideoOnlyPlatform) {
    scanPageData();
  }
  scanDom(0);

  return JSON.stringify(Array.from(candidatesMap.values()));
})()
''';
