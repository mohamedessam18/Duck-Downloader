import re
import json

scratch_dir = r"C:\Users\me548\.gemini\antigravity\brain\564c265c-4e9e-46e7-91b2-a8e99038b851\scratch\\"

for filename in ["script_11.json", "script_16.json"]:
    filepath = scratch_dir + filename
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)
        print(f"Loaded {filename} successfully as JSON.")
    except Exception as e:
        print(f"Error loading {filename} as JSON: {e}")
        continue
    
    # Let's extract any URLs from the raw text
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    
    urls = re.findall(r"https?://[^\s\"'<>)]+", content)
    print(f"{filename} has {len(urls)} URLs")
    for u in urls[:10]:
        print("  -", u)
