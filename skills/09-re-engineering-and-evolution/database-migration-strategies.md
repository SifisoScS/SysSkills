---
name: Database Migration Strategies
slug: database-migration-strategies
category: 09-re-engineering-and-evolution
proficiency: advanced
description: >
  Execute database schema changes safely in production without downtime.
  Covers expand-contract pattern, online DDL, zero-downtime column
  renaming, large table backfills, flyway/liquibase versioning, shadow
  tables, blue-green database cutovers, and CI/CD migration gates.
tags:
  - database-migrations
  - schema-evolution
  - zero-downtime
  - expand-contract
  - online-ddl
  - flyway
  - liquibase
  - backfill
  - blue-green
status: published
---

## Principles

### The Core Problem
Deploying a schema change and application code simultaneously risks downtime: the old code runs against the new schema (or vice versa) during a rolling deployment. The solution is to **decouple schema changes from application changes**.

### Expand-Contract (Parallel Change) Pattern
The safest approach for zero-downtime migrations — three distinct phases:

```
Phase 1 — EXPAND (additive only, backward compatible):
  → Add new column/table (nullable or with default)
  → Old code ignores the new column; new code writes to both old + new

Phase 2 — MIGRATE DATA:
  → Backfill existing rows to populate the new column/table
  → Done in batches to avoid long-running locks

Phase 3 — CONTRACT (remove old):
  → Deploy new code that reads only from new column/table
  → Remove old column/table after old code is fully deployed
```

**Key rule**: never perform Phase 3 until old code is confirmed gone from all instances.

### Lock Danger Zones
These DDL operations take **full table locks** and block all reads/writes:
- `ADD COLUMN` with a non-null default (PostgreSQL < 11)
- `DROP COLUMN` (PostgreSQL marks column as dropped; vacuumed away later)
- `ALTER COLUMN TYPE` (rewrites the table)
- `ADD CONSTRAINT` without `NOT VALID` (validates all existing rows inline)
- `CREATE INDEX` without `CONCURRENTLY`

Use the safe alternatives shown in the patterns below.

### Migration Versioning Rules
1. **Migrations are append-only** — never modify a committed migration file
2. **Every migration must be reversible** — write the `down` migration at the same time
3. **Migrations run in CI** before the deploy — catch failures before production
4. **One change per migration file** — small, targeted, independently reversible
5. **Name migrations descriptively**: `V42__add_payment_gateway_ref_column.sql`

---

## Implementation Patterns

