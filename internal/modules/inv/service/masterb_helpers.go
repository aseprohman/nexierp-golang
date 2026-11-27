// service/masterb_helpers.go — helper kecil lintas-fitur MASTER-B modul inv
// (prefix `mb` — pengaman kolisi nama dengan file fitur lain di package
// service yang sama): merge patch 3-state, aktor scope, entityId.
package service

import (
	"nexierp/internal/core/audit"
	"nexierp/internal/core/numbering"
)

// numberingEntityID — id entity natural baru (kolom entity_id NOT NULL
// UNIQUE semua tabel inv).
func numberingEntityID() string { return numbering.NewEntityID() }

// actorIDOf — id user aktor utk evaluasi scope; 0 = sistem (fail-open SEMUA
// — padanan actor?.id == null).
func actorIDOf(actor audit.Actor) int64 {
	if actor.IDCoreUsers != nil {
		return *actor.IDCoreUsers
	}
	return 0
}

// mergeStr — padanan `input.x ?? row.x`: tidak dikirim → nilai lama.
func mergeStr(in *string, lama string) string {
	if in != nil {
		return *in
	}
	return lama
}

// merge3 — padanan `input.x !== undefined ? input.x : row.x` untuk field
// nullish 3-state: tidak dikirim → lama; dikirim (termasuk null) → pakai.
func merge3[T any](ada bool, in *T, lama *T) *T {
	if ada {
		return in
	}
	return lama
}

// mergeStatus — padanan `(input.status ?? row.status)`: "" (tidak dikirim)
// → nilai lama.
func mergeStatus(in, lama string) string {
	if in != "" {
		return in
	}
	return lama
}
