// mastera_body.go — parser body fitur MASTER-A — bentuk & PESAN issue PERSIS
// skema zod packages/schemas/src/inv/schemas.ts (urutan field deklarasi;
// default zod diterapkan; pesan custom verbatim; refine hanya pada skema
// yang memilikinya). Primitif + mode di mastera_validasi.go.
package handler

import (
	"strconv"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
)

const (
	maPesanSkuWajib   = "SKU wajib."
	maPesanSkuRegex   = "SKU: huruf/angka/. _ -"
	maPesanNamaProduk = "Nama produk wajib."
	maPesanNamaInduk  = "Nama induk wajib."
	maPesanMaksStok   = "Stok maksimum harus lebih besar dari stok minimum."
	maPesanJasaStok   = "Jasa tidak menjejak stok (tanpa gerakan)."
)

var maMin0 = int64(0)

func maItoa(n int) string { return strconv.Itoa(n) }

// maF0 — float64(0) alamat utk default urutan.
/* ================================================================== */
/* PRODUK                                                             */
/* ================================================================== */

// maParseProdukBuat — produkCreateSchema (+2 refine verbatim).
func maParseProdukBuat(m map[string]any, issues *[]errkontrak.FieldIssue) (service.ProdukBuatInput, *service.VarianEntryInput) {
	var in service.ProdukBuatInput
	in.KodeProduk, _ = maZodString(m, "kodeProduk", 1, 50, maPesanSkuWajib, maPesanSkuRegex, maReKodeKode, true, maModeWajib, issues)
	in.Nama, _ = maZodString(m, "nama", 1, 100, maPesanNamaProduk, "", nil, true, maModeWajib, issues)
	if tipe, ada := maZodEnum(m, "tipe", maEnumTipeProduk, maModeDefault, issues); ada {
		in.Tipe = tipe
	} else {
		in.Tipe = "BARANG"
	}
	in.IDInvKategoriProduk, _ = maZodIDRef(m, "idInvKategoriProduk", maModeWajib, issues)
	in.IDInvUnitUkur, _ = maZodIDRef(m, "idInvUnitUkur", maModeWajib, issues)
	if b, ada := maZodBool(m, "jejakStok", maModeDefault, issues); ada {
		in.JejakStok = b
	} else {
		in.JejakStok = true
	}
	if s, ada := maZodString(m, "barcode", 0, 50, "", "", nil, true, maModeNullish, issues); ada {
		v := s
		in.Barcode = &v
	}
	if f, ada := maZodMoney(m, "hargaJual", maModeNullish, issues); ada {
		in.HargaJual = &f
	}
	if f, ada := maZodMoney(m, "hargaBiaya", maModeNullish, issues); ada {
		in.HargaBiaya = &f
	}
	if f, ada := maZodQtyInt(m, "stokMinimum", &maMin0, "", maModeDefault, issues); ada {
		in.StokMinimum = int32(f)
	} // else default 0 (nilai nol)
	if f, ada := maZodQtyInt(m, "stokMaksimum", &maMin0, "", maModeNullish, issues); ada {
		in.StokMaksimum = int32Ptr(f)
	}
	if b, ada := maZodBool(m, "reorderAktif", maModeDefault, issues); ada {
		in.ReorderAktif = b
	} // else default false
	if b, ada := maZodBool(m, "adalahIndukVarian", maModeDefault, issues); ada {
		in.AdalahIndukVarian = b
	} // else default false
	if f, ada := maZodQtyInt(m, "beratGram", &maMin0, "", maModeNullish, issues); ada {
		in.BeratGram = int32Ptr(f)
	}
	if f, ada := maZodQtyInt(m, "volumeCm3", &maMin0, "", maModeNullish, issues); ada {
		in.VolumeCm3 = int32Ptr(f)
	}
	if s, ada := maZodString(m, "keterangan", 0, 5000, "", "", nil, false, maModeNullish, issues); ada {
		in.Keterangan = &s
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeDefault, issues); ada {
		in.Status = status
	} else {
		in.Status = "AKTIF"
	}

	// varian (nullish object) — D-38.
	if v, ada := m["varian"]; ada && v != nil {
		obj, ok := v.(map[string]any)
		if !ok {
			*issues = append(*issues, maIssue("varian", maMsgBukan("object", maNamaTipeJSON(v))))
		} else {
			varian := &service.VarianEntryInput{}
			varian.IDInvProdukInduk, _ = maZodIDRef(obj, "idInvProdukInduk", maModeWajib, issues)
			varian.Nilai = maParseVarianNilaiItems(obj, issues)
			// Refine stokMaksimum > stokMinimum (path stokMaksimum).
			if in.StokMaksimum != nil && *in.StokMaksimum <= in.StokMinimum {
				*issues = append(*issues, maIssue("stokMaksimum", maPesanMaksStok))
			}
			// Refine jasa tidak menjejak stok (path jejakStok).
			if in.Tipe == "JASA" && in.JejakStok {
				*issues = append(*issues, maIssue("jejakStok", maPesanJasaStok))
			}
			return in, varian
		}
	}
	// Refine di luar varian tetap dijalankan (persis .refine level schema).
	if in.StokMaksimum != nil && *in.StokMaksimum <= in.StokMinimum {
		*issues = append(*issues, maIssue("stokMaksimum", maPesanMaksStok))
	}
	if in.Tipe == "JASA" && in.JejakStok {
		*issues = append(*issues, maIssue("jejakStok", maPesanJasaStok))
	}
	return in, nil
}