### Pattern 1 — Safe PostgreSQL DDL (Online Operations)
```sql
-- ─── ADD COLUMN safely ────────────────────────────────────────────────────────

-- WRONG: blocks table in PostgreSQL < 11 (full table rewrite with default)
ALTER TABLE payments ADD COLUMN gateway_ref TEXT NOT NULL DEFAULT '';

-- RIGHT: add nullable first, backfill, then add constraint
ALTER TABLE payments ADD COLUMN gateway_ref TEXT;        -- instant; no lock
-- ... backfill (see Pattern 2) ...
ALTER TABLE payments ALTER COLUMN gateway_ref SET NOT NULL;  -- fast if no NULLs remain

-- ─── ADD INDEX safely ─────────────────────────────────────────────────────────

-- WRONG: locks table for minutes on large tables
CREATE INDEX idx_payments_account_id ON payments(account_id);

-- RIGHT: CONCURRENTLY — no lock; takes longer but safe in production
CREATE INDEX CONCURRENTLY idx_payments_account_id ON payments(account_id);

-- If the concurrent index build fails (e.g., connection drop), it leaves an INVALID index:
-- Check for and clean up invalid indexes:
SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_index i ON c.oid = i.indexrelid
    WHERE c.relname = pg_indexes.indexname AND i.indisvalid
  );
-- Then: DROP INDEX CONCURRENTLY idx_payments_account_id; and re-run

-- ─── DROP COLUMN safely (expand-contract Phase 3) ────────────────────────────

-- Only after all code reading/writing old column is fully deployed out
-- PostgreSQL marks the column dropped instantly (no rewrite); space reclaimed by VACUUM
ALTER TABLE payments DROP COLUMN old_status;

-- ─── RENAME COLUMN safely (via expand-contract) ───────────────────────────────

-- Direct rename: ALTER TABLE payments RENAME COLUMN status TO payment_status;
-- This is instant BUT will break code still reading 'status' during rolling deploy

-- Safe expand-contract rename sequence:
-- Phase 1: add new column, write to both
ALTER TABLE payments ADD COLUMN payment_status TEXT;
-- ... deploy code that reads old, writes both ...

-- Phase 2: backfill
UPDATE payments SET payment_status = status WHERE payment_status IS NULL;

-- Phase 3: switch reads to new, then drop old
-- ... deploy code that reads new column only ...
ALTER TABLE payments DROP COLUMN status;

-- ─── ALTER COLUMN TYPE safely ────────────────────────────────────────────────

-- WRONG: full table rewrite (hours on large table)
ALTER TABLE payments ALTER COLUMN amount TYPE NUMERIC(12,2);

-- RIGHT: add new column, backfill, switch, drop old (expand-contract)
ALTER TABLE payments ADD COLUMN amount_decimal NUMERIC(12,2);
UPDATE payments SET amount_decimal = amount::NUMERIC(12,2)
  WHERE amount_decimal IS NULL;
-- deploy code writing to both columns
-- deploy code reading new column only
ALTER TABLE payments DROP COLUMN amount;
ALTER TABLE payments RENAME COLUMN amount_decimal TO amount;

-- ─── ADD CONSTRAINT safely ────────────────────────────────────────────────────

-- WRONG: validates all rows inline — long lock on large table
ALTER TABLE payments ADD CONSTRAINT chk_positive_amount CHECK (amount > 0);

-- RIGHT: add NOT VALID first (skips existing rows), then validate separately
ALTER TABLE payments
  ADD CONSTRAINT chk_positive_amount CHECK (amount > 0) NOT VALID;

-- This can run as a separate migration after all new rows are valid:
ALTER TABLE payments VALIDATE CONSTRAINT chk_positive_amount;
-- VALIDATE takes ShareUpdateExclusiveLock — allows reads/writes, blocks DDL only
```

### Pattern 2 — Large Table Backfill (Batched, Production-Safe)
```sql
-- Backfilling 100M rows inline blocks the table.
-- Process in small batches with a sleep between each to avoid replication lag.

-- ─── PostgreSQL batched backfill ──────────────────────────────────────────────

DO $$
DECLARE
  batch_size  INT := 5000;
  last_id     BIGINT := 0;
  max_id      BIGINT;
  rows_updated INT;
BEGIN
  SELECT MAX(id) INTO max_id FROM payments;

  LOOP
    UPDATE payments
    SET payment_status = status
    WHERE id > last_id
      AND id <= last_id + batch_size
      AND payment_status IS NULL;

    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    last_id := last_id + batch_size;

    RAISE NOTICE 'Backfilled up to id %, rows updated: %', last_id, rows_updated;

    EXIT WHEN last_id > max_id;
    PERFORM pg_sleep(0.1);   -- 100ms pause to ease replica lag
  END LOOP;

  RAISE NOTICE 'Backfill complete.';
END $$;
```

