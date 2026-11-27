// Handler WILAYAH modul core — SATU pendaftar utk 4 fitur (wilayah lookup 9,
// wilayah_admin 12, cluster 8, agama 5): padanan WilayahController +
// WilayahAdminController + ClusterController + AgamaController NestJS.
// Permukaan HTTP murni (Echo): decode body → validasi zod-ekuivalen (pesan
// VERBATIM schemas packages) → delegasi service → pemetaan error
// errkontrak (problem+json). Kontras kontrak:
//   - lookup list → { data, meta } ATAS (tanpa bungkus {data});
//   - detail/mutasi → { data: view };
//   - DELETE wilayah_admin pakai VERSION di BODY (soft delete + bump);
//   - PATCH/DELETE cluster & agama: PATCH = If-Match ATAU body version
//     (If-Match menang), DELETE TANPA version (soft delete deleted_at saja,
//     respons {data:{id}} HTTP 200).
package handler

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf16"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/service"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// DaftarkanWilayah — pasang 34 route 4 fitur di group /api (path tanpa
// prefix /api; guard JWT + RBAC route-centric).
func DaftarkanWilayah(api *echo.Group, d types.Deps) {
	h := &wilayahHandler{
		lookup:  service.NewWilayahService(d.DB),
		admin:   service.NewWilayahAdminService(d.DB, d.Audit),
		cluster: service.NewClusterService(d.DB, d.Audit),
		agama:   service.NewAgamaService(d.DB, d.Audit),
	}

	// -----------------------------------------------------------------
	// WILAYAH (lookup) + WILAYAH ADMIN (tulis) — base path SAMA
	// /system/wilayah, SET RBAC terpisah (system.wilayah vs
	// system.wilayah_admin) via core_routes.
	// -----------------------------------------------------------------
	g := api.Group("/system/wilayah", d.AuthGuard, d.RbacGuard)

	// Lookup baca (SET system.wilayah)
	g.GET("/provinsi", h.listProvinsi)
	g.GET("/provinsi/:id", h.getProvinsi)
	g.GET("/kota", h.listKota)
	g.GET("/kota/:id", h.getKota)
	g.GET("/kecamatan", h.listKecamatan)
	g.GET("/kecamatan/:id", h.getKecamatan)
	g.GET("/kelurahan", h.listKelurahan)
	g.GET("/kelurahan/:id", h.getKelurahan)
	g.GET("/kodepos/:kodepos", h.listKodePos)

	// Tulis admin (SET system.wilayah_admin)
	g.POST("/provinsi", h.createProvinsi)
	g.PATCH("/provinsi/:id", h.updateProvinsi)
	g.DELETE("/provinsi/:id", h.deleteProvinsi)
	g.POST("/kota", h.createKota)
	g.PATCH("/kota/:id", h.updateKota)
	g.DELETE("/kota/:id", h.deleteKota)
	g.POST("/kecamatan", h.createKecamatan)
	g.PATCH("/kecamatan/:id", h.updateKecamatan)
	g.DELETE("/kecamatan/:id", h.deleteKecamatan)
	g.POST("/kelurahan", h.createKelurahan)
	g.PATCH("/kelurahan/:id", h.updateKelurahan)
	g.DELETE("/kelurahan/:id", h.deleteKelurahan)

	// -----------------------------------------------------------------
	// CLUSTER — modul-options DIDEKLARASIKAN SEBELUM ":id" agar tidak
	// tertelan param dinamis (persis urutan controller NestJS).
	// -----------------------------------------------------------------
	cg := api.Group("/system/cluster", d.AuthGuard, d.RbacGuard)
	cg.GET("/modul-options", h.clusterModulOptions)
	cg.GET("", h.clusterList)
	cg.POST("", h.clusterCreate)
	cg.GET("/:id", h.clusterDetail)
	cg.PATCH("/:id", h.clusterUpdate)
	cg.DELETE("/:id", h.clusterRemove)
	cg.PUT("/:id/modul", h.clusterSyncModul)
	cg.PUT("/modul/:idModulCluster/fitur", h.clusterSyncFitur)

	// -----------------------------------------------------------------
	// AGAMA
	// -----------------------------------------------------------------
	ag := api.Group("/system/agama", d.AuthGuard, d.RbacGuard)
	ag.GET("", h.agamaList)
	ag.POST("", h.agamaCreate)
	ag.GET("/:id", h.agamaDetail)
	ag.PATCH("/:id", h.agamaUpdate)
	ag.DELETE("/:id", h.agamaRemove)
}

// wilayahHandler — dependensi handler wilayah/cluster/agama.
type wilayahHandler struct {
	lookup  *service.WilayahService
	admin   *service.WilayahAdminService
	cluster *service.ClusterService
	agama   *service.AgamaService
}

// =====================================================================
// Helper HTTP & validasi (zod-ekuivalen — pesan VERBATIM zod 3.25)
// =====================================================================

// (decodeBody/badBody/gagalValidasi/namaTipeJSON/coerceNumber dipakai dari
// handler package ini — helpers tenants.go; detail 400 "Body tidak valid"/
// "Data tidak valid." satu konvensi seluruh modul core.)

// msgExpected — padanan pesan invalid_type zod 3.25 (undefined/null/tipe lain).
func msgExpected(expected, received string) string {
	return fmt.Sprintf("Invalid input: expected %s, received %s", expected, received)
}

