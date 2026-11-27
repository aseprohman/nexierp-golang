// Package handler — permukaan HTTP fitur FILES modul core (padanan
// controllers/files/files.controller.ts): media library terpusat
// /system/files — 9 endpoint, guard AuthGuard + RbacGuard (route-centric
// via core_routes). Metadata di core_files + core_media_categories (ddl/
// 01c + ddl/44); fisik HANYA di S3/MinIO (bucket nexierp).
//
// Endpoint:
//
//	POST   /system/files              — unggah (base64 JSON; cap 8 MB kernel)
//	GET    /system/files              — daftar file HIDUP (envelope Page)
//	GET    /system/files/kategori     — kategori hidup + jumlahFile
//	POST   /system/files/kategori     — tambah kategori (409 NAMA_DIPAKAI)
//	PATCH  /system/files/kategori/:id — ubah kategori (409 VERSI_BENTROK)
//	DELETE /system/files/kategori/:id — soft delete + SET NULL file terkait
//	GET    /system/files/:id/raw      — stream binary same-origin (inline)
//	GET    /system/files/:id/url      — presigned URL GET (1 jam)
//	DELETE /system/files/:id          — soft delete file (object MinIO tetap)
//
// Rute STATIS "kategori" dideklarasikan SEBELUM rute ber-parameter agar
// tidak tertelan :id (verbatim urutan controller NestJS). Handler TIPIS:
// bind → validasi (di service, zod-verbatim) → delegasi → pemetaan error;
// orkestrasi & tx ada di kernel storage.MediaLibraryService.
package handler

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/service"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// DaftarkanFiles — pasang 9 endpoint /system/files di bawah group api
// (prefix /api) dengan guard AuthGuard + RbacGuard.
func DaftarkanFiles(api *echo.Group, d types.Deps) {
	h := &filesHandlers{svc: service.NewFilesService(d.Media)}
	g := api.Group("/system/files", d.AuthGuard, d.RbacGuard)

	// --- kategori (rute statis — SEBELUM rute ber-parameter) ------------
	g.GET("/kategori", h.listKategori)
	g.POST("/kategori", h.createKategori)
	g.PATCH("/kategori/:id", h.updateKategori)
	g.DELETE("/kategori/:id", h.removeKategori)

	// --- rute ber-parameter (file) ---------------------------------------
	g.POST("", h.upload)
	g.GET("", h.list)
	g.GET("/:id/raw", h.streamRaw)
	g.GET("/:id/url", h.signedUrl)
	g.DELETE("/:id", h.removeFile)
}

// filesHandlers — satu struct handler fitur (method BERNAMA — nama runtime
// `...handler.(*filesHandlers).upload-fm` stabil untuk permission code
// cmd/scanroute `{modul}.{fitur}.{action}`).
type filesHandlers struct {
	svc *service.FilesService
}

/* -------------------------------------------------------------- */
/* File                                                            */
/* -------------------------------------------------------------- */

