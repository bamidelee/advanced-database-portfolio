# Portfolio 2: Query Processing and Optimisation

This portfolio measures how PostgreSQL executes seven queries that the AquaFlow apps and staff run regularly, identifies why the slow ones are slow by reading their execution plans, and improves them with targeted indexes and one query rewrite. All measurements were taken on the schema from Portfolio 1, filled with about two years of generated operating data.

## Files

| File | Description |
|---|---|
| `seed.sql` | Generates realistic data at volume entirely inside PostgreSQL |
| `explain.sql` | The seven business queries, each run with `EXPLAIN (ANALYZE, BUFFERS)` |
| `indexes.sql` | The seven performance indexes, each justified against a specific query |
| `drop-indexes.sql` | Removes the indexes to restore the "before" state |
| `explain-before.txt` | Full execution plans before indexing |
| `explain-after.txt` | Full execution plans after indexing |
| `screenshots/` | Seed summary and index size report |

## How to Reproduce

From the repository root, with the `aquaflow-db` container running and the Portfolio 1 schema applied:

```bash
# 1. Generate data (about 80 seconds)
docker exec -it aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-2-query-optimisation/seed.sql

# 2. Measure without indexes
docker exec aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-2-query-optimisation/explain.sql > portfolio-2-query-optimisation/explain-before.txt 2>&1

# 3. Add indexes
docker exec -it aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-2-query-optimisation/indexes.sql

# 4. Measure again
docker exec aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-2-query-optimisation/explain.sql > portfolio-2-query-optimisation/explain-after.txt 2>&1
```

## Test Data

Indexes only make a measurable difference once tables are large, so `seed.sql` generates about two years of activity for a growing platform:

| Table | Rows |
|---|---|
| trip_status_history | 1,155,397 |
| job_offer | 618,956 |
| delivery_request | 300,000 |
| trip | 293,894 |
| payment, vendor_earning | 274,184 each |
| rating | 164,805 |
| address | 67,467 |
| customer | 50,000 |
| payout | 8,913 |
| refund | 3,994 |
| tanker, driver, vendor | 1,236 / 1,005 / 400 |

The generator is written as set-based `INSERT ... SELECT` statements using `generate_series()`, which is far faster than inserting rows one at a time from an application. Each request's outcome (completed, cancelled, retried after a failed trip, or still in progress) is decided first in a temporary plan table, and offers, trips, status history, payments, earnings and payouts are all derived from that plan. This keeps the data internally consistent: every trip's driver belongs to the same vendor as its tanker, every tanker is large enough for its load, every payment matches its quoted price, and every payout equals the sum of the earnings it settles. These rules were verified with checking queries after generation. The script uses `setseed()`, so every run produces identical data and timings can be compared fairly.

## Method

Each query in `explain.sql` is run twice. The first run is discarded and serves as a warm-up, so both the "before" and "after" measurements read data already in memory, isolating the effect of the indexes from the effect of disk caching. The second run uses `EXPLAIN (ANALYZE, BUFFERS)`, which executes the query and reports the plan chosen by the optimiser, the estimated and actual row counts at each step, the time spent in each step, and the number of data pages read.

PostgreSQL does not automatically create indexes on foreign key columns. After Portfolio 1, the only indexes in the database were those created by primary keys, unique constraints and the partial unique index on trips. This made the baseline a fair test of what targeted indexes add.

## Results

| Query | Purpose | Before | After | Speed-up |
|---|---|---|---|---|
| Q1 | Customer request history | 13.133 ms | 0.037 ms | ~355× |
| Q2 | Delivery tracking timeline | 64.227 ms | 0.039 ms | ~1,650× |
| Q3 | Live operations dashboard | 20.303 ms | 4.080 ms | ~5× |
| Q4 | Tanker matching | 0.370 ms | 0.452 ms | No change |
| Q5 | Vendor monthly statement | 15.699 ms | 12.380 ms | ~1.3× |
| Q6 | Weekly area report (original) | 80.619 ms | 55.386 ms | ~1.5× |
| Q6b | Weekly area report (rewritten) | 75.871 ms | 34.038 ms | ~2.2× |

