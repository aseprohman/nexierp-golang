package queue

// Unit test MURNI (tanpa Redis/goroutine) — padanan job-siklus.spec.ts:
// pemilihan interval + keputusan per tick (dorman, lantai, guard overlap).

import (
	"context"
	"testing"
	"time"
)

func TestPilihIntervalMs(t *testing.T) {
	kasus := []struct {
		nama     string
		interval int64
		harap    int64
	}{
		{"interval 0 (job mati) → tick dorman TickMatiMs", 0, TickMatiMs},
		{"interval negatif dianggap mati → TickMatiMs", -1, TickMatiMs},
		{"interval di bawah lantai → IntervalMinimalMs (anti config rusak)", 50, IntervalMinimalMs},
		{"interval normal diteruskan apa adanya", 15_000, 15_000},
		{"interval besar diteruskan apa adanya", 21_600_000, 21_600_000},
	}
	for _, k := range kasus {
		t.Run(k.nama, func(t *testing.T) {
			if got := PilihIntervalMs(k.interval); got != k.harap {
				t.Fatalf("PilihIntervalMs(%d) = %d, harap %d", k.interval, got, k.harap)
			}
		})
	}
}

func TestLangkahSiklus(t *testing.T) {
	kasus := []struct {
		nama          string
		interval      int64
		berjalan      bool
		harapEksekusi bool
		harapJeda     time.Duration
	}{
		{"interval 0 → mati, tick dorman 60 dtk", 0, false, false, 60 * time.Second},
		{"interval negatif → mati, tick dorman 60 dtk", -5, true, false, 60 * time.Second},
		{"interval kecil dilantai 1 dtk, boleh eksekusi", 50, false, true, 1 * time.Second},
		{"interval normal → jeda sama", 15_000, false, true, 15 * time.Second},
		{"overlap: siklus masih jalan → skip, jeda tetap", 2_000, true, false, 2 * time.Second},
	}
	for _, k := range kasus {
		t.Run(k.nama, func(t *testing.T) {
			eksekusi, jeda := langkahSiklus(k.interval, k.berjalan)
			if eksekusi != k.harapEksekusi || jeda != k.harapJeda {
				t.Fatalf("langkahSiklus(%d, %v) = (%v, %v), harap (%v, %v)",
					k.interval, k.berjalan, eksekusi, jeda, k.harapEksekusi, k.harapJeda)
			}
		})
	}
}

func TestTidurDibatalkanContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if tidur(ctx, time.Hour) {
		t.Fatal("tidur harus false bila context sudah dibatalkan")
	}
	if !tidur(context.Background(), time.Millisecond) {
		t.Fatal("tidur harus true untuk jeda normal")
	}
}

func TestEksekusiAmanPanicJadiError(t *testing.T) {
	err := eksekusiAman(context.Background(), func(ctx context.Context) error {
		panic("ledakan")
	})
	if err == nil {
		t.Fatal("panic harus diubah jadi error")
	}
}
