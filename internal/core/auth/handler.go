// Handler auth — TIPIS: parse body → Service → bentuk respons `{data}`
// (padanan auth.controller.ts; route/dekorator/HttpCode/pesan VERBATIM).
// Paths TANPA prefix `/api` (diset cmd/api): 5 publik + 3 guard.
package auth

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/config"
	"nexierp/internal/core/errkontrak"
)

// Handler — dependensi handler auth.
type Handler struct {
	svc *Service
	cfg *config.Env
}

// Pendaftar — kontrak minimal router: *echo.Echo maupun *echo.Group
// (prefix global /api diset wiring cmd/api lewat e.Group("/api")).
type Pendaftar interface {
	Group(prefix string, m ...echo.MiddlewareFunc) *echo.Group
	POST(path string, h echo.HandlerFunc, m ...echo.MiddlewareFunc) *echo.Route
	GET(path string, h echo.HandlerFunc, m ...echo.MiddlewareFunc) *echo.Route
}

// Daftarkan — pasang 8 route auth pada router (path tanpa prefix /api).
func Daftarkan(e Pendaftar, svc *Service, cfg *config.Env) {
	h := &Handler{svc: svc, cfg: cfg}

	pub := e.Group("/auth")
	pub.POST("/login", h.login)                             // 200
	pub.POST("/register", h.register)                       // 201
	pub.POST("/aktivasi", h.aktivasi)                       // 200
	pub.POST("/aktivasi/kirim-ulang", h.kirimUlangAktivasi) // 200
	pub.POST("/refresh", h.refresh)                         // 200

	guard := Guard(svc.DB(), cfg)
	priv := e.Group("/auth", guard)
	priv.POST("/logout", h.logout)                  // 200
	priv.GET("/me", h.me)                           // 200
	priv.POST("/change-password", h.changePassword) // 200
}

// ---------------------------------------------------------------------
// Helper kecil
// ---------------------------------------------------------------------

// ipOf — IP asli request (fallback "-" agar NOT NULL terpenuhi).
func ipOf(c echo.Context) string {
	if ip := c.RealIP(); ip != "" {
		return ip
	}
	return "-"
}

// userAgentOf — User-Agent asli request (fallback "unknown").
func userAgentOf(c echo.Context) string {
	if ua := c.Request().Header.Get("User-Agent"); ua != "" {
		return ua
	}
	return "unknown"
}

// badBody — 400 VAL-400 "Body tidak valid" + issues (padanan parseBody).
func badBody(c echo.Context, issues []errkontrak.FieldIssue) error {
	if issues == nil {
		issues = []errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}}
	}
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Body tidak valid", issues)
}

// setSessionCookies — pasang dua Set-Cookie ruang origin (login/refresh).
func setSessionCookies(c echo.Context, cfg *config.Env, accessToken, refreshToken string) {
	for _, ck := range SessionCookies(cfg, c.Request().Header, accessToken, refreshToken) {
		c.Response().Header().Add(echo.HeaderSetCookie, ck)
	}
}

// clearSessionCookies — hapus dua cookie ruang origin (Max-Age=0).
func clearSessionCookies(c echo.Context, cfg *config.Env) {
	for _, ck := range ClearedSessionCookies(cfg, c.Request().Header) {
		c.Response().Header().Add(echo.HeaderSetCookie, ck)
	}
}

// ---------------------------------------------------------------------
// Publik
// ---------------------------------------------------------------------

