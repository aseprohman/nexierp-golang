// MailerService — kernel pengiriman email SMTP (padanan services/
// mailer.service.ts NestJS; ddl/81 core_mail_log).
//
// Kontrak:
//   - Kirim TIDAK PERNAH throw/panic — hasil status (TERKIRIM/GAGAL/NONAKTIF)
//     dibaca pemanggil; kegagalan SMTP tidak boleh membalikkan transaksi
//     bisnis pemanggil (email = efek samping pasca-commit).
//   - Setiap panggilan tercatat SATU baris core_mail_log (append-only);
//     kegagalan penulisan log TIDAK menggagalkan hasil.
//   - MailHost kosong = layanan NONAKTIF: panggilan tetap sukses
//     (status NONAKTIF) — mode dev tanpa SMTP tetap boot.
//   - Transport go-mail lazy — dibangun saat kirim pertama.
package mailer

import (
	"context"
	"crypto/tls"
	"log/slog"
	"sync"

	"github.com/wneessen/go-mail"

	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/mailer/repository"
	"nexierp/internal/core/mailer/repository/gen"
)

// Service — padanan MailerService NestJS.
type Service struct {
	cfg *config.Env
	db  *database.DB // dipasang via SetDB — penulisan core_mail_log (pool, non-tx)

	mu     sync.Mutex
	client *mail.Client // transport lazy — nil = belum pernah kirim
}

// New — bangun service (transport LAZY; DB dipasang terpisah via SetDB).
func New(cfg *config.Env) *Service {
	return &Service{cfg: cfg}
}

// SetDB — pasang pool DB untuk penulisan core_mail_log (wiring bootstrap).
func (s *Service) SetDB(db *database.DB) { s.db = db }

// Aktif — layanan email aktif (MailHost terisi)?
func (s *Service) Aktif() bool { return s.cfg.MailHost != "" }

// PengirimDefault — pengirim default (header From); fallback MAIL_USERNAME.
// Format persis NestJS: `"Nama" <alamat>` (tanpa escaping kutip nama).
func (s *Service) PengirimDefault() string {
	alamat := s.cfg.MailFromAddress
	if alamat == "" {
		alamat = s.cfg.MailUsername
	}
	if alamat == "" {
		return ""
	}
	if s.cfg.MailFromName != "" {
		return `"` + s.cfg.MailFromName + `" <` + alamat + `>`
	}
	return alamat
}

// Kirim — kirim satu email; selalu selesai dengan MailResult (tanpa throw).
// Keputusan bisnis atas hasil (mis. registrasi tetap sukses walau email
// gagal + tawarkan kirim-ulang) milik pemanggil.
func (s *Service) Kirim(ctx context.Context, p MailPayload) MailResult {
	if !s.Aktif() {
		s.catat(ctx, p, MailStatusNonaktif, "", "")
		return MailResult{Status: MailStatusNonaktif}
	}

	from := s.PengirimDefault()
	if from == "" {
		const pesan = "MAIL_FROM_ADDRESS/MAIL_USERNAME kosong — pengirim tak diketahui."
		s.catat(ctx, p, MailStatusGagal, pesan, "")
		return MailResult{Status: MailStatusGagal, Error: ptr(pesan)}
	}

	msg, err := s.bangunPesan(from, p)
	if err == nil {
		var cl *mail.Client
		cl, err = s.transport()
		if err == nil {
			err = cl.DialAndSendWithContext(ctx, msg)
		}
	}
	if err != nil {
		pesan := potong300(err.Error())
		slog.Warn("Kirim email ke "+p.Kepada+" gagal: "+pesan, "komponen", "mailer", "jenis", p.Jenis)
		s.catat(ctx, p, MailStatusGagal, pesan, "")
		return MailResult{Status: MailStatusGagal, Error: ptr(pesan)}
	}

	messageID := msg.GetMessageID()
	s.catat(ctx, p, MailStatusTerkirim, "", messageID)
	res := MailResult{Terkirim: true, Status: MailStatusTerkirim}
	if messageID != "" {
		res.MessageID = ptr(messageID)
	}
	return res
}

// ListByPenerima — riwayat kirim terbaru per alamat penerima (observabilitas).
func (s *Service) ListByPenerima(ctx context.Context, exec repository.DBTX, penerima string, limit int) ([]gen.CoreMailLog, error) {
	return repository.NewMailLogRepository().ListByPenerima(ctx, exec, penerima, int32(limit))
}

// Tutup — buang transport terbangun (padanan onModuleDestroy; koneksi
// go-mail tidak pernah persist — reset memaksa bangun-ulang di kirim berikut).
func (s *Service) Tutup() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.client = nil
}

