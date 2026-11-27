// Package audit — KONTRAK (disusun koordinator; jangan ubah file ini).
// Service & repository ditambahkan di file lain dengan SEMANTIK persis
// AuditService NestJS (append in-transaction, aktor dari JWT oleh caller).
package audit

// Severity — enum core_audit_trail.severity.
type Severity string

const (
	SeverityInfo     Severity = "info"
	SeverityWarning  Severity = "warning"
	SeverityCritical Severity = "critical"
)

// Snapshot — jsonb before/after.
type Snapshot map[string]any

// Actor — padanan AuditActor NestJS. IDCoreUsers nil = proses sistem.
// Aktor WAJIB dibangun CALLER dari JWT (req.user) — tidak pernah dari payload client.
type Actor struct {
	IDCoreUsers *int64
	ActorName   string // fallback service: "system"
	IPAddress   string // fallback service: ""
	UserAgent   string // fallback service: "server"
	RequestID   string // fallback service: "req-"+6 byte hex
}

// EntryInput — padanan AuditEntryInput.
type EntryInput struct {
	ModuleKey     string // opsional; di-resolve ke id_core_modules
	IdCoreModules *int64 // opsional; bila sudah diketahui caller
	EntityType    string
	EntityID      string
	Action        string
	Severity      Severity // kosong → "info"
	BeforeValue   Snapshot
	AfterValue    Snapshot
}

// AppendInput — padanan AuditAppendInput (entry + actor).
type AppendInput struct {
	EntryInput
	Actor Actor
}

// AppendResult — padanan { ids }.
type AppendResult struct {
	IDs []int64
}
