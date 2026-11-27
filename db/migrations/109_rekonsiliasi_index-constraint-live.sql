-- +goose Up
-- =====================================================================================
-- MIGRASI REKONSILIASI: 109_rekonsiliasi_index-constraint-live.sql
-- APA    : index & constraint live yang belum ada di schema segar (27 index, 33 constraint) + VALIDATE 3 constraint NOT VALID yang di live sudah valid
-- KENAPA : bentuk live DB dev = acuan kerja backend Go; objek ini ada di live
--          (baseline deploy/Drizzle) tetapi belum ada di schema segar hasil porting.
-- SUMBER : fakta pg_dump live dev 127.0.0.1:15433 -> /tmp/live-schema.sql
--          dan diff sistematis /tmp/delta-fresh-vs-live.txt
-- IDEMPOTEN: CREATE INDEX IF NOT EXISTS; DO $$ cek pg_constraint; VALIDATE ter-guard pg_constraint.convalidated
-- CATATAN: definisi diambil verbatim dari pg_dump live
-- =====================================================================================


CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_bupot_faktur_pajak ON public.acc_bukti_potong USING btree (id_pur_faktur_pembelian, id_acc_pajak) WHERE ((id_pur_faktur_pembelian IS NOT NULL) AND (deleted_at IS NULL));

CREATE INDEX IF NOT EXISTS ix_acc_event_fktplg ON public.acc_event_log USING btree (id_sls_faktur_pelanggan, created_at) WHERE (id_sls_faktur_pelanggan IS NOT NULL);