/* -------------------------------------------------------------- */
/* Internal                                                        */
/* -------------------------------------------------------------- */

// bangunPesan — rakit pesan MIME (from/to/subject/html+text) persis NestJS.
func (s *Service) bangunPesan(from string, p MailPayload) (*mail.Msg, error) {
	msg := mail.NewMsg()

	if err := msg.From(from); err != nil {
		return nil, err
	}
	// penerima: `"Nama" <alamat>` bila nama tampil ada — persis NestJS.
	tujuan := p.Kepada
	if p.NamaTujuan != nil && *p.NamaTujuan != "" {
		tujuan = `"` + *p.NamaTujuan + `" <` + p.Kepada + `>`
	}
	if err := msg.To(tujuan); err != nil {
		return nil, err
	}
	msg.Subject(p.Subjek)
	msg.SetBodyString(mail.TypeTextHTML, p.HTML)
	if p.Teks != nil {
		msg.AddAlternativeString(mail.TypeTextPlain, *p.Teks)
	}
	return msg, nil
}

// transport — transport SMTP lazy: ssl/465 = implicit TLS; tls = STARTTLS
// wajib; none = STARTTLS opportunistic tanpa verifikasi sertifikat
// (InsecureSkipVerify — padanan rejectUnauthorized:false); tanpa setting =
// opportunistic (default nodemailer).
func (s *Service) transport() (*mail.Client, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client != nil {
		return s.client, nil
	}

	c := s.cfg
	opts := []mail.Option{mail.WithPort(c.MailPort)}
	switch {
	case c.MailEncryption == "ssl" || c.MailPort == 465:
		opts = append(opts, mail.WithSSL())
	case c.MailEncryption == "tls":
		opts = append(opts, mail.WithTLSPolicy(mail.TLSMandatory))
	case c.MailEncryption == "none":
		opts = append(opts, mail.WithTLSPolicy(mail.TLSOpportunistic),
			mail.WithTLSConfig(&tls.Config{InsecureSkipVerify: true})) // nolint:gosec // padanan rejectUnauthorized:false (catcher dev)
	default:
		opts = append(opts, mail.WithTLSPolicy(mail.TLSOpportunistic))
	}
	if c.MailUsername != "" && c.MailPassword != "" {
		opts = append(opts,
			mail.WithSMTPAuth(mail.SMTPAuthPlain),
			mail.WithUsername(c.MailUsername),
			mail.WithPassword(c.MailPassword),
		)
	}

	cl, err := mail.NewClient(c.MailHost, opts...)
	if err != nil {
		return nil, err
	}
	s.client = cl
	return cl, nil
}

// catat — tulis SATU baris core_mail_log via pool (non-tx, append-only);
// kegagalan penulisan log tak dilempar — hanya peringatan.
func (s *Service) catat(ctx context.Context, p MailPayload, status MailStatus, pesanError, providerMessageID string) {
	if s.db == nil {
		slog.Warn("Gagal menulis core_mail_log ("+p.Jenis+" → "+p.Kepada+"): DB belum dipasang (SetDB)",
			"komponen", "mailer")
		return
	}
	var (
		pesanErr *string
		provider *string
	)
	if pesanError != "" {
		pesanErr = ptr(pesanError)
	}
	if providerMessageID != "" {
		provider = ptr(providerMessageID)
	}
	_, err := repository.NewMailLogRepository().Insert(ctx, s.db.Pool, repository.MailLogInsert{
		EntityID:          uuidV4(),
		IDCoreUsers:       p.IDCoreUsers,
		Penerima:          p.Kepada,
		PenerimaNama:      p.NamaTujuan,
		Subjek:            p.Subjek,
		Jenis:             p.Jenis,
		Status:            statusGen(status),
		PesanError:        pesanErr,
		ProviderMessageID: provider,
	})
	if err != nil {
		slog.Warn("Gagal menulis core_mail_log ("+p.Jenis+" → "+p.Kepada+"): "+err.Error(),
			"komponen", "mailer")
	}
}

// statusGen — map status service → enum sqlc hasil generate.
func statusGen(s MailStatus) gen.EnumStatusMail {
	switch s {
	case MailStatusTerkirim:
		return gen.EnumStatusMailTERKIRIM
	case MailStatusGagal:
		return gen.EnumStatusMailGAGAL
	default:
		return gen.EnumStatusMailNONAKTIF
	}
}

// ptr — helper pointer string.
func ptr(s string) *string { return &s }

// potong300 — bucket 300 varchar(300) core_mail_log.pesan_error; aman rune
// (ellipsis "…" satu rune seperti verbatim NestJS).
func potong300(v string) string {
	r := []rune(v)
	if len(r) <= 300 {
		return v
	}
	return string(r[:297]) + "…"
}
