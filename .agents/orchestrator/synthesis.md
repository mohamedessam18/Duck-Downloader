# Synthesis of Exploration Findings — Iteration 2 Remediation Plan

## 1. Overview
All three Explorer subagents for Iteration 2 have completed their investigations and delivered detailed fix specifications:
- **Explorer 1 (M2)**: `d:\PROJECTS\Duck Downloder\.agents\explorer_m2_1\handoff.md` (R1 IAP Transaction & Concurrency Fixes)
- **Explorer 2 (M2)**: `d:\PROJECTS\Duck Downloder\.agents\explorer_m2_2\handoff.md` (R2 Code Quality, Stream Cleanup, ID3 Tags, Type Parsing, Staged File Operations)
- **Explorer 3 (M2)**: `d:\PROJECTS\Duck Downloder\.agents\explorer_m2_3\handoff.md` (R3 Syntax Correction, YouTube Catch-All Interception, Cobalt Service Exclusion)

---

## 2. Comprehensive Implementation Roadmap for Worker 2

### Track 1: Requirement R1 — Store Production In-App Purchase Setup
1. **Target File**: `lib/services/premium_manager.dart`
   - Add queue fields: `final List<List<PurchaseDetails>> _purchaseUpdateQueue = [];` and `bool _isProcessingPurchaseStream = false;`.
   - Update `_handlePurchaseUpdates` to push purchase lists to `_purchaseUpdateQueue` and process them sequentially inside a `_isProcessingPurchaseStream` lock.
   - Relocate `completePurchase(purchase)` into the `try` block immediately AFTER `verifyAndSave(purchase)` succeeds. Do NOT execute `completePurchase` in `catch` or `finally` blocks when receipt verification fails.
   - Ensure `purchasePending = false` and `statusMessage = 'No active purchases found to restore.'` when store returns 0 restored items.

### Track 2: Requirement R2 — Code Quality & Bug Fixes
1. **WebSocket Stream Cleanup (`lib/state/downloads_controller.dart`)**:
   - In `cancelDownload()` and inside `_controlDownload()` when `action == 'cancel'`, invoke `_cancelDownloadSubscription(item.id)` to cancel and dispose active WebSocket subscriptions.
2. **ID3 Tag Unicode & Metadata Preservation (`lib/services/file_service.dart`)**:
   - Add `import 'dart:convert';`.
   - Update `_fixedLengthBytes` to use `utf8.encode(val)` so non-ASCII/Unicode strings are encoded properly without replacing characters >= 256 with `?`.
   - Update `updateMp3Metadata`: when `hasTag == true`, read existing 128-byte ID3v1 block into `tagBytes` before updating offsets 0–92 to preserve Year, Comment, Track, and Genre metadata.
3. **JSON String-Number Deserialization (`lib/models/download_models.dart`)**:
   - Add `num? _parseNum(dynamic v) => v is num ? v : (v is String ? num.tryParse(v) : null);`.
   - Update `FormatInfo.fromJson`, `DownloadItem.fromJson`, `DownloadStatusUpdate.fromJson`, `PlaylistItem.fromJson`, `BackendCookiesInfo.fromJson` to use `_parseNum(...)?.toInt()`.
4. **Staged Replacement for Cross-Volume Operations (`lib/services/trim_service.dart`)**:
   - Refactor `replaceOriginal()` to perform staged replacement: copy `trimmed` to temp file in target folder, verify copy, back up original via rename, swap temp to original, and delete backup/trimmed files.

### Track 3: Requirement R3 — Google Play Compliance & Syntax Fixes
1. **Dart Syntax & Service Methods (`lib/services/youtube_explode_service.dart`)**:
   - Remove misplaced closing brace `}` at line 101. Clean up class structure so all methods (`extractMetadata`, `extractPlaylist`, `downloadAudioNative`, `downloadVideoNative`, `downloadStream`) are cleanly defined in class body and throw `Exception('YouTube downloads are not supported under Google Play policies.')`.
2. **Catch-All YouTube Interception (`lib/services/youtube_explode_service.dart` & `lib/state/downloads_controller.dart`)**:
   - Update `isYouTubeUrl` and `isYouTubePlaylistUrl` to return `true` for ANY URL containing `youtube.com`, `youtu.be`, `youtube-nocookie.com`, `/live/`, `/clip/`, `/shorts/`, `/watch`, `/playlist`, `v=`, or substring `youtube`.
3. **Disable YouTube in Cobalt Service (`lib/services/cobalt_service.dart`)**:
   - Update `CobaltService.isSupported(String url)`: explicitly reject YouTube URLs (`if (lower.contains('youtube') || lower.contains('youtu.be')) return false;`).
4. **Update Unit Tests (`test/cobalt_service_test.dart` & `test/r3_youtube_permission_challenge_test.dart`)**:
   - Update test assertions to verify `CobaltService.isSupported` returns `false` for YouTube URLs.
5. **Manifest AAR Merger Safeguard (`android/app/src/main/AndroidManifest.xml`)**:
   - Explicitly add `<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" tools:node="remove"/>`, `<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" tools:node="remove"/>`, `<uses-permission android:name="android.permission.READ_MEDIA_AUDIO" tools:node="remove"/>`.

### Track 4: Build & Test Verification
- Run `flutter analyze` and fix any errors or warnings.
- Run `flutter test` via terminal command and verify that 100% of tests compile and pass.
- Update `google_play_audit_report.md` to document all verified fixes.
