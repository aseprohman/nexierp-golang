// Cookie sesi httpOnly dua ruang origin — port persis shared/cookies.ts:
// portal member (Origin ∈ PORTAL_ORIGINS) = `ecom_at`/`ecom_rt`;
// selainnya (backoffice) = `nexierp_at`/`nexierp_rt`. Token TIDAK disimpan
// di localStorage; frontend memakai credentials: "include".
package auth

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"nexierp/internal/core/config"
)

const (
	ATCookie       = "nexierp_at"
	RTCookie       = "nexierp_rt"
	ATCookiePortal = "ecom_at"
	RTCookiePortal = "ecom_rt"
)

// AsalRequest — header `origin` lalu `referer` (origin-nya saja);
// string kosong bila keduanya tidak ada.
func AsalRequest(h http.Header) string {
	origin := strings.TrimSpace(h.Get("Origin"))
	if origin != "" {
		return strings.TrimRight(origin, "/")
	}
	referer := strings.TrimSpace(h.Get("Referer"))
	if referer != "" {
		if u, err := url.Parse(referer); err == nil && u.Host != "" {
			return u.Scheme + "://" + u.Host
		}
	}
	return ""
}

// PrefiksSesi — "ecom" bila asal = portal member (cfg.PortalOrigins),
// "nexierp" selainnya (tanpa Origin = default backoffice).
func PrefiksSesi(cfg *config.Env, h http.Header) string {
	asal := AsalRequest(h)
	if asal == "" {
		return "nexierp"
	}
	for _, p := range cfg.PortalOrigins {
		if strings.TrimRight(p, "/") == asal {
			return "ecom"
		}
	}
	return "nexierp"
}

// NamaCookieAkses — nama cookie access token untuk request ini.
func NamaCookieAkses(cfg *config.Env, h http.Header) string {
	if PrefiksSesi(cfg, h) == "ecom" {
		return ATCookiePortal
	}
	return ATCookie
}

// NamaCookieRefresh — nama cookie refresh token untuk request ini.
func NamaCookieRefresh(cfg *config.Env, h http.Header) string {
	if PrefiksSesi(cfg, h) == "ecom" {
		return RTCookiePortal
	}
	return RTCookie
}

const baseAttrs = "Path=/; HttpOnly; SameSite=Lax"

// serializeCookie — `name=value; <base>; Max-Age=n` + `; Secure` bila
// cfg.CookieSecure (padanan COOKIE_SECURE === "true").
func serializeCookie(cfg *config.Env, name, value string, maxAgeSec int) string {
	secure := ""
	if cfg.CookieSecure {
		secure = "; Secure"
	}
	return name + "=" + value + "; " + baseAttrs + "; Max-Age=" + strconv.Itoa(maxAgeSec) + secure
}

// SessionCookies — dua Set-Cookie setelah login/refresh: access 900 dtk,
// refresh 43200 dtk (port sessionCookies).
func SessionCookies(cfg *config.Env, h http.Header, accessToken, refreshToken string) []string {
	p := PrefiksSesi(cfg, h)
	return []string{
		serializeCookie(cfg, p+"_at", accessToken, 900),
		serializeCookie(cfg, p+"_rt", refreshToken, 43200),
	}
}

// ClearedSessionCookies — cookie kedaluwarsa untuk logout (Max-Age=0,
// SELALU dikirim walau sesi sudah tidak ada).
func ClearedSessionCookies(cfg *config.Env, h http.Header) []string {
	p := PrefiksSesi(cfg, h)
	return []string{
		serializeCookie(cfg, p+"_at", "", 0),
		serializeCookie(cfg, p+"_rt", "", 0),
	}
}

// CookieTokenOf — ambil nilai cookie by name dari header `cookie`
// (padanan cookieTokenOf, termasuk decodeURIComponent).
func CookieTokenOf(h http.Header, name string) string {
	raw := h.Get("Cookie")
	if raw == "" {
		return ""
	}
	for _, part := range strings.Split(raw, ";") {
		part = strings.TrimSpace(part)
		k, v, ok := strings.Cut(part, "=")
		if k == name && ok {
			if decoded, err := url.PathUnescape(v); err == nil {
				return decoded
			}
			return v
		}
	}
	return ""
}

// CookieAksesOf — access token dari cookie RUANG request (guard).
func CookieAksesOf(cfg *config.Env, h http.Header) string {
	return CookieTokenOf(h, NamaCookieAkses(cfg, h))
}

// CookieRefreshOf — refresh token dari cookie RUANG request (refresh).
func CookieRefreshOf(cfg *config.Env, h http.Header) string {
	return CookieTokenOf(h, NamaCookieRefresh(cfg, h))
}
