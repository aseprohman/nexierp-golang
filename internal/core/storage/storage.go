// Package storage — padanan kernel NestJS core/storage: object storage
// S3/MinIO (aws-sdk-go-v2) + media library (registry core_files,
// core_media_categories, ddl/01c+44/44).
//
// ATURAN STORAGE (direktif pemilik): fisik file HANYA di S3/MinIO (bucket
// `nexierp`) — tidak ada file yang ditulis ke folder lokal; pembacaan lewat
// presigned URL atau streaming same-origin.
package storage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"

	"nexierp/internal/core/config"
)

// SIGNED_URL_EXPIRES_SECONDS — detik default masa berlaku presigned GET (1 jam).
const SIGNED_URL_EXPIRES_SECONDS = 3600

// Service — kernel object storage. DUA klien: `s3` (endpoint internal
// jaringan backend — put/get/delete) dan `signer` (endpoint terjangkau
// browser — presigned URL; signature mengikat host, jadi klien terpisah,
// bukan string-replace).
type Service struct {
	s3     *s3.Client
	signer *s3.Client
	bucket string
}

// Opts — opsi presigned GET.
type Opts struct {
	ExpiresInSeconds int    // 0 → SIGNED_URL_EXPIRES_SECONDS
	Inline           bool   // true → response-content-disposition inline (render di browser)
	FileName         string // nama file unduhan (kutip ganda dibuang — persis NestJS)
}

// New — bangun service: dua klien S3 (region "us-east-1", forcePathStyle
// wajib untuk MinIO). Bucket default "nexierp" (fallback persis NestJS).
func New(cfg *config.Env) (*Service, error) {
	endpoint := cfg.MinioEndpoint
	bucket := cfg.MinioBucket
	if bucket == "" {
		bucket = "nexierp"
	}
	creds := credentials.NewStaticCredentialsProvider(cfg.MinioAccessKey, cfg.MinioSecretKey, "")

	internal := s3.NewFromConfig(aws.Config{
		Region:       "us-east-1",
		Credentials:  creds,
		BaseEndpoint: aws.String(NormalizeEndpoint(endpoint)),
	}, func(o *s3.Options) { o.UsePathStyle = true })

	// Presigned URL dibuka BROWSER — host harus terjangkau dari luar
	// (MINIO_PUBLIC_ENDPOINT, mis. http://localhost:19000).
	publik := cfg.MinioPublicEndpoint
	if publik == "" {
		publik = endpoint
	}
	signer := s3.NewFromConfig(aws.Config{
		Region:       "us-east-1",
		Credentials:  creds,
		BaseEndpoint: aws.String(NormalizeEndpoint(publik)),
	}, func(o *s3.Options) { o.UsePathStyle = true })

	return &Service{s3: internal, signer: signer, bucket: bucket}, nil
}

// NormalizeEndpoint — normalisasi endpoint MinIO (port persis NestJS):
//   - tanpa skema → `http://` (MinIO dev tanpa TLS);
//   - http tanpa port → :9000; https tanpa port TETAP (port default 443
//     implisit — presigned URL ikut `$host` vhost deploy);
//   - kosong → http://nexierp-minio:9000.
func NormalizeEndpoint(raw string) string {
	ep := strings.TrimSpace(raw)
	if ep == "" {
		ep = "http://nexierp-minio:9000"
	}
	if !strings.HasPrefix(ep, "http://") && !strings.HasPrefix(ep, "https://") {
		ep = "http://" + ep
	}
	u, err := url.Parse(ep)
	if err != nil {
		return ep // input tak terurai — kembalikan apa adanya (tanpa panic)
	}
	if u.Port() == "" && u.Scheme == "http" {
		u.Host = u.Hostname() + ":9000"
	}
	return strings.TrimSuffix(u.String(), "/")
}

