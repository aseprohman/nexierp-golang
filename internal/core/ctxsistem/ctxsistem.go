// Package ctxsistem — aktor sistem konstan untuk job/loop siklus
// (padanan CTX_SISTEM / aktor `{id:0, username:"system"}` NestJS).
// Nilai fallback (ip "", ua "server") diisi AuditService — actorName "system"
// adalah fallback baku service audit.
package ctxsistem

import "nexierp/internal/core/audit"

// Aktor mengembalikan actor sistem untuk panggilan service dari job.
func Aktor() audit.Actor {
	return audit.Actor{ActorName: "system"}
}
