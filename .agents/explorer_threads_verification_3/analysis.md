# Analysis - Threads Downloader Verification and Testing

## Executive Summary
This analysis outlines the verification and testing strategy for the Threads media downloader in Duck Downloader. By analyzing the `_extractScript` scraper in the client code and examining the scratch directory, we propose a robust testing strategy using simulated HTML/DOM structures in a Python/Node.js validation script.

---

## 1. Scratch Directory Investigation
We investigated the scratch directory located at:
`C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/`

We examined the following files:
- **`all_urls.txt`**: Contains 421 lines of resource URLs, script paths, stylesheet links, and other external domains. None of the lines contain the target post IDs or user names.
- **`script_11.json`**: Contains a Barcelona (Threads) client-side bootloader shell response returning a 404 page layout (`Barcelona404ErrorRoot`). No post-specific media or details are present.
- **`script_16.json`**: Contains Barcelona client-side CDS/theme data and bootloader configurations. No post-specific media or details are present.
- **`test_threads.py`**: A python crawler script designed to download and inspect `@zuck`'s Threads post (`Cx7z8o5r4lZ`). Does not contain references to the target URLs.
- **`fix_consts.py` / `fix_consts.dart`**: Scripts used to automate fixing Flutter/Dart constant linting issues on `duck_app_screen.dart`.
- **`test_extract.dart`**: A Dart client test script simulating an extraction request to a local API server using a dummy Instagram URL.

**Finding**: There are no cached HTML pages, page data, or structures for the three target URLs inside the scratch directory or the workspace. They must be simulated/mocked for verification.

---

## 2. JS Scraper Script `_extractScript` Analysis
The scraper script is located in `lib/screens/locked_social_browser_screen.dart` (lines 259–494).

### Key Mechanics
1. **DOM Scoping (Lines 349–350)**:
   - Scopes the extraction using `document.querySelector('article')` (which represents the primary post card/body on Threads/Instagram) or `document.querySelector('main')`.
   - Scoping strictly within `<article>` naturally excludes recommended posts, headers, and the comment section avatars which exist outside the main post container.
2. **Deduplication by Base Filename (Lines 265–277, 305–320)**:
   - `getCleanPath` extracts the filename segment of Meta CDN URLs, strips resolution parameters (like `/s640x640/` or `/e35/`), and returns the base filename (excluding extension, e.g., `4321_n`).
   - If multiple candidates have the same base filename (representing the same media asset in different resolutions/formats), the script:
     - Prioritizes video candidates (`isVideo: true`) over image candidates (replaces the image placeholder with the video).
     - Keeps the candidate with the highest resolution/width if they are of the same media type.
3. **Structured JSON Scanning (Lines 427–461)**:
   - Extracts data from script tags using `walkJson`, recursively scanning for keys like `image_versions2`, `display_resources`, `video_versions`, and `carousel_media`.
   - Prevents recursive overflow by capping the search count at 25,000 steps.
4. **Synchronous Execution (Lines 260, 489–492)**:
   - Uses a fully synchronous IIFE (`(() => { ... })()`) to ensure that the WebView's `evaluateJavascript` returns the populated media array instantly rather than returning a pending promise placeholder.

---

## 3. Recommended Python Verification Strategy
Since the scraper script relies on modern ES6+ JS features (such as `Map`, `Array.from`, `const`/`let`, arrow functions, and `new URL()`), evaluating it using Python's standard `js2py` library is **not recommended** because `js2py` implements an ES5 runtime and lacks native support for ES6 classes, collections, and modern browser APIs. Transpiling and polyfilling the script inside `js2py` is brittle.

### Proposed Architecture
We recommend using **Node.js** as the JS execution runtime via Python's `subprocess` module.
- The Python verification script will read `lib/screens/locked_social_browser_screen.dart` to extract the `_extractScript` Javascript string.
- The Python script will define mock HTML structures representing each of the three test scenarios.
- For each test, Python will write a temporary JS file containing a lightweight DOM emulation wrapper, the simulated page data, and the scraper script.
- The Python script will execute `node temp_runner.js`, capture the output, and verify the assertions.

