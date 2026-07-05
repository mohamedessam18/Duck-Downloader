import os

search_terms = ["DaTTBQSFXzk", "DaTQ9Umjf1N", "DaRLOr2jiRX"]
workspace = r"d:\PROJECTS\Duck Downloder"

exclude_dirs = {"build", ".git", ".gradle", ".dart_tool", ".agents"}

found = []

for root, dirs, files in os.walk(workspace):
    # modify dirs in place to exclude unwanted directories
    dirs[:] = [d for d in dirs if d not in exclude_dirs]
    for file in files:
        file_path = os.path.join(root, file)
        try:
            with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
                for term in search_terms:
                    if term in content:
                        found.append((file_path, term))
        except Exception as e:
            pass

print("Search completed. Found:")
for path, term in found:
    print(f"{path}: contains '{term}'")
