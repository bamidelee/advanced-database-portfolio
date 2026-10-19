-- =====================================================================
-- AquaFlow - Commit, Rollback and Savepoints
-- MIT 8103 Advanced Database Systems - Portfolio 3, Demo 1
--
-- Single-session demonstrations of transaction control using the
-- functions in functions.sql. Each run picks trips and offers that are
-- still in the right state, so the script can be rerun.
--
-- Run with:
--   psql -U postgres -d aquaflow -f 01-commit-rollback.sql
-- =====================================================================

\set ON_ERROR_STOP off
\set ON_ERROR_ROLLBACK off
\set VERBOSITY terse
\pset pager off
\pset footer off

-- Reusable query showing everything complete_trip() touches for one trip.
-- Usage:  :state <trip_id>;
\set state 'SELECT t.id AS trip, t.status AS trip_status, r.status AS request_status, tk.status AS tanker_status, (SELECT count(*) FROM payment p WHERE p.request_id = r.id) AS payments, (SELECT count(*) FROM vendor_earning e WHERE e.trip_id = t.id) AS earnings FROM trip t JOIN delivery_request r ON r.id = t.request_id JOIN tanker tk ON tk.id = t.tanker_id WHERE t.id ='

-- Pick three trips that have arrived and are waiting to be completed
SELECT id AS trip_a, (SELECT volume_litres FROM delivery_request WHERE id = request_id) AS vol_a
FROM trip WHERE status = 'arrived' ORDER BY id LIMIT 1 OFFSET 0 \gset
SELECT id AS trip_b, (SELECT volume_litres FROM delivery_request WHERE id = request_id) AS vol_b
FROM trip WHERE status = 'arrived' ORDER BY id LIMIT 1 OFFSET 1 \gset
SELECT id AS trip_c, (SELECT volume_litres FROM delivery_request WHERE id = request_id) AS vol_c
FROM trip WHERE status = 'arrived' ORDER BY id LIMIT 1 OFFSET 2 \gset


\echo
\echo '======================================================================'
\echo ' TEST 1: COMMIT - completing a delivery'
\echo ' complete_trip() updates 4 tables and inserts into 3. On COMMIT,'
\echo ' all of it becomes permanent together.'
\echo '======================================================================'
\echo 'Before:'
:state :trip_a;

BEGIN;
SELECT complete_trip(:trip_a, :vol_a, 'card', 'PSTK-DEMO-' || :trip_a) AS payment_id;
COMMIT;

\echo 'After COMMIT: trip and request completed, 1 payment, 1 earning, tanker available'
:state :trip_a;


\echo
\echo '======================================================================'
\echo ' TEST 2: AUTOMATIC ROLLBACK - payment fails halfway through'
\echo ' The gateway sends a reference that was already used in Test 1.'
\echo ' Steps 1 and 2 succeed, step 3 fails on the unique constraint.'
\echo ' Expected: the whole transaction is undone, including steps 1 and 2.'
\echo '======================================================================'
\echo 'Before:'
:state :trip_b;

BEGIN;
SELECT complete_trip(:trip_b, :vol_b, 'card', 'PSTK-DEMO-' || :trip_a) AS payment_id;

\echo
\echo 'After an error, PostgreSQL refuses every further statement in the'
\echo 'transaction until it is ended. Even a trivial query fails:'
SELECT 1;
ROLLBACK;

\echo
\echo 'After ROLLBACK: trip still arrived, request still assigned, no payment.'
\echo 'Steps 1 and 2 ran, but nothing they changed was kept:'
:state :trip_b;


\echo
\echo '======================================================================'
\echo ' TEST 3: EXPLICIT ROLLBACK - abandoning a change on purpose'
\echo ' A finance officer starts a refund on the Test 1 payment, then'
\echo ' realises it is the wrong customer and cancels.'
\echo '======================================================================'
SELECT id AS payment_a FROM payment WHERE gateway_reference = 'PSTK-DEMO-' || :trip_a \gset

BEGIN;
INSERT INTO refund (payment_id, amount, reason, approved_by)
VALUES (:payment_a, 5000.00, 'Entered against wrong customer', 9);

\echo 'Inside the transaction, the refund is visible to this session:'
SELECT count(*) AS refunds_for_payment FROM refund WHERE payment_id = :payment_a;
ROLLBACK;

\echo 'After ROLLBACK, it never happened:'
SELECT count(*) AS refunds_for_payment FROM refund WHERE payment_id = :payment_a;


\echo
\echo '======================================================================'
\echo ' TEST 4: SAVEPOINT - undoing part of a transaction'
\echo ' A delivery is completed and the customer rates it in the same'
\echo ' transaction. The app sends an invalid score (7). Only the rating'
\echo ' is rolled back to the savepoint; the delivery is kept, a corrected'
\echo ' rating is saved, and the transaction commits.'
\echo '======================================================================'
\echo 'Before:'
:state :trip_c;

BEGIN;
SELECT complete_trip(:trip_c, :vol_c, 'bank_transfer', 'TRF-DEMO-' || :trip_c) AS payment_id;

SAVEPOINT before_rating;
INSERT INTO rating (trip_id, score) VALUES (:trip_c, 7);
ROLLBACK TO SAVEPOINT before_rating;

\echo 'Rolled back to the savepoint. The delivery steps above are still pending commit.'
INSERT INTO rating (trip_id, score, comment) VALUES (:trip_c, 4, 'Good service');
COMMIT;

\echo 'After COMMIT: delivery completed and the corrected rating saved'
:state :trip_c;
SELECT trip_id, score, comment FROM rating WHERE trip_id = :trip_c;


\echo
\echo '======================================================================'
\echo ' TEST 5: BUSINESS RULE ENFORCED IN A TRANSACTION'
\echo ' Portfolio 1 noted that no foreign key can ensure a trip''s driver'
\echo ' works for the vendor that owns the tanker. assign_trip() enforces it.'
\echo '======================================================================'
-- A pending offer on a pending request, for a tanker that is available
SELECT jo.id AS offer_d, jo.request_id AS request_d, tk.vendor_id AS vendor_d
FROM job_offer jo
JOIN delivery_request r ON r.id = jo.request_id
JOIN tanker tk ON tk.id = jo.tanker_id
WHERE jo.response = 'pending' AND r.status = 'pending' AND tk.status = 'available'
ORDER BY jo.id LIMIT 1 \gset

SELECT min(id) AS right_driver FROM driver WHERE vendor_id = :vendor_d AND is_active \gset
SELECT min(id) AS wrong_driver FROM driver WHERE vendor_id <> :vendor_d \gset

\echo
\echo 'Attempt 1: driver from a different vendor. Expected: refused.'
BEGIN;
SELECT assign_trip(:offer_d, :wrong_driver) AS trip_id;
ROLLBACK;

\echo
\echo 'Attempt 2: the vendor''s own driver. Expected: trip created.'
BEGIN;
SELECT assign_trip(:offer_d, :right_driver) AS trip_id;
COMMIT;

SELECT r.id AS request, r.status AS request_status, t.id AS trip, t.status AS trip_status,
       tk.plate_number, tk.status AS tanker_status
FROM delivery_request r
JOIN trip t ON t.request_id = r.id
JOIN tanker tk ON tk.id = t.tanker_id
WHERE r.id = :request_d;

\echo
\echo '======================================================================'
\echo ' END OF DEMO 1'
\echo '======================================================================'
