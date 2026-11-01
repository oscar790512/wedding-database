import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite')

test('relay reservations survive replay, enforce privacy and share the SMTP quota', async () => {
  const db = await PGlite.create()
  try {
    await db.exec('CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE TABLE guests(id uuid PRIMARY KEY);')
    for (const name of ['20261026000000_wedding_email.sql', '20261028000000_retryable_email_claim.sql', '20261101000000_wedding_email_relay.sql']) {
      const sql = readFileSync(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8')
      await db.exec(sql)
      await db.exec(sql)
    }
    const sender = 'sender@gmail.com'
    const reserve = async (id, hash = 'a', limit = 450, interval = 0, account = sender) =>
      (await db.query('SELECT reserve_wedding_email_relay($1,$2,$3,$4,$5) AS result', [id, account, hash, limit, interval])).rows[0].result
    const id = randomUUID()
    const results = await Promise.all([reserve(id), reserve(id)])
    assert.equal(results.filter(r => r.state === 'claimed').length, 1)
    assert.equal(results.filter(r => r.status === 'unknown').length, 1)
    assert.equal((await db.query('SELECT count(*)::int AS n FROM wedding_email_relay_requests')).rows[0].n, 1)
    assert.equal((await reserve(id, 'tampered')).state, 'conflict')
    assert.equal((await reserve(id, 'a', 450, 0, 'other@gmail.com')).state, 'conflict')
    // Response loss after SMTP acceptance replays the persisted receipt, even over quota.
    await db.query("UPDATE wedding_email_relay_requests SET status='sent' WHERE id=$1", [id])
    assert.equal((await reserve(id, 'a', 0)).status, 'sent')
    assert.equal((await reserve(randomUUID(), 'a', 1)).state, 'quota')
    assert.equal((await reserve(randomUUID(), 'a', 450, 100)).state, 'wait')
    const guest = randomUUID(), batch = randomUUID()
    await db.query('INSERT INTO guests VALUES($1)', [guest])
    await db.query('SELECT enqueue_wedding_email($1,$2,$3,$4,$5,$6)', [batch, 'test', sender, 'admin', '{}', JSON.stringify([{id: guest, name: 'Synthetic', email: 'guest@example.com', checkin_token: 'test-only'}])])
    const claim = async (limit, interval = 0) => (await db.query('SELECT claim_wedding_email_v2($1,$2,$3,$4,$5) AS result', [batch, sender, limit, interval, randomUUID()])).rows[0].result
    assert.equal((await claim(1)).state, 'quota')
    assert.equal((await claim(450, 100)).state, 'wait')
    assert.equal((await claim(450)).state, 'claimed')
    assert.equal((await reserve(randomUUID(), 'a', 2)).state, 'quota')
    const failed = randomUUID()
    assert.equal((await reserve(failed)).state, 'claimed')
    await db.query("UPDATE wedding_email_relay_requests SET status='failed',reason='setup' WHERE id=$1", [failed])
    assert.equal((await reserve(failed)).status, 'failed')
    assert.equal((await reserve(failed)).reason, 'setup')
    const permissions = (await db.query("SELECT has_table_privilege('anon','wedding_email_relay_requests','SELECT') AS public_read, has_function_privilege('authenticated','reserve_wedding_email_relay(uuid,text,text,integer,double precision)','EXECUTE') AS public_call, has_function_privilege('service_role','reserve_wedding_email_relay(uuid,text,text,integer,double precision)','EXECUTE') AS server_call")).rows[0]
    assert.deepEqual(permissions, {public_read: false, public_call: false, server_call: true})
    const columns = (await db.query("SELECT column_name FROM information_schema.columns WHERE table_name='wedding_email_relay_requests'")).rows.map(row => row.column_name)
    assert.deepEqual(columns.sort(), ['id','sender','payload_hash','status','reason','started_at'].sort())
  } finally { await db.close() }
})
