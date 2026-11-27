// Unit test murni scope MASTER-B: keanggotaan baris dalam keputusan cakupan
// 'storages' (gudang & lokasi — lokasi virtual SELALU tampil) + helper merge
// patch 3-state — tanpa DB.
package service

import (
	"testing"

	"nexierp/internal/modules/inv/repository"
)

func gudangRow(id int64) *repository.GudangRantaiRow {
	return &repository.GudangRantaiRow{GudangRow: repository.GudangRow{ID: id}}
}

func lokasiRow(jenis string, idGudang *int64) *repository.LokasiRow {
	return &repository.LokasiRow{Jenis: jenis, IDInvGudang: idGudang}
}

func TestTerlihatGudang(t *testing.T) {
	row := gudangRow(3)

	if !terlihatGudang(row, nil) {
		t.Fatal("SEMUA (nil) harus lolos")
	}
	deny := &repository.CakupanStorages{Deny: true}
	if terlihatGudang(row, deny) {
		t.Fatal("DENY_ALL tidak boleh lolos")
	}
	daftar := &repository.CakupanStorages{IDs: []int64{1, 3, 9}}
	if !terlihatGudang(row, daftar) {
		t.Fatal("id dalam whitelist harus lolos")
	}
	luar := &repository.CakupanStorages{IDs: []int64{1, 2}}
	if terlihatGudang(row, luar) {
		t.Fatal("id di luar whitelist tidak boleh lolos")
	}
}

func TestTerlihatLokasi(t *testing.T) {
	g3 := int64(3)

	// Lokasi virtual (jenis != INTERNAL) SELALU lolos di semua mode.
	if !terlihatLokasi(lokasiRow("VENDOR", nil), nil) {
		t.Fatal("virtual SEMUA harus lolos")
	}
	if !terlihatLokasi(lokasiRow("CUSTOMER", &g3), &repository.CakupanStorages{Deny: true}) {
		t.Fatal("virtual DENY_ALL harus tetap lolos (keputusan pemilik 2026-11-11)")
	}
	if !terlihatLokasi(lokasiRow("SCRAP", nil), &repository.CakupanStorages{IDs: []int64{1}}) {
		t.Fatal("virtual DAFTAR harus tetap lolos")
	}

	internal := lokasiRow("INTERNAL", &g3)
	if !terlihatLokasi(internal, nil) {
		t.Fatal("INTERNAL SEMUA harus lolos")
	}
	if terlihatLokasi(internal, &repository.CakupanStorages{Deny: true}) {
		t.Fatal("INTERNAL DENY_ALL tidak boleh lolos")
	}
	if !terlihatLokasi(internal, &repository.CakupanStorages{IDs: []int64{3}}) {
		t.Fatal("INTERNAL gudang dalam whitelist harus lolos")
	}
	if terlihatLokasi(internal, &repository.CakupanStorages{IDs: []int64{1}}) {
		t.Fatal("INTERNAL gudang luar whitelist tidak boleh lolos")
	}
	// INTERNAL tanpa gudang (lintas CHECK DB) → tersembunyi bila DAFTAR.
	if terlihatLokasi(lokasiRow("INTERNAL", nil), &repository.CakupanStorages{IDs: []int64{3}}) {
		t.Fatal("INTERNAL tanpa gudang tidak boleh lolos pada DAFTAR")
	}
}

func TestIdDalam(t *testing.T) {
	if !idDalam([]int64{1, 2, 3}, 2) || idDalam([]int64{1, 2, 3}, 9) {
		t.Fatal("idDalam salah")
	}
}

func TestMergePatch3State(t *testing.T) {
	baru := "baru"
	nihil := (*string)(nil)
	lama := "lama"

	if mergeStr(nil, lama) != lama {
		t.Fatal("mergeStr absen harus nilai lama")
	}
	if mergeStr(&baru, lama) != baru {
		t.Fatal("mergeStr terisi harus nilai baru")
	}
	if got := merge3(false, &baru, &lama); *got != lama {
		t.Fatal("merge3 tidak dikirim harus nilai lama")
	}
	if got := merge3(true, &baru, &lama); *got != baru {
		t.Fatal("merge3 dikirim harus nilai baru")
	}
	if got := merge3(true, nil, &lama); got != nil {
		t.Fatal("merge3 null eksplisit harus clear")
	}
	if mergeStatus("", lama) != lama || mergeStatus(baru, lama) != baru {
		t.Fatal("mergeStatus salah")
	}
	_ = nihil
}
