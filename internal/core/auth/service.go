// Service autentikasi — porting PERSIS services/auth.service.ts NestJS:
// urutan cek login (unknown → inactive → locked → password), lockout
// state server-side dalam transaksi, sesi + audit + trail SATU tx,
// register member portal + token aktivasi email, refresh tanpa rotasi
// sesi, logout, me, ganti password, sweep core_auth_tokens.
package auth

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/auth/repository"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
)

// AuditSink — interface lokal kecil untuk decouple dari service audit
// (di-wiring cmd/api dari audit.New; agent infra menyediakan AppendOne).
type AuditSink interface {
	AppendOne(ctx context.Context, exec pgx.Tx, entry audit.AppendInput) (int64, error)
}

// Service — kernel auth. PermissionSet & KirimAktivasi DI-INJECT dari
// cmd/api (dilarang import rbac/mailer langsung).
type Service struct {
	db    *database.DB
	cfg   *config.Env
	audit AuditSink

	// PermissionSet — permission efektif user via rbac compiler (wiring
	// cmd/api). Nil = permission kosong.
	PermissionSet func(ctx context.Context, userID int64) ([]string, error)

	// KirimAktivasi — pengirim email aktivasi (wiring cmd/api dari mailer).
	// Nil = email dilewati (registrasi tetap sukses).
	KirimAktivasi func(ctx context.Context, payload MailAktivasiPayload)

	logger *slog.Logger
}

// NewService — repo pool-level dibuat sekali; di dalam transaksi selalu
// pakai repository.New(tx).
func NewService(db *database.DB, cfg *config.Env, audit AuditSink) *Service {
	return &Service{
		db:     db,
		cfg:    cfg,
		audit:  audit,
		logger: slog.Default(),
	}
}

// DB — akses pool untuk guard (wiring cmd/api).
func (s *Service) DB() *database.DB { return s.db }

// SetLogger — logger aplikasi dari cmd/api (opsional).
func (s *Service) SetLogger(l *slog.Logger) {
	if l != nil {
		s.logger = l
	}
}

// ---------------------------------------------------------------------
// Login
// ---------------------------------------------------------------------

// Alasan gagal login — enum pg core_login_fail_reason.
const (
	failUnknownUser   = "unknown_user"
	failWrongPassword = "wrong_password"
	failLocked        = "locked"
	failInactive      = "inactive"
)

