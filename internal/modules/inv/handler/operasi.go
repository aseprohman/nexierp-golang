// Handler OPERASI-LAIN modul inv — SATU pendaftar utk 4 fitur (dokumen
// mutasi barang +dari GR, penyesuaian stok +barcode, picking, jadwal
// hitung): padanan MutasiController + PenyesuaianController +
// PickingController + JadwalHitungController NestJS. Permukaan HTTP murni
// (Echo): decode body → validasi zod-ekuivalen (pesan VERBATIM
// packages/schemas/src/inv/schemas.ts, gaya pesan default zod 3.25) →
// delegasi service → pemetaan error errkontrak (problem+json). Tanpa query
// SQL, tanpa aturan bisnis. Route statis dideklarasikan SEBELUM ":id"
// (gr-eligible, dari-gr, barcode/:kode — persis urutan controller sumber).
package handler

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf16"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/auth"
	"nexierp/internal/core/errkontrak"
	coreshared "nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// DaftarkanOperasiLain — pasang SEMUA route operasi-lain di bawah group
// /api (path tanpa prefix /api; guard JWT + RBAC route-centric). Dipanggil
// DaftarkanOperasi (module.go — wiring satu pintu modul inv).
func DaftarkanOperasiLain(api *echo.Group, d types.Deps) {
	h := &operasiHandler{
		mutasi:      service.NewMutasiService(d),
		penyesuaian: service.NewPenyesuaianService(d),
		picking:     service.NewPickingService(d),
		jadwal:      service.NewJadwalService(d),
	}

	// MUTASI — dokumen mutasi barang (patch 07/D-45 + dari GR patch 59).
	m := api.Group("/inventory/operasi/mutasi", d.AuthGuard, d.RbacGuard)
	m.GET("", h.mutasiList)
	m.POST("", h.mutasiCreate)
	m.GET("/gr-eligible", h.mutasiGrEligible) // SEBELUM ":id" — tak tertelan param
	m.POST("/dari-gr", h.mutasiDariGr)
	m.GET("/:id", h.mutasiGet)
	m.PATCH("/:id", h.mutasiUpdate)
	m.POST("/:id/ajukan", h.mutasiAjukan)
	m.POST("/:id/keputusan", h.mutasiKeputusan)
	m.POST("/:id/batal", h.mutasiBatal)
	m.DELETE("/:id", h.mutasiRemove)

	// PENYESUAIAN — dokumen penyesuaian/cycle count/scrap (INV-F08/F12).
	p := api.Group("/inventory/operasi/penyesuaian", d.AuthGuard, d.RbacGuard)
	p.GET("", h.penyesuaianList)
	p.POST("", h.penyesuaianCreate)
	p.GET("/barcode/:kode", h.penyesuaianBarcode) // WAJIB sebelum ":id"
	p.GET("/:id", h.penyesuaianGet)
	p.PATCH("/:id", h.penyesuaianUpdate)
	p.POST("/:id/ajukan", h.penyesuaianAjukan)
	p.POST("/:id/keputusan", h.penyesuaianKeputusan)
	p.POST("/:id/batal", h.penyesuaianBatal)

	// PICKING — agregat kerja per nomor_dokumen (tanpa tabel; D-07/D-25).
	pk := api.Group("/inventory/operasi/picking", d.AuthGuard, d.RbacGuard)
	pk.GET("", h.pickingList)
	pk.GET("/:nomorDokumen", h.pickingGet)
	pk.POST("/:nomorDokumen/langkah", h.pickingMajukanLangkah)

	// JADWAL HITUNG — cycle count terjadwal (patch 04 — P1 #7).
	j := api.Group("/inventory/operasi/jadwal-hitung", d.AuthGuard, d.RbacGuard)
	j.GET("", h.jadwalList)
	j.POST("", h.jadwalCreate)
	j.GET("/:id", h.jadwalGet)
	j.PATCH("/:id", h.jadwalUpdate)
	j.DELETE("/:id", h.jadwalRemove)
	j.POST("/:id/generate", h.jadwalGenerate)
}

// operasiHandler — dependensi handler operasi-lain.
type operasiHandler struct {
	mutasi      *service.MutasiService
	penyesuaian *service.PenyesuaianService
	picking     *service.PickingService
	jadwal      *service.JadwalService
}

// opCtx — konteks mutasi: aktor audit WAJIB dari JWT + request asli; userID
// utk evaluasi data-scope 'storages' (0 = tidak diketahui → fail-open).
func opCtx(c echo.Context) service.CtxMutasi {
	u := auth.FromReq(c.Request())
	actor := coreshared.ActorOf(c.Request())
	userID := int64(0)
	if u != nil {
		userID = u.ID
	}
	return service.CtxMutasi{Actor: actor, UserID: userID}
}

/* ==================================================================
/* Helper permukaan HTTP — decode body + validasi zod-parity 3.25
/* ================================================================== */