// login — POST /auth/login (publik, 200): body invalid = 400 (zod),
// kredensial salah = 401; token di-set sebagai cookie httpOnly.
func (h *Handler) login(c echo.Context) error {
	m, ok := decodeJSONBody(c.Request().Body)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiLogin(m)
	if len(issues) > 0 {
		return badBody(c, issues)
	}
	data, err := h.svc.Login(c.Request().Context(), in.Username, in.Password, ipOf(c), userAgentOf(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	setSessionCookies(c, h.cfg, data.AccessToken, data.RefreshToken)
	return errkontrak.OK(c, data)
}

// register — POST /auth/register (publik, 201): akun NONAKTIF + tautan
// aktivasi dikirim ke email; TANPA cookie sesi.
func (h *Handler) register(c echo.Context) error {
	m, ok := decodeJSONBody(c.Request().Body)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiRegister(m)
	if len(issues) > 0 {
		return badBody(c, issues)
	}
	data, err := h.svc.Register(c.Request().Context(), in, ipOf(c), userAgentOf(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, data)
}

// aktivasi — POST /auth/aktivasi (publik, 200): one-time + TTL 24 jam;
// idempoten untuk klik ganda.
func (h *Handler) aktivasi(c echo.Context) error {
	m, ok := decodeJSONBody(c.Request().Body)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiAktivasi(m)
	if len(issues) > 0 {
		return badBody(c, issues)
	}
	if err := h.svc.Aktivasi(c.Request().Context(), in.Token); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

// kirimUlangAktivasi — POST /auth/aktivasi/kirim-ulang (publik, 200):
// SELALU ok (anti-enumerasi email).
func (h *Handler) kirimUlangAktivasi(c echo.Context) error {
	m, ok := decodeJSONBody(c.Request().Body)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiKirimUlang(m)
	if len(issues) > 0 {
		return badBody(c, issues)
	}
	if err := h.svc.KirimUlangAktivasi(c.Request().Context(), in.Email); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

// refresh — POST /auth/refresh (publik, 200): refresh token dari body
// ATAU cookie ruang request; pasangan baru di-set ulang sebagai cookie.
func (h *Handler) refresh(c echo.Context) error {
	// safeParse gagal → fallback cookie (body opsional).
	refreshToken := ""
	if m, ok := decodeJSONBody(c.Request().Body); ok {
		refreshToken = refreshFromBody(m)
	}
	if refreshToken == "" {
		refreshToken = CookieRefreshOf(h.cfg, c.Request().Header)
	}
	if refreshToken == "" {
		return errkontrak.WriteProblem(c, http.StatusBadRequest, "",
			"Refresh token tidak ada (body atau cookie ruang request).", nil)
	}
	data, err := h.svc.Refresh(c.Request().Context(), refreshToken, ipOf(c), userAgentOf(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	setSessionCookies(c, h.cfg, data.AccessToken, data.RefreshToken)
	return errkontrak.OK(c, data)
}

// ---------------------------------------------------------------------
// Guard
// ---------------------------------------------------------------------

// logout — POST /auth/logout (guard, 200): sesi dicabut + cookie
// SELALU dibersihkan; aktor dari req.user (bukan payload client).
func (h *Handler) logout(c echo.Context) error {
	if user := From(c); user != nil {
		actor := audit.Actor{
			IDCoreUsers: &user.ID,
			ActorName:   user.Username,
			IPAddress:   ipOf(c),
			UserAgent:   userAgentOf(c),
		}
		if err := h.svc.Logout(c.Request().Context(), user.SessionID, &actor); err != nil {
			return errkontrak.Map(c, err)
		}
	}
	clearSessionCookies(c, h.cfg)
	return errkontrak.OK(c, map[string]any{"ok": true})
}

// me — GET /auth/me (guard, 200): profil + roles + permission efektif +
// menu + id karyawan ter-link.
func (h *Handler) me(c echo.Context) error {
	user := From(c)
	if user == nil {
		return errkontrak.WriteProblem(c, http.StatusUnauthorized, errkontrak.CodeAuth401, pesanToken401, nil)
	}
	data, err := h.svc.Me(c.Request().Context(), user.ID)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// changePassword — POST /auth/change-password (guard, 200): pre-parse
// gagal → 400 VAL-400 pesan spesifik + issues (verbatim controller).
func (h *Handler) changePassword(c echo.Context) error {
	m, ok := decodeJSONBody(c.Request().Body)
	if !ok {
		return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400,
			"Body tidak valid (newPassword minimal 6 karakter).", nil)
	}
	in, issues := validasiChangePassword(m)
	if len(issues) > 0 {
		return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400,
			"Body tidak valid (newPassword minimal 6 karakter).", issues)
	}
	user := From(c)
	if user == nil {
		return errkontrak.WriteProblem(c, http.StatusUnauthorized, errkontrak.CodeAuth401, pesanToken401, nil)
	}
	if err := h.svc.ChangePassword(c.Request().Context(), user.ID,
		in.CurrentPassword, in.NewPassword, ipOf(c), userAgentOf(c)); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}
