# Challenge Report: Threads scraper verification analysis

## Challenge Summary

**Overall risk assessment**: MEDIUM

While the core Python normalization logic and browser scraper are robust under standard scenarios, we found a significant accuracy mismatch in the JS DOM Shim query selector implementation that can lead to incorrect media type classification in test environments.

---

## Challenges

### [Medium] Challenge 1: JS DOM Shim Query Selector Inaccuracy (False Video Classification)

- **Assumption challenged**: The JS DOM Shim's `querySelectorAll` implementation behaves identically to a real browser's CSS selector engine.
- **Attack/Failure scenario**: The mock DOM shim implements `querySelectorAll(selector)` using simple substring matching (e.g., `selector.includes('video')` or `selector.includes('source')`). If the scraper queries for `"video src, video source, video"`, the shim evaluates `selector.includes('video')` to `true` and returns *any* `<source>` element in the DOM tree, including `<source>` tags under `<picture>` tags. If these image sources contain a `src` attribute, they are incorrectly processed by the scraper as video candidates and assigned `isVideo: true`.
- **Blast radius**: Low-impact on production since the real browser uses standard CSS selectors which restrict `<source>` to `<video>` parent context. However, it compromises the fidelity of the test/verification environment itself, potentially causing test failures or false positives when testing HTML containing `<picture>` elements.
- **Mitigation**: Update the JS DOM Shim's `querySelectorAll` implementation to traverse parent hierarchies or match selectors more precisely, ensuring descendant relationships (like `video source`) are respected. For example, check if `node.parent.tagName === 'VIDEO'` before returning it for video queries.

### [Low] Challenge 2: Rejection of Square-ish Preview Images

- **Assumption challenged**: Preview images (from og/meta tags) that are close to square (width and height difference <= 4px) are always profile pictures/avatars.
- **Attack/Failure scenario**: An author might upload a high-resolution, perfectly square image as the main post content. If the scraping script falls back to parsing og/meta preview sources, `should_reject` will evaluate `squareish` and `looks_preview_source()` to `true`, and discard the valid high-resolution square image.
- **Blast radius**: Moderate. The user will fail to download the image if the scraper has to fall back to preview/meta sources.
- **Mitigation**: Ensure preview rejection only targets small square-ish images (e.g. only reject square-ish preview images if width < 500px).

---

## Stress Test Results

### 1. Invalid Inputs (Data URIs, blob URIs, FTP URIs, Profile Pictures)
- **Scenario**: A DOM structure containing invalid image sources (data URIs, blob URIs, ftp URIs, profile picture URLs containing `profile_pic`, `s150x150`, or `logo`).
- **Expected behavior**: All invalid URIs are discarded, and only valid HTTP/HTTPS image links are returned.
- **Actual/Predicted behavior**: Correctly discarded by `BrowserImageCandidate.should_reject` and `normalized()`.
- **Pass/Fail**: PASS

### 2. Isolation of Recommended Images / Comments
- **Scenario**: Recommended images placed outside of the `<article>` tag, commenter avatars inside the `<article>` tag, and small emoji reactions.
- **Expected behavior**: Recommended images outside the article are isolated by `mainContainer` query. Commenter avatars and emojis are discarded by normalization rules (name matching and size thresholds).
- **Actual/Predicted behavior**: Recommended images outside were isolated. Avatars (`commenter_avatar.jpg`) and emojis (size < 150px) were correctly discarded.
- **Pass/Fail**: PASS

### 3. Execution of `verify_threads.py`
- **Scenario**: Running the script `verify_threads.py` using Python.
- **Expected behavior**: All 3 built-in tests (Single Image, Single Video, Mixed Carousel) run and pass their assertions.
- **Actual/Predicted behavior**: Successfully executed and all assertions passed.
- **Pass/Fail**: PASS

### 4. Mock DOM Shim Selector Hierarchy (Vulnerability test)
- **Scenario**: DOM containing a `<picture>` element with a child `<source src="url">`.
- **Expected behavior**: The `<source>` element under `<picture>` is recognized as an image source and NOT as a video.
- **Actual/Predicted behavior**: The mock DOM shim incorrectly matches it under the video selector because the selector includes the word `'video'`. The scraper adds it with `isVideo: true` (falsely classifying it as a video).
- **Pass/Fail**: FAIL (Shim accuracy failure)

---

## Unchallenged Areas

- **Network-level scraping constraints** — Reason not challenged: Operating in CODE_ONLY network mode; no live HTTP requests can be executed. Tests are scoped to DOM extraction and normalization.