const (
	msgIntFraction = "Invalid input: expected int, received number"
	msgNaN         = "Invalid input: expected number, received NaN"
)

// fi — field issue singkat.
func fi(field, message string) errkontrak.FieldIssue {
	return errkontrak.FieldIssue{Field: field, Message: message}
}

// regex kode wilayah/kode pos (persis pola zod schemas).
var (
	kodeProvinsiRE  = regexp.MustCompile(`^\d{2}$`)
	kodeKotaRE      = regexp.MustCompile(`^\d{4}$`)
	kodeKecamatanRE = regexp.MustCompile(`^\d{6}$`)
	kodeKelurahanRE = regexp.MustCompile(`^\d{10}$`)
)

// --- validasi field primitif (issues ter-append sesuai urutan skema) ---

// reqStringTrim — string WAJIB + trim (z.string().trim().min/max).
func reqStringTrim(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, fi(key, msgExpected("string", "undefined")))
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, fi(key, msgExpected("string", namaTipeJSON(v))))
		return "", false
	}
	return strings.TrimSpace(s), true
}

// reqStringTrimRE — string wajib + trim + regex (kode wilayah).
func reqStringTrimRE(m map[string]any, key string, re *regexp.Regexp, msgRegex string, issues *[]errkontrak.FieldIssue) (string, bool) {
	s, ok := reqStringTrim(m, key, issues)
	if !ok {
		return "", false
	}
	if !re.MatchString(s) {
		*issues = append(*issues, fi(key, msgRegex))
		return s, false
	}
	return s, true
}

// reqStringTrimMinMax — string wajib + trim + panjang min/max custom.
func reqStringTrimMinMax(m map[string]any, key string, min int, max int, msgMin, msgMax string, issues *[]errkontrak.FieldIssue) (string, bool) {
	s, ok := reqStringTrim(m, key, issues)
	if !ok {
		return "", false
	}
	okAll := true
	if len([]rune(s)) < min {
		*issues = append(*issues, fi(key, msgMin))
		okAll = false
	}
	if len([]rune(s)) > max {
		*issues = append(*issues, fi(key, msgMax))
		okAll = false
	}
	return s, okAll
}

// reqEnum — enum WAJIB (message kustom menutup invalid_type + enum value).
func reqEnum(m map[string]any, key string, nilai []string, msg string, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, fi(key, msg))
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, fi(key, msg))
		return "", false
	}
	for _, n := range nilai {
		if s == n {
			return s, true
		}
	}
	*issues = append(*issues, fi(key, msg))
	return s, false
}

// reqNumberInt — number WAJIB int >= min (message min custom).
func reqNumberInt(m map[string]any, key string, min int64, msgMin string, issues *[]errkontrak.FieldIssue) (int64, bool) {
	n, ok := parseNumberJSON(m, key, "number", issues)
	if !ok {
		return 0, false
	}
	if n != float64(int64(n)) {
		*issues = append(*issues, fi(key, msgIntFraction))
		return int64(n), false
	}
	if int64(n) < min {
		*issues = append(*issues, fi(key, msgMin))
		return int64(n), false
	}
	return int64(n), true
}

// optNumberInt — number OPSIONAL int >= min (null = invalid type).
func optNumberInt(m map[string]any, key string, min int64, msgMin string, issues *[]errkontrak.FieldIssue) (*int64, bool) {
	v, ada := m[key]
	if !ada {
		return nil, true
	}
	m2 := map[string]any{key: v}
	n, ok := parseNumberJSON(m2, key, "number", issues)
	if !ok {
		return nil, false
	}
	if n != float64(int64(n)) {
		*issues = append(*issues, fi(key, msgIntFraction))
		return nil, false
	}
	if int64(n) < min {
		*issues = append(*issues, fi(key, msgMin))
		return nil, false
	}
	out := int64(n)
	return &out, true
}

// parseNumberJSON — nilai field → float64 + issue invalid_type bila bukan
// number JSON (z.number() pada tipe lain).
func parseNumberJSON(m map[string]any, key, expected string, issues *[]errkontrak.FieldIssue) (float64, bool) {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, fi(key, msgExpected(expected, "undefined")))
		return 0, false
	}
	n, ok := v.(float64)
	if !ok {
		*issues = append(*issues, fi(key, msgExpected(expected, namaTipeJSON(v))))
		return 0, false
	}
	return n, true
}

// reqVersion — `version` WAJIB untuk PATCH/DELETE wilayah_admin
// (z.number().int().min(1, "Version wajib ...")).
func reqVersion(m map[string]any, msgMin string, issues *[]errkontrak.FieldIssue) (int64, bool) {
	return reqNumberInt(m, "version", 1, msgMin, issues)
}

// optNullableTrim — field string trim OPSIONAL nullish (deskripsi/icon/tone):
// absen → nil,nil; null → nil,true(null); string → trim + max.
// Return (nilai, null-dikirim, valid).
func optNullableTrim(m map[string]any, key string, max int, issues *[]errkontrak.FieldIssue) (*string, bool, bool) {
	v, ada := m[key]
	if !ada {
		return nil, false, true
	}
	if v == nil {
		return nil, true, true
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, fi(key, msgExpected("string", namaTipeJSON(v))))
		return nil, false, false
	}
	s = strings.TrimSpace(s)
	if len([]rune(s)) > max {
		*issues = append(*issues, fi(
			key,
			fmt.Sprintf("Too big: expected string to have <=%d characters", max),
		))
		return nil, false, false
	}
	return &s, false, true
}

