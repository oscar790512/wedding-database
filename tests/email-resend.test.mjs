import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite')

test('explicit resends preserve accepted delivery history and atomically replace only the active recipient', async () => {
  const db = await PGlite.create()
  try {
    await db.exec('CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE TABLE guests(id uuid PRIMARY KEY);')
    for (const name of ['20261026000000_wedding_email.sql', '20261028000000_retryable_email_claim.sql', '20261101000000_wedding_email_relay.sql', '20261101010000_wedding_email_resend.sql']) {
      const sql = readFileSync(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8')
      await db.exec(sql)
      await db.exec(sql)
    }
    const guest = { id: randomUUID(), name: 'Synthetic Guest', email: 'typo@example.com', checkin_token: 'synthetic-qr' }
    const originalBatch = randomUUID(), resendBatch = randomUUID()
    await db.query('INSERT INTO guests VALUES($1)', [guest.id])
    const enqueue = async (batch, g) => db.query('SELECT enqueue_wedding_email($1,$2,$3,$4,$5,$6)', [batch, 'test', 'sender@gmail.com', 'admin', '{}', JSON.stringify([g])])
    await enqueue(originalBatch, guest)
    const original = (await db.query("UPDATE wedding_email_deliveries SET status='sent',attempted_at=now(),sent_at=now() RETURNING *")).rows[0]
    await db.query('INSERT INTO wedding_email_attempts(delivery_id,sender) VALUES($1,$2)', [original.id, 'sender@gmail.com'])
    const previous = (await db.query("SELECT jsonb_build_object('id',id,'batch_id',batch_id,'email',email,'status',status,'attempted_at',attempted_at,'sent_at',sent_at) AS snapshot FROM wedding_email_deliveries WHERE id=$1", [original.id])).rows[0].snapshot
    const corrected = { ...guest, email: 'corrected@example.com' }
    // Ordinary batch sends still cannot silently resend accepted recipients.
    await enqueue(randomUUID(), corrected)
    assert.equal((await db.query('SELECT count(*)::int AS n FROM wedding_email_deliveries')).rows[0].n, 1)
    const content = { subject: 'Reviewed resend', resend_of: previous }
    const resend = (batch, snapshot = previous, g = corrected) => db.query('SELECT enqueue_wedding_email_resend($1,$2,$3,$4,$5,$6,$7)', [batch, 'test', 'sender@gmail.com', 'admin', JSON.stringify({...content, resend_of: snapshot}), JSON.stringify(g), JSON.stringify(snapshot)])
    // Unknown/in-flight rows cannot be made resendable through this feature.
    for (const state of ['pending', 'sending', 'unknown', 'failed']) {
      await db.query('UPDATE wedding_email_deliveries SET status=$1 WHERE id=$2', [state, original.id])
      await assert.rejects(resend(resendBatch))
      assert.equal((await db.query('SELECT count(*)::int AS n FROM wedding_email_deliveries')).rows[0].n, 1)
    }
    await db.query("UPDATE wedding_email_deliveries SET status='sent' WHERE id=$1", [original.id])
    await assert.rejects(resend(resendBatch, {...previous, email: 'stale@example.com'}))
    await assert.rejects(resend(resendBatch, previous, {...corrected, id: randomUUID()}))
    await Promise.all([resend(resendBatch), resend(resendBatch)])
    const all = (await db.query('SELECT * FROM wedding_email_deliveries ORDER BY created_at,id')).rows
    assert.equal(all.length, 2)
    const saved = all.find(row => row.id === original.id), current = all.find(row => row.id !== original.id)
    assert.equal(saved.status, 'sent')
    assert.equal(saved.email, 'typo@example.com')
    assert.equal(saved.batch_id, originalBatch)
    assert.deepEqual(saved.sent_at, original.sent_at)
    assert.deepEqual(saved.attempted_at, original.attempted_at)
    assert.ok(saved.superseded_at)
    assert.equal(current.email, 'corrected@example.com')
    assert.equal(current.status, 'pending')
    assert.equal(current.batch_id, resendBatch)
    assert.equal(current.checkin_token, 'synthetic-qr')
    assert.equal((await db.query('SELECT count(*)::int AS n FROM wedding_email_deliveries WHERE superseded_at IS NULL')).rows[0].n, 1)
    // Another confirmation using the stale source cannot create another active delivery.
    await assert.rejects(resend(randomUUID()))
    await enqueue(randomUUID(), corrected)
    assert.equal((await db.query('SELECT count(*)::int AS n FROM wedding_email_deliveries')).rows[0].n, 2)
    assert.equal((await db.query('SELECT delivery_id FROM wedding_email_attempts')).rows[0].delivery_id, original.id)
    // The new delivery goes through the same claim worker/transport, retaining the corrected address.
    const claimed = (await db.query('SELECT claim_wedding_email_v2($1,$2,$3,$4,$5) AS result', [resendBatch, 'sender@gmail.com', 450, 0, randomUUID()])).rows[0].result
    assert.equal(claimed.state, 'claimed')
    assert.equal(claimed.delivery.email, 'corrected@example.com')
    assert.equal((await db.query('SELECT count(*)::int AS n FROM wedding_email_attempts')).rows[0].n, 2)
    // A failed new attempt can use ordinary retry without touching the accepted historical row.
    await db.query("UPDATE wedding_email_deliveries SET status='failed' WHERE id=$1", [current.id])
    const retryBatch = randomUUID()
    await enqueue(retryBatch, corrected)
    assert.equal((await db.query('SELECT batch_id FROM wedding_email_deliveries WHERE superseded_at IS NULL')).rows[0].batch_id, retryBatch)
    assert.equal((await db.query('SELECT count(*)::int AS n FROM wedding_email_deliveries')).rows[0].n, 2)
    assert.equal((await db.query('SELECT email FROM wedding_email_deliveries WHERE id=$1', [original.id])).rows[0].email, 'typo@example.com')
    const grants = (await db.query("SELECT has_function_privilege('authenticated','enqueue_wedding_email_resend(uuid,text,text,text,jsonb,jsonb,jsonb)','EXECUTE') AS browser_call, has_function_privilege('service_role','enqueue_wedding_email_resend(uuid,text,text,text,jsonb,jsonb,jsonb)','EXECUTE') AS server_call")).rows[0]
    assert.deepEqual(grants, {browser_call: false, server_call: true})
  } finally { await db.close() }
})
