// Service Pengguna (Sheet "Pengguna") fitur RBAC modul core — port VERBATIM
// services/rbac/users.service.ts NestJS ke MODEL RBAC v2:
//
//   - 1 user MULTI-ROLE via junction core_users_roles (assigned_by = aktor
//     JWT), tanpa kolom role primer;
//   - detail = roles + effectivePermissions dari Compiler.PermissionSet
//     (union multi-role + override per-user) — 7 query detail PARALEL
//     persis Promise.all;
//   - SEMUA tulis di dalam SATU pgx tx + audit pada transaksi yang sama;
//     aktor dari JWT (audit.Actor), BUKAN payload client.
//
// KEPUTUSAN RATIFIKASI (modul core Go): password demo/reset disimpan sebagai
// argon2id (auth.HashPassword) — NestJS menyimpan plaintext "nexgea123" lalu
// meng-hash-nya saat login pertama (upgrade-on-login core/auth). Go meng-hash
// LANGSUNG: perilaku eksternal identik (login argon2id + must_change_password),
// tanpa jendela plaintext di DB. Respons reset tetap menampilkan plaintext
// SEKALI; history hanya MASK; audit TANPA plaintext.
package service

import (
	"context"
	"crypto/rand"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/auth"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// UsersService — orkestrasi fitur users (db + audit + compiler + repo).
type UsersService struct {
	db       *database.DB
	audit    *audit.Service
	compiler *rbac.Compiler
	repo     *repository.UsersRepo
}

// NewUsersService membangun service users dari deps modul.
func NewUsersService(d types.Deps) *UsersService {
	return &UsersService{db: d.DB, audit: d.Audit, compiler: d.Compiler, repo: repository.NewUsersRepo()}
}

// GenerateTemporaryPassword — password sementara mudah dibaca:
// Nxg-xxxx-xxxx (port mock api.ts:388). Alphabet TANPA karakter ambigu
// i,o,l,L,0,O,1,I — regex spec `^Nxg-[a-km-np-z2-9]{4}-[a-km-np-z2-9]{4}$/i`.
func GenerateTemporaryPassword() string {
	const alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"
	segment := func() string {
		out := make([]byte, 4)
		for i := range out {
			n, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
			if err != nil {
				n = big.NewInt(time.Now().UnixNano() % int64(len(alphabet))) // crypto/rand praktis tak pernah gagal
				if n.Sign() < 0 {
					n = big.NewInt(0)
				}
			}
			out[i] = alphabet[n.Int64()]
		}
		return string(out)
	}
	return "Nxg-" + segment() + "-" + segment()
}

// ---------------------------------------------------------------------
// Baca
// ---------------------------------------------------------------------

// List — daftar user berelasi (paginated + filter q atas username/name/email
// + filter[role] EXISTS junction). Sort whitelist dijaga handler
// (shared.SortUnknown); fallback username ASC (urutan mock).
func (s *UsersService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.UserView], error) {
	q := ""
	for _, key := range []string{"q", "query", "search"} {
		if v, ada := pr.Filters[key]; ada {
			q = v // ?? nullish — q terisi walau string kosong
			break
		}
	}
	roleCode := pr.Filters["role"]
	sortField, sortDesc := "username", false
	if len(pr.Sort) > 0 {
		sortField, sortDesc = pr.Sort[0].Field, pr.Sort[0].Desc
	}
	f := repository.UserFilter{Q: q, RoleCode: roleCode}

	rows, err := s.repo.List(ctx, s.db.Pool, f, sortField, sortDesc, int32(pr.Limit), int32(pr.Offset))
	if err != nil {
		return errkontrak.Page[types.UserView]{}, err
	}
	total, err := s.repo.Count(ctx, s.db.Pool, f)
	if err != nil {
		return errkontrak.Page[types.UserView]{}, err
	}
	return errkontrak.BuildPage(rows, int(total), pr), nil
}

// Detail — detail berelasi satu user (port fetchUserDetail): 7 query baca
// PARALEL persis Promise.all, lalu effectivePermissions dari compiler.
func (s *UsersService) Detail(ctx context.Context, userID int64) (types.UserDetail, error) {
	user, ok, err := s.repo.MuatByID(ctx, s.db.Pool, userID)
	if err != nil {
		return types.UserDetail{}, err
	}
	if !ok {
		return types.UserDetail{}, notFoundUser(userID)
	}

	var (
		wg       sync.WaitGroup
		mu       sync.Mutex
		firstErr error
		roleRows []repository.ListAllRolesLiteRow
		users    map[int64]string
		assigns  []repository.ListAssignmentsOfUserRow
		overr    []types.UserOverrideView
		sessions []repository.ListSessionsOfUserRow
		mfa      *types.MfaView
		names    []string
	)
	fatal := func(err error) {
		mu.Lock()
		if firstErr == nil {
			firstErr = err
		}
		mu.Unlock()
	}
	run := func(fn func() error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := fn(); err != nil {
				fatal(err)
			}
		}()
	}
	pool := s.db.Pool
	run(func() error { // semua role (peta resolve assignment)
		rows, err := s.repo.AllRolesLite(ctx, pool)
		roleRows = rows
		return err
	})
	run(func() error { // semua username (peta resolve assigned_by)
		m, err := s.repo.AllUsernames(ctx, pool)
		users = m
		return err
	})
	run(func() error { // assignment role user
		rows, err := s.repo.AssignmentsOfUser(ctx, pool, userID)
		assigns = rows
		return err
	})
	run(func() error { // override per-user PER SET (baris hidup)
		rows, err := s.repo.OverridesOfUser(ctx, pool, userID)
		overr = rows
		return err
	})
	run(func() error { // sesi user
		rows, err := s.repo.SessionsOfUser(ctx, pool, userID)
		sessions = rows
		return err
	})
	run(func() error { // MFA user (nil bila belum daftar)
		row, err := s.repo.MfaByUser(ctx, pool, userID)
		mfa = row
		return err
	})
	run(func() error { // izin dari Role — nama SET aktif via junction role
		v, err := s.repo.RolePermissionNames(ctx, pool, userID)
		names = v
		return err
	})
	wg.Wait()
	if firstErr != nil {
		return types.UserDetail{}, firstErr
	}

	// Peta role & user untuk resolve assignment (detil paralel di atas).
	rolesByID := make(map[int64]repository.ListAllRolesLiteRow, len(roleRows))
	for _, r := range roleRows {
		rolesByID[r.ID] = r
	}

	// MULTI-ROLE: semua role junction user (urut code — deterministik).
	held := make([]repository.ListAllRolesLiteRow, 0, len(assigns))
	for _, a := range assigns {
		if r, ok := rolesByID[a.IDCoreRoles]; ok {
			held = append(held, r)
		}
	}
	sort.Slice(held, func(i, j int) bool { return held[i].Code < held[j].Code })
	heldBriefs := make([]types.RoleBrief, len(held))
	for i, r := range held {
		heldBriefs[i] = types.RoleBrief{Code: r.Code, Role: r.Role}
	}

	// extraRoles — urutan baris junction (tanpa order SQL, persis NestJS).
	extra := make([]types.UserRoleAssignmentView, len(assigns))
	for i, a := range assigns {
		assignedBy := fmt.Sprintf("%d", a.IDCoreUsersAssignedBy)
		if name, ok := users[a.IDCoreUsersAssignedBy]; ok {
			assignedBy = name
		}
		roleCode := fmt.Sprintf("%d", a.IDCoreRoles)
		if r, ok := rolesByID[a.IDCoreRoles]; ok {
			roleCode = r.Code
		}
		extra[i] = types.UserRoleAssignmentView{
			UserID:     a.IDCoreUsers,
			RoleCode:   roleCode,
			AssignedBy: assignedBy,
			AssignedAt: isoReq(a.AssignedAt),
		}
	}

	// sessions — sort loginAt DESC di sisi aplikasi (localeCompare ISO JS).
	sessionViews := make([]types.SessionView, len(sessions))
	for i, r := range sessions {
		var userID int64
		if r.IDCoreUsers.Valid {
			userID = r.IDCoreUsers.Int64
		}
		sessionViews[i] = types.SessionView{
			ID:        r.ID,
			UserID:    userID,
			UserName:  r.UserName,
			DeviceKey: repository.PgTextPtr(r.DeviceKey),
			LoginAt:   isoReq(r.LoginAt),
			ExpiresAt: isoReq(r.ExpiresAt),
			LogoutAt:  isoOpt(r.LogoutAt),
			RevokedAt: isoOpt(r.RevokedAt),
			IPAddress: r.IpAddress,
			UserAgent: repository.TextEmpty(r.UserAgent),
			Device:    r.Device,
			IsValid:   r.IsValid,
		}
	}
	sort.SliceStable(sessionViews, func(i, j int) bool {
		return sessionViews[i].LoginAt > sessionViews[j].LoginAt
	})

	// Permission efektif = union semua role + override (compiler v2).
	effective, err := s.compiler.PermissionSet(ctx, userID)
	if err != nil {
		return types.UserDetail{}, err
	}
	if effective == nil {
		effective = []string{}
	}

	if extra == nil {
		extra = []types.UserRoleAssignmentView{}
	}
	if overr == nil {
		overr = []types.UserOverrideView{}
	}
	if names == nil {
		names = []string{}
	}

	return types.UserDetail{
		User:                 repository.UserRowToView(user, heldBriefs),
		ExtraRoles:           extra,
		EffectivePermissions: effective,
		RolePermissions:      names,
		Overrides:            overr,
		Sessions:             sessionViews,
		Mfa:                  mfa,
	}, nil
}