// Login — autentikasi username/password; pesan & urutan cek persis kode
// asli `authenticate`. Membuat sesi + token + audit dalam SATU tx.
func (s *Service) Login(ctx context.Context, rawUsername, password, ip, userAgent string) (*TokenPairResult, error) {
	uname := strings.ToLower(strings.TrimSpace(rawUsername))
	settings, err := s.GetSecuritySettings(ctx)
	if err != nil {
		return nil, err
	}
	safeIp, safeUa := amanIpUA(ip, userAgent)

	user, err := s.repo().GetUserByUsername(ctx, uname)
	if err != nil {
		return nil, err
	}

	// 1) Username tak terdaftar — pesan netral, audit unknown_user.
	if user == nil {
		if err := s.tulisGagalLogin(ctx, nil, uname, failUnknownUser, uname, safeIp, safeUa); err != nil {
			return nil, err
		}
		return nil, errkontrak.Unauthorized("Username tidak terdaftar.", errkontrak.CodeAuth401)
	}

	// 2) Akun nonaktif — bedakan member portal BELUM AKTIVASI email dari
	//    akun dinonaktifkan admin (pesan mengarah ke tautan aktivasi).
	if !user.IsActive {
		if err := s.tulisGagalLogin(ctx, &user.ID, uname, failInactive, user.Name, safeIp, safeUa); err != nil {
			return nil, err
		}
		memberPortal, err := s.repo().PunyaRoleKode(ctx, user.ID, "ecom_member")
		if err != nil {
			return nil, err
		}
		if memberPortal {
			return nil, errkontrak.Unauthorized(
				"Akun belum diaktivasi — buka tautan aktivasi yang dikirim ke email Anda, atau minta tautan baru di halaman masuk.",
				errkontrak.CodeAuth401)
		}
		return nil, errkontrak.Unauthorized("Akun dinonaktifkan. Hubungi administrator.", errkontrak.CodeAuth401)
	}

	// 3) Terkunci (locked_until > now) — cek SEBELUM verifikasi password.
	if user.LockedUntil != nil && user.LockedUntil.After(time.Now()) {
		if err := s.tulisGagalLogin(ctx, &user.ID, uname, failLocked, user.Name, safeIp, safeUa); err != nil {
			return nil, err
		}
		until := formatJamMenit(*user.LockedUntil)
		return nil, errkontrak.Unauthorized(
			fmt.Sprintf("Akun terkunci sementara (hingga %s) karena terlalu banyak percobaan gagal.", until),
			errkontrak.CodeAuth401)
	}

	// 4) Verifikasi password — argon2, atau plaintext seed (upgrade-on-login).
	passwordOk, err := VerifyPassword(user.PasswordHash, password)
	if err != nil {
		return nil, err
	}
	if !passwordOk {
		failed := user.FailedLoginAttempts + 1
		locked := int(failed) >= settings.MaxFailedAttempts
		var lockedUntil *time.Time
		if locked {
			t := time.Now().Add(time.Duration(settings.LockoutMinutes) * time.Minute)
			lockedUntil = &t
		} else {
			lockedUntil = user.LockedUntil
		}
		reason := failWrongPassword
		if locked {
			reason = failLocked
		}
		err = s.db.Tx(ctx, func(tx pgx.Tx) error {
			rt := repository.New(tx)
			if err := rt.UpdateLoginGagal(ctx, failed, lockedUntil, user.ID); err != nil {
				return err
			}
			return s.tulisGagalLoginTx(ctx, tx, &user.ID, uname, reason, user.Name, safeIp, safeUa)
		})
		if err != nil {
			return nil, err
		}
		if locked {
			return nil, errkontrak.Unauthorized(
				fmt.Sprintf("Password salah %d× — akun terkunci %d menit.", failed, settings.LockoutMinutes),
				errkontrak.CodeAuth401)
		}
		return nil, errkontrak.Unauthorized(
			fmt.Sprintf("Password salah (percobaan %d/%d).", failed, settings.MaxFailedAttempts),
			errkontrak.CodeAuth401)
	}

	// 5) Sukses — upgrade-on-login password seed plaintext (idempoten):
	//    hash sekali DI LUAR tx (kerja CPU argon2), tulis di dalam tx.
	needsUpgrade := !strings.HasPrefix(user.PasswordHash, "$argon2")
	var upgradedHash string
	if needsUpgrade {
		upgradedHash = HashPassword(password)
	}

	now := time.Now()
	expiresAt := now.Add(time.Duration(settings.SessionTtlHours) * time.Hour)

	var sessionID int64
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		rt := repository.New(tx)
		var upg *string
		if needsUpgrade {
			upg = &upgradedHash
		}
		if err := rt.UpdateLoginSukses(ctx, user.ID, now, upg); err != nil {
			return err
		}
		// device_key = uuid acak per login — TANPA dedup (tiap login =
		// perangkat baru; padanan mockup randomUUID()).
		sessionID, err = rt.InsertSesi(ctx, user.ID, user.Name, RandomUUID(), now, expiresAt, safeIp, safeUa)
		if err != nil {
			return err
		}
		if err := rt.InsertLoginAudit(ctx, repository.LoginAuditParams{
			IDCoreUsers:   &user.ID,
			UsernameTried: uname,
			Success:       true,
			FailReason:    "",
			IpAddress:     safeIp,
			UserAgent:     safeUa,
			AttemptedAt:   now,
		}); err != nil {
			return err
		}
		// Audit trail pusat — SATU transaksi dengan INSERT sesi.
		return s.appendTrail(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "login",
				EntityID:   uname,
				Action:     "login",
				AfterValue: audit.Snapshot{"session": sessionID},
				Severity:   audit.SeverityInfo,
			},
			Actor: audit.Actor{
				IDCoreUsers: &user.ID,
				ActorName:   user.Name,
				IPAddress:   safeIp,
				UserAgent:   safeUa,
			},
		})
	})
	if err != nil {
		return nil, err
	}

	session, err := s.buildSessionView(ctx, user.ID, user.Username, user.Name, sessionID, now, expiresAt)
	if err != nil {
		return nil, err
	}
	access, refresh, expiresIn := s.issueTokens(user.ID, user.Username, sessionID, expiresAt)
	return &TokenPairResult{
		AccessToken:  access,
		RefreshToken: refresh,
		TokenType:    "Bearer",
		ExpiresIn:    expiresIn,
		Session:      session,
	}, nil
}