// opMsgExpected — padanan pesan invalid_type zod 3.25 (undefined/null/tipe lain).
func opMsgExpected(expected, received string) string {
	return fmt.Sprintf("Invalid input: expected %s, received %s", expected, received)
}

const (
	opMsgIntFraction = "Invalid input: expected int, received number"
	opMsgNaN         = "Invalid input: expected number, received NaN"
)

// opFi — field issue singkat.
func opFi(field, message string) errkontrak.FieldIssue {
	return errkontrak.FieldIssue{Field: field, Message: message}
}

// opNamaTipeJSON — getParsedType zod utk nilai JSON apa pun.
func opNamaTipeJSON(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case string:
		return "string"
	case bool:
		return "boolean"
	case float64:
		return "number"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return "unknown"
	}
}

// opDecodeBody — baca body request → map JSON; ok=false bila rusak (padanan
// safeParse gagal struktur → detail "Body tidak valid"); body kosong = objek
// kosong.
func opDecodeBody(c echo.Context) (map[string]any, bool) {
	body, err := io.ReadAll(c.Request().Body)
	if err != nil {
		return nil, false
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		return map[string]any{}, true
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, false
	}
	return m, true
}

// opBadBody — 400 VAL-400 detail "Body tidak valid".
func opBadBody(c echo.Context, issues []errkontrak.FieldIssue) error {
	if issues == nil {
		issues = []errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}}
	}
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Body tidak valid", issues)
}

// opGagalValidasi — padanan parseWith gagal: 400 VAL-400 "Data tidak valid."
func opGagalValidasi(c echo.Context, issues []errkontrak.FieldIssue) error {
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Data tidak valid.", issues)
}

// opUtf16Len — panjang gaya JS (UTF-16 code units) utk max string zod.
func opUtf16Len(s string) int {
	n := 0
	for _, r := range s {
		n += utf16.RuneLen(r)
	}
	return n
}

// opReqEnum — enum WAJIB (message kustom/custom default menutup invalid_type
// + enum value — verbatim zod 3.25 invalid_option).
func opReqEnum(m map[string]any, key string, nilai []string, issues *[]errkontrak.FieldIssue) (string, bool) {
	msg := `Invalid option: expected one of ` + opQuotedPipe(nilai)
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, opFi(key, opMsgExpected("string", "undefined")))
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("string", opNamaTipeJSON(v))))
		return "", false
	}
	for _, n := range nilai {
		if s == n {
			return s, true
		}
	}
	*issues = append(*issues, opFi(key, msg))
	return s, false
}

// opQuotedPipe — `"A"|"B"` utk pesan invalid_option.
func opQuotedPipe(nilai []string) string {
	out := ""
	for i, n := range nilai {
		if i > 0 {
			out += "|"
		}
		out += `"` + n + `"`
	}
	return out
}

// opReqIDRef — idRefSchema: number WAJIB int positif (pesan ≤0 verbatim
// "Pilih salah satu opsi.").
func opReqIDRef(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (int64, bool) {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, opFi(key, opMsgExpected("number", "undefined")))
		return 0, false
	}
	n, ok := v.(float64)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("number", opNamaTipeJSON(v))))
		return 0, false
	}
	if n != float64(int64(n)) {
		*issues = append(*issues, opFi(key, opMsgIntFraction))
		return int64(n), false
	}
	if int64(n) < 1 {
		*issues = append(*issues, opFi(key, "Pilih salah satu opsi."))
		return int64(n), false
	}
	return int64(n), true
}

// opOptIDRef — idRef nullish (absen/null → nil, valid).
func opOptIDRef(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*int64, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, true
	}
	sub := map[string]any{key: v}
	id, ok := opReqIDRef(sub, key, issues)
	if !ok {
		return nil, false
	}
	return &id, true
}

// opReqNumberInt — number WAJIB int ≥ min (pesan custom min).
func opReqNumberInt(m map[string]any, key string, min int64, msgMin string, issues *[]errkontrak.FieldIssue) (int64, bool) {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, opFi(key, opMsgExpected("number", "undefined")))
		return 0, false
	}
	n, ok := v.(float64)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("number", opNamaTipeJSON(v))))
		return 0, false
	}
	okAll := true
	if n != float64(int64(n)) {
		*issues = append(*issues, opFi(key, opMsgIntFraction))
		okAll = false
	}
	if int64(n) < min {
		*issues = append(*issues, opFi(key, msgMin))
		okAll = false
	}
	return int64(n), okAll
}

// opOptNumberIntNullish — number nullish int ≥ min (null/absen → nil).
func opOptNumberIntNullish(m map[string]any, key string, min int64, msgMin string, issues *[]errkontrak.FieldIssue) (*int64, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, true
	}
	sub := map[string]any{key: v}
	n, ok := opReqNumberInt(sub, key, min, msgMin, issues)
	if !ok {
		return nil, false
	}
	return &n, true
}

