## 2026-07-03T02:09:02Z
You are Worker 2 under the Project Orchestrator.
Your working directory is d:\PROJECTS\Duck Downloder\.agents\worker_threads_verification_2\.
Your mission is to improve the Python verification script `verify_threads.py` located at `C:\Users\me548\.gemini\antigravity\brain\564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/verify_threads.py`.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Instructions:
1. Edit `C:\Users\me548\.gemini\antigravity\brain\564c265c-4e9e-46e7-91b2-a8e99038b851/scratch/verify_threads.py` to fix the following issues:
   - **DOM Shim Accuracy**: Update `MockElement` and its `querySelectorAll` implementation to accurately match selectors and prevent false classifications.
     Specifically, when `appendChild(child)` is called, set `child.parent = this`.
     Update the `querySelectorAll(selector)` logic so that:
       - If `selector.includes('video')`: match `VIDEO` elements, or `SOURCE` elements whose parent is a `VIDEO` element (i.e. `node.parent && node.parent.tagName === 'VIDEO'`).
       - If `selector.includes('source') || selector.includes('picture')`: match `PICTURE` elements, or `SOURCE` elements whose parent is NOT a `VIDEO` element (i.e., they are inside a `PICTURE` or have another tag context).
       - Put the check for `'video'` before checking `'source'` to ensure queries for `'video source'` do not fall into the generic source rule.
   - **Hardcoded Path Portability**: Ensure that the lookup for `locked_social_browser_screen.dart` is robust. If `d:\PROJECTS\Duck Downloder\lib\screens\locked_social_browser_screen.dart` is not found, fallback to searching recursively or using standard parent paths from the script file location.
2. Execute the script to make sure it runs successfully and all tests pass.
3. Save your progress updates in `progress.md` and write a `handoff.md` report in your working directory when done.
