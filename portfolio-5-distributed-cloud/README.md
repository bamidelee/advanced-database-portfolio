# Portfolio 5: Distributed and Cloud Databases

A single database server is a single point of failure: if it goes down, no customer can request water and no driver can record a delivery. This portfolio runs AquaFlow's data across several servers and examines what that buys and what it costs.

- **Part A** sets up PostgreSQL streaming replication (a primary and a read-only replica), then measures replication lag, provokes a stale read, compares asynchronous and synchronous replication, and fails over to the replica.
- **Part B** runs a three-member MongoDB replica set, kills its primary to watch an automatic election, and removes the majority to see writes refused.
- **Part C** designs how AquaFlow would shard when one server is no longer enough, and how it would be deployed on cloud infrastructure serving Lagos.

Parts A and B were run on a separate Docker Compose stack (`docker-compose.yml` in this folder), so the experiments never touch the main databases.

## Files

| File | Description |
|---|---|
| `docker-compose.yml` | PostgreSQL primary and replica, and a three-member MongoDB replica set |
| `postgres/init-primary.sh` | Creates the replication account on the primary |
| `postgres/pg-replication-demo.sh` | Part A demonstration |
| `postgres/pg-replication-demo-output.txt` | Part A output |
| `mongo/mongo-replicaset-demo.sh` | Part B demonstration |
| `mongo/mongo-replicaset-demo-output.txt` | Part B output |

## How to Reproduce

From the repository root, with Docker running:

```bash
bash portfolio-5-distributed-cloud/postgres/pg-replication-demo.sh
bash portfolio-5-distributed-cloud/mongo/mongo-replicaset-demo.sh
docker compose -f portfolio-5-distributed-cloud/docker-compose.yml down -v   # remove afterwards
```

Each script builds its servers from scratch on every run.

---

## Part A: PostgreSQL Streaming Replication

### How it works

Every change in PostgreSQL is first written to the **write-ahead log (WAL)**, which is how PostgreSQL recovers after a crash. Streaming replication reuses that log. The replica is created as a byte-for-byte copy of the primary with `pg_basebackup`. It then connects to the primary, receives each WAL record as it is written, and replays it, so the replica continuously repeats the primary's changes. While replaying, it is a **hot standby**: it accepts read-only queries.

The primary is configured with `wal_level=replica` and allows WAL senders. The replica's `cluster_name` (`replica1`) becomes its name in `pg_stat_replication`, which synchronous replication refers to.

### Demonstrations (`postgres/pg-replication-demo-output.txt`)

**1. Topology.** The primary lists `replica1` with state `streaming`, and the replica reports `pg_is_in_recovery() = true`.

**2. Lag during a bulk load.** The Portfolio 1 schema and the Portfolio 2 seed (about 400 MB, 300,000 requests and over a million status-history rows) were loaded on the primary only. Every three seconds, the primary reported how many bytes of WAL the replica had not yet replayed. The replica's visible row count stayed at **zero for the whole load** and then jumped to 300,000. The seed runs as one transaction, and the replica, like any other session, only sees its rows once it has replayed the commit. Replication preserves transaction boundaries. Afterwards, both servers reported identical row counts.

**3. Read-only replica.** An `INSERT` on the replica was refused: *cannot execute INSERT in a read-only transaction*. All writes must go to the primary.

**4. A stale read.** Replay on the replica was paused with `pg_wal_replay_pause()` to make a delay visible. A customer registered on the primary, and the same lookup on the replica returned nothing. After `pg_wal_replay_resume()`, the replica found them. This is the *read-your-writes* problem of asynchronous replication: an app that writes to the primary and immediately reads from a replica can show a user that their own action did not happen. AquaFlow should send reads that follow a user's own write (such as "show my new request") to the primary, and use replicas for reads that can tolerate a short delay, such as reports.

**5. Synchronous replication.** With `synchronous_standby_names = 'replica1'`, a commit on the primary waits until the replica confirms it has received and stored the WAL, so a committed transaction exists on both servers.

- *Commit time.* Timing 300 commits each way showed little difference, because both servers ran on one machine and the replica was microseconds away. In a real deployment with the replica in another data centre, every synchronous commit also waits for a network round trip, which directly lengthens every write.
- *When the replica is down.* The replica was stopped and a row inserted on the primary. The commit **waited indefinitely** (`wait_event = SyncRep`), and the row was invisible to every other session. Cancelling the wait produced PostgreSQL's warning: *the transaction has already committed locally, but might not have been replicated to the standby*. The row then became visible. Synchronous replication had turned a replica failure into a primary that could not complete writes, trading availability for durability.
- *Lesson.* `statement_timeout` does **not** release this wait: PostgreSQL disables the statement timer before the commit step. This was discovered when a first attempt at the demo hung indefinitely. An operator or monitoring process must cancel the waiting sessions, or switch synchronous replication off. In production this is usually handled by listing several standbys and requiring any one of them (`synchronous_standby_names = 'ANY 1 (replica1, replica2)'`), so a single replica failure does not stop writes.