// ---------------------------------------------------------------------
// Tulis
// ---------------------------------------------------------------------

// CreateUserInput — nilai create user (hasil validasi handler).
type CreateUserInput struct {
	Username   string
	Email      string // "" bila tidak dikirim (persis `input.email ?? ""`)
	FullName   string
	Department string
	RoleIds    []int64
	IsActive   bool
}

// Create — buat user (port createUser; model v2): username unik (409
// SYS-409: pre-check + tangkap 23505 → 409 pesan sama), roleIds tervalidasi
// (404 SYS-404) — SEMUA role ditulis ke junction dengan assigned_by = aktor
// JWT; password demo disimpan argon2id + must_change_password.
func (s *UsersService) Create(ctx context.Context, in CreateUserInput, actor audit.Actor) (types.UserView, error) {
	uniqueRoleIds := dedupeIds(in.RoleIds)
	var inserted repository.InsertUserRow
	var roles []repository.ListRolesByIdsRow

	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		// (1) Pre-check username (409 SYS-409).
		if _, ada, err := s.repo.IDByUsername(ctx, tx, in.Username); err != nil {
			return err
		} else if ada {
			return errkontrak.Conflict(fmt.Sprintf("Username '%s' sudah dipakai.", in.Username), "SYS-409")
		}

		// (2) Validasi roleIds (404 SYS-404 — missing urut input).
		rows, err := s.repo.RolesByIds(ctx, tx, uniqueRoleIds)
		if err != nil {
			return err
		}
		if len(rows) != len(uniqueRoleIds) {
			found := make(map[int64]bool, len(rows))
			for _, r := range rows {
				found[r.ID] = true
			}
			missing := make([]string, 0)
			for _, id := range uniqueRoleIds {
				if !found[id] {
					missing = append(missing, fmt.Sprintf("%d", id))
				}
			}
			return errkontrak.NotFound(fmt.Sprintf("Role tidak ditemukan: %s.", strings.Join(missing, ", ")), "SYS-404")
		}
		roles = rows

		// (3) Insert user — password demo argon2id (ratifikasi), wajib
		// ganti password di login pertama.
		now := time.Now()
		row, err := s.repo.Insert(ctx, tx, repository.InsertUserParams{
			Username:           in.Username,
			Email:              pgtype.Text{String: in.Email, Valid: true},
			Name:               in.FullName,
			Department:         pgtype.Text{String: in.Department, Valid: true},
			PasswordHash:       auth.HashPassword(types.DefaultDemoPassword),
			IsActive:           in.IsActive,
			PasswordChangedAt:  pgtype.Timestamptz{Time: now, Valid: true},
			MustChangePassword: true,
		})
		if err != nil {
			// Race 23505 (username unik) → 409 pesan verbatim yang sama.
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(fmt.Sprintf("Username '%s' sudah dipakai.", in.Username), "SYS-409")
			}
			return err
		}
		inserted = row

		// (4) Junction multi-role — unique(id_user, id_role) idempoten.
		assignedBy := actorIDOf(actor)
		for _, role := range roles {
			if err := s.repo.InsertUserRole(ctx, tx, inserted.ID, role.ID, assignedBy, true); err != nil {
				return err
			}
		}

		// (5) Audit user create (afterValue: username + kode role) — tx sama.
		codes := make([]string, len(roles))
		for i, r := range roles {
			codes[i] = r.Code
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "user",
				EntityID:   fmt.Sprintf("%d", inserted.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{"username": inserted.Username, "roles": codes},
			},
			Actor: actor,
		}})
		return err
	})
	if err != nil {
		return types.UserView{}, err
	}
	return repository.UserInsertRowToView(inserted, roleBriefsOf(roles)), nil
}

// SetActive — aktifkan/nonaktifkan user (port setUserActive): deaktivasi
// mencabut SEMUA sesi aktif (is_valid=false + revoked_at) dalam tx yang sama.
func (s *UsersService) SetActive(ctx context.Context, userID int64, isActive bool, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		user, ok, err := s.repo.MuatByID(ctx, tx, userID)
		if err != nil {
			return err
		}
		if !ok {
			return notFoundUser(userID)
		}
		if err := s.repo.UpdateIsActive(ctx, tx, userID, isActive); err != nil {
			return err
		}
		if !isActive {
			if err := s.repo.CabutSesiAktif(ctx, tx, userID, time.Now()); err != nil {
				return err
			}
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "user",
				EntityID:    fmt.Sprintf("%d", userID),
				Action:      "update",
				BeforeValue: audit.Snapshot{"is_active": user.IsActive},
				AfterValue:  audit.Snapshot{"is_active": isActive},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

// ResetPassword — reset password user (port resetUserPassword + penulisan
// riwayat): generate `Nxg-xxxx-xxxx` bila tidak diberikan, simpan argon2id
// (ratifikasi — plaintext respons SEKALI), set must_change_password, buka
// kunci, tulis baris core_password_history berisi MASK tampilan. Plaintext
// TIDAK pernah masuk audit trail.
func (s *UsersService) ResetPassword(ctx context.Context, userID int64, temporaryPassword string, provided bool, actor audit.Actor) (string, error) {
	var password string
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		user, ok, err := s.repo.MuatByID(ctx, tx, userID)
		if err != nil {
			return err
		}
		if !ok {
			return notFoundUser(userID)
		}
		password = temporaryPassword
		if !provided {
			password = GenerateTemporaryPassword()
		}
		if err := s.repo.UpdateResetPassword(ctx, tx, userID, auth.HashPassword(password)); err != nil {
			return err
		}
		// History hanya MASK tampilan (ala seed mockup) — bukan plaintext.
		mask := password[:4] + strings.Repeat("•", 12)
		if err := s.repo.InsertPasswordHistory(ctx, tx, userID, user.Name, time.Now(), mask); err != nil {
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "user",
				EntityID:   fmt.Sprintf("%d", userID),
				Action:     "reset_password",
				// Plaintext sengaja tidak dicatat di audit (port komentar mock).
				AfterValue: audit.Snapshot{"must_change_password": true},
				Severity:   audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
	if err != nil {
		return "", err
	}
	return password, nil
}

// Unlock — buka kunci user (port unlockUser): reset failed_login_attempts
// dan locked_until; audit severity warning.
func (s *UsersService) Unlock(ctx context.Context, userID int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		user, ok, err := s.repo.MuatByID(ctx, tx, userID)
		if err != nil {
			return err
		}
		if !ok {
			return notFoundUser(userID)
		}
		if err := s.repo.UpdateUnlock(ctx, tx, userID); err != nil {
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "user",
				EntityID:   fmt.Sprintf("%d", userID),
				Action:     "unlock",
				BeforeValue: audit.Snapshot{
					"failed": user.FailedLoginAttempts,
					"locked": isoOrNull(user.LockedUntil),
				},
				AfterValue: audit.Snapshot{"failed_attempts": 0, "locked_until": nil},
				Severity:   audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

// AssignRoles — assign MULTI-ROLE user — REPLACE junction core_users_roles
// (minimal satu role — divalidasi SEBELUM tx dengan pesan panjang). Audit
// user_roles replace, lalu Compiler.InvalidateUser DI DALAM Tx closure
// (presedensi verbatim NestJS).
func (s *UsersService) AssignRoles(ctx context.Context, userID int64, roleIds []int64, actor audit.Actor) ([]types.RoleBrief, error) {
	uniqueRoleIds := dedupeIds(roleIds)
	if len(uniqueRoleIds) == 0 {
		return nil, errkontrak.Validation([]errkontrak.FieldIssue{{
			Field:   "roleIds",
			Message: "Minimal satu role — user tanpa role tidak memiliki akses apa pun.",
		}})
	}

	var roles []repository.ListRolesByIdsRow
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		user, ok, err := s.repo.MuatByID(ctx, tx, userID)
		if err != nil {
			return err
		}
		if !ok {
			return notFoundUser(userID)
		}
		rows, err := s.repo.RolesByIds(ctx, tx, uniqueRoleIds)
		if err != nil {
			return err
		}
		if len(rows) != len(uniqueRoleIds) {
			found := make(map[int64]bool, len(rows))
			for _, r := range rows {
				found[r.ID] = true
			}
			missing := make([]string, 0)
			for _, id := range uniqueRoleIds {
				if !found[id] {
					missing = append(missing, fmt.Sprintf("%d", id))
				}
			}
			return errkontrak.NotFound(fmt.Sprintf("Role tidak ditemukan: %s.", strings.Join(missing, ", ")), "SYS-404")
		}
		roles = rows

		before, err := s.repo.RoleCodesOfUser(ctx, tx, userID)
		if err != nil {
			return err
		}

		if err := s.repo.DeleteUserRolesByUser(ctx, tx, userID); err != nil {
			return err
		}
		assignedBy := actorIDOf(actor)
		for _, r := range roles {
			if err := s.repo.InsertUserRole(ctx, tx, userID, r.ID, assignedBy, false); err != nil {
				return err
			}
		}

		after := make([]string, len(roles))
		for i, r := range roles {
			after[i] = r.Code
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "user_roles",
				EntityID:    user.Username,
				Action:      "replace",
				BeforeValue: audit.Snapshot{"roles": before},
				AfterValue:  audit.Snapshot{"roles": after, "assigned_by": actor.ActorName},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}

		// Presedensi verbatim: invalidasi cache user DI DALAM tx closure.
		s.compiler.InvalidateUser(userID)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return roleBriefsOf(roles), nil
}

// ---------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------

// notFoundUser — 404 SYS-404 pesan verbatim findUser.
func notFoundUser(id int64) error {
	return errkontrak.NotFound(fmt.Sprintf("User id %d tidak ditemukan.", id), "SYS-404")
}

// dedupeIds — unik pertahankan urutan ([...new Set(ids)]).
func dedupeIds(ids []int64) []int64 {
	seen := make(map[int64]bool, len(ids))
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// roleBriefsOf — baris role → pasangan {code, role}.
func roleBriefsOf(roles []repository.ListRolesByIdsRow) []types.RoleBrief {
	out := make([]types.RoleBrief, len(roles))
	for i, r := range roles {
		out[i] = types.RoleBrief{Code: r.Code, Role: r.Role}
	}
	return out
}

// actorIDOf — id aktor audit (0 bila proses sistem — padanan ctx.actor.id ?? 0).
func actorIDOf(actor audit.Actor) int64 {
	if actor.IDCoreUsers != nil {
		return *actor.IDCoreUsers
	}
	return 0
}

// isoOrNull — pgtype.Timestamptz → string ISO atau nil (audit before).
func isoOrNull(t pgtype.Timestamptz) any {
	if !t.Valid {
		return nil
	}
	return types.Iso(t.Time)
}

// isoReq — timestamptz NOT NULL → ISO (toISOString JS).
func isoReq(t pgtype.Timestamptz) string {
	if !t.Valid {
		return ""
	}
	return types.Iso(t.Time)
}

// isoOpt — timestamptz nullable → *string (NULL → nil).
func isoOpt(t pgtype.Timestamptz) *string {
	if !t.Valid {
		return nil
	}
	s := types.Iso(t.Time)
	return &s
}
