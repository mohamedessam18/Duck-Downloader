# Original User Request

## Initial Request — 2026-07-02T22:49:28Z

Verify and test the Threads media downloader in the Duck Downloader application using three specific test cases to ensure all media extraction scenarios work perfectly.

Working directory: d:\PROJECTS\Duck Downloder
Integrity mode: development

## Test URLs
- **Single Image**: `https://www.threads.com/@aicreatorbase/post/DaTTBQSFXzk`
- **Single Video**: `https://www.threads.com/@ahnmedyahya/post/DaTQ9Umjf1N`
- **Mixed Image & Video**: `https://www.threads.com/@cataessapromo/post/DaRLOr2jiRX`

## Requirements

### R1. Verification Script
Create a Python verification script inside the scratch directory `C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/` that loads or simulates the HTML content of the three target Threads URLs.

### R2. Scraper Simulation
The script must evaluate our updated Javascript scraper script (`_extractScript` from `lib/screens/locked_social_browser_screen.dart`) against the page HTML/DOM structure.

### R3. Output Integrity Verification
Ensure the script verifies:
1. **Single Image**: Extracts exactly 1 image URL (high resolution, no profile pictures or static assets).
2. **Single Video**: Extracts exactly 1 video URL (with `isVideo: true`, no static placeholder images).
3. **Mixed Carousel**: Extracts exactly the main post's images and videos (no duplicates, no comment section avatars, no recommended posts).

## Acceptance Criteria

### Test Validation
- [ ] The Python verification script runs successfully inside the python/docker environment.
- [ ] All three test cases pass validation.
- [ ] No duplicates or avatar/comment URLs are returned by the scraper.

## Follow-up — 2026-07-24T14:33:04Z

Full production readiness audit, Google Play Store review simulation, and Google Play Billing production store configuration for Duck Downloader.

Working directory: d:\PROJECTS\Duck Downloder
Integrity mode: development

## Requirements

### R1. Store Production In-App Purchase Setup
Disable any sandbox/mock/dummy fallback flags for subscriptions and configure `in_app_purchase` state management to rely strictly on official store products (Google Play Billing / Apple App Store).

### R2. Production Code Quality & Bug Audit
Conduct a comprehensive static and dynamic review of all Dart, Kotlin, and Web source code. Identify potential runtime crashes, race conditions, memory leaks, or unhandled exceptions across media downloads, PiP, lock screen playback, and local storage.

### R3. Google Play Store Compliance & Rejection Simulation
Simulate a Google Play Console automated and manual app review. Inspect app metadata, permissions, background services, network calls, and user data safety disclosures against Google Play Developer Policies. Report any potential rejection triggers (trademark violations, privacy policy gaps, prohibited background executions) along with actionable fixes.

## Acceptance Criteria

### In-App Purchase Production Readiness
- [ ] In-App Purchase service removes sandbox/mock fallback flags and is configured for live store product IDs (`duck_pro_monthly`, `duck_pro_yearly`).
- [ ] Product loading, purchase stream listening, and purchase restoration logic handle real store responses seamlessly without throwing unhandled exceptions.

### Code Quality & Bug-Free Operation
- [ ] All Flutter unit tests pass (`flutter test`).
- [ ] `flutter analyze` reports zero critical errors or breaking warnings.
- [ ] No unhandled null pointer exceptions or unhandled async Futures exist in core controllers.

### Google Play Policy & Rejection Audit
- [ ] Comprehensive audit report generated listing all potential Google Play Store rejection risks (if any).
- [ ] Verification that YouTube downloads on Google Play builds are handled safely with compliant user messaging.
- [ ] Verification that permissions (`READ_MEDIA_VIDEO`, `READ_MEDIA_IMAGES`, `WRITE_SETTINGS`, `POST_NOTIFICATIONS`) conform to Google Play Target SDK 34+ guidelines.

