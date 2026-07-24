import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/downloads_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final DuckDownloadsController controller;

  static const String privacyPolicyUrl = 'https://duckdownloader.app/privacy-policy.html';

  Future<void> _openPrivacyPolicy(BuildContext context) async {
    try {
      final Uri uri = Uri.parse(privacyPolicyUrl);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        final Uri localUri = Uri.parse('privacy-policy.html');
        await launchUrl(localUri);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open Privacy Policy: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? const Color(0xFF101112) : const Color(0xFFF5F6F8);
    final cardColor = isDark ? const Color(0xFF1D1D1F) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF151517);
    final mutedColor = isDark ? const Color(0xFFB8B8B8) : const Color(0xFF6F707A);
    const goldColor = Color(0xFFFFC52F);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF171819) : Colors.white,
        elevation: 0,
        title: Text(
          'Settings & Compliance',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        iconTheme: IconThemeData(color: textColor),
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: cardColor,
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.privacy_tip_outlined, color: goldColor),
                      title: Text(
                        'Privacy Policy',
                        style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        'Read our Google Play compliant Privacy Policy & disclosures',
                        style: TextStyle(color: mutedColor, fontSize: 13),
                      ),
                      trailing: Icon(Icons.open_in_new, color: mutedColor, size: 20),
                      onTap: () => _openPrivacyPolicy(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Card(
                color: cardColor,
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.save_alt, color: goldColor),
                      title: Text(
                        'Auto Save Media',
                        style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        'Automatically save completed downloads to Gallery / Music',
                        style: TextStyle(color: mutedColor, fontSize: 13),
                      ),
                      value: controller.autoSaveVideos,
                      activeColor: goldColor,
                      onChanged: (val) => controller.toggleAutoSaveVideos(val),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.content_paste, color: goldColor),
                      title: Text(
                        'Clipboard Link Detection',
                        style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        'Prompt to download when media links are copied',
                        style: TextStyle(color: mutedColor, fontSize: 13),
                      ),
                      value: controller.enableClipboardDetection,
                      activeColor: goldColor,
                      onChanged: (val) => controller.toggleClipboardDetection(val),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.music_note, color: goldColor),
                      title: Text(
                        'Background Playback',
                        style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        'Continue audio playback when screen is off or in background',
                        style: TextStyle(color: mutedColor, fontSize: 13),
                      ),
                      value: controller.backgroundPlaybackEnabled,
                      activeColor: goldColor,
                      onChanged: (val) => controller.toggleBackgroundPlaybackEnabled(val),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'Duck Downloader v1.0.0+1\nGoogle Play Compliant Build (Target SDK 34)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: mutedColor, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