// ---------------------------------------------------------------------
// Register (D-16 + ddl/81)
// ---------------------------------------------------------------------

// Register — registrasi member portal: akun core_users NONAKTIF + role
// ecom_member + token aktivasi one-time + audit — SATU transaksi. Sandi
// di-hash argon2 DI LUAR tx. Email pasca-commit (kegagalan SMTP tidak
// membalikkan registrasi).
func (s *Service) Register(ctx context.Context, input RegisterInput, ip, userAgent string) (*RegisterResultView, error) {
	username := strings.ToLower(strings.TrimSpace(input.Email))
	safeIp, safeUa := amanIpUA(ip, userAgent)

	// 1) Pre-check unik — email = username (natural key core_users).
	ada, err := s.repo().GetUserByUsername(ctx, username)
	if err != nil {
		return nil, err
	}
	if ada != nil {
		return nil, errkontrak.Conflict("Email sudah terdaftar — gunakan email lain atau masuk.")
	}

	// 2) Hash argon2 DI LUAR tx.
	passwordHash := HashPassword(input.Sandi)

	// 3) Token aktivasi — mentah hanya hidup di email; DB simpan SHA-256.
	token := BuatTokenAktivasi(time.Now())

	var user repository.InsertUserRow
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		rt := repository.New(tx)
		u, err := rt.InsertUser(ctx, username, username, input.Nama, passwordHash, false)
		if err != nil {
			return err
		}
		if u == nil {
			// Race antar-transaksi — baris dibuat pemanggil lain.
			return errkontrak.Conflict("Email sudah terdaftar — gunakan email lain atau masuk.")
		}
		user = *u
		// Role ecom_member — hilang (belum seed) → skip junction.
		roleID, err := rt.CariRoleIdByKode(ctx, "ecom_member")
		if err != nil {
			return err
		}
		if roleID != nil {
			if err := rt.AssignRoleUser(ctx, u.ID, *roleID, u.ID); err != nil {
				return err
			}
		}
		if _, err := rt.InsertAuthToken(ctx, RandomUUID(), u.ID, token.Hash, token.BerlakuHingga); err != nil {
			return err
		}
		// Audit trail pusat — SATU transaksi dengan INSERT user.
		return s.appendTrail(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "register",
				EntityID:   username,
				Action:     "register",
				AfterValue: audit.Snapshot{"role": "ecom_member", "menunggu_aktivasi": true},
				Severity:   audit.SeverityInfo,
			},
			Actor: audit.Actor{
				IDCoreUsers: &u.ID,
				ActorName:   u.Name,
				IPAddress:   safeIp,
				UserAgent:   safeUa,
			},
		})
	})
	if err != nil {
		return nil, err
	}

	// 4) Email aktivasi pasca-commit (non-transaksional) — try/catch aman.
	s.kirimEmailAktivasi(ctx, MailAktivasiPayload{
		Kepada:      user.Email,
		NamaTujuan:  user.Name,
		IDCoreUsers: user.ID,
		Token:       token.Mentah,
		Tautan:      s.tautanAktivasi(token.Mentah),
	})

	return &RegisterResultView{Email: username, Status: "MENUNGGU_AKTIVASI"}, nil
}

// tautanAktivasi — <ECOM_PORTAL_URL tanpa slash ekor>/aktivasi?token=…
func (s *Service) tautanAktivasi(tokenMentah string) string {
	dasar := strings.TrimRight(s.cfg.EcomPortalURL, "/")
	return dasar + "/aktivasi?token=" + tokenMentah
}

// kirimEmailAktivasi — SELURUH isi dijaga: KirimAktivasi nil → skip;
// panic di handler mailer tertelan (registrasi tetap sukses).
func (s *Service) kirimEmailAktivasi(ctx context.Context, payload MailAktivasiPayload) {
	if s.KirimAktivasi == nil {
		return
	}
	defer func() {
		if r := recover(); r != nil {
			s.logger.Warn("Email aktivasi gagal dikirim — registrasi tetap sukses, member memakai kirim-ulang", "panic", r)
		}
	}()
	s.KirimAktivasi(ctx, payload)
}

