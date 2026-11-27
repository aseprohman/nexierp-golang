package repository

// Helper datascope (gen hanya boleh di repository/): builder params +
// mapper row→View. Argumen primitif — tipe input milik service.

import (
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

func isoPg(t pgtype.Timestamptz) string {
	if !t.Valid {
		return ""
	}
	return t.Time.UTC().Format("2006-01-02T15:04:05.000Z07:00")
}

// DefinitionToView — mapper baris core_scope_definitions → view
// (persis definitionToView NestJS: ISO UTC, version, tanpa deleted_at).
func DefinitionToView(row gen.CoreScopeDefinition) types.ScopeDefinitionView {
	return types.ScopeDefinitionView{
		ID:          row.ID,
		ModuleID:    row.IDCoreModules,
		ScopeKey:    row.ScopeKey,
		Label:       row.Label,
		Description: row.Description,
		TargetTable: row.TargetTable,
		TargetField: row.TargetField,
		Operator:    string(row.Operator),
		IsActive:    row.IsActive,
		Version:     row.Version,
		CreatedAt:   isoPg(row.CreatedAt),
	}
}

// BuildInsertDefinitionParams — dari input service (primitif).
func BuildInsertDefinitionParams(moduleID int64, scopeKey, label string, description *string, targetTable, targetField string) gen.InsertScopeDefinitionParams {
	desc := ""
	if description != nil {
		desc = *description
	}
	return gen.InsertScopeDefinitionParams{
		IDCoreModules: moduleID,
		ScopeKey:      scopeKey,
		Label:         label,
		Description:   desc,
		TargetTable:   targetTable,
		TargetField:   targetField,
	}
}

// BuildInsertAssignmentParams — dari input service (primitif; XOR sudah
// divalidasi schema — tepat satu dari roleID/userID non-nil).
func BuildInsertAssignmentParams(definitionID int64, roleID, userID *int64, note *string) gen.InsertScopeAssignmentParams {
	p := gen.InsertScopeAssignmentParams{
		IDCoreScopeDefinitions: definitionID,
		Note:                   "",
	}
	if note != nil {
		p.Note = *note
	}
	if roleID != nil {
		p.IDCoreRoles = pgtype.Int8{Int64: *roleID, Valid: true}
	}
	if userID != nil {
		p.IDCoreUsers = pgtype.Int8{Int64: *userID, Valid: true}
	}
	return p
}