// kodePosBuat — preprocess "" → tidak dikirim; nullish + regex 5 digit.
// (nil, false) = NULL (belum tercantum).
func kodePosBuat(m map[string]any, issues *[]errkontrak.FieldIssue) (*string, bool) {
	v, ada := m["kodePos"]
	if !ada || v == nil {
		return nil, true
	}
	if s, ok := v.(string); ok && s == "" {
		return nil, true
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, fi("kodePos", msgExpected("string", namaTipeJSON(v))))
		return nil, false
	}
	if !types.KodePosRE.MatchString(s) {
		*issues = append(*issues, fi("kodePos", "Kode pos 5 digit."))
		return nil, false
	}
	return &s, true
}

// kodePosUbah — tri-state PATCH kelurahan: absen/"" → pertahankan (nil,nil);
// null → hapus (KodePosNull); string → ganti (regex).
func kodePosUbah(m map[string]any, ubah *types.WilayahKelurahanUbah, issues *[]errkontrak.FieldIssue) bool {
	v, ada := m["kodePos"]
	if !ada {
		return true
	}
	if s, ok := v.(string); ok && s == "" {
		return true
	}
	if v == nil {
		ubah.KodePosNull = true
		return true
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, fi("kodePos", msgExpected("string", namaTipeJSON(v))))
		return false
	}
	if !types.KodePosRE.MatchString(s) {
		*issues = append(*issues, fi("kodePos", "Kode pos 5 digit."))
		return false
	}
	ubah.KodePos = &s
	return true
}

// =====================================================================
// Validasi DTO wilayah_admin (padanan wilayah*Buat/Ubah/HapusSchema)
// =====================================================================

const msgVersionUbah = "Version wajib untuk optimistic locking."
const msgVersionHapus = "Version wajib."

func validasiProvinsiBuat(m map[string]any) (types.WilayahProvinsiBuat, []errkontrak.FieldIssue) {
	var out types.WilayahProvinsiBuat
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := reqStringTrimRE(m, "kode", kodeProvinsiRE, "Kode provinsi 2 digit.", &issues); !o {
		ok = false
	} else {
		out.Kode = v
	}
	if v, o := reqStringTrimMinMax(m, "nama", 1, 100, "Nama provinsi wajib diisi.", "Nama provinsi maksimal 100 karakter.", &issues); !o {
		ok = false
	} else {
		out.Nama = v
	}
	return out, gagalAtauNil(issues, ok)
}

func validasiKotaBuat(m map[string]any) (types.WilayahKotaBuat, []errkontrak.FieldIssue) {
	var out types.WilayahKotaBuat
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := reqStringTrimRE(m, "kode", kodeKotaRE, "Kode kota/kabupaten 4 digit.", &issues); !o {
		ok = false
	} else {
		out.Kode = v
	}
	if v, o := reqStringTrimMinMax(m, "nama", 1, 100, "Nama kota/kabupaten wajib diisi.", "Nama kota/kabupaten maksimal 100 karakter.", &issues); !o {
		ok = false
	} else {
		out.Nama = v
	}
	if v, o := reqEnum(m, "jenis", []string{types.JenisKota, types.JenisKabupaten}, "Jenis hanya KOTA atau KABUPATEN.", &issues); !o {
		ok = false
	} else {
		out.Jenis = v
	}
	if v, o := reqNumberInt(m, "idCoreProvinsi", 1, "Provinsi induk wajib — id numerik >= 1.", &issues); !o {
		ok = false
	} else {
		out.IDCoreProvinsi = v
	}
	return out, gagalAtauNil(issues, ok)
}

func validasiKecamatanBuat(m map[string]any) (types.WilayahKecamatanBuat, []errkontrak.FieldIssue) {
	var out types.WilayahKecamatanBuat
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := reqStringTrimRE(m, "kode", kodeKecamatanRE, "Kode kecamatan 6 digit.", &issues); !o {
		ok = false
	} else {
		out.Kode = v
	}
	if v, o := reqStringTrimMinMax(m, "nama", 1, 100, "Nama kecamatan wajib diisi.", "Nama kecamatan maksimal 100 karakter.", &issues); !o {
		ok = false
	} else {
		out.Nama = v
	}
	if v, o := reqNumberInt(m, "idCoreKota", 1, "Kota induk wajib — id numerik >= 1.", &issues); !o {
		ok = false
	} else {
		out.IDCoreKota = v
	}
	return out, gagalAtauNil(issues, ok)
}

func validasiKelurahanBuat(m map[string]any) (types.WilayahKelurahanBuat, []errkontrak.FieldIssue) {
	var out types.WilayahKelurahanBuat
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := reqStringTrimRE(m, "kode", kodeKelurahanRE, "Kode kelurahan/desa 10 digit.", &issues); !o {
		ok = false
	} else {
		out.Kode = v
	}
	if v, o := reqStringTrimMinMax(m, "nama", 1, 100, "Nama kelurahan/desa wajib diisi.", "Nama kelurahan/desa maksimal 100 karakter.", &issues); !o {
		ok = false
	} else {
		out.Nama = v
	}
	if v, o := kodePosBuat(m, &issues); !o {
		ok = false
	} else {
		out.KodePos = v
	}
	if v, o := reqNumberInt(m, "idCoreKecamatan", 1, "Kecamatan induk wajib — id numerik >= 1.", &issues); !o {
		ok = false
	} else {
		out.IDCoreKecamatan = v
	}
	return out, gagalAtauNil(issues, ok)
}