// ---------------------------------------------------------------------
// Aktivasi email (core_auth_tokens ddl/81)
// ---------------------------------------------------------------------

const pesanTokenAktivasi400 = "Token aktivasi tidak valid atau kedaluwarsa — minta tautan baru melalui halaman masuk."

// Aktivasi — one-time + TTL 24 jam; idempoten untuk klik ganda; sukses →
// akun AKTIF.
func (s *Service) Aktivasi(ctx context.Context, tokenMentah string) error {
	tokenHash := SHA256Hex(tokenMentah)
	now := time.Now()
	token, err := s.repo().CariAuthTokenByHash(ctx, tokenHash)
	if err != nil {
		return err
	}
	// tak ada / terpakai / kedaluwarsa → 400 VAL-400.
	if token == nil || token.DipakaiAt != nil || !token.BerlakuHingga.After(now) {
		return errkontrak.BadRequest(pesanTokenAktivasi400, errkontrak.CodeVal400)
	}
	user, err := s.repo().GetUserByID(ctx, token.IDCoreUsers)
	if err != nil {
		return err
	}
	if user == nil {
		return errkontrak.BadRequest(pesanTokenAktivasi400, errkontrak.CodeVal400)
	}

	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		rt := repository.New(tx)
		if err := rt.TandaiTokenDipakai(ctx, now, token.ID); err != nil {
			return err
		}
		if !user.IsActive {
			if err := rt.AktifkanUser(ctx, user.ID, now); err != nil {
				return err
			}
			// Audit trail — aktivasi sukses SATU transaksi.
			return s.appendTrail(ctx, tx, audit.AppendInput{
				EntryInput: audit.EntryInput{
					ModuleKey:  "system",
					EntityType: "user",
					EntityID:   user.Username,
					Action:     "aktivasi_email",
					AfterValue: audit.Snapshot{"is_active": true},
					Severity:   audit.SeverityInfo,
				},
				Actor: audit.Actor{IDCoreUsers: &user.ID, ActorName: user.Name},
			})
		}
		return nil
	})
}

// KirimUlangAktivasi — SELALU jawab ok (anti-enumerasi email): email tak
// dikenal / akun sudah aktif = no-op diam. Satu token AKTIVASI aktif per
// user — yang belum terpakai dicabut (soft-delete).
func (s *Service) KirimUlangAktivasi(ctx context.Context, emailRaw string) error {
	username := strings.ToLower(strings.TrimSpace(emailRaw))
	user, err := s.repo().GetUserByUsername(ctx, username)
	if err != nil {
		return err
	}
	if user == nil || user.IsActive {
		return nil
	}

	token := BuatTokenAktivasi(time.Now())
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		rt := repository.New(tx)
		if err := rt.CabutTokenAktivasiBelumPakai(ctx, time.Now(), user.ID); err != nil {
			return err
		}
		_, err := rt.InsertAuthToken(ctx, RandomUUID(), user.ID, token.Hash, token.BerlakuHingga)
		return err
	})
	if err != nil {
		return err
	}
	s.kirimEmailAktivasi(ctx, MailAktivasiPayload{
		Kepada:      user.Email,
		NamaTujuan:  user.Name,
		IDCoreUsers: user.ID,
		Token:       token.Mentah,
		Tautan:      s.tautanAktivasi(token.Mentah),
	})
	return nil
}

// ---------------------------------------------------------------------
// Sweep token kedaluwarsa
// ---------------------------------------------------------------------

// SweepTokenKedaluwarsa — hapus token kedaluwarsa (terpakai maupun tidak;
// hard delete — jejak kirim email tetap di core_mail_log). Dikirim ke
// nilainya: jumlah baris dihapus. SATU siklus = SATU delegasi service.
func (s *Service) SweepTokenKedaluwarsa(ctx context.Context) (int64, error) {
	ids, err := s.repo().HapusTokenKedaluwarsa(ctx, time.Now())
	if err != nil {
		return 0, err
	}
	return int64(len(ids)), nil
}

// ---------------------------------------------------------------------
// Refresh
// ---------------------------------------------------------------------

