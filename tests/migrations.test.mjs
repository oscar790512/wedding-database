// Optional local PostgreSQL/WASM check. CI also exercises the real Supabase CLI.
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
const moduleId = process.env.PGLITE_MODULE || '@electric-sql/pglite'
const { PGlite } = await import(moduleId)
const extensionId = name => process.env.PGLITE_MODULE
  ? new URL(`./contrib/${name}.js`, moduleId).href
  : `@electric-sql/pglite/contrib/${name}`
const { citext } = await import(extensionId('citext'))
const { pgcrypto } = await import(extensionId('pgcrypto'))
const read = relative => readFileSync(new URL(relative, import.meta.url), 'utf8')
const migrations = readdirSync(new URL('../supabase/migrations/', import.meta.url)).filter(name => name.endsWith('.sql')).sort()

for (const state of ['fresh', 'manually-applied-email']) {
  test(`versioned SQL supports ${state} databases and preserves existing deliveries`, async () => {
    const db = await PGlite.create({ extensions: { citext, pgcrypto } })
    try {
      await db.exec('CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;')
      if (state === 'manually-applied-email') {
        await db.exec(read('../schema.sql'))
        await db.exec(read('../supabase/migrations/20261026000000_wedding_email.sql'))
        await db.exec(read('./seed.sql'))
      }
      for (const name of migrations) await db.exec(read(`../supabase/migrations/${name}`))
      if (state === 'fresh') await db.exec(read('./seed.sql'))
      // Replaying idempotent adoption SQL must also preserve already-sent records.
      for (const name of migrations) await db.exec(read(`../supabase/migrations/${name}`))
      await db.exec(read('./assertions.sql'))
      assert.equal((await db.query('SELECT count(*)::int AS n FROM wedding_email_deliveries')).rows[0].n, 1)
    } finally { await db.close() }
  })
}
