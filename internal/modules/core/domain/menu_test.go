// domain/menu_test.go — uji murni guard anti-siklus parent menu
// (padanan menu-rules.spec.ts; terminasi pada rantai korup).
package domain

import (
	"testing"
)

func ptr(v int64) *int64 { return &v }

// rantai linear: 3→2→1 (1 = root).
func linearParent() func(int64) *int64 {
	return func(id int64) *int64 {
		switch id {
		case 2:
			return ptr(1)
		case 3:
			return ptr(2)
		}
		return nil
	}
}

func TestApakahParentKeturunanSiklus(t *testing.T) {
	// parentUsulan 3 adalah keturunan target 1 → jadikan parent 1 = 3 siklus.
	if !ApakahParentKeturunan(linearParent(), 1, 3) {
		t.Fatal("3 keturunan 1 — seharusnya terdeteksi siklus")
	}
	// parentUsulan = target langsung.
	if !ApakahParentKeturunan(linearParent(), 2, 3) {
		t.Fatal("3 anak langsung 2 — seharusnya terdeteksi")
	}
}

func TestApakahParentKeturunanAman(t *testing.T) {
	// parentUsulan 1 (root, tanpa parent) — bukan keturunan siapa pun.
	if ApakahParentKeturunan(linearParent(), 3, 1) {
		t.Fatal("1 bukan keturunan 3 — seharusnya aman")
	}
	// target = dirinya dengan parentUsulan cabang lain (tanpa relasi).
	if ApakahParentKeturunan(func(id int64) *int64 { return nil }, 5, 6) {
		t.Fatal("6 tanpa rantai ke 5 — seharusnya aman")
	}
}

func TestApakahParentKeturunanRantaiKorupTerminasi(t *testing.T) {
	// Data lama korup: 1→2 dan 2→1 (siklus eksisting). Guard wajib
	// terminasi (set dikunjungi), bukan infinite loop.
	korup := func(id int64) *int64 {
		switch id {
		case 1:
			return ptr(2)
		case 2:
			return ptr(1)
		}
		return nil
	}
	if ApakahParentKeturunan(korup, 9, 1) {
		t.Fatal("siklus korup tidak menyentuh target 9 — seharusnya false")
	}
}

func TestApakahParentKeturunanSiklusMengenaiTarget(t *testing.T) {
	// Korup namun rantainya melewati target: 1→2→1, target 2 → true.
	korup := func(id int64) *int64 {
		switch id {
		case 1:
			return ptr(2)
		case 2:
			return ptr(1)
		}
		return nil
	}
	if !ApakahParentKeturunan(korup, 2, 1) {
		t.Fatal("rantai korup melewati target 2 — seharusnya true")
	}
}
