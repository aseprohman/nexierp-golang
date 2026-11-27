// Package queue — pola baku job siklus Go (padanan JobSiklusBullMQ NestJS),
// digulirkan dengan LOOP GOROUTINE (tanpa scheduler eksternal — interval CFG
// dinamis lebih cocok loop daripada ticker tetap). redisURL disimpan bagi
// task asynq antar-runtime yang menyusul; jalur siklus sendiri TIDAK
// menyentuh Redis, sehingga Mulai tetap hidup walau Redis mati.
//
// Kontrak pola baku (dipertahankan dari JobSiklusBullMQ):
//   - interval DIBACA ULANG tiap eksekusi (module-config/env) — berubah
//     berlaku tanpa restart; `<=0` = job mati (tick dorman 60 dtk tanpa
//     aksi, tick tetap jalan agar config hidup terbaca);
//   - guard overlap in-process (atomic bool) — skip, bukan antre;
//   - error siklus di-log warn, TIDAK pernah throw/panic ke kernel;
//   - eksekusi pertama ditunda JedaKickoffMs (padanan kickoff delayed).
package queue

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// Padanan konstanta JobSiklusBullMQ (TICK_MATI_MS dkk.).
const (
	// TickMatiMs — tick dorman saat interval <= 0 (job mati).
	TickMatiMs int64 = 60_000
	// IntervalMinimalMs — lantai interval, anti siklus tak-wajar dari
	// config rusak.
	IntervalMinimalMs int64 = 1_000
	// JedaKickoffMs — jeda eksekusi pertama setelah Mulai ("jeda awal").
	JedaKickoffMs int64 = 10_000
	// JedaMulaiUlangMs — jeda coba-ulang terkait Redis belum siap (disiapkan
	// bagi pemakai yang menyentuh Redis; Mux sendiri tidak memakainya).
	JedaMulaiUlangMs int64 = 60_000

	// TimeoutEksekusiDefault — context timeout per eksekusi (wajar, mencegah
	// siklus menggantung selamanya).
	TimeoutEksekusiDefault = 5 * time.Minute
)

// PilihIntervalMs — murni, padanan pilihEveryMs: interval > 0 dilantai
// IntervalMinimalMs; interval <= 0 (mati) → TickMatiMs.
func PilihIntervalMs(intervalMs int64) int64 {
	if intervalMs > 0 {
		return max(intervalMs, IntervalMinimalMs)
	}
	return TickMatiMs
}

// langkahSiklus — keputusan murni per tick (diuji unit tanpa Redis):
// apakah eksekusi dijalankan dan berapa jeda ke tick berikutnya
// (jeda = max(interval, IntervalMinimalMs) atau tick dorman).
func langkahSiklus(intervalMs int64, siklusBerjalan bool) (eksekusi bool, jeda time.Duration) {
	if intervalMs <= 0 {
		// job mati — tick dorman tanpa eksekusi (config tetap terbaca).
		return false, time.Duration(TickMatiMs) * time.Millisecond
	}
	jeda = time.Duration(PilihIntervalMs(intervalMs)) * time.Millisecond
	if siklusBerjalan {
		// guard overlap: tick bertumpuk saat siklus > interval → skip.
		return false, jeda
	}
	return true, jeda
}

// siklus — satu registrasi (padanan satu JobSiklusBullMQ).
type siklus struct {
	namaQueue  string
	namaJob    string
	intervalMs func() int64
	eksekusi   func(ctx context.Context) error
	berjalan   atomic.Bool // guard overlap in-process
}

// Mux — kumpulan siklus + lifecycle (padanan RegistWorker NestJS).
type Mux struct {
	redisURL string
	log      *slog.Logger

	mu     sync.Mutex
	daftar []*siklus
	cancel context.CancelFunc
	wg     sync.WaitGroup
	jalan  bool
}

// NewMux membuat mux kosong. log nil → slog.Default().
func NewMux(redisURL string, log *slog.Logger) *Mux {
	if log == nil {
		log = slog.Default()
	}
	return &Mux{redisURL: redisURL, log: log}
}

// DaftarkanSiklus memasang SATU goroutine siklus — panggil sebelum Mulai.
// intervalMs DIBACA ULANG tiap siklus; eksekusi menerima context ber timeout
// TimeoutEksekusiDefault (turunan context Mulai).
func (m *Mux) DaftarkanSiklus(namaQueue, namaJob string, intervalMs func() int64, eksekusi func(ctx context.Context) error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.jalan {
		m.log.Warn("DaftarkanSiklus setelah Mulai diabaikan", "job", namaJob)
		return
	}
	m.daftar = append(m.daftar, &siklus{
		namaQueue:  namaQueue,
		namaJob:    namaJob,
		intervalMs: intervalMs,
		eksekusi:   eksekusi,
	})
}

// Mulai menjalankan semua siklus terdaftar. Tidak pernah gagal walau Redis
// mati — jalur siklus tidak menyentuh Redis. Dipanggil dua kali = no-op.
func (m *Mux) Mulai(ctx context.Context) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.jalan {
		return
	}
	ctxMux, cancel := context.WithCancel(ctx)
	m.cancel = cancel
	m.jalan = true
	for _, s := range m.daftar {
		m.wg.Add(1)
		go m.jalankan(ctxMux, s)
	}
	m.log.Info("Mux job siklus aktif", "jumlah_siklus", len(m.daftar))
}

// Berhenti membatalkan context semua siklus lalu MENUNGGU goroutine
// (termasuk eksekusi yang sedang jalan) selesai — padanan berhenti().
func (m *Mux) Berhenti() {
	m.mu.Lock()
	cancel := m.cancel
	m.cancel = nil
	m.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	m.wg.Wait()
}

// jalankan — badan goroutine satu siklus. Tidak pernah panic ke kernel:
// error/panic eksekusi di-log warn, tick berikutnya tetap jalan.
func (m *Mux) jalankan(ctx context.Context, s *siklus) {
	defer m.wg.Done()
	// kickoff: eksekusi pertama JedaKickoffMs setelah boot — jangan menunggu
	// interval penuh (padanan job kickoff delayed). Bisa dibatalkan.
	if !tidur(ctx, time.Duration(JedaKickoffMs)*time.Millisecond) {
		return
	}
	m.log.Info("Job siklus aktif", "job", s.namaJob, "queue", s.namaQueue)
	for {
		// Interval DIBACA ULANG tiap siklus.
		eksekusi, jeda := langkahSiklus(s.intervalMs(), s.berjalan.Load())
		if eksekusi && s.berjalan.CompareAndSwap(false, true) {
			ectx, batalkan := context.WithTimeout(ctx, TimeoutEksekusiDefault)
			err := eksekusiAman(ectx, s.eksekusi)
			batalkan()
			s.berjalan.Store(false)
			if err != nil && ctx.Err() == nil {
				// shutdown diminta → diam; error lain → warn, lanjut tick.
				m.log.Warn("Siklus gagal — lanjut tick berikut", "job", s.namaJob, "err", err.Error())
			}
		}
		// setelah selesai tunggu max(interval, 1000ms) — tick berikutnya.
		if !tidur(ctx, jeda) {
			return
		}
	}
}

// eksekusiAman menjalankan delegasi dengan recover — panic diubah jadi
// error (kernel tidak boleh mati oleh job).
func eksekusiAman(ctx context.Context, fn func(ctx context.Context) error) (err error) {
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("panic siklus: %v", p)
		}
	}()
	return fn(ctx)
}

// tidur menunggu d ATAU ctx.Done — false berarti dibatalkan.
func tidur(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return ctx.Err() == nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
