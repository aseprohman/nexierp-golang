package rbac

import "testing"

// TestIsPublicPath — allowlist publik: set eksak + entri ber-segmen `:xxx`
// cocok per segmen (jumlah segmen sama, `:x` = satu segmen non-kosong).
func TestIsPublicPath(t *testing.T) {
	kasus := []struct {
		nama string
		path string
		pub  bool
	}{
		// Set eksak.
		{"health eksak", "/health", true},
		{"login eksak", "/auth/login", true},
		{"register eksak", "/auth/register", true},
		{"refresh eksak", "/auth/refresh", true},
		// Bukan publik — endpoint terlindungi & endpoint tak dikenal.
		{"system users", "/system/users", false},
		{"health suffix", "/health/detail", false},
		{"auth prefix", "/auth/profile", false},
		{"login subpath", "/auth/login/attempts", false},
		{"root", "/", false},
		{"kosong jadi root", "", false},
		// Trailing slash sudah dinormalisasi sebelum masuk sini — path
		// ber-trailing slash TIDAK cocok eksak (matching setelah normalisasi).
		{"health trailing slash", "/health/", false},
		{"case sensitif", "/HEALTH", false},
		{"case sensitif login", "/Auth/Login", false},
	}

	for _, k := range kasus {
		if got := IsPublicPath(k.path); got != k.pub {
			t.Errorf("%s: IsPublicPath(%q) = %v, harap %v", k.nama, k.path, got, k.pub)
		}
	}
}

// TestIsPublicPathPolaParam — entri ber-segmen `:xxx` cocok satu segmen
// non-kosong apa pun; jumlah segmen wajib sama.
func TestIsPublicPathPolaParam(t *testing.T) {
	// Simulasikan allowlist ber-parameter (pola `:x`) — guard memakai satu
	// matcher dengan registry (MatchSegments), jadi uji matcher-nya langsung.
	pola := []string{"", "auth", ":action"}
	if !MatchSegments(pola, []string{"", "auth", "login"}) {
		t.Error("pola `:action` harus cocok segmen `login`")
	}
	if !MatchSegments(pola, []string{"", "auth", "logout"}) {
		t.Error("pola `:action` harus cocok segmen `logout`")
	}
	if MatchSegments(pola, []string{"", "auth", "login", "attempts"}) {
		t.Error("jumlah segmen beda tidak boleh cocok")
	}
	if MatchSegments(pola, []string{"", "auth", ""}) {
		t.Error("segmen `:x` tidak boleh menerima segmen kosong")
	}
	if MatchSegments(pola, []string{"", "authz", "login"}) {
		t.Error("segmen literal `auth` tidak boleh menerima `authz`")
	}
}

// TestSplitSegments — segmen kosong dibuang: leading & trailing slash hilang.
func TestSplitSegments(t *testing.T) {
	kasus := []struct {
		in   string
		want []string
	}{
		{"/system/users/123", []string{"system", "users", "123"}},
		{"/system/users/", []string{"system", "users"}},
		{"system/users", []string{"system", "users"}},
		{"/", []string{}},
		{"", []string{}},
		{"//a//b//", []string{"a", "b"}},
		{"/inv/barang/:id", []string{"inv", "barang", ":id"}},
	}
	for _, k := range kasus {
		got := SplitSegments(k.in)
		if len(got) != len(k.want) {
			t.Errorf("SplitSegments(%q) = %v, harap %v", k.in, got, k.want)
			continue
		}
		for i := range got {
			if got[i] != k.want[i] {
				t.Errorf("SplitSegments(%q)[%d] = %q, harap %q", k.in, i, got[i], k.want[i])
			}
		}
	}
}

// TestCountParamSegments — kunci precedence: literal sebelum param.
func TestCountParamSegments(t *testing.T) {
	if n := countParamSegments(SplitSegments("/inv/barang/detail")); n != 0 {
		t.Errorf("route literal harus 0 param, dapat %d", n)
	}
	if n := countParamSegments(SplitSegments("/inv/barang/:id")); n != 1 {
		t.Errorf("route satu param harus 1, dapat %d", n)
	}
	if n := countParamSegments(SplitSegments("/a/:b/:c")); n != 2 {
		t.Errorf("route dua param harus 2, dapat %d", n)
	}
}
