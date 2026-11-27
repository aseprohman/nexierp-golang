package rbac

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/rbac/repository/gen"
)

// fakeScopeLoader — loader scope palsu (pure, tanpa DB).
type fakeScopeLoader struct {
	defIDs  []int64
	roleIDs []int64
	rows    []gen.ScopeAssignmentValueRowsRow
}

func (f *fakeScopeLoader) ScopeDefinitionIDs(ctx context.Context, scopeKey string, moduleID *int64) ([]int64, error) {
	return f.defIDs, nil
}

func (f *fakeScopeLoader) UserRoleIDs(ctx context.Context, userID int64) ([]int64, error) {
	return f.roleIDs, nil
}

func (f *fakeScopeLoader) ScopeAssignmentValueRows(ctx context.Context, defIDs []int64, userID int64, roleIDs []int64) ([]gen.ScopeAssignmentValueRowsRow, error) {
	return f.rows, nil
}

// userPtr — id_core_users baris ROLE = NULL (invalid), baris USER = terisi.
func userPtr(v int64) pgtype.Int8 { return pgtype.Int8{Int64: v, Valid: true} }

// teks — nilai core_scope_values; LEFT JOIN kosong = invalid (NULL).
func teks(s string) pgtype.Text { return pgtype.Text{String: s, Valid: true} }

func baris(userID pgtype.Int8, value pgtype.Text) gen.ScopeAssignmentValueRowsRow {
	return gen.ScopeAssignmentValueRowsRow{UserID: userID, Value: value}
}

// TestDataScopeDecision — konversi nilai → keputusan tiga-mode (murni).
func TestDataScopeDecision(t *testing.T) {
	if d := DataScopeDecision(nil); d.Mode != ModeSemua {
		t.Errorf("nil harus SEMUA (fail-open), dapat %s", d.Mode)
	}
	if d := DataScopeDecision([]string{}); d.Mode != ModeDenyAll {
		t.Errorf("kosong harus DENY_ALL, dapat %s", d.Mode)
	}
	if d := DataScopeDecision([]string{"abc", "xyz"}); d.Mode != ModeDenyAll {
		t.Errorf("semua non-numerik harus DENY_ALL, dapat %s", d.Mode)
	}
	d := DataScopeDecision([]string{"15", "abc", "17"})
	if d.Mode != ModeDaftar || len(d.IDs) != 2 || d.IDs[0] != 15 || d.IDs[1] != 17 {
		t.Errorf("campuran harus DAFTAR [15 17] (non-numerik dibuang), dapat %+v", d)
	}
}

// TestWhitelistFilter — semantik: SEMUA → nil; DENY_ALL → deny; DAFTAR → IN.
func TestWhitelistFilter(t *testing.T) {
	if f := WhitelistFilter(&Decision{Mode: ModeSemua}); f != nil {
		t.Error("SEMUA harus tanpa filter (nil)")
	}
	if f := WhitelistFilter(nil); f != nil {
		t.Error("Decision nil harus fail-open (nil)")
	}
	if f := WhitelistFilter(&Decision{Mode: ModeDenyAll}); f == nil || !f.Deny {
		t.Error("DENY_ALL harus filter deny (sql false)")
	}
	f := WhitelistFilter(&Decision{Mode: ModeDaftar, IDs: []int64{1, 2, 3}})
	if f == nil || f.Deny || len(f.IDs) != 3 {
		t.Error("DAFTAR harus filter IN (IDs)")
	}
	// DAFTAR dengan IDs kosong (tak seharusnya terjadi dari evaluator) → deny.
	if f := WhitelistFilter(&Decision{Mode: ModeDaftar}); f == nil || !f.Deny {
		t.Error("DAFTAR tanpa IDs harus fail-closed (deny)")
	}
}

// TestScopeValuesFailOpen — definisi kosong / rows kosong → SEMUA.
func TestScopeValuesFailOpen(t *testing.T) {
	ctx := context.Background()

	loader := &fakeScopeLoader{defIDs: nil} // dimensi belum terdaftar
	s := &Scope{repo: loader}
	d, err := s.Values(ctx, nil, 7, "outlets", nil)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != ModeSemua {
		t.Errorf("katalog kosong harus SEMUA, dapat %s", d.Mode)
	}

	loader = &fakeScopeLoader{defIDs: []int64{3}} // katalog ada, tanpa assignment
	s = &Scope{repo: loader}
	d, err = s.Values(ctx, nil, 7, "outlets", nil)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != ModeSemua {
		t.Errorf("tanpa assignment harus SEMUA, dapat %s", d.Mode)
	}
}

// TestScopeValuesUserMenimpaRole — baris USER ada → MENGGANTIKAN union ROLE.
func TestScopeValuesUserMenimpaRole(t *testing.T) {
	loader := &fakeScopeLoader{
		defIDs:  []int64{3},
		roleIDs: []int64{11},
		rows: []gen.ScopeAssignmentValueRowsRow{
			baris(userPtr(11), teks("15")), // role 11 → outlet 15
			baris(userPtr(11), teks("16")), // role 11 → outlet 16
			baris(userPtr(7), teks("99")),  // user 7 → outlet 99 (menimpa)
		},
	}
	s := &Scope{repo: loader}
	d, err := s.Values(context.Background(), nil, 7, "outlets", nil)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != ModeDaftar || len(d.IDs) != 1 || d.IDs[0] != 99 {
		t.Errorf("baris USER harus menimpa role; dapat %+v", d)
	}
}

// TestScopeValuesAssignmentNolNilaiDeny — LEFT JOIN: baris milik user ada
// tapi TANPA nilai (value NULL) → DENY_ALL, bukan fallback ke role.
func TestScopeValuesAssignmentNolNilaiDeny(t *testing.T) {
	loader := &fakeScopeLoader{
		defIDs:  []int64{3},
		roleIDs: []int64{11},
		rows: []gen.ScopeAssignmentValueRowsRow{
			baris(userPtr(11), teks("15")),   // role punya nilai
			baris(userPtr(7), pgtype.Text{}), // user: assignment tanpa nilai → deny
		},
	}
	s := &Scope{repo: loader}
	d, err := s.Values(context.Background(), nil, 7, "outlets", nil)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != ModeDenyAll {
		t.Errorf("assignment user tanpa nilai harus DENY_ALL, dapat %s", d.Mode)
	}
}

// TestScopeValuesNilaiNonNumerikDeny — semua nilai non-numerik → DENY_ALL.
func TestScopeValuesNilaiNonNumerikDeny(t *testing.T) {
	loader := &fakeScopeLoader{
		defIDs: []int64{3},
		rows: []gen.ScopeAssignmentValueRowsRow{
			baris(userPtr(7), teks("bukan-angka")),
		},
	}
	s := &Scope{repo: loader}
	d, err := s.Values(context.Background(), nil, 7, "outlets", nil)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != ModeDenyAll {
		t.Errorf("nilai non-numerik semua harus DENY_ALL, dapat %s", d.Mode)
	}
}

// TestScopeValuesUnionRoleDedup — union nilai role dengan dedup.
func TestScopeValuesUnionRoleDedup(t *testing.T) {
	loader := &fakeScopeLoader{
		defIDs:  []int64{3},
		roleIDs: []int64{11, 12},
		rows: []gen.ScopeAssignmentValueRowsRow{
			baris(userPtr(11), teks("15")),
			baris(userPtr(12), teks("15")), // duplikat antar role
			baris(userPtr(12), teks("17")),
		},
	}
	s := &Scope{repo: loader}
	d, err := s.Values(context.Background(), nil, 7, "outlets", nil)
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != ModeDaftar || len(d.IDs) != 2 {
		t.Errorf("union role harus dedup; dapat %+v", d)
	}
}
