-- =====================================================================
-- AquaFlow - Constraint Tests
-- MIT 8103 Advanced Database Systems - Portfolio 1
--
-- Demonstrates that the business rules in schema.sql are enforced by
-- the database itself. Each test states the expected outcome.
--
-- Run with:
--   psql -U postgres -d aquaflow -f constraint-tests.sql
-- For guided screenshots (pauses between batches of tests), add:
--   -v pause=1
-- or simply run ./capture-evidence.sh, which does this for you.
--
-- Everything runs inside one transaction that is rolled back at the end,
-- so the database is left exactly as it was. ON_ERROR_ROLLBACK lets the
-- script continue after each expected error.
-- =====================================================================

\set ON_ERROR_ROLLBACK on
\set ON_ERROR_STOP off
\pset footer off
\pset pager off

BEGIN;

-- ---------------------------------------------------------------------
-- Setup: minimal valid data (explicit IDs so tests are predictable)
-- ---------------------------------------------------------------------
INSERT INTO staff (id, full_name, email, role) VALUES
  (1, 'Tolu Adeyemi', 'tolu@aquaflow.ng', 'operations'),
  (2, 'Ngozi Okafor', 'ngozi@aquaflow.ng', 'finance');

INSERT INTO service_area (id, name) VALUES (1, 'Ikoyi'), (2, 'Victoria Island');

INSERT INTO customer (id, full_name, phone, customer_type) VALUES
  (1, 'Chidi Eze',          '08030000001', 'household'),
  (2, 'Marina Suites Ltd',  '08030000002', 'business');

INSERT INTO address (id, customer_id, service_area_id, street_address, latitude, longitude, tank_capacity_litres, contact_name, contact_phone) VALUES
  (1, 1, 1, '12 Bourdillon Road, Ikoyi',   6.452000, 3.435000, 5000,  'Chidi Eze',     '08030000001'),
  (2, 2, 2, '5 Adeola Odeku, Victoria Island', 6.428000, 3.421000, 20000, 'Security Desk', '08030000099');

INSERT INTO vendor (id, business_name, owner_name, phone, bank_name, account_number) VALUES
  (1, 'Island Tankers', 'Musa Bello', '08050000001', 'Access Bank', '0000000001');

INSERT INTO driver (id, vendor_id, full_name, phone, licence_number) VALUES
  (1, 1, 'Kunle Ade', '08060000001', 'LAG-DRV-0001');

INSERT INTO tanker (id, vendor_id, plate_number, capacity_litres, status) VALUES
  (1, 1, 'LAG-101-AA', 10000, 'available'),
  (2, 1, 'LAG-102-AA', 10000, 'available'),
  (3, 1, 'LAG-103-AA', 10000, 'available');

INSERT INTO delivery_request (id, customer_id, address_id, volume_litres, quoted_price) VALUES
  (1, 1, 1, 5000, 25000.00);

INSERT INTO job_offer (id, request_id, tanker_id, response, responded_at) VALUES
  (1, 1, 1, 'accepted', now()),
  (2, 1, 2, 'accepted', now()),
  (3, 1, 3, 'accepted', now());

INSERT INTO trip (id, request_id, offer_id, tanker_id, driver_id) VALUES
  (1, 1, 1, 1, 1);

\echo
\echo '================ CONSTRAINT TESTS ================'
\if :{?pause}
  \echo '=== SCREENSHOT 4 of 6: Constraint tests 1-5 ==='
\endif

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 1: Request cannot use another customer''s address'
\echo 'Expected: ERROR - violates fk_request_address_belongs_to_customer'
INSERT INTO delivery_request (id, customer_id, address_id, volume_litres, quoted_price)
VALUES (2, 1, 2, 5000, 25000.00);

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 2: Only one live trip per request'
\echo 'Expected: ERROR - violates one_live_trip_per_request'
INSERT INTO trip (id, request_id, offer_id, tanker_id, driver_id)
VALUES (2, 1, 2, 2, 1);

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 3: A failed trip must have a reason'
\echo 'Expected: ERROR - violates chk_trip_failure_reason'
UPDATE trip SET status = 'failed' WHERE id = 1;

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 4: After a trip fails, the request can be retried by another tanker'
\echo 'Expected: SUCCESS - first trip failed, second trip inserted'
UPDATE trip SET status = 'failed', failure_reason = 'Tanker broke down on Third Mainland Bridge' WHERE id = 1;
INSERT INTO trip (id, request_id, offer_id, tanker_id, driver_id)
VALUES (2, 1, 2, 2, 1);
SELECT id, request_id, tanker_id, status, failure_reason FROM trip ORDER BY id;

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 5: A completed trip must record completion time and volume'
\echo 'Expected: ERROR - violates chk_trip_completion_details'
UPDATE trip SET status = 'completed' WHERE id = 2;


