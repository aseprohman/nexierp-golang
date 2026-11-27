// Unit test murni cookie dua ruang origin — tanpa DB/framework.
package auth

import (
	"net/http"
	"strings"
	"testing"

	"nexierp/internal/core/config"
)

func cfgTest(portal string, secure bool) *config.Env {
	return &config.Env{
		PortalOrigins: strings.Split(portal, ","),
		CookieSecure:  secure,
	}
}

func header(h map[string]string) http.Header {
	hh := http.Header{}
	for k, v := range h {
		hh.Set(k, v)
	}
	return hh
}

func TestPrefiksSesiPortal(t *testing.T) {
	cfg := cfgTest("http://localhost:3200,https://portal.example.com", false)
	h := header(map[string]string{"Origin": "http://localhost:3200"})
	if PrefiksSesi(cfg, h) != "ecom" {
		t.Fatal("origin portal harus ruang ecom")
	}
	// trailing slash di origin request tetap cocok.
	h2 := header(map[string]string{"Origin": "https://portal.example.com/"})
	if PrefiksSesi(cfg, h2) != "ecom" {
		t.Fatal("origin portal (slash ekor) harus ruang ecom")
	}
}

func TestPrefiksSesiBackoffice(t *testing.T) {
	cfg := cfgTest("http://localhost:3200", false)
	cases := []http.Header{
		header(map[string]string{"Origin": "http://localhost:3000"}),
		header(map[string]string{"Referer": "http://localhost:3000/dashboard"}),
		header(map[string]string{}), // tanpa Origin = default backoffice
	}
	for i, h := range cases {
		if PrefiksSesi(cfg, h) != "nexierp" {
			t.Fatalf("case %d: harus ruang nexierp", i)
		}
	}
}

func TestRefererFallbackPortal(t *testing.T) {
	cfg := cfgTest("http://localhost:3200", false)
	h := header(map[string]string{"Referer": "http://localhost:3200/aktivasi?token=x"})
	if PrefiksSesi(cfg, h) != "ecom" {
		t.Fatal("referer portal harus ruang ecom")
	}
}

func TestNamaCookie(t *testing.T) {
	cfg := cfgTest("http://localhost:3200", false)
	hPortal := header(map[string]string{"Origin": "http://localhost:3200"})
	hWeb := header(map[string]string{})
	if NamaCookieAkses(cfg, hPortal) != ATCookiePortal || NamaCookieRefresh(cfg, hPortal) != RTCookiePortal {
		t.Fatal("cookie portal salah")
	}
	if NamaCookieAkses(cfg, hWeb) != ATCookie || NamaCookieRefresh(cfg, hWeb) != RTCookie {
		t.Fatal("cookie backoffice salah")
	}
}

func TestSessionCookies(t *testing.T) {
	cfg := cfgTest("http://localhost:3200", false)
	h := header(map[string]string{"Origin": "http://localhost:3200"})
	got := SessionCookies(cfg, h, "AT", "RT")
	if len(got) != 2 {
		t.Fatalf("harus 2 cookie, dapat %d", len(got))
	}
	if got[0] != "ecom_at=AT; Path=/; HttpOnly; SameSite=Lax; Max-Age=900" {
		t.Fatalf("cookie access salah: %s", got[0])
	}
	if got[1] != "ecom_rt=RT; Path=/; HttpOnly; SameSite=Lax; Max-Age=43200" {
		t.Fatalf("cookie refresh salah: %s", got[1])
	}
}

func TestSessionCookiesSecure(t *testing.T) {
	cfg := cfgTest("http://localhost:3200", true)
	h := header(map[string]string{})
	got := SessionCookies(cfg, h, "AT", "RT")
	if !strings.HasSuffix(got[0], "; Secure") || !strings.HasSuffix(got[1], "; Secure") {
		t.Fatalf("COOKIE_SECURE=true harus menambah Secure: %v", got)
	}
	if !strings.HasPrefix(got[0], "nexierp_at=") {
		t.Fatalf("default tanpa Origin = nexierp_at: %s", got[0])
	}
}

func TestClearedSessionCookies(t *testing.T) {
	cfg := cfgTest("http://localhost:3200", false)
	h := header(map[string]string{"Origin": "http://localhost:3200"})
	got := ClearedSessionCookies(cfg, h)
	want0 := "ecom_at=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
	want1 := "ecom_rt=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
	if got[0] != want0 || got[1] != want1 {
		t.Fatalf("cookie bersih salah: %v", got)
	}
}

func TestCookieTokenOf(t *testing.T) {
	h := header(map[string]string{"Cookie": "a=1; nexierp_at=TOK.EN; x=y"})
	if got := CookieTokenOf(h, "nexierp_at"); got != "TOK.EN" {
		t.Fatalf("nilai cookie salah: %q", got)
	}
	if got := CookieTokenOf(h, "tak_ada"); got != "" {
		t.Fatalf("cookie tak ada harus kosong: %q", got)
	}
}

func TestCookieAksesRefreshOf(t *testing.T) {
	cfg := cfgTest("http://localhost:3200", false)
	h := header(map[string]string{
		"Origin": "http://localhost:3200",
		"Cookie": "ecom_rt=RTX; ecom_at=ATX",
	})
	if got := CookieAksesOf(cfg, h); got != "ATX" {
		t.Fatalf("cookie akses portal salah: %q", got)
	}
	if got := CookieRefreshOf(cfg, h); got != "RTX" {
		t.Fatalf("cookie refresh portal salah: %q", got)
	}
	// ruang backoffice — nexierp_at/nexierp_rt.
	h2 := header(map[string]string{"Cookie": "nexierp_at=ATB; nexierp_rt=RTB"})
	if got := CookieAksesOf(cfg, h2); got != "ATB" {
		t.Fatalf("cookie akses backoffice salah: %q", got)
	}
}