// maParseVarianNilaiItems — z.array(varianNilaiItemSchema).min(1).max(20)
// (path ber-index gaya zod: varian.nilai.0.idInvAtribut).
func maParseVarianNilaiItems(obj map[string]any, issues *[]errkontrak.FieldIssue) []service.VarianNilaiItem {
	v, ada := obj["nilai"]
	if !ada || v == nil {
		*issues = append(*issues, maIssue("varian.nilai", maMsgMinArray(1)))
		return nil
	}
	arr, ok := v.([]any)
	if !ok {
		*issues = append(*issues, maIssue("varian.nilai", maMsgBukan("array", maNamaTipeJSON(v))))
		return nil
	}
	if len(arr) < 1 {
		*issues = append(*issues, maIssue("varian.nilai", maMsgMinArray(1)))
	}
	if len(arr) > 20 {
		*issues = append(*issues, maIssue("varian.nilai", maMsgMaxArray(20)))
	}
	out := make([]service.VarianNilaiItem, 0, len(arr))
	for i, item := range arr {
		objItem, ok := item.(map[string]any)
		if !ok {
			*issues = append(*issues, maIssue("varian.nilai."+maItoa(i), maMsgBukan("object", maNamaTipeJSON(item))))
			continue
		}
		idAtribut, adaA := maZodIDRef(objItem, "idInvAtribut", maModeWajib, issues)
		idNilai, adaN := maZodIDRef(objItem, "idInvNilaiAtribut", maModeWajib, issues)
		if !adaA || !adaN {
			continue
		}
		_ = idAtribut
		_ = idNilai
		out = append(out, service.VarianNilaiItem{IDInvAtribut: idAtribut, IDInvNilaiAtribut: idNilai})
	}
	return out
}

