"""CSRF protection for the form (ADR 0005): a double-submit token plus a Fetch Metadata check.

The token is random, set in a `__Host-` cookie (HTTPS only, this host only, not readable by
scripts) and repeated in a hidden form field; a POST must carry both, equal. Browsers also say
where a request comes from in `Sec-Fetch-Site`; anything but `same-origin` is refused.
"""

import hmac
import re
import secrets

COOKIE_NAME = "__Host-csrf"
FIELD_NAME = "csrf_token"
TOKEN_BYTES = 32
_TOKEN = re.compile(r"[A-Za-z0-9_-]{43}")  # 32 bytes, base64url without padding


def new_token() -> str:
    return secrets.token_urlsafe(TOKEN_BYTES)


def is_token(value: str | None) -> bool:
    return value is not None and _TOKEN.fullmatch(value) is not None


def tokens_match(cookie: str | None, field: str | None) -> bool:
    if cookie is None or field is None or not is_token(cookie):
        return False
    return hmac.compare_digest(cookie.encode(), field.encode())


def is_same_origin(sec_fetch_site: str | None) -> bool:
    """Requests without the header (older browsers, non-browser clients) still need the token."""
    return sec_fetch_site is None or sec_fetch_site == "same-origin"