After synchronous replication was switched off and the replica restarted, it reconnected, replayed the WAL it had missed, and showed the row.

**6. Failover.** The primary was stopped. The replica still refused writes, until `SELECT pg_promote()` ended recovery mode, which took well under a second. It then accepted new writes and held all 300,000 requests. Two lessons:

- PostgreSQL does not fail over by itself. Promotion was a manual decision. Production systems use a manager such as Patroni, or a managed cloud service, to detect the failure and promote a replica automatically.
- The old primary must never simply be restarted. It would believe it was still the primary, and two servers accepting writes (*split brain*) would create conflicting data. It has to be rebuilt as a replica of the new primary, for example with `pg_rewind` or a fresh base backup.

---

## Part B: MongoDB Replica Set

### How it works

A MongoDB replica set has one **primary**, which accepts writes, and **secondaries**, which copy the primary's operation log (*oplog*) and apply it. Members exchange heartbeats every two seconds. If the primary is silent for longer than `electionTimeoutMillis` (10 seconds by default), the others hold an election. A member can only become primary with votes from a **majority** of the set: 2 of 3 here.

The **write concern** says how many members must confirm a write before the client is told it succeeded. The default in MongoDB 7.0 is `majority`.

### Demonstrations (`mongo/mongo-replicaset-demo-output.txt`)

**1. Topology.** One PRIMARY (mongo1, given priority 2 so it is preferred) and two SECONDARY members, with a default write concern of `majority`.

**2. Replicated writes.** One write was acknowledged with `w: "majority"` and one with `w: 3` (all members). Reading each member directly showed all three held both documents.

**3. Automatic failover.** The primary was killed with `docker kill`, which stops it instantly, like a power failure. (`docker stop` was tried first, but a clean shutdown makes the primary step down and hand over in under a second, which does not represent a real failure.) The remaining members stopped receiving heartbeats and elected a new primary after about **10 seconds**, matching the election timeout, with no operator involved. The application's next write, through the same connection string, succeeded: the driver discovered the new primary itself. This contrasts with PostgreSQL in Part A, where promotion was manual.

**4. Write concern versus what happened.** With one member down, a write requiring all three members failed with `WriteConcernFailed: waiting for replication timed out`. Yet both running members held the document. The write was **not undone**: it was applied, and the client was simply told it could not be confirmed on all members in time. This mirrors the cancelled synchronous commit in PostgreSQL. In both systems, a replication acknowledgement controls when the client is told about a write, not whether the write happens. An application that treats such an error as "the write did not happen" and retries it could create a duplicate, which is why idempotent writes (for example, upserting by a payment reference) matter in distributed systems.

**5. Losing the majority.** A second member was killed, leaving one out of three. It stayed SECONDARY and would not become primary. One member cannot tell whether the other two have failed or are merely cut off on the far side of a network split, possibly electing a primary of their own. Refusing to act without a majority guarantees there is never more than one primary. Writes were refused after five seconds (`MongoServerSelectionError`: no primary could be found), while reads with `readPreference: secondaryPreferred` still returned all four events, accepting that they might be stale.

**6. Recovery.** Both members returned, copied the operations they had missed from the oplog, and an election restored a primary. mongo1, with the highest priority, took back the primary role once it had caught up. All three members held the same four events.

---

## Consistency Versus Availability

The CAP theorem states that when a network partition separates servers, a distributed system must choose between **consistency** (every read sees the latest write) and **availability** (every request gets an answer). The PACELC extension adds that even without a partition, there is a trade-off between **latency** and **consistency**. Both demonstrations showed these trade-offs directly:

| Situation | Choice made | Seen in |
|---|---|---|
| Asynchronous replica serving reads | Latency and availability over consistency: replica reads can be stale | Part A, demo 4 |
| Synchronous replication | Consistency over latency (every commit waits) and over availability (commits stop when the replica fails) | Part A, demo 5 |
| MongoDB majority writes | Consistency: a write is only confirmed once it cannot be lost in a failover | Part B, demos 2 and 4 |
| MongoDB without a majority | Consistency over availability: no writes rather than risk two primaries | Part B, demo 5 |
| Reads from secondaries | Availability over consistency: answers continue, possibly stale | Part B, demo 5 |