```go
// Go batched backfill service — runs as a Kubernetes Job
// Safer than a SQL DO block: can be paused, monitored, and restarted

package backfill

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"time"
)

type PaymentStatusBackfill struct {
	db     *sql.DB
	logger *slog.Logger
}

func (b *PaymentStatusBackfill) Run(ctx context.Context) error {
	const batchSize = 5000
	const pauseBetweenBatches = 100 * time.Millisecond

	var lastID int64 = 0
	var totalUpdated int64

	for {
		select {
		case <-ctx.Done():
			b.logger.Info("backfill interrupted", "total_updated", totalUpdated)
			return ctx.Err()
		default:
		}

		result, err := b.db.ExecContext(ctx, `
			UPDATE payments
			SET payment_status = status
			WHERE id > $1
			  AND id <= $1 + $2
			  AND payment_status IS NULL`,
			lastID, batchSize,
		)
		if err != nil {
			return fmt.Errorf("batch update at id %d: %w", lastID, err)
		}

		rowsAffected, _ := result.RowsAffected()
		totalUpdated += rowsAffected
		lastID += batchSize

		b.logger.Info("batch complete",
			"last_id", lastID,
			"rows_this_batch", rowsAffected,
			"total_updated", totalUpdated,
		)

		// Check if we've processed all rows
		var remaining int64
		err = b.db.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM payments WHERE payment_status IS NULL`,
		).Scan(&remaining)
		if err != nil {
			return err
		}
		if remaining == 0 {
			b.logger.Info("backfill complete", "total_updated", totalUpdated)
			return nil
		}

		time.Sleep(pauseBetweenBatches)
	}
}
```

### Pattern 3 — Flyway Migration Files
```
db/migrations/
├── V1__create_payments_table.sql
├── V2__add_account_id_index.sql
├── V3__add_gateway_ref_column.sql           ← expand phase
├── V4__backfill_gateway_ref.sql             ← backfill phase
├── V5__set_gateway_ref_not_null.sql         ← contract phase
└── V6__drop_old_status_column.sql
```

```sql
-- V3__add_gateway_ref_column.sql (expand — additive, safe)
ALTER TABLE payments ADD COLUMN gateway_ref TEXT;
CREATE INDEX CONCURRENTLY idx_payments_gateway_ref ON payments(gateway_ref)
  WHERE gateway_ref IS NOT NULL;

-- V4__backfill_gateway_ref.sql (data migration — idempotent)
-- Idempotency: WHERE gateway_ref IS NULL ensures safe re-run
UPDATE payments
SET gateway_ref = external_id   -- old column name
WHERE gateway_ref IS NULL
  AND external_id IS NOT NULL;

-- V5__set_gateway_ref_not_null.sql (constraint — after backfill verified)
-- Add NOT VALID first to avoid locking on large table
ALTER TABLE payments
  ADD CONSTRAINT chk_gateway_ref_not_empty
  CHECK (gateway_ref IS NOT NULL AND gateway_ref != '') NOT VALID;

-- Validate in next migration or same one (separate transaction recommended)
ALTER TABLE payments VALIDATE CONSTRAINT chk_gateway_ref_not_empty;

-- V6__drop_old_status_column.sql (contract — only after old code gone)
ALTER TABLE payments DROP COLUMN external_id;
```

```yaml
# flyway.conf — Flyway configuration
flyway.url=jdbc:postgresql://${DB_HOST}:5432/${DB_NAME}
flyway.user=${DB_USER}
flyway.password=${DB_PASSWORD}
flyway.locations=classpath:db/migrations
flyway.validateOnMigrate=true
flyway.outOfOrder=false
flyway.baselineOnMigrate=false
flyway.lockRetryCount=10      # retry acquiring migration lock for rolling deploys
flyway.connectRetries=5
```

### Pattern 4 — GitHub Actions Migration Gate
```yaml
# .github/workflows/migrate.yml
# Runs migrations in CI before deploying application code

name: Database Migration

on:
  push:
    branches: [main]
    paths:
      - 'db/migrations/**'
      - '.github/workflows/migrate.yml'

