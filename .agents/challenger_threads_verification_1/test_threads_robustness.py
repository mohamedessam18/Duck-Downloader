import os
import sys
import json
from pathlib import Path

# Add verify_threads directory to sys.path
verify_threads_dir = r"C:\Users\me548\.gemini\antigravity\brain\564c265c-4e9e-46e7-91b2-a8e99038b851\scratch"
sys.path.insert(0, verify_threads_dir)

try:
    from verify_threads import BrowserImageCandidate, run_js_test, extract_scraper_script
except ImportError as e:
    print(f"Failed to import verify_threads from {verify_threads_dir}: {e}")
    sys.exit(1)

def run_challenge_tests():
    print("Extracting scraper code...")
    scraper_code = extract_scraper_script()
    print("Successfully extracted scraper script.")

    # ----------------------------------------------------
    # Challenge 1: Invalid Inputs (Data URIs, blob URIs, non-http/https URLs, and profile pictures)
    # ----------------------------------------------------
    print("\n--- Challenge 1: Invalid Inputs & Normalization ---")
    url = "https://www.threads.net/@user/post/12345"

    dom_setup_invalid = """
    const article = new MockElement('ARTICLE');
    document.appendChild(article);

    // Data URI image
    const imgData = new MockElement('IMG', {
      src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
      width: 1080,
      height: 1080
    });
    article.appendChild(imgData);

    // Blob URI image
    const imgBlob = new MockElement('IMG', {
      src: "blob:https://www.threads.net/d3b07384-d113-4ec6-a790-fd01f66085a6",
      width: 1080,
      height: 1080
    });
    article.appendChild(imgBlob);

    // FTP URI image
    const imgFtp = new MockElement('IMG', {
      src: "ftp://scontent.cdninstagram.com/image.jpg",
      width: 1080,
      height: 1080
    });
    article.appendChild(imgFtp);

    // Profile picture containing 'profile_pic'
    const imgProfilePic = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/profile_pic.jpg",
      width: 300,
      height: 300
    });
    article.appendChild(imgProfilePic);

    // Profile picture containing 's150x150'
    const imgS150 = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/s150x150/avatar.jpg",
      width: 300,
      height: 300
    });
    article.appendChild(imgS150);

    // Logo image (contains 'logo')
    const imgLogo = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/logo.png",
      width: 300,
      height: 300
    });
    article.appendChild(imgLogo);

    // Valid main post image
    const imgValid = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/main_post_image.jpg",
      width: 1080,
      height: 1080
    });
    article.appendChild(imgValid);
    """

    raw_output = run_js_test(url, dom_setup_invalid, scraper_code)
    candidates_raw = json.loads(raw_output)
    
    print(f"Scraper returned {len(candidates_raw)} raw candidates from DOM.")
    normalized = BrowserImageCandidate.normalize_all(candidates_raw)
    print(f"After normalization, {len(normalized)} candidates remain.")
    for cand in normalized:
        print(f"  - Accepted URL: {cand.url}")

    # Check if the normalization logic successfully rejected all invalid ones
    accepted_urls = [cand.url for cand in normalized]
    
    # We expect only the valid main post image to remain
    assert "https://scontent.cdninstagram.com/main_post_image.jpg" in accepted_urls, "Valid image was incorrectly discarded"
    
    # Check that data URI, blob URI, and ftp URI are NOT in accepted URLs
    for url_str in accepted_urls:
        assert not url_str.startswith("data:"), f"Data URI accepted: {url_str}"
        assert not url_str.startswith("blob:"), f"Blob URI accepted: {url_str}"
        assert not url_str.startswith("ftp:"), f"FTP URI accepted: {url_str}"
        assert "profile_pic" not in url_str, f"Profile pic accepted: {url_str}"
        assert "s150x150" not in url_str, f"S150x150 pic accepted: {url_str}"
        assert "logo" not in url_str, f"Logo accepted: {url_str}"

    print("Challenge 1 Passed: Invalid inputs and normalization rejection rules are working correctly.")

    # ----------------------------------------------------
    # Challenge 2: DOM Shim & Isolation of recommended images / comment section avatars
    # ----------------------------------------------------
    print("\n--- Challenge 2: DOM Shim & Isolation ---")
    
    # Scenario A: Recommended images outside of article / main
    dom_setup_isolation = """
    const article = new MockElement('ARTICLE');
    document.appendChild(article);

    const imgValid = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/main_post_image.jpg",
      width: 1080,
      height: 1080
    });
    article.appendChild(imgValid);

    // Recommended posts (outside article/main)
    const recommendedContainer = new MockElement('DIV', { id: "recommended" });
    document.appendChild(recommendedContainer);
    
    const imgRec = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/recommended_ad.jpg",
      width: 800,
      height: 800
    });
    recommendedContainer.appendChild(imgRec);
    """

    raw_output = run_js_test(url, dom_setup_isolation, scraper_code)
    candidates_raw = json.loads(raw_output)
    
    print(f"Scraper returned {len(candidates_raw)} raw candidates.")
    # Check if recommended_ad.jpg is returned
    urls = [c['url'] for c in candidates_raw]
    assert "https://scontent.cdninstagram.com/recommended_ad.jpg" not in urls, "Recommended image outside article was not isolated!"
    print("Sub-test A: Recommended images outside 'article' are successfully isolated by querySelector('article').")

    # Scenario B: Comment section avatars inside the article (e.g. comment thread or reply inline)
    dom_setup_comments = """
    const article = new MockElement('ARTICLE');
    document.appendChild(article);

    const imgValid = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/main_post_image.jpg",
      width: 1080,
      height: 1080
    });
    article.appendChild(imgValid);

    // Commenter avatar inside the article (e.g. in a comment element inside the post layout)
    const commenterAvatar = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/commenter_avatar.jpg",
      width: 150,
      height: 150
    });
    article.appendChild(commenterAvatar);

    // Small emoji reaction image inside the article
    const emojiImg = new MockElement('IMG', {
      src: "https://scontent.cdninstagram.com/emoji_heart.png",
      width: 32,
      height: 32
    });
    article.appendChild(emojiImg);
    """

    raw_output = run_js_test(url, dom_setup_comments, scraper_code)
    candidates_raw = json.loads(raw_output)
    normalized = BrowserImageCandidate.normalize_all(candidates_raw)
    
    accepted_urls = [cand.url for cand in normalized]
    print(f"Normalized candidates from comments setup: {accepted_urls}")
    
    # We expect commenter_avatar.jpg to be rejected because of 'avatar' in the URL, and emoji_heart.png rejected because of size < 150
    assert "https://scontent.cdninstagram.com/commenter_avatar.jpg" not in accepted_urls, "Commenter avatar was not rejected by normalization"
    assert "https://scontent.cdninstagram.com/emoji_heart.png" not in accepted_urls, "Small emoji image was not rejected by size filter"
    print("Sub-test B: Avatars and emoji reactions inside the article are successfully rejected by normalization rules.")

    # Scenario C: Picture source mock DOM shim selector vulnerability
    # If a picture contains <source src="https://scontent.cdninstagram.com/pic_source.jpg">
    # The selector check in querySelectorAll matches 'video src, video source, video' using simple string inclusion.
    # It checks if selector contains 'video', and if so, matches any 'SOURCE' node.
    dom_setup_pic_source = """
    const article = new MockElement('ARTICLE');
    document.appendChild(article);

    const pic = new MockElement('PICTURE');
    article.appendChild(pic);

    const source = new MockElement('SOURCE', {
      src: "https://scontent.cdninstagram.com/pic_source.jpg",
      srcset: "https://scontent.cdninstagram.com/pic_source.jpg 1080w"
    });
    pic.appendChild(source);
    """

    raw_output_pic = run_js_test(url, dom_setup_pic_source, scraper_code)
    candidates_raw_pic = json.loads(raw_output_pic)
    print(f"Scraper returned candidates for picture source: {candidates_raw_pic}")
    
    # Let's see if the candidate has isVideo: true
    is_video_list = [c['isVideo'] for c in candidates_raw_pic if 'pic_source.jpg' in c['url']]
    print(f"Is video list for picture source candidate: {is_video_list}")
    if any(is_video_list):
        print("WARNING: Picture source element was incorrectly classified as a video in the mock DOM environment!")
    else:
        print("Picture source element was not classified as video (perhaps no src was matched).")


    # ----------------------------------------------------
    # Challenge 3: Small size and aspect ratio rejection rules
    # ----------------------------------------------------
    print("\n--- Challenge 3: Small Size and Aspect Ratio Rejection ---")
    
    # Case 1: Image size < 150 width or height
    cand_small_w = BrowserImageCandidate("https://scontent.cdninstagram.com/small_w.jpg", width=149, height=300, source='img')
    cand_small_h = BrowserImageCandidate("https://scontent.cdninstagram.com/small_h.jpg", width=300, height=149, source='img')
    cand_ok_size = BrowserImageCandidate("https://scontent.cdninstagram.com/ok_size.jpg", width=150, height=150, source='img')
    
    assert cand_small_w.should_reject, "Expected image with width < 150 to be rejected"
    assert cand_small_h.should_reject, "Expected image with height < 150 to be rejected"
    assert not cand_ok_size.should_reject, "Expected 150x150 image from 'img' source to not be rejected"
    print("Size threshold (< 150px) checks passed.")

    # Case 2: Square-ish preview source rejection
    # If it is from a preview source (e.g. meta/og) and is square-ish (width - height <= 4), it should reject (usually represents profile pictures in meta tags)
    cand_preview_square = BrowserImageCandidate("https://scontent.cdninstagram.com/preview_sq.jpg", width=200, height=200, source='meta', is_preview=True)
    cand_preview_non_square = BrowserImageCandidate("https://scontent.cdninstagram.com/preview_rect.jpg", width=1200, height=630, source='meta', is_preview=True)
    
    assert cand_preview_square.should_reject, "Expected square-ish preview image to be rejected"
    assert not cand_preview_non_square.should_reject, "Expected non-square preview image to be accepted"
    print("Square-ish preview source rejection check passed.")

    print("\nAll challenge tests completed successfully and verified robust behavior!")

if __name__ == "__main__":
    run_challenge_tests()
