-- Query auth: core_login_audit — satu INSERT untuk login sukses & gagal.
-- fail_reason NULL saat sukses (login berhasil tanpa alasan gagal); enum
-- di-cast dari narg text agar param Go tetap pgtype.Text.

-- name: InsertLoginAudit :exec
INSERT INTO core_login_audit
  (id_core_users, username_tried, success, fail_reason, ip_address, user_agent, attempted_at)
VALUES ($1, $2, $3, sqlc.narg('fail_reason')::core_login_fail_reason, $4, $5, $6);
