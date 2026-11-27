// Package domain — aturan bisnis MURNI fitur wilayah modul core (tanpa
// framework/DB): guard prefix kode anak, versi bentrok, kode duplikat,
// kode dipakai child, child hidup saat hapus, tidak ditemukan — pesan &
// kode error WLY VERBATIM WilayahAdminService NestJS (422 WLY-001, 409
// WLY-002/003/004, 404 WLY-005).
package domain

import (
	"fmt"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/types"
)

// TolakPrefixAnak — prefix kode anak WAJIB = kode induk (struktur Kepmendagri
// berjenjang: kota startsWith provinsi, kecamatan startsWith kota, kelurahan
// startsWith kecamatan) — 422 WLY-001.
func TolakPrefixAnak(labelAnak, kodeAnak, labelInduk, kodeInduk string) error {
	if !startsWith(kodeAnak, kodeInduk) {
		return errkontrak.Unprocessable(
			fmt.Sprintf(
				"Kode %s '%s' harus diawali kode %s induk '%s' (WLY-001).",
				lower(labelAnak), kodeAnak, labelInduk, kodeInduk,
			),
			types.WLYParamTidakSah,
		)
	}
	return nil
}

// VersiBentrok — versi kirim ≠ server → error WLY-002; cocok → nil.
func VersiBentrok(label, kode string, versiServer int32, versiKirim int64) error {
	if int64(versiServer) != versiKirim {
		return ErrVersi(label, kode, versiServer, &versiKirim)
	}
	return nil
}

// ErrVersi — versi bentrok — 409 WLY-002 (versiKirim nil = tanpa bagian
// ", kirim N" — race update/soft-delete).
func ErrVersi(label, kode string, versiServer int32, versiKirim *int64) error {
	detail := fmt.Sprintf("server %d", versiServer)
	if versiKirim != nil {
		detail = fmt.Sprintf("server %d, kirim %d", versiServer, *versiKirim)
	}
	return errkontrak.Conflict(
		fmt.Sprintf(
			"Versi %s '%s' tidak cocok (%s) — muat ulang lalu ulangi (WLY-002).",
			lower(label), kode, detail,
		),
		types.WLYVersiBentrok,
	)
}

// TolakKodeDipakaiChild — kode induk diubah padahal masih dipakai child —
// 422 WLY-001 (ubah child lebih dulu).
func TolakKodeDipakaiChild(label, kode string, n int32, labelChild string) error {
	return errkontrak.Unprocessable(
		fmt.Sprintf(
			"Kode %s '%s' dipakai %d %s — ubah child lebih dulu (WLY-001).",
			lower(label), kode, n, labelChild,
		),
		types.WLYParamTidakSah,
	)
}

// ErrChildHidup — soft delete ditolak bila masih punya child hidup —
// 409 WLY-003 (pesan pakai NAMA baris, bukan kode).
func ErrChildHidup(label, nama string, n int32, labelChild string) error {
	return errkontrak.Conflict(
		fmt.Sprintf(
			"%s '%s' masih punya %d %s — hapus child lebih dulu (WLY-003).",
			label, nama, n, labelChild,
		),
		types.WLYTerpakai,
	)
}

// ErrDuplikat — kode hidup duplikat (pre-check + race 23505) — 409 WLY-004.
func ErrDuplikat(label, kode string) error {
	return errkontrak.Conflict(
		fmt.Sprintf(
			"Kode %s '%s' sudah dipakai baris hidup lain (WLY-004).",
			lower(label), kode,
		),
		types.WLYKodeDuplikat,
	)
}

// ErrTidakDitemukan — baris/induk tidak ditemukan atau ter-soft-delete —
// 404 WLY-005.
func ErrTidakDitemukan(label string, id int64) error {
	return errkontrak.NotFound(
		fmt.Sprintf("%s id %d tidak ditemukan (WLY-005).", label, id),
		types.WLYTidakDitemukan,
	)
}

// startsWith — padanan String.prototype.startsWith.
func startsWith(s, prefix string) bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

// lower — padanan toLowerCase() untuk label ASCII (Provinsi/Kota/…).
func lower(s string) string {
	out := []byte(s)
	for i, c := range out {
		if c >= 'A' && c <= 'Z' {
			out[i] = c + ('a' - 'A')
		}
	}
	return string(out)
}
