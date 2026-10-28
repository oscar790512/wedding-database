# Wedding database

資料庫結構的部署來源為 `supabase/migrations/`。GitHub Actions 先在獨立 PostgreSQL 驗證，再部署 Staging，成功後才部署 Production。正式環境原有的 GitHub Environment 審核規則仍適用。

## 自動部署

- push 到此 repo 的 `main`：測試 → Staging → Production。
- 手動執行 workflow，target 為 `staging`：測試 → Staging。
- 手動執行 workflow，target 為 `production`：測試 → Staging → Production。
- 各環境沿用既有 secrets：`SUPABASE_ACCESS_TOKEN`、`SUPABASE_PROJECT_REF`、`SUPABASE_DB_PASSWORD`。

兩個部署 job 都執行 `supabase db push --linked --yes`。CLI 以各資料庫的 `supabase_migrations.schema_migrations` 記錄已套用版本，只執行尚未套用的檔案。workflow 不會執行 `db reset`、清除歷史或自動 repair；遇到版本不一致會失敗並停止後續部署。

這個流程由 **DB repo** 觸發。單獨推 Frontend 或 Backend 不會執行 DB workflow。新增功能涉及資料表時，應先部署 DB repo 並確認 Production 成功，再部署依賴該結構的程式。

## 首次銜接既有環境

目前有三個版本：

1. `20260620000000_baseline.sql`：切換版本化部署時的既有 `schema.sql` 快照。保留原本可重複執行的建表、欄位檢查與資料轉換邏輯，供既有環境銜接與新環境初始化。
2. `20261004000000_add_table_number_to_table_settings.sql`：原本桌號 migration，移至標準目錄與版本格式。
3. `20261026000000_wedding_email.sql`：Email 批次、寄送紀錄、嘗試紀錄與兩個排程函式。

已經在 SQL Editor 手動建立 Email 表的測試環境，初次 `db push` 會以 `IF NOT EXISTS` 與 `CREATE OR REPLACE FUNCTION` 銜接並寫入版本歷史；保留既有資料和寄送結果。尚未建立的正式環境則會自動新增。之後重複部署會略過已記錄的版本。

Backend repo 內原本的 Email SQL 暫留作相容文件／測試來源；之後資料庫變更以本 repo 的 migration 為準。

`schema.sql` 留作切換時的參考快照，不再由部署流程直接執行。不要修改已發布的 migration；後續變更新增一個版本即可，不需手動複製 SQL 到 Dashboard。

## 新增資料庫變更

```sh
supabase migration new describe_the_change
# 編輯產生的 supabase/migrations/<timestamp>_describe_the_change.sql
```

提交新檔後，透過此 repo 的 `main` 部署。每個環境都會獨立追蹤版本。建立新資料表時，請同時設定 RLS 與最小必要權限。

SMTP 帳號與 Google 應用程式密碼仍是 Backend 的環境設定，不會由資料庫 migration 建立。

## 驗證

CI 的兩組測試使用一次性的 PostgreSQL 17，實際執行 Supabase CLI：

- 空資料庫初始化所有 migration。
- 模擬既有 `schema.sql` 與已手動套用 Email SQL 的環境。
- 兩組都重跑 `db push`，檢查版本只記錄一次。
- 確認 Email 表、函式、RLS、角色權限及舊桌號欄位。
- 保留已寄送紀錄、QR token、模板快照和寄送嘗試；測試不寄信。

可選的本機 SQL 回歸測試使用 PGlite，涵蓋上述兩種初始結構及重複 SQL 套用的相容性：

```sh
npm install --prefix /tmp/wedding-db-tests @electric-sql/pglite
PGLITE_MODULE=file:///tmp/wedding-db-tests/node_modules/@electric-sql/pglite/dist/index.js node --test tests/migrations.test.mjs
```

本機測試不連 Supabase，也不使用正式資料。CLI 的真實版本歷史行為由 GitHub Actions PostgreSQL 測試驗證。

參考：[Supabase Database Migrations](https://supabase.com/docs/guides/deployment/database-migrations)、[CLI db push](https://supabase.com/docs/reference/cli/supabase-db-push)。
