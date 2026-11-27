// Package numbering — penomoran dokumen ANTI-RACE (padanan NumberingService
// NestJS, ARSITEKTUR §7.2). Sumber nomor = baris `core_sequences` per
// (modul, jenis dokumen). Pola wajib: UPDATE dulu (jalur umum), bila 0 baris
// seed-if-missing lalu UPDATE LAGI dalam STATEMENT BARU (snapshot segar —
// CTE data-modifying TIDAK BOLEH dipakai: UPDATE dalam statement yang sama
// tidak melihat baris hasil INSERT CTE). Semua method menerima executor
// DBTX — pemanggil memakai tx bisnis yang sama agar nomor ikut
// commit/rollback bersama dokumennya.
package numbering

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"nexierp/internal/core/database"
)

// Options — opsi pemakaian nomor.
type Options struct {
	Prefix  string     // prefix bila baris counter BELUM ada (seed)
	Padding int        // lebar digit bila baris counter belum ada (default 4)
	Joiner  string     // pemisah prefix–nomor (default otomatis — lihat FormatCode)
	Now     *time.Time // basis render template {MMyy} (default now — utk unit test)
}

// Allocation — baris counter hasil alokasi.
type Allocation struct {
	Seq     int64
	Prefix  string
	Padding int
}

// Service — kernel numbering.
type Service struct {
	db   *database.DB
	repo *Repository

	mu    sync.Mutex
	cache map[string]int64 // moduleKey → id_core_modules (core_modules jarang berubah)
}

// New membuat service numbering.
func New(db *database.DB) *Service {
	return &Service{db: db, repo: NewRepository(), cache: make(map[string]int64)}
}

// Next mengambil nomor berikutnya + kode final untuk satu (modul, jenis
// dokumen).
func (s *Service) Next(ctx context.Context, exec DBTX, moduleKey, docName string, opt Options) (string, error) {
	a, err := s.Allocate(ctx, exec, moduleKey, docName, opt)
	if err != nil {
		return "", err
	}
	return FormatCode(a, opt), nil
}

// Allocate mengalokasikan counter — UPDATE dulu; 0 baris → seed-if-missing
// DALAM TX SAMA lalu UPDATE LAGI DALAM STATEMENT BARU (snapshot segar);
// gagal lagi → error persis service NestJS.
func (s *Service) Allocate(ctx context.Context, exec DBTX, moduleKey, docName string, opt Options) (Allocation, error) {
	// Modul wajib terdaftar (cek + cache) — persis urutan NestJS.
	if _, err := s.resolveModuleID(ctx, exec, moduleKey); err != nil {
		return Allocation{}, err
	}
	prefix := opt.Prefix
	if prefix == "" {
		prefix = strings.ToUpper(truncateRunes(docName, 20)) // docName.slice(0,20).toUpperCase()
	}
	padding := opt.Padding
	if padding == 0 {
		padding = 4
	}

	row, err := s.repo.IncrementSequence(ctx, exec, moduleKey, docName)
	if err != nil {
		return Allocation{}, fmt.Errorf("numbering: increment core_sequences: %w", err)
	}
	if row == nil {
		// Baris belum ada — seed-kan (idempoten), lalu increment di statement
		// baru agar snapshot-nya melihat baris yang baru dibuat.
		if err := s.repo.SeedSequence(ctx, exec, moduleKey, docName, prefix, padding); err != nil {
			return Allocation{}, fmt.Errorf("numbering: seed core_sequences: %w", err)
		}
		row, err = s.repo.IncrementSequence(ctx, exec, moduleKey, docName)
		if err != nil {
			return Allocation{}, fmt.Errorf("numbering: increment core_sequences: %w", err)
		}
	}
	if row == nil {
		return Allocation{}, fmt.Errorf(
			"Numbering gagal: baris core_sequences (%s/%s) tidak bisa dialokasi.", moduleKey, docName)
	}
	return Allocation{Seq: row.CurrentValue, Prefix: row.Prefix, Padding: row.Padding}, nil
}

// resolveModuleID — natural key modul → FK numerik (cache in-memory,
// aman-race); error persis service NestJS bila modul tidak terdaftar.
func (s *Service) resolveModuleID(ctx context.Context, exec DBTX, moduleKey string) (int64, error) {
	s.mu.Lock()
	id, ok := s.cache[moduleKey]
	s.mu.Unlock()
	if ok {
		return id, nil
	}
	found, err := s.repo.FindModuleIdByKey(ctx, exec, moduleKey)
	if err != nil {
		return 0, fmt.Errorf("numbering: lookup core_modules: %w", err)
	}
	if found == nil {
		return 0, fmt.Errorf("Modul '%s' tidak terdaftar di core_modules.", moduleKey)
	}
	s.mu.Lock()
	s.cache[moduleKey] = *found
	s.mu.Unlock()
	return *found, nil
}

// truncateRunes — padanan slice(0, n) tingkat rune (bukan byte).
func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}
