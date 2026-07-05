# Project: Threads Downloader Verification and Testing

## Architecture
- **Duck Downloader App**: Dart/Flutter mobile application.
- **Scraper Screen**: `lib/screens/locked_social_browser_screen.dart` contains a JavaScript string `_extractScript` used to extract media links (image and video URLs) from a web view.
- **Verification Script**: A Python verification script needs to be created inside the scratch directory `C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/`.
- **Environment**: Runs inside a Python/Docker environment (requires standard python execution).
- **Test Scenarios**:
  1. **Single Image URL**: `https://www.threads.com/@aicreatorbase/post/DaTTBQSFXzk` -> Extracts exactly 1 high-resolution image URL. No profile pictures or static assets.
  2. **Single Video URL**: `https://www.threads.com/@ahnmedyahya/post/DaTQ9Umjf1N` -> Extracts exactly 1 video URL with `isVideo: true`. No static placeholder images.
  3. **Mixed Image & Video URL**: `https://www.threads.com/@cataessapromo/post/DaRLOr2jiRX` -> Extracts exactly the main post's images and videos (no duplicates, no comment section avatars, no recommended posts).

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|---|---|---|---|
| 1 | Exploration & Analysis | Locate Threads HTML/JSON mock sources in the workspace/scratch dir. Analyze the JS scraper `_extractScript`. | none | DONE |
| 2 | Python Verification Script | Implement the verification script in the scratch directory to evaluate `_extractScript` against the simulated/loaded HTML. | M1 | DONE |
| 3 | Validation and Verification | Execute the script inside the Python environment to verify that all 3 test cases pass successfully with no duplicates/avatars. | M2 | DONE |

## Code Layout
- Scraper Script: `lib/screens/locked_social_browser_screen.dart`
- Verification Script: `C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/verify_threads.py` (or similar)
- Mock Data / Scripts: `C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/`
