// Unit test murni NormalizeEndpoint (padanan StorageService.normalizeEndpoint).
package storage

import "testing"

func TestNormalizeEndpoint(t *testing.T) {
	kasus := []struct {
		nama string
		raw  string
		mau  string
	}{
		{"kosong → fallback compose", "", "http://nexierp-minio:9000"},
		{"tanpa skema → http + port 9000", "nexierp-minio", "http://nexierp-minio:9000"},
		{"host:port tanpa skema", "localhost:19000", "http://localhost:19000"},
		{"http dengan port dipertahankan", "http://localhost:19000", "http://localhost:19000"},
		{"http tanpa port → :9000", "http://minio.example.com", "http://minio.example.com:9000"},
		{"https tanpa port tetap", "https://minio.example.com", "https://minio.example.com"},
		{"https dengan port tetap", "https://minio.example.com:8443", "https://minio.example.com:8443"},
		{"trailing slash dibuang", "http://minio.example.com/", "http://minio.example.com:9000"},
		{"spasi di-trim", "  nexierp-minio  ", "http://nexierp-minio:9000"},
	}
	for _, k := range kasus {
		t.Run(k.nama, func(t *testing.T) {
			if got := NormalizeEndpoint(k.raw); got != k.mau {
				t.Fatalf("NormalizeEndpoint(%q) = %q, mau %q", k.raw, got, k.mau)
			}
		})
	}
}
