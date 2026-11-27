// handler/gudang.go — endpoint HTTP fitur GUDANG modul inv (padanan
// GudangController NestJS — CRUD /inventory/master/gudang, 5 endpoint;
// semua jalur baca/ubah/hapus ter-scope dimensi 'storages' di service).
// Validasi body = zod-parity gudangCreateSchema/gudangUpdateSchema
// (pesan & urutan issue verbatim); PATCH menerima `kode` (divalidasi,
// tidak dipakai — quirk verbatim service).
package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// daftarkanGudang — pasang 5 route gudang (guard auth + RBAC route-centric).
func daftarkanGudang(api *echo.Group, d types.Deps) {
	h := &GudangHandler{svc: service.NewGudangService(d)}
	g := api.Group("/inventory/master/gudang", d.AuthGuard, d.RbacGuard)
	g.GET("", h.daftar)       // GET /inventory/master/gudang
	g.POST("", h.buat)        // POST /inventory/master/gudang (201)
	g.GET("/:id", h.ambil)    // GET /inventory/master/gudang/:id
	g.PATCH("/:id", h.ubah)   // PATCH /inventory/master/gudang/:id
	g.DELETE("/:id", h.hapus) // DELETE /inventory/master/gudang/:id
}

// GudangHandler — dependensi handler gudang.
type GudangHandler struct {
	svc *service.GudangService
}

// daftar — GET /inventory/master/gudang — halaman gudang (ter-scope).
func (h *GudangHandler) daftar(c echo.Context) error {
	pr, err := mbPageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.svc.List(c.Request().Context(), pr, mbUserID(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// buat — POST /inventory/master/gudang — 201 {data}.
func (h *GudangHandler) buat(c echo.Context) error {
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbGudangCreate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Create(c.Request().Context(), in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// ambil — GET /inventory/master/gudang/:id — {data} (404 di luar cakupan).
func (h *GudangHandler) ambil(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.svc.Get(c.Request().Context(), id, mbUserID(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// ubah — PATCH /inventory/master/gudang/:id — version WAJIB di body.
func (h *GudangHandler) ubah(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbGudangUpdate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Update(c.Request().Context(), id, in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// hapus — DELETE /inventory/master/gudang/:id — {data:{ok:true}}.
func (h *GudangHandler) hapus(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := h.svc.Remove(c.Request().Context(), id, mbActor(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

/* -------------------------------------------------------------- */
/* Validasi zod-parity gudangCreateSchema                          */
/* -------------------------------------------------------------- */

// mbGudangCreate — pesan & urutan issue persis skema (deklarasi field
// berurutan: kode, nama, kodeSatuan, alamat, idCoreKelurahan, latitude,
// longitude, status).
func mbGudangCreate(m map[string]any) (service.GudangCreateInput, []errkontrak.FieldIssue) {
	var in service.GudangCreateInput
	issues := []errkontrak.FieldIssue{}

	kode, _ := mbZodString(m, "kode", 1, 50, reKodeInv, "Kode: huruf/angka/. _ -", "Kode gudang wajib.", true, false, &issues)
	in.Kode = kode

	nama, _ := mbZodString(m, "nama", 1, 100, nil, "", "Nama gudang wajib.", true, false, &issues)
	in.Nama = nama

	if v, ada := mbZodString(m, "kodeSatuan", 0, 50, nil, "", "", false, true, &issues); ada {
		s := v
		in.KodeSatuan = &s
	}
	if v, ada := mbZodString(m, "alamat", 0, 300, nil, "", "", false, true, &issues); ada {
		s := v
		in.Alamat = &s
	}
	if v, _ := mbZodID(m, "idCoreKelurahan", &issues); v != nil {
		in.IDCoreKelurahan = v
	}
	if v, _ := mbZodNumNullish(m, "latitude", -90, 90, "Latitude -90..90.", "Latitude -90..90.", &issues); v != nil {
		in.Latitude = v
	}
	if v, _ := mbZodNumNullish(m, "longitude", -180, 180, "Longitude -180..180.", "Longitude -180..180.", &issues); v != nil {
		in.Longitude = v
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	} else {
		in.Status = "AKTIF" // z.enum(STATUS_AKTIF).default("AKTIF")
	}
	return in, issues
}

// mbGudangUpdate — gudangUpdateSchema = create.partial() + version wajib.
// `kode` divalidasi bila dikirim tapi TIDAK dipakai service (quirk verbatim).
func mbGudangUpdate(m map[string]any) (service.GudangUpdateInput, []errkontrak.FieldIssue) {
	var in service.GudangUpdateInput
	issues := []errkontrak.FieldIssue{}

	mbZodString(m, "kode", 1, 50, reKodeInv, "Kode: huruf/angka/. _ -", "Kode gudang wajib.", false, false, &issues)

	if v, ada := mbZodString(m, "nama", 1, 100, nil, "", "Nama gudang wajib.", false, false, &issues); ada {
		s := v
		in.Nama = &s
	}
	// kodeSatuan/alamat .nullish() — null eksplisit = 3-state clear.
	if v, ada := mbZodStringPtr(m, "kodeSatuan", 0, 50, true, &issues); ada {
		in.KodeSatuan, in.KodeSatuanAda = v, true
	}
	if v, ada := mbZodStringPtr(m, "alamat", 0, 300, true, &issues); ada {
		in.Alamat, in.AlamatAda = v, true
	}
	if v, ada := mbZodID(m, "idCoreKelurahan", &issues); ada {
		in.IDCoreKelurahan, in.IDCoreKelurahanAda = v, true
	}
	if v, ada := mbZodNumNullish(m, "latitude", -90, 90, "Latitude -90..90.", "Latitude -90..90.", &issues); ada {
		in.Latitude, in.LatitudeAda = v, true
	}
	if v, ada := mbZodNumNullish(m, "longitude", -180, 180, "Longitude -180..180.", "Longitude -180..180.", &issues); ada {
		in.Longitude, in.LongitudeAda = v, true
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	}
	in.Version = mbVersion(m, &issues)
	return in, issues
}
