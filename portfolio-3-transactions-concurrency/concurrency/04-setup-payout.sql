-- =====================================================================
-- Scenario 4 setup: a vendor with unpaid earnings, plus one of their
-- tankers on a trip that has just arrived. Finance will run the
-- vendor's payout while the driver completes that delivery.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
SET client_min_messages = warning;
DELETE FROM demo.ctx;

SELECT t.id AS tanker, t.vendor_id AS vendor
FROM tanker t JOIN vendor v ON v.id = t.vendor_id
WHERE t.status = 'available' AND v.verification_status = 'verified' AND t.capacity_litres >= 5000
  AND NOT EXISTS (SELECT 1 FROM trip x WHERE x.tanker_id = t.id AND x.status IN ('assigned', 'en_route', 'arrived'))
  AND EXISTS (SELECT 1 FROM driver d WHERE d.vendor_id = t.vendor_id AND d.is_active)
  AND EXISTS (SELECT 1 FROM vendor_earning e WHERE e.vendor_id = t.vendor_id AND e.payout_id IS NULL)
ORDER BY t.id LIMIT 1 \gset

SELECT min(id) AS driver FROM driver WHERE vendor_id = :vendor AND is_active \gset
SELECT id AS address_id, customer_id FROM address ORDER BY id LIMIT 1 OFFSET 30 \gset

-- Create a request, have the vendor accept it, and move the trip to arrived
INSERT INTO delivery_request (customer_id, address_id, volume_litres, quoted_price)
VALUES (:customer_id, :address_id, 5000, 20000.00) RETURNING id AS request \gset
INSERT INTO job_offer (request_id, tanker_id) VALUES (:request, :tanker) RETURNING id AS offer \gset
SELECT assign_trip(:offer, :driver) AS trip \gset
UPDATE trip SET status = 'arrived' WHERE id = :trip;
INSERT INTO trip_status_history (trip_id, status) VALUES (:trip, 'arrived');

\o /dev/null
SELECT demo.set('vendor', :vendor), demo.set('trip', :trip);
\o
SELECT count(*) AS n, sum(net_amount) AS total
FROM vendor_earning WHERE vendor_id = :vendor AND payout_id IS NULL \gset
\echo 'Setup: vendor' :vendor 'has' :n 'unpaid earnings totalling' :total '; trip' :trip 'has just arrived at the customer'
\echo
\o /dev/null
SELECT demo.start_clock();
\o