jobs:
  validate-migrations:
    name: Validate migrations (dry run)
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_DB: payments_test
          POSTGRES_USER: payments
          POSTGRES_PASSWORD: test
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Install Flyway CLI
        run: |
          curl -L https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/10.10.0/flyway-commandline-10.10.0-linux-x64.tar.gz \
            | tar xz --strip=1 -C /usr/local/bin flyway-10.10.0/flyway
          chmod +x /usr/local/bin/flyway

      - name: Validate migration scripts
        run: |
          flyway \
            -url="jdbc:postgresql://localhost:5432/payments_test" \
            -user=payments \
            -password=test \
            -locations="filesystem:db/migrations" \
            validate

      - name: Run migrations against test database
        run: |
          flyway \
            -url="jdbc:postgresql://localhost:5432/payments_test" \
            -user=payments \
            -password=test \
            -locations="filesystem:db/migrations" \
            migrate

      - name: Verify schema state
        run: |
          flyway \
            -url="jdbc:postgresql://localhost:5432/payments_test" \
            -user=payments \
            -password=test \
            -locations="filesystem:db/migrations" \
            info

  deploy-migrations:
    name: Apply migrations to staging
    runs-on: ubuntu-latest
    needs: validate-migrations
    environment: staging
    steps:
      - uses: actions/checkout@v4

      - name: Run migrations (staging)
        env:
          DB_URL: ${{ secrets.STAGING_DB_URL }}
        run: |
          flyway \
            -url="${DB_URL}" \
            -locations="filesystem:db/migrations" \
            migrate

      # Application deploy happens AFTER migration completes successfully
      - name: Trigger application deploy
        run: echo "Migrations complete — triggering app deploy"
        # In practice: call your CD system (ArgoCD sync, Helm upgrade, etc.)
```

### Pattern 5 — Shadow Table for Zero-Downtime Type Migration
```sql
-- Scenario: changing payments.user_id from INTEGER to UUID
-- Too risky to do in-place on a large table; use shadow table approach