Comparing the original Q6 before indexing with the rewritten Q6b after indexing, the weekly report went from 80.619 ms to 34.038 ms, about 2.4 times faster, with identical results.

## Analysis

### Q1: Customer request history — 13.1 ms to 0.04 ms

**Before**, PostgreSQL had no way to find one customer's requests except reading all 300,000 rows of `delivery_request` (a parallel sequential scan), keeping the 10 that matched, and then sorting them by date.

**After**, the composite index `idx_request_customer_created (customer_id, created_at DESC)` lets PostgreSQL jump straight to this customer's entries. Because the index stores them already ordered newest first, the sort step disappears entirely and the `LIMIT 20` can stop reading as soon as it has enough rows. Column order matters here: an index on `(created_at, customer_id)` would not help, because the customer filter must come first to narrow the search.

This query runs every time a customer opens the app, so it matters most in practice even though its original time looks small. At thousands of users, 13 ms per request becomes real server load.

### Q2: Delivery tracking timeline — 64.2 ms to 0.04 ms

**Before**, the query needed two full scans: the whole `trip` table to find the trips for one request, and the whole `trip_status_history` table, over 1.1 million rows, to find their status changes. It read more than a million rows to return eight.

**After**, `idx_trip_request` finds the request's two trips (the failed attempt and the retry) directly, and `idx_history_trip_changed` finds each trip's status changes directly. This was the largest improvement, because the table being scanned was the largest.

One finding here was that the partial unique index from Portfolio 1, `one_live_trip_per_request`, already indexes `trip.request_id`, but the optimiser could not use it. That index excludes failed and cancelled trips, while this query must show the failed attempt too. A partial index can only serve queries whose conditions guarantee they need nothing outside it.

### Q3: Live operations dashboard — 20.3 ms to 4.1 ms

**Before**, finding the few hundred trips currently in progress meant scanning all 293,894 trips and discarding the completed, failed and cancelled ones.

**After**, the partial index `idx_trip_active` contains only trips whose status is assigned, en route or arrived. It is **32 kB**, compared with 29 MB for the table, and completed trips, which are the overwhelming majority, never enter it. When a trip completes, it drops out of the index automatically.

The improvement is smaller than Q1 and Q2 because the filter is no longer the bottleneck. The remaining time is spent joining each of the 513 active trips to its request, address, tanker, driver and service area, which the plan shows as hundreds of primary key lookups. Those lookups were already indexed by primary keys, so further indexing would not help.

### Q4: Tanker matching — no change (control case)

This query was already fast before any indexes were added, and adding them changed nothing. The difference between 0.370 ms and 0.452 ms is measurement noise at sub-millisecond scale, not a real slowdown.

There are two reasons:

1. **The expensive part was already indexed.** The check for tankers already offered this request looks up `job_offer` by `(request_id, tanker_id)`. The unique constraint on that pair, added in Portfolio 1 to stop a tanker being offered the same request twice, automatically created an index. The plan shows an *Index Only Scan* on `uq_job_offer_request_tanker`, meaning PostgreSQL answered from the index without reading the table at all. A constraint designed for data integrity also provided performance.
2. **The other tables are small.** With 1,236 tankers and 400 vendors, reading them sequentially takes a fraction of a millisecond, and an index would add overhead rather than remove it.

This shows that indexing every column is not the goal. An index is only worth its cost where a plan shows a large table being scanned for a small result.

### Q5: Vendor monthly statement — 15.7 ms to 12.4 ms

**Before**, all 274,184 rows of `vendor_earning` were scanned to find one vendor's 1,245 earnings.

**After**, `idx_earning_vendor` finds those 1,245 earnings directly, which removed the full scan. However, the overall gain was modest, and the execution plan explains why. The query only wants last month's earnings, but the completion date is stored on `trip`, not on `vendor_earning`. So PostgreSQL still has to look up all 1,245 trips individually by primary key to check their dates, and most are then discarded because they fall outside the month.

