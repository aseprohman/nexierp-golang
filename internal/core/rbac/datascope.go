package rbac

import (
	"context"
	"strconv"

	"nexierp/internal/core/rbac/repository"
	"nexierp/internal/core/rbac/repository/gen"
)

// scopeLoader — permukaan repository yang dipakai evaluator scope (dipisah
// jadi interface agar semantik fail-open/precedence teruji pure tanpa DB).
type scopeLoader interface {
	ScopeDefinitionIDs(ctx context.Context, scopeKey string, moduleID *int64) ([]int64, error)
	UserRoleIDs(ctx context.Context, userID int64) ([]int64, error)
	ScopeAssignmentValueRows(ctx context.Context, defIDs []int64, userID int64, roleIDs []int64) ([]gen.ScopeAssignmentValueRowsRow, error)
}

// ScopeMode — tiga mode keputusan scope (analog `null | [] | [nilai…]`
// evaluator NestJS).
type ScopeMode string

const (
	// ModeSemua — dimensi tak terdaftar / tanpa assignment hidup → tanpa
	// batasan (fail-open — paritas perilaku lama).
	ModeSemua ScopeMode = "SEMUA"
	// ModeDaftar — whitelist IDs (union ROLE; baris USER menimpa).
	ModeDaftar ScopeMode = "DAFTAR"
	// ModeDenyAll — assignment hidup tanpa nilai (atau nilai semua
	// non-numerik) → tidak melihat apa pun (fail-closed).
	ModeDenyAll ScopeMode = "DENY_ALL"
)

// Decision — keputusan scope untuk satu aktor pada satu dimensi; siap
// dipakai query modul domain:
//
//	scope, _ := rbac.Values(ctx, tx, userID, "outlets", &moduleID)
//	switch scope.Mode {
//	case rbac.ModeDenyAll: /* 0 baris */
//	case rbac.ModeDaftar:  /* kolom IN scope.IDs */
//	default:               /* SEMUA — tanpa predicate */
//	}
type Decision struct {
	// Mode keputusan.
	Mode ScopeMode
	// IDs — whitelist id target; hanya terisi bila Mode DAFTAR (non-kosong).
	IDs []int64
}

// DataScopeDecision — MURNI (padanan domain/data-scope-rules.ts): konversi
// hasil evaluator (nilai teks) → keputusan tiga-mode. Nilai dikonversi
// numerik (kolom target bigint/integer PK); nilai non-numerik dibuang —
// habis semua → DENY_ALL (bukan fail-open). values nil = fail-open SEMUA.
func DataScopeDecision(values []string) *Decision {
	if values == nil {
		return &Decision{Mode: ModeSemua}
	}
	ids := make([]int64, 0, len(values))
	for _, v := range values {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			ids = append(ids, n)
		}
	}
	if len(ids) == 0 {
		return &Decision{Mode: ModeDenyAll}
	}
	return &Decision{Mode: ModeDaftar, IDs: ids}
}

// Filter — cara modul menerapkan keputusan scope pada query-nya (pemetaan
// kolom target per modul = milik modul masing-masing, G1+).
type Filter struct {
	// Deny — true = whitelist kosong → bangun `WHERE false` (0 baris).
	Deny bool
	// IDs — DAFTAR → `kolom = ANY(IDs)`.
	IDs []int64
}

// WhitelistFilter — semantik padanan whitelistFilter NestJS: SEMUA → tanpa
// filter (nil); DENY_ALL → deny (sql false); DAFTAR → IN. Decision nil
// diperlakukan fail-open (tanpa filter).
func WhitelistFilter(d *Decision) *Filter {
	if d == nil || d.Mode == ModeSemua {
		return nil
	}
	if d.Mode == ModeDenyAll || len(d.IDs) == 0 {
		return &Filter{Deny: true}
	}
	return &Filter{IDs: d.IDs}
}

// Scope — evaluator generik data-scope tiga tabel dinamis (padanan
// DataScopeService NestJS): core_scope_definitions (katalog) →
// core_scope_assignments (pemberian whitelist ke ROLE/USER) →
// core_scope_values (himpunan nilai).
//
// KEAMANAN: pemetaan `scope_key → kolom query modul` hidup di KODE modul
// masing-masing (G1+) — target_table/target_field di DB hanya registry UI
// dan tidak pernah dipakai menyusun SQL (keputusan §9.2).
type Scope struct {
	repo scopeLoader
	// def — executor default (pool) bila pemanggil tidak mengirim executor.
	def repository.Executor
}

// NewScope membuat evaluator dengan executor default (pool).
func NewScope(def repository.Executor) *Scope {
	return &Scope{repo: repository.New(def), def: def}
}

// Values — EVALUATOR GENERIK: keputusan tiga-mode user untuk satu dimensi
// scope (`scope_key` katalog). Semantik (paritas NestJS):
//
//   - definisi aktif kosong / tidak ada baris assignment → SEMUA (fail-open);
//   - baris milik USER ada → MENGGANTIKAN union baris semua ROLE user;
//   - assignment dengan 0 nilai (LEFT JOIN value NULL) → DENY_ALL — deny,
//     bukan fallback ke role;
//   - nilai non-numerik dibuang (kolom target bigint PK); semua gagal →
//     DENY_ALL; else DAFTAR IDs.
//
// moduleID opsional — persempit katalog ke satu modul bila scope_key sama
// dipakai lebih dari satu modul. exec opsional — evaluasi pada koneksi/tx
// tertentu (nil = pool default); aman dipanggil di dalam transaksi.
func (s *Scope) Values(ctx context.Context, exec repository.Executor, userID int64, scopeKey string, moduleID *int64) (*Decision, error) {
	// Executor tx/koneksi opsional: nil / sama dengan default → repo default;
	// berbeda (tx pemanggil) → repo di atasnya, tanpa mengubah state Scope.
	repo := s.repo
	if exec != nil && exec != s.def {
		repo = repository.New(exec)
	}
	// 1) Definisi aktif untuk scope_key (opsional per modul).
	defIDs, err := repo.ScopeDefinitionIDs(ctx, scopeKey, moduleID)
	if err != nil {
		return nil, err
	}
	// Fail-open: dimensi belum terdaftar di katalog → tanpa batasan.
	if len(defIDs) == 0 {
		return &Decision{Mode: ModeSemua}, nil
	}

	// 2) Assignment aktif milik user ATAU role-nya — LEFT JOIN values agar
	//    assignment dengan 0 nilai tetap terdeteksi (value NULL = deny-all).
	roleIDs, err := repo.UserRoleIDs(ctx, userID)
	if err != nil {
		return nil, err
	}
	rows, err := repo.ScopeAssignmentValueRows(ctx, defIDs, userID, roleIDs)
	if err != nil {
		return nil, err
	}
	// Tidak ada apa pun → fail-open.
	if len(rows) == 0 {
		return &Decision{Mode: ModeSemua}, nil
	}

	// 3) Precedence: user rows ada → union milik user (override role);
	//    hanya role rows → union role.
	picked := rows[:0:0]
	for _, r := range rows {
		if r.UserID.Valid && r.UserID.Int64 == userID {
			picked = append(picked, r)
		}
	}
	if len(picked) == 0 {
		picked = rows
	}
	seen := make(map[string]struct{})
	values := make([]string, 0, len(picked))
	for _, r := range picked {
		if !r.Value.Valid {
			continue // value NULL = assignment tanpa nilai
		}
		if _, dup := seen[r.Value.String]; dup {
			continue
		}
		seen[r.Value.String] = struct{}{}
		values = append(values, r.Value.String)
	}
	return DataScopeDecision(values), nil
}
