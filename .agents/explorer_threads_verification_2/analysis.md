# Analysis: Threads Media Downloader Verification & Testing

This document presents the exploration, analysis, and recommended verification strategy for the Threads media downloader in Duck Downloader.

---

## 1. Scratch Directory Resource Examination

We examined all files in the scratch directory `C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/`:
1. **`all_urls.txt`**: This contains a list of 421 static URLs (e.g. static assets on `cdninstagram.com`, CSS/JS config URLs, and telemetry endpoints). It does not contain any cached HTML pages, page data, or structures for the three target post URLs.
2. **`script_11.json`**: This is a minified JSON response containing bootloader configuration, current user initial data, static asset domains, and cookie consent settings. There are no post-specific structures or media URLs related to the target URLs.
3. **`script_16.json`**: Similar to `script_11.json`, this contains CSS/theme definitions, regulation error messages, and bootloader definitions. It contains no media URLs or structures for the target posts.
4. **`test_threads.py`**: A simple python script attempting to fetch a live Threads page programmatically using `urllib.request`. In an offline/code-only sandbox (and due to Meta's strict login gates and bot detection), live requests fail or yield login screens instead of post media.
5. **Other files (`fix_consts.py`, `fix_consts.dart`, `test_extract.dart`)**: These relate to unrelated hotfixes and API serialization checks.

**Conclusion on Scratch Resources**: No cached HTML pages, page data, or structured mock payloads for the three target URLs are present in the scratch directory or the workspace. Therefore, the verification script must simulate the HTML and JSON DOM states programmatically.

---

## 2. Scraper Script (`_extractScript`) Analysis

The scraper script `_extractScript` resides in `lib/screens/locked_social_browser_screen.dart` (lines 259–494). 

### Key Mechanisms:
1. **Scope and Target Selection**:
   - The script scopes DOM scanning inside the `<article>` element (representing the main post), falling back to `<main>` or the `document`. This ensures comment section avatars and recommended posts are ignored.
   - It scans DOM elements (`img`, `video`, `source`, `picture`, and `meta` tags) and page scripts (`scanPageData`).
2. **JSON Parsing & Deep Walk (`walkJson`)**:
   - It searches for JSON structures inside `<script>` elements matching keywords like `image_versions2`, `video_versions`, etc.
   - It walks recursively through these structures to locate image and video candidate objects, extracting high-resolution media URLs.
3. **Deduplication and Video Prioritization**:
   - Clean paths are computed using `getCleanPath(url)`, which extracts the base filename (excluding extension, e.g. `4321_n` for both `4321_n.jpg` and `4321_n.mp4`).
   - If a video candidate and an image candidate share the same base name, the video candidate (`isVideo: true`) takes precedence, replacing the image (which is typically a static video thumbnail/placeholder).
   - If two candidates are of the same type, the one with the higher resolution/width is preserved.

### DOM APIs & Environment Requirements:
To execute this script in a non-browser runtime (like a Python process), we must polyfill/mock the following:
- **Global Variables**: `location.href`, `document`.
- **Global Constructors**: `URL`, `Map` (in case of ES5 runtimes), `Array.from` (in case of ES5 runtimes).
- **DOM Traversal & Selection**:
  - `document.querySelector` (for `article`, `main`)
  - `document.querySelectorAll` (for `img`, `source`, `video`, `meta`)
  - `document.scripts` (returning script tags with `textContent` or `text`)
- **Element Properties**:
  - For image nodes: `src`, `srcset`, `currentSrc`, `width`, `height`, `naturalWidth`, `naturalHeight`.
  - For video/source nodes: `src`, `getAttribute('src')`, `getAttribute('srcset')`.
  - For meta nodes: `getAttribute('content')`.

---

## 3. Recommended Verification Strategy

We propose a Python verification script `verify_threads.py` located in the scratch directory. The script will:
1. **Extract the Live Scraper Script**: Read `lib/screens/locked_social_browser_screen.dart` and parse `_extractScript` using regex so that any updates to the app's scraper are tested instantly.
2. **Setup a Mock DOM JSRuntime**:
   - Use **Node.js** via Python's `subprocess` if available (since Node.js natively supports ES6 features like `Map`, `Array.from`, arrow functions, and `URL`).
   - Fallback to **`js2py`** (if installed in the Python environment), injecting custom polyfills for `Map`, `Array.from`, and `URL` to ensure execution compatibility.
3. **Programmatically Construct Mock HTML / DOM States**:
   - Inject helper functions to build mock element structures matching the three target URLs.
4. **Assert Expected Rules**: Run the scraper against each mock DOM and assert output rules.

### JavaScript Mock DOM Shim
The Python script will prepend this JS shim to `_extractScript` before evaluation:

```javascript
// Polyfill Map and Array.from if missing (resilience for js2py / ES5 engines)
if (typeof Map === 'undefined') {
  globalThis.Map = class {
    constructor() { this.store = {}; }
    set(key, val) { this.store[key] = val; return this; }
    get(key) { return this.store[key]; }
    has(key) { return key in this.store; }
    values() { return Object.values(this.store); }
  };
}
if (typeof Array.from === 'undefined') {
  Array.from = function(iterable) {
    if (iterable && typeof iterable.values === 'function') return iterable.values();
    if (Array.isArray(iterable)) return iterable;
    const arr = [];
    for (let item of iterable) arr.push(item);
    return arr;
  };
}
if (typeof URL === 'undefined') {
  globalThis.URL = class {
    constructor(url, base) {
      this.href = url;
      let relative = url;
      if (url.startsWith('http://') || url.startsWith('https://')) {
        const parts = url.split('/');
        this.protocol = parts[0];
        this.host = parts[2];
        this.pathname = '/' + parts.slice(3).join('/').split('?')[0];
      } else if (base) {
        const baseParts = base.split('/');
        const domain = baseParts.slice(0, 3).join('/');
        this.href = url.startsWith('/') ? domain + url : baseParts.slice(0, baseParts.length-1).join('/') + '/' + url;
        const parts = this.href.split('/');
        this.protocol = parts[0];
        this.host = parts[2];
        this.pathname = '/' + parts.slice(3).join('/').split('?')[0];
      } else {
        this.pathname = url.split('?')[0];
      }
    }
  };
}

// Mock DOM Classes
class MockElement {
  constructor(tagName, attributes = {}, textContent = '') {
    this.tagName = tagName.toUpperCase();
    this.attributes = attributes;
    this.textContent = textContent;
  }
  getAttribute(name) { return this.attributes[name] || null; }
  get src() { return this.attributes['src'] || ''; }
  get srcset() { return this.attributes['srcset'] || ''; }
  get currentSrc() { return this.attributes['currentSrc'] || this.src; }
  get width() { return this.attributes['width'] || 0; }
  get height() { return this.attributes['height'] || 0; }
  get naturalWidth() { return this.attributes['naturalWidth'] || this.width; }
  get naturalHeight() { return this.attributes['naturalHeight'] || this.height; }
}

class MockDocument {
  constructor() { this.elements = []; }
  createElement(tag, attrs, textContent) {
    const el = new MockElement(tag, attrs, textContent);
    this.elements.push(el);
    return el;
  }
  querySelector(selector) {
    if (selector === 'article') return this.elements.find(e => e.tagName === 'ARTICLE') || null;
    if (selector === 'main') return this.elements.find(e => e.tagName === 'MAIN') || null;
    return this;
  }
  querySelectorAll(selector) {
    if (selector.includes('img')) return this.elements.filter(e => e.tagName === 'IMG');
    if (selector.includes('picture source[srcset]') || selector.includes('source[srcset]')) {
      return this.elements.filter(e => e.tagName === 'SOURCE' && e.attributes['srcset']);
    }
    if (selector.includes('video')) return this.elements.filter(e => e.tagName === 'VIDEO' || e.tagName === 'SOURCE');
    if (selector.includes('meta')) {
      const matchMeta = (el) => {
        if (el.tagName !== 'META') return false;
        if (selector.includes('og:image') && el.attributes['property'] === 'og:image') return true;
        if (selector.includes('twitter:image') && el.attributes['name'] === 'twitter:image') return true;
        if (selector.includes('og:image:secure_url') && el.attributes['property'] === 'og:image:secure_url') return true;
        if (selector.includes('og:video') && el.attributes['property'] === 'og:video') return true;
        if (selector.includes('og:video:secure_url') && el.attributes['property'] === 'og:video:secure_url') return true;
        if (selector.includes('twitter:player') && el.attributes['name'] === 'twitter:player') return true;
        return false;
      };
      return this.elements.filter(matchMeta);
    }
    return [];
  }
  get scripts() { return this.elements.filter(e => e.tagName === 'SCRIPT'); }
}

const document = new MockDocument();
const location = { href: '' };
```

---

## 4. Test Scenario Configurations & Assertions

### Scenario 1: Single Image
*   **URL**: `https://www.threads.com/@aicreatorbase/post/DaTTBQSFXzk`
*   **DOM Structure**:
    *   `location.href` = `https://www.threads.com/@aicreatorbase/post/DaTTBQSFXzk`
    *   Create `<article>` node.
    *   Create `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/4321_n.jpg?_nc_cat=101" srcset="https://scontent.cdninstagram.com/v/t51.2885-15/4321_n.jpg?_nc_cat=101 640w, https://scontent.cdninstagram.com/v/t51.2885-15/4321_high.jpg?_nc_cat=101 1080w" width="640" height="640">` inside the article.
    *   Create a `<meta property="og:image" content="https://scontent.cdninstagram.com/v/t51.2885-15/4321_n.jpg">` tag.
    *   Create a comment avatar `<img src="https://scontent.cdninstagram.com/v/t51.2885-19/comment_avatar.jpg">` **outside** the article.
*   **Assertions**:
    *   Output list contains exactly **1** candidate.
    *   Candidate URL matches the highest resolution `4321_high.jpg` version.
    *   `isVideo` is `false`.
    *   No profile pictures/comment avatars are returned.

### Scenario 2: Single Video
*   **URL**: `https://www.threads.com/@ahnmedyahya/post/DaTQ9Umjf1N`
*   **DOM Structure**:
    *   `location.href` = `https://www.threads.com/@ahnmedyahya/post/DaTQ9Umjf1N`
    *   Create `<article>` node.
    *   Create `<video src="https://video.cdninstagram.com/v/t16/9876_n.mp4?_nc_cat=102">` inside the article.
    *   Create a video thumbnail placeholder `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/9876_n.jpg?_nc_cat=102" width="640" height="640">` inside the article.
    *   Create `<meta property="og:video" content="https://video.cdninstagram.com/v/t16/9876_n.mp4">` tag.
*   **Assertions**:
    *   Output list contains exactly **1** candidate.
    *   Candidate URL is the `.mp4` video URL.
    *   `isVideo` is `true`.
    *   The thumbnail image (`9876_n.jpg`) is successfully deduplicated/replaced by the video.

### Scenario 3: Mixed Carousel
*   **URL**: `https://www.threads.com/@cataessapromo/post/DaRLOr2jiRX`
*   **DOM Structure**:
    *   `location.href` = `https://www.threads.com/@cataessapromo/post/DaRLOr2jiRX`
    *   Create `<article>` node.
    *   Create Slide 1 image: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/carousel_1.jpg?_nc_cat=103">`
    *   Create Slide 2 video: `<video src="https://video.cdninstagram.com/v/t16/carousel_2.mp4?_nc_cat=103">` and its static image representation `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/carousel_2.jpg?_nc_cat=103">`
    *   Create Slide 3 image: `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/carousel_3.jpg?_nc_cat=103">`
    *   Create `<script>` node containing structured JSON matching the react state format:
        ```json
        {
          "require": [
            ["ScheduledServerJS", "handle", null, [{
              "__bbox": {
                "items": [{
                  "carousel_media": [
                    { "image_versions2": { "candidates": [{"url": "https://scontent.cdninstagram.com/v/t51.2885-15/carousel_1.jpg", "width": 640}] } },
                    { "video_versions": [{"url": "https://video.cdninstagram.com/v/t16/carousel_2.mp4", "width": 1080}], "image_versions2": { "candidates": [{"url": "https://scontent.cdninstagram.com/v/t51.2885-15/carousel_2.jpg", "width": 640}] } },
                    { "image_versions2": { "candidates": [{"url": "https://scontent.cdninstagram.com/v/t51.2885-15/carousel_3.jpg", "width": 640}] } }
                  ]
                }]
              }
            }]]
          ]
        }
        ```
    *   Create recommended post images `<img src="https://scontent.cdninstagram.com/v/t51.2885-15/rec_post.jpg">` **outside** the article.
*   **Assertions**:
    *   Output list contains exactly **3** candidates.
    *   Candidate 1: Image URL `carousel_1.jpg`, `isVideo: false`.
    *   Candidate 2: Video URL `carousel_2.mp4`, `isVideo: true`. (Image `carousel_2.jpg` is discarded).
    *   Candidate 3: Image URL `carousel_3.jpg`, `isVideo: false`.
    *   No recommended posts/avatars are returned.
