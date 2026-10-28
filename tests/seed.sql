-- Synthetic fixtures for disposable test databases only.
INSERT INTO guests(id, name, phone, status, email, checkin_token)
VALUES ('00000000-0000-4000-8000-000000000001', 'Migration fixture', '0000000000', 'attend', 'guest@example.invalid', 'test-only-qr');
INSERT INTO wedding_email_batches(id, campaign, sender, created_by, content)
VALUES ('10000000-0000-4000-8000-000000000001', 'migration-test', 'sender@example.invalid', 'test', '{"subject":"Original reviewed subject"}');
INSERT INTO wedding_email_deliveries(id, batch_id, campaign, guest_id, name, email, checkin_token, status, sent_at)
VALUES ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'migration-test', '00000000-0000-4000-8000-000000000001', 'Migration fixture', 'guest@example.invalid', 'test-only-qr', 'sent', '2026-10-26T00:00:00Z');
INSERT INTO wedding_email_attempts(delivery_id, sender, started_at)
VALUES ('20000000-0000-4000-8000-000000000001', 'sender@example.invalid', '2026-10-26T00:00:00Z');
