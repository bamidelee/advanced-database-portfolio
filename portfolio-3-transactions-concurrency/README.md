# Portfolio 3: Transactions and Concurrency

This portfolio demonstrates how AquaFlow keeps its data correct when operations involve several tables, when they fail partway through, and when many users act at the same moment. It covers commit, rollback and savepoints; race conditions between vendors and drivers; the anomalies each isolation level allows; deadlocks; and a real lock-wait incident encountered while building Portfolio 1.

Every concurrency scenario was run as two real PostgreSQL sessions at the same time, and the evidence is a merged, timestamped timeline of what each session did.

## Files

| File | Description |
|---|---|
| `functions.sql` | `assign_trip()` and `complete_trip()`, the two multi-table business operations |
| `01-commit-rollback.sql` | Single-session demo of commit, automatic rollback, explicit rollback, savepoints and a business rule |
| `01-commit-rollback-output.txt` | Output of the above |
| `concurrency/run-race-demos.sh` | Runs scenarios 2 and 3 (race conditions) and the tanker guard migration |
| `concurrency/run-isolation-demos.sh` | Runs scenarios 4 and 5 (isolation levels) and 6 (deadlock) |
| `concurrency/demo-helpers.sql`, `session-header.sql` | Logging and timing utilities shared by every scenario, in a separate `demo` schema |
| `concurrency/0N-*.sql` | Setup, session and verification scripts for each scenario |
| `concurrency/03c-add-tanker-guard.sql` | Schema change adding a constraint against tanker double-booking |
| `concurrency/output/` | Timeline of every scenario |
| `screenshots/` | Selected evidence |

## How to Reproduce

From the repository root, with the `aquaflow-db` container running and the database seeded (Portfolio 2):

```bash
docker exec aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-3-transactions-concurrency/functions.sql

docker exec aquaflow-db psql -q -U postgres -d aquaflow -f /portfolio/portfolio-3-transactions-concurrency/01-commit-rollback.sql > portfolio-3-transactions-concurrency/01-commit-rollback-output.txt 2>&1

bash portfolio-3-transactions-concurrency/concurrency/run-race-demos.sh
bash portfolio-3-transactions-concurrency/concurrency/run-isolation-demos.sh
```

Each script selects or creates fresh data for every run, so all of them can be rerun.

## 1. Transactions as Business Operations

Two AquaFlow operations change several tables and must either complete entirely or not at all. They are implemented as PL/pgSQL functions in `functions.sql`. A function runs inside the caller's transaction, so if any statement within it fails, everything it changed is undone with the rest of the transaction.

**`complete_trip()`** runs when a driver confirms delivery: it marks the trip and request completed, records the status change, records the customer's payment, credits the vendor's earnings minus commission, and frees the tanker. If the payment cannot be recorded, a trip must never be left marked completed without a payment.

**`assign_trip()`** runs when a vendor accepts a job offer: it accepts the offer, creates the trip and its first status entry, marks the request assigned and the tanker busy. Before checking anything, it locks the request row and then the tanker row with `SELECT ... FOR UPDATE`, always in that order. It also enforces a rule identified as a known limitation in Portfolio 1: **a trip's driver must work for the vendor that owns the tanker**. No foreign key can express this, because both references are individually valid. The function rejects mismatched pairs.

### Demo 1 results (`01-commit-rollback-output.txt`)

| Test | What it shows | Outcome |
|---|---|---|
| 1. COMMIT | `complete_trip()` changes seven rows across six tables | All changes become permanent together |
| 2. Automatic rollback | The payment step fails on a duplicate gateway reference after steps 1 and 2 have already run | The trip remains `arrived` and the request `assigned`. The function's progress notices prove steps 1 and 2 executed, and the database undid them |
| 3. Explicit ROLLBACK | A refund is entered against the wrong customer, then abandoned | The refund is visible inside the transaction and gone after `ROLLBACK` |
| 4. SAVEPOINT | A delivery is completed, then an invalid rating (7) is submitted in the same transaction | `ROLLBACK TO SAVEPOINT` discards only the rating. The delivery and a corrected rating commit |
| 5. Business rule | `assign_trip()` is called with a driver from another vendor, then with the vendor's own driver | The first is refused, the second creates the trip |

