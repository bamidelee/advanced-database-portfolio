-- =====================================================================
-- Scenario 3 setup: one available tanker, offered two different new
-- requests. The vendor's two drivers accept both jobs at the same moment
-- from two phones.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
DELETE FROM demo.ctx;

-- An available tanker whose verified vendor has at least two active drivers
SELECT t.id AS tanker, t.vendor_id AS vendor
FROM tanker t JOIN vendor v ON v.id = t.vendor_id
WHERE t.status = 'available' AND v.verification_status = 'verified' AND t.capacity_litres >= 5000
  AND NOT EXISTS (SELECT 1 FROM trip x WHERE x.tanker_id = t.id AND x.status IN ('assigned', 'en_route', 'arrived'))
  AND (SELECT count(*) FROM driver d WHERE d.vendor_id = t.vendor_id AND d.is_active) >= 2
ORDER BY t.id LIMIT 1 \gset

SELECT min(id) AS driver_a, max(id) AS driver_b FROM driver WHERE vendor_id = :vendor AND is_active \gset

-- Two different customers
SELECT id AS address_1, customer_id AS customer_1 FROM address ORDER BY id LIMIT 1 OFFSET 10 \gset
SELECT id AS address_2, customer_id AS customer_2 FROM address WHERE customer_id <> :customer_1 ORDER BY id LIMIT 1 OFFSET 20 \gset

INSERT INTO delivery_request (customer_id, address_id, volume_litres, quoted_price)
VALUES (:customer_1, :address_1, 5000, 20000.00) RETURNING id AS request \gset
INSERT INTO delivery_request (customer_id, address_id, volume_litres, quoted_price)
VALUES (:customer_2, :address_2, 5000, 20000.00) RETURNING id AS request2 \gset
INSERT INTO job_offer (request_id, tanker_id) VALUES (:request,  :tanker) RETURNING id AS offer_a \gset
INSERT INTO job_offer (request_id, tanker_id) VALUES (:request2, :tanker) RETURNING id AS offer_b \gset

\o /dev/null
SELECT demo.set('tanker', :tanker), demo.set('request', :request), demo.set('request2', :request2),
       demo.set('offer_a', :offer_a), demo.set('offer_b', :offer_b),
       demo.set('driver_a', :driver_a), demo.set('driver_b', :driver_b);
\o
\echo 'Setup: tanker' :tanker 'offered request' :request '(offer' :offer_a ') and request' :request2 '(offer' :offer_b ')'
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
