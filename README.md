# MIT 8103 Advanced Database Systems Portfolio

**Student:** Ibrahim Olujide
**Matric/Student ID:** 301910809
**Programme:** Master of Information Technology
**Session:** 2026/2027 First Semester (September cohort)

## Case Study: AquaFlow Water Tanker Services

### Organisation and Scenario
AquaFlow is a simulated on-demand water tanker platform, operating like a ride-hailing service for water, on Lagos Island, Nigeria. Many households and businesses in areas such as Lagos Island, Ikoyi, Victoria Island, and Obalende cannot use their borehole or well water because of saltwater intrusion: seawater from the Atlantic Ocean and the Lagos Lagoon has seeped into the shallow aquifers that boreholes draw from, pushing chloride levels above the WHO limit for safe water [1][2][3]. Reaching fresh water requires very deep boreholes that most property owners cannot afford [1], and surface pollution from sewage and industrial waste further degrades groundwater [4]. As a result, residents rely on water tankers to fill their storage tanks.

AquaFlow connects these customers with independent vendors who own and operate their own water tankers. The platform matches each request to a nearby available tanker, tracks the delivery live, processes payment, and pays vendors after deducting a commission.

### Nature of the Business
Customers request a delivery through the AquaFlow customer app, specifying the delivery address and volume needed, either immediately or at a scheduled time. The platform finds available tankers near the customer with enough capacity and sends the request to their vendors through the AquaFlow vendor app. The first vendor to accept is assigned the job, and the tanker's location is tracked live until it arrives. The driver confirms the volume delivered, the customer pays by card or bank transfer through the app, and the vendor's earnings, minus AquaFlow's commission, are credited for payout.

### Users of the Database
- **Customers** (households and businesses) register addresses, request deliveries, pay, track tankers in real time, and rate completed deliveries.
- **Vendors** (tanker owners) register their tankers and drivers, accept or decline requests, and receive payouts. A vendor may own one or several tankers.
- **Drivers** operate tankers on behalf of vendors, share live location, and update delivery status. A vendor may also drive their own tanker.
- **Operations staff** monitor active deliveries, resolve disputes, and manage service areas and pricing.
- **Finance staff** reconcile customer payments, commissions, refunds, and vendor payouts.

### Major Data Stored
Customers and delivery addresses (including storage tank capacity and access notes), service areas, vendors, tankers (capacity, plate number, availability status), drivers, pricing rules, delivery requests, job offers and acceptances, delivery status history, live tanker locations, payments, refunds, commissions, vendor payouts, and ratings.

### Key Operations
- Register customers, vendors, tankers, and drivers
- Request a water delivery (immediate or scheduled)
- Find nearby available tankers with sufficient capacity
- Offer jobs to vendors and assign each job to exactly one tanker
- Track tanker location and delivery status in real time
- Confirm delivered volume and process payment
- Reverse failed payments and refund cancelled deliveries
- Calculate commissions and credit vendor earnings for payout
- Generate reports on demand per area, vendor performance, delivery times, and revenue

## Portfolio Summary

| Portfolio | Topic | What was built | Key findings |
|---|---|---|---|
| [1](portfolio-1-database-design/) | Database Design and Modelling | 17-table PostgreSQL schema with an ER diagram, normalisation analysis, and 15 constraint tests | Composite foreign key stops a request using another customer's address; a partial unique index allows retries after a failed trip but only one successful trip; a generated column keeps net earnings consistent |
| [2](portfolio-2-query-optimisation/) | Query Processing and Optimisation | Two years of seeded data (300,000 requests, 1.1 million status rows), seven business queries with before/after execution plans | Targeted indexes made the two main customer queries hundreds to over a thousand times faster; one query needed a rewrite, not just an index; the optimiser rightly ignores indexes for broad queries |
| [3](portfolio-3-transactions-concurrency/) | Transactions and Concurrency | Atomic business functions, plus two-session demos of races, isolation levels and deadlocks with merged timelines | Found and fixed a real gap that allowed tanker double-booking (present in the seed data); READ COMMITTED produced a wrong vendor payout; write skew needed SERIALIZABLE; documented a real lock-wait incident |
| [4](portfolio-4-nosql/) | NoSQL and Advanced Data Models | Redis for live tanker positions and matching; MongoDB for delivery documents and a GPS time series | Nearest-tanker search in memory with expiring heartbeats; a whole delivery read as one document; GPS stored at about 16 bytes per point; validation caught inconsistent records during migration |
| [5](portfolio-5-distributed-cloud/) | Distributed and Cloud Databases | PostgreSQL primary/replica and a three-member MongoDB replica set, plus a sharding and cloud deployment design | Stale replica reads, synchronous commits blocked by a failed replica, manual versus automatic failover, writes refused without a majority; shard by customer; host near Lagos for latency and data protection law |

