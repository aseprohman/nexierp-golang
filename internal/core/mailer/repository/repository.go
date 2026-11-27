// Package repository — SATU-SATUNYA pengguna schema core_mail_log (ddl/81)
// di area mailer: menulis baris jejak kirim + membaca riwayat per penerima.
// Executor diteruskan dari pemanggil (pool untuk log kirim, tx bila pemanggil
// mau jejak dalam transaksinya) — pola persis MailLogRepository NestJS.
package repository

import (
	"context"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/mailer/repository/gen"
)

// DBTX — alias executor sqlc (pool pgx maupun pgx.Tx keduanya memenuhi).
type DBTX = gen.DBTX

// MailLogRepository — padanan MailLogRepository NestJS (append-only).
type MailLogRepository struct{}

// NewMailLogRepository — repo tanpa state.
func NewMailLogRepository() *MailLogRepository { return &MailLogRepository{} }

// MailLogInsert — nilai INSERT core_mail_log (dibangun service, dieksekusi repo).
type MailLogInsert struct {
	EntityID          string
	IDCoreUsers       *int64
	Penerima          string
	PenerimaNama      *string
	Subjek            string
	Jenis             string
	Status            gen.EnumStatusMail
	PesanError        *string
	ProviderMessageID *string
}

// Insert — tulis satu baris jejak kirim (sukses maupun gagal/nonaktif).
func (r *MailLogRepository) Insert(ctx context.Context, exec DBTX, v MailLogInsert) (gen.CoreMailLog, error) {
	arg := gen.InsertMailLogParams{
		EntityID:          uuidParam(v.EntityID),
		IDCoreUsers:       int8Nullable(v.IDCoreUsers),
		Penerima:          v.Penerima,
		PenerimaNama:      textNullable(v.PenerimaNama),
		Subjek:            v.Subjek,
		Jenis:             v.Jenis,
		Status:            v.Status,
		PesanError:        textNullable(v.PesanError),
		ProviderMessageID: textNullable(v.ProviderMessageID),
	}
	return gen.New(exec).InsertMailLog(ctx, arg)
}

// ListByPenerima — riwayat kirim terbaru per alamat penerima.
func (r *MailLogRepository) ListByPenerima(ctx context.Context, exec DBTX, penerima string, limit int32) ([]gen.CoreMailLog, error) {
	if limit <= 0 {
		limit = 20 // padanan default limit NestJS
	}
	return gen.New(exec).ListMailLogByPenerima(ctx, gen.ListMailLogByPenerimaParams{
		Penerima: penerima,
		Limit:    limit,
	})
}

/* ---------- helper pgtype (kolom nullable / uuid) ------------------------- */

func uuidParam(s string) pgtype.UUID {
	var u pgtype.UUID
	_ = u.Scan(s) // parse teks UUID; gagal = invalid (kolom uuid menolak)
	return u
}

func textNullable(s *string) pgtype.Text {
	if s == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *s, Valid: true}
}

func int8Nullable(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}