// gagalAtauNil — issues penuh → kembalikan issues (validasi GAGAL); kosong → nil.
func gagalAtauNil(issues []errkontrak.FieldIssue, ok bool) []errkontrak.FieldIssue {
	if ok && len(issues) == 0 {
		return nil
	}
	return issues
}

func validasiWilayahUbah(m map[string]any, level string) (kode, nama *string, versi int64, issues []errkontrak.FieldIssue) {
	issues = []errkontrak.FieldIssue{}
	ok := true
	// kode (opsional; regex per level bila dikirim)
	if v, ada := m["kode"]; ada {
		s, okS := v.(string)
		var re *regexp.Regexp
		var msg string
		switch level {
		case "provinsi":
			re, msg = kodeProvinsiRE, "Kode provinsi 2 digit."
		case "kota":
			re, msg = kodeKotaRE, "Kode kota/kabupaten 4 digit."
		case "kecamatan":
			re, msg = kodeKecamatanRE, "Kode kecamatan 6 digit."
		default:
			re, msg = kodeKelurahanRE, "Kode kelurahan/desa 10 digit."
		}
		if !okS {
			issues = append(issues, fi("kode", msgExpected("string", namaTipeJSON(v))))
			ok = false
		} else {
			s = strings.TrimSpace(s)
			if !re.MatchString(s) {
				issues = append(issues, fi("kode", msg))
				ok = false
			} else {
				kode = &s
			}
		}
	}
	// nama (opsional; min/max custom — label VERBATIM schemas:
	// kota → "kota/kabupaten", kelurahan → "kelurahan/desa")
	namaLabel := level
	switch level {
	case "kota":
		namaLabel = "kota/kabupaten"
	case "kelurahan":
		namaLabel = "kelurahan/desa"
	}
	msgNamaMin := "Nama " + namaLabel + " wajib diisi."
	msgNamaMax := "Nama " + namaLabel + " maksimal 100 karakter."
	if v, ada := m["nama"]; ada {
		s, okS := v.(string)
		if !okS {
			issues = append(issues, fi("nama", msgExpected("string", namaTipeJSON(v))))
			ok = false
		} else {
			s = strings.TrimSpace(s)
			if len([]rune(s)) < 1 {
				issues = append(issues, fi("nama", msgNamaMin))
				ok = false
			}
			if len([]rune(s)) > 100 {
				issues = append(issues, fi("nama", msgNamaMax))
				ok = false
			}
			if okS {
				nama = &s
			}
		}
	}
	// version (WAJIB)
	if v, o := reqVersion(m, msgVersionUbah, &issues); !o {
		ok = false
	} else {
		versi = v
	}
	if ok && len(issues) == 0 {
		return kode, nama, versi, nil
	}
	return kode, nama, versi, issues
}

func validasiWilayahHapus(m map[string]any) (types.WilayahHapus, []errkontrak.FieldIssue) {
	var out types.WilayahHapus
	issues := []errkontrak.FieldIssue{}
	v, ok := reqVersion(m, msgVersionHapus, &issues)
	if !ok {
		return out, issues
	}
	out.Version = v
	return out, nil
}

// =====================================================================
// Handler WILAYAH — lookup (READ-ONLY; respons list = { data, meta } ATAS)
// =====================================================================

