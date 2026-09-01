from pathlib import Path
from urllib.parse import urlparse
import re



ADULT_DOMAINS = {
    "pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com", "redtube.com",
    "youporn.com", "spankbang.com", "chaturbate.com", "stripchat.com",
    "livejasmin.com", "bongacams.com", "camsoda.com", "eporner.com",
    "hqporner.com", "tnaflix.com", "beeg.com", "tube8.com", "motherless.com",
    "fapello.com", "coomer.party", "coomer.su", "kemono.party", "kemono.su",
    "nhentai.net", "hanime.tv", "hentaihaven.xxx", "daftsex.com", "javhd.com",
    "javlibrary.com", "javbus.com", "missav.com", "javdb.com", "heavy-r.com",
    "thumbzilla.com", "brazzers.com", "bangbros.com", "nuvid.com",
    "sunporno.com", "rule34.xxx", "rule34.paheal.net", "gelbooru.com",
    "danbooru.donmai.us", "e621.net", "realbooru.com", "txxx.com",
    "hclips.com", "youjizz.com", "porndoe.com", "porn300.com", "porn555.com",
    "pornhat.com", "empflix.com", "redgifs.com", "erome.com", "x-art.com",
    "twistys.com", "lustery.com", "manyvids.com", "clips4sale.com",
    "camwhores.tv", "adultwork.com", "escortdirectory.com", "playboy.com",
    "penthouse.com", "hustler.com", "vporn.com", "bravoteens.tv",
}

ADULT_KEYWORDS = [
    r"\bporn\b", r"\bxxx\b", r"\bnsfw\b", r"\bhentai\b", r"\berotic\b",
    r"\bsexvideo\b", r"\bcamgirl\b", r"\bcamgirls\b", r"\bjav\b",
    r"\bblowjob\b", r"\bcreampie\b", r"\bgangbang\b", r"\bmilf\b",
    r"\banal\b", r"\bmasturbat\w*", r"\bhardcore\b", r"\berome\b",
    r"\brule34\b", r"\bx-rated\b", r"\bsex\b",
]

ADULT_KEYWORD_REGEX = re.compile("|".join(ADULT_KEYWORDS), re.IGNORECASE)


def is_adult_content(url_or_text: str) -> bool:
    """Check if a URL or metadata string refers to adult/pornographic content."""
    if not url_or_text:
        return False
    lower = url_or_text.lower()
    parsed = urlparse(url_or_text) if "://" in url_or_text else None
    
    if parsed and parsed.netloc:
        host = parsed.netloc.lower()
        if host.startswith("www."):
            host = host[4:]
        for adult_domain in ADULT_DOMAINS:
            if host == adult_domain or host.endswith(f".{adult_domain}"):
                return True

    # Check path & query if it's a URL, or full text if plain text
    path_and_query = f"{parsed.path} {parsed.query}" if parsed else lower
    # Replace separators like _, -, ?, =, &, / with space so word boundary \b works reliably
    normalized_text = re.sub(r'[^a-zA-Z0-9]', ' ', path_and_query)
    if ADULT_KEYWORD_REGEX.search(normalized_text):
        return True
        
    return False


def validate_not_adult_content(url_or_text: str) -> None:
    if is_adult_content(url_or_text):
        raise ValueError("المحتوى الإباحي غير مدعوم نهائياً / Adult and sexually explicit content is not supported.")


def validate_public_url(raw_url: str) -> None:
    parsed = urlparse(raw_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("Only public http/https URLs are supported.")
    host = parsed.hostname or ""
    blocked_hosts = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}
    if host.lower() in blocked_hosts or host.startswith("10.") or host.startswith("192.168."):
        raise ValueError("Private or local URLs are not supported.")
    validate_not_adult_content(raw_url)


def sanitize_filename(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]+', "_", value).strip(" .")
    return cleaned[:140] or "duck_download"


def ensure_inside(base: Path, target: Path) -> Path:
    resolved_base = base.resolve()
    resolved_target = target.resolve()
    if resolved_base not in resolved_target.parents and resolved_base != resolved_target:
        raise ValueError("Path traversal detected.")
    return resolved_target