Test 2 also shows a PostgreSQL behaviour worth noting: after an error, the transaction enters an aborted state and every further statement is refused, even `SELECT 1`, until the transaction is ended with `ROLLBACK`. This prevents an application from accidentally continuing with half-applied changes.

## 2. Method for Concurrency Scenarios

Race conditions only appear when transactions overlap, so each scenario starts two `psql` sessions at the same moment. Each session holds its transaction open at chosen points with `pg_sleep`, so the overlap happens the same way every run.

Each event is logged using `clock_timestamp()`, which returns the real time, rather than `now()`, which is fixed at the start of a transaction. `demo.try()` runs a statement, catches any error, and records whether it succeeded and how long it was blocked waiting for the other session. The runner merges both logs into one timeline ordered by elapsed time. A verification query then checks the outcome against the business rule.

The helpers live in a separate `demo` schema so the application schema is untouched. One design detail: the log function reads the scenario start time from a session setting instead of a table. Under SERIALIZABLE, any table read can be the point where PostgreSQL raises a serialization failure. An early version read the start time from a table, which caused the failure to be raised by the logging call itself and placed the error at the wrong point in the timeline.

## 3. Race Conditions

### Scenario 2: Two vendors accept the same request

| | Approach | Outcome |
|---|---|---|
| 2a | Plain SQL: read status, see `pending`, insert a trip | Vendor 2's insert **blocks for about a second** until Vendor 1 commits, then fails on `one_live_trip_per_request`. One trip is created |
| 2b | `assign_trip()` with `FOR UPDATE` | Vendor 2 waits on the row lock, then receives `Request ... is already assigned`. One trip is created |

Both sessions read `pending` in 2a, because neither could see the other's uncommitted work. The request was still protected, by the partial unique index designed in Portfolio 1. When one transaction inserts into a unique index while another has an uncommitted conflicting entry, PostgreSQL makes it wait for the other to finish. If the other commits, the insert fails; if it rolls back, the insert succeeds.

2b gives the same correct outcome with a better failure. A raw constraint violation is something the app has to interpret, while "already assigned" can be shown directly to the vendor. Under READ COMMITTED, when a `FOR UPDATE` wait ends, PostgreSQL re-reads the row as committed by the other transaction, which is why Vendor 2 sees the new status rather than its earlier snapshot.

### Scenario 3: One tanker accepted for two requests

| | Approach | Outcome |
|---|---|---|
| 3a | Plain SQL: read tanker, see `available`, create a trip | **Both commit. The tanker is double-booked** onto two live trips |
| 3b | `assign_trip()` with `FOR UPDATE` | Driver 2 waits for the tanker lock, then receives `Tanker ... is busy`. One live trip |
| 3c | Plain SQL again, after adding a guard index | Driver 2's insert blocks, then fails on `one_live_trip_per_tanker`. One live trip |

This was a genuine gap in the Portfolio 1 design. The schema prevented two live trips per *request*, but nothing prevented two live trips per *tanker*. In 3a, Driver 2's status update was blocked for a second by Driver 1's uncommitted update to the same tanker row, but once Driver 1 committed, Driver 2's update went ahead. It had already decided to proceed based on a stale read, which is a classic *check-then-act* race.

**The seed data had already fallen into this gap.** Before writing the fix, a check showed that dozens of tankers in the Portfolio 2 seed data were on two or three in-progress trips at once (the exact count is in `output/03c-add-tanker-guard.txt`). The seed generator assigned tankers to trips without checking availability, exactly like the careless code in 3a, and the schema allowed it.

The fix was applied in two layers:

1. **`assign_trip()`** locks the tanker before checking it, which handles the normal application path (3b).
2. **A partial unique index, `one_live_trip_per_tanker`**, on `trip (tanker_id) WHERE status IN ('assigned', 'en_route', 'arrived')`, makes the database refuse a second live trip for a tanker whatever code attempts it (3c).

The index could not be created while violations existed, so `03c-add-tanker-guard.sql` first resolves them in the same transaction. The earliest live trip on each tanker is kept, later ones are marked failed with the reason "Data cleanup: tanker was double-booked", and their requests return to `pending` to be offered to another tanker. Cleaning existing data before adding a constraint is a normal part of changing a live schema.

## 4. Isolation Levels

### Scenario 4: Vendor payout during a delivery

Finance reads a vendor's unpaid earnings, creates a payout for that total, and then marks those earnings as paid. Meanwhile, a driver completes a delivery for the same vendor, creating a new unpaid earning.

| Isolation level | Outcome |
|---|---|
| READ COMMITTED | **MISMATCH.** The payout amount covers the earnings that existed when Finance first looked, but the update marking earnings as paid also includes the new delivery. That earning is recorded as paid but was never paid out |
| REPEATABLE READ | **MATCH.** The payout and the earnings marked paid agree. The new earning stays unpaid for the next payout |

Under READ COMMITTED, each *statement* sees the latest committed data. Finance's total came from one statement, and the update, two seconds later, was a new statement that saw the driver's committed delivery. Under REPEATABLE READ, the whole *transaction* works from one snapshot taken at its first query, so the update cannot see rows committed after that point. The total and the update are consistent with each other.

This is the most costly anomaly in the portfolio, because it silently loses a vendor's money and no constraint can catch it: every individual row is valid. Payout runs should therefore use REPEATABLE READ.

### Scenario 5: Write skew

Business rule: **a vendor must always keep at least one active driver.** Two operations staff each check that the vendor has more than one active driver, then each takes a *different* driver off duty.

| Isolation level | Outcome |
|---|---|
| REPEATABLE READ | **Both commit. The vendor has no active driver** |
| SERIALIZABLE | Staff 2 commits. Staff 1's commit is refused: *could not serialize access due to read/write dependencies among transactions*. One driver remains active |

This shows that REPEATABLE READ is not enough for every rule. PostgreSQL's REPEATABLE READ is snapshot isolation: it stops a transaction seeing others' changes, and it stops two transactions updating the *same* row. Here, the two staff updated *different* rows, so there was no conflict to detect. Each decision was valid against its own snapshot, but together they broke the rule. This is called write skew.

SERIALIZABLE uses Serializable Snapshot Isolation. It also tracks what each transaction *read*. It noticed that each transaction's decision depended on data the other changed, meaning no serial order of the two could produce this outcome, and aborted one. The application must be prepared to retry a transaction that fails with SQLSTATE `40001`. On retry, Staff 1 would count one active driver and correctly refuse.

### Choosing isolation levels for AquaFlow

| Operation | Level | Reason |
|---|---|---|
| Accepting jobs, completing trips | READ COMMITTED with `FOR UPDATE` | The conflicts are on known rows, so explicit row locks are precise and cheap |
| Payout runs, financial reconciliation | REPEATABLE READ | Every statement must agree on one consistent view of the earnings |
| Rules spanning several rows (driver cover) | SERIALIZABLE with retry | No single row to lock, and only SERIALIZABLE detects write skew |

READ COMMITTED remains the default for everything else because stronger levels cost more: REPEATABLE READ and SERIALIZABLE can abort transactions that READ COMMITTED would let through, which requires retry logic in the application.

## 5. Deadlock

### Scenario 6

Two staff each update the same two tankers in one transaction, but in opposite orders.

| | Approach | Outcome |
|---|---|---|
| 6a | Staff 1 updates tanker A then B; Staff 2 updates B then A | **Deadlock.** Each holds one row and waits for the other's. After one second, PostgreSQL aborts Staff 1 with *deadlock detected*, and Staff 2 completes |
| 6b | Both lock both tankers first with `SELECT ... WHERE id IN (A, B) ORDER BY id FOR UPDATE` | No deadlock. Staff 2 waits until Staff 1 commits, then proceeds |

