// Package service — orkestrasi fitur IAM modul core (padanan
// services/iam/*.ts NestJS): validasi → SATU transaksi bisnis (repo + audit
// di executor tx yang sama) → invalidasi registry/compiler setelah commit →
// mapping view. Pesan error & urutan validasi VERBATIM sumber.
package service

import (
	"encoding/json"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/core/repository"
)

// ---------------------------------------------------------------------
// Dependensi fitur (dibangun handler dari types.Deps)
// ---------------------------------------------------------------------

// IamRoutesService — padanan IamRoutesService.
type IamRoutesService struct {
	db       *database.DB
	audit    *audit.Service
	registry *rbac.RouteRegistry
	repo     *repository.RoutesRepo
}

// NewIamRoutesService membuat service routes.
func NewIamRoutesService(d Deps) *IamRoutesService {
	return &IamRoutesService{
		db:       d.DB,
		audit:    d.Audit,
		registry: d.Registry,
		repo:     repository.NewRoutesRepo(),
	}
}

// IamPermissionsService — padanan IamPermissionsService.
type IamPermissionsService struct {
	db    *database.DB
	audit *audit.Service
	repo  *repository.PermissionsRepo
}

// NewIamPermissionsService membuat service permissions.
func NewIamPermissionsService(d Deps) *IamPermissionsService {
	return &IamPermissionsService{db: d.DB, audit: d.Audit, repo: repository.NewPermissionsRepo()}
}

// IamMenusService — padanan IamMenusService.
type IamMenusService struct {
	db       *database.DB
	audit    *audit.Service
	compiler *rbac.Compiler
	repo     *repository.MenusRepo
}

// NewIamMenusService membuat service menus.
func NewIamMenusService(d Deps) *IamMenusService {
	return &IamMenusService{db: d.DB, audit: d.Audit, compiler: d.Compiler, repo: repository.NewMenusRepo()}
}

// IamFeaturesService — padanan IamFeaturesService.
type IamFeaturesService struct {
	db    *database.DB
	audit *audit.Service
	repo  *repository.FeaturesRepo
}

// NewIamFeaturesService membuat service features.
func NewIamFeaturesService(d Deps) *IamFeaturesService {
	return &IamFeaturesService{db: d.DB, audit: d.Audit, repo: repository.NewFeaturesRepo()}
}

// IamUserOverridesService — padanan IamUserOverridesService.
type IamUserOverridesService struct {
	db       *database.DB
	audit    *audit.Service
	compiler *rbac.Compiler
	repo     *repository.OverridesRepo
}

// NewIamUserOverridesService membuat service user-overrides.
func NewIamUserOverridesService(d Deps) *IamUserOverridesService {
	return &IamUserOverridesService{db: d.DB, audit: d.Audit, compiler: d.Compiler, repo: repository.NewOverridesRepo()}
}

// IamDatascopeService — padanan IamDatascopeService.
type IamDatascopeService struct {
	db    *database.DB
	audit *audit.Service
	repo  *repository.DatascopeRepo
}

// NewIamDatascopeService membuat service datascope.
func NewIamDatascopeService(d Deps) *IamDatascopeService {
	return &IamDatascopeService{db: d.DB, audit: d.Audit, repo: repository.NewDatascopeRepo()}
}

// Deps — alias kebutuhan wiring (hindari import siklus handler ↔ service;
// handler membangun service dari types.Deps lewat konversi ini).
type Deps struct {
	DB       *database.DB
	Audit    *audit.Service
	Registry *rbac.RouteRegistry
	Compiler *rbac.Compiler
}

// ---------------------------------------------------------------------
// Snapshot audit — padanan afterValue/beforeValue jsonb drizzle
// ---------------------------------------------------------------------

// iamSnapshotOf — struct view apa pun → audit.Snapshot (jsonb before/after;
// bentuk objek persis sumber karena diproses lewat JSON).
func iamSnapshotOf(v any) audit.Snapshot {
	b, err := json.Marshal(v)
	if err != nil {
		return audit.Snapshot{}
	}
	var m audit.Snapshot
	_ = json.Unmarshal(b, &m)
	return m
}

// iamDerefInt64 — *int64 → int64 (nil → 0).
func iamDerefInt64(v *int64) int64 {
	if v == nil {
		return 0
	}
	return *v
}

// iamDerefInt32 — *int32 → int32 (nil → 0).
func iamDerefInt32(v *int32) int32 {
	if v == nil {
		return 0
	}
	return *v
}
