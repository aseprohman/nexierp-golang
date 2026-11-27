-- +goose Up
-- =====================================================================================
-- MIGRASI REKONSILIASI: 108_rekonsiliasi_enum-live.sql
-- APA    : 561 enum type live-only (yatim — tidak dipakai kolom live mana pun) dibuat persis kosakata live
-- KENAPA : bentuk live DB dev = acuan kerja backend Go; objek ini ada di live
--          (baseline deploy/Drizzle) tetapi belum ada di schema segar hasil porting.
-- SUMBER : fakta pg_dump live dev 127.0.0.1:15433 -> /tmp/live-schema.sql
--          dan diff sistematis /tmp/delta-fresh-vs-live.txt
-- IDEMPOTEN: DO $$ dengan penangkap duplicate_object
-- CATATAN: tipe yatim dibuat demi paritas penuh enum live vs segar; sqlc tidak terpengaruh
-- =====================================================================================


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_account_type AS ENUM ('asset', 'liability', 'equity', 'revenue', 'expense');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_anomaly_status AS ENUM ('new', 'reviewed', 'confirmed', 'dismissed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_anomaly_type AS ENUM ('duplicate_invoice', 'unusual_pattern', 'weekend_posting', 'round_amount');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_approval_kind AS ENUM ('journal', 'payment', 'invoice', 'contract');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_approval_status AS ENUM ('pending', 'approved', 'rejected', 'waiting');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_asset_status AS ENUM ('active', 'disposed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_audit_severity AS ENUM ('info', 'warning');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_bank_status AS ENUM ('connected', 'syncing', 'error', 'disconnected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_bank_type AS ENUM ('h2h', 'va', 'statement');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_budget_type AS ENUM ('revenue', 'expense');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_bupot_status AS ENUM ('draft', 'ready', 'sent', 'accepted');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_bupot_type AS ENUM ('ppn_keluaran', 'ppn_masukan', 'pph23', 'pph42', 'pph21');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_cash_account_type AS ENUM ('cash', 'bank');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_cash_type AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_chart_type AS ENUM ('table', 'bar', 'line');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_contract_kind AS ENUM ('deferred_revenue', 'prepaid', 'lease', 'accrual');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_contract_status AS ENUM ('active', 'completed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_depreciation_method AS ENUM ('straight', 'declining');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_elimination_status AS ENUM ('draft', 'posted');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_entity_currency AS ENUM ('IDR', 'USD', 'SGD');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_entity_role AS ENUM ('holding', 'subsidiary', 'associate');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_export_format AS ENUM ('SAF-T', 'CSV', 'XLSX', 'AUD');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_export_status AS ENUM ('queued', 'ready', 'downloaded');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_fiscal_status AS ENUM ('closed', 'open', 'future');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_flow AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_intercompany_status AS ENUM ('draft', 'posted', 'eliminated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_intercompany_type AS ENUM ('sale', 'service', 'loan', 'dividend');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_invoice_status AS ENUM ('unpaid', 'partial', 'paid');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_invoice_type AS ENUM ('sales', 'purchase');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_journal_source AS ENUM ('manual', 'inventory', 'sales', 'purchasing', 'payroll', 'system');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_ocr_status AS ENUM ('captured', 'draft_expense', 'discarded');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_partner_type AS ENUM ('customer', 'supplier');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_project_status AS ENUM ('on_going', 'completed', 'over_budget');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_recon_status AS ENUM ('suggested', 'matched', 'dismissed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_spt_kind AS ENUM ('PPN', '"PPh 23"', '"PPh 21"');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.acc_spt_status AS ENUM ('draft', 'ready', 'submitted', 'accepted');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_acquisition_source AS ENUM ('beli', 'hibah', 'bawaan-pemilik', 'capex');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_approval_status AS ENUM ('pending', 'disetujui', 'ditolak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_asset_condition AS ENUM ('baik', 'perlu-perhatian', 'rusak-ringan', 'rusak-berat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_asset_status AS ENUM ('aktif', 'perbaikan', 'dipinjam', 'disposed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_audit_session_status AS ENUM ('terjadwal', 'terbuka', 'berjalan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_capex_status AS ENUM ('diajukan', 'disetujui', 'ditolak', 'po-dibuat', 'diterima', 'kapitalisasi', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_cip_status AS ENUM ('berjalan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_claim_stage AS ENUM ('insiden', 'dokumentasi', 'klaim', 'settlement', 'selesai', 'ditolak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_custody_type AS ENUM ('bast-awal', 'pindah-tangan', 'pengembalian');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_depreciation_method AS ENUM ('garis-lurus', 'saldo-menurun-ganda');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_disposal_method AS ENUM ('dijual', 'rusak', 'hilang', 'donasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_disposal_status AS ENUM ('usulan', 'disetujui', 'ditolak', 'tereksekusi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_fiscal_group AS ENUM ('K1', 'K2', 'K3', 'K4');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_fitness_status AS ENUM ('layak', 'perlu-perhatian', 'tidak-layak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_lease_status AS ENUM ('berjalan', 'berakhir', 'diubah');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_loan_status AS ENUM ('dipinjam', 'dikembalikan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_location_level AS ENUM ('cabang', 'gedung', 'lantai', 'titik');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_pm_status AS ENUM ('terjadwal', 'berjalan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_policy_status AS ENUM ('aktif', 'expired');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_priority AS ENUM ('rendah', 'sedang', 'tinggi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_replacement_priority AS ENUM ('tinggi', 'sedang', 'rendah');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_safety_kind AS ENUM ('apar', 'harness', 'helmet', 'genset', 'tandon', 'listrik', 'forklift');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_scan_status AS ENUM ('terbuka', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_vehicle_log_type AS ENUM ('bbm', 'servis', 'pajak', 'stnk');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.ast_wo_status AS ENUM ('terbuka', 'ditugaskan', 'progres', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_add_on_category AS ENUM ('meal', 'equipment', 'activity', 'transport', 'other');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_channel AS ENUM ('walk_in', 'whatsapp', 'phone', 'website', 'corporate', 'traveloka', 'tiket', 'agoda', 'booking_com', 'airbnb');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_folio_source AS ENUM ('room', 'fnb', 'minibar', 'laundry', 'equipment', 'damage', 'other');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_group_stage AS ENUM ('quotation', 'contract', 'dp', 'confirmed', 'closed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_guest_segment AS ENUM ('corporate', 'government');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_hk_task_status AS ENUM ('pending', 'in_progress', 'done', 'inspected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_hk_task_type AS ENUM ('cleaning', 'inspection', 'maintenance', 'turndown');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_hk_unit_status AS ENUM ('dirty', 'clean', 'inspected', 'occupied');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_ledger_type AS ENUM ('guest', 'city');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_ota_import_status AS ENUM ('imported', 'redeemed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_ota_sync_status AS ENUM ('synced', 'syncing', 'error', 'disconnected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_payment_kind AS ENUM ('dp', 'pelunasan', 'extra', 'refund');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_payment_method AS ENUM ('transfer', 'qris', 'cash', 'card', 'va');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_payment_status AS ENUM ('pending', 'confirmed', 'refunded', 'pending_approval', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_pricing_model AS ENUM ('per_unit', 'per_person');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_property_kind AS ENUM ('glamping', 'homestay', 'villa', 'campground', 'hotel', 'venue');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_rate_plan_type AS ENUM ('bar', 'corporate', 'ota', 'package');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_reservation_status AS ENUM ('booking', 'dp_received', 'confirmed', 'checked_in', 'checked_out', 'cancelled', 'no_show');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_task_priority AS ENUM ('normal', 'priority');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_unit_kind AS ENUM ('room', 'villa', 'tent', 'pitch', 'cabana', 'venue');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_venue_slot_status AS ENUM ('open', 'booked', 'blocked');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.book_weather_action AS ENUM ('reschedule', 'voucher', 'refund');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.core_workflow_action AS ENUM ('start', 'approve', 'reject', 'return', 'delegate', 'recall', 'cancel');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.core_workflow_status AS ENUM ('in_progress', 'approved', 'rejected', 'returned', 'cancelled', 'completed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.core_workflow_step_status AS ENUM ('waiting', 'current', 'approved', 'rejected', 'skipped');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_campaign_segment AS ENUM ('vip', 'kronis', 'ibu_hamil', 'bpjs', 'asuransi', 'umum', 'dormant');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_campaign_status AS ENUM ('draft', 'terkirim');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_follow_up_status AS ENUM ('menunggu', 'terkirim', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_follow_up_type AS ENUM ('pasca_tindakan', 'kronis', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_inbox_channel AS ENUM ('whatsapp', 'live_chat', 'instagram', 'facebook');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_inbox_thread_status AS ENUM ('bot', 'agent');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_message_channel AS ENUM ('wa', 'sms', 'email');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_message_kind AS ENUM ('reminder_h1', 'reminder_h2', 'refill', 'hasil_lab', 'ultah', 'followup', 'recall', 'broadcast', 'survey');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_message_status AS ENUM ('terkirim', 'gagal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_referral_status AS ENUM ('menunggu', 'rewarded');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_segment_tag AS ENUM ('vip', 'kronis', 'ibu_hamil', 'bpjs', 'asuransi', 'umum');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_ticket_category AS ENUM ('pelayanan', 'administrasi', 'fasilitas', 'medis');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_ticket_priority AS ENUM ('normal', 'tinggi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.crm_ticket_status AS ENUM ('pending', 'on_progress', 'resolved');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.dokter_portal_event_kind AS ENUM ('akses', 'ttd', 'ack', 'pengajuan', 'resep', 'penunjang', 'insiden', 'telemedisin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.dokter_portal_preauth_status AS ENUM ('diajukan', 'disetujui', 'ditolak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.dokter_portal_quota_kind AS ENUM ('ubah_kuota', 'blokir_jadwal', 'tambah_sesi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.dokter_portal_quota_status AS ENUM ('menunggu_persetujuan', 'disetujui', 'ditolak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.dokter_portal_sep_status AS ENUM ('aktif', 'menunggu', 'tidak_ada');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_aksi_baku AS ENUM ('BACA', 'CREATE', 'TULIS', 'AJUKAN', 'SETUJUI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_arah_kejadian_psn AS ENUM ('PELANGGARAN', 'REWARD');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_arah_sinkron_core AS ENUM ('IMPOR', 'EKSPOR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_flag_beban_tendik AS ENUM ('UNDER', 'MIN', 'OVER');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_hasil_setoran_psn AS ENUM ('LANCAR', 'MUROJAAH', 'ULANG');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_hasil_validasi_umur_ppdb AS ENUM ('BELUM_DINILAI', 'LOLOS', 'GAGAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jalur_ppdb AS ENUM ('DOMISILI', 'AFIRMASI', 'PRESTASI', 'MUTASI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_berkas_ppdb AS ENUM ('AKTA_KELAHIRAN', 'KARTU_KELUARGA', 'RAPOR', 'SERTIFIKAT_PRESTASI', 'KARTU_BANTUAN', 'KARTU_DISABILITAS', 'SK_MUTASI', 'REKOMENDASI_PSIKOLOG', 'REKOMENDASI_DEWAN_GURU', 'IJAZAH_SKL', 'FOTO', 'LAINNYA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_cakupan_target_psn AS ENUM ('JUZ', 'SURAT', 'HALAMAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_hari_akd AS ENUM ('EFEKTIF', 'LIBUR', 'KEGIATAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_izin_psn AS ENUM ('PULANG', 'KEGIATAN', 'LAINNYA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_kelamin_akd AS ENUM ('L', 'P');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_kelamin_ppdb AS ENUM ('LAKI_LAKI', 'PEREMPUAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_kompetensi_tendik AS ENUM ('DIKLAT', 'PPG', 'SERTIFIKASI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_layanan_shp AS ENUM ('STANDARD', 'EKSPRES', 'INSTANT', 'KARGO', 'LAINNYA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_media_ppdb AS ENUM ('FOTO', 'VIDEO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_nilai_konfig AS ENUM ('TEKS', 'ANGKA', 'BOOLEAN', 'OPSI', 'JSON');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_penilaian_akd AS ENUM ('FORMATIF', 'SUMATIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_penugasan_tendik AS ENUM ('MENGAJAR_MAPEL', 'WALI_KELAS', 'KEPESANTRENAN_KELAS_DINIYAH', 'KEPESANTRENAN_KAMAR_MUSYRIF', 'TUGAS_TAMBAHAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_program_psn AS ENUM ('DINIYAH_FORMAL', 'TAHFIDZ', 'KITAB_KUNING', 'KHITOBAH');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_rapor_akd AS ENUM ('MAPEL', 'PROYEK_P5');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_satuan_akd AS ENUM ('SEKOLAH', 'MADRASAH');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_sertifikat_psn AS ENUM ('KHAT', 'LEVEL', 'PROGRES');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_sesi_akd AS ENUM ('HARIAN', 'PELAJARAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_sesi_psn AS ENUM ('MAJELIS', 'MIMBAR', 'IBADAH_KOLEKTIF', 'TAHFIDZ_MALAM', 'KELAS_DINIYAH');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_sk_akd AS ENUM ('KENAIKAN', 'KELULUSAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_ujian_psn AS ENUM ('TASMI', 'DINIYAH', 'KITAB');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenjang_akd AS ENUM ('RA', 'TK', 'SD', 'MI', 'SMP', 'MTs', 'SMA', 'MA', 'SMK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenjang_ppdb AS ENUM ('SD', 'MI', 'SMP', 'MTs', 'SMA', 'MA', 'SMK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_kanal_ppdb AS ENUM ('PUBLIK', 'LURING');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_kategori_afirmasi_ppdb AS ENUM ('YATIM', 'DHUAFA', 'HAFIZH');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_kategori_konten_ppdb AS ENUM ('PENGUMUMAN', 'BERITA', 'FAQ');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_keadaan_komitmen_acc AS ENUM ('CATAT', 'SESUAIKAN', 'LEPAS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_kehadiran_ppdb AS ENUM ('BELUM', 'HADIR', 'TIDAK_HADIR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_kehadiran_psn AS ENUM ('HADIR', 'IZIN', 'SAKIT', 'ALPA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_keputusan_wali_psn AS ENUM ('SETUJU', 'TOLAK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_keterangan_presensi_akd AS ENUM ('HADIR', 'SAKIT', 'IZIN', 'ALPA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_komponen_seleksi_ppdb AS ENUM ('TES_AKADEMIK', 'WAWANCARA', 'TES_KEISLAMAN', 'TES_CALISTUNG');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_lapisan_kaldik_akd AS ENUM ('PROVINSI', 'YAYASAN', 'SATUAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_level_diniyah_psn AS ENUM ('ULA', 'WUSTHA', 'ULYA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_metode_ambil_shp AS ENUM ('PICKUP', 'DROP_OFF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_model_kurikulum_akd AS ENUM ('MERDEKA', 'K13');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_peran_penugasan_akd AS ENUM ('GURU_MAPEL', 'WALI_KELAS', 'PEMBINA_EXSKUL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_peran_penugasan_psn AS ENUM ('USTADZ', 'MUSYRIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_peran_wali_akd AS ENUM ('AYAH', 'IBU', 'WALI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_periode_raport_psn AS ENUM ('BULANAN', 'SEMESTER');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sasaran_akd AS ENUM ('SEMUA', 'ROMBEL', 'JENJANG');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sifat_mapel_akd AS ENUM ('WAJIB', 'PILIHAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sistem_sinkron_core AS ENUM ('DAPODIK', 'VERVALPD', 'DNS', 'DNT', 'EMIS', 'E_RKAM', 'E_IJAZAH_PKPPS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_agenda_psn AS ENUM ('TERJADWAL', 'BERLANGSUNG', 'SELESAI', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_berkas_ppdb AS ENUM ('MENUNGGU', 'SAH', 'TIDAK_SAH', 'DIMINTA_ULANG');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_biaya_ppdb AS ENUM ('BELUM_LUNAS', 'LUNAS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_bk_akd AS ENUM ('AKTIF', 'DITUTUP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_daftar_ulang_ppdb AS ENUM ('DIBUAT', 'SIAP_MASUK', 'BATAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_distribusi_tendik AS ENUM ('BELUM', 'TERKIRIM', 'GAGAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_ekskul_akd AS ENUM ('DIBUKA', 'BERJALAN', 'DITUTUP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_gelombang_ppdb AS ENUM ('DRAFT', 'DIBUKA', 'DITUTUP', 'SELESAI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_hasil_ppdb AS ENUM ('TERJADWAL', 'DINILAI', 'TERKUNCI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_izin_psn AS ENUM ('DIAJUKAN', 'DIVALIDASI_USTADZ', 'DISETUJUI_WAKA', 'MENUNGGU_WALI', 'DISETUJUI', 'BERLANGSUNG', 'KEMBALI', 'DITOLAK', 'TERLAMBAT');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_jadwal_akd AS ENUM ('DRAF', 'AKTIF', 'DIJEDA', 'BERAKHIR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_kaldik_akd AS ENUM ('DRAF', 'VALID', 'ARSIP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_kalkulasi_shp AS ENUM ('DIPROSES', 'SELESAI', 'GAGAL', 'KEDALUWARSA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_kejadian_psn AS ENUM ('TERCATAT', 'PEMBINAAN', 'SELESAI', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_kinerja_tendik AS ENUM ('DRAF', 'FINAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_modul AS ENUM ('AKTIF', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_nilai_psn AS ENUM ('DRAF', 'FINAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_nisn_ppdb AS ENUM ('MENUNGGU', 'TERDAFTAR', 'VALID', 'GAGAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_notifikasi AS ENUM ('TERKIRIM', 'DIBACA', 'DIARSIPKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_p5_akd AS ENUM ('DIBUKA', 'BERJALAN', 'SELESAI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_pendaftaran_ppdb AS ENUM ('DRAFT', 'TERKIRIM', 'VERIFIKASI', 'LOLOS_VERIFIKASI', 'DITOLAK', 'TERJADWAL_SELEKSI', 'SELEKSI_SELESAI', 'LULUS', 'TIDAK_LULUS', 'DAFTAR_ULANG', 'MASUK', 'HANGUS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_penempatan_akd AS ENUM ('PROPOSAL', 'AKTIF', 'MUTASI', 'NAIK', 'TINGGAL', 'LULUS', 'KELUAR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_penempatan_psn AS ENUM ('AKTIF', 'PINDAH', 'KELUAR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_penerbitan_psn AS ENUM ('DRAFT', 'MENUNGGU_PENGESAHAN', 'DISAHKAN', 'TERBIT', 'DICABUT');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_pengaduan_ppdb AS ENUM ('TIDAK_ADA', 'TERKIRIM', 'DITANGANI', 'SELESAI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_pengguna AS ENUM ('AKTIF', 'DINONAKTIFKAN', 'DITANGGUHKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_pengumuman_akd AS ENUM ('DRAF', 'TERJADWAL', 'TAYANG', 'DIARSIPKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_pengumuman_ppdb AS ENUM ('DRAFT', 'TERBIT');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_penilaian_akd AS ENUM ('DRAF', 'DIMODERASI', 'FINAL', 'DIRAPOR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_penugasan AS ENUM ('AKTIF', 'BERAKHIR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_penugasan_akd AS ENUM ('AKTIF', 'BERAKHIR', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_penugasan_psn AS ENUM ('AKTIF', 'BERAKHIR', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_periode_akd AS ENUM ('TERJADWAL', 'TERBUKA', 'TERTUTUP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_ppg_tendik AS ENUM ('BELUM_DAFTAR', 'CALON', 'PROSES', 'LULUS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_presensi_akd AS ENUM ('TERCATAT', 'TERKUNCI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_prestasi_akd AS ENUM ('DIAJUKAN', 'TERVERIFIKASI', 'DIARSIPKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_publikasi_ppdb AS ENUM ('DRAFT', 'TERBIT');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_rapor_akd AS ENUM ('DRAF', 'DIVERIFIKASI', 'TERBIT', 'DIEKSPOR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_raport_psn AS ENUM ('DIPROSES', 'TERBIT', 'GAGAL_DIPROSES');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_rombel_akd AS ENUM ('DIBENTUK', 'AKTIF', 'DITUTUP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_semester_akd AS ENUM ('RANCANGAN', 'AKTIF', 'DITUTUP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_setoran_psn AS ENUM ('TERJADWAL', 'DINILAI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_sinkron_core AS ENUM ('BERJALAN', 'BERHASIL', 'PARSIAL', 'GAGAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_siswa_akd AS ENUM ('AKTIF', 'MUTASI', 'LULUS', 'KELUAR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_sk_akd AS ENUM ('DRAF', 'DIAJUKAN', 'DISETUJUI', 'DITANDATANGANI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_sk_tendik AS ENUM ('DRAF', 'MENUNGGU_PERSETUJUAN', 'AKTIF', 'BERAKHIR', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_struktur_akd AS ENUM ('DRAF', 'AKTIF', 'ARSIP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_ta_akd AS ENUM ('RANCANGAN', 'AKTIF', 'ARSIP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_target_psn AS ENUM ('AKTIF', 'ARSIP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_ujian_psn AS ENUM ('TERJADWAL', 'DINILAI', 'DIVALIDASI_WAKA', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_verifikasi_kompetensi_tendik AS ENUM ('MENUNGGU', 'TERVERIFIKASI', 'DITOLAK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_beban_tendik AS ENUM ('SK_ONLY', 'TERVERIFIKASI_JADWAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_data_akd AS ENUM ('PPDB', 'MUTASI', 'MANUAL', 'MIGRASI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_nilai_psn AS ENUM ('KELAS_DINIYAH', 'UJIAN_TASMI', 'PROGRES_KITAB', 'MANUAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_penugasan_akd AS ENUM ('SK_SDM', 'MANUAL_MIGRASI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_penugasan_psn AS ENUM ('INTERNAL', 'SK_SDM');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_presensi_akd AS ENUM ('QR', 'MANUAL', 'WSI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_santri_psn AS ENUM ('MANUAL', 'MIGRASI', 'AKD');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_target_psn AS ENUM ('DEFAULT_PROGRAM', 'PENYESUAIAN_SANTRI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_target_distribusi_tendik AS ENUM ('AKD', 'PSN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_jenis_baris AS ENUM ('BIAYA', 'POTONGAN', 'BEASISWA', 'DENDA', 'PENYESUAIAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_jenis_beasiswa AS ENUM ('PRESTASI', 'HAFIZH', 'YATIM_DHUAFA', 'ANAK_PEGAWAI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_jenis_penyesuaian AS ENUM ('KOREKSI', 'KREDIT_NOTE', 'VOID_TAGIHAN', 'REFUND');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_jenis_potongan AS ENUM ('KAKAK_ADIK', 'ANAK_PEGAWAI', 'DAFTAR_ULANG_AWAL', 'KEMITRAAN', 'KEBIJAKAN_EKONOMI', 'LAINNYA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_jenis_tagihan AS ENUM ('PAKET', 'MANUAL', 'PPDB', 'KEGIATAN', 'DENDA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_jenjang_pengingat AS ENUM ('PRA_JT', 'PASCA_JT');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_kanal_bayar AS ENUM ('KASIR', 'TRANSFER', 'VA', 'QRIS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_kanal_kirim AS ENUM ('INTERNAL', 'WA', 'EMAIL', 'CETAK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_kanal_pengingat AS ENUM ('INTERNAL', 'WA', 'EMAIL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_sifat_komponen AS ENUM ('WAJIB', 'OPSIONAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_siklus_komponen AS ENUM ('BULANAN', 'SEMESTER', 'TAHUNAN', 'SEKALI', 'KEGIATAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_angsuran AS ENUM ('TERJADWAL', 'JATUH_TEMPO', 'TERBAYAR', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_batch AS ENUM ('BERJALAN', 'SELESAI', 'SELESAI_DENGAN_GAGAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_keringanan AS ENUM ('DIAJUKAN', 'DISETUJUI', 'DITOLAK', 'AKTIF', 'BERAKHIR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_kwitansi AS ENUM ('TERBIT', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_match AS ENUM ('TAK_DIKENAL', 'DIUSULKAN', 'TERMATCH');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_paket AS ENUM ('DRAF', 'AKTIF', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_pembayaran AS ENUM ('PENDING_VERIFIKASI', 'TERKONFIRMASI', 'DITOLAK', 'REFUNDED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_pengecualian AS ENUM ('DIAJUKAN', 'DISETUJUI', 'DITOLAK', 'BERAKHIR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_pengingat AS ENUM ('DIJADWALKAN', 'TERKIRIM', 'GAGAL', 'DILEWATI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_penyesuaian AS ENUM ('DIAJUKAN', 'DISETUJUI', 'DITOLAK', 'DIEKSEKUSI', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_status_tagihan AS ENUM ('TERJADWAL', 'TERBIT', 'SEBAGIAN', 'TERLAMBAT', 'LUNAS', 'ADJUSTED', 'VOID');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_subjek_tipe AS ENUM ('SISWA', 'MANUAL_INTERIM', 'PENDAFTARAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_sumber_dana AS ENUM ('DANA_BEBAS', 'DANA_TERBATAS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_sumber_pembayaran AS ENUM ('KASIR', 'WSI', 'SISTEM');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_sumber_skema AS ENUM ('SKEMA_BENDAHARA', 'USULAN_WALI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tgs_tipe_nilai AS ENUM ('PERSEN', 'NOMINAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_tingkat_kerahasiaan_akd AS ENUM ('UMUM', 'TERBATAS', 'RAHASIA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_branch AS ENUM ('kln-btm', 'kln-ggx');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_dose_unit AS ENUM ('tab', 'kps', 'ml', 'amp', 'patch', 'sachet', 'tube');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_drug_class AS ENUM ('keras', 'bebas', 'bebas_terbatas', 'narkotika', 'psikotropika');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_drug_form AS ENUM ('tablet', 'kapsul', 'sirup', 'injeksi', 'salep', 'patch', 'sachet', 'effervescent');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_konsinyasi_type AS ENUM ('terima', 'terjual', 'retur', 'settlement');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_opname_scope AS ENUM ('semua', 'narkotika');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_opname_status AS ENUM ('draft', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_pay_method AS ENUM ('tunai', 'qris', 'saldo_pasien');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_pr_reason AS ENUM ('stok_minimum', 'forecast');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_pr_status AS ENUM ('diusulkan', 'diproses');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_price_kind AS ENUM ('umum', 'bpjs', 'tpa', 'asuransi', 'korporat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_resep_status AS ENUM ('menunggu_kaji', 'dikaji', 'disiapkan', 'menunggu_bayar', 'selesai', 'revisi_diminta', 'ditolak', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_retur_reason AS ENUM ('expired', 'rusak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_sale_status AS ENUM ('menunggu_bayar', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_tele_channel AS ENUM ('whatsapp', 'halodoc', 'klikapotek');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.farmasi_tele_status AS ENUM ('diproses', 'dikirim', 'diterima');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_account_type AS ENUM ('cash', 'bank', 'petty_cash');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_anomaly_status AS ENUM ('baru', 'ditinjau', 'selesai', 'false_alarm');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_anomaly_type AS ENUM ('duplikat', 'pola_tak_wajar', 'fraud_risk');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_budget_mode AS ENUM ('warning', 'block', 'approval');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_card_tx_status AS ENUM ('matched', 'unmatched');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_collection_status AS ENUM ('baru', 'dihubungi', 'janji_bayar', 'eskalasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_direction AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_disbursement_category AS ENUM ('payroll', 'supplier', 'reimbursement', 'refund');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_disbursement_status AS ENUM ('draft', 'awaiting_approval', 'processing', 'completed', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_expense_kind AS ENUM ('expense', 'travel', 'cash_advance');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_expense_status AS ENUM ('awaiting_approval', 'approved', 'disbursed', 'settled', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_flow_type AS ENUM ('operasional', 'investasi', 'pembiayaan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_giro_status AS ENUM ('registered', 'deposited', 'cleared', 'bounced');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_giro_type AS ENUM ('received', 'issued');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_ic_loan_status AS ENUM ('aktif', 'lunas');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_loan_calc AS ENUM ('flat', 'anuitas', 'menurun');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_loan_kind AS ENUM ('bank', 'leasing', 'internal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_match_status AS ENUM ('matched', 'suggested', 'unmatched');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_mutation_ref_type AS ENUM ('receipt', 'payment', 'transfer', 'petty', 'manual', 'bank_import', 'va', 'disbursement', 'loan', 'reimbursement', 'giro', 'pooling');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_payment_method AS ENUM ('transfer', 'cash', 'qris', 'virtual_account', 'giro', 'ewallet');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_payment_request_status AS ENUM ('cek_budget', 'menunggu_persetujuan', 'siap_eksekusi', 'dieksekusi', 'ditolak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_petty_type AS ENUM ('expense', 'refill', 'return');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_pool_type AS ENUM ('operasional', 'zba', 'pool', 'payroll', 'physical', 'notional');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_pooling_kind AS ENUM ('physical', 'notional');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_reimbursement_status AS ENUM ('submitted', 'approved', 'paid', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_supplier_invoice_status AS ENUM ('diterima', 'diverifikasi', 'dijadwalkan', 'dibayar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_va_bank AS ENUM ('BCA', 'Mandiri', 'BRI', 'CIMB', 'BNI', 'Permata');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fin_withholding_type AS ENUM ('"PPh 22"', '"PPh 23"', '"PPh 4(2)"');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_banquet_status AS ENUM ('draft', 'confirmed', 'in_preparation', 'served', 'billed', 'closed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_channel AS ENUM ('telepon', 'qr_kamar', 'whatsapp');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_consumption_source_type AS ENUM ('pos_sale', 'room_service', 'banquet', 'production', 'minibar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_haccp_result AS ENUM ('lulus', 'tidak_lulus', 'na');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_haccp_shift AS ENUM ('pagi', 'siang', 'malam');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_menu_category AS ENUM ('makanan_utama', 'appetizer', 'sup', 'dessert', 'minuman', 'minibar', 'paket_banquet');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_minibar_count_status AS ENUM ('counted', 'charged', 'void');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_production_status AS ENUM ('planned', 'in_progress', 'completed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_requisition_status AS ENUM ('draft', 'submitted', 'converted', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_room_service_status AS ENUM ('open', 'preparing', 'on_delivery', 'delivered', 'charged', 'void');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_station AS ENUM ('kitchen', 'bar', 'pastry');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_waste_reason AS ENUM ('kadaluarsa', 'rusak', 'gagal_masak', 'sisa_produksi', 'lainnya');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.fnb_waste_status AS ENUM ('posted', 'void');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_approval_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_asset_status AS ENUM ('draft', 'diajukan', 'dibayar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_attendance_source AS ENUM ('web', 'mobile', 'fingerprint', 'face', 'rfid');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_attendance_status AS ENUM ('hadir', 'terlambat', 'izin', 'sakit', 'cuti', 'alpha');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_channel_status AS ENUM ('terhubung', 'gangguan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_claim_category AS ENUM ('transport', 'medis', 'representasi', 'lainnya');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_contract_status AS ENUM ('aktif', 'akan_berakhir', 'diperbarui', 'berakhir');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_employee_status AS ENUM ('tetap', 'kontrak', 'probation', 'harian', 'resigned');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_endpoint_status AS ENUM ('aktif', 'jeda', 'error');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_gender AS ENUM ('L', 'P');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_leave_type AS ENUM ('tahunan', 'sakit', 'melahirkan', 'menikah', 'duka', 'unpaid');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_loan_status AS ENUM ('active', 'completed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_missing_punch_type AS ENUM ('lupa_masuk', 'lupa_pulang');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_notif_channel AS ENUM ('email', 'whatsapp', 'inapp');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_payrun_kind AS ENUM ('reguler', 'thr', 'bonus', 'settlement');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_payrun_status AS ENUM ('draft', 'calculated', 'reviewed', 'approved', 'posted', 'paid');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_profile_update_status AS ENUM ('pending', 'verified', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.hr_run_result_status AS ENUM ('berhasil', 'gagal_sebagian', 'diproses');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_abc_class AS ENUM ('A', 'B', 'C');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_adjustment_type AS ENUM ('rusak', 'hilang', 'retur', 'koreksi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_approval_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_backorder_status AS ENUM ('waiting', 'partial', 'done');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_channel AS ENUM ('shopee', 'tokopedia', 'lazada', 'pos', 'website');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_correction_type AS ENUM ('rusak', 'hilang', 'retur', 'koreksi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_dropship_status AS ENUM ('new', 'forwarded', 'shipped', 'delivered');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_move_doc_status AS ENUM ('draft', 'awaiting_approval', 'approved', 'posted', 'rejected', 'in_transit', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_move_doc_type AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_movement_dir AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_mutation_type AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_opname_status AS ENUM ('scheduled', 'counting', 'reconciled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_po_draft_status AS ENUM ('draft', 'submitted');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_ref_type AS ENUM ('purchase', 'sales', 'opname', 'adjustment', 'transfer', 'manual');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_serial_status AS ENUM ('in_stock', 'reserved', 'sold');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_sync_status AS ENUM ('success', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.inv_transfer_status AS ENUM ('draft', 'awaiting_approval', 'approved', 'in_transit', 'received', 'rejected', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_adjustment_scope AS ENUM ('tindakan', 'kategori', 'periode');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_adjustment_source AS ENUM ('internal', 'portal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_adjustment_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_class_name AS ENUM ('Umum', 'Asuransi', 'BPJS', 'Korporat', 'VIP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_contract_status AS ENUM ('draft', 'pending_approval', 'aktif', 'berakhir', 'dibatalkan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_doctor_status AS ENUM ('tetap', 'visiting', 'per_case');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_event_kind AS ENUM ('fee_post', 'fee_reverse', 'adjust', 'contract', 'scheme', 'slip', 'payment', 'pph', 'portal', 'payroll', 'compliance', 'recon');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_fee_entry_status AS ENUM ('posted', 'reversed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_nakes_role AS ENUM ('dokter', 'dokter_gigi', 'perawat', 'bidan', 'apoteker');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_payer_class AS ENUM ('umum', 'asuransi', 'bpjs', 'korporat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_payer_scope AS ENUM ('all', 'umum', 'asuransi', 'bpjs', 'korporat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_payment_method AS ENUM ('transfer', 'h2h');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_pph_status AS ENUM ('dihitung', 'dipotong', 'disetor');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_recon_status AS ENUM ('open', 'resolved');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_recon_type AS ENUM ('belum_ditagih', 'void_setelah_fee', 'selisih_tarif');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_scheme_kind AS ENUM ('percentage', 'nominal', 'tier', 'guarantee_fee');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_slip_period_type AS ENUM ('bulanan', 'mingguan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.jasmed_slip_status AS ENUM ('draft', 'terbit', 'dibayar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_authorizer_role AS ENUM ('"Supervisor Kasir"', '"Manager Operasional"', 'Direktur');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_bill_status AS ENUM ('menunggu', 'dibayar', 'void');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_cash_type AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_doctor_role AS ENUM ('umum', 'spesialis', 'gigi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_hold_source AS ENUM ('rme', 'kasir');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_hold_status AS ENUM ('held');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_item_source AS ENUM ('rme', 'farmasi', 'kasir');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_payer_kind AS ENUM ('umum', 'bpjs', 'tpa', 'asuransi', 'korporat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_payment_method AS ENUM ('cash', 'qris', 'edc', 'va');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_payment_payer AS ENUM ('pasien', 'penjamin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_sale_status AS ENUM ('completed', 'voided');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_sale_type AS ENUM ('jasa', 'barang');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_service_kind AS ENUM ('jasa', 'barang', 'admin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kasir_shift_status AS ENUM ('open', 'closed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_accident_severity AS ENUM ('ringan', 'sedang', 'berat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_accident_status AS ENUM ('terbuka', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_audit_status AS ENUM ('terjadwal', 'berjalan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_capa_source AS ENUM ('audit-internal', 'insiden', 'survei', 'komite', 'monitoring');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_capa_status AS ENUM ('terbuka', 'progres', 'verifikasi', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_committee AS ENUM ('komite-medis', 'ppi', 'mutu', 'k3');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_disposition_method AS ENUM ('musnah', 'arsip');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_ep_status AS ENUM ('belum', 'sedang', 'sesuai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_evidence_key AS ENUM ('rme-cppt', 'asset-kalibrasi', 'farmasi-pengkajian', 'farmasi-narkotika', 'hr-pelatihan', 'booking-kebersihan', 'audit-akses-rm', 'limbah-manifest', 'insiden-ikp');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_export_status AS ENUM ('draft', 'diekspor', 'terkirim');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_export_type AS ENUM ('sirs', 'satu-data', 'dinkes');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_finding_severity AS ENUM ('mayor', 'minor', 'observasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_hygiene_kind AS ENUM ('kebersihan-tangan', 'kebersihan-ruang');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_hygiene_shift AS ENUM ('pagi', 'siang', 'sore');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_incident_status AS ENUM ('dilaporkan', 'diverifikasi', 'investigasi', 'perbaikan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_incident_type AS ENUM ('near-miss', 'kpc', 'kdd', 'sentinel');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_infection_type AS ENUM ('infeksi-luka', 'isk', 'ispa', 'lainnya');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_k3_kind AS ENUM ('apar', 'jalur-evakuasi', 'listrik', 'sanitasi', 'tandon');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_k3_program AS ENUM ('bhd', 'p3k', 'k3-umum', 'kebakaran');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_legal_doc_kind AS ENUM ('nib-oss', 'izin-klinik', 'akreditasi', 'str', 'sip', 'sipp', 'izin-alkes', 'izin-radiasi', 'sertifikat-lainnya');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_quality_category AS ENUM ('sop', 'kebijakan', 'buku-mutu', 'manual');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_quality_status AS ENUM ('draft', 'review', 'disetujui', 'arsip');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_rca_status AS ENUM ('berjalan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_report_frequency AS ENUM ('bulanan', 'triwulan', 'semester', 'tahunan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_retention_action AS ENUM ('arsip', 'musnah');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_retention_type AS ENUM ('rekam-medis', 'resep', 'dokumen-mutu', 'keuangan', 'log-akses', 'limbah');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_risk_category AS ENUM ('klinis', 'operasional', 'data', 'regulasi', 'k3');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_risk_level AS ENUM ('rendah', 'sedang', 'tinggi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_risk_status AS ENUM ('aktif', 'termitigasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_rm_action AS ENUM ('buka', 'ubah', 'cetak', 'ekspor');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_rm_basis AS ENUM ('perawatan', 'persetujuan-pasien', 'audit', 'klaim');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_room_category AS ENUM ('poliklinik', 'tindakan', 'penunjang', 'umum');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_run_status AS ENUM ('berjalan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_std_group AS ENUM ('pelayanan', 'manajemen');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_submission_status AS ENUM ('terkirim', 'dikonfirmasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_survey_status AS ENUM ('persiapan', 'terjadwal', 'berjalan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_survey_type AS ENUM ('akreditasi-pertama', 'asesmen-berkala', 'survei-mutu', 'survei-internal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_waste_category AS ENUM ('infeksius', 'tajam', 'patologis', 'kimia-farmasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.kepatuhan_waste_status AS ENUM ('diserahkan', 'dikonfirmasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_ai_flag_status AS ENUM ('baru', 'ditinjau', 'diabaikan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_api_partner_kind AS ENUM ('mcu_korporat', 'lab_mititra', 'rumah_sakit', 'klaim');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_api_partner_status AS ENUM ('connected', 'degraded', 'disconnected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_billing_status AS ENUM ('unpaid', 'paid', 'pascabayar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_claim_payer AS ENUM ('BPJS', 'Asuransi', 'Korporat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_courier_status AS ENUM ('transit', 'diterima');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_event_kind AS ENUM ('order', 'sample', 'reject', 'run', 'hl7', 'result', 'verify', 'amend', 'critical', 'qc', 'calibration', 'ris', 'fhir', 'courier', 'settlement', 'pacs', 'distribute');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_fhir_resource AS ENUM ('DiagnosticReport', 'Observation');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_fhir_status AS ENUM ('terkirim', 'antre', 'gagal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_gender AS ENUM ('L', 'P');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_instrument_kind AS ENUM ('hematologi', '"kimia klinik"', 'urinalisis', 'serologi', 'centrifuge', 'rontgen', 'usg');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_instrument_status AS ENUM ('normal', 'qc-fail', 'maintenance');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_lot_status AS ENUM ('ok', 'low', 'expired');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_movement_reason AS ENUM ('consumption', 'waste', 'film');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_order_item_status AS ENUM ('requested', 'collected', 'processing', 'completed', 'verified');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_order_priority AS ENUM ('rutin', 'cepat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_partner_status AS ENUM ('aktif', 'paused');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_qc_level AS ENUM ('normal', 'patologis');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_qc_status AS ENUM ('pass', 'warning', 'fail');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_qi_phase AS ENUM ('pra-analitik', 'analitik', 'pasca-analitik');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_rad_modality AS ENUM ('rontgen', 'usg');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_rad_status AS ENUM ('ordered', 'in_progress', 'draft', 'final');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_result_flag AS ENUM ('normal', 'tinggi', 'rendah', 'kritis-tinggi', 'kritis-rendah', 'abnormal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_result_source AS ENUM ('manual', 'hl7-astm');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_result_status AS ENUM ('draft', 'final', 'usang');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_revshare_status AS ENUM ('pending', 'paid');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_sample_condition AS ENUM ('cukup', 'lisis', 'ikterik');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_test_category AS ENUM ('Hematologi', '"Kimia Darah"', 'Urinalisis', 'Serologi', 'Radiologi', 'USG');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_test_origin AS ENUM ('internal', 'kemitraan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_value_type AS ENUM ('numeric', 'qualitative');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.lab_work_kind AS ENUM ('lab', 'radiologi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_aging_bucket AS ENUM ('0-30', '31-60', '61-90', '>90');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_batch_channel AS ENUM ('manual', 'edi', 'portal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_batch_finding_type AS ENUM ('kurang_bayar', 'lebih_bayar', 'denial');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_billing_basis AS ENUM ('per_kasus', 'bulanan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_bpjs_submission_status AS ENUM ('menunggu', 'terkirim');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_bpjs_submission_type AS ENUM ('data_pelayanan', 'klaim_luar_paket');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_capitation_member_status AS ENUM ('aktif', 'nonaktif');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_capitation_period_status AS ENUM ('diterbitkan', 'dibayar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_capitation_segment AS ENUM ('PBI', 'Non-PBI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_claim_batch_status AS ENUM ('draft', 'terkirim', 'diproses', 'direkonsiliasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_claim_status AS ENUM ('draft', 'menunggu_dokumen', 'diajukan', 'diproses', 'disetujui', 'ditolak', 'ditolak_sebagian', 'dibayar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_denial_code AS ENUM ('DOC-INC', 'EXCL', 'PLAFON', 'PREAUTH', 'WAITING', 'DUP', 'OTHER');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_eligibility_outcome AS ENUM ('approved', 'warning', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_event_kind AS ENUM ('eligibility', 'split', 'invoice', 'payment', 'denial', 'claim', 'preauth', 'sep', 'mcu', 'batch', 'reminder');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_follow_up AS ENUM ('perbaiki_dokumen', 'pindah_pasien', 'banding');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_grade AS ENUM ('A', 'B', 'C', 'D');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_integration_status AS ENUM ('tersambung', 'terbatas', 'belum');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_integration_type AS ENUM ('vclaim', 'satusehat', 'edi_tpa', 'api_penjamin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_invoice_basis AS ENUM ('per_kasus', 'bulanan', 'batch_mcu', 'kapitasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_invoice_status AS ENUM ('terbit', 'dikirim', 'dispute', 'dibayar', 'ditolak_sebagian');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_kind AS ENUM ('bpjs', 'tpa', 'asuransi', 'korporat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_mcu_batch_status AS ENUM ('draft', 'dijadwalkan', 'berjalan', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_mcu_contract_status AS ENUM ('aktif', 'berakhir');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_mcu_reconcile AS ENUM ('bulanan', 'per_kasus');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_mcu_result AS ENUM ('sehat', 'sehat_dgn_catatan', 'tidak_lulus');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_mcu_voucher_status AS ENUM ('terbit', 'terpakai', 'kedaluwarsa');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_payment_method AS ENUM ('transfer', 'giro', 'kliring');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_preauth_status AS ENUM ('diajukan', 'disetujui', 'ditolak', 'revisi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_rate_card_status AS ENUM ('aktif', 'arsip');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_referral_direction AS ENUM ('masuk', 'keluar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_reminder_channel AS ENUM ('email', 'wa', 'surat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_reminder_level AS ENUM ('reminder_1', 'reminder_2', 'surat_pemberitahuan', 'eskalasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_risk_level AS ENUM ('rendah', 'sedang', 'tinggi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_scheme AS ENUM ('fee_for_service', 'capitation', 'paket');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_sep_status AS ENUM ('aktif', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_sep_type AS ENUM ('rujukan', 'kontrol', 'kunjungan_langsung');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.penjamin_split_status AS ENUM ('terbuka', 'ditagihkan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_business_mode AS ENUM ('retail', 'fnb', 'take_away', 'delivery');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_cash_type AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_customer_status AS ENUM ('aktif', 'blocked');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_customer_tx_type AS ENUM ('topup', 'pay', 'refund', 'adjust', 'redeem');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_event_type AS ENUM ('sale', 'void', 'refund', 'discount', 'topup', 'refund_deposit', 'voucher', 'shift');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_kds_line_status AS ENUM ('queued', 'preparing', 'ready');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_payment_method AS ENUM ('cash', 'qris', 'edc', 'saldo');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_promo_type AS ENUM ('happy_hour', 'bundle', 'member_price', 'bxgy');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_sale_status AS ENUM ('completed', 'voided', 'held', 'refunded');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_shift_status AS ENUM ('open', 'closed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_station AS ENUM ('bar', 'kitchen');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_table_status AS ENUM ('kosong', 'terisi', 'reserved');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pos_voucher_type AS ENUM ('percent', 'nominal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_asn_status AS ENUM ('announced', 'in_transit', 'received');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_contract_status AS ENUM ('active', 'expiring', 'closed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_dropship_status AS ENUM ('pending', 'po_sent', 'shipped', 'delivered', 'issue');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_efaktur_status AS ENUM ('matched', 'unmatched', 'synced');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_import_status AS ENUM ('dokumen', 'pelabuhan', 'bea_cukai', 'released', 'landed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_intercompany_status AS ENUM ('requested', 'approved', 'invoiced', 'eliminated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_invoice_status AS ENUM ('unpaid', 'partial', 'paid');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_jenis_baris AS ENUM ('BARANG', 'JASA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_mobile_kind AS ENUM ('PO', 'PR', 'Payment');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_mobile_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_notification_channel AS ENUM ('push', 'email', 'whatsapp');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_ocr_status AS ENUM ('processing', 'ready', 'imported', 'discarded', 'blocked');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_po_status AS ENUM ('draft', 'approved', 'received', 'done');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_portal_upload_status AS ENUM ('pending_review', 'validated', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_pr_status AS ENUM ('submitted', 'approved', 'rejected', 'converted');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_savings_status AS ENUM ('targeted', 'realized');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_subcontract_status AS ENUM ('material_sent', 'in_process', 'finished_received');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_supplier_category AS ENUM ('barang', 'jasa', 'importir');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_supplier_status AS ENUM ('aktif', 'trial', 'blacklist');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_tax_note_type AS ENUM ('debit', 'credit');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_tender_status AS ENUM ('open', 'closed', 'awarded');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_blackout_scope AS ENUM ('dokter', 'poli', 'semua');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_booking_status AS ENUM ('booked', 'checked_in', 'no_show', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_channel AS ENUM ('walk_in', 'whatsapp', 'telepon', 'online_jkn', 'satusehat', 'halodoc', 'alodokter', 'kiosk', 'aplikasi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_decision_status AS ENUM ('menunggu', 'disetujui', 'ditolak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_gender AS ENUM ('L', 'P');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_notif_channel AS ENUM ('wa', 'sms', 'email');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_notif_kind AS ENUM ('konfirmasi', 'reminder_h1', 'reminder_h0', 'perubahan_jadwal', 'penawaran_slot');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_notif_status AS ENUM ('terkirim', 'gagal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_patient_category AS ENUM ('umum', 'anak', 'lansia', 'ibu_hamil');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_patient_kind AS ENUM ('baru', 'lama');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_payer_kind AS ENUM ('umum', 'bpjs', 'tpa', 'asuransi', 'korporat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_service_type AS ENUM ('konsultasi', 'tindakan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_visit_kind AS ENUM ('baru', 'kunjungan_ulang', 'kontrol');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_visit_priority AS ENUM ('normal', 'darurat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_visit_status AS ENUM ('menunggu', 'dilayani', 'selesai', 'terlewat', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.regpas_waiting_status AS ENUM ('menunggu', 'ditawarkan', 'promosi', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_amendment_target AS ENUM ('aop', 'soap', 'diagnosis', 'tindakan', 'resume');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_audit_action AS ENUM ('buka_rm', 'buat_catatan', 'amend', 'ttd', 'kirim_resep', 'revisi_resep', 'tagih_kasir', 'konsen', 'ekspor', 'akses', 'sinkron', 'rujukan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_author_role AS ENUM ('dokter', 'perawat', 'apoteker');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_drug_category AS ENUM ('"Obat Keras"', '"Obat Bebas & OTC"');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_drug_form AS ENUM ('tablet', 'kapsul', 'sirup', 'salep', 'tetes', 'injeksi', 'nebule', 'inhaler', 'larutan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_drug_type AS ENUM ('generik', 'paten');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_dx_kind AS ENUM ('utama', 'sekunder');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_encounter_kind AS ENUM ('tatap_muka', 'telemedisin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_encounter_status AS ENUM ('dibuka', 'ditutup');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_fhir_partner_kind AS ENUM ('rs_rujukan', 'lab_mitra', 'asuransi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_prescription_status AS ENUM ('draft', 'terkirim', 'dikaji', 'revisi_diajukan', 'direvisi', 'disetujui', 'ditolak', 'diserahkan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_procedure_category AS ENUM ('Konsultasi', 'Tindakan', 'Kegigian', 'Penunjang');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_procedure_role AS ENUM ('dokter', 'dokter_gigi', 'perawat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_referral_kind AS ENUM ('internal', 'eksternal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_referral_service AS ENUM ('lab', 'radiologi', 'poli', 'faskes_lain');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_referral_status AS ENUM ('diterbitkan', 'hasil_diterima', 'selesai');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_registry_program AS ENUM ('DM', 'HT', 'ASMA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_satusehat_resource AS ENUM ('Patient', 'Encounter', 'Condition', 'Observation', 'MedicationRequest', 'ServiceRequest');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_signer_relation AS ENUM ('pasien', 'keluarga');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_substitution_outcome AS ENUM ('diajukan', 'diterima', 'ditolak_dokter');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_sync_status AS ENUM ('pending', 'terkirim', 'gagal', 'retry');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_tele_modality AS ENUM ('chat', 'video');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_tele_payment AS ENUM ('va_paid', 'va_pending');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_tele_status AS ENUM ('menunggu', 'berlangsung', 'selesai', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_template_status AS ENUM ('draft', 'review', 'disetujui');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_ttd_method AS ENUM ('pin', 'passkey');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_vital_source AS ENUM ('triase', 'pemeriksaan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_webhook_event_kind AS ENUM ('encounter.selesai', 'hasil_lab.kritis', 'resep.diserahkan', 'rujukan.diterbitkan');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.rme_webhook_status AS ENUM ('200', '500', 'pending');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_approval_level AS ENUM ('sales', 'supervisor', 'manager');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_backorder_status AS ENUM ('menunggu', 'dipenuhi');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_cascade_level AS ENUM ('perusahaan', 'wilayah', 'tim', 'individu');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_channel AS ENUM ('gt', 'mt', 'key-account');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_commission_base AS ENUM ('penjualan', 'margin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_commission_status AS ENUM ('draft', 'disetujui', 'ke-payroll');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_consignment_status AS ENUM ('titipan', 'lapor-terjual', 'settled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_delivery_status AS ENUM ('dikirim', 'diterima');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_discount_approval_status AS ENUM ('pending', 'disetujui', 'ditolak');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_edi_status AS ENUM ('masuk', 'diproses');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_invoice_status AS ENUM ('outstanding', 'lunas');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_order_status AS ENUM ('draft', 'confirm', 'dikirim', 'terinvoice', 'selesai', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_payment_term_id AS ENUM ('cash', 'tempo7', 'tempo14', 'tempo30');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_price_tier AS ENUM ('ecer', 'grosir', 'member', 'reseller', 'distributor');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_promo_status AS ENUM ('aktif', 'berakhir', 'draft');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_promo_type AS ENUM ('diskon-percent', 'diskon-nominal', 'bundling', 'cashback');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_quotation_status AS ENUM ('draft', 'terkirim', 'converted', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_rebate_status AS ENUM ('berjalan', 'terbayar');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_rep_role AS ENUM ('sales', 'spv', 'manager');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_return_status AS ENUM ('draft', 'disetujui');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_route_status AS ENUM ('check-in', 'order', 'selesai', 'batal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.sal_tpm_stage AS ENUM ('rencana', 'approval', 'eksekusi', 'klaim', 'settlement');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd
