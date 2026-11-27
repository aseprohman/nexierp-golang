// repository/iam_datascope.go — SATU-SATUNYA pengguna area sqlc DATASCOPE
// (ddl/50): katalog `core_scope_definitions`, pemberian whitelist
// `core_scope_assignments` (role/user XOR), himpunan nilai `core_scope_values`
// (padanan DatascopeRepository NestJS).
//
// OPSI NILAI GENERIK: introspeksi drizzle diganti REGISTRY STATIS
// SCOPE_TABLE_PROFILES (map target_table → profil kolom) — identifier SQL
// HANYA dari map statis ini (nilai filter/search tetap parameter $n).
// Resolusi tabel rujukan persis resolveRefProfile:
//  1. FK kolom target_field → tabel rujukannya;
//  2. konvensi nama `id_<tabel>` → tabel <tabel>;
//  3. fallback: target_table itu sendiri (scope per PK tabel).
package repository

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// DatascopeRepo — wrapper sqlc area datascope.
type DatascopeRepo struct{}

// NewDatascopeRepo membuat repository datascope.
func NewDatascopeRepo() *DatascopeRepo { return &DatascopeRepo{} }

// ====================================================================
// DEFINISI (katalog dimensi scope)
// ====================================================================

// ListDefinitions — baris definisi aktif (tanpa soft-delete), urut modul
// lalu scope_key.
func (r *DatascopeRepo) ListDefinitions(ctx context.Context, exec DBTX) ([]gen.CoreScopeDefinition, error) {
	return gen.New(exec).ListScopeDefinitions(ctx)
}

// CountAssignmentsByDefinition — ringkasan jumlah assignment hidup per definisi.
func (r *DatascopeRepo) CountAssignmentsByDefinition(ctx context.Context, exec DBTX) ([]gen.CountAssignmentsByDefinitionRow, error) {
	return gen.New(exec).CountAssignmentsByDefinition(ctx)
}