// maParseProdukUbah — produkUpdateSchema = base.partial().omit(kodeProduk)
// .extend({version}) — TANPA refine (persis skema).
func maParseProdukUbah(m map[string]any, issues *[]errkontrak.FieldIssue) service.ProdukUbahInput {
	var in service.ProdukUbahInput
	if s, ada := maZodString(m, "nama", 1, 100, maPesanNamaProduk, "", nil, true, maModeOpsional, issues); ada {
		in.Nama = &s
	}
	if tipe, ada := maZodEnum(m, "tipe", maEnumTipeProduk, maModeOpsional, issues); ada {
		in.Tipe = &tipe
	}
	if n, ada := maZodIDRef(m, "idInvKategoriProduk", maModeOpsional, issues); ada {
		in.IDInvKategoriProduk = &n
	}
	if n, ada := maZodIDRef(m, "idInvUnitUkur", maModeOpsional, issues); ada {
		in.IDInvUnitUkur = &n
	}
	if b, ada := maZodBool(m, "jejakStok", maModeOpsional, issues); ada {
		in.JejakStok = &b
	}
	if maAdaKey(m, "barcode") {
		in.BarcodeAda = true
		if s, ada := maZodString(m, "barcode", 0, 50, "", "", nil, true, maModeNullish, issues); ada {
			v := s // null → ada=true, v="" (service NULL-kan — || null)
			in.Barcode = &v
		}
	}
	if maAdaKey(m, "hargaJual") {
		in.HargaJualAda = true
		if f, ada := maZodMoney(m, "hargaJual", maModeNullish, issues); ada {
			in.HargaJual = &f
		}
	}
	if maAdaKey(m, "hargaBiaya") {
		in.HargaBiayaAda = true
		if f, ada := maZodMoney(m, "hargaBiaya", maModeNullish, issues); ada {
			in.HargaBiaya = &f
		}
	}
	if f, ada := maZodQtyInt(m, "stokMinimum", &maMin0, "", maModeOpsional, issues); ada {
		in.StokMinimum = int32Ptr(f)
	}
	if maAdaKey(m, "stokMaksimum") {
		in.StokMaksimumAda = true
		if f, ada := maZodQtyInt(m, "stokMaksimum", &maMin0, "", maModeNullish, issues); ada {
			in.StokMaksimum = int32Ptr(f)
		}
	}
	if b, ada := maZodBool(m, "reorderAktif", maModeOpsional, issues); ada {
		in.ReorderAktif = &b
	}
	if b, ada := maZodBool(m, "adalahIndukVarian", maModeOpsional, issues); ada {
		in.AdalahIndukVarian = &b
	}
	if maAdaKey(m, "beratGram") {
		in.BeratGramAda = true
		if f, ada := maZodQtyInt(m, "beratGram", &maMin0, "", maModeNullish, issues); ada {
			in.BeratGram = int32Ptr(f)
		}
	}
	if maAdaKey(m, "volumeCm3") {
		in.VolumeCm3Ada = true
		if f, ada := maZodQtyInt(m, "volumeCm3", &maMin0, "", maModeNullish, issues); ada {
			in.VolumeCm3 = int32Ptr(f)
		}
	}
	if maAdaKey(m, "keterangan") {
		in.KeteranganAda = true
		if s, ada := maZodString(m, "keterangan", 0, 5000, "", "", nil, false, maModeNullish, issues); ada {
			in.Keterangan = &s
		}
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeOpsional, issues); ada {
		in.Status = &status
	}
	in.Version = maZodVersion(m, issues)
	return in
}

/* ================================================================== */
/* PRODUK INDUK                                                       */
/* ================================================================== */

func maParseIndukBuat(m map[string]any, issues *[]errkontrak.FieldIssue) service.IndukBuatInput {
	var in service.IndukBuatInput
	in.Kode, _ = maZodString(m, "kode", 1, 50, maPesanNamaIndukWajibKode(), maPesanKode, maReKodeKode, true, maModeWajib, issues)
	in.Nama, _ = maZodString(m, "nama", 1, 100, maPesanNamaInduk, "", nil, true, maModeWajib, issues)
	if s, ada := maZodString(m, "deskripsi", 0, 5000, "", "", nil, false, maModeNullish, issues); ada {
		in.Deskripsi = &s
	}
	in.IDInvKategoriProduk, _ = maZodIDRef(m, "idInvKategoriProduk", maModeWajib, issues)
	in.IDInvUnitUkur, _ = maZodIDRef(m, "idInvUnitUkur", maModeWajib, issues)
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeDefault, issues); ada {
		in.Status = status
	} else {
		in.Status = "AKTIF"
	}
	return in
}

func maPesanNamaIndukWajibKode() string { return "Kode induk wajib." }

func maParseIndukUbah(m map[string]any, issues *[]errkontrak.FieldIssue) service.IndukUbahInput {
	var in service.IndukUbahInput
	if s, ada := maZodString(m, "nama", 1, 100, maPesanNamaInduk, "", nil, true, maModeOpsional, issues); ada {
		in.Nama = &s
	}
	if maAdaKey(m, "deskripsi") {
		in.DeskripsiAda = true
		if s, ada := maZodString(m, "deskripsi", 0, 5000, "", "", nil, false, maModeNullish, issues); ada {
			in.Deskripsi = &s
		}
	}
	if n, ada := maZodIDRef(m, "idInvKategoriProduk", maModeOpsional, issues); ada {
		in.IDInvKategoriProduk = &n
	}
	if n, ada := maZodIDRef(m, "idInvUnitUkur", maModeOpsional, issues); ada {
		in.IDInvUnitUkur = &n
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeOpsional, issues); ada {
		in.Status = &status
	}
	in.Version = maZodVersion(m, issues)
	return in
}

