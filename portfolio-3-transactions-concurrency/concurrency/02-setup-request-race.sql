-- =====================================================================
-- Scenario 2 setup: one new request, offered to two tankers owned by
-- two different vendors. Both vendors will try to accept it at once.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
DELETE FROM demo.ctx;

-- Two available tankers from different verified vendors, each vendor
-- having an active driver
SELECT t.id AS tanker_a, t.vendor_id AS vendor_a
FROM tanker t JOIN vendor v ON v.id = t.vendor_id
WHERE t.status = 'available' AND v.verification_status = 'verified' AND t.capacity_litres >= 5000
  AND NOT EXISTS (SELECT 1 FROM trip x WHERE x.tanker_id = t.id AND x.status IN ('assigned', 'en_route', 'arrived'))
  AND EXISTS (SELECT 1 FROM driver d WHERE d.vendor_id = t.vendor_id AND d.is_active)
ORDER BY t.id LIMIT 1 \gset

SELECT t.id AS tanker_b, t.vendor_id AS vendor_b
FROM tanker t JOIN vendor v ON v.id = t.vendor_id
WHERE t.status = 'available' AND v.verification_status = 'verified' AND t.capacity_litres >= 5000
  AND NOT EXISTS (SELECT 1 FROM trip x WHERE x.tanker_id = t.id AND x.status IN ('assigned', 'en_route', 'arrived'))
  AND t.vendor_id <> :vendor_a
  AND EXISTS (SELECT 1 FROM driver d WHERE d.vendor_id = t.vendor_id AND d.is_active)
ORDER BY t.id LIMIT 1 \gset

SELECT min(id) AS driver_a FROM driver WHERE vendor_id = :vendor_a AND is_active \gset
SELECT min(id) AS driver_b FROM driver WHERE vendor_id = :vendor_b AND is_active \gset
SELECT id AS address_id, customer_id FROM address ORDER BY id LIMIT 1 \gset

INSERT INTO delivery_request (customer_id, address_id, volume_litres, quoted_price)
VALUES (:customer_id, :address_id, 5000, 20000.00) RETURNING id AS request \gset
INSERT INTO job_offer (request_id, tanker_id) VALUES (:request, :tanker_a) RETURNING id AS offer_a \gset
INSERT INTO job_offer (request_id, tanker_id) VALUES (:request, :tanker_b) RETURNING id AS offer_b \gset

\o /dev/null
SELECT demo.set('request', :request), demo.set('offer_a', :offer_a), demo.set('offer_b', :offer_b),
       demo.set('driver_a', :driver_a), demo.set('driver_b', :driver_b);
\o
\echo 'Setup: new request' :request 'offered to vendor' :vendor_a '(offer' :offer_a ') and vendor' :vendor_b '(offer' :offer_b ')'
\echo

-- Warm-up: one rolled-back insert loads the trip table's index pages
-- into memory, so the first timed insert in the demo is not slowed by
-- disk reads that could be mistaken for lock waits.
\o /dev/null
BEGIN;
INSERT INTO trip (request_id, offer_id, tanker_id, driver_id)
SELECT request_id, id, tanker_id, :driver_a FROM job_offer WHERE id = :offer_a;
ROLLBACK;
SELECT demo.start_clock();
\o
