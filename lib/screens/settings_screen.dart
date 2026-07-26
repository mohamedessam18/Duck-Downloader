import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/downloads_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final DuckDownloadsController controller;

  static const String privacyPolicyUrl = 'https://duckdownloader.app/privacy-policy.html';

  void _showPrivacyPolicyDialog(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? const Color(0xFF1D1D1F) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF151517);
    final mutedColor = isDark ? const Color(0xFFB8B8B8) : const Color(0xFF6F707A);
    const goldColor = Color(0xFFFFC52F);

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: dialogBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 500),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: goldColor.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shield_outlined, color: goldColor, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Privacy Policy',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: mutedColor),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildPolicySection(
                          title: '1. User Data & Security',
                          content:
                              'Duck Downloader respects your absolute privacy. All downloaded media files, images, videos, and private vault content are stored locally on your device only. No personal files are ever uploaded or transmitted to external servers.',
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                        _buildPolicySection(
                          title: '2. Private Vault Encryption',
                          content:
                              'Files moved to the Secure Vault are encrypted and hidden from third-party gallery apps. Access is strictly guarded by your personal 4-digit PIN and optional Biometric / Face ID authentication.',
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                        _buildPolicySection(
                          title: '3. Device Permissions',
                          content:
                              '• Storage & Media: Required exclusively to save downloaded media files to your device gallery/music folder.\n• Notifications: Used solely to show live download progress bars.\n• Write System Settings: Required when setting trimmed audio clips as system ringtones.',
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                        _buildPolicySection(
                          title: '4. Google Play Developer Compliance',
                          content:
                              'Duck Downloader complies strictly with Google Play Developer Policies. Background operations are limited to active media tasks, and no user tracking or telemetry data is collected.',
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Last Updated: July 2026',
                          style: TextStyle(color: mutedColor, fontSize: 11, fontStyle: FontStyle.italic),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: goldColor,
                      foregroundColor: const Color(0xFF151517),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('I Understand', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPolicySection({
    required String title,
    required String content,
    required Color textColor,
    required Color mutedColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            content,
            style: TextStyle(color: mutedColor, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
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
                      trailing: Icon(Icons.chevron_right, color: mutedColor, size: 22),
                      onTap: () => _showPrivacyPolicyDialog(context),
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
