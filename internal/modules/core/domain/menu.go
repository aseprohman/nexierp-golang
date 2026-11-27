// Package domain — aturan murni modul core (tanpa I/O). Padanan
// domain/menu-rules.ts NestJS.
package domain

// ApakahParentKeturunan — apakah `parentUsulan` adalah keturunan dari
// `target`? Guard anti-siklus parent menu (PATCH /system/menus/:id): bila
// true, menjadikan `parentUsulan` sebagai parent `target` membentuk siklus
// A→B→…→A yang membuat subtree hilang dari tree navigasi.
//
// `parentOf` = accessor rantai parent (id → parent id | nil) — DB/live data;
// guard `dikunjungi` melindungi dari siklus data lama yang sudah korup
// (terminasi, bukan infinite loop).
func ApakahParentKeturunan(parentOf func(id int64) *int64, target, parentUsulan int64) bool {
	cursor := parentUsulan
	dikunjungi := map[int64]bool{}
	for cursor != 0 && !dikunjungi[cursor] {
		dikunjungi[cursor] = true
		if cursor == target {
			return true
		}
		next := parentOf(cursor)
		if next == nil {
			return false
		}
		cursor = *next
	}
	return false
}
