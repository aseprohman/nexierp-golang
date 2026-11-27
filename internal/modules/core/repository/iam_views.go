// repository/iam_views.go — pembantu lintas-fitur IAM: alias executor sqlc,
// mapper waktu ISO-8601, mapper baris → view, dan penyusun ORDER BY
// whitelist (sort dinamis aman-injection — identifier dari map statis,
// nilai filter tetap parameter $n).
package repository

import (
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// DBTX — executor (pool | tx) agar mutasi + audit SATU transaksi bisnis.
type DBTX = gen.DBTX

// ---------------------------------------------------------------------
// Waktu — padanan shared/views.ts iso / isoRequired (ISO-8601 offset,
// toISOString JS selalu UTC + milidetik).
// ---------------------------------------------------------------------

const isoLayout = "2006-01-02T15:04:05.000Z07:00"

// Iso — pgtype.Timestamptz → ISO string; invalid → nil (kolom nullable).
func Iso(t pgtype.Timestamptz) *string {
	if !t.Valid {
		return nil
	}
	s := t.Time.UTC().Format(isoLayout)
	return &s
}

// IsoRequired — pgtype.Timestamptz → ISO string; invalid → string kosong
// (kolom NOT NULL — tak pernah terjadi).
func IsoRequired(t pgtype.Timestamptz) string {
	if !t.Valid {
		return ""
	}
	return t.Time.UTC().Format(isoLayout)
}

// ---------------------------------------------------------------------
// Mapper baris → view (padankan *ToView repo NestJS)
// ---------------------------------------------------------------------

// RouteToView — baris core_routes → RouteView (routeViewSchema).
func RouteToView(id int64, method string, uriPattern, permissionCode string, createdAt, updatedAt pgtype.Timestamptz) types.RouteView {
	return types.RouteView{
		ID:             id,
		Method:         method,
		URIPattern:     uriPattern,
		PermissionCode: permissionCode,
		CreatedAt:      IsoRequired(createdAt),
		UpdatedAt:      Iso(updatedAt),
	}
}

// PermissionNameOf — name NULL (kolom legacy nullable) → fallback id agar
// kontrak view `name: string` terpenuhi (persis permissionToView).
func PermissionNameOf(name pgtype.Text, id int64) string {
	if name.Valid && name.String != "" {
		return name.String
	}
	return "set#" + strconvI64(id)
}

// OverrideToView — baris flat JOIN override → UserOverrideView; moduleKey =
// segmen pertama permissionName (setara split_part di JS); permissionName
// null → fallback `set#<id>` (persis overrideToView).
func OverrideToView(r gen.FindOverrideJoinRowRow) types.UserOverrideView {
	permissionName := "set#" + strconvI64(r.PermissionID)
	if r.PermissionName.Valid && r.PermissionName.String != "" {
		permissionName = r.PermissionName.String
	}
	moduleKey := permissionName
	if i := strings.Index(permissionName, "."); i > 0 {
		moduleKey = permissionName[:i]
	}
	return types.UserOverrideView{
		ID:             r.ID,
		UserID:         r.UserID,
		UserName:       r.UserName,
		PermissionID:   r.PermissionID,
		PermissionName: permissionName,
		ModuleKey:      moduleKey,
		Granted:        r.Granted,
		GrantedByName:  PgTextPtr(r.GrantedByName),
		GrantedAt:      IsoRequired(r.GrantedAt),
		ExpiresAt:      Iso(r.ExpiresAt),
	}
}

// ---------------------------------------------------------------------
// Helper pointer/pgtype kecil
// ---------------------------------------------------------------------

// PgTextPtr — pgtype.Text → *string (invalid → nil).
func PgTextPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	return &t.String
}

// TextPtrOf — *string → pgtype.Text (nil → NULL).
func TextPtrOf(s *string) pgtype.Text {
	if s == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *s, Valid: true}
}

// Int8Of — *int64 → pgtype.Int8 (nil → NULL).
func Int8Of(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}

// Int8Ptr — pgtype.Int8 → *int64 (invalid → nil).
func Int8Ptr(v pgtype.Int8) *int64 {
	if !v.Valid {
		return nil
	}
	return &v.Int64
}

// Int2Ptr — pgtype.Int2 → *int32 (invalid → nil).
func Int2Ptr(v pgtype.Int2) *int32 {
	if !v.Valid {
		return nil
	}
	x := int32(v.Int16)
	return &x
}

// Int2Of — *int32 → pgtype.Int2 (nil → NULL).
func Int2Of(v *int32) pgtype.Int2 {
	if v == nil {
		return pgtype.Int2{}
	}
	return pgtype.Int2{Int16: int16(*v), Valid: true}
}

func strconvI64(v int64) string {
	return strconv.FormatInt(v, 10)
}

// ---------------------------------------------------------------------
// ORDER BY whitelist — padanan drizzlePageBounds (field di luar whitelist
// ditolak shared.SortUnknown; clause dibangun dari identifier statis).
// ---------------------------------------------------------------------

// orderClause — susun "col DIR, col DIR" dari hasil parse sort; def dipakai
// bila tidak ada sort. Identifier kolom dari map whitelist statis.
func orderClause(pr *errkontrak.PageRequest, allowed map[string]string, def string) string {
	if pr == nil || len(pr.Sort) == 0 {
		return def
	}
	parts := make([]string, 0, len(pr.Sort))
	for _, s := range pr.Sort {
		col, ok := allowed[s.Field]
		if !ok {
			continue // sudah ditolak SortUnknown — tidak mungkin lewat sini
		}
		dir := "ASC"
		if s.Desc {
			dir = "DESC"
		}
		parts = append(parts, col+" "+dir)
	}
	if len(parts) == 0 {
		return def
	}
	return strings.Join(parts, ", ")
}
