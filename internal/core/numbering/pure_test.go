// pure_test.go — unit test fungsi murni penomoran (RenderPrefix,
// FormatCode, NewEntityID).
package numbering

import (
	"strings"
	"testing"
	"time"
)

// waktu uji tetap: 2026-10-26T08:00:00Z
var waktuUji = time.Date(2026, 10, 26, 8, 0, 0, 0, time.UTC)

func TestRenderPrefix(t *testing.T) {
	kasus := []struct {
		prefix string
		mau    string
	}{
		{"TRF/{MMyy}", "TRF/1026"},
		{"MV-{mmyy}", "MV-1026"},
		{"JV-{yyyy}", "JV-2026"},
		{"PO", "PO"}, // tanpa template
		{"{MMyy}/{MMyy}", "1026/1026"},
	}
	for _, k := range kasus {
		if got := RenderPrefix(k.prefix, waktuUji); got != k.mau {
			t.Errorf("RenderPrefix(%q) = %q, mau %q", k.prefix, got, k.mau)
		}
	}
}

func TestRenderPrefixUTC(t *testing.T) {
	// basis UTC, bukan zona lokal: 2026-11-01 00:30 WIB = 2026-10-31 17:30 UTC
	// → bulan UTC = 10 (lokal November = 11; render pakai UTC harus 10).
	w := time.Date(2026, 11, 1, 0, 30, 0, 0, time.FixedZone("WIB", 7*3600))
	if got := RenderPrefix("{MMyy}{yyyy}", w); got != "10262026" {
		t.Errorf("RenderPrefix UTC = %q, mau %q", got, "10262026")
	}
}

func TestFormatCode(t *testing.T) {
	kasus := []struct {
		nama string
		a    Allocation
		opt  Options
		mau  string
	}{
		{
			// prefix ber-template → joiner default "/"
			nama: "template MMyy",
			a:    Allocation{Seq: 1, Prefix: "TRF/{MMyy}", Padding: 4},
			opt:  Options{Now: &waktuUji},
			mau:  "TRF/1026/0001",
		},
		{
			// prefix mengandung "/" → joiner default "/"
			nama: "prefix slash",
			a:    Allocation{Seq: 42, Prefix: "TRF/1026", Padding: 4},
			opt:  Options{},
			mau:  "TRF/1026/0042",
		},
		{
			// prefix polos → joiner default "-"
			nama: "prefix polos",
			a:    Allocation{Seq: 1, Prefix: "MV", Padding: 5},
			opt:  Options{},
			mau:  "MV-00001",
		},
		{
			// joiner eksplisit menang
			nama: "joiner eksplisit",
			a:    Allocation{Seq: 7, Prefix: "MV", Padding: 4},
			opt:  Options{Joiner: "#"},
			mau:  "MV#0007",
		},
		{
			// now eksplisit dipakai render; prefix ber "{" → joiner default "/"
			nama: "now eksplisit",
			a:    Allocation{Seq: 9, Prefix: "JV-{yyyy}", Padding: 4},
			opt:  Options{Now: &waktuUji},
			mau:  "JV-2026/0009",
		},
	}
	for _, k := range kasus {
		if got := FormatCode(k.a, k.opt); got != k.mau {
			t.Errorf("%s: FormatCode = %q, mau %q", k.nama, got, k.mau)
		}
	}
}

func TestNewEntityID(t *testing.T) {
	id := NewEntityID()
	if len(id) != 36 || strings.Count(id, "-") != 4 {
		t.Fatalf("NewEntityID bentuk salah: %q", id)
	}
	// versi 4 di posisi 14 dan varian 8/9/A/B di posisi 19
	if id[14] != '4' {
		t.Errorf("versi bukan 4: %q", id)
	}
	switch id[19] {
	case '8', '9', 'a', 'b':
	default:
		t.Errorf("varian salah: %q", id)
	}
	if NewEntityID() == id {
		t.Error("NewEntityID harus unik antar panggilan")
	}
}