PostgreSQL does not try to prevent deadlocks. When a lock wait exceeds `deadlock_timeout` (one second by default), it checks for a cycle and aborts one transaction to break it. The other then continues. The verification query shows the database's `deadlocks` counter increasing.

The prevention is to always acquire locks in the same order. If every transaction locks lower IDs first, a cycle cannot form, and the worst outcome is a short wait. `assign_trip()` follows the same principle by always locking the request before the tanker.

## 6. Case Study: A Real Lock Wait

While capturing evidence for Portfolio 1, the evidence script stopped at its first step with no output and no error. It was rerun, with the same result.

**Diagnosis.** Querying `pg_stat_activity` from a separate session showed:

```
 pid |        state        | wait_event_type |                       query
-----+---------------------+-----------------+----------------------------------------------------
  84 | idle                | Client          | SELECT n.nspname as "Schema",  ...
 140 | idle in transaction | Client          | SELECT id, request_id, tanker_id, status, failure_
 187 | active              | Lock            | DROP TABLE IF EXISTS rating, vendor_earning, payou
 196 | active              | Lock            | DROP TABLE IF EXISTS rating, vendor_earning, payou
```

- **Session 140** was an earlier run of the constraint tests. It had opened a transaction and inserted test rows, then stopped at the terminal pager while displaying a result. It was still inside its transaction (`idle in transaction`), holding locks on the tables it had written to.
- **Sessions 187 and 196** were the two attempts to rerun the schema script. `DROP TABLE` needs an exclusive lock, so both were waiting (`wait_event_type = Lock`) for session 140 to finish, which it never would, because the process owning it was waiting for keyboard input.
- **Session 84** was an idle `psql` session that was not in a transaction and blocked nothing.

**Resolution.** The stuck sessions were ended with `pg_terminate_backend()`, which rolled back session 140's open transaction and released its locks. The schema then ran normally.

**Prevention.** The evidence script was changed to run with `lock_timeout = 10s`, so a blocked statement now fails with a clear error after ten seconds instead of waiting forever. The test script was also changed to disable the pager, removing the cause.

**Lesson.** A transaction left open holds its locks indefinitely, whether or not anything is happening in it. In a production system, `idle in transaction` sessions are a common cause of unexplained slowdowns, and PostgreSQL provides `idle_in_transaction_session_timeout` to end them automatically. Diagnosis relied on `pg_stat_activity`, which shows each session's state and what it is waiting for.

## Summary

| Problem | Where it appeared | Control mechanism |
|---|---|---|
| Partial failure of a multi-table operation | Payment failing mid-completion | Atomic transaction, automatic rollback |
| Partial undo of a transaction | Invalid rating alongside a valid delivery | `SAVEPOINT` / `ROLLBACK TO SAVEPOINT` |
| Rule beyond foreign keys | Driver from another vendor | Check inside `assign_trip()` |
| Two acceptances of one request | Scenario 2 | Partial unique index (Portfolio 1), plus `FOR UPDATE` for a clear error |
| Tanker double-booking | Scenario 3, and in the seed data | `FOR UPDATE` in `assign_trip()`, plus new partial unique index |
| Inconsistent read within a transaction | Payout (Scenario 4) | REPEATABLE READ |
| Write skew | Driver cover rule (Scenario 5) | SERIALIZABLE with retry |
| Deadlock | Opposite lock order (Scenario 6) | Consistent lock ordering |
| Lock held by an abandoned transaction | Real incident during Portfolio 1 | `lock_timeout`, `pg_stat_activity`, `pg_terminate_backend()` |

The broad lesson is that correctness under concurrency comes from layers. Constraints protect the data whatever code runs. Locks and transactions protect each operation's own logic. Isolation levels decide what each transaction is allowed to see. Each layer caught something the others could not.