// Refresh — tukar refresh token dengan pasangan baru. Validitas dari
// baris core_sessions + user masih aktif; TANPA rotasi sesi (sid tetap).
func (s *Service) Refresh(ctx context.Context, refreshToken, ip, userAgent string) (*TokenPairResult, error) {
	claims, err := ParseAccessToken(s.cfg.JWTRefreshSecret, refreshToken)
	if err != nil {
		return nil, errkontrak.Unauthorized("Refresh token tidak valid.", errkontrak.CodeAuth401)
	}
	if claims.SID == 0 || claims.Sub == 0 || claims.Username == "" {
		return nil, errkontrak.Unauthorized("Refresh token tidak valid.", errkontrak.CodeAuth401)
	}

	ses, err := s.repo().GetSesiByID(ctx, claims.SID)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	if ses == nil || !ses.IsValid || ses.RevokedAt != nil || ses.LogoutAt != nil || !ses.ExpiresAt.After(now) {
		return nil, errkontrak.Unauthorized("Sesi sudah berakhir — silakan login kembali.", errkontrak.CodeAuth401)
	}

	user, err := s.repo().GetUserByID(ctx, ses.IDCoreUsers)
	if err != nil {
		return nil, err
	}
	if user == nil || !user.IsActive {
		return nil, errkontrak.Unauthorized("Akun dinonaktifkan. Hubungi administrator.", errkontrak.CodeAuth401)
	}

	session, err := s.buildSessionView(ctx, user.ID, user.Username, user.Name, ses.ID, ses.LoginAt, ses.ExpiresAt)
	if err != nil {
		return nil, err
	}
	access, refresh, expiresIn := s.issueTokens(user.ID, user.Username, ses.ID, ses.ExpiresAt)
	return &TokenPairResult{
		AccessToken:  access,
		RefreshToken: refresh,
		TokenType:    "Bearer",
		ExpiresIn:    expiresIn,
		Session:      session,
	}, nil
}

// ---------------------------------------------------------------------
// Logout
// ---------------------------------------------------------------------

// Logout — tutup sesi: is_valid=false + logout_at; trail 'logout' dalam
// transaksi yang sama. Idempoten untuk sesi yang sudah tidak ada.
func (s *Service) Logout(ctx context.Context, sessionID int64, actor *audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		rt := repository.New(tx)
		ses, err := rt.GetSesiByID(ctx, sessionID)
		if err != nil {
			return err
		}
		if ses == nil {
			return nil
		}
		if err := rt.TutupSesi(ctx, sessionID, time.Now()); err != nil {
			return err
		}
		// Aktor dari JWT; fallback = pemilik sesi (server-derived).
		idActor := ses.IDCoreUsers
		namaActor := ses.UserName
		ipActor, uaActor := "", ""
		if actor != nil {
			if actor.IDCoreUsers != nil {
				idActor = *actor.IDCoreUsers
			}
			if actor.ActorName != "" {
				namaActor = actor.ActorName
			}
			ipActor = actor.IPAddress
			uaActor = actor.UserAgent
		}
		return s.appendTrail(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "login",
				EntityID:   ses.UserName, // entityId SELALU pemilik sesi
				Action:     "logout",
				AfterValue: audit.Snapshot{"session": sessionID},
				Severity:   audit.SeverityInfo,
			},
			Actor: audit.Actor{
				IDCoreUsers: &idActor,
				ActorName:   namaActor,
				IPAddress:   ipActor,
				UserAgent:   uaActor,
			},
		})
	})
}

// ---------------------------------------------------------------------
// Me
// ---------------------------------------------------------------------

// Me — user + roles + permission efektif + menus + karyawan ter-link.
func (s *Service) Me(ctx context.Context, userID int64) (*MeView, error) {
	user, err := s.repo().GetUserByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	if user == nil {
		return nil, errkontrak.Unauthorized("Pengguna tidak ditemukan.", errkontrak.CodeAuth401)
	}
	roles, err := s.repo().MuatRolesUser(ctx, user.ID)
	if err != nil {
		return nil, err
	}
	permissions, err := s.permissions(ctx, user.ID)
	if err != nil {
		return nil, err
	}
	menus, err := s.repo().MuatMenusUser(ctx, user.ID)
	if err != nil {
		return nil, err
	}
	karyawanID, err := s.repo().CariKaryawanTerlink(ctx, user.ID)
	if err != nil {
		return nil, err
	}
	// Nullable sejak ddl/65 (user portal non-staf) — kontrak tetap string.
	department := user.Department

	return &MeView{
		ID:           user.ID,
		Username:     user.Username,
		FullName:     user.Name,
		Department:   department,
		Email:        user.Email,
		Roles:        rolesView(roles),
		Permissions:  permissions,
		Menus:        menusView(menus),
		IDHrKaryawan: karyawanID,
	}, nil
}

// ---------------------------------------------------------------------
// Settings (port getSecuritySettings)
// ---------------------------------------------------------------------

// GetSecuritySettings — sumber = baris core_meta id 'security'; fallback
// default bila baris/JSON hilang.
func (s *Service) GetSecuritySettings(ctx context.Context) (SecuritySettings, error) {
	raw, err := s.repo().CariSecurityMeta(ctx)
	if err != nil {
		return DefaultSecuritySettings, err
	}
	return parseSecuritySettings(raw), nil
}

// ---------------------------------------------------------------------
// Ganti password mandiri
// ---------------------------------------------------------------------

// ChangePassword — verifikasi password saat ini, hash argon2 password
// baru, catat password_history (masked), reset must_change_password, dan
// audit trail — satu transaksi. TANPA revoke sesi lain.
func (s *Service) ChangePassword(ctx context.Context, userID int64, currentPassword, newPassword, ipAddress, userAgent string) error {
	if len([]rune(newPassword)) < 6 {
		return errkontrak.BadRequest("Password baru minimal 6 karakter.", errkontrak.CodeVal400)
	}
	if newPassword == currentPassword {
		return errkontrak.BadRequest("Password baru sama dengan password saat ini.", errkontrak.CodeVal400)
	}
	user, err := s.repo().GetUserByID(ctx, userID)
	if err != nil {
		return err
	}
	if user == nil {
		return errkontrak.Unauthorized("Sesi tidak valid.", errkontrak.CodeAuth401)
	}
	currentOk, err := VerifyPassword(user.PasswordHash, currentPassword)
	if err != nil {
		return err
	}
	if !currentOk {
		return errkontrak.BadRequest("Password saat ini salah.", errkontrak.CodeVal400)
	}
	newHash := HashPassword(newPassword)
	now := time.Now()
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		rt := repository.New(tx)
		if err := rt.UpdatePassword(ctx, userID, newHash, now, false); err != nil {
			return err
		}
		if err := rt.InsertPasswordHistory(ctx, userID, user.Name, now, MaskedHash(newPassword)); err != nil {
			return err
		}
		return s.appendTrail(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "user",
				EntityID:   user.Username,
				Action:     "change_password",
				AfterValue: audit.Snapshot{"must_change_password": false},
				Severity:   audit.SeverityWarning,
			},
			Actor: audit.Actor{
				IDCoreUsers: &userID,
				ActorName:   user.Username,
				IPAddress:   ipAddress,
				UserAgent:   userAgent,
			},
		})
	})
}

// ---------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------

// repo — executor pool (di luar transaksi).
func (s *Service) repo() *repository.Repository {
	return repository.New(s.db.Pool)
}

// amanIpUA — fallback "-" / "unknown" agar kolom NOT NULL terpenuhi.
func amanIpUA(ip, userAgent string) (string, string) {
	safeIp := ip
	if safeIp == "" {
		safeIp = "-"
	}
	safeUa := userAgent
	if safeUa == "" {
		safeUa = "unknown"
	}
	return safeIp, safeUa
}

// tulisGagalLogin — kegagalan login di transaksi sendiri (audit + trail).
func (s *Service) tulisGagalLogin(ctx context.Context, idCoreUsers *int64, usernameTried, failReason, actorName, ip, userAgent string) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		return s.tulisGagalLoginTx(ctx, tx, idCoreUsers, usernameTried, failReason, actorName, ip, userAgent)
	})
}

