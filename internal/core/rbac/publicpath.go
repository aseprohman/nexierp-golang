package rbac

import "strings"

// PublicAllowlist — endpoint publik TANPA sesi; pencocokan EKSAK setelah
// normalisasi path (tanpa prefix `/api`, tanpa query, tanpa trailing slash).
// Padanan PUBLIC_ALLOWLIST permissions.guard.ts NestJS.
var PublicAllowlist = []string{
	"/health",
	"/auth/login",
	"/auth/register",
	"/auth/refresh",
}

// allowSet — set eksak allowlist.
var allowSet = func() map[string]struct{} {
	m := make(map[string]struct{}, len(PublicAllowlist))
	for _, p := range PublicAllowlist {
		m[p] = struct{}{}
	}
	return m
}()

// publicPatterns — entri allowlist ber-parameter (`:param`) per segmen.
var publicPatterns = func() (out []string) {
	for _, p := range PublicAllowlist {
		if strings.Contains(p, ":") {
			out = append(out, p)
		}
	}
	return
}()

// IsPublicPath — path publik: set eksak dulu, lalu pola ber-parameter —
// segmen `:xxx` pada entri cocok SATU segmen non-kosong apa pun.
func IsPublicPath(path string) bool {
	if _, ok := allowSet[path]; ok {
		return true
	}
	for _, pattern := range publicPatterns {
		ps := strings.Split(pattern, "/")
		xs := strings.Split(path, "/")
		if len(ps) != len(xs) {
			continue
		}
		if MatchSegments(ps, xs) {
			return true
		}
	}
	return false
}

// SplitSegments — pecah path/pattern jadi segmen non-kosong: leading &
// trailing slash hilang (trailing slash otomatis diabaikan).
func SplitSegments(pathOrPattern string) []string {
	parts := strings.Split(pathOrPattern, "/")
	out := make([]string, 0, len(parts))
	for _, s := range parts {
		if len(s) > 0 {
			out = append(out, s)
		}
	}
	return out
}

// MatchSegments — cocokkan segmen pattern vs segmen path: `:param` menerima
// segmen non-kosong apa pun, selain itu eksak. Pemanggil yang sudah memecah
// via SplitSegments dijamin non-kosong; pemanggil strings.Split (allowlist)
// mendapat cek non-kosong di sini.
func MatchSegments(pattern, path []string) bool {
	if len(pattern) != len(path) {
		return false
	}
	for i, p := range pattern {
		if strings.HasPrefix(p, ":") {
			if path[i] == "" {
				return false
			}
			continue
		}
		if p != path[i] {
			return false
		}
	}
	return true
}

// countParamSegments — jumlah segmen `:` (kunci precedence registry:
// literal dicoba lebih dulu).
func countParamSegments(segments []string) (n int) {
	for _, s := range segments {
		if strings.HasPrefix(s, ":") {
			n++
		}
	}
	return n
}
