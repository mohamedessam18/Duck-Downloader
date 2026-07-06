import 'dart:ui';

bool get mediaIsLight =>
    PlatformDispatcher.instance.platformBrightness == Brightness.light;

Color get mediaGold =>
    mediaIsLight ? const Color(0xFFC69214) : const Color(0xFFFFC52F);

Color get mediaWarmGold =>
    mediaIsLight ? const Color(0xFFB58032) : const Color(0xFFF6BD6A);

Color get mediaMuted =>
    mediaIsLight ? const Color(0xFF6F707A) : const Color(0xFFB8B8B8);

const mediaDanger = Color(0xFFFF7A65);