// maParseIndukAtributReplace — indukAtributReplaceSchema {items max20,
// version} — item: idInvAtribut wajib, wajib default(true), urutan
// qtySchema.min(0).default(0).
func maParseIndukAtributReplace(m map[string]any, issues *[]errkontrak.FieldIssue) service.IndukAtributReplaceInput {
	var in service.IndukAtributReplaceInput
	v, ada := m["items"]
	if !ada || v == nil {
		*issues = append(*issues, maIssue("items", maMsgRequired))
	} else if arr, ok := v.([]any); !ok {
		*issues = append(*issues, maIssue("items", maMsgBukan("array", maNamaTipeJSON(v))))
	} else {
		if len(arr) > 20 {
			*issues = append(*issues, maIssue("items", maMsgMaxArray(20)))
		}
		for i, item := range arr {
			objItem, ok := item.(map[string]any)
			if !ok {
				*issues = append(*issues, maIssue("items."+maItoa(i), maMsgBukan("object", maNamaTipeJSON(item))))
				continue
			}
			idAtribut, adaA := maZodIDRef(objItem, "idInvAtribut", maModeWajib, issues)
			wajib, adaW := maZodBool(objItem, "wajib", maModeDefault, issues)
			if !adaW {
				wajib = true // z.default(true)
			}
			urutanF, adaU := maZodQtyInt(objItem, "urutan", &maMin0, "", maModeDefault, issues)
			urutan := int32(0)
			if adaU {
				urutan = int32(urutanF)
			}
			if !adaA {
				continue
			}
			in.Items = append(in.Items, service.IndukAtributItem{
				IDInvAtribut: idAtribut, Wajib: wajib, Urutan: urutan,
			})
		}
	}
	in.Version = maZodVersion(m, issues)
	return in
}

// maParseVarianGenerate — varianGenerateSchema {kombinasi min1 max200,
// harga nullish}.
func maParseVarianGenerate(m map[string]any, issues *[]errkontrak.FieldIssue) service.VarianGenerateInput {
	var in service.VarianGenerateInput
	v, ada := m["kombinasi"]
	if !ada || v == nil {
		*issues = append(*issues, maIssue("kombinasi", "Minimal satu kombinasi nilai."))
	} else if arr, ok := v.([]any); !ok {
		*issues = append(*issues, maIssue("kombinasi", maMsgBukan("array", maNamaTipeJSON(v))))
	} else {
		if len(arr) < 1 {
			*issues = append(*issues, maIssue("kombinasi", "Minimal satu kombinasi nilai."))
		}
		if len(arr) > 200 {
			*issues = append(*issues, maIssue("kombinasi", "Maksimal 200 varian per proses."))
		}
		for i, item := range arr {
			objItem, ok := item.(map[string]any)
			if !ok {
				*issues = append(*issues, maIssue("kombinasi."+maItoa(i), maMsgBukan("object", maNamaTipeJSON(item))))
				continue
			}
			idAtribut, adaA := maZodIDRef(objItem, "idInvAtribut", maModeWajib, issues)
			idNilai, adaN := maZodIDRef(objItem, "idInvNilaiAtribut", maModeWajib, issues)
			if !adaA || !adaN {
				continue
			}
			in.Kombinasi = append(in.Kombinasi, service.VarianNilaiItem{
				IDInvAtribut: idAtribut, IDInvNilaiAtribut: idNilai,
			})
		}
	}
	if f, ada := maZodMoney(m, "hargaJual", maModeNullish, issues); ada {
		in.HargaJual = &f
	}
	if f, ada := maZodMoney(m, "hargaBiaya", maModeNullish, issues); ada {
		in.HargaBiaya = &f
	}
	return in
}

/* ================================================================== */
/* KATEGORI                                                           */
/* ================================================================== */

func maParseKategoriBuat(m map[string]any, issues *[]errkontrak.FieldIssue) service.KategoriBuatInput {
	var in service.KategoriBuatInput
	in.Nama, _ = maZodString(m, "nama", 1, 100, "Nama kategori wajib.", "", nil, true, maModeWajib, issues)
	if n, ada := maZodIDRef(m, "idKategoriInduk", maModeNullish, issues); ada {
		in.IDKategoriInduk = int64Ptr(n)
	}
	if v, ada := maZodEnum(m, "metodeValuasi", maEnumMetodeValuasi, maModeDefault, issues); ada {
		in.MetodeValuasi = v
	} else {
		in.MetodeValuasi = "STANDAR"
	}
	if v, ada := maZodEnum(m, "sistemValuasi", maEnumSistemValuasi, maModeDefault, issues); ada {
		in.SistemValuasi = v
	} else {
		in.SistemValuasi = "PERPETUAL"
	}
	if v, ada := maZodEnum(m, "kebijakanPelacakan", maEnumPelacakan, maModeDefault, issues); ada {
		in.KebijakanPelacakan = v
	} else {
		in.KebijakanPelacakan = "TANPA"
	}
	if b, ada := maZodBool(m, "kebijakanKedaluwarsa", maModeDefault, issues); ada {
		in.KebijakanKedaluwarsa = b
	} // else default false
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeDefault, issues); ada {
		in.Status = status
	} else {
		in.Status = "AKTIF"
	}
	return in
}

