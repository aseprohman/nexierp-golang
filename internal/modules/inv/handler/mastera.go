// Handler MASTER-A — permukaan HTTP murni keenam fitur master inv (padanan
// controllers/master/{produk,produk-induk,kategori,unit,unit-konversi,
// kemasan}.controller.ts NestJS): bind body/query → validasi zod-parity
// (pesan & urutan issue PERSIS packages/schemas inv/schemas.ts) → delegasi
// service → bentuk respons dan problem+json PERSIS NestJS. Tanpa query SQL,
// tanpa aturan bisnis. Permission ROUTE-CENTRIC: guard group mencocokkan
// (method, path) → inventory.master.* di core_routes (PERSIS @UseGuards).
//
// Satu pintu: DaftarkanMasterA(api, d) — dipanggil DaftarkanMaster modul inv.
// Route statis (`lookup`) dideklarasikan SEBELUM `:id` agar tidak tertelan
// param dinamis (urutan registrasi route Nest).
package handler

import (
	"github.com/labstack/echo/v4"

	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// DaftarkanMasterA — pasang 30 route keenam fitur MASTER-A di bawah
// /inventory/master/* (guard auth + RBAC route-centric persis controller
// NestJS).
func DaftarkanMasterA(api *echo.Group, d types.Deps) {
	produk := service.NewProdukService(d.DB, d.Audit)
	induk := service.NewProdukIndukService(d.DB, d.Audit)
	kategori := service.NewKategoriService(d.DB, d.Audit)
	unit := service.NewUnitService(d.DB, d.Audit)
	konversi := service.NewUnitKonversiService(d.DB, d.Audit)
	kemasan := service.NewKemasanService(d.DB, d.Audit)

	/* ---------------- produk ---------------- */
	g := api.Group("/inventory/master/produk", d.AuthGuard, d.RbacGuard)
	g.GET("", hProdukList(produk))          // GET /produk
	g.POST("", hProdukCreate(produk))       // POST /produk (201)
	g.GET("/lookup", hProdukLookup(produk)) // GET /produk/lookup (SEBELUM :id)
	g.GET("/:id", hProdukGet(produk))       // GET /produk/:id
	g.PATCH("/:id", hProdukUpdate(produk))  // PATCH /produk/:id (409 INV-017)
	g.DELETE("/:id", hProdukRemove(produk)) // DELETE /produk/:id (409 INV-002)

	/* ---------------- produk-induk ---------------- */
	g = api.Group("/inventory/master/produk-induk", d.AuthGuard, d.RbacGuard)
	g.GET("", hIndukList(induk))                       // GET /produk-induk
	g.POST("", hIndukCreate(induk))                    // POST /produk-induk (201)
	g.GET("/:id", hIndukGet(induk))                    // GET /produk-induk/:id
	g.PATCH("/:id", hIndukUpdate(induk))               // PATCH /produk-induk/:id
	g.DELETE("/:id", hIndukRemove(induk))              // DELETE /produk-induk/:id
	g.PUT("/:id/atribut", hIndukReplaceAtribut(induk)) // PUT .../:id/atribut
	g.POST("/:id/varian", hIndukGenerateVarian(induk)) // POST .../:id/varian (201)

	/* ---------------- kategori ---------------- */
	g = api.Group("/inventory/master/kategori", d.AuthGuard, d.RbacGuard)
	g.GET("", hKategoriList(kategori))
	g.POST("", hKategoriCreate(kategori))
	g.GET("/:id", hKategoriGet(kategori))
	g.PATCH("/:id", hKategoriUpdate(kategori))
	g.DELETE("/:id", hKategoriRemove(kategori))

	/* ---------------- unit ---------------- */
	g = api.Group("/inventory/master/unit", d.AuthGuard, d.RbacGuard)
	g.GET("", hUnitList(unit))
	g.POST("", hUnitCreate(unit))
	g.GET("/:id", hUnitGet(unit))
	g.PATCH("/:id", hUnitUpdate(unit))
	g.DELETE("/:id", hUnitRemove(unit))

	/* ---------------- unit-konversi ---------------- */
	g = api.Group("/inventory/master/unit-konversi", d.AuthGuard, d.RbacGuard)
	g.GET("", hKonversiList(konversi))
	g.POST("", hKonversiCreate(konversi))
	g.GET("/:id", hKonversiGet(konversi))
	g.PATCH("/:id", hKonversiUpdate(konversi))
	g.DELETE("/:id", hKonversiRemove(konversi))

	/* ---------------- kemasan ---------------- */
	g = api.Group("/inventory/master/kemasan", d.AuthGuard, d.RbacGuard)
	g.GET("", hKemasanList(kemasan))
	g.POST("", hKemasanCreate(kemasan))
	g.GET("/lookup", hKemasanLookup(kemasan)) // WAJIB sebelum :id (persis Nest)
	g.GET("/:id", hKemasanGet(kemasan))
	g.PATCH("/:id", hKemasanUpdate(kemasan))
	g.DELETE("/:id", hKemasanRemove(kemasan))
}
