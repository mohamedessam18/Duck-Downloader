# Threads Media Downloader Analysis and Verification Strategy

## 1. Executive Summary
This report analyzes the existing scraper script `_extractScript` in `lib/screens/locked_social_browser_screen.dart` and examines resources in the scratch directory to establish a verification strategy for the Threads media downloader in Duck Downloader. Currently, the scratch directory lacks cached HTML files or page data specific to the three target URLs. Therefore, the recommended verification strategy relies on programmatically generating mocked HTML pages that simulate the DOM and inline script states for each test case. To evaluate the ES6-based JS scraper, we propose running the script using Node.js (via Python's `subprocess` or `execjs`) or a polyfilled `js2py` environment with a lightweight DOM mock, and then verifying the output against the rejections and normalization rules defined in `BrowserImageCandidate`.

---

## 2. Scratch Directory Resource Audit
We examined all files in `C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/` and determined their contents:

1. **`all_urls.txt` (27.8 KB)**:
   - A plain text list containing 420 URLs.
   - Mostly static assets hosted on Meta CDN (`static.cdninstagram.com`), redirect URLs (`tinyurl.com`, `short.gy`), regional help center URLs, and blocklist prefixes.
   - *Findings*: Does not contain any HTML markup, page structures, or post metadata for the three target URLs.

2. **`script_11.json` (38.8 KB) & `script_16.json` (37.7 KB)**:
   - Hydration script payloads containing configuration metadata, translation tables, bootloader endpoints, and URL prefix blocklists (like `ClickIDURLPrefixBlocklistSVConfig`) typical of the Threads/Instagram web app structure.
   - *Findings*: These files are generic configuration scripts. They do not contain any post contents, images, videos, or account data for the three target URLs.

3. **`test_threads.py` (1.0 KB)**:
   - A script that sends a network request to `https://www.threads.net/@zuck/post/Cx7z8o5r4lZ` with custom headers and searches for keywords like `zuck`, `threads` in the response body.
   - *Findings*: This is a simple diagnostic script and is not a verification script for our target URLs.

4. **`test_extract.dart` (0.9 KB)**:
   - A Dart helper script that sends a POST request to `/api/playlist/extract` on `localhost:8000` to test playlist extraction API serialization.
   - *Findings*: Unrelated to Threads WebView scraper execution.

5. **`fix_consts.dart` & `fix_consts.py`**:
   - Automated helper scripts to run `flutter analyze` and fix constant errors in `lib/screens/duck_app_screen.dart`.
   - *Findings*: Unrelated to the Threads media downloader.

**Conclusion**: The scratch directory contains **no cached HTML pages, page data, or structures** for the three target URLs:
- `https://www.threads.com/@aicreatorbase/post/DaTTBQSFXzk` (Single Image)
- `https://www.threads.com/@ahnmedyahya/post/DaTQ9Umjf1N` (Single Video)
- `https://www.threads.com/@cataessapromo/post/DaRLOr2jiRX` (Mixed Carousel)

---

## 3. Scraper Script Analysis (`_extractScript`)
The scraper script located in `lib/screens/locked_social_browser_screen.dart` (lines 259–494) is a synchronous JavaScript IIFE designed to extract media links from a WebView.

### Key Components:
- **`getCleanPath(url)`**: Parses the URL and cleans up sizing and encoding segments (such as `/s640x640/` or `/e35/`). It returns the base filename (excluding extension, e.g. `12345_n` for `12345_n.jpg`). This is the key for candidate deduplication.
- **`add(...)`**: Resolves candidate URLs, determines if the media is a video (checking `.mp4`, `.mov`, etc. or `isVideo: true`), and registers candidates in `candidatesMap`.
  - *Deduplication logic*: If a candidate with the same base filename exists:
    - If new is video and existing is image, overwrite image with video.
    - If new is image and existing is video, keep existing video.
    - If both are of the same type, keep the one with the larger width.
- **`scanDom(slideIndex)`**: Searches for media elements inside the DOM:
  - Constrained to `<article>` (representing the main post) or `<main>` or document.
  - Queries `img` elements (capturing `currentSrc`/`src`, `srcset`, and `picture source[srcset]`).
  - Queries `video` and `video source` elements.
  - Queries preview meta tags (`og:image`, `og:video`, etc.).
- **`scanPageData()`**: Searches all inline scripts:
  - Filters scripts matching key media-related keywords.
  - Extracts JSON-like strings using the regular expression `/\{[^<]{100,}\}/g`.
  - For each match (up to 12), parses and traverses the object recursively via `walkJson`.
  - Extracts raw video URLs matching `.mp4`, etc.
- **`walkJson(...)`**: Traverses JSON structures to find media properties:
  - Extracts images: `image_versions2`, `display_resources`, `imageVersions`, `display_url`, `thumbnail_src`.
  - Extracts videos: `video_versions`, `videoVersions`, `video_url`.
  - Traverses carousels: `carousel_media`, `edge_sidecar_to_children.edges`, `children`, `items`, tracking the slide index.
- **Output**: Returns a JSON string of all objects in `candidatesMap.values()`.

---

## 4. Recommended Python Verification Script Strategy

To test and verify the JS scraper script against the three target URLs in a constrained network environment, we must mock/simulate the page structure and evaluate the scraper.

### A. Environment Simulation
Since the scraper script uses modern JavaScript features (`const/let`, `Map`, `Array.from`, `arrow functions`, and `new URL()`), standard Python JS engines like `js2py` can fail or require extensive polyfills.
*Recommended Runtime*:
- **Node.js execution via Python `subprocess`**: Run a Node.js process to execute the script. It natively supports ES6 features and `URL` objects.
- **Python-based DOM Mocking**: Since we are in a script environment without a full headless browser, we can mock the DOM APIs in JavaScript before executing `_extractScript`.

#### Mock DOM JavaScript Preamble:
```javascript
class Element {
  constructor(tag, attrs = {}) {
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
  }
  getAttribute(name) {
    return this.attrs[name] || null;
  }
  get src() { return this.attrs['src'] || ''; }
  get currentSrc() { return this.attrs['currentSrc'] || ''; }
  get srcset() { return this.attrs['srcset'] || ''; }
  get naturalWidth() { return this.attrs['width'] ? Number(this.attrs['width']) : 0; }
  get width() { return this.attrs['width'] ? Number(this.attrs['width']) : 0; }
  get naturalHeight() { return this.attrs['height'] ? Number(this.attrs['height']) : 0; }
  get height() { return this.attrs['height'] ? Number(this.attrs['height']) : 0; }
}

class DocumentMock {
  constructor() {
    this.elements = [];
    this.scripts = [];
  }
  querySelector(selector) {
    return this; // Simplify so mainContainer queries run against the document mock
  }
  querySelectorAll(selector) {
    if (selector.includes('img')) {
      return this.elements.filter(e => e.tagName === 'IMG');
    }
    if (selector.includes('video') || selector.includes('source')) {
      return this.elements.filter(e => e.tagName === 'VIDEO' || e.tagName === 'SOURCE');
    }
    if (selector.includes('meta')) {
      return this.elements.filter(e => e.tagName === 'META');
    }
    if (selector.includes('picture source')) {
      return this.elements.filter(e => e.tagName === 'SOURCE' && e.attrs['srcset']);
    }
    return [];
  }
  get scripts() {
    return this.scripts;
  }
}

// Global environment mocks
const location = { href: 'https://www.threads.net/' };
const document = new DocumentMock();
```

### B. Python Mock Data Structures for Test Cases

The Python verification script will construct the mock environment for each URL. Here are the suggested structures:

#### Test Case 1: Single Image (`https://www.threads.com/@aicreatorbase/post/DaTTBQSFXzk`)
- **Mock DOM Configuration**:
  - Image element: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/post_image_123_n.jpg" width="1080" height="1080">`
  - Profile avatar element: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/avatar_profile_pic_n.jpg" width="150" height="150">`
  - Meta tag: `<meta property="og:image" content="https://scontent.cdninstagram.com/v/t51.2885-15/post_image_123_n.jpg">`
- **Verification Rule**: Verify exactly **1** candidate is returned, and it is the high-res post image, while the avatar is correctly rejected by the candidate filtering logic.

#### Test Case 2: Single Video (`https://www.threads.com/@ahnmedyahya/post/DaTQ9Umjf1N`)
- **Mock DOM Configuration**:
  - Video elements: `<video><source src="https://scontent.cdninstagram.com/v/t50.1234-16/post_video_456_n.mp4"></video>`
  - Video placeholder thumbnail image: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/post_video_456_n.jpg" width="1080" height="1920">`
  - Script block containing React Hydration state:
    ```json
    {
      "require": [
        ["ScheduledServerJS", "handle", null, [{
          "video_versions": [{"url": "https://scontent.cdninstagram.com/v/t50.1234-16/post_video_456_n.mp4", "width": 1080, "height": 1920}]
        }]]
      ]
    }
    ```
- **Verification Rule**: Verify exactly **1** candidate is returned with `isVideo: true`. The static placeholder image sharing the base filename `post_video_456_n` must be automatically discarded in favor of the video URL.

#### Test Case 3: Mixed Carousel (`https://www.threads.com/@cataessapromo/post/DaRLOr2jiRX`)
- **Mock DOM Configuration**:
  - Main post container with:
    - Slide 0 Video: `<video src="https://scontent.cdninstagram.com/v/t50.1234-16/slide_0_video_789_n.mp4"></video>`
    - Slide 0 Video Placeholder: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/slide_0_video_789_n.jpg" width="1080" height="1080">`
    - Slide 1 Image: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/slide_1_image_abc_n.jpg" width="1080" height="1080">`
    - Slide 2 Image: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/slide_2_image_xyz_n.jpg" width="1080" height="1080">`
  - Outside post container (Comments section mock):
    - Avatar: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/user_avatar_n.jpg" width="50" height="50">`
    - Comment image: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/comment_attach_n.jpg" width="300" height="300">`
  - Script block representing carousel structures:
    ```json
    {
      "carousel_media": [
        {"carousel_index": 0, "video_versions": [{"url": "https://scontent.cdninstagram.com/v/t50.1234-16/slide_0_video_789_n.mp4"}]},
        {"carousel_index": 1, "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/v/t51.2885-15/slide_1_image_abc_n.jpg"}]}},
        {"carousel_index": 2, "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/v/t51.2885-15/slide_2_image_xyz_n.jpg"}]}}
      ]
    }
    ```
- **Verification Rule**: Verify exactly **3** candidates are returned (1 video, 2 images) with correct slide indexes. Verify that comments/avatars outside the main article are excluded, and no duplicate images (like the video placeholder) are extracted.

### C. Output Integration with `BrowserImageCandidate` Rules
The Python verification script should load the JS execution output and simulate Dart's `BrowserImageCandidate.normalizeAll` rejections:
1. Parse JS output list of candidates.
2. Apply rejections:
   - Reject URLs matching `profile_pic`, `s150x150`, `/profile_images/`, `avatar`, `logo`, `icon`, `spinner`, `tracker`, `/static/`, `/assets/`, `rsrc.php`.
   - Reject candidates where width and height are known and less than 150.
3. Sort and rank:
   - Group by URL and keep the one with the highest score (ranking source rank: `page_data` > `srcset` > `img` > `meta`).
   - Sort final candidates by `slideIndex` then `order`.
4. Run assertions on the final lists to ensure perfect alignment with target test requirements.