// opReqStringTrim — string WAJIB + trim (z.string().trim().min/max).
func opReqStringTrim(m map[string]any, key string, min int, max int, msgMin, msgMax string, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, opFi(key, opMsgExpected("string", "undefined")))
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("string", opNamaTipeJSON(v))))
		return "", false
	}
	s = strings.TrimSpace(s)
	okAll := true
	if opUtf16Len(s) < min {
		*issues = append(*issues, opFi(key, msgMin))
		okAll = false
	}
	if opUtf16Len(s) > max {
		*issues = append(*issues, opFi(key, msgMax))
		okAll = false
	}
	return s, okAll
}

// opOptStringTrimNullish — string nullish + trim + max (absen/null → nil).
func opOptStringTrimNullish(m map[string]any, key string, max int, issues *[]errkontrak.FieldIssue) (*string, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, true
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("string", opNamaTipeJSON(v))))
		return nil, false
	}
	s = strings.TrimSpace(s)
	if opUtf16Len(s) > max {
		*issues = append(*issues, opFi(key,
			fmt.Sprintf("Too big: expected string to have <=%d characters", max)))
		return nil, false
	}
	return &s, true
}

// opTanggalNullish — tanggalSchema.nullish(): string min 1 (absen/null → nil).
func opTanggalNullish(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*string, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, true
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("string", opNamaTipeJSON(v))))
		return nil, false
	}
	if len(s) < 1 {
		*issues = append(*issues, opFi(key, "Too small: expected string to have >=1 characters"))
		return nil, false
	}
	return &s, true
}

// opMoneyNullish — moneySchema.nullish(): number ≥ 0 ≤ 999999999999 finite.
func opMoneyNullish(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*float64, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, true
	}
	n, ok := v.(float64)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("number", opNamaTipeJSON(v))))
		return nil, false
	}
	okAll := true
	if n < 0 {
		*issues = append(*issues, opFi(key, "Too small: expected number to be >=0"))
		okAll = false
	}
	if n > 999_999_999_999 {
		*issues = append(*issues, opFi(key, "Too big: expected number to be <=999999999999"))
		okAll = false
	}
	return &n, okAll
}

// opVersion — versionSchema: int ≥ 1 WAJIB.
func opVersion(m map[string]any, issues *[]errkontrak.FieldIssue) (int64, bool) {
	return opReqNumberInt(m, "version", 1, "Too small: expected number to be >=1", issues)
}

// opReqArray — array wajib (min/max custom; elemen mentah dikembalikan).
func opReqArray(m map[string]any, key string, min int, max int, msgMin, msgMax string, issues *[]errkontrak.FieldIssue) ([]any, bool) {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, opFi(key, opMsgExpected("array", "undefined")))
		return nil, false
	}
	arr, ok := v.([]any)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("array", opNamaTipeJSON(v))))
		return nil, false
	}
	okAll := true
	if len(arr) < min {
		*issues = append(*issues, opFi(key, msgMin))
		okAll = false
	}
	if max > 0 && len(arr) > max {
		*issues = append(*issues, opFi(key, msgMax))
		okAll = false
	}
	return arr, okAll
}

// opOptArray — array opsional (absen/null → nil).
func opOptArray(m map[string]any, key string, min int, msgMin string, issues *[]errkontrak.FieldIssue) ([]any, bool, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, false, true
	}
	arr, ok := v.([]any)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("array", opNamaTipeJSON(v))))
		return nil, false, false
	}
	if len(arr) < min {
		*issues = append(*issues, opFi(key, msgMin))
		return arr, false, false
	}
	return arr, true, true
}

// opBodyKosong — z.object({}).strict().optional(): objek kosong | absen;
// unknown key → issue `Unrecognized key: "x"` (verbatim strict).
func opBodyKosong(m map[string]any) []errkontrak.FieldIssue {
	var issues []errkontrak.FieldIssue
	for k := range m {
		issues = append(issues, opFi(k, fmt.Sprintf("Unrecognized key: %q", k)))
	}
	return issues
}

/* ==================================================================
/* Validasi DTO (pesan VERBATIM packages/schemas/src/inv/schemas.ts)
/* ================================================================== */

var (
	opKodeRE   = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	opMsgKode  = "Kode: huruf/angka/. _ -"
	opMsgNaN66 = "Qty wajib angka."
)

// opValidasiMutasiCreate — mutasiDokumenCreateSchema.
func opValidasiMutasiCreate(m map[string]any) (service.MutasiCreateInput, []errkontrak.FieldIssue) {
	var in service.MutasiCreateInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := opReqEnum(m, "jenis", []string{"PENERIMAAN", "PENGIRIMAN", "TRANSFER_INTERNAL"}, &issues); !o {
		ok = false
	} else {
		in.Jenis = v
	}
	if v, o := opReqIDRef(m, "idLokasiSumber", &issues); !o {
		ok = false
	} else {
		in.IDLokasiSumber = v
	}
	if v, o := opReqIDRef(m, "idLokasiTujuan", &issues); !o {
		ok = false
	} else {
		in.IDLokasiTujuan = v
	}
	if v, o := opTanggalNullish(m, "tanggalDokumen", &issues); !o {
		ok = false
	} else {
		in.TanggalDokumen = v
	}
	if v, o := opOptStringTrimNullish(m, "alasan", 300, &issues); !o {
		ok = false
	} else {
		in.Alasan = v
	}
	arr, o := opReqArray(m, "items", 1, 200, "Minimal satu item mutasi.", "Maksimal 200 item per dokumen.", &issues)
	if !o {
		ok = false
	}
	for i, el := range arr {
		em, isObj := el.(map[string]any)
		if !isObj {
			issues = append(issues, opFi(fmt.Sprintf("items.%d", i), opMsgExpected("object", opNamaTipeJSON(el))))
			ok = false
			continue
		}
		item, itemIssues := opValidasiMutasiItem(em, fmt.Sprintf("items.%d", i))
		if itemIssues != nil {
			issues = append(issues, itemIssues...)
			ok = false
			continue
		}
		in.Items = append(in.Items, item)
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opValidasiMutasiItem — mutasiItemSchema (pesan custom qty verbatim).
func opValidasiMutasiItem(m map[string]any, path string) (service.MutasiItemInput, []errkontrak.FieldIssue) {
	var in service.MutasiItemInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := opReqIDRef(m, "idInvProduk", &issues); !o {
		ok = false
	} else {
		in.IDInvProduk = v
	}
	if v, o := opOptIDRef(m, "idInvLotSerial", &issues); !o {
		ok = false
	} else {
		in.IDInvLotSerial = v
	}
	if v, o := opReqIDRef(m, "idInvUnitUkur", &issues); !o {
		ok = false
	} else {
		in.IDInvUnitUkur = v
	}
	// qtyDiminta: z.number({ message: "Qty wajib angka." }).int("Qty wajib
	// bilangan bulat.").positive("Qty harus > 0.")
	v, ada := m["qtyDiminta"]
	if !ada {
		issues = append(issues, opFi(path+".qtyDiminta", opMsgNaN66))
		ok = false
	} else {
		n, isNum := v.(float64)
		if !isNum {
			issues = append(issues, opFi(path+".qtyDiminta", opMsgNaN66))
			ok = false
		} else {
			if n != float64(int64(n)) {
				issues = append(issues, opFi(path+".qtyDiminta", "Qty wajib bilangan bulat."))
				ok = false
			}
			if n <= 0 {
				issues = append(issues, opFi(path+".qtyDiminta", "Qty harus > 0."))
				ok = false
			}
			if ok {
				in.QtyDiminta = int(n)
			}
		}
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opValidasiMutasiUpdate — mutasiDokumenUpdateSchema (partial + version).
func opValidasiMutasiUpdate(m map[string]any) (service.MutasiUpdateInput, []errkontrak.FieldIssue) {
	var in service.MutasiUpdateInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, ada := m["jenis"]; ada {
		sub := map[string]any{"jenis": v}
		if j, o := opReqEnum(sub, "jenis", []string{"PENERIMAAN", "PENGIRIMAN", "TRANSFER_INTERNAL"}, &issues); !o {
			ok = false
		} else {
			in.Jenis = j
		}
	}
	if v, ada := m["idLokasiSumber"]; ada {
		sub := map[string]any{"idLokasiSumber": v}
		if id, o := opReqIDRef(sub, "idLokasiSumber", &issues); !o {
			ok = false
		} else {
			in.IDLokasiSumber = &id
		}
	}
	if v, ada := m["idLokasiTujuan"]; ada {
		sub := map[string]any{"idLokasiTujuan": v}
		if id, o := opReqIDRef(sub, "idLokasiTujuan", &issues); !o {
			ok = false
		} else {
			in.IDLokasiTujuan = &id
		}
	}
	if v, o := opTanggalNullish(m, "tanggalDokumen", &issues); !o {
		ok = false
	} else {
		in.TanggalAda = true
		in.TanggalDokumen = v
	}
	if v, ada := m["alasan"]; ada {
		sub := map[string]any{"alasan": v}
		if a, o := opOptStringTrimNullish(sub, "alasan", 300, &issues); !o {
			ok = false
		} else {
			in.AlasanAda = true
			in.Alasan = a
		}
	}
	if arr, adaArr, o := opOptArray(m, "items", 1, "Too small: expected array to have >=1 items", &issues); !o {
		ok = false
	} else if adaArr {
		in.ItemsAda = true
		for i, el := range arr {
			em, isObj := el.(map[string]any)
			if !isObj {
				issues = append(issues, opFi(fmt.Sprintf("items.%d", i), opMsgExpected("object", opNamaTipeJSON(el))))
				ok = false
				continue
			}
			item, itemIssues := opValidasiMutasiItem(em, fmt.Sprintf("items.%d", i))
			if itemIssues != nil {
				issues = append(issues, itemIssues...)
				ok = false
				continue
			}
			in.Items = append(in.Items, item)
		}
	}
	if v, o := opVersion(m, &issues); !o {
		ok = false
	} else {
		in.Version = v
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opValidasiKeputusan — mutasiKeputusanSchema & penyesuaianKeputusanSchema
// (identik): keputusan enum + alasan nullish + refine TOLAK wajib alasan.
func opValidasiKeputusan(m map[string]any) (service.MutasiKeputusanInput, []errkontrak.FieldIssue) {
	var in service.MutasiKeputusanInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := opReqEnum(m, "keputusan", []string{"SETUJUI", "TOLAK"}, &issues); !o {
		ok = false
	} else {
		in.Keputusan = v
	}
	if v, o := opOptStringTrimNullish(m, "alasan", 300, &issues); !o {
		ok = false
	} else {
		in.Alasan = v
	}
	// refine: TOLAK → alasan ≥ 3 — "Alasan wajib saat menolak."
	if in.Keputusan == "TOLAK" && (in.Alasan == nil || opUtf16Len(*in.Alasan) < 3) {
		issues = append(issues, opFi("alasan", "Alasan wajib saat menolak."))
		ok = false
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opValidasiPenyesuaianItem — penyesuaianItemSchema (+refine kemasan).
func opValidasiPenyesuaianItem(m map[string]any, path string) (service.PenyesuaianItemInput, []errkontrak.FieldIssue) {
	var in service.PenyesuaianItemInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := opReqIDRef(m, "idInvProduk", &issues); !o {
		ok = false
	} else {
		in.IDInvProduk = v
	}
	if v, o := opOptIDRef(m, "idInvLotSerial", &issues); !o {
		ok = false
	} else {
		in.IDInvLotSerial = v
	}
	if v, o := opReqIDRef(m, "idInvLokasiStok", &issues); !o {
		ok = false
	} else {
		in.IDInvLokasiStok = v
	}
	if v, o := opReqIDRef(m, "idInvUnitUkur", &issues); !o {
		ok = false
	} else {
		in.IDInvUnitUkur = v
	}
	if v, o := opOptIDRef(m, "idInvKemasan", &issues); !o {
		ok = false
	} else {
		in.IDInvKemasan = v
	}
	if v, o := opOptNumberIntNullish(m, "qtyKemasanHitung", 0, "Qty kemasan hitung tidak boleh negatif.", &issues); !o {
		ok = false
	} else if v != nil {
		q := int(*v)
		in.QtyKemasanHitung = &q
	}
	if v, o := opReqNumberInt(m, "qtySistem", 0, "Qty sistem tidak boleh negatif.", &issues); !o {
		ok = false
	} else {
		in.QtySistem = int(v)
	}
	if v, o := opReqNumberInt(m, "qtyHitung", 0, "Qty hitung tidak boleh negatif.", &issues); !o {
		ok = false
	} else {
		in.QtyHitung = int(v)
	}
	if v, o := opMoneyNullish(m, "biayaSatuan", &issues); !o {
		ok = false
	} else {
		in.BiayaSatuan = v
	}
	// refine: idInvKemasan → qtyKemasanHitung wajib — "Qty kemasan hitung
	// wajib bila kemasan dipilih."
	if in.IDInvKemasan != nil && in.QtyKemasanHitung == nil {
		issues = append(issues, opFi(path+".qtyKemasanHitung", "Qty kemasan hitung wajib bila kemasan dipilih."))
		ok = false
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opValidasiPenyesuaianCreate — penyesuaianCreateSchema (+2 refine alasan).
func opValidasiPenyesuaianCreate(m map[string]any) (service.PenyesuaianCreateInput, []errkontrak.FieldIssue) {
	var in service.PenyesuaianCreateInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	// jenis: default "PENYESUAIAN".
	if v, ada := m["jenis"]; ada {
		sub := map[string]any{"jenis": v}
		if j, o := opReqEnum(sub, "jenis", []string{"PENYESUAIAN", "CYCLE_COUNT", "SCRAP"}, &issues); !o {
			ok = false
		} else {
			in.Jenis = j
		}
	} else {
		in.Jenis = "PENYESUAIAN"
	}
	if v, o := opReqIDRef(m, "idInvGudang", &issues); !o {
		ok = false
	} else {
		in.IDInvGudang = v
	}
	if v, o := opTanggalNullish(m, "tanggalDokumen", &issues); !o {
		ok = false
	} else {
		in.TanggalDokumen = v
	}
	if v, o := opOptStringTrimNullish(m, "alasan", 300, &issues); !o {
		ok = false
	} else {
		in.Alasan = v
	}
	arr, o := opReqArray(m, "items", 1, 0, "Minimal satu baris penyesuaian.", "", &issues)
	if !o {
		ok = false
	}
	for i, el := range arr {
		em, isObj := el.(map[string]any)
		if !isObj {
			issues = append(issues, opFi(fmt.Sprintf("items.%d", i), opMsgExpected("object", opNamaTipeJSON(el))))
			ok = false
			continue
		}
		item, itemIssues := opValidasiPenyesuaianItem(em, fmt.Sprintf("items.%d", i))
		if itemIssues != nil {
			issues = append(issues, itemIssues...)
			ok = false
			continue
		}
		in.Items = append(in.Items, item)
	}
	// refine: PENYESUAIAN → alasan ≥ 3 — "Alasan wajib untuk penyesuaian manual."
	if in.Jenis == "PENYESUAIAN" && (in.Alasan == nil || opUtf16Len(*in.Alasan) < 3) {
		issues = append(issues, opFi("alasan", "Alasan wajib untuk penyesuaian manual."))
		ok = false
	}
	// refine: SCRAP → alasan ≥ 3 — "Alasan wajib untuk scrap."
	if in.Jenis == "SCRAP" && (in.Alasan == nil || opUtf16Len(*in.Alasan) < 3) {
		issues = append(issues, opFi("alasan", "Alasan wajib untuk scrap."))
		ok = false
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opValidasiPenyesuaianUpdate — penyesuaianUpdateSchema.
func opValidasiPenyesuaianUpdate(m map[string]any) (service.PenyesuaianUpdateInput, []errkontrak.FieldIssue) {
	var in service.PenyesuaianUpdateInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, ada := m["jenis"]; ada {
		sub := map[string]any{"jenis": v}
		if j, o := opReqEnum(sub, "jenis", []string{"PENYESUAIAN", "CYCLE_COUNT", "SCRAP"}, &issues); !o {
			ok = false
		} else {
			in.Jenis = j
		}
	}
	if v, o := opTanggalNullish(m, "tanggalDokumen", &issues); !o {
		ok = false
	} else {
		in.TanggalAda = true
		in.TanggalDokumen = v
	}
	if v, ada := m["alasan"]; ada {
		sub := map[string]any{"alasan": v}
		if a, o := opOptStringTrimNullish(sub, "alasan", 300, &issues); !o {
			ok = false
		} else {
			in.AlasanAda = true
			in.Alasan = a
		}
	}
	if arr, adaArr, o := opOptArray(m, "items", 1, "Too small: expected array to have >=1 items", &issues); !o {
		ok = false
	} else if adaArr {
		in.ItemsAda = true
		for i, el := range arr {
			em, isObj := el.(map[string]any)
			if !isObj {
				issues = append(issues, opFi(fmt.Sprintf("items.%d", i), opMsgExpected("object", opNamaTipeJSON(el))))
				ok = false
				continue
			}
			item, itemIssues := opValidasiPenyesuaianItem(em, fmt.Sprintf("items.%d", i))
			if itemIssues != nil {
				issues = append(issues, itemIssues...)
				ok = false
				continue
			}
			in.Items = append(in.Items, item)
		}
	}
	if v, o := opVersion(m, &issues); !o {
		ok = false
	} else {
		in.Version = v
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opValidasiJadwalCreate — jadwalHitungCreateSchema.
func opValidasiJadwalCreate(m map[string]any) (service.JadwalCreateInput, []errkontrak.FieldIssue) {
	var in service.JadwalCreateInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := opReqStringTrim(m, "kode", 1, 50, "Kode jadwal wajib.", "Too big: expected string to have <=50 characters", &issues); !o {
		ok = false
	} else if !opKodeRE.MatchString(v) {
		issues = append(issues, opFi("kode", opMsgKode))
		ok = false
	} else {
		in.Kode = v
	}
	if v, o := opReqStringTrim(m, "nama", 1, 100, "Nama jadwal wajib.", "Too big: expected string to have <=100 characters", &issues); !o {
		ok = false
	} else {
		in.Nama = v
	}
	if v, o := opReqIDRef(m, "idInvGudang", &issues); !o {
		ok = false
	} else {
		in.IDInvGudang = v
	}
	if v, o := opOptIDRef(m, "idInvLokasiStok", &issues); !o {
		ok = false
	} else {
		in.IDInvLokasiStok = v
	}
	// frekuensi default "BULANAN"; hariEksekusi default 1 (0..28); aktif default true.
	if v, ada := m["frekuensi"]; ada {
		sub := map[string]any{"frekuensi": v}
		if f, o := opReqEnum(sub, "frekuensi", []string{"HARIAN", "MINGGUAN", "BULANAN", "TRIWULAN"}, &issues); !o {
			ok = false
		} else {
			in.Frekuensi = f
		}
	} else {
		in.Frekuensi = "BULANAN"
	}
	if v, ada := m["hariEksekusi"]; ada {
		sub := map[string]any{"hariEksekusi": v}
		n, o := opReqNumberInt(sub, "hariEksekusi", 0, "Hari eksekusi 0 (Minggu) s.d. 28.", &issues)
		if !o {
			ok = false
		} else {
			if n > 28 {
				issues = append(issues, opFi("hariEksekusi", "Too big: expected number to be <=28"))
				ok = false
			}
			in.HariEksekusi = int(n)
		}
	} else {
		in.HariEksekusi = 1
	}
	if v, ada := m["aktif"]; ada {
		b, isBool := v.(bool)
		if !isBool {
			issues = append(issues, opFi("aktif", opMsgExpected("boolean", opNamaTipeJSON(v))))
			ok = false
		} else {
			in.Aktif = b
		}
	} else {
		in.Aktif = true
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opValidasiJadwalUpdate — jadwalHitungUpdateSchema (partial + version).
func opValidasiJadwalUpdate(m map[string]any) (service.JadwalUpdateInput, []errkontrak.FieldIssue) {
	var in service.JadwalUpdateInput
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, ada := m["kode"]; ada {
		sub := map[string]any{"kode": v}
		s, o := opReqStringTrim(sub, "kode", 1, 50, "Kode jadwal wajib.", "Too big: expected string to have <=50 characters", &issues)
		if !o {
			ok = false
		} else if !opKodeRE.MatchString(s) {
			issues = append(issues, opFi("kode", opMsgKode))
			ok = false
		} else {
			in.Kode = s
		}
	}
	if v, ada := m["nama"]; ada {
		sub := map[string]any{"nama": v}
		s, o := opReqStringTrim(sub, "nama", 1, 100, "Nama jadwal wajib.", "Too big: expected string to have <=100 characters", &issues)
		if !o {
			ok = false
		} else {
			in.Nama = s
		}
	}
	if v, ada := m["idInvGudang"]; ada {
		sub := map[string]any{"idInvGudang": v}
		if id, o := opReqIDRef(sub, "idInvGudang", &issues); !o {
			ok = false
		} else {
			in.IDInvGudang = &id
		}
	}
	if v, ada := m["idInvLokasiStok"]; ada {
		sub := map[string]any{"idInvLokasiStok": v}
		if id, o := opOptIDRef(sub, "idInvLokasiStok", &issues); !o {
			ok = false
		} else {
			in.LokasiAda = true
			in.IDInvLokasiStok = id
		}
	}
	if v, ada := m["frekuensi"]; ada {
		sub := map[string]any{"frekuensi": v}
		if f, o := opReqEnum(sub, "frekuensi", []string{"HARIAN", "MINGGUAN", "BULANAN", "TRIWULAN"}, &issues); !o {
			ok = false
		} else {
			in.Frekuensi = f
		}
	}
	if v, ada := m["hariEksekusi"]; ada {
		sub := map[string]any{"hariEksekusi": v}
		n, o := opReqNumberInt(sub, "hariEksekusi", 0, "Hari eksekusi 0 (Minggu) s.d. 28.", &issues)
		if !o {
			ok = false
		} else {
			if n > 28 {
				issues = append(issues, opFi("hariEksekusi", "Too big: expected number to be <=28"))
				ok = false
			}
			h := int(n)
			in.HariEksekusi = &h
		}
	}
	if v, ada := m["aktif"]; ada {
		sub := map[string]any{"aktif": v}
		b, o := opOptBool(sub, "aktif", &issues)
		if !o {
			ok = false
		} else {
			in.AktifAda = true
			in.Aktif = b
		}
	}
	if v, o := opVersion(m, &issues); !o {
		ok = false
	} else {
		in.Version = v
	}
	if ok && len(issues) == 0 {
		return in, nil
	}
	return in, issues
}

// opOptBool — boolean nullish.
func opOptBool(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*bool, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, true
	}
	b, ok := v.(bool)
	if !ok {
		*issues = append(*issues, opFi(key, opMsgExpected("boolean", opNamaTipeJSON(v))))
		return nil, false
	}
	return &b, true
}

// opReqAlasanBatal — mutasiBatalSchema/penyesuaianBatalSchema (pesan min
// BERBEDA antar fitur — dikirim pemanggil).
func opReqAlasanBatal(m map[string]any, msgMin string) (string, []errkontrak.FieldIssue) {
	issues := []errkontrak.FieldIssue{}
	s, ok := opReqStringTrim(m, "alasan", 3, 300, msgMin, "Too big: expected string to have <=300 characters", &issues)
	if !ok {
		return "", issues
	}
	return s, nil
}

// opReqVersion — penyesuaianAjukanSchema/mutasiAjukanSchema {version}.
func opReqVersion(m map[string]any) (int64, []errkontrak.FieldIssue) {
	issues := []errkontrak.FieldIssue{}
	v, ok := opVersion(m, &issues)
	if !ok {
		return 0, issues
	}
	return v, nil
}

/* ==================================================================
/* Handler MUTASI
/* ================================================================== */

func (h *operasiHandler) mutasiList(c echo.Context) error {
	page, err := h.mutasi.List(c.Request().Context(), c.Request().URL.Query(), opCtx(c).UserID)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page) // Page<T> ATAS — tanpa bungkus {data}
}

func (h *operasiHandler) mutasiCreate(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	in, issues := opValidasiMutasiCreate(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.mutasi.Create(c.Request().Context(), in, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view) // 201
}

func (h *operasiHandler) mutasiGrEligible(c echo.Context) error {
	data, err := h.mutasi.GrEligible(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

func (h *operasiHandler) mutasiDariGr(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	var in service.MutasiDariGrInput
	issues := []errkontrak.FieldIssue{}
	if v, o := opReqIDRef(m, "idPurPenerimaan", &issues); !o {
		return opGagalValidasi(c, issues)
	} else {
		in.IDPurPenerimaan = v
	}
	if v, o := opOptIDRef(m, "idLokasiTujuan", &issues); !o {
		return opGagalValidasi(c, issues)
	} else {
		in.IDLokasiTujuan = v
	}
	view, err := h.mutasi.DariGr(c.Request().Context(), in, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view) // 201
}

func (h *operasiHandler) mutasiGet(c echo.Context) error {
	view, err := h.mutasi.Get(c.Request().Context(), c.Param("id"), opCtx(c).UserID)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) mutasiUpdate(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	in, issues := opValidasiMutasiUpdate(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.mutasi.Update(c.Request().Context(), c.Param("id"), in, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) mutasiAjukan(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	version, issues := opReqVersion(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.mutasi.Ajukan(c.Request().Context(), c.Param("id"), version, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) mutasiKeputusan(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	in, issues := opValidasiKeputusan(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.mutasi.Keputusan(c.Request().Context(), c.Param("id"), in, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) mutasiBatal(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	alasan, issues := opReqAlasanBatal(m, "Alasan pembatalan wajib (min. 3 karakter).")
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.mutasi.Batal(c.Request().Context(), c.Param("id"), alasan, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) mutasiRemove(c echo.Context) error {
	if err := h.mutasi.Remove(c.Request().Context(), c.Param("id"), opCtx(c)); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

/* ==================================================================
/* Handler PENYESUAIAN
/* ================================================================== */

func (h *operasiHandler) penyesuaianList(c echo.Context) error {
	pr, err := errkontrak.ParsePageRequest(c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.penyesuaian.List(c.Request().Context(), pr)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *operasiHandler) penyesuaianCreate(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	in, issues := opValidasiPenyesuaianCreate(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.penyesuaian.Create(c.Request().Context(), in, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view) // 201
}

func (h *operasiHandler) penyesuaianBarcode(c echo.Context) error {
	view, err := h.penyesuaian.ResolveBarcode(c.Request().Context(), c.Param("kode"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) penyesuaianGet(c echo.Context) error {
	view, err := h.penyesuaian.Get(c.Request().Context(), c.Param("id"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) penyesuaianUpdate(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	in, issues := opValidasiPenyesuaianUpdate(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.penyesuaian.Update(c.Request().Context(), c.Param("id"), in, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) penyesuaianAjukan(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	version, issues := opReqVersion(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.penyesuaian.Ajukan(c.Request().Context(), c.Param("id"), version, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) penyesuaianKeputusan(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	in, issues := opValidasiKeputusan(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.penyesuaian.Keputusan(c.Request().Context(), c.Param("id"), service.PenyesuaianKeputusanInput(in), opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) penyesuaianBatal(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	alasan, issues := opReqAlasanBatal(m, "Alasan pembatalan wajib.")
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.penyesuaian.Batal(c.Request().Context(), c.Param("id"), alasan, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

/* ==================================================================
/* Handler PICKING
/* ================================================================== */

func (h *operasiHandler) pickingList(c echo.Context) error {
	page, err := h.picking.List(c.Request().Context(), c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *operasiHandler) pickingGet(c echo.Context) error {
	data, err := h.picking.Get(c.Request().Context(), c.Param("nomorDokumen"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

func (h *operasiHandler) pickingMajukanLangkah(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	if issues := opBodyKosong(m); issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.picking.MajukanLangkah(c.Request().Context(), c.Param("nomorDokumen"), opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

/* ==================================================================
/* Handler JADWAL HITUNG
/* ================================================================== */

func (h *operasiHandler) jadwalList(c echo.Context) error {
	page, err := h.jadwal.List(c.Request().Context(), c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *operasiHandler) jadwalCreate(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	in, issues := opValidasiJadwalCreate(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.jadwal.Create(c.Request().Context(), in, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view) // 201
}

func (h *operasiHandler) jadwalGet(c echo.Context) error {
	view, err := h.jadwal.Get(c.Request().Context(), c.Param("id"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) jadwalUpdate(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	in, issues := opValidasiJadwalUpdate(m)
	if issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.jadwal.Update(c.Request().Context(), c.Param("id"), in, opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *operasiHandler) jadwalRemove(c echo.Context) error {
	if err := h.jadwal.Remove(c.Request().Context(), c.Param("id"), opCtx(c)); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

func (h *operasiHandler) jadwalGenerate(c echo.Context) error {
	m, ok := opDecodeBody(c)
	if !ok {
		return opBadBody(c, nil)
	}
	if issues := opBodyKosong(m); issues != nil {
		return opGagalValidasi(c, issues)
	}
	view, err := h.jadwal.Generate(c.Request().Context(), c.Param("id"), opCtx(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// strconv — dipakai helper angka (guard kecil).
var _ = strconv.Itoa
