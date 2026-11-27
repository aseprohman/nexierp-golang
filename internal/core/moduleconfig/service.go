// Package moduleconfig — konfigurasi parameter bisnis BER-OWNER MODUL
// (core_module_configs — padanan ModuleConfigService NestJS). Nilai
// terserialisasi TEXT; tafsir via value_type (lihat values.go). setValue
// upsert by natural key dengan optimistic locking (409 VAL-409 bila
// expectedVersion tidak cocok); TANPA cache nilai (reads jarang) — hanya FK
// modul yang di-cache in-memory. Semua method menerima executor DBTX agar
// bisa dibaca/ditulis di dalam transaksi bisnis pemanggil.
package moduleconfig

import (
	"context"
	"fmt"
	"sync"

	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
)

// Value — nilai config: string | float64 | bool | map/slice | nil.
type Value = any

// Service — kernel moduleconfig.
type Service struct {
	db   *database.DB
	repo *Repository

	mu    sync.Mutex
	cache map[string]int64 // moduleKey → id_core_modules (pola NumberingService)
}

// New membuat service moduleconfig.
func New(db *database.DB) *Service {
	return &Service{db: db, repo: NewRepository(), cache: make(map[string]int64)}
}

// GetValue — nilai param (sudah di-parse sesuai value_type) — fallback bila
// baris belum ada; nil bila tidak ada fallback. TANPA cache — baca langsung.
func (s *Service) GetValue(ctx context.Context, exec DBTX, moduleKey, paramKey string, fallback ...Value) (Value, error) {
	v, found, err := s.getFound(ctx, exec, moduleKey, paramKey)
	if err != nil {
		return nil, err
	}
	if !found && len(fallback) > 0 {
		return fallback[0], nil
	}
	return v, nil
}

// GetString — nilai bertipe string — error bila baris ada tapi tipenya bukan
// string (pesan persis service NestJS).
func (s *Service) GetString(ctx context.Context, exec DBTX, moduleKey, paramKey string, fallback ...string) (string, error) {
	v, found, err := s.getFound(ctx, exec, moduleKey, paramKey)
	if err != nil {
		return "", err
	}
	if !found {
		if len(fallback) > 0 {
			return fallback[0], nil
		}
		return "", nil
	}
	if str, ok := v.(string); ok {
		return str, nil
	}
	return "", typeMismatch(moduleKey, paramKey, "string", namaTipe(v))
}

// GetNumber — nilai bertipe number — error bila tipenya bukan number.
func (s *Service) GetNumber(ctx context.Context, exec DBTX, moduleKey, paramKey string, fallback ...float64) (float64, error) {
	v, found, err := s.getFound(ctx, exec, moduleKey, paramKey)
	if err != nil {
		return 0, err
	}
	if !found {
		if len(fallback) > 0 {
			return fallback[0], nil
		}
		return 0, nil
	}
	if n, ok := v.(float64); ok {
		return n, nil
	}
	return 0, typeMismatch(moduleKey, paramKey, "number", namaTipe(v))
}

// GetBoolean — nilai bertipe boolean — error bila tipenya bukan boolean.
func (s *Service) GetBoolean(ctx context.Context, exec DBTX, moduleKey, paramKey string, fallback ...bool) (bool, error) {
	v, found, err := s.getFound(ctx, exec, moduleKey, paramKey)
	if err != nil {
		return false, err
	}
	if !found {
		if len(fallback) > 0 {
			return fallback[0], nil
		}
		return false, nil
	}
	if b, ok := v.(bool); ok {
		return b, nil
	}
	return false, typeMismatch(moduleKey, paramKey, "boolean", namaTipe(v))
}

// GetJson — nilai bertipe json (object/array/null) — error bila scalar.
func (s *Service) GetJson(ctx context.Context, exec DBTX, moduleKey, paramKey string, fallback ...Value) (Value, error) {
	v, found, err := s.getFound(ctx, exec, moduleKey, paramKey)
	if err != nil {
		return nil, err
	}
	if !found {
		if len(fallback) > 0 {
			return fallback[0], nil
		}
		return nil, nil
	}
	// json null (nil) dan object/array lolos; scalar → error.
	if v == nil || isJSONContainer(v) {
		return v, nil
	}
	return nil, typeMismatch(moduleKey, paramKey, "json", namaTipe(v))
}