## Repository Structure

```
advanced-database-portfolio/
├── docker-compose.yml                 # PostgreSQL, Redis and MongoDB for Portfolios 1-4
├── portfolio-1-database-design/       # ER model, schema.sql, constraint tests
├── portfolio-2-query-optimisation/    # seed.sql, queries, indexes, execution plans
├── portfolio-3-transactions-concurrency/
│   ├── functions.sql                  # assign_trip(), complete_trip()
│   ├── 01-commit-rollback.sql
│   └── concurrency/                   # two-session race, isolation and deadlock demos
├── portfolio-4-nosql/
│   ├── redis/                         # live tanker tracking and matching
│   └── mongo/                         # delivery documents and GPS time series
├── portfolio-5-distributed-cloud/
│   ├── docker-compose.yml             # separate stack: replicated PostgreSQL and MongoDB
│   ├── postgres/                      # streaming replication and failover
│   └── mongo/                         # replica set elections
└── README.md
```

Each portfolio folder has its own README explaining what was done, how it was tested, and what was found, with output files and screenshots as evidence.

## Running Everything

Requires Docker with Docker Compose. Bash scripts were run on Linux; on Windows, use Git Bash.

```bash
# Main databases (Portfolios 1-4)
docker compose up -d

# Portfolio 1: schema and constraint tests
bash portfolio-1-database-design/capture-evidence.sh

# Portfolio 2: data, then before/index/after measurements
docker exec -it aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-2-query-optimisation/seed.sql
docker exec aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-2-query-optimisation/explain.sql > portfolio-2-query-optimisation/explain-before.txt 2>&1
docker exec -it aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-2-query-optimisation/indexes.sql
docker exec aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-2-query-optimisation/explain.sql > portfolio-2-query-optimisation/explain-after.txt 2>&1

# Portfolio 3: functions, then demos
docker exec aquaflow-db psql -U postgres -d aquaflow -f /portfolio/portfolio-3-transactions-concurrency/functions.sql
docker exec aquaflow-db psql -q -U postgres -d aquaflow -f /portfolio/portfolio-3-transactions-concurrency/01-commit-rollback.sql > portfolio-3-transactions-concurrency/01-commit-rollback-output.txt 2>&1
bash portfolio-3-transactions-concurrency/concurrency/run-race-demos.sh
bash portfolio-3-transactions-concurrency/concurrency/run-isolation-demos.sh

# Portfolio 4
bash portfolio-4-nosql/redis/redis-demo.sh
bash portfolio-4-nosql/mongo/mongo-demo.sh

# Portfolio 5 (builds its own separate stack)
bash portfolio-5-distributed-cloud/postgres/pg-replication-demo.sh
bash portfolio-5-distributed-cloud/mongo/mongo-replicaset-demo.sh
```

The database passwords in the compose files are for local development only.

Note: after Portfolio 3, the database has a guard index (`one_live_trip_per_tanker`) that rejects tanker double-booking. The Portfolio 2 seed generator creates some double-booked trips (the finding described in Portfolio 3), so rerunning `seed.sql` would fail against the guard. To regenerate the data, drop the index first, then rerun `run-race-demos.sh`, which cleans the data and recreates it:

```bash
docker exec aquaflow-db psql -U postgres -d aquaflow -c "DROP INDEX IF EXISTS one_live_trip_per_tanker;"
```

## Tools Used

PostgreSQL 16, Redis 7.2, MongoDB 7.0, Docker Compose, dbdiagram.io (DBML), psql, redis-cli, mongosh, mongoimport, and Bash.

## AI Use Declaration

See the AI Use Declaration in the final documentation submitted through the LMS.

## References

1. Delineation of saline water intrusion to safe-guide inland groundwater resources (Lagos Island). *Ocean & Coastal Management*, Vol. 116, 2015, pp. 162–168.
2. Assessment of Saline Intrusion in Lagos Coastal Aquifer. *International Archive of Applied Sciences and Technology*, Vol. 3, No. 3, 2012, pp. 23–28.
3. Yusuf, M. A., Ojulari, B. A., Ibrahim, K. O., & Abiye, T. A. (2021). Assessment of saltwater–freshwater interactions using water samples and borehole logging information in the Lagos coastal region, Nigeria. *Environmental Earth Sciences*.
4. Hydrogeochemical processes and salinity status of the freshwater aquifer in the Lagos coastal basin. Available via PubMed Central (PMC8564569).

Further references for each portfolio are listed in its own README.