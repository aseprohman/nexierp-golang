// Tipe area mailer — padanan types/mailer-types.ts. Murni tipe/kontrak.
package mailer

// MailPayload — payload satu kirim email (padanan MailPayload NestJS).
type MailPayload struct {
	// Kepada — alamat email tujuan (single — loop di pemanggil untuk banyak tujuan).
	Kepada string
	// NamaTujuan — nama tampil tujuan; nil = tanpa nama.
	NamaTujuan *string
	// Subjek email (bucket 200 — core_mail_log.subjek).
	Subjek string
	// Jenis — kode keperluan kirim, tercatat core_mail_log.jenis (mis. AKTIVASI_MEMBER).
	Jenis string
	// HTML — body HTML lengkap (bangun via KemasHtmlEmail).
	HTML string
	// Teks — body teks polos; nil = diturunkan dari paragraf template.
	Teks *string
	// IDCoreUsers — user CORE pemilik kiriman; nil = penerima tanpa akun.
	IDCoreUsers *int64
}

// MailStatus — mirror enum_status_mail (ddl/81: TERKIRIM | GAGAL | NONAKTIF).
type MailStatus string

const (
	MailStatusTerkirim MailStatus = "TERKIRIM"
	MailStatusGagal    MailStatus = "GAGAL"
	MailStatusNonaktif MailStatus = "NONAKTIF"
)

// MailResult — hasil Kirim; tidak pernah throw, pemanggil baca status.
type MailResult struct {
	Terkirim  bool
	Status    MailStatus
	MessageID *string // message-id vendor SMTP — hanya bila TERKIRIM
	Error     *string // ringkasan error (potong 300) — hanya bila GAGAL
}
