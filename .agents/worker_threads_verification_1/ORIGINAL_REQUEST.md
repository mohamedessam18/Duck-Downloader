## 2026-07-03T01:56:30Z

You are Worker 1 under the Project Orchestrator.
Your working directory is d:\PROJECTS\Duck Downloder\.agents\worker_threads_verification_1\.
Your mission is to implement a Python verification script inside the scratch directory `C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/` that loads or simulates the HTML content of the three target Threads URLs.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Instructions:
1. Create a Python script named `verify_threads.py` in the scratch directory:
`C:\Users\me548/.gemini/antigravity/brain/564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/`
2. The script must:
   - Extract the JS scraper script (`_extractScript`) dynamically from `lib/screens/locked_social_browser_screen.dart` (located in the workspace `d:\PROJECTS\Duck Downloder`).
   - Define JS DOM shim classes/functions (MockElement, MockDocument, location, Map, Array.from, URL, etc.) that represent the HTML structure and properties queried by the scraper (like querySelector, querySelectorAll, src, srcset, scripts, picture, source, video, etc.).
   - Prepend this DOM shim to the scraper script.
   - For each of the three Threads test cases (Single Image, Single Video, Mixed Carousel), mock the document DOM elements and JSON page scripts to match their respective post structure (e.g. including images inside the article, ignoring avatars/comment elements outside, providing the correct JSON react state, etc., as described in `d:\PROJECTS\Duck Downloder\.agents\orchestrator\synthesis.md`).
   - Execute the combined script using a Python-accessible JS environment. For example, the script can run `node` via Python's `subprocess` (e.g. writing the script and running it, or piping input to `node -e`). Alternatively, try `js2py` as a fallback. (Subprocess Node.js is preferred since it has ES6 support natively).
   - Verify the outputs return exactly what is required:
     - Single Image: extracts exactly 1 image URL (high resolution, no profile pictures or static assets).
     - Single Video: extracts exactly 1 video URL (with `isVideo: true`, no static placeholder images).
     - Mixed Carousel: extracts exactly the main post's images and videos (no duplicates, no comment section avatars, no recommended posts).
3. Test your python script by executing it (run it using `run_command` in your environment to make sure it passes all cases).
4. Document the execution outputs and verify they match the acceptance criteria.
5. Save your progress updates in `progress.md` and write a `handoff.md` report in your working directory when done.