-- Phase 1: create shadow table with new schema
CREATE TABLE payments_v2 (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  legacy_id   BIGINT UNIQUE,          -- maps old PK → new for dual-write period
  user_id     UUID NOT NULL,
  amount      NUMERIC(12,2) NOT NULL,
  status      TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Phase 2: dual-write trigger on old table → keeps shadow in sync
CREATE OR REPLACE FUNCTION sync_payment_to_v2()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO payments_v2 (legacy_id, user_id, amount, status, created_at)
    VALUES (
      NEW.id,
      NEW.user_id::UUID,   -- requires user_id to be castable
      NEW.amount,
      NEW.status,
      NEW.created_at
    )
    ON CONFLICT (legacy_id) DO NOTHING;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE payments_v2
    SET status = NEW.status,
        amount = NEW.amount
    WHERE legacy_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_payments_v2
AFTER INSERT OR UPDATE ON payments
FOR EACH ROW EXECUTE FUNCTION sync_payment_to_v2();

-- Phase 3: backfill historical rows (before trigger was added)
INSERT INTO payments_v2 (legacy_id, user_id, amount, status, created_at)
SELECT id, user_id::UUID, amount, status, created_at
FROM payments
WHERE id NOT IN (SELECT legacy_id FROM payments_v2 WHERE legacy_id IS NOT NULL)
ON CONFLICT (legacy_id) DO NOTHING;

-- Phase 4: verify row counts match
SELECT
  (SELECT COUNT(*) FROM payments)    AS old_count,
  (SELECT COUNT(*) FROM payments_v2) AS new_count;

-- Phase 5: cutover — rename tables atomically (brief exclusive lock, ~1ms)
BEGIN;
  ALTER TABLE payments    RENAME TO payments_old;
  ALTER TABLE payments_v2 RENAME TO payments;
  -- Rename indexes, sequences, constraints as needed
COMMIT;

-- Phase 6: drop old table and trigger after confirming cutover
DROP TRIGGER trg_sync_payments_v2 ON payments_old;
DROP TABLE payments_old;
```

### Pattern 6 — Migration Runbook & Rollback Plan
```markdown
# Migration Runbook: V42 — Rename user_id Column

## Pre-migration checklist
- [ ] Migration tested in staging with production-size dataset
- [ ] Backfill time estimated: ~15 min for 50M rows at 5K/batch
- [ ] Rollback script tested and verified
- [ ] Monitoring dashboards open: error rate, p99 latency, replication lag
- [ ] On-call engineer available during migration window
- [ ] Feature flag `payments_use_new_user_id` ready to disable if needed

## Migration steps (with estimated times)
1. [5m] Apply V42__add_user_uuid_column.sql (expand) — additive, no downtime
2. [20m] Run backfill job `kubectl apply -f k8s/backfill-user-uuid-job.yaml`
   - Monitor: `kubectl logs -f job/backfill-user-uuid`
   - Stop signal: `kubectl delete job/backfill-user-uuid`
3. [5m] Apply V43__set_user_uuid_not_null.sql — fast if all rows backfilled
4. [10m] Deploy app v2.5.0 (reads user_uuid, writes both columns)
5. [24h] Monitor — allow one full day before phase 3
6. [5m] Apply V44__drop_old_user_id_column.sql (contract)

## Monitoring thresholds during migration
- Error rate spike > 0.5%: pause migration, investigate
- p99 latency > 2× baseline: pause migration
- Replication lag > 30s: pause backfill (reduce batch size or increase sleep)

## Rollback procedure
### If V42 needs rollback (expand phase):
  ALTER TABLE payments DROP COLUMN user_uuid;  -- instant
  DROP INDEX CONCURRENTLY idx_payments_user_uuid;

### If backfill is stuck or causing lag:
  kubectl delete job/backfill-user-uuid       # stop job
  # Resume later with smaller batch size: BATCH_SIZE=1000

### If V43 (NOT NULL constraint) fails:
  ALTER TABLE payments DROP CONSTRAINT chk_user_uuid_not_null;
  # Investigate nulls: SELECT COUNT(*) FROM payments WHERE user_uuid IS NULL;

### If app v2.5.0 has bugs:
  # Roll back app to v2.4.x — it reads old column, ignores user_uuid
  # V42 schema is backward compatible; old code still works

## Post-migration verification
SELECT
  COUNT(*) FILTER (WHERE user_uuid IS NULL) AS null_count,
  COUNT(*) AS total
FROM payments;
-- Expected: null_count = 0
```

---

## Anti-Patterns

### 1. Deploying Schema Change and Code Simultaneously
Deploying a `DROP COLUMN` and the new code in the same release. During a rolling deploy, old pods still run against the schema with the column dropped.

**Fix**: always separate schema changes from application deploys. Schema change first (backward compatible), then app deploy, then cleanup.

### 2. `CREATE INDEX` Without `CONCURRENTLY`
On a 50M-row table, `CREATE INDEX` holds an exclusive lock for minutes — blocking all reads and writes.

**Fix**: always use `CREATE INDEX CONCURRENTLY`. It takes longer but never blocks production traffic.

### 3. Modifying Committed Migration Files
Changing a migration file that has already run in any environment. The migration tool detects the checksum mismatch and refuses to run, blocking deploys.

**Fix**: create a new migration to amend the previous change. Migration history is append-only.

### 4. Unbatched Backfills
`UPDATE payments SET new_col = old_col` on 100M rows takes exclusive row locks for the entire duration and causes replication lag spikes.

**Fix**: batch in 1K–10K row chunks with a short sleep between batches.

### 5. Not Testing the Down Migration
Teams write up migrations but never test the rollback. When they need to roll back in production, the down script is broken or missing.

**Fix**: every migration PR must include a tested down migration. CI runs both up and down migrations against a test database.

### 6. Skipping Migration in CI
Teams apply migrations manually to staging and production but don't run them in CI. Schema changes that break queries aren't caught until deploy.

**Fix**: run migrations automatically in CI against a fresh test database on every PR that touches `db/migrations/`.

---

## Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| Add nullable column | `ALTER TABLE ADD COLUMN` — instant, no lock, safe anytime |
| Add non-null column with default (PostgreSQL 11+) | Safe — stored as metadata, no rewrite |
| Add non-null column with default (PostgreSQL < 11) | Add nullable → backfill → set NOT NULL |
| Rename column | Expand-contract: add new → backfill → switch reads → drop old |
| Change column type | Expand-contract: add new → backfill → switch → drop old |
| Create index on large table | `CREATE INDEX CONCURRENTLY` — never blocking |
| Add foreign key constraint | `ADD CONSTRAINT ... NOT VALID` → `VALIDATE CONSTRAINT` |
| Drop column | Verify no code reads it → `ALTER TABLE DROP COLUMN` |
| Migrate to new table structure | Shadow table + dual-write + atomic rename |
| Backfill 100M+ rows | Batched Go/Python job with progress tracking and restart capability |
| Emergency rollback needed | Feature flag to disable new code path; rollback is separate migration |
| Multi-service schema change | Own the schema in one service; expose via API — never share DB across services |

---

## Proficiency Levels

### Novice
- Understands that schema changes can cause downtime
- Knows `CREATE INDEX CONCURRENTLY` exists and why it matters
- Can write a simple Flyway migration file and run it

### Intermediate
- Applies the expand-contract pattern for column renames and type changes
- Writes batched backfill scripts that avoid replication lag
- Adds the `NOT VALID` / `VALIDATE CONSTRAINT` two-step for large tables
- Integrates migrations into CI pipelines

### Advanced
- Designs migrations for tables with hundreds of millions of rows
- Implements shadow table pattern for structural schema migrations
- Writes comprehensive runbooks including rollback procedures
- Orchestrates multi-phase migrations across multiple app deploys
- Detects and cleans up invalid indexes left by failed concurrent builds

### Expert
- Designs zero-downtime migration strategies for globally distributed databases
- Applies online schema change tools (pt-online-schema-change, gh-ost for MySQL; pg_repack for PostgreSQL) for table rewrites without downtime
- Coordinates schema migrations across microservices that share data via events
- Builds migration observability: tracks migration duration, replication lag impact, and lock wait times in Prometheus

---

## AI Prompts

1. **Migration review**: "Review this database migration for safety: `ALTER TABLE payments ADD COLUMN user_uuid UUID NOT NULL DEFAULT gen_random_uuid()`. Is it safe to run on a 50M-row table in production? What could go wrong?"

2. **Expand-contract plan**: "I need to rename the `user_id` column (INTEGER) to `user_uuid` (UUID) in the payments table with 80M rows and no downtime. Give me the full expand-contract migration plan with SQL for each phase."

3. **Backfill design**: "Design a batched backfill for populating `payments.user_uuid` from `users.uuid` where `payments.user_id = users.id`. The table has 100M rows. How should I handle failures, restarts, and replication lag monitoring?"

4. **Lock analysis**: "Which of these DDL statements will take a full table lock and for how long on a 200M-row table? Suggest safe alternatives for each."

5. **Runbook**: "Write a migration runbook for adding a NOT NULL `gateway_ref` column to the payments table. Include pre-migration checklist, step-by-step procedure, monitoring thresholds, and rollback plan."

---

## References

- PostgreSQL documentation — `ALTER TABLE`, `CREATE INDEX CONCURRENTLY`, lock types
- Flyway documentation — flywaydb.org — versioned migrations, checksums, repair
- Liquibase documentation — liquibase.org — XML/YAML/SQL changeset format
- Brandur Leach — *Zero-downtime Postgres migrations* (brandur.org)
- GitHub Engineering Blog — *gh-ost: GitHub's online schema migration tool for MySQL*
- pg_repack — github.com/reorg/pg_repack — online table rebuilds for PostgreSQL
- `pt-online-schema-change` — Percona Toolkit for MySQL online schema changes
- Ondřej Bouda — *Safe PostgreSQL Schema Migrations* (pgconf.eu)
