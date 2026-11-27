// security_environment.go — service ENVIRONMENT (padanan
// services/security/environment.service.ts): port fetchEnvironment,
// saveEnvironmentCategory, updateCompanyLogo, testSmtp.
//   - Kategori konfigurasi = baris core_app_settings (fields jsonb) —
//     pengurutan kategori kanonik + merge key dilakukan di sini (murni).
//   - Logo perusahaan = core_meta.id="company_logo" (upsert).
//   - testSmtp = verifikasi koneksi+autentikasi SMTP NYATA (net/smtp —
//     BUKAN pengiriman email); kegagalan koneksi → {ok:false} HTTP 200.
package service

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/smtp"
	"sort"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// EnvironmentService — kernel fitur environment.
type EnvironmentService struct {
	db    *database.DB
	audit *audit.Service
	repo  *repository.EnvironmentRepository
}

// NewEnvironmentService membuat service environment.
func NewEnvironmentService(db *database.DB, auditSvc *audit.Service) *EnvironmentService {
	return &EnvironmentService{db: db, audit: auditSvc, repo: repository.NewEnvironmentRepository()}
}

// GetEnvironment — seluruh kategori terurut kanonik (company, smtp, app,
// storage) + logo perusahaan (default `{logoName:"", logoDataUrl:null}`).
// Fields = payload jsonb apa adanya (field rusak lolos — jangan buang data).
func (s *EnvironmentService) GetEnvironment(ctx context.Context) (types.EnvironmentConfig, error) {
	rows, err := s.repo.ListKategori(ctx, s.db.Pool)
	if err != nil {
		return types.EnvironmentConfig{}, err
	}
	rank := map[string]int{}
	for i, c := range types.EnvCategoryOrder {
		rank[c] = i
	}
	sorted := append([]types.EnvCategoryData(nil), rows...)
	sort.SliceStable(sorted, func(i, j int) bool {
		return rankOrDefault(sorted[i].Category, rank) < rankOrDefault(sorted[j].Category, rank)
	})
	logo, err := s.GetCompanyLogo(ctx)
	if err != nil {
		return types.EnvironmentConfig{}, err
	}
	return types.EnvironmentConfig{Categories: sorted, Logo: logo}, nil
}

func rankOrDefault(category string, rank map[string]int) int {
	if r, ok := rank[category]; ok {
		return r
	}
	return 99
}

// GetCompanyLogo — baca core_meta dengan fallback default; payload jsonb
// dibaca longgar (logoName harus string; logoDataUrl diteruskan apa adanya
// ?? null).
func (s *EnvironmentService) GetCompanyLogo(ctx context.Context) (types.CompanyLogo, error) {
	row, err := s.repo.MuatMeta(ctx, s.db.Pool, types.CompanyLogoMetaKey)
	if err != nil {
		return types.CompanyLogo{}, err
	}
	if row != nil {
		var value map[string]any
		if json.Unmarshal(row.Value, &value) == nil {
			if name, ok := value["logoName"].(string); ok {
				var dataURL any
				if v, ada := value["logoDataUrl"]; ada && v != nil {
					dataURL = v
				}
				return types.CompanyLogo{LogoName: name, LogoDataUrl: dataURL}, nil
			}
		}
	}
	return types.CompanyLogo{LogoName: "", LogoDataUrl: nil}, nil
}