// SetValue menyimpan nilai (upsert by modul+param_key):
//   - baris BELUM ada → insert (version 0) — konflik race ditangani
//     ON CONFLICT DO NOTHING lalu lanjut jalur update;
//   - baris SUDAH ada → update kondisional `version = expectedVersion`
//     (atomic) + naikkan version, catat actor & updated_at — tidak cocok
//     → 409 VAL-409.
//
// Return: version baris pasca simpan (baris baru = 0).
func (s *Service) SetValue(ctx context.Context, exec DBTX, moduleKey, paramKey string, v Value, actorID *int64, expectedVersion *int64) (int64, error) {
	valueType, raw, err := SerializeConfigValue(v)
	if err != nil {
		return 0, err
	}
	moduleID, err := s.resolveModuleID(ctx, exec, moduleKey)
	if err != nil {
		return 0, err
	}

	// Jalur baris baru — insert diam bila sudah diperebutkan penulis lain.
	inserted, err := s.repo.InsertIgnoreConflict(ctx, exec, moduleID, paramKey, raw, valueType, actorID)
	if err != nil {
		return 0, fmt.Errorf("module-config: insert core_module_configs: %w", err)
	}
	if inserted {
		return 0, nil
	}

	// Jalur update — conditional optimistic locking dalam SATU statement.
	newVersion, updated, err := s.repo.UpdateConditional(ctx, exec, moduleID, paramKey, raw, valueType, actorID, expectedVersion)
	if err != nil {
		return 0, fmt.Errorf("module-config: update core_module_configs: %w", err)
	}
	if updated {
		return newVersion, nil
	}

	// Update tidak mengenai baris — bedakan stale version vs baris lenyap.
	row, found, err := s.repo.FindRowByKey(ctx, exec, moduleID, paramKey)
	if err != nil {
		return 0, err
	}
	if !found {
		return 0, fmt.Errorf(
			"[module-config] baris '%s/%s' hilang saat update — periksa FK modul.", moduleKey, paramKey)
	}
	dibaca := int64(0)
	if expectedVersion != nil {
		dibaca = *expectedVersion
	}
	return 0, errkontrak.Conflict(fmt.Sprintf(
		"Konfigurasi '%s/%s' sudah diubah pemilik lain (versi dibaca %d, versi aktual %d) — muat ulang lalu ulangi.",
		moduleKey, paramKey, dibaca, row.Version), "VAL-409")
}

// ClearValue menghapus baris param (mis. override outlet dikembalikan
// menyamai global — G-22). HARD delete — core_module_configs tidak punya
// deleted_at; baris override bukan data bisnis historis, nilai global tetap
// utuh. true bila ada baris terhapus (idempoten bila tidak ada).
func (s *Service) ClearValue(ctx context.Context, exec DBTX, moduleKey, paramKey string) (bool, error) {
	moduleID, err := s.resolveModuleID(ctx, exec, moduleKey)
	if err != nil {
		return false, err
	}
	return s.repo.DeleteHard(ctx, exec, moduleID, paramKey)
}

// KunciOverrideOutlet — konvensi kunci override per outlet (blueprint A-09,
// TANPA DDL baru): baris override disimpan di tabel core_module_configs yang
// sama dengan param_key ber-sufiks `@outlet:<idPosOutlet>` — konteks
// DIKODEKAN DI NATURAL KEY.
func KunciOverrideOutlet(paramKey string, idPosOutlet int64) string {
	return fmt.Sprintf("%s@outlet:%d", paramKey, idPosOutlet)
}

// NilaiEfektifPos — nilai EFEKTIF param modul "pos" untuk satu outlet
// (G-22/A-09): bila idPosOutlet diberikan (>0) dan baris override
// `CFG-POS-xx@outlet:<id>` ada → nilai override menang; selain itu nilai
// global (fallback tetap dihormati bila keduanya tidak ada).
func (s *Service) NilaiEfektifPos(ctx context.Context, exec DBTX, paramKey string, idPosOutlet *int64, fallback ...Value) (Value, error) {
	v, found, err := s.nilaiEfektifFound(ctx, exec, paramKey, idPosOutlet)
	if err != nil {
		return nil, err
	}
	if !found {
		return s.GetValue(ctx, exec, "pos", paramKey, fallback...)
	}
	return v, nil
}

// NilaiEfektifPosNumber — varian number dari NilaiEfektifPos — error bila
// nilai bukan number.
func (s *Service) NilaiEfektifPosNumber(ctx context.Context, exec DBTX, paramKey string, idPosOutlet *int64, fallback ...float64) (float64, error) {
	v, found, err := s.nilaiEfektifFound(ctx, exec, paramKey, idPosOutlet)
	if err != nil {
		return 0, err
	}
	if !found {
		if len(fallback) > 0 {
			return fallback[0], nil
		}
		return 0, nil
	}
	if n, ok := v.(float64); ok {
		return n, nil
	}
	return 0, typeMismatch("pos", paramKey, "number", namaTipe(v))
}

