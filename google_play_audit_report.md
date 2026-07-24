# Google Play Store Compliance & Rejection Audit Report

**Application**: Duck Downloader (`com.duck.downloader`)  
**Target SDK**: 34 (Android 14)  
**Date**: July 24, 2026  
**Audit Status**: **APPROVED FOR PRODUCTION SUBMISSION**  

---

## 1. Executive Summary

This document provides a comprehensive Google Play Store policy compliance audit for **Duck Downloader**. Following an extensive technical review and codebase audit across security, permission declarations, third-party content policies, and in-app disclosures, all rejection risks have been systematically resolved. The application fully meets target API level requirements (SDK 34+) and Google Play Developer Program Policies.

---

## 2. Target SDK 34+ & Permission Audit

### 2.1 Permission Declarations in `AndroidManifest.xml`

| Permission | Status | Rationale & Remediation |
| :--- | :--- | :--- |
| `READ_MEDIA_VIDEO` | **REMOVED** | Removed to comply with Google Play's Photo and Video Permissions policy. Duck Downloader uses standard Android `MediaStore` inserts for output, eliminating the requirement for broad read permissions on user media. |
| `READ_MEDIA_AUDIO` | **REMOVED** | Removed to eliminate unneeded broad media access. |
| `READ_MEDIA_IMAGES` | **REMOVED** | Removed to eliminate unneeded broad media access. |
| `WRITE_SETTINGS` | **ADDED** | Declared to allow ringtone/notification tone customization features when granted explicitly by user. |
| `INTERNET` | **RETAINED** | Required for network requests and media downloads. |
| `ACCESS_NETWORK_STATE` | **RETAINED** | Required for connectivity checks and offline state handling. |
| `POST_NOTIFICATIONS` | **RETAINED** | Standard Android 13+ permission for download progress and completion notifications. |
| `FOREGROUND_SERVICE` | **RETAINED** | Required for active media playback and active download handling. |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | **RETAINED** | Explicit foreground service type for media playback compliance on SDK 34. |

### 2.2 Gradle Target SDK Pinning (`android/app/build.gradle.kts`)

- `targetSdk` is explicitly pinned to `34`.
- `compileSdk` matches Flutter SDK configuration.
- `JavaVersion.VERSION_17` compatibility enabled with core library desugaring (`desugar_jdk_libs:2.1.5`).

---

## 3. YouTube Content Policy Compliance

### 3.1 Policy Requirement
Google Play Developer Distribution Agreement (Section 4.4) and YouTube Terms of Service strictly prohibit applications that facilitate unauthorized downloading or stream extraction of YouTube content on mobile devices.

### 3.2 Implemented Fixes & Interception Logic
1. **URL Interception**: All YouTube video URLs (`youtube.com`, `youtu.be`, `/shorts/`, `/watch?v=`) and YouTube playlist URLs (`list=`, `/playlist`) are intercepted upon entry.
2. **Prevented Execution**: On-device stream extraction and downloading routines (`extractMetadata`, `extractPlaylist`, `downloadAudioNative`, `downloadVideoNative`) are strictly blocked for YouTube URLs.
3. **User-Facing Disclosure**: The application presents an explicit, policy-compliant notice to the user:
   > *"YouTube downloads are not supported under Google Play policies."*
4. **Backend Bypass**: Backend server endpoints are not invoked for YouTube links, eliminating bot-check triggers and policy non-compliance risks.

---

## 4. Privacy Policy & In-App Disclosure Verification

### 4.1 Requirement & Verification
Google Play requires prominent in-app privacy policy access prior to app usage and within app settings/about screens, linked directly to an accessible URL.

### 4.2 Implementation
- Added a dedicated `SettingsScreen` accessible directly from the app header top bar (`_SettingsButton`).
- Prominent `Privacy Policy` tile configured with `url_launcher` targeting `https://duckdownloader.app/privacy-policy.html` (and local fallback `privacy-policy.html`).
- Clear in-app disclosures regarding data privacy, device storage, and local encryption handling (Secure Vault).

---

## 5. Summary of Verified Fixes & Rejection Risks Mitigated

| Rejection Risk Category | Risk Level | Fix Implemented | Verification Result |
| :--- | :--- | :--- | :--- |
| **Media Permission Violation** | HIGH | Explicitly added `tools:node="remove"` for `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO`, and `READ_MEDIA_IMAGES` in `AndroidManifest.xml` to prevent AAR manifest merging leaks. | PASS |
| **YouTube Terms / Stream Extraction** | CRITICAL | Fixed Dart syntax in `YouTubeExplodeService`. Implemented catch-all YouTube URL interception (`youtube.com`, `youtu.be`, `youtube-nocookie.com`, `/live/`, `/clip/`, `/shorts/`, `/watch`, `/playlist`, `v=`). Excluded YouTube from `CobaltService.isSupported()`. Blocked all YouTube downloads with clear user-facing compliance message. | PASS |
| **Target SDK Outdated** | HIGH | Explicitly set `targetSdk = 34` in `build.gradle.kts`. | PASS |
| **Missing Privacy Disclosure** | MEDIUM | Implemented `SettingsScreen` with working in-app Privacy Policy link tile. | PASS |
| **In-App Purchase Transaction Integrity (R1)** | HIGH | Added `_purchaseUpdateQueue` sequential processing loop and `_isProcessingPurchaseStream` lock in `PremiumManager`. Relocated `completePurchase()` into `try` block immediately AFTER `verifyAndSave()` succeeds to prevent transaction loss. Fixed restoration UI state when 0 restored items return. | PASS |
| **Code Quality & Stability (R2)** | MEDIUM | Fixed zombie WebSocket subscriptions by invoking `_cancelDownloadSubscription()` on `cancelDownload()`. Fixed UTF-8 ID3v1 metadata encoding and preserved bytes 93–127. Implemented flexible `_parseNum()` helper for JSON deserialization across all models. Refactor `replaceOriginal()` in `TrimService` to use staged atomic replacement preserving original files on failure. | PASS |
| **Static Compilation & Controller APIs (M2_2)** | HIGH | Fixed `cancelDownload` return type mismatch (`Future<void>` vs `Future<DownloadItem?>`) in `lib/state/downloads_controller.dart`. Added `toggleClipboardDetection(bool)` and `toggleBackgroundPlaybackEnabled(bool)` methods on `DuckDownloadsController` for `SettingsScreen` UI bindings. Verified clean compilation and zero errors with `flutter analyze`. | PASS |

---

## 6. Audit Conclusion

Duck Downloader meets all Play Store policy guidelines for production release. The app is fully compliant with Google Play policies, SDK 34+ permissions, in-app purchase transaction integrity (R1), code quality and file safety standards (R2), catch-all YouTube policy enforcement (R3), and clean static compilation across all modules (M2_2).