// SaveEnvironmentCategory — kategori tidak ada → 404 SYS-404; hanya key
// yang dikenal kategori yang berubah; tidak ada perubahan → selesai TANPA
// audit; ada perubahan → update fields + audit before/after warning (SATU
// tx).
func (s *EnvironmentService) SaveEnvironmentCategory(ctx context.Context, input types.SaveEnvironmentCategoryInput, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		cat, err := s.repo.MuatKategori(ctx, tx, input.Category)
		if err != nil {
			return err
		}
		if cat == nil {
			return errkontrak.NotFound("Kategori konfigurasi tidak ditemukan.", "SYS-404")
		}

		var fields []json.RawMessage
		if len(cat.Fields) > 0 {
			if err := json.Unmarshal(cat.Fields, &fields); err != nil {
				return errkontrak.Internal("Terjadi kesalahan internal pada server.", "SYS-001")
			}
		}
		before := map[string]any{}
		out := make([]json.RawMessage, 0, len(fields))
		for _, raw := range fields {
			var f map[string]any
			if err := json.Unmarshal(raw, &f); err != nil || f == nil {
				// Field bukan object → lolos apa adanya (normalisasi passthrough).
				out = append(out, raw)
				continue
			}
			if key, ok := f["key"].(string); ok {
				if newValue, ada := input.Values[key]; ada {
					oldValue := f["value"]
					if !samaNilai(oldValue, newValue) {
						before[key] = oldValue
						f["value"] = newValue
						merged, err := json.Marshal(f)
						if err != nil {
							return errkontrak.Internal("Terjadi kesalahan internal pada server.", "SYS-001")
						}
						out = append(out, merged)
						continue
					}
				}
			}
			out = append(out, raw)
		}
		if len(before) == 0 {
			return nil // NO CHANGE → tanpa update, tanpa audit (port mock).
		}

		payload, err := json.Marshal(out)
		if err != nil {
			return errkontrak.Internal("Terjadi kesalahan internal pada server.", "SYS-001")
		}
		if err := s.repo.UpdateFieldsKategori(ctx, tx, input.Category, payload); err != nil {
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "app_setting",
				EntityID:    input.Category,
				Action:      "update",
				BeforeValue: before,
				AfterValue:  audit.Snapshot(input.Values),
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

// truthy — Boolean(value) JS: null/""/false/0 → false; selain itu true.
func truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case string:
		return t != ""
	case bool:
		return t
	case float64:
		return t != 0
	}
	return true
}

// samaNilai — perbandingan ketat JS `!==` untuk nilai JSON (string/bool/
// number bertipe sama saja yang dianggap sama; null === null → sama).
func samaNilai(a, b any) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	av, aStr := a.(string)
	bv, bStr := b.(string)
	if aStr || bStr {
		return aStr && bStr && av == bv
	}
	ab, aBool := a.(bool)
	bb, bBool := b.(bool)
	if aBool || bBool {
		return aBool && bBool && ab == bb
	}
	af, aNum := a.(float64)
	bf, bNum := b.(float64)
	if aNum || bNum {
		return aNum && bNum && af == bf
	}
	return false
}

// UpdateCompanyLogo — upsert core_meta + audit info (entityId company/logo).
func (s *EnvironmentService) UpdateCompanyLogo(ctx context.Context, logo types.CompanyLogo, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		payload, err := json.Marshal(logo)
		if err != nil {
			return errkontrak.Internal("Terjadi kesalahan internal pada server.", "SYS-001")
		}
		if err := s.repo.UpsertMeta(ctx, tx, types.CompanyLogoMetaKey, payload); err != nil {
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "app_setting",
				EntityID:   "company/logo",
				Action:     "update",
				AfterValue: audit.Snapshot{
					"logo_name": logo.LogoName,
					"has_logo":  truthy(logo.LogoDataUrl), // Boolean(value) JS
				},
				// Severity kosong → info (fallback service audit).
			},
			Actor: actor,
		}})
		return err
	})
}