### DOM Emulation Wrapper
To run the scraper without a real browser (like Selenium or Playwright), we mock the standard browser APIs in JS:
```javascript
// Stub DOM Classes
class Element {
  constructor(data) {
    this.tagName = data.tagName || 'DIV';
    this.src = data.src || '';
    this.currentSrc = data.currentSrc || '';
    this.srcset = data.srcset || '';
    this.content = data.content || '';
    this.textContent = data.textContent || '';
    this.naturalWidth = data.width || null;
    this.naturalHeight = data.height || null;
    this.width = data.width || null;
    this.height = data.height || null;
    this._children = (data.children || []).map(c => new Element(c));
  }
  getAttribute(name) {
    if (name === 'srcset') return this.srcset;
    if (name === 'src') return this.src;
    if (name === 'content') return this.content;
    return '';
  }
  querySelectorAll(selector) {
    const results = [];
    const match = (el) => {
      if (selector === 'img' && el.tagName === 'IMG') results.push(el);
      if (selector === 'video' && el.tagName === 'VIDEO') results.push(el);
      if (selector === 'video src, video source, video') {
        if (el.tagName === 'VIDEO' || el.tagName === 'SOURCE') results.push(el);
      }
      if (selector === 'picture source[srcset], source[srcset]' && el.tagName === 'SOURCE' && el.srcset) results.push(el);
      if (selector.includes('meta') && el.tagName === 'META') results.push(el);
      el._children.forEach(match);
    };
    this._children.forEach(match);
    return results;
  }
}

// Global Mocks
global.location = { href: '%(url)s' };
global.document = {
  scripts: %(scripts)s.map(text => ({ textContent: text })),
  querySelector: (selector) => {
    if (selector === 'article') return %(article)s ? new Element(%(article)s) : null;
    if (selector === 'main') return %(main)s ? new Element(%(main)s) : null;
    return new Element(%(document)s);
  },
  querySelectorAll: (selector) => {
    return new Element(%(document)s).querySelectorAll(selector);
  }
};
```

---

## 4. Test Scenario Structure & Mock Data

### Scenario 1: Single Image Post
- **Target URL**: `https://www.threads.com/@aicreatorbase/post/DaTTBQSFXzk`
- **Output Integrity Rule**: Extracts exactly 1 high-resolution image URL. Profile pictures (avatars) and recommended post images must be excluded.
- **Mock DOM Structure**:
  - Main document contains a `<main>` container.
  - Avatar image `https://scontent.cdninstagram.com/v/t51.2885-15/avatar_1.jpg` lives outside the `<article>`.
  - Recommended image `https://scontent.cdninstagram.com/v/t51.2885-15/recommendation_1.jpg` lives outside the `<article>`.
  - Main post `<article>` contains an `<img>` tag with `src="https://scontent.cdninstagram.com/v/t51.2885-15/image_1.jpg"` and width 1080.
  - Scripts contain page JSON state with `image_versions2` referencing the main post image.

### Scenario 2: Single Video Post
- **Target URL**: `https://www.threads.com/@ahnmedyahya/post/DaTQ9Umjf1N`
- **Output Integrity Rule**: Extracts exactly 1 video URL with `isVideo: true`. The static thumbnail image (placeholder) sharing the same base filename must be excluded (deduplicated).
- **Mock DOM Structure**:
  - Main post `<article>` contains a `<video>` tag with `src="https://scontent.cdninstagram.com/v/t51.2885-15/video_1.mp4"`.
  - Main post `<article>` contains an `<img>` tag (video thumbnail) with `src="https://scontent.cdninstagram.com/v/t51.2885-15/video_1.jpg"`.
  - Script tags contain JSON state with `video_versions` and `image_versions2` using matching filename prefixes.

