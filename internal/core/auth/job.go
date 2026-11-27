// Job SWEEP token auth — pola baku siklus (padanan jobs/token-sweep.job.ts
// BullMQ): queue `nexierp.auth`, job `auth.token-sweep`, interval env
// AUTH_TOKEN_SWEEP_INTERVAL_MS (default 6 jam; dibaca ULANG tiap eksekusi;
// 0 = job mati — tick dorman 60 dtk). SATU siklus = SATU delegasi
// Service.SweepTokenKedaluwarsa. Registrasi ke queue.Mux (core/queue —
// dikontrak agent lain; import di sini HANYA kontraknya).
package auth

import (
	"context"

	"nexierp/internal/core/queue"
)

// Nama queue & job — satu queue per modul (persis token-sweep.job.ts).
const (
	NamaQueueSweep = "nexierp.auth"
	NamaJobSweep   = "auth.token-sweep"
)

// RegistrasiSiklusSweep — daftarkan siklus sweep pada Mux queue. Interval
// dibungkus fungsi agar dibaca ulang tiap eksekusi (interval env berubah
// tanpa restart); 0 = mati ditangani Mux (tick dorman 60 dtk).
func (s *Service) RegistrasiSiklusSweep(mux *queue.Mux) {
	mux.DaftarkanSiklus(NamaQueueSweep, NamaJobSweep,
		func() int64 { return int64(s.cfg.AuthTokenSweepIntervalMs) },
		func(ctx context.Context) error {
			dihapus, err := s.SweepTokenKedaluwarsa(ctx)
			if err != nil {
				return err
			}
			if dihapus > 0 {
				s.logger.Info("Sweep token auth: token kedaluwarsa dihapus.", "jumlah", dihapus)
			}
			return nil
		},
	)
}