// Put — simpan objek; kembalikan object key yang dipakai.
func (s *Service) Put(ctx context.Context, objectKey string, body []byte, contentType string) (string, error) {
	_, err := s.s3.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.bucket),
		Key:         aws.String(objectKey),
		Body:        bytes.NewReader(body),
		ContentType: aws.String(contentType),
	})
	if err != nil {
		return "", fmt.Errorf("gagal simpan object %s: %w", objectKey, err)
	}
	return objectKey, nil
}

// SignedGetURL — presigned URL GET: `Inline` untuk preview di browser
// (iframe/img/player, PDF/video render), default attachment (unduh dengan
// nama file aslinya). Signature dibangun klien `signer` (host publik).
func (s *Service) SignedGetURL(ctx context.Context, objectKey string, opts Opts) (string, error) {
	expires := opts.ExpiresInSeconds
	if expires <= 0 {
		expires = SIGNED_URL_EXPIRES_SECONDS
	}
	input := &s3.GetObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(objectKey),
	}
	nama := strings.ReplaceAll(opts.FileName, `"`, "")
	switch {
	case opts.Inline:
		cd := "inline"
		if opts.FileName != "" {
			cd = fmt.Sprintf(`inline; filename="%s"`, nama)
		}
		input.ResponseContentDisposition = aws.String(cd)
	case opts.FileName != "":
		input.ResponseContentDisposition = aws.String(fmt.Sprintf(`attachment; filename="%s"`, nama))
	}
	res, err := s3.NewPresignClient(s.signer).PresignGetObject(ctx, input, func(o *s3.PresignOptions) {
		o.Expires = time.Duration(expires) * time.Second
	})
	if err != nil {
		return "", fmt.Errorf("gagal presign object %s: %w", objectKey, err)
	}
	return res.URL, nil
}

// Remove — hapus objek (idempoten: object tak ada dianggap sukses —
// semantik S3 DeleteObject 204).
func (s *Service) Remove(ctx context.Context, objectKey string) error {
	_, err := s.s3.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(objectKey),
	})
	if err != nil {
		var ae smithy.APIError
		if errors.As(err, &ae) && (ae.ErrorCode() == "NoSuchKey" || ae.ErrorCode() == "NotFound") {
			return nil
		}
		return fmt.Errorf("gagal hapus object %s: %w", objectKey, err)
	}
	return nil
}

// GetObjectInfo — info object untuk STREAMING same-origin (endpoint
// /system/files/:id/raw atau pengiriman vendor): GetObject pada klien
// INTERNAL (jaringan backend → MinIO), TANPA presigned URL/domain publik.
func (s *Service) GetObjectInfo(ctx context.Context, objectKey string) (io.ReadCloser, string, *int64, error) {
	res, err := s.s3.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(objectKey),
	})
	if err != nil {
		return nil, "", nil, fmt.Errorf("gagal buka object %s: %w", objectKey, err)
	}
	ct := "application/octet-stream"
	if res.ContentType != nil && *res.ContentType != "" {
		ct = *res.ContentType
	}
	return res.Body, ct, res.ContentLength, nil
}

// BucketName — nama bucket registry (disimpan ke core_files.bucket).
func (s *Service) BucketName() string { return s.bucket }

// PastikanBucket — pastikan bucket ada; buat bila belum (idempoten;
// race antar instance — bucket dibuat proses lain dianggap sukses).
// Dipanggil wiring bootstrap (padanan onModuleInit NestJS).
func (s *Service) PastikanBucket(ctx context.Context) error {
	_, err := s.s3.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(s.bucket)})
	if err == nil {
		return nil
	}
	_, err = s.s3.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(s.bucket)})
	if err == nil {
		return nil
	}
	var ae smithy.APIError
	if errors.As(err, &ae) && (ae.ErrorCode() == "BucketAlreadyOwnedByYou" || ae.ErrorCode() == "BucketAlreadyExists") {
		return nil
	}
	return fmt.Errorf("gagal pastikan bucket %s: %w", s.bucket, err)
}
