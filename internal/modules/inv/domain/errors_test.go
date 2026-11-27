// Unit test murni domain MASTER-B: syarat koordinat berpasangan gudang
// (padanan koordinatPasang gudang.service.ts) — tanpa DB.
package domain

import (
	"testing"

	"nexierp/internal/core/errkontrak"
)

func TestKoordinatPasang(t *testing.T) {
	lat := 12.5
	lng := -107.1

	cases := []struct {
		nama     string
		lat, lng *float64
		nIssue   int
		field    string
	}{
		{"keduanya terisi sah", &lat, &lng, 0, ""},
		{"keduanya kosong sah", nil, nil, 0, ""},
		// field = sisi TERISI (verbatim sumber: adaLat ? latitude : longitude).
		{"hanya latitude", &lat, nil, 1, "latitude"},
		{"hanya longitude", nil, &lng, 1, "longitude"},
	}

	for _, c := range cases {
		t.Run(c.nama, func(t *testing.T) {
			issues := []errkontrak.FieldIssue{}
			KoordinatPasang(&issues, c.lat, c.lng)
			if len(issues) != c.nIssue {
				t.Fatalf("jumlah issue = %d, mau %d", len(issues), c.nIssue)
			}
			if c.nIssue > 0 {
				if issues[0].Field != c.field {
					t.Fatalf("field = %s, mau %s", issues[0].Field, c.field)
				}
				if issues[0].Message != "Koordinat harus diisi berpasangan (latitude & longitude)." {
					t.Fatalf("pesan = %q", issues[0].Message)
				}
			}
		})
	}
}

func TestErrTersembunyiParitas404(t *testing.T) {
	g := ErrGudangTersembunyi(42)
	if g.Status != 404 || g.Code != KodeInvTidakDitemukan {
		t.Fatalf("gudang tersembunyi = %d/%s", g.Status, g.Code)
	}
	if g.Detail != "Gudang id 42 tidak ditemukan." {
		t.Fatalf("detail gudang = %q", g.Detail)
	}
	l := ErrLokasiTersembunyi(7)
	if l.Status != 404 || l.Code != KodeInvTidakDitemukan {
		t.Fatalf("lokasi tersembunyi = %d/%s", l.Status, l.Code)
	}
	if l.Detail != "Lokasi id 7 tidak ditemukan." {
		t.Fatalf("detail lokasi = %q", l.Detail)
	}
}
