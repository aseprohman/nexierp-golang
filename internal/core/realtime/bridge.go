// Jembatan compiler RBAC → hub WS (padanan rbac-realtime.bridge.ts):
// memasang listener invalidasi cache permission lalu menerjemahkannya jadi
// event `rbac.changed`. Interface lokal (callback, bukan inject struct)
// agar tidak terjadi siklus rbac → realtime → rbac.
//
// Catatan tipe: hook memakai rbac.InvalidationHook (nama tipe dari paket
// rbac, bentuk func(userIDs []int64, all bool)) — identitas tipe Go butuh
// NAMA tipe agar *rbac.Compiler benar-benar memenuhi interface ini
// (func literal dengan bentuk sama tetap assignable ke hook saat wiring).
package realtime

import (
	"nexierp/internal/core/rbac"
)

// OnInvalidator — kontrak minimal PermissionCompilerService
// (nexierp/internal/core/rbac).
type OnInvalidator interface {
	OnInvalidate(fn rbac.InvalidationHook)
}

// Bridge memasang callback invalidasi: all=true → kirim ke SEMUA koneksi
// aktif; selain itu ke room user terkait. Payload minimal {"reason":"rbac"}
// — klien tidak boleh memperlakukan payload sebagai sumber data.
func Bridge(comp OnInvalidator, h *Hub) {
	comp.OnInvalidate(func(userIDs []int64, all bool) {
		payload := map[string]string{"reason": "rbac"} // key JSON "reason"
		if all {
			h.emitSemua(EventRbacChanged, payload)
			return
		}
		h.EmitToUsers(userIDs, EventRbacChanged, payload)
	})
}
