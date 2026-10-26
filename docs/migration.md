# Migrating the single-owner database

The old database has unscoped tables. Startup refuses it unless an explicit legacy owner UUID is configured. The UUID must match the reserved, verified owner in libauth.

A single transaction adds account ownership to meals, attempts, receipts, settings, import IDs, cancellation tombstones and audit data. The existing provider key is decrypted with the preserved master key and reencrypted with the owner's UUID as authenticated data. An incorrect key aborts the migration; it never creates an empty replacement database.

Before applying it, online-backup the SQLite database and OAuth state off the host, preserve the master key, restore the copies, and verify integrity and decryption. Compare counts, entry hashes, dates, timestamps and exact decimal spending before and after migration. Repeat the migration on the restored copy to verify idempotency.

The legacy OAuth database stays separate. Existing unexpired grants are mapped only to the configured owner when used on the legacy host and with their original audience. New authorization grants use libauth. Do not redirect legacy API POST requests across hosts.

Rollback requires the old code and its pre-migration database together. Freeze writes and stop in-flight processing before switching the production schema; do not restore an old backup over newer writes.