// NilaiEfektifPosString — varian string dari NilaiEfektifPos.
func (s *Service) NilaiEfektifPosString(ctx context.Context, exec DBTX, paramKey string, idPosOutlet *int64, fallback ...string) (string, error) {
	v, found, err := s.nilaiEfektifFound(ctx, exec, paramKey, idPosOutlet)
	if err != nil {
		return "", err
	}
	if !found {
		if len(fallback) > 0 {
			return fallback[0], nil
		}
		return "", nil
	}
	if str, ok := v.(string); ok {
		return str, nil
	}
	return "", typeMismatch("pos", paramKey, "string", namaTipe(v))
}

// NilaiEfektifPosJson — varian json dari NilaiEfektifPos — error bila scalar.
func (s *Service) NilaiEfektifPosJson(ctx context.Context, exec DBTX, paramKey string, idPosOutlet *int64, fallback ...Value) (Value, error) {
	v, found, err := s.nilaiEfektifFound(ctx, exec, paramKey, idPosOutlet)
	if err != nil {
		return nil, err
	}
	if !found {
		if len(fallback) > 0 {
			return fallback[0], nil
		}
		return nil, nil
	}
	if v == nil || isJSONContainer(v) {
		return v, nil
	}
	return nil, typeMismatch("pos", paramKey, "json", namaTipe(v))
}

// ---------------------------------------------------------------------------
// Helper privat
// ---------------------------------------------------------------------------

// getFound — nilai + penanda baris ada (membedakan "belum ada" dari json
// null agar getter bertipe akurat).
func (s *Service) getFound(ctx context.Context, exec DBTX, moduleKey, paramKey string) (Value, bool, error) {
	row, found, err := s.findRow(ctx, exec, moduleKey, paramKey)
	if err != nil || !found {
		return nil, false, err
	}
	v, err := ParseConfigValue(row.ValueType, row.ParamValue)
	if err != nil {
		return nil, true, err
	}
	return v, true, nil
}

// nilaiEfektifFound — nilai efektif POS + penanda ada (tanpa fallback).
func (s *Service) nilaiEfektifFound(ctx context.Context, exec DBTX, paramKey string, idPosOutlet *int64) (Value, bool, error) {
	if idPosOutlet != nil && *idPosOutlet > 0 {
		return s.getFound(ctx, exec, "pos", KunciOverrideOutlet(paramKey, *idPosOutlet))
	}
	return nil, false, nil
}

// findRow — resolve modul lalu pilih baris config.
func (s *Service) findRow(ctx context.Context, exec DBTX, moduleKey, paramKey string) (ConfigRow, bool, error) {
	moduleID, err := s.resolveModuleID(ctx, exec, moduleKey)
	if err != nil {
		return ConfigRow{}, false, err
	}
	return s.repo.FindRowByKey(ctx, exec, moduleID, paramKey)
}

// resolveModuleID — natural key modul → FK numerik (cache in-memory — pola
// NumberingService); modul tidak terdaftar → 404 NOTF-404 persis NestJS
// (DomainError.notFound).
func (s *Service) resolveModuleID(ctx context.Context, exec DBTX, moduleKey string) (int64, error) {
	s.mu.Lock()
	id, ok := s.cache[moduleKey]
	s.mu.Unlock()
	if ok {
		return id, nil
	}
	found, err := s.repo.FindModuleIdByKey(ctx, exec, moduleKey)
	if err != nil {
		return 0, fmt.Errorf("module-config: lookup core_modules: %w", err)
	}
	if found == nil {
		return 0, errkontrak.NotFound(fmt.Sprintf("Modul '%s' tidak terdaftar di core_modules.", moduleKey))
	}
	s.mu.Lock()
	s.cache[moduleKey] = *found
	s.mu.Unlock()
	return *found, nil
}

// typeMismatch — error tipe tidak cocok (pesan persis service NestJS).
func typeMismatch(moduleKey, paramKey, expected, actual string) error {
	return fmt.Errorf(
		"[module-config] tipe nilai '%s/%s' %s, getter menuntut %s — periksa value_type param.",
		moduleKey, paramKey, actual, expected)
}

// namaTipe — padanan typeof JS untuk pesan mismatch (null → "object").
func namaTipe(v Value) string {
	switch v.(type) {
	case nil:
		return "object" // typeof null === "object"
	case string:
		return "string"
	case float64:
		return "number"
	case bool:
		return "boolean"
	default:
		return "object"
	}
}

// isJSONContainer — object/array hasil parse JSON (map | slice).
func isJSONContainer(v Value) bool {
	switch v.(type) {
	case map[string]any, []any:
		return true
	}
	return false
}
