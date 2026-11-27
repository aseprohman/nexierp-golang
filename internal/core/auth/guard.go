// Guard JWT + helper sesi — port persis guards/jwt-auth.guard.ts:
// token dari Authorization Bearer (case-insensitive) ATAU cookie ruang
// origin; verify HS256; klaim wajib; validasi sesi + user aktif DI SERVER
// per request. Gagal → 401 AUTH-401 "Token akses tidak valid atau
// kedaluwarsa."
package auth

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/labstack/echo/v4"

	"nexierp/internal/core/auth/repository"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
)

// DBTX — padanan gen.DBTX sqlc: *pgxpool.Pool dan pgx.Tx keduanya
// memenuhi (kontrak executor untuk CekSesiAktif & service audit).
type DBTX interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// Kunci context echo untuk *User hasil guard.
const ctxKeyUser = "nexierp.auth.user"

const pesanToken401 = "Token akses tidak valid atau kedaluwarsa."

// CekSesiAktif — validasi sesi + user aktif (port loadValidUser guard):
// is_valid, belum revoked/logout, expires_at > now, session.id_core_users
// == userID, user is_active. Pelanggaran = DomainError 401 AUTH-401;
// error DB mentah diteruskan apa adanya (→ 500 oleh errkontrak.Map).
func CekSesiAktif(ctx context.Context, exec DBTX, sid int64, userID int64) error {
	gagal := errkontrak.Unauthorized(pesanToken401, errkontrak.CodeAuth401)

	repo := repository.New(exec)
	ses, err := repo.GetSesiByID(ctx, sid)
	if err != nil {
		return err
	}
	if ses == nil {
		return gagal
	}
	now := time.Now()
	if !ses.IsValid || ses.RevokedAt != nil || ses.LogoutAt != nil || !ses.ExpiresAt.After(now) {
		return gagal
	}
	if ses.IDCoreUsers != userID {
		return gagal
	}
	aktif, err := repo.GetUserAktifByID(ctx, userID)
	if err != nil {
		return err
	}
	if !aktif {
		return gagal
	}
	return nil
}

// Guard — middleware echo: autentikasi token akses → simpan *User di
// context. Kontrak export untuk modul lain (dipakai modul L2/L3).
func Guard(d *database.DB, cfg *config.Env) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			user, dbErr := autentikasi(cfg, d, c)
			if dbErr != nil {
				// Error DB mentah → 500 via Map (persis jalur filter NestJS).
				return errkontrak.Map(c, dbErr)
			}
			if user == nil {
				return errkontrak.WriteProblem(c, http.StatusUnauthorized, errkontrak.CodeAuth401, pesanToken401, nil)
			}
			c.Set(ctxKeyUser, user)
			return next(c)
		}
	}
}

// From — *User hasil guard dari echo.Context (nil bila tanpa guard).
func From(c echo.Context) *User {
	u, _ := c.Get(ctxKeyUser).(*User)
	return u
}

// autentikasi — port authenticate(): token dari header Bearer ATAU cookie
// ruang request → verify → validasi sesi. (nil, nil) = tidak sah (401);
// (nil, err) = kegagalan DB (500 via errkontrak.Map).
func autentikasi(cfg *config.Env, d *database.DB, c echo.Context) (*User, error) {
	header := c.Request().Header.Get("Authorization")
	token := ""
	if len(header) >= 7 && strings.EqualFold(header[:7], "bearer ") {
		token = strings.TrimSpace(header[7:])
	}
	// Cookie RUANG request — portal member (ecom_at) & backoffice (nexierp_at).
	if token == "" {
		token = CookieAksesOf(cfg, c.Request().Header)
	}
	if token == "" {
		return nil, nil
	}
	claims, err := ParseAccessToken(cfg.JWTAccessSecret, token)
	if err != nil || claims.SID == 0 || claims.Sub == 0 || claims.Username == "" {
		return nil, nil
	}
	if err := CekSesiAktif(c.Request().Context(), d.Pool, claims.SID, claims.Sub); err != nil {
		// DomainError (sesi/user tidak sah) = 401 baku; lainnya diteruskan.
		if _, domain := errkontrak.AsDomain(err); domain {
			return nil, nil
		}
		return nil, err
	}
	return &User{ID: claims.Sub, Username: claims.Username, SessionID: claims.SID}, nil
}

// FromReq — padanan From untuk http.Request mentah (dipakai helper
// lintas-paket yang tidak membawa echo.Context).
func FromReq(req *http.Request) *User {
	u, _ := req.Context().Value(ctxKeyUser).(*User)
	return u
}