func maParseKategoriUbah(m map[string]any, issues *[]errkontrak.FieldIssue) service.KategoriUbahInput {
	var in service.KategoriUbahInput
	if s, ada := maZodString(m, "nama", 1, 100, "Nama kategori wajib.", "", nil, true, maModeOpsional, issues); ada {
		in.Nama = &s
	}
	if maAdaKey(m, "idKategoriInduk") {
		in.IDKategoriIndukAda = true
		if n, ada := maZodIDRef(m, "idKategoriInduk", maModeNullish, issues); ada {
			in.IDKategoriInduk = int64Ptr(n)
		}
	}
	if v, ada := maZodEnum(m, "metodeValuasi", maEnumMetodeValuasi, maModeOpsional, issues); ada {
		in.MetodeValuasi = &v
	}
	if v, ada := maZodEnum(m, "sistemValuasi", maEnumSistemValuasi, maModeOpsional, issues); ada {
		in.SistemValuasi = &v
	}
	if v, ada := maZodEnum(m, "kebijakanPelacakan", maEnumPelacakan, maModeOpsional, issues); ada {
		in.KebijakanPelacakan = &v
	}
	if b, ada := maZodBool(m, "kebijakanKedaluwarsa", maModeOpsional, issues); ada {
		in.KebijakanKedaluwarsa = &b
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeOpsional, issues); ada {
		in.Status = &status
	}
	in.Version = maZodVersion(m, issues)
	return in
}

/* ================================================================== */
/* UNIT                                                               */
/* ================================================================== */

func maParseUnitBuat(m map[string]any, issues *[]errkontrak.FieldIssue) service.UnitBuatInput {
	var in service.UnitBuatInput
	in.Kode, _ = maZodString(m, "kode", 1, 50, "Kode unit wajib.", maPesanKode, maReKodeKode, true, maModeWajib, issues)
	in.Nama, _ = maZodString(m, "nama", 1, 100, "Nama unit wajib.", "", nil, true, maModeWajib, issues)
	if s, ada := maZodString(m, "kategoriUom", 1, 50, "", "", nil, true, maModeDefault, issues); ada {
		in.KategoriUom = s
	} else {
		in.KategoriUom = "UNIT"
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeDefault, issues); ada {
		in.Status = status
	} else {
		in.Status = "AKTIF"
	}
	return in
}

func maParseUnitUbah(m map[string]any, issues *[]errkontrak.FieldIssue) service.UnitUbahInput {
	var in service.UnitUbahInput
	if s, ada := maZodString(m, "kode", 1, 50, "Kode unit wajib.", maPesanKode, maReKodeKode, true, maModeOpsional, issues); ada {
		in.Kode = &s
	}
	if s, ada := maZodString(m, "nama", 1, 100, "Nama unit wajib.", "", nil, true, maModeOpsional, issues); ada {
		in.Nama = &s
	}
	if s, ada := maZodString(m, "kategoriUom", 1, 50, "", "", nil, true, maModeOpsional, issues); ada {
		in.KategoriUom = &s
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeOpsional, issues); ada {
		in.Status = &status
	}
	in.Version = maZodVersion(m, issues)
	return in
}

/* ================================================================== */
/* UNIT KONVERSI                                                      */
/* ================================================================== */

// maParseKonversiBuat — unitKonversiCreateSchema (+refine dari ≠ ke, CREATE
// ONLY — pesan verbatim, path idUnitKe).
func maParseKonversiBuat(m map[string]any, issues *[]errkontrak.FieldIssue) service.KonversiBuatInput {
	var in service.KonversiBuatInput
	in.IDUnitDari, _ = maZodIDRef(m, "idUnitDari", maModeWajib, issues)
	in.IDUnitKe, _ = maZodIDRef(m, "idUnitKe", maModeWajib, issues)
	if f, ada := maZodRasio(m, "faktor", maModeWajib, issues); ada {
		in.Faktor = f
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeDefault, issues); ada {
		in.Status = status
	} else {
		in.Status = "AKTIF"
	}
	// refine: idUnitDari !== idUnitKe — 400 pesan verbatim (refine zod
	// tetap berjalan walau field wajib absen — undefined === undefined).
	if in.IDUnitDari == in.IDUnitKe {
		*issues = append(*issues, maIssue("idUnitKe", "Unit asal dan tujuan tidak boleh sama."))
	}
	return in
}