// upload — POST "" — unggah file (base64 JSON, BUKAN multipart; cap 8 MB
// ditegakkan kernel) → 201 {data: FileView}.
func (h *filesHandlers) upload(c echo.Context) error {
	body, ok := decodeFilesBody(c.Request().Body)
	if !ok {
		return filesBadBody(c)
	}
	view, err := h.svc.Upload(c.Request().Context(), body, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// list — GET "" — daftar file HIDUP (soft-deleted tak pernah tampil) —
// envelope Page {data, meta:{page,limit,total,totalPages}}.
func (h *filesHandlers) list(c echo.Context) error {
	page, err := h.svc.List(c.Request().Context(), c.QueryParams())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// streamRaw — GET /:id/raw — STREAM isi file same-origin (GetObject
// INTERNAL MinIO, tanpa presigned URL) untuk <img>/<video>/<iframe> FE
// (validasi cookie sesi httpOnly). id = entity_id UUID ATAU id numerik.
// Content-Disposition inline dengan filename tersanitasi (header
// injection-safe); Content-Length hanya bila S3 mengirim ukuran.
func (h *filesHandlers) streamRaw(c echo.Context) error {
	fs, err := h.svc.StreamRaw(c.Request().Context(), c.Param("id"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	hdr := c.Response().Header()
	hdr.Set(echo.HeaderContentDisposition,
		fmt.Sprintf(`inline; filename="%s"`, filesInlineName.Replace(fs.FileName)))
	if fs.Size != nil {
		hdr.Set(echo.HeaderContentLength, strconv.FormatInt(*fs.Size, 10))
	}
	defer fs.Body.Close()
	return c.Stream(http.StatusOK, fs.ContentType, fs.Body)
}

// signedUrl — GET /:id/url — presigned URL GET (1 jam) — `?inline=1|true`
// untuk preview (PDF render di iframe, image di <img>); default attachment
// (unduh). 404 bila file tak ada / sudah soft-deleted.
func (h *filesHandlers) signedUrl(c echo.Context) error {
	inline := c.QueryParam("inline") == "1" || c.QueryParam("inline") == "true"
	v, err := h.svc.SignedURL(c.Request().Context(), c.Param("id"), inline)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, v)
}

// removeFile — DELETE /:id — SOFT DELETE registry (deleted_at + version+1
// dalam tx + audit); object MinIO TIDAK dihapus (sweep terpisah — deferred).
func (h *filesHandlers) removeFile(c echo.Context) error {
	if err := h.svc.Remove(c.Request().Context(), c.Param("id"), shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

/* -------------------------------------------------------------- */
/* Kategori library (ddl/44)                                       */
/* -------------------------------------------------------------- */

// listKategori — GET /kategori — kategori HIDUP (ORDER nama ASC) + jumlah
// file hidup per kategori; filter idCoreModules opsional.
func (h *filesHandlers) listKategori(c echo.Context) error {
	rows, err := h.svc.ListKategori(c.Request().Context(), c.QueryParams())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, rows)
}

// createKategori — POST /kategori — tambah kategori (NULL modul = kategori
// bersama) → 201; 409 NAMA_DIPAKAI bila nama dipakai dalam lingkup modul
// yang sama; 404 bila modul tidak ada.
func (h *filesHandlers) createKategori(c echo.Context) error {
	body, ok := decodeFilesBody(c.Request().Body)
	if !ok {
		return filesBadBody(c)
	}
	view, err := h.svc.CreateKategori(c.Request().Context(), body, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// updateKategori — PATCH /kategori/:id — ubah kategori (optimistic lock
// `version` wajib; 409 VERSI_BENTROK bila stale) — version naik +1.
func (h *filesHandlers) updateKategori(c echo.Context) error {
	body, ok := decodeFilesBody(c.Request().Body)
	if !ok {
		return filesBadBody(c)
	}
	view, err := h.svc.UpdateKategori(c.Request().Context(), c.Param("id"), body, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// removeKategori — DELETE /kategori/:id — soft delete + DALAM tx yang sama
// file hidup terkait di-SET NULL ("Tanpa kategori") — aset aman.
func (h *filesHandlers) removeKategori(c echo.Context) error {
	if err := h.svc.RemoveKategori(c.Request().Context(), c.Param("id"), shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

/* -------------------------------------------------------------- */
/* Helper kecil                                                    */
/* -------------------------------------------------------------- */

// filesInlineName — buang `"`, `\`, `\r`, `\n` dari nama file untuk header
// Content-Disposition (verbatim regex /["\\\r\n]/g controller NestJS).
var filesInlineName = strings.NewReplacer(`"`, "", `\`, "", "\r", "", "\n", "")

// decodeFilesBody — body JSON → map (padanan safeParse zod pada req.body):
// body kosong = objek kosong (issue "Required" per field — persis zod);
// JSON rusak / bukan objek → ok=false (400 "Body tidak valid").
func decodeFilesBody(r io.Reader) (map[string]any, bool) {
	body, err := io.ReadAll(r)
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

// filesBadBody — 400 VAL-400 "Body tidak valid" + issues (padanan jalur
// body-parser NestJS; parseWith menangani validasi skema di service).
func filesBadBody(c echo.Context) error {
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400,
		"Body tidak valid", []errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}})
}