\if :{?pause}
  \echo
  \echo '>>> TAKE SCREENSHOT 4 NOW (save as constraint-tests-1.png), then press Enter'
  \prompt '' _continue
  \! printf '\033[2J\033[H'
\endif
\if :{?pause}
  \echo '=== SCREENSHOT 5 of 6: Constraint tests 6-10 ==='
\endif

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 6: Once a trip is completed, no further trip can be added'
\echo 'Expected: ERROR - violates one_live_trip_per_request'
UPDATE trip SET status = 'completed', completed_at = now(), volume_delivered_litres = 5000 WHERE id = 2;
INSERT INTO trip (id, request_id, offer_id, tanker_id, driver_id)
VALUES (3, 1, 3, 3, 1);

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 7: Net earnings are computed by the database'
\echo 'Expected: SUCCESS - net_amount = 25000.00 - 2500.00 = 22500.00'
INSERT INTO vendor_earning (id, trip_id, vendor_id, gross_amount, commission_amount)
VALUES (1, 2, 1, 25000.00, 2500.00);
SELECT trip_id, gross_amount, commission_amount, net_amount FROM vendor_earning;

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 8: Net earnings cannot be written directly'
\echo 'Expected: ERROR - column "net_amount" can only be updated to DEFAULT'
UPDATE vendor_earning SET net_amount = 99999.00 WHERE id = 1;

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 9: Commission cannot exceed the gross amount'
\echo 'Expected: ERROR - violates chk_earning_amounts'
UPDATE vendor_earning SET commission_amount = 30000.00 WHERE id = 1;

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 10: A trip can only earn once'
\echo 'Expected: ERROR - duplicate key violates vendor_earning_trip_id_key'
INSERT INTO vendor_earning (id, trip_id, vendor_id, gross_amount, commission_amount)
VALUES (2, 2, 1, 25000.00, 2500.00);


\if :{?pause}
  \echo
  \echo '>>> TAKE SCREENSHOT 5 NOW (save as constraint-tests-2.png), then press Enter'
  \prompt '' _continue
  \! printf '\033[2J\033[H'
\endif
\if :{?pause}
  \echo '=== SCREENSHOT 6 of 6: Constraint tests 11-15 ==='
\endif

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 11: Rating must be between 1 and 5'
\echo 'Expected: ERROR - violates chk_rating_score_range'
INSERT INTO rating (id, trip_id, score) VALUES (1, 2, 7);

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 12: Volumes and prices must be positive'
\echo 'Expected: ERROR - violates chk_request_volume_positive'
INSERT INTO delivery_request (id, customer_id, address_id, volume_litres, quoted_price)
VALUES (3, 2, 2, -500, 25000.00);

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 13: A refund must be approved by a staff member'
\echo 'Expected: ERROR - null value in column "approved_by"'
INSERT INTO payment (id, request_id, amount, method, gateway_reference, status, paid_at)
VALUES (1, 1, 25000.00, 'card', 'PSTK-TEST-0001', 'successful', now());
INSERT INTO refund (id, payment_id, amount, reason)
VALUES (1, 1, 5000.00, 'Partial delivery');

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 14: A vendor cannot be marked verified without a verifying staff member'
\echo 'Expected: ERROR - violates chk_vendor_verified_by'
UPDATE vendor SET verification_status = 'verified' WHERE id = 1;

-- ---------------------------------------------------------------------
\echo
\echo 'TEST 15: Duplicate tanker plate numbers are rejected'
\echo 'Expected: ERROR - duplicate key violates tanker_plate_number_key'
INSERT INTO tanker (id, vendor_id, plate_number, capacity_litres)
VALUES (4, 1, 'LAG-101-AA', 15000);

\echo
\echo '================ END OF TESTS ================'
\echo 'Rolling back all test data...'

ROLLBACK;

\if :{?pause}
  \echo
  \echo '>>> TAKE SCREENSHOT 6 NOW (save as constraint-tests-3.png), then press Enter'
  \prompt '' _continue
\endif
