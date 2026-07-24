# Project: Duck Downloader Production Readiness & Google Play Compliance

## Architecture
- **Duck Downloader App**: Cross-platform (Flutter/Dart frontend, Kotlin/Android native integration, Web components, Python process-worker/backend).
- **In-App Purchase**: `in_app_purchase` package integration in Flutter, handling subscriptions (`duck_pro_monthly`, `duck_pro_yearly`).
- **Core Controllers & Downloader Logic**: Media downloader screens, background services, lock screen controls, PiP playback, local storage handlers.
- **Android / Store Compliance**: `android/app/src/main/AndroidManifest.xml`, target SDK 34+, permissions (`READ_MEDIA_VIDEO`, `READ_MEDIA_IMAGES`, `WRITE_SETTINGS`, `POST_NOTIFICATIONS`), background service policy compliance, YouTube download handling policy.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|---|---|---|---|
| 1 | Store Production In-App Purchase Setup (R1) | Disable sandbox/mock fallback flags. Configure `in_app_purchase` state management strictly for official store product IDs (`duck_pro_monthly`, `duck_pro_yearly`). Ensure robust streams & error handling. | none | IN_PROGRESS |
| 2 | Production Code Quality & Bug Audit (R2) | Review Dart, Kotlin, Web code. Fix critical `flutter analyze` lints/errors. Ensure 100% `flutter test` pass. Eliminate unhandled null pointers and unhandled async Futures in core controllers. | M1 | PLANNED |
| 3 | Google Play Compliance & Rejection Audit (R3) | Audit permissions (`READ_MEDIA_VIDEO`, `READ_MEDIA_IMAGES`, `WRITE_SETTINGS`, `POST_NOTIFICATIONS` on SDK 34+), background execution, YouTube download policies, privacy disclosures. Generate audit report. | M2 | PLANNED |

## Interface Contracts & Product IDs
- Subscription Product IDs: `duck_pro_monthly`, `duck_pro_yearly`
- Store Services: `in_app_purchase` Flutter plugin

## Code Layout
- Flutter Code: `lib/` (controllers, screens, services, providers)
- Android Native Code: `android/`
- Test Files: `test/`
- Documentation & Metadata: `.agents/`