// maParseKonversiUbah — unitKonversiUpdateSchema — base.partial() TANPA
// refine (update TANPA refine → biarkan CHECK DB backstop persis Nest);
// faktor tetap rasioSchema positive.
func maParseKonversiUbah(m map[string]any, issues *[]errkontrak.FieldIssue) service.KonversiUbahInput {
	var in service.KonversiUbahInput
	if n, ada := maZodIDRef(m, "idUnitDari", maModeOpsional, issues); ada {
		in.IDUnitDari = &n
	}
	if n, ada := maZodIDRef(m, "idUnitKe", maModeOpsional, issues); ada {
		in.IDUnitKe = &n
	}
	if f, ada := maZodRasio(m, "faktor", maModeOpsional, issues); ada {
		in.Faktor = &f
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeOpsional, issues); ada {
		in.Status = &status
	}
	in.Version = maZodVersion(m, issues)
	return in
}

/* ================================================================== */
/* KEMASAN                                                            */
/* ================================================================== */

func maParseKemasanBuat(m map[string]any, issues *[]errkontrak.FieldIssue) service.KemasanBuatInput {
	var in service.KemasanBuatInput
	in.IDInvProduk, _ = maZodIDRef(m, "idInvProduk", maModeWajib, issues)
	in.Kode, _ = maZodString(m, "kode", 1, 50, "Kode kemasan wajib.", maPesanKode, maReKodeKode, true, maModeWajib, issues)
	in.Nama, _ = maZodString(m, "nama", 1, 100, "Nama kemasan wajib.", "", nil, true, maModeWajib, issues)
	if s, ada := maZodString(m, "barcode", 0, 50, "", "", nil, true, maModeNullish, issues); ada {
		in.Barcode = &s
	}
	in.IDInvUnitUkur, _ = maZodIDRef(m, "idInvUnitUkur", maModeWajib, issues)
	if f, ada := maZodQtyInt(m, "qtyIsi", nil, "Qty isi kemasan harus > 0.", maModeWajib, issues); ada {
		in.QtyIsi = int32(f)
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeDefault, issues); ada {
		in.Status = status
	} else {
		in.Status = "AKTIF"
	}
	return in
}

func maParseKemasanUbah(m map[string]any, issues *[]errkontrak.FieldIssue) service.KemasanUbahInput {
	var in service.KemasanUbahInput
	if n, ada := maZodIDRef(m, "idInvProduk", maModeOpsional, issues); ada {
		in.IDInvProduk = &n
	}
	if s, ada := maZodString(m, "kode", 1, 50, "Kode kemasan wajib.", maPesanKode, maReKodeKode, true, maModeOpsional, issues); ada {
		in.Kode = &s
	}
	if s, ada := maZodString(m, "nama", 1, 100, "Nama kemasan wajib.", "", nil, true, maModeOpsional, issues); ada {
		in.Nama = &s
	}
	if maAdaKey(m, "barcode") {
		in.BarcodeAda = true
		if s, ada := maZodString(m, "barcode", 0, 50, "", "", nil, true, maModeNullish, issues); ada {
			in.Barcode = &s
		}
	}
	if n, ada := maZodIDRef(m, "idInvUnitUkur", maModeOpsional, issues); ada {
		in.IDInvUnitUkur = &n
	}
	if f, ada := maZodQtyInt(m, "qtyIsi", nil, "Qty isi kemasan harus > 0.", maModeOpsional, issues); ada {
		in.QtyIsi = int32Ptr(f)
	}
	if status, ada := maZodEnum(m, "status", maEnumStatusAktif, maModeOpsional, issues); ada {
		in.Status = &status
	}
	in.Version = maZodVersion(m, issues)
	return in
}

/* ================================================================== */
/* Konversi kecil                                                     */
/* ================================================================== */

func int32Ptr(f float64) *int32 { v := int32(f); return &v }
func int64Ptr(n int64) *int64   { return &n }