AquaFlow does not need one choice for everything. Each kind of data gets the guarantee its business meaning requires:

| AquaFlow data | Needs | Approach |
|---|---|---|
| Payments, payouts, refunds | Never lost, never duplicated | Synchronous replication to at least one standby (`ANY 1` of several), or MongoDB `w: majority`. Read from the primary |
| Trip assignment | One winner per request and per tanker | Always on the primary, with the Portfolio 3 locks and constraints |
| Customer's own recent activity | Read-your-writes | Read from the primary for a short period after the user writes |
| Reports and analytics | Can be minutes old | Asynchronous replicas |
| Live tanker positions | Fresh within seconds; a lost ping is harmless | Redis (Portfolio 4), optimised for availability and speed |

---

## Part C: Sharding Design

### When AquaFlow should shard

Replication copies all of the data to every server, which increases read capacity and availability but not write capacity or storage. **Sharding** splits the data itself across servers, so each holds and writes only part of it. It also adds substantial complexity: queries and transactions that span shards become slower and harder. AquaFlow's current dataset is about 400 MB, which one server handles easily, so the sensible order of escalation is:

1. A larger server (vertical scaling), with the indexes from Portfolio 2.
2. Read replicas for reporting (Part A).
3. **Partitioning within one server** for the fastest-growing table. `trip_status_history` gains several rows per trip, is append-only, and is mostly read for recent trips. Range-partitioning it by month lets queries for recent trips skip old partitions, and old months can be archived by dropping a partition instead of a slow `DELETE`.
4. Sharding, only when write volume or data size exceeds what one primary can handle, for example if AquaFlow expanded across Lagos and to other cities.

### Choosing a shard key for PostgreSQL

Using an extension such as Citus, tables are distributed across worker servers by a **distribution column**. The choice decides which queries stay on one shard and which must visit all of them. Candidates for AquaFlow:

| Shard key | Strength | Weakness |
|---|---|---|
| `service_area_id` | A city's operations stay together | Only six values, so at most six shards, and heavily uneven: Victoria Island and Ikoyi would be hot spots |
| `request_id` | Spreads writes evenly | A customer's history is scattered across every shard |
| `customer_id` | Spreads evenly over 50,000+ values. A customer's requests, trips, payments and ratings live together, so the app's most frequent queries (Portfolio 2's Q1 and Q2) hit one shard | Vendor statements and area reports must query every shard |

**Recommendation: distribute by `customer_id`.** `delivery_request`, `trip`, `trip_status_history`, `payment`, `refund`, `vendor_earning` and `rating` are **co-located** on the same shard as their customer. That requires adding `customer_id` to the child tables, which currently reach it only through `request_id`, a deliberate redundancy that sharding needs. `service_area`, `pricing_rule`, `vendor`, `driver` and `tanker` are small, so they become **reference tables**, copied in full to every shard so joins with them stay local.

Two consequences follow from earlier portfolios:

- **Tanker status changes constantly**, and every write to a reference table must reach every shard. This is a further argument for keeping live tanker status in Redis (Portfolio 4) and treating the PostgreSQL `tanker` table as mostly static data.
- **Cross-shard queries** such as vendor payouts would visit all shards. These are batch operations run a few times a month, so they can tolerate the cost, or run on a replica.

### Sharding the NoSQL stores

- **MongoDB `deliveries`**: a hashed shard key on `customer.id` spreads writes evenly and keeps a customer's history on one shard. A lookup by `_id` alone would have to ask every shard, so the tracking screen should query with both `_id` and `customer.id`, which the app always knows. `tanker_positions` would shard by `meta.tanker_id`, keeping each tanker's route together.
- **Redis Cluster**: keys are spread across 16,384 hash slots. The single `geo:tankers:available` set would sit on one server and become a hot spot, so it would be split per service area (`geo:tankers:available:{ikoyi}` and so on), with matching near an area boundary also searching the neighbouring area's set. As noted in Portfolio 4, `match.lua` would also need restructuring, because a cluster script may only access keys passed to it on the same shard.

---

## Cloud Deployment

### Where the servers should be

Latency and law both point towards hosting close to Lagos:

- **Latency.** Every query from an app in Lagos to a database in another country adds a network round trip, and synchronous replication adds another to every commit. AWS opened a **Local Zone in Lagos** in January 2023, offering compute and storage within the city for latency-sensitive applications [1]. The nearest full cloud regions, with the complete range of managed database services, are in South Africa: AWS in Cape Town, and Microsoft Azure and Google Cloud in Johannesburg.
- **Data protection.** The **Nigeria Data Protection Act 2023** allows personal data to be transferred outside Nigeria only where the recipient provides an adequate level of protection, through law, binding corporate rules, contractual clauses, codes of conduct or certification, or under limited other conditions [2][3]. The NDPA General Application and Implementation Directive 2025 adds detailed requirements for cross-border transfers [4]. AquaFlow stores customers' names, phone numbers and home addresses, so hosting in South Africa would be a cross-border transfer requiring a valid legal basis, while hosting in Lagos would avoid that question.

### Proposed deployment

| Component | Deployment | What it provides |
|---|---|---|
| Application servers | Lagos Local Zone | Low latency for customers, vendors and drivers |
| PostgreSQL (system of record) | Primary plus a synchronous standby in a separate data centre and an asynchronous read replica. Either a managed service such as Amazon RDS Multi-AZ (which maintains a synchronous standby and fails over automatically), or self-managed with Patroni if the database must stay in Lagos | Part A's replication with automatic, safe failover |
| MongoDB | Three-member replica set across three data centres, for example MongoDB Atlas | Part B's automatic elections, surviving the loss of any one data centre |
| Redis | Managed Redis with a replica, such as Amazon ElastiCache | Live state that can be rebuilt from PostgreSQL if lost |
| Backups | Continuous WAL archiving for point-in-time recovery, plus daily snapshots copied to another region | Recovery from mistakes that replication would faithfully copy, such as an accidental `DELETE` |
| Monitoring | Alerts on replication lag, `idle in transaction` sessions (Portfolio 3), commits waiting on `SyncRep`, and replica set members not in PRIMARY or SECONDARY state | Early warning of the problems demonstrated in this portfolio |

Managed services automate exactly what these demonstrations performed by hand: an RDS Multi-AZ failover is Part A's promotion carried out automatically, with the old primary fenced off and rebuilt, and Atlas runs Part B's elections across separate data centres. Building the manual versions first made clear what those services are doing and which trade-offs they make by default.

One point applies whatever the provider: **replication is not a backup.** A replica copies every change, including mistakes, within milliseconds. Only backups with point-in-time recovery can restore data to the moment before an error.

---

## Summary

- PostgreSQL streaming replication provided a read-only copy that preserved transaction boundaries, but asynchronous replicas can serve stale reads, and failover required a manual promotion with care to avoid split brain.
- Synchronous replication guaranteed every commit existed on two servers, at the cost of commit latency and of writes stopping entirely when the only synchronous standby failed. `statement_timeout` does not release that wait.
- The MongoDB replica set failed over automatically in about ten seconds, refused writes rather than risk two primaries when the majority was lost, and kept serving possibly stale reads.
- In both systems, a replication acknowledgement controls what the client is told, not whether the write happened.
- AquaFlow should choose consistency for money and assignment, read-your-writes for a user's own actions, and availability for live positions and reports.
- Sharding is not needed at AquaFlow's current size. If it is, `customer_id` is the best key, with co-located customer data and small reference tables.
- Deployment should be close to Lagos for latency and to keep customers' personal data within the Nigeria Data Protection Act's requirements.

## References

1. ITWeb, "AWS extends local zone footprint with Lagos launch", 26 January 2023. https://itweb.africa/content/KBpdgvpmYEN7LEew
2. Nigeria Data Protection Act, 2023, Part VIII: Cross-Border Transfers of Personal Data. https://assets.kpmg.com/content/dam/kpmg/ng/pdf/nigeria-data-protection-act2023.pdf
3. Mondaq, "An Overview Of The Nigeria Data Protection Act, 2023", 25 July 2023. https://www.mondaq.com/nigeria/privacy-protection/1346676/an-overview-of-the-nigeria-data-protection-act-2023
4. Legal 500, "Cross-Border Data Transfers: An Overview Of Legal Requirements And Compliance Mechanisms In Nigeria". https://www.legal500.com/developments/thought-leadership/cross-border-data-transfers-an-overview-of-legal-requirements-and-compliance-mechanisms-in-nigeria/
5. PostgreSQL Global Development Group, *PostgreSQL 16 Documentation*, Chapter 27: High Availability, Load Balancing, and Replication. https://www.postgresql.org/docs/16/high-availability.html
6. MongoDB, Inc., *MongoDB Manual*: Replication, and Write Concern. https://www.mongodb.com/docs/manual/replication/