// TestSmtp — konfigurasi belum lengkap → {ok:false} TANPA audit; lengkap →
// verifikasi koneksi SMTP nyata, hasil (sukses/gagal) diaudit sebagai
// smtp_test. TIDAK pernah melempar 500: kegagalan koneksi adalah hasil uji,
// bukan error server.
func (s *EnvironmentService) TestSmtp(ctx context.Context, actor audit.Actor) (types.SmtpTestResult, error) {
	cat, err := s.repo.MuatKategori(ctx, s.db.Pool, "smtp")
	if err != nil {
		return types.SmtpTestResult{}, err
	}
	valueOf := func(key string) string {
		var fields []json.RawMessage
		if cat == nil || len(cat.Fields) == 0 {
			return ""
		}
		if json.Unmarshal(cat.Fields, &fields) != nil {
			return ""
		}
		for _, raw := range fields {
			var f map[string]any
			if json.Unmarshal(raw, &f) != nil || f == nil {
				continue
			}
			if k, ok := f["key"].(string); !ok || k != key {
				continue
			}
			switch v := f["value"].(type) {
			case string:
				return v
			case float64:
				return strconv.FormatFloat(v, 'g', -1, 64) // String(number) JS
			}
			return ""
		}
		return ""
	}

	host := valueOf("smtp_host")
	sender := valueOf("smtp_sender_email")
	if host == "" || sender == "" {
		return types.SmtpTestResult{
			OK:      false,
			Message: "SMTP host & email pengirim wajib diisi sebelum mengirim email uji.",
		}, nil
	}

	// Number(valueOf("smtp_port")) || 587 — 0/NaN → default (falsy JS).
	port := 587
	if p, err := strconv.Atoi(valueOf("smtp_port")); err == nil && p != 0 {
		port = p
	}
	encryption := valueOf("smtp_encryption")
	if encryption == "" {
		encryption = "starttls"
	}
	result := verifySmtp(host, port, encryption, valueOf("smtp_username"), valueOf("smtp_password"))

	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		_, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "app_setting",
				EntityID:   "smtp",
				Action:     "smtp_test",
				AfterValue: audit.Snapshot{"host": host, "sender": sender, "ok": result.OK},
				// Severity kosong → info.
			},
			Actor: actor,
		}})
		return err
	})
	if err != nil {
		return types.SmtpTestResult{}, err
	}
	return result, nil
}

// ---------------------------------------------------------------------
// Verifikasi SMTP nyata (padanan verifySmtp + transport.verify nodemailer)
// ---------------------------------------------------------------------

// smtpPlainAuth — AUTH PLAIN tanpa syarat TLS (nodemailer tetap mengirim
// AUTH pada koneksi plaintext bila dikonfigurasi; stdlib smtp.PlainAuth
// menolaknya).
type smtpPlainAuth struct {
	username, password string
}

func (a smtpPlainAuth) Start(*smtp.ServerInfo) (string, []byte, error) {
	return "PLAIN", []byte("\x00" + a.username + "\x00" + a.password), nil
}

func (a smtpPlainAuth) Next(fromServer []byte, more bool) ([]byte, error) {
	if more {
		return nil, errors.New("server mengirim challenge tak diharapkan")
	}
	return nil, nil
}

// verifySmtp — koneksi + EHLO (+STARTTLS) + AUTH opsional — verify() saja,
// BUKAN pengiriman email. Timeout pendek agar tombol uji tidak menggantung
// (dial 10s; keseluruhan sesi 15s). Error apa pun → {ok:false}.
func verifySmtp(host string, port int, encryption, user, pass string) types.SmtpTestResult {
	gagal := func(err error) types.SmtpTestResult {
		return types.SmtpTestResult{OK: false, Message: "Koneksi SMTP gagal: " + err.Error()}
	}

	addr := net.JoinHostPort(host, strconv.Itoa(port)) // aman untuk IPv6
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var conn net.Conn
	var err error
	if encryption == "ssl" {
		// secure: true — TLS implisit sejak koneksi dibuka.
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{ServerName: host})
	} else {
		conn, err = dialer.Dial("tcp", addr)
	}
	if err != nil {
		return gagal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(15 * time.Second)) // socketTimeout

	client, err := smtp.NewClient(conn, host)
	if err != nil {
		return gagal(err)
	}
	defer client.Close()

	if encryption == "starttls" {
		// requireTLS: STARTTLS wajib sebelum lanjut.
		if err := client.StartTLS(&tls.Config{ServerName: host}); err != nil {
			return gagal(err)
		}
	}
	if user != "" {
		if err := client.Auth(smtpPlainAuth{username: user, password: pass}); err != nil {
			return gagal(err)
		}
	}
	_ = client.Quit()
	return types.SmtpTestResult{
		OK:      true,
		Message: fmt.Sprintf("Koneksi SMTP %s:%d berhasil diverifikasi.", host, port),
	}
}
