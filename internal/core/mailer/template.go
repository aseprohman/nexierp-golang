// Template HTML email generik — padanan shared/mail-template.ts: layout
// brand inline-style (klien email tidak mendukung CSS eksternal) + pasangan
// teks polos. MURNI presentasi: konten (judul/paragraf/tombol) dari pemanggil.
package mailer

import "strings"

// KemasHtmlEmailInput — input builder (padanan KemasHtmlEmailInput).
type KemasHtmlEmailInput struct {
	// Judul di kepala kartu (mis. "Aktivasi Akun Member").
	Judul string
	// Sapaan pembuka (mis. "Halo Budi,"); kosong = langsung paragraf.
	Sapaan string
	// Paragraf isi (urutan dipertahankan).
	Paragraf []string
	// Tombol aksi utama (mis. link aktivasi); nil = tanpa tombol.
	Tombol *TombolEmail
	// Paragraf penutup (mis. catatan kedaluwarsa).
	Penutup []string
}

// TombolEmail — tombol aksi utama email.
type TombolEmail struct {
	Label string
	URL   string
}

// Hasil — pasangan {html, teks} untuk satu email.
type Hasil struct {
	HTML string
	Teks string
}

// KemasHtmlEmail — bangun pasangan {html, teks}; struktur tag + teks sama
// dengan kemasHtmlEmail NestJS (indentasi baris paragraf 12 spasi).
func KemasHtmlEmail(in KemasHtmlEmailInput) Hasil {
	var h strings.Builder

	h.WriteString(`<!DOCTYPE html>
<html lang="id">
<body style="margin:0;padding:24px;background:#f1f5f9;font-family:Arial,Helvetica,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
             style="max-width:520px;background:#ffffff;border-radius:16px;overflow:hidden;border:1px solid #e2e8f0">
        <tr>
          <td style="background:#0f172a;padding:20px 32px">
            <span style="font-size:18px;font-weight:800;letter-spacing:1px;color:#ffffff">NEXIERP</span>
          </td>
        </tr>
        <tr>
          <td style="padding:32px">
            <h1 style="margin:0 0 16px;font-size:20px;color:#0f172a">`)
	h.WriteString(in.Judul)
	h.WriteString(`</h1>
`)
	// Baris sapaan/paragraf/tombol/penutup mengikuti literal TS: placeholder
	// kosong tetap meninggalkan satu baris indentasi (byte-for-byte).
	h.WriteString(`            `)
	if in.Sapaan != "" {
		h.WriteString(`<p style="margin:0 0 12px;font-size:14px;font-weight:700;color:#0f172a">`)
		h.WriteString(in.Sapaan)
		h.WriteString(`</p>`)
	}
	h.WriteString("\n            ")
	h.WriteString(strings.Join(petaParagraf(in.Paragraf), "\n            "))
	h.WriteString("\n            ")
	if in.Tombol != nil {
		h.WriteString(`<p style="margin:24px 0">
              <a href="`)
		h.WriteString(in.Tombol.URL)
		h.WriteString(`"
                 style="display:inline-block;background:#4f46e5;color:#ffffff;text-decoration:none;
                        font-size:14px;font-weight:700;padding:12px 28px;border-radius:10px">
                `)
		h.WriteString(in.Tombol.Label)
		h.WriteString(`
              </a>
            </p>
            <p style="margin:0 0 12px;font-size:12px;line-height:1.6;color:#64748b;word-break:break-all">
              Bila tombol tidak berfungsi, salin tautan berikut ke peramban:<br/>
              `)
		h.WriteString(in.Tombol.URL)
		h.WriteString(`
            </p>`)
	}
	h.WriteString("\n            ")
	h.WriteString(strings.Join(petaParagraf(in.Penutup), "\n            "))
	h.WriteString(`
          </td>
        </tr>
        <tr>
          <td style="background:#f8fafc;padding:16px 32px;border-top:1px solid #e2e8f0">
            <p style="margin:0;font-size:11px;color:#94a3b8">
              Email otomatis dari NEXIERP — jangan balas email ini.
            </p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`)

	// Teks polos — susunan baris persis padanan TS.
	var t []string
	t = append(t, "NEXIERP", "", in.Judul)
	if in.Sapaan != "" {
		t = append(t, "", in.Sapaan)
	}
	t = append(t, "")
	t = append(t, in.Paragraf...)
	if in.Tombol != nil {
		t = append(t, "", in.Tombol.Label+":", in.Tombol.URL)
	}
	if len(in.Penutup) > 0 {
		t = append(t, "")
		t = append(t, in.Penutup...)
	}

	return Hasil{HTML: h.String(), Teks: strings.Join(t, "\n")}
}

// petaParagraf — bungkus tiap paragraf dengan <p> inline-style (padanan baris()).
func petaParagraf(paragraf []string) []string {
	out := make([]string, 0, len(paragraf))
	for _, p := range paragraf {
		out = append(out, `<p style="margin:0 0 12px;font-size:14px;line-height:1.6;color:#334155">`+p+`</p>`)
	}
	return out
}