func (h *wilayahHandler) listProvinsi(c echo.Context) error {
	page, err := h.lookup.ListProvinsi(c.Request().Context(), c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *wilayahHandler) getProvinsi(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.lookup.GetProvinsi(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) listKota(c echo.Context) error {
	page, err := h.lookup.ListKota(c.Request().Context(), c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *wilayahHandler) getKota(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.lookup.GetKota(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) listKecamatan(c echo.Context) error {
	page, err := h.lookup.ListKecamatan(c.Request().Context(), c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *wilayahHandler) getKecamatan(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.lookup.GetKecamatan(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) listKelurahan(c echo.Context) error {
	page, err := h.lookup.ListKelurahan(c.Request().Context(), c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *wilayahHandler) getKelurahan(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.lookup.GetKelurahan(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) listKodePos(c echo.Context) error {
	kodepos := c.Param("kodepos")
	if !types.KodePosRE.MatchString(kodepos) {
		return gagalValidasi(c, []errkontrak.FieldIssue{{
			Field:   "kodepos",
			Message: fmt.Sprintf("Kode pos harus tepat 5 digit angka (diterima: %s).", kodepos),
		}})
	}
	page, err := h.lookup.ListKodePos(c.Request().Context(), kodepos, c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// =====================================================================
// Handler WILAYAH ADMIN — CRUD (respons create 201 / update 200 view,
// delete { data: { ok: true } })
// =====================================================================

func (h *wilayahHandler) createProvinsi(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiProvinsiBuat(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	view, err := h.admin.CreateProvinsi(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

func (h *wilayahHandler) updateProvinsi(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	kode, nama, versi, issues := validasiWilayahUbah(m, "provinsi")
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	view, err := h.admin.UpdateProvinsi(c.Request().Context(), id, types.WilayahProvinsiUbah{
		Kode: kode, Nama: nama, Version: versi,
	}, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) deleteProvinsi(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiWilayahHapus(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	out, err := h.admin.DeleteProvinsi(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, out)
}

func (h *wilayahHandler) createKota(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiKotaBuat(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	view, err := h.admin.CreateKota(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

func (h *wilayahHandler) updateKota(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	kode, nama, versi, issues := validasiWilayahUbah(m, "kota")
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	in := types.WilayahKotaUbah{Kode: kode, Nama: nama, Version: versi}
	if jenis, ada := m["jenis"]; ada {
		issues := []errkontrak.FieldIssue{}
		j, okJ := reqEnum(map[string]any{"jenis": jenis}, "jenis",
			[]string{types.JenisKota, types.JenisKabupaten}, "Jenis hanya KOTA atau KABUPATEN.", &issues)
		if issues != nil {
			return gagalValidasi(c, issues)
		}
		if okJ {
			in.Jenis = &j
		}
	}
	if p, ada := m["idCoreProvinsi"]; ada {
		issues := []errkontrak.FieldIssue{}
		pv, okP := optNumberInt(map[string]any{"idCoreProvinsi": p}, "idCoreProvinsi", 1,
			"Provinsi induk wajib — id numerik >= 1.", &issues)
		if issues != nil {
			return gagalValidasi(c, issues)
		}
		if okP {
			in.IDCoreProvinsi = pv
		}
	}
	view, err := h.admin.UpdateKota(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) deleteKota(c echo.Context) error {
	return h.hapusWilayah(c, h.admin.DeleteKota)
}

func (h *wilayahHandler) createKecamatan(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiKecamatanBuat(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	view, err := h.admin.CreateKecamatan(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

func (h *wilayahHandler) updateKecamatan(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	kode, nama, versi, issues := validasiWilayahUbah(m, "kecamatan")
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	in := types.WilayahKecamatanUbah{Kode: kode, Nama: nama, Version: versi}
	if p, ada := m["idCoreKota"]; ada {
		issues := []errkontrak.FieldIssue{}
		pv, okP := optNumberInt(map[string]any{"idCoreKota": p}, "idCoreKota", 1,
			"Kota induk wajib — id numerik >= 1.", &issues)
		if issues != nil {
			return gagalValidasi(c, issues)
		}
		if okP {
			in.IDCoreKota = pv
		}
	}
	view, err := h.admin.UpdateKecamatan(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) deleteKecamatan(c echo.Context) error {
	return h.hapusWilayah(c, h.admin.DeleteKecamatan)
}

func (h *wilayahHandler) createKelurahan(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiKelurahanBuat(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	view, err := h.admin.CreateKelurahan(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

func (h *wilayahHandler) updateKelurahan(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	kode, nama, versi, issues := validasiWilayahUbah(m, "kelurahan")
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	in := types.WilayahKelurahanUbah{Kode: kode, Nama: nama, Version: versi}
	if !kodePosUbah(m, &in, &issues) {
		return gagalValidasi(c, issues)
	}
	if p, ada := m["idCoreKecamatan"]; ada {
		issues := []errkontrak.FieldIssue{}
		pv, okP := optNumberInt(map[string]any{"idCoreKecamatan": p}, "idCoreKecamatan", 1,
			"Kecamatan induk wajib — id numerik >= 1.", &issues)
		if issues != nil {
			return gagalValidasi(c, issues)
		}
		if okP {
			in.IDCoreKecamatan = pv
		}
	}
	view, err := h.admin.UpdateKelurahan(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) deleteKelurahan(c echo.Context) error {
	return h.hapusWilayah(c, h.admin.DeleteKelurahan)
}

// hapusWilayah — pola DELETE wilayah_admin seragam: body {version} wajib;
// delegasi service level itu; respons { data: { ok: true } }.
func (h *wilayahHandler) hapusWilayah(
	c echo.Context,
	hapus func(ctx context.Context, id int64, in types.WilayahHapus, actor audit.Actor) (types.OkTrue, error),
) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiWilayahHapus(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	out, err := hapus(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, out)
}

// =====================================================================
// Validasi query list cluster/agama (zod ekuivalen
// coreClusterListQuerySchema / coreAgamaListQuerySchema):
// search max 120, status AKTIF|NONAKTIF, sort ^-?\w+$, page default 1,
// limit default 50 max 200 (>200 → 400 — BUKAN clamp; zod schema sendiri).
// Detail 400 verbatim audit: `Query pagination/filter tidak sah (VAL-400).`
// =====================================================================

var sortCARe = regexp.MustCompile(`^-?\w+$`)

// utf16Len — panjang gaya JS (UTF-16 code units) untuk max string zod.
func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		n += utf16.RuneLen(r) // 1, atau 2 untuk rune > 0xFFFF
	}
	return n
}

// parseListQueryCA — parse query list cluster/agama; gagal → 400 VAL-400
// dengan detail verbatim audit (issues urut field skema: search, status,
// sort, page, limit).
func parseListQueryCA(c echo.Context) (types.ClusterAgamaListQuery, error) {
	q := c.Request().URL.Query()
	issues := []errkontrak.FieldIssue{}
	out := types.ClusterAgamaListQuery{Page: 1, Limit: 50, SortCol: ""}

	// search — opsional, max 120 (tanpa trim; trim dilakukan repo utk LIKE)
	if vals, ada := q["search"]; ada && len(vals) > 0 {
		s := vals[0]
		if utf16Len(s) > 120 {
			issues = append(issues, fi("search", "Too big: expected string to have <=120 characters"))
		} else {
			v := s
			out.Search = &v
		}
	}
	// status — opsional enum
	if vals, ada := q["status"]; ada && len(vals) > 0 {
		s := vals[0]
		if s != "AKTIF" && s != "NONAKTIF" {
			issues = append(issues, fi("status", `Invalid option: expected one of "AKTIF"|"NONAKTIF"`))
		} else {
			v := s
			out.Status = &v
		}
	}
	// sort — opsional regex ^-?\w+$ (custom message)
	if vals, ada := q["sort"]; ada && len(vals) > 0 {
		s := vals[0]
		if !sortCARe.MatchString(s) {
			issues = append(issues, fi("sort", "Gunakan `field` (ASC) atau `-field` (DESC)"))
		} else {
			out.SortDesc = strings.HasPrefix(s, "-")
			out.SortCol = kanonikSortCA(strings.TrimPrefix(s, "-"))
		}
	}
	// page — coerce default 1, min 1 (tanpa max)
	if vals, ada := q["page"]; ada && len(vals) > 0 {
		n, isNum := coerceNumber(vals[0])
		switch {
		case !isNum:
			issues = append(issues, fi("page", msgNaN))
		case n != float64(int64(n)):
			issues = append(issues, fi("page", msgIntFraction))
		case n < 1:
			issues = append(issues, fi("page", "Too small: expected number to be >=1"))
		default:
			out.Page = int32(n)
		}
	}
	// limit — coerce default 50, min 1 MAX 200 (zod — bukan clamp)
	if vals, ada := q["limit"]; ada && len(vals) > 0 {
		n, isNum := coerceNumber(vals[0])
		switch {
		case !isNum:
			issues = append(issues, fi("limit", msgNaN))
		case n != float64(int64(n)):
			issues = append(issues, fi("limit", msgIntFraction))
		case n < 1:
			issues = append(issues, fi("limit", "Too small: expected number to be >=1"))
		case n > 200:
			issues = append(issues, fi("limit", "Too big: expected number to be <=200"))
		default:
			out.Limit = int32(n)
		}
	}
	if len(issues) > 0 {
		return out, errkontrak.Validation(issues, "Query pagination/filter tidak sah (VAL-400).")
	}
	return out, nil
}

// kanonikSortCA — field sort list cluster/agama — HANYA nama polos
// (schema regex melarang alias lain); whitelist kolom drizzle
// code/nama/urutan/status/created_at|createdAt/updated_at|updatedAt.
// Field di luar whitelist → 400 via shared.SortUnknown.
func kanonikSortCA(field string) string {
	switch field {
	case "code", "nama", "urutan", "status":
		return field
	case "created_at", "createdAt":
		return "created_at"
	case "updated_at", "updatedAt":
		return "updated_at"
	}
	return field // dibiarkan — SortUnknown menolak (pesan verbatim)
}

// validasiSortCA — whitelist sort list cluster/agama via shared.SortUnknown
// (field tidak dikenal → 400 VAL-400 `Field sort tidak dikenal: X.`).
func validasiSortCA(q types.ClusterAgamaListQuery) error {
	if q.SortCol == "" {
		return nil // tanpa param sort → default SQL (urutan ASC, id ASC)
	}
	pr := &errkontrak.PageRequest{Sort: []errkontrak.SortKey{{Field: q.SortCol, Desc: q.SortDesc}}}
	return shared.SortUnknown(pr, []string{
		"code", "nama", "urutan", "status", "created_at", "createdAt", "updated_at", "updatedAt",
	})
}

// =====================================================================
// Validasi DTO cluster (padanan coreClusterCreate/Update/ModulSyncSchema)
// =====================================================================

func validasiClusterBuat(m map[string]any) (types.ClusterBuat, []errkontrak.FieldIssue) {
	var out types.ClusterBuat
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := reqStringTrimMinMax(m, "code", 1, 50, "Kode cluster wajib.", "Kode cluster maksimal 50 karakter.", &issues); !o {
		ok = false
	} else {
		out.Code = v
	}
	if v, o := reqStringTrimMinMax(m, "nama", 1, 100, "Nama cluster wajib.", "Nama cluster maksimal 100 karakter.", &issues); !o {
		ok = false
	} else {
		out.Nama = v
	}
	// deskripsi/icon/tone — trim, max, nullish (NULL bila null/absen)
	if v, _, o := optNullableTrim(m, "deskripsi", 200, &issues); !o {
		ok = false
	} else {
		out.Deskripsi = v
	}
	if v, _, o := optNullableTrim(m, "icon", 50, &issues); !o {
		ok = false
	} else {
		out.Icon = v
	}
	if v, _, o := optNullableTrim(m, "tone", 100, &issues); !o {
		ok = false
	} else {
		out.Tone = v
	}
	// urutan — int min 0, DEFAULT 0; status — enum, DEFAULT "AKTIF"
	if v, ada := m["urutan"]; ada {
		if v2, o := optNumberInt(map[string]any{"urutan": v}, "urutan", 0,
			"Too small: expected number to be >=0", &issues); !o {
			ok = false
		} else if v2 != nil {
			out.Urutan = int32(*v2)
		}
	}
	if v, ada := m["status"]; ada {
		if v2, o := reqEnum(map[string]any{"status": v}, "status",
			[]string{"AKTIF", "NONAKTIF"}, `Invalid option: expected one of "AKTIF"|"NONAKTIF"`, &issues); !o {
			ok = false
		} else {
			out.Status = v2
		}
	} else {
		out.Status = "AKTIF"
	}
	return out, gagalAtauNil(issues, ok)
}

func validasiClusterUbah(m map[string]any) (types.ClusterUbah, []errkontrak.FieldIssue) {
	var out types.ClusterUbah
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, ada := m["code"]; ada {
		issues := []errkontrak.FieldIssue{}
		s, okS := reqStringTrimMinMax(map[string]any{"code": v}, "code", 1, 50,
			"Kode cluster wajib.", "Kode cluster maksimal 50 karakter.", &issues)
		if len(issues) > 0 {
			return out, issues
		}
		if okS {
			out.Code = &s
		}
	}
	if v, ada := m["nama"]; ada {
		issues := []errkontrak.FieldIssue{}
		s, okS := reqStringTrimMinMax(map[string]any{"nama": v}, "nama", 1, 100,
			"Nama cluster wajib.", "Nama cluster maksimal 100 karakter.", &issues)
		if len(issues) > 0 {
			return out, issues
		}
		if okS {
			out.Nama = &s
		}
	}
	if d, isNull, o := optNullableTrim(m, "deskripsi", 200, &issues); !o {
		ok = false
	} else {
		out.Deskripsi, out.DeskripsiNull = d, isNull
	}
	if v, isNull, o := optNullableTrim(m, "icon", 50, &issues); !o {
		ok = false
	} else {
		out.Icon, out.IconNull = v, isNull
	}
	if v, isNull, o := optNullableTrim(m, "tone", 100, &issues); !o {
		ok = false
	} else {
		out.Tone, out.ToneNull = v, isNull
	}
	if v, ada := m["urutan"]; ada {
		issues := []errkontrak.FieldIssue{}
		pv, okP := optNumberInt(map[string]any{"urutan": v}, "urutan", 0,
			"Too small: expected number to be >=0", &issues)
		if issues != nil {
			return out, issues
		}
		if okP && pv != nil {
			u := int32(*pv)
			out.Urutan = &u
		}
	}
	if v, ada := m["status"]; ada {
		issues := []errkontrak.FieldIssue{}
		s, okS := reqEnum(map[string]any{"status": v}, "status",
			[]string{"AKTIF", "NONAKTIF"}, `Invalid option: expected one of "AKTIF"|"NONAKTIF"`, &issues)
		if len(issues) > 0 {
			return out, issues
		}
		if okS {
			out.Status = &s
		}
	}
	// version — WAJIB di body (versionSchema: int min 0); If-Match menang
	// bila ada (diputuskan handler setelah parse).
	if v, ada := m["version"]; ada {
		if v2, o := optNumberInt(map[string]any{"version": v}, "version", 0,
			"Too small: expected number to be >=0", &issues); !o {
			ok = false
		} else if v2 != nil {
			out.Version = *v2
		} else {
			// null → invalid_type (bukan optional)
			issues = append(issues, fi("version", msgExpected("number", "null")))
			ok = false
		}
	} else {
		issues = append(issues, fi("version", msgExpected("number", "undefined")))
		ok = false
	}
	return out, gagalAtauNil(issues, ok)
}

// validasiIDArray — modulIds/fiturIds: array wajib, elemen int >= 1
// (issues path titik: "modulIds.0" — persis zod).
func validasiIDArray(m map[string]any, key string) ([]int64, []errkontrak.FieldIssue) {
	v, ada := m[key]
	if !ada {
		return nil, []errkontrak.FieldIssue{fi(key, msgExpected("array", "undefined"))}
	}
	arr, ok := v.([]any)
	if !ok {
		return nil, []errkontrak.FieldIssue{fi(key, msgExpected("array", namaTipeJSON(v)))}
	}
	out := make([]int64, 0, len(arr))
	issues := []errkontrak.FieldIssue{}
	for i, el := range arr {
		field := fmt.Sprintf("%s.%d", key, i)
		n, okN := el.(float64)
		if !okN {
			issues = append(issues, fi(field, msgExpected("number", namaTipeJSON(el))))
			continue
		}
		if n != float64(int64(n)) {
			issues = append(issues, fi(field, msgIntFraction))
			continue
		}
		if int64(n) < 1 {
			issues = append(issues, fi(field, "Too small: expected number to be >=1"))
			continue
		}
		out = append(out, int64(n))
	}
	if len(issues) > 0 {
		return nil, issues
	}
	return out, nil
}

// =====================================================================
// Handler CLUSTER
// =====================================================================

func (h *wilayahHandler) clusterModulOptions(c echo.Context) error {
	data, err := h.cluster.ModulOptions(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

func (h *wilayahHandler) clusterList(c echo.Context) error {
	q, err := parseListQueryCA(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := validasiSortCA(q); err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.cluster.List(c.Request().Context(), q)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *wilayahHandler) clusterCreate(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiClusterBuat(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	view, err := h.cluster.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

func (h *wilayahHandler) clusterDetail(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	detail, err := h.cluster.Get(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, detail)
}

func (h *wilayahHandler) clusterUpdate(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	ifMatch, err := shared.IfMatchVersion(c.Request())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiClusterUbah(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	// If-Match ATAU body version — If-Match menang (padanan
	// `ifMatchVersion(req) ?? dto.version`).
	expected := &in.Version
	if ifMatch != nil {
		expected = ifMatch
	}
	view, err := h.cluster.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()), expected)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) clusterRemove(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	out, err := h.cluster.Remove(c.Request().Context(), id, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, out) // HttpCode 200 — { data: { id } }
}

func (h *wilayahHandler) clusterSyncModul(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	ids, issues := validasiIDArray(m, "modulIds")
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	rows, err := h.cluster.SyncModul(c.Request().Context(), id, types.ClusterSyncModul{ModulIDs: ids}, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, rows)
}

func (h *wilayahHandler) clusterSyncFitur(c echo.Context) error {
	idModul, err := shared.ParseIDParam(c.Param("idModulCluster"), "idModulCluster")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	ids, issues := validasiIDArray(m, "fiturIds")
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	out, err := h.cluster.SyncFitur(c.Request().Context(), idModul, types.ClusterSyncFitur{FiturIDs: ids}, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, out)
}

// =====================================================================
// Validasi + handler AGAMA (pola cluster minus junction)
// =====================================================================

const msgAgamaEnum = `Invalid option: expected one of "AKTIF"|"NONAKTIF"`

func validasiAgamaBuat(m map[string]any) (types.AgamaBuat, []errkontrak.FieldIssue) {
	var out types.AgamaBuat
	issues := []errkontrak.FieldIssue{}
	ok := true
	if v, o := reqStringTrimMinMax(m, "code", 1, 50, "Kode agama wajib.", "Kode agama maksimal 50 karakter.", &issues); !o {
		ok = false
	} else {
		out.Code = v
	}
	if v, o := reqStringTrimMinMax(m, "nama", 1, 100, "Nama agama wajib.", "Nama agama maksimal 100 karakter.", &issues); !o {
		ok = false
	} else {
		out.Nama = v
	}
	if v, ada := m["urutan"]; ada {
		if v2, o := optNumberInt(map[string]any{"urutan": v}, "urutan", 0,
			"Too small: expected number to be >=0", &issues); !o {
			ok = false
		} else if v2 != nil {
			out.Urutan = int32(*v2)
		}
	}
	if v, ada := m["status"]; ada {
		if v2, o := reqEnum(map[string]any{"status": v}, "status", []string{"AKTIF", "NONAKTIF"}, msgAgamaEnum, &issues); !o {
			ok = false
		} else {
			out.Status = v2
		}
	} else {
		out.Status = "AKTIF"
	}
	return out, gagalAtauNil(issues, ok)
}

func validasiAgamaUbah(m map[string]any) (types.AgamaUbah, []errkontrak.FieldIssue) {
	var out types.AgamaUbah
	issues := []errkontrak.FieldIssue{}
	if v, ada := m["code"]; ada {
		issues := []errkontrak.FieldIssue{}
		s, okS := reqStringTrimMinMax(map[string]any{"code": v}, "code", 1, 50,
			"Kode agama wajib.", "Kode agama maksimal 50 karakter.", &issues)
		if len(issues) > 0 {
			return out, issues
		}
		if okS {
			out.Code = &s
		}
	}
	if v, ada := m["nama"]; ada {
		issues := []errkontrak.FieldIssue{}
		s, okS := reqStringTrimMinMax(map[string]any{"nama": v}, "nama", 1, 100,
			"Nama agama wajib.", "Nama agama maksimal 100 karakter.", &issues)
		if len(issues) > 0 {
			return out, issues
		}
		if okS {
			out.Nama = &s
		}
	}
	if v, ada := m["urutan"]; ada {
		issues := []errkontrak.FieldIssue{}
		pv, okP := optNumberInt(map[string]any{"urutan": v}, "urutan", 0,
			"Too small: expected number to be >=0", &issues)
		if issues != nil {
			return out, issues
		}
		if okP && pv != nil {
			u := int32(*pv)
			out.Urutan = &u
		}
	}
	if v, ada := m["status"]; ada {
		issues := []errkontrak.FieldIssue{}
		s, okS := reqEnum(map[string]any{"status": v}, "status", []string{"AKTIF", "NONAKTIF"}, msgAgamaEnum, &issues)
		if len(issues) > 0 {
			return out, issues
		}
		if okS {
			out.Status = &s
		}
	}
	if v, ada := m["version"]; ada {
		if v2, o := optNumberInt(map[string]any{"version": v}, "version", 0,
			"Too small: expected number to be >=0", &issues); !o {
			return out, issues
		} else if v2 != nil {
			out.Version = *v2
		} else {
			return out, []errkontrak.FieldIssue{fi("version", msgExpected("number", "null"))}
		}
	} else {
		return out, []errkontrak.FieldIssue{fi("version", msgExpected("number", "undefined"))}
	}
	if len(issues) > 0 {
		return out, issues
	}
	return out, nil
}

func (h *wilayahHandler) agamaList(c echo.Context) error {
	q, err := parseListQueryCA(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := validasiSortCA(q); err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.agama.List(c.Request().Context(), q)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *wilayahHandler) agamaCreate(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiAgamaBuat(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	view, err := h.agama.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

func (h *wilayahHandler) agamaDetail(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.agama.Get(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) agamaUpdate(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	ifMatch, err := shared.IfMatchVersion(c.Request())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiAgamaUbah(m)
	if issues != nil {
		return gagalValidasi(c, issues)
	}
	// If-Match ATAU body version — If-Match menang.
	expected := &in.Version
	if ifMatch != nil {
		expected = ifMatch
	}
	view, err := h.agama.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()), expected)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

func (h *wilayahHandler) agamaRemove(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	out, err := h.agama.Remove(c.Request().Context(), id, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, out) // HttpCode 200 — { data: { id } }
}