A further improvement would be to store the completion date on `vendor_earning` itself and index `(vendor_id, earned_at)`, so the date filter could be applied inside the index. That would mean duplicating a value already held in `trip`, which is exactly the kind of redundancy the Portfolio 1 normalisation removed. This was left as a documented trade-off: a 12 ms monthly statement is acceptable, and the normalised design avoids the risk of the two dates disagreeing.

### Q6 and Q6b: Weekly area report — 80.6 ms to 34.0 ms

This query showed that an index can be used and still fail to fix the real bottleneck.

**Before**, both `delivery_request` and `trip` were scanned in full.

**After indexing, Q6** used `idx_request_created` to find the week's requests (about 16,000) instead of scanning all 300,000. But the improvement was only from 80.6 ms to 55.4 ms. The plan showed why: to attach each request's completed trip, the optimiser still read **all** completed trips (about 274,000) to build a hash table for the join. Probing an index 16,000 times was estimated to cost more than one scan, so the new index on `trip.request_id` was not used. The filter was fixed, but the join was not.

**Q6b** adds one condition to the join: `t.assigned_at >= now() - interval '7 days'`. A trip is always assigned after its request is created, so for a request from the last seven days, its trip must also have been assigned in the last seven days. The condition therefore cannot exclude any trip the report needs, and the results are identical. What it changes is that the optimiser can now restrict the trip side as well, using the partial index `idx_trip_completed_assigned` (completed trips only, ordered by assignment time). Both sides of the join are now small, and the time fell to 34.0 ms.

This was the only improvement that required changing the query rather than just adding an index. It required understanding the business rule that makes the extra condition safe, which is information the optimiser cannot work out on its own.

### Selectivity: when the optimiser ignores an index

The last part of `explain.sql` compares the plans for counting requests from the last 7 days and from the last 365 days, with `idx_request_created` available for both:

- **7 days** (about 5% of rows): the optimiser uses an *Index Only Scan* on `idx_request_created`.
- **365 days** (about half the table): it ignores the index and uses a *Parallel Seq Scan*.

This is the optimiser working correctly. An index lookup means jumping to scattered locations, while a sequential scan reads the table straight through. Once a query needs a large fraction of a table, reading all of it in order is cheaper than following the index for each row. Indexes help *selective* queries, and broad analytical queries over most of a table are better served by other techniques, such as pre-computed summary tables.

## Cost of the Indexes

Indexes are not free. Each one uses disk space, and every insert or update to the table must also update every index on it.

| Index | Table | Index size | Table size |
|---|---|---|---|
| idx_history_trip_changed | trip_status_history | 35 MB | 66 MB |
| idx_request_customer_created | delivery_request | 9,264 kB | 23 MB |
| idx_request_created | delivery_request | 6,600 kB | 23 MB |
| idx_trip_request | trip | 6,384 kB | 29 MB |
| idx_trip_completed_assigned | trip | 5,960 kB | 29 MB |
| idx_earning_vendor | vendor_earning | 1,960 kB | 38 MB |
| idx_trip_active | trip | 32 kB | 29 MB |

The largest cost is `idx_history_trip_changed`, at more than half the size of its table. `trip_status_history` is also the most write-heavy table, since every status change by every driver inserts a row, and each insert now updates this index too. This was judged worthwhile because the tracking screen it serves (Q2) is opened constantly by customers waiting for water, and went from 64 ms to 0.04 ms.

The two partial indexes show the opposite end of the trade-off. `idx_trip_active` is only 32 kB because it holds only in-progress trips, and `idx_trip_completed_assigned` skips failed and cancelled trips. Indexing only the rows a query actually needs keeps both the storage and the write cost down.

## Summary

- Targeted indexes reduced the two most frequent customer-facing queries (Q1 and Q2) from tens of milliseconds to under 0.05 ms.
- Partial indexes served queries over small subsets of a large table (Q3, Q6b) at a fraction of the cost of a full index.
- A unique constraint added for data integrity in Portfolio 1 already made Q4 fast, so no index was needed.
- Execution plans revealed where an index helped only part of a query (Q5, Q6), and in Q6 a query rewrite based on a business rule fixed what indexing alone could not.
- The optimiser correctly ignores indexes when a query needs most of a table, so indexes are a tool for selective queries rather than a universal fix.
