package web

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"regexp"
)

// CSRF protection for the form (ADR 0005): a double-submit token plus a Fetch Metadata check.
//
// The token is random, set in a __Host- cookie (HTTPS only, this host only, not readable by scripts) and
// repeated in a hidden form field; a POST must carry both, equal. Browsers also say where a request comes
// from in Sec-Fetch-Site; anything but same-origin is refused.
const (
	cookieName = "__Host-csrf"
	fieldName  = "csrf_token"
	tokenBytes = 32
)

var tokenPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`) // 32 bytes, base64url without padding

func newToken() string {
	raw := make([]byte, tokenBytes)
	if _, err := rand.Read(raw); err != nil {
		panic("csrf: no randomness available: " + err.Error()) // the Go runtime treats this as fatal too
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

func isToken(value string) bool { return tokenPattern.MatchString(value) }

// tokensMatch compares the cookie with the form field in constant time.
func tokensMatch(cookie, field string) bool {
	if !isToken(cookie) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(cookie), []byte(field)) == 1
}

// sessionToken is the token already in the cookie, else a new one: open tabs keep working after a refusal.
func sessionToken(r *http.Request) string {
	if cookie, err := r.Cookie(cookieName); err == nil && isToken(cookie.Value) {
		return cookie.Value
	}
	return newToken()
}

// sameOrigin accepts requests without the header (older browsers, non-browser clients): they still need the token.
func sameOrigin(r *http.Request) bool {
	site := r.Header.Get("Sec-Fetch-Site")
	return site == "" || site == "same-origin"
}

func csrfCookie(token string) *http.Cookie {
	return &http.Cookie{
		Name:     cookieName,
		Value:    token,
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
	}
}