CREATE INDEX IF NOT EXISTS ix_acc_event_fktpms ON public.acc_event_log USING btree (id_pur_faktur_pembelian, created_at) WHERE (id_pur_faktur_pembelian IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fpajak_normal_per_faktur ON public.acc_faktur_pajak USING btree (id_sls_faktur_pelanggan) WHERE (((jenis)::text = 'NORMAL'::text) AND (deleted_at IS NULL));

CREATE INDEX IF NOT EXISTS ix_acc_nota_faktur_pelanggan ON public.acc_nota_kredit USING btree (id_sls_faktur_pelanggan) WHERE (id_sls_faktur_pelanggan IS NOT NULL);

CREATE INDEX IF NOT EXISTS ix_acc_nota_faktur_pemasok ON public.acc_nota_kredit USING btree (id_pur_faktur_pembelian) WHERE (id_pur_faktur_pembelian IS NOT NULL);

CREATE INDEX IF NOT EXISTS ix_acc_alok_fktplg ON public.acc_pembayaran_alokasi USING btree (id_sls_faktur_pelanggan) WHERE (id_sls_faktur_pelanggan IS NOT NULL);

CREATE INDEX IF NOT EXISTS ix_acc_alok_fktpms ON public.acc_pembayaran_alokasi USING btree (id_pur_faktur_pembelian) WHERE (id_pur_faktur_pembelian IS NOT NULL);

CREATE INDEX IF NOT EXISTS core_menus_id_core_modules_idx ON public.core_menus USING btree (id_core_modules);

CREATE INDEX IF NOT EXISTS core_menus_parent_idx ON public.core_menus USING btree (parent);

CREATE UNIQUE INDEX IF NOT EXISTS core_roles_code_key ON public.core_roles USING btree (code);

CREATE INDEX IF NOT EXISTS core_roles_menus_id_core_menus_idx ON public.core_roles_menus USING btree (id_core_menus);

CREATE INDEX IF NOT EXISTS core_roles_menus_id_core_roles_idx ON public.core_roles_menus USING btree (id_core_roles);

CREATE UNIQUE INDEX IF NOT EXISTS core_roles_menus_pair_key ON public.core_roles_menus USING btree (id_core_menus, id_core_roles);

CREATE INDEX IF NOT EXISTS core_routes_id_core_modules_features_idx ON public.core_routes USING btree (id_core_modules_features);

CREATE UNIQUE INDEX IF NOT EXISTS core_routes_method_uri_key ON public.core_routes USING btree (method, uri_pattern);

CREATE INDEX IF NOT EXISTS core_routes_permission_code_idx ON public.core_routes USING btree (permission_code);

CREATE INDEX IF NOT EXISTS core_sessions_device_key_idx ON public.core_sessions USING btree (device_key);

CREATE INDEX IF NOT EXISTS core_sessions_id_core_users_idx ON public.core_sessions USING btree (id_core_users);

CREATE INDEX IF NOT EXISTS core_sessions_is_valid_idx ON public.core_sessions USING btree (is_valid) WHERE is_valid;

CREATE UNIQUE INDEX IF NOT EXISTS core_users_username_key ON public.core_users USING btree (username);

CREATE INDEX IF NOT EXISTS core_users_roles_id_core_roles_idx ON public.core_users_roles USING btree (id_core_roles);

CREATE INDEX IF NOT EXISTS core_users_roles_id_core_users_idx ON public.core_users_roles USING btree (id_core_users);

CREATE UNIQUE INDEX IF NOT EXISTS core_users_roles_pair_key ON public.core_users_roles USING btree (id_core_users, id_core_roles);

CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_gerakan_idempoten ON public.inv_gerakan_stok USING btree (id_inv_gerakan_header, id_inv_produk, entity_id_sumber) WHERE (deleted_at IS NULL);

CREATE INDEX IF NOT EXISTS ix_pur_kesepakatan_pemasok ON public.pur_kesepakatan USING btree (id_pur_pemasok) WHERE (deleted_at IS NULL);

CREATE INDEX IF NOT EXISTS ix_pur_pesanan_pemasok ON public.pur_pesanan USING btree (id_pur_pemasok) WHERE (deleted_at IS NULL);

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.acc_bukti_potong'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK ((((((id_pur_faktur_pembelian IS NOT NULL))::integer + ((id_acc_nota_kredit IS NOT NULL))::integer) + ((id_acc_entri_jurnal IS NOT NULL))::integer) = 1))$cdef$) THEN
    ALTER TABLE ONLY public.acc_bukti_potong ADD CONSTRAINT ck_acc_bupot_tepat_satu_dokumen CHECK ((((((id_pur_faktur_pembelian IS NOT NULL))::integer + ((id_acc_nota_kredit IS NOT NULL))::integer) + ((id_acc_entri_jurnal IS NOT NULL))::integer) = 1));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.acc_bukti_potong'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.acc_bukti_potong ADD CONSTRAINT fk_acc_bupot_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.acc_event_log'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK ((((((((((((((id_acc_entri_jurnal IS NOT NULL))::integer + ((id_sls_faktur_pelanggan IS NOT NULL))::integer) + ((id_pur_faktur_pembelian IS NOT NULL))::integer) + ((id_acc_nota_kredit IS NOT NULL))::integer) + ((id_acc_pembayaran IS NOT NULL))::integer) + ((id_acc_periode IS NOT NULL))::integer) + ((id_acc_rekonsiliasi_bank IS NOT NULL))::integer) + ((id_acc_faktur_pajak IS NOT NULL))::integer) + ((id_acc_bukti_potong IS NOT NULL))::integer) + ((id_acc_akun IS NOT NULL))::integer) + ((id_acc_pajak IS NOT NULL))::integer) = 1))$cdef$) THEN
    ALTER TABLE ONLY public.acc_event_log ADD CONSTRAINT ck_acc_event_tepat_satu_subjek CHECK ((((((((((((((id_acc_entri_jurnal IS NOT NULL))::integer + ((id_sls_faktur_pelanggan IS NOT NULL))::integer) + ((id_pur_faktur_pembelian IS NOT NULL))::integer) + ((id_acc_nota_kredit IS NOT NULL))::integer) + ((id_acc_pembayaran IS NOT NULL))::integer) + ((id_acc_periode IS NOT NULL))::integer) + ((id_acc_rekonsiliasi_bank IS NOT NULL))::integer) + ((id_acc_faktur_pajak IS NOT NULL))::integer) + ((id_acc_bukti_potong IS NOT NULL))::integer) + ((id_acc_akun IS NOT NULL))::integer) + ((id_acc_pajak IS NOT NULL))::integer) = 1));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.acc_model_rekonsiliasi'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE SET NULL$cdef$) THEN
    ALTER TABLE ONLY public.acc_model_rekonsiliasi ADD CONSTRAINT fk_acc_model_rkn_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.acc_nota_kredit'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK (((id_sls_faktur_pelanggan IS NULL) <> (id_pur_faktur_pembelian IS NULL)))$cdef$) THEN
    ALTER TABLE ONLY public.acc_nota_kredit ADD CONSTRAINT ck_acc_nota_tepat_satu_faktur CHECK (((id_sls_faktur_pelanggan IS NULL) <> (id_pur_faktur_pembelian IS NULL)));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.acc_pembayaran'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.acc_pembayaran ADD CONSTRAINT fk_acc_byr_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.acc_pembayaran_alokasi'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK (((id_sls_faktur_pelanggan IS NULL) <> (id_pur_faktur_pembelian IS NULL)))$cdef$) THEN
    ALTER TABLE ONLY public.acc_pembayaran_alokasi ADD CONSTRAINT ck_acc_alok_tepat_satu_faktur CHECK (((id_sls_faktur_pelanggan IS NULL) <> (id_pur_faktur_pembelian IS NULL)));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_menus'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_core_modules) REFERENCES core_modules(id) ON UPDATE CASCADE ON DELETE SET NULL$cdef$) THEN
    ALTER TABLE ONLY public.core_menus ADD CONSTRAINT core_menus_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES core_modules(id) ON UPDATE CASCADE ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_menus'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (parent) REFERENCES core_menus(id) ON UPDATE CASCADE ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.core_menus ADD CONSTRAINT core_menus_parent_fkey FOREIGN KEY (parent) REFERENCES core_menus(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_roles'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$UNIQUE (code)$cdef$) THEN
    ALTER TABLE ONLY public.core_roles ADD CONSTRAINT core_roles_code_key UNIQUE (code);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_roles_menus'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_core_menus) REFERENCES core_menus(id) ON UPDATE CASCADE ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.core_roles_menus ADD CONSTRAINT core_roles_menus_id_core_menus_fkey FOREIGN KEY (id_core_menus) REFERENCES core_menus(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_roles_menus'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_core_roles) REFERENCES core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.core_roles_menus ADD CONSTRAINT core_roles_menus_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_roles_menus'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$UNIQUE (id_core_menus, id_core_roles)$cdef$) THEN
    ALTER TABLE ONLY public.core_roles_menus ADD CONSTRAINT core_roles_menus_pair_key UNIQUE (id_core_menus, id_core_roles);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_routes'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_core_modules_features) REFERENCES core_modules_features(id) ON UPDATE CASCADE ON DELETE SET NULL$cdef$) THEN
    ALTER TABLE ONLY public.core_routes ADD CONSTRAINT core_routes_id_core_modules_features_fkey FOREIGN KEY (id_core_modules_features) REFERENCES core_modules_features(id) ON UPDATE CASCADE ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_routes'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$UNIQUE (method, uri_pattern)$cdef$) THEN
    ALTER TABLE ONLY public.core_routes ADD CONSTRAINT core_routes_method_uri_key UNIQUE (method, uri_pattern);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_sessions'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_core_users) REFERENCES core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.core_sessions ADD CONSTRAINT core_sessions_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_users'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK ((failed_login_attempts >= 0))$cdef$) THEN
    ALTER TABLE ONLY public.core_users ADD CONSTRAINT core_users_failed_login_attempts_check CHECK ((failed_login_attempts >= 0));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_users'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK (((username)::text = lower((username)::text)))$cdef$) THEN
    ALTER TABLE ONLY public.core_users ADD CONSTRAINT core_users_username_check CHECK (((username)::text = lower((username)::text)));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_users'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$UNIQUE (username)$cdef$) THEN
    ALTER TABLE ONLY public.core_users ADD CONSTRAINT core_users_username_key UNIQUE (username);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_users_roles'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_core_roles) REFERENCES core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.core_users_roles ADD CONSTRAINT core_users_roles_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_users_roles'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_core_users_assigned_by) REFERENCES core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.core_users_roles ADD CONSTRAINT core_users_roles_id_core_users_assigned_by_fkey FOREIGN KEY (id_core_users_assigned_by) REFERENCES core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_users_roles'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_core_users) REFERENCES core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.core_users_roles ADD CONSTRAINT core_users_roles_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.core_users_roles'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$UNIQUE (id_core_users, id_core_roles)$cdef$) THEN
    ALTER TABLE ONLY public.core_users_roles ADD CONSTRAINT core_users_roles_pair_key UNIQUE (id_core_users, id_core_roles);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_ecom_katalog_kategori_publik'
                 AND conrelid = 'public.ecom_katalog_online'::regclass AND NOT convalidated) THEN
    ALTER TABLE ONLY public.ecom_katalog_online VALIDATE CONSTRAINT ck_ecom_katalog_kategori_publik;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ecom_pesanan_web'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK ((biaya_layanan >= (0)::numeric))$cdef$) THEN
    ALTER TABLE ONLY public.ecom_pesanan_web ADD CONSTRAINT ecom_pesanan_web_biaya_layanan_check CHECK ((biaya_layanan >= (0)::numeric));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ecom_pesanan_web'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK ((poin_ditukar >= 0))$cdef$) THEN
    ALTER TABLE ONLY public.ecom_pesanan_web ADD CONSTRAINT ecom_pesanan_web_poin_ditukar_check CHECK ((poin_ditukar >= 0));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pos_kartu_poin_sls_pelanggan'
                 AND conrelid = 'public.pos_kartu_poin'::regclass AND NOT convalidated) THEN
    ALTER TABLE ONLY public.pos_kartu_poin VALIDATE CONSTRAINT fk_pos_kartu_poin_sls_pelanggan;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pos_pesanan_sls_pelanggan'
                 AND conrelid = 'public.pos_pesanan'::regclass AND NOT convalidated) THEN
    ALTER TABLE ONLY public.pos_pesanan VALIDATE CONSTRAINT fk_pos_pesanan_sls_pelanggan;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pur_kesepakatan'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$CHECK (((tipe <> 'BLANKET_ORDER'::pur_jenis_kesepakatan) OR (id_pur_pemasok IS NOT NULL)))$cdef$) THEN
    ALTER TABLE ONLY public.pur_kesepakatan ADD CONSTRAINT ck_pur_kesepakatan_blanket CHECK (((tipe <> 'BLANKET_ORDER'::pur_jenis_kesepakatan) OR (id_pur_pemasok IS NOT NULL)));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pur_kesepakatan'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.pur_kesepakatan ADD CONSTRAINT fk_pur_kesepakatan_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pur_pesanan'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_inv_gudang) REFERENCES inv_gudang(id) ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.pur_pesanan ADD CONSTRAINT fk_pur_pesanan_gudang FOREIGN KEY (id_inv_gudang) REFERENCES inv_gudang(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pur_pesanan'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.pur_pesanan ADD CONSTRAINT fk_pur_pesanan_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES pur_pemasok(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pur_retur'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_pur_pesanan) REFERENCES pur_pesanan(id) ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.pur_retur ADD CONSTRAINT fk_pur_retur_pesanan FOREIGN KEY (id_pur_pesanan) REFERENCES pur_pesanan(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.sls_promosi_aturan'::regclass
                 AND pg_get_constraintdef(oid) = $cdef$FOREIGN KEY (id_inv_produk_gratis) REFERENCES inv_produk(id) ON DELETE RESTRICT$cdef$) THEN
    ALTER TABLE ONLY public.sls_promosi_aturan ADD CONSTRAINT sls_promosi_aturan_id_inv_produk_gratis_fkey FOREIGN KEY (id_inv_produk_gratis) REFERENCES inv_produk(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd
