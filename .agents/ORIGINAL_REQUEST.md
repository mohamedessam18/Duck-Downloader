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