// tulisGagalLoginTx — varian dalam tx milik caller (port pushLoginTrail:
// action "login_failed", severity warning).
func (s *Service) tulisGagalLoginTx(ctx context.Context, tx pgx.Tx, idCoreUsers *int64, usernameTried, failReason, actorName, ip, userAgent string) error {
	rt := repository.New(tx)
	if err := rt.InsertLoginAudit(ctx, repository.LoginAuditParams{
		IDCoreUsers:   idCoreUsers,
		UsernameTried: usernameTried,
		Success:       false,
		FailReason:    failReason,
		IpAddress:     ip,
		UserAgent:     userAgent,
		AttemptedAt:   time.Now(),
	}); err != nil {
		return err
	}
	return s.appendTrail(ctx, tx, audit.AppendInput{
		EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "login",
			EntityID:   usernameTried,
			Action:     "login_failed",
			AfterValue: audit.Snapshot{"reason": failReason},
			Severity:   audit.SeverityWarning,
		},
		Actor: audit.Actor{
			IDCoreUsers: idCoreUsers,
			ActorName:   actorName,
			IPAddress:   ip,
			UserAgent:   userAgent,
		},
	})
}

// issueTokens — access 15m (cfg) + refresh sisa umur sesi (min 60 dtk,
// secret berbeda, jti 48-byte hex (96-hex, persis randomBytes(48).hex NestJS)). Kolom hash refresh tidak ada di
// core_sessions — validitas tetap dari baris sesi di server.
func (s *Service) issueTokens(userID int64, username string, sessionID int64, sessionExpiresAt time.Time) (string, string, int) {
	access := SignAccessToken(s.cfg.JWTAccessSecret, userID, username, sessionID, s.cfg.JWTAccessTTL)
	refreshExpiresIn := int64(sessionExpiresAt.Sub(time.Now()).Seconds())
	if refreshExpiresIn < 60 {
		refreshExpiresIn = 60
	}
	refresh := SignRefreshToken(s.cfg.JWTRefreshSecret, userID, username, sessionID, refreshExpiresIn, RandomHex(48))
	return access, refresh, int(s.cfg.JWTAccessTTL / time.Second)
}

// buildSessionView — susun SessionView: roles junction + permission
// efektif (sorted leksikografis).
func (s *Service) buildSessionView(ctx context.Context, userID int64, username, fullName string, sessionID int64, loginAt, expiresAt time.Time) (*SessionView, error) {
	roles, err := s.repo().MuatRolesUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	permissionSet, err := s.permissions(ctx, userID)
	if err != nil {
		return nil, err
	}
	return &SessionView{
		SessionID: sessionID,
		User: SessionUserView{
			ID:       userID,
			Username: username,
			FullName: fullName,
			Roles:    rolesView(roles),
		},
		PermissionSet: permissionSet,
		LoginAt:       isoOf(loginAt),
		ExpiresAt:     isoOf(expiresAt),
	}, nil
}

// rolesView — repository.RoleRow → view JSON (kontrak sesi/me).
func rolesView(rows []repository.RoleRow) []SessionUserRoleInfo {
	out := make([]SessionUserRoleInfo, 0, len(rows))
	for _, r := range rows {
		out = append(out, SessionUserRoleInfo{Code: r.Code, Role: r.Role, Description: r.Description})
	}
	return out
}

// menusView — repository.MenuRow → view JSON (kontrak meViewSchema).
func menusView(rows []repository.MenuRow) []MenuItemView {
	out := make([]MenuItemView, 0, len(rows))
	for _, m := range rows {
		out = append(out, MenuItemView{
			ID:           m.ID,
			Text:         m.Text,
			UrlPath:      m.UrlPath,
			Order:        m.Order,
			Parent:       m.Parent,
			Icon:         m.Icon,
			ExternalHref: m.ExternalHref,
		})
	}
	return out
}

// permissions — PermissionSet injected (rbac compiler); nil → kosong;
// hasil di-sort leksikografis (kontrak permissionSet).
func (s *Service) permissions(ctx context.Context, userID int64) ([]string, error) {
	if s.PermissionSet == nil {
		return []string{}, nil
	}
	set, err := s.PermissionSet(ctx, userID)
	if err != nil {
		return nil, err
	}
	if set == nil {
		return []string{}, nil
	}
	sort.Strings(set)
	return set, nil
}

// appendTrail — tulis satu entri audit trail via AuditSink; sink nil =
// dilewati (wiring belum terpasang).
func (s *Service) appendTrail(ctx context.Context, tx pgx.Tx, entry audit.AppendInput) error {
	if s.audit == nil {
		return nil
	}
	_, err := s.audit.AppendOne(ctx, tx, entry)
	return err
}