// FindDefinitionById — definisi hidup by id (baris PENUH); null bila absen.
func (r *DatascopeRepo) FindDefinitionById(ctx context.Context, exec DBTX, id int64) (*gen.CoreScopeDefinition, error) {
	row, err := gen.New(exec).FindScopeDefinitionById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FindDefinitionTarget — (target_table, target_field) definisi hidup.
func (r *DatascopeRepo) FindDefinitionTarget(ctx context.Context, exec DBTX, id int64) (*gen.FindScopeDefinitionTargetRow, error) {
	row, err := gen.New(exec).FindScopeDefinitionTarget(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FindDefinitionDuplicate — duplikat (modul, scope_key) hidup.
func (r *DatascopeRepo) FindDefinitionDuplicate(ctx context.Context, exec DBTX, moduleID int64, scopeKey string) (bool, error) {
	_, err := gen.New(exec).FindScopeDefinitionDuplicate(ctx, gen.FindScopeDefinitionDuplicateParams{
		IDCoreModules: moduleID,
		ScopeKey:      scopeKey,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindDefinitionDuplicateId — id duplikat hidup (guard pindahan registry:
// `dup && dup.id !== id` persis sumber); null bila tidak ada.
func (r *DatascopeRepo) FindDefinitionDuplicateId(ctx context.Context, exec DBTX, moduleID int64, scopeKey string) (*int64, error) {
	id, err := gen.New(exec).FindScopeDefinitionDuplicate(ctx, gen.FindScopeDefinitionDuplicateParams{
		IDCoreModules: moduleID,
		ScopeKey:      scopeKey,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// FindDefinitionIdById — id definisi hidup by id (ensureDefinitionExists).
func (r *DatascopeRepo) FindDefinitionIdById(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := gen.New(exec).FindScopeDefinitionIdById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// InsertDefinition — insert definisi (operator 'in' statis di query).
func (r *DatascopeRepo) InsertDefinition(ctx context.Context, exec DBTX, arg gen.InsertScopeDefinitionParams) (*gen.CoreScopeDefinition, error) {
	row, err := gen.New(exec).InsertScopeDefinition(ctx, arg)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// DefinitionPatch — set parsial UPDATE definisi (version bump di service).
type DefinitionPatch struct {
	Label       *string
	Description *string
	IsActive    *bool
	ScopeKey    *string
	ModuleID    *int64
	TargetTable *string
	TargetField *string
	Version     int64
	UpdatedAt   pgtype.Timestamptz
}

// UpdateDefinitionById — update definisi by id → baris terbaru.
func (r *DatascopeRepo) UpdateDefinitionById(ctx context.Context, exec DBTX, id int64, p DefinitionPatch) (*gen.CoreScopeDefinition, error) {
	arg := gen.UpdateScopeDefinitionByIdParams{Version: p.Version, UpdatedAt: p.UpdatedAt, ID: id}
	if p.Label != nil {
		arg.SetLabel = true
		arg.Label = *p.Label
	}
	if p.Description != nil {
		arg.SetDescription = true
		arg.Description = *p.Description
	}
	if p.IsActive != nil {
		arg.SetIsActive = true
		arg.IsActive = *p.IsActive
	}
	if p.ScopeKey != nil {
		arg.SetScopeKey = true
		arg.ScopeKey = *p.ScopeKey
	}
	if p.ModuleID != nil {
		arg.SetModule = true
		arg.ModuleID = *p.ModuleID
	}
	if p.TargetTable != nil {
		arg.SetTargetTable = true
		arg.TargetTable = *p.TargetTable
	}
	if p.TargetField != nil {
		arg.SetTargetField = true
		arg.TargetField = *p.TargetField
	}
	row, err := gen.New(exec).UpdateScopeDefinitionById(ctx, arg)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// SoftDeleteDefinitionById — SOFT delete definisi (deleted_at + version).
func (r *DatascopeRepo) SoftDeleteDefinitionById(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt pgtype.Timestamptz, version int64) error {
	return gen.New(exec).SoftDeleteScopeDefinitionById(ctx, gen.SoftDeleteScopeDefinitionByIdParams{
		ID:        id,
		DeletedAt: deletedAt,
		UpdatedAt: updatedAt,
		Version:   version,
	})
}

// CountAssignmentsLiveByDefinition — jumlah assignment HIDUP (guard DELETE).
func (r *DatascopeRepo) CountAssignmentsLiveByDefinition(ctx context.Context, exec DBTX, definitionID int64) (int, error) {
	n, err := gen.New(exec).CountAssignmentsLiveByDefinition(ctx, definitionID)
	return int(n), err
}

// ====================================================================
// ASSIGNMENT (pemberian whitelist ke role/user)
// ====================================================================

// ListAssignmentsByDefinition — assignment hidup + nama subject, urut id.
func (r *DatascopeRepo) ListAssignmentsByDefinition(ctx context.Context, exec DBTX, definitionID int64) ([]gen.ListAssignmentsByDefinitionRow, error) {
	return gen.New(exec).ListAssignmentsByDefinition(ctx, definitionID)
}

// ListAllScopeValues — seluruh nilai whitelist hidup (urut id PK) —
// pengelompokan per assignment dilakukan service.
func (r *DatascopeRepo) ListAllScopeValues(ctx context.Context, exec DBTX) ([]gen.ListAllScopeValuesRow, error) {
	return gen.New(exec).ListAllScopeValues(ctx)
}

// FindAssignmentById — assignment hidup by id (baris PENUH); null bila absen.
func (r *DatascopeRepo) FindAssignmentById(ctx context.Context, exec DBTX, id int64) (*gen.CoreScopeAssignment, error) {
	row, err := gen.New(exec).FindScopeAssignmentById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FindAssignmentDuplicate — duplikat pasangan hidup (definisi + role XOR
// user; role null → bandingkan user, persis ternary sumber).
func (r *DatascopeRepo) FindAssignmentDuplicate(ctx context.Context, exec DBTX, definitionID int64, roleID, userID *int64) (bool, error) {
	_, err := gen.New(exec).FindAssignmentDuplicate(ctx, gen.FindAssignmentDuplicateParams{
		IDCoreScopeDefinitions: definitionID,
		RoleID:                 int64OrZero(roleID),
		UserID:                 Int8Of(userID),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// InsertAssignment — insert assignment (role ATAU user — XOR di schema).
func (r *DatascopeRepo) InsertAssignment(ctx context.Context, exec DBTX, arg gen.InsertScopeAssignmentParams) (*gen.CoreScopeAssignment, error) {
	row, err := gen.New(exec).InsertScopeAssignment(ctx, arg)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// AssignmentPatch — set parsial UPDATE assignment (version bump di service).
type AssignmentPatch struct {
	IsActive  *bool
	Note      *string
	Version   int64
	UpdatedAt pgtype.Timestamptz
}

// UpdateAssignmentById — update assignment by id → baris terbaru.
func (r *DatascopeRepo) UpdateAssignmentById(ctx context.Context, exec DBTX, id int64, p AssignmentPatch) (*gen.CoreScopeAssignment, error) {
	arg := gen.UpdateScopeAssignmentByIdParams{Version: p.Version, UpdatedAt: p.UpdatedAt, ID: id}
	if p.IsActive != nil {
		arg.SetIsActive = true
		arg.IsActive = *p.IsActive
	}
	if p.Note != nil {
		arg.SetNote = true
		arg.Note = *p.Note
	}
	row, err := gen.New(exec).UpdateScopeAssignmentById(ctx, arg)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// SoftDeleteAssignmentById — SOFT delete assignment (deleted_at + version).
func (r *DatascopeRepo) SoftDeleteAssignmentById(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt pgtype.Timestamptz, version int64) error {
	return gen.New(exec).SoftDeleteScopeAssignmentById(ctx, gen.SoftDeleteScopeAssignmentByIdParams{
		ID:        id,
		DeletedAt: deletedAt,
		UpdatedAt: updatedAt,
		Version:   version,
	})
}

// ====================================================================
// VALUES (whitelist satu assignment)
// ====================================================================

// ListValuesOfAssignment — whitelist nilai satu assignment hidup (urut id).
func (r *DatascopeRepo) ListValuesOfAssignment(ctx context.Context, exec DBTX, assignmentID int64) ([]string, error) {
	return gen.New(exec).ListScopeValuesOfAssignment(ctx, assignmentID)
}

// CountValues — jumlah nilai hidup satu assignment.
func (r *DatascopeRepo) CountValues(ctx context.Context, exec DBTX, assignmentID int64) (int, error) {
	n, err := gen.New(exec).CountScopeValues(ctx, assignmentID)
	return int(n), err
}

// ListValuesBefore — nilai hidup sebelum REPLACE (urut NILAI — snapshot audit).
func (r *DatascopeRepo) ListValuesBefore(ctx context.Context, exec DBTX, assignmentID int64) ([]string, error) {
	return gen.New(exec).ListScopeValuesBefore(ctx, assignmentID)
}

// DeleteValues — bulk replace tahap 1: hapus FISIK nilai yang tak di payload.
func (r *DatascopeRepo) DeleteValues(ctx context.Context, exec DBTX, assignmentID int64, toDelete []string) error {
	return gen.New(exec).DeleteScopeValues(ctx, gen.DeleteScopeValuesParams{
		AssignmentID: assignmentID,
		Values:       toDelete,
	})
}

// InsertValues — bulk replace tahap 2: sisip nilai (ON CONFLICT DO NOTHING;
// loop dalam executor tx yang sama).
func (r *DatascopeRepo) InsertValues(ctx context.Context, exec DBTX, assignmentID int64, values []string) error {
	q := gen.New(exec)
	for _, v := range values {
		if err := q.InsertScopeValue(ctx, gen.InsertScopeValueParams{
			IDCoreScopeAssignments: assignmentID,
			Value:                  v,
		}); err != nil {
			return err
		}
	}
	return nil
}

// ====================================================================
// Validasi FK (modul/role/user wajib ada)
// ====================================================================

// FindModuleIdByKey — id modul by key; null bila absen.
func (r *DatascopeRepo) FindModuleIdByKey(ctx context.Context, exec DBTX, key string) (*int64, error) {
	id, err := gen.New(exec).FindModuleIdByKey(ctx, key)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// FindModuleIdById — id modul by id; null bila absen.
func (r *DatascopeRepo) FindModuleIdById(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := gen.New(exec).FindModuleIdById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindRoleIdById — id role by id (ensureRoleExists); null bila absen.
func (r *DatascopeRepo) FindRoleIdById(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := gen.New(exec).FindRoleIdById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindUserIdById — id user by id (ensureUserExists); null bila absen.
func (r *DatascopeRepo) FindUserIdById(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := gen.New(exec).FindUserById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// ====================================================================
// OPSI NILAI GENERIK — registry statis pengganti introspeksi drizzle
// ====================================================================

// scopeFKCol — kolom numerik; RefTable kosong = non-FK (nilai mentah).
type scopeFKCol struct {
	Name     string
	RefTable string
}

// scopeTableProfile — profil tabel rujukan (padankan profileScopeTable):
// StringCols maks 3 (kandidat tampilan & pencarian), NumericCols maks 2,
// LabelCol = name→title→username→code→string pertama, ParentCol self-ref.
type scopeTableProfile struct {
	Pk           string
	StringCols   []string
	NumericCols  []scopeFKCol
	LabelCol     string
	ParentCol    string
	HasDeletedAt bool
}

// SCOPE_TABLE_PROFILES — mirror statis schema modul (core/inv/hr/pos):
// modul baru menambahkan entri tabelnya di sini.
var SCOPE_TABLE_PROFILES = map[string]scopeTableProfile{
	"core_users": {
		Pk: "id", StringCols: []string{"username", "name", "department"},
		LabelCol: "name", HasDeletedAt: true,
	},
	"core_roles": {
		Pk: "id", StringCols: []string{"code", "role", "description"},
		LabelCol: "code", HasDeletedAt: true,
	},
	"core_provinsi": {
		Pk: "id", StringCols: []string{"kode", "nama"},
		LabelCol: "nama", HasDeletedAt: true,
	},
	"core_kota": {
		Pk: "id", StringCols: []string{"kode", "nama"},
		LabelCol: "nama", HasDeletedAt: true,
		NumericCols: []scopeFKCol{{Name: "id_core_provinsi", RefTable: "core_provinsi"}},
	},
	"core_kecamatan": {
		Pk: "id", StringCols: []string{"kode", "nama"},
		LabelCol: "nama", HasDeletedAt: true,
		NumericCols: []scopeFKCol{{Name: "id_core_kota", RefTable: "core_kota"}},
	},
	"core_kelurahan": {
		Pk: "id", StringCols: []string{"kode", "nama", "kode_pos"},
		LabelCol: "nama", HasDeletedAt: true,
		NumericCols: []scopeFKCol{{Name: "id_core_kecamatan", RefTable: "core_kecamatan"}},
	},
	"hr_departemen": {
		Pk: "id", StringCols: []string{"kode", "nama", "keterangan"},
		LabelCol: "nama", ParentCol: "id_hr_departemen", HasDeletedAt: true,
		NumericCols: []scopeFKCol{{Name: "id_core_users", RefTable: "core_users"}},
	},
	"hr_jabatan": {
		Pk: "id", StringCols: []string{"kode", "nama", "keterangan"},
		LabelCol: "nama", HasDeletedAt: true,
		NumericCols: []scopeFKCol{
			{Name: "id_hr_departemen", RefTable: "hr_departemen"},
			{Name: "kelas_risiko_jkk"}, // numerik non-FK — nilai mentah
		},
	},
	"hr_karyawan": {
		Pk: "id", StringCols: []string{"nik_pegawai", "nama_lengkap", "bank"},
		LabelCol: "nik_pegawai", ParentCol: "id_hr_karyawan", HasDeletedAt: true,
		NumericCols: []scopeFKCol{
			{Name: "id_hr_departemen", RefTable: "hr_departemen"},
			{Name: "id_hr_jabatan", RefTable: "hr_jabatan"},
		},
	},
	"inv_gudang": {
		Pk: "id", StringCols: []string{"kode", "nama", "kode_satuan"},
		LabelCol: "nama", HasDeletedAt: true,
		NumericCols: []scopeFKCol{
			{Name: "id_core_kelurahan", RefTable: "core_kelurahan"},
			{Name: "latitude"}, // numerik non-FK — nilai mentah
		},
	},
	"pos_outlet": {
		Pk: "id", StringCols: []string{"kode", "nama", "no_telepon"},
		LabelCol: "nama", HasDeletedAt: true,
		NumericCols: []scopeFKCol{{Name: "id_inv_gudang", RefTable: "inv_gudang"}},
	},
}

// SCOPE_FK_LABELS — label Indonesia kolom umum (persis datascope-types.ts).
var SCOPE_FK_LABELS = map[string]string{
	"id_inventory_items":      "Barang",
	"id_inventory_warehouses": "Gudang/Storage",
	"id_inventory_categories": "Kategori",
	"id_inventory_batches":    "Lot",
	"id_inventory_serials":    "Serial",
	"id_inventory_uoms":       "Satuan",
	"id_purchasing_suppliers": "Supplier",
	"item":                    "Barang",
	"warehouse":               "Gudang/Storage",
	"category":                "Kategori",
}

// SCOPE_COLUMN_LABELS — label Indonesia kolom umum; sisanya humanize.
var SCOPE_COLUMN_LABELS = map[string]string{
	"name": "Nama", "code": "Kode", "city": "Kota", "address": "Alamat",
	"title": "Judul", "username": "Pengguna", "description": "Deskripsi",
	"note": "Catatan", "received_date": "Tgl terima",
	"warranty_until": "Sampai garansi", "production_date": "Tgl produksi",
	"expiry_date": "Kedaluwarsa", "lot_code": "No. lot",
	"serial_number": "No. seri", "sku": "SKU", "barcode": "Barcode",
}

var reSnake = regexp.MustCompile(`_([a-z0-9])`)

// camelCase — snake_case → camelCase (persis helper sumber).
func camelCase(s string) string {
	return reSnake.ReplaceAllStringFunc(s, func(m string) string {
		return strings.ToUpper(m[len(m)-1:])
	})
}

// humanizeColumn — label generik kolom (persis humanizeColumn sumber).
func humanizeColumn(key string) string {
	if label, ok := SCOPE_COLUMN_LABELS[key]; ok {
		return label
	}
	text := camelCase(key)
	text = strings.TrimPrefix(text, "id")
	text = strings.TrimPrefix(text, "Id")
	var b strings.Builder
	for i, r := range text {
		if r >= 'A' && r <= 'Z' {
			if i > 0 {
				b.WriteRune(' ')
			}
		}
		b.WriteRune(r)
	}
	text = strings.TrimSpace(b.String())
	if text == "" {
		return "ID"
	}
	return strings.ToUpper(text[:1]) + text[1:]
}

// resolveRefProfile — profil tabel RUJUKAN dari (target_table, target_field)
// — 3 langkah persis sumber (FK → konvensi id_ → tabel target sendiri).
func resolveRefProfile(targetTable, targetField string) (string, *scopeTableProfile) {
	if target, ok := SCOPE_TABLE_PROFILES[targetTable]; ok {
		for _, c := range target.NumericCols {
			if c.Name == targetField && c.RefTable != "" {
				if p, ok := SCOPE_TABLE_PROFILES[c.RefTable]; ok {
					return c.RefTable, &p
				}
			}
		}
	}
	if strings.HasPrefix(targetField, "id_") {
		if p, ok := SCOPE_TABLE_PROFILES[targetField[3:]]; ok {
			return targetField[3:], &p
		}
	}
	if p, ok := SCOPE_TABLE_PROFILES[targetTable]; ok {
		return targetTable, &p
	}
	return "", nil
}

// ListOptions — baris tabel rujukan definisi, paging/search SERVER
// (?page&limit&search — TANPA sort). value = PK baris sebagai teks; kolom
// display = string (maks 3) + numerik (maks 2, FK di-label); parent label
// bila self-referensi. Null bila tabel tidak ter-registry (service → 404
// pesan verbatim SCOPE_TABLE_REGISTRIES).
func (r *DatascopeRepo) ListOptions(ctx context.Context, exec DBTX, targetTable, targetField string, pr *errkontrak.PageRequest, search *string) (*types.ScopeOptionsResult, error) {
	tableName, profile := resolveRefProfile(targetTable, targetField)
	if profile == nil {
		return nil, nil
	}
	p := *profile

	// Kolom tampilan: string maks 3 + numerik maks 2 (persis sumber).
	type displayCol struct {
		name    string
		fk      *scopeFKCol
		refProf *scopeTableProfile
	}
	display := []displayCol{}
	for i, c := range p.StringCols {
		if i == 3 {
			break
		}
		display = append(display, displayCol{name: c})
	}
	for i, c := range p.NumericCols {
		if i == 2 {
			break
		}
		d := displayCol{name: c.Name, fk: &c}
		if c.RefTable != "" {
			if rp, ok := SCOPE_TABLE_PROFILES[c.RefTable]; ok {
				d.refProf = &rp
			}
		}
		display = append(display, d)
	}

	columns := []types.ScopeOptionColumn{{Key: "value", Label: "ID"}}
	for _, d := range display {
		label, ok := SCOPE_FK_LABELS[d.name]
		if !ok {
			label = humanizeColumn(d.name)
		}
		columns = append(columns, types.ScopeOptionColumn{Key: d.name, Label: label})
	}
	if p.ParentCol != "" {
		columns = append(columns, types.ScopeOptionColumn{Key: "parent", Label: "Induk"})
	}

	// WHERE: deleted_at IS NULL (bila ada) + ILIKE seluruh kolom string.
	conds := []string{}
	args := []any{}
	if p.HasDeletedAt {
		conds = append(conds, "deleted_at IS NULL")
	}
	if search != nil {
		term := strings.TrimSpace(*search)
		if term != "" && len(p.StringCols) > 0 {
			or := []string{}
			for _, c := range p.StringCols {
				or = append(or, fmt.Sprintf("%s ILIKE $%d", c, len(args)+1))
				args = append(args, "%"+term+"%")
			}
			conds = append(conds, "("+joinOr(or)+")")
		}
	}
	where := ""
	if len(conds) > 0 {
		where = " WHERE " + joinAnd(conds)
	}

	// SELECT: pk AS value + kolom display + parent id.
	selects := []string{p.Pk + " AS value"}
	for _, d := range display {
		selects = append(selects, d.name)
	}
	if p.ParentCol != "" {
		selects = append(selects, p.ParentCol+" AS parent_id")
	}

	var total int
	if err := exec.QueryRow(ctx,
		"SELECT count(*) FROM "+tableName+where, args...).Scan(&total); err != nil {
		return nil, err
	}

	sql := "SELECT " + strings.Join(selects, ", ") + " FROM " + tableName + where +
		" ORDER BY " + p.Pk + " ASC" +
		" LIMIT $" + strconv.Itoa(len(args)+1) + " OFFSET $" + strconv.Itoa(len(args)+2)
	args = append(args, pr.Limit, pr.Offset)

	rows, err := exec.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	type rawRow struct {
		vals  []any
		names []string
	}
	raws := []rawRow{}
	fds := rows.FieldDescriptions()
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			rows.Close()
			return nil, err
		}
		names := make([]string, len(fds))
		for i, fd := range fds {
			names[i] = string(fd.Name)
		}
		raws = append(raws, rawRow{vals: vals, names: names})
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()

	// Label induk (self-referensi) — satu query tambahan bila ada.
	parentLabels := map[string]string{}
	if p.ParentCol != "" {
		ids := []int64{}
		seen := map[int64]bool{}
		for _, raw := range raws {
			if v, ok := kolom(raw, "parent_id"); ok && v != nil {
				if n, ok := toInt64(v); ok && !seen[n] {
					seen[n] = true
					ids = append(ids, n)
				}
			}
		}
		if len(ids) > 0 {
			labelCol := p.LabelCol
			if labelCol == "" {
				labelCol = p.Pk
			}
			prows, err := exec.Query(ctx,
				"SELECT id, "+labelCol+" FROM "+tableName+" WHERE id = ANY($1)", ids)
			if err != nil {
				return nil, err
			}
			for prows.Next() {
				var id int64
				var label any
				if err := prows.Scan(&id, &label); err != nil {
					prows.Close()
					return nil, err
				}
				parentLabels[strconv.FormatInt(id, 10)] = fmt.Sprintf("%v", label)
			}
			if err := prows.Err(); err != nil {
				prows.Close()
				return nil, err
			}
			prows.Close()
		}
	}

	// Label FK per kolom — kumpulkan id unik lalu query label rujukan.
	fkLabels := map[string]map[string]string{}
	for _, d := range display {
		if d.fk == nil || d.fk.RefTable == "" || d.refProf == nil {
			continue
		}
		ids := []int64{}
		seen := map[int64]bool{}
		for _, raw := range raws {
			if v, ok := kolom(raw, d.name); ok && v != nil {
				if n, ok := toInt64(v); ok && !seen[n] {
					seen[n] = true
					ids = append(ids, n)
				}
			}
		}
		m := map[string]string{}
		if len(ids) > 0 {
			refRows, err := exec.Query(ctx,
				"SELECT id, "+d.refProf.LabelCol+" FROM "+d.fk.RefTable+" WHERE id = ANY($1)", ids)
			if err != nil {
				return nil, err
			}
			for refRows.Next() {
				var id int64
				var label any
				if err := refRows.Scan(&id, &label); err != nil {
					refRows.Close()
					return nil, err
				}
				m[strconv.FormatInt(id, 10)] = fmt.Sprintf("%v", label)
			}
			if err := refRows.Err(); err != nil {
				refRows.Close()
				return nil, err
			}
			refRows.Close()
		}
		fkLabels[d.name] = m
	}

	// Baris = objek DINAMIS: FK ditampilkan sebagai LABEL rujukannya.
	data := []types.ScopeOptionRow{}
	for _, raw := range raws {
		row := types.ScopeOptionRow{"value": toString(kolomMust(raw, "value"))}
		if p.ParentCol != "" {
			if v, ok := kolom(raw, "parent_id"); ok && v != nil {
				row["parent"] = parentLabels[toString(v)]
			} else {
				row["parent"] = nil
			}
		} else {
			row["parent"] = nil
		}
		for _, d := range display {
			v, _ := kolom(raw, d.name)
			if d.fk != nil && d.fk.RefTable != "" {
				if v == nil {
					row[d.name] = nil
				} else if label, ok := fkLabels[d.name][toString(v)]; ok {
					row[d.name] = label
				} else {
					row[d.name] = toString(v)
				}
			} else {
				row[d.name] = anyOrNil(v)
			}
		}
		data = append(data, row)
	}

	out := &types.ScopeOptionsResult{Data: data, Columns: columns}
	page := errkontrak.BuildPage([]types.ScopeOptionRow{}, total, pr)
	out.Meta = struct {
		Page       int `json:"page"`
		Limit      int `json:"limit"`
		Total      int `json:"total"`
		TotalPages int `json:"totalPages"`
	}{Page: page.Meta.Page, Limit: page.Meta.Limit, Total: page.Meta.Total, TotalPages: page.Meta.TotalPages}
	return out, nil
}

// ---------------------------------------------------------------------
// helper nilai dinamis
// ---------------------------------------------------------------------

func kolom(raw struct {
	vals  []any
	names []string
}, name string) (any, bool) {
	for i, n := range raw.names {
		if n == name {
			return raw.vals[i], true
		}
	}
	return nil, false
}

func kolomMust(raw struct {
	vals  []any
	names []string
}, name string) any {
	v, _ := kolom(raw, name)
	return v
}

// toInt64 — nilai numerik PG (int64/int32/float64) → int64.
func toInt64(v any) (int64, bool) {
	switch t := v.(type) {
	case int64:
		return t, true
	case int32:
		return int64(t), true
	case int16:
		return int64(t), true
	case float64:
		return int64(t), true
	}
	return 0, false
}

// toString — nilai baris → teks (value whitelist = String(pk)).
func toString(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	if n, ok := toInt64(v); ok {
		return strconv.FormatInt(n, 10)
	}
	return fmt.Sprintf("%v", v)
}

// anyOrNil — nilai tampilan apa adanya (nil diteruskan).
func anyOrNil(v any) any {
	if v == nil {
		return nil
	}
	return v
}

func joinOr(parts []string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += " OR "
		}
		out += p
	}
	return out
}