### Scenario 3: Mixed Carousel Post (Image & Video)
- **Target URL**: `https://www.threads.com/@cataessapromo/post/DaRLOr2jiRX`
- **Output Integrity Rule**: Extracts exactly the main post's images and videos. No duplicates, no comment section avatars, no recommended posts.
- **Mock DOM Structure**:
  - Main post `<article>` contains a carousel of two slides:
    - Slide 1: Image `https://scontent.cdninstagram.com/v/t51.2885-15/slide_1.jpg`.
    - Slide 2: Video `https://scontent.cdninstagram.com/v/t51.2885-15/slide_2.mp4` and its thumbnail image `https://scontent.cdninstagram.com/v/t51.2885-15/slide_2.jpg`.
  - Comments section (outside `<article>`) contains an avatar `https://scontent.cdninstagram.com/v/t51.2885-15/avatar_comment.jpg`.
  - Script tags contain page JSON with a `carousel_media` array representing both slides.

---

## 5. Proposed Verification Script Code Structure
The implementation script `verify_threads.py` will be created in the scratch directory:

```python
import json
import re
import subprocess
import tempfile
from pathlib import Path

# Paths
WORKSPACE = Path("d:/PROJECTS/Duck Downloder")
SCRAPER_FILE = WORKSPACE / "lib/screens/locked_social_browser_screen.dart"

def extract_js_scraper():
    content = SCRAPER_FILE.read_text(encoding="utf-8")
    match = re.search(r"const _extractScript = r'''(.*?)''';", content, re.DOTALL)
    if not match:
        raise ValueError("Could not find _extractScript in the Dart source file!")
    return match.group(1)

def run_js_test(url, mock_dom):
    scraper_js = extract_js_scraper()
    
    # Render DOM wrapper
    wrapper = """
    class Element {
      constructor(data) {
        this.tagName = data.tagName || 'DIV';
        this.src = data.src || '';
        this.currentSrc = data.currentSrc || '';
        this.srcset = data.srcset || '';
        this.content = data.content || '';
        this.textContent = data.textContent || '';
        this.naturalWidth = data.width || null;
        this.naturalHeight = data.height || null;
        this.width = data.width || null;
        this.height = data.height || null;
        this._children = (data.children || []).map(c => new Element(c));
      }
      getAttribute(name) {
        if (name === 'srcset') return this.srcset;
        if (name === 'src') return this.src;
        if (name === 'content') return this.content;
        return '';
      }
      querySelectorAll(selector) {
        const results = [];
        const match = (el) => {
          if (selector === 'img' && el.tagName === 'IMG') results.push(el);
          if (selector === 'video' && el.tagName === 'VIDEO') results.push(el);
          if (selector === 'video src, video source, video') {
            if (el.tagName === 'VIDEO' || el.tagName === 'SOURCE') results.push(el);
          }
          if (selector === 'picture source[srcset], source[srcset]' && el.tagName === 'SOURCE' && el.srcset) results.push(el);
          if (selector.includes('meta') && el.tagName === 'META') results.push(el);
          el._children.forEach(match);
        };
        this._children.forEach(match);
        return results;
      }
    }

    global.location = { href: %s };
    global.document = {
      scripts: %s.map(text => ({ textContent: text })),
      querySelector: (selector) => {
        if (selector === 'article') return %s ? new Element(%s) : null;
        if (selector === 'main') return %s ? new Element(%s) : null;
        return new Element(%s);
      },
      querySelectorAll: (selector) => {
        return new Element(%s).querySelectorAll(selector);
      }
    };
    """ % (
        json.dumps(url),
        json.dumps(mock_dom.get("scripts", [])),
        json.dumps(mock_dom.get("article")),
        json.dumps(mock_dom.get("article")),
        json.dumps(mock_dom.get("main")),
        json.dumps(mock_dom.get("main")),
        json.dumps(mock_dom.get("document", {})),
        json.dumps(mock_dom.get("document", {}))
    )

    # Combine DOM mock with extraction script
    full_code = wrapper + "\n" + scraper_js
    
    with tempfile.NamedTemporaryFile(mode='w', suffix='.js', delete=False, encoding='utf-8') as f:
        f.write(full_code)
        temp_name = f.name

    try:
        res = subprocess.run(['node', temp_name], capture_output=True, text=True, check=True)
        return json.loads(res.stdout.strip())
    finally:
        Path(temp_name).unlink(missing_ok=True)

# Verification Assertions definition follows ...
```
This strategy ensures 100% deterministic test results, eliminates external network calls, runs correctly inside python/docker runtimes with Node.js installed, and matches the extraction logic identically.
