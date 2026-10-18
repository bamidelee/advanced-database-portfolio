-- =====================================================================
-- AquaFlow - Seed Data Generator
-- MIT 8103 Advanced Database Systems - Portfolio 2
--
-- Generates about two years of realistic operating data for the
-- AquaFlow schema, entirely inside PostgreSQL using set-based
-- INSERT ... SELECT with generate_series().
--
-- Approximate volumes:
--   50,000 customers, ~67,000 addresses, 400 vendors, ~1,000 drivers,
--   ~1,200 tankers, 300,000 delivery requests, ~600,000 job offers,
--   ~290,000 trips, ~1.1 million status history rows, plus payments,
--   refunds, earnings, payouts and ratings.
--
-- Run with:
--   psql -U postgres -d aquaflow -f seed.sql
--
-- The script is deterministic (setseed) so every run produces the same
-- data, and it wipes all tables first, so it can be rerun safely.
-- =====================================================================

\set ON_ERROR_STOP on
\timing on

BEGIN;

-- Fixed seed: identical data on every run, so query timings are comparable
SELECT setseed(0.2026);

TRUNCATE staff, service_area, pricing_rule, customer, address, vendor,
  driver, tanker, delivery_request, job_offer, trip, trip_status_history,
  payment, refund, payout, vendor_earning, rating
  RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- Reference data used only during seeding
-- ---------------------------------------------------------------------
CREATE TEMP TABLE names ON COMMIT DROP AS
SELECT
  ARRAY['Adebayo','Chinedu','Aisha','Ngozi','Tunde','Funmilayo','Emeka','Fatima',
        'Oluwaseun','Ifeoma','Musa','Yetunde','Ikechukwu','Zainab','Babajide',
        'Chiamaka','Ibrahim','Kemi','Obinna','Halima','Segun','Adaeze','Usman',
        'Bukola','Nnamdi','Amina','Femi','Uchenna','Hauwa','Damilola','Kelechi',
        'Sade','Yusuf','Ebere','Tobi','Nkechi','Abubakar','Folake','Chukwuemeka',
        'Rukayat'] AS first_names,
  ARRAY['Adeyemi','Okafor','Bello','Eze','Ogunleye','Nwosu','Abubakar','Balogun',
        'Okonkwo','Ibrahim','Adebayo','Obi','Mohammed','Olawale','Chukwu','Lawal',
        'Ojo','Nwachukwu','Suleiman','Akande','Uche','Danjuma','Oyelaran','Igwe',
        'Afolabi','Onyeka','Garba','Fashola','Okeke','Bakare'] AS last_names,
  ARRAY['Marina','Island','Eko','Atlantic','Lagoon','Palm','Royal','Harbour',
        'Crown','Bay'] AS biz_prefix,
  ARRAY['Suites','Towers','Plaza','Apartments','Hotel','Hospital','Restaurant',
        'Estates','Court','Residences'] AS biz_suffix,
  ARRAY['Island','Eko','Clearwater','Lagoon','Aqua','Blue Wave','Fresh Spring',
        'Atlantic','Pure Flow','Marina'] AS vendor_prefix,
  ARRAY['Water Tankers','Haulage','Water Services','Water Supply'] AS vendor_suffix,
  ARRAY['Access Bank','GTBank','Zenith Bank','First Bank','UBA','Opay',
        'Moniepoint','Kuda'] AS banks;

CREATE TEMP TABLE area_ref (
  id int, name text, lat numeric, lng numeric, premium numeric, streets text[]
) ON COMMIT DROP;

INSERT INTO area_ref VALUES
  (1, 'Lagos Island',     6.4550, 3.3940, 1.00, ARRAY['Broad Street','Nnamdi Azikiwe Street','Idumota Road','Balogun Street','Martins Street','Docemo Street']),
  (2, 'Ikoyi',            6.4520, 3.4350, 1.30, ARRAY['Bourdillon Road','Awolowo Road','Kingsway Road','Glover Road','Alexander Avenue','Thompson Avenue']),
  (3, 'Victoria Island',  6.4280, 3.4210, 1.30, ARRAY['Adeola Odeku Street','Ahmadu Bello Way','Akin Adesola Street','Ajose Adeogun Street','Ozumba Mbadiwe Avenue','Saka Tinubu Street']),
  (4, 'Obalende',         6.4480, 3.4040, 1.00, ARRAY['Obalende Road','Keffi Street','Ikoyi Road','Moloney Street']),
  (5, 'Marina',           6.4485, 3.3900, 1.10, ARRAY['Marina Road','Custom Street','Odunlami Street','Breadfruit Street']),
  (6, 'Onikan',           6.4440, 3.4000, 1.10, ARRAY['King George V Road','Onikan Road','Bishop Street','Campbell Street']);

-- ---------------------------------------------------------------------
-- Staff: 8 operations, 8 finance, 4 admin
-- ---------------------------------------------------------------------
INSERT INTO staff (id, full_name, email, role)
SELECT g,
       fn || ' ' || ln,
       lower(fn || '.' || ln || g) || '@aquaflow.ng',
       CASE WHEN g <= 8 THEN 'operations' WHEN g <= 16 THEN 'finance' ELSE 'admin' END::staff_role
FROM generate_series(1, 20) g
CROSS JOIN names n
CROSS JOIN LATERAL (
  SELECT n.first_names[1 + (g * 7) % 40] AS fn,
         n.last_names[1 + (g * 11) % 30] AS ln
) x;

-- ---------------------------------------------------------------------
-- Service areas and pricing (four price changes over the period)
-- ---------------------------------------------------------------------
INSERT INTO service_area (id, name)
SELECT id, name FROM area_ref;

INSERT INTO pricing_rule (service_area_id, price_per_1000_litres, effective_from, created_by)
SELECT a.id,
       round(p.base * a.premium, 2),
       now() - p.days_ago * interval '1 day',
       1 + (a.id + p.step) % 8                      -- an operations staff member
FROM area_ref a
CROSS JOIN (VALUES (1, 900, 2500), (2, 540, 3000), (3, 270, 3500), (4, 90, 4000))
  AS p(step, days_ago, base);

-- ---------------------------------------------------------------------
-- Customers: 50,000 (about 15% businesses)
-- ---------------------------------------------------------------------
INSERT INTO customer (id, full_name, phone, email, customer_type, created_at)
SELECT g,
       CASE WHEN is_biz
            THEN n.biz_prefix[1 + floor(r2 * 10)::int] || ' ' || n.biz_suffix[1 + floor(r3 * 10)::int] || ' Ltd'
            ELSE n.first_names[1 + floor(r2 * 40)::int] || ' ' || n.last_names[1 + floor(r3 * 30)::int]
       END,
       '080' || lpad(g::text, 8, '0'),
       CASE WHEN r4 < 0.7 THEN 'customer' || g || '@example.com' END,
       CASE WHEN is_biz THEN 'business' ELSE 'household' END::customer_type,
       now() - interval '800 days' + r5 * interval '780 days'
FROM (
  SELECT g, random() < 0.15 AS is_biz, random() AS r2, random() AS r3,
         random() AS r4, random() AS r5
  FROM generate_series(1, 50000) g
) c
CROSS JOIN names n;

-- ---------------------------------------------------------------------
-- Addresses: every customer has one; about 35% have a second
-- ---------------------------------------------------------------------
INSERT INTO address (id, customer_id, service_area_id, label, street_address,
                     latitude, longitude, tank_capacity_litres,
                     contact_name, contact_phone, access_notes)
SELECT row_number() OVER (ORDER BY c.id, s.n),
       c.id,
       a.id,
       CASE WHEN c.customer_type = 'business'
            THEN CASE WHEN s.n = 1 THEN 'Head Office' ELSE 'Branch' END
            ELSE CASE WHEN s.n = 1 THEN 'Home' ELSE 'Second Home' END END,
       (1 + floor(s.r1 * 120))::int || ' ' || a.streets[1 + floor(s.r2 * cardinality(a.streets))::int],
       round(a.lat + (s.r3::numeric - 0.5) * 0.016, 6),
       round(a.lng + (s.r4::numeric - 0.5) * 0.016, 6),
       CASE WHEN c.customer_type = 'business'
            THEN (2 + floor(s.r5 * 9))::int * 5000                -- 10,000 to 50,000
            ELSE (ARRAY[2000, 3000, 5000])[1 + floor(s.r5 * 3)::int] END,
       CASE WHEN c.customer_type = 'business'
            THEN (ARRAY['Security Desk', 'Facility Manager', 'Front Desk'])[1 + floor(s.r1 * 3)::int]
            ELSE c.full_name END,
       CASE WHEN c.customer_type = 'business'
            THEN '081' || lpad((c.id * 2 + s.n)::text, 8, '0')
            ELSE c.phone END,
       CASE WHEN s.r6 < 0.25
            THEN (ARRAY['Gate closes at 10pm', 'Call on arrival', 'Tank is on the roof, long hose needed',
                        'Narrow street, small tanker preferred', 'Enter through the back gate'])[1 + floor(s.r6 * 20)::int]
       END
FROM customer c
CROSS JOIN LATERAL (
  SELECT n, random() AS r1, random() AS r2, random() AS r3, random() AS r4,
         random() AS r5, random() AS r6,
         1 + floor(random() * 6)::int AS area_id
  FROM generate_series(1, 1 + (random() < 0.35 AND c.id > 0)::int) n
) s
JOIN area_ref a ON a.id = s.area_id;

-- ---------------------------------------------------------------------
-- Vendors: 400 (90% verified)
-- ---------------------------------------------------------------------
INSERT INTO vendor (id, business_name, owner_name, phone, bank_name, account_number,
                    verification_status, verified_by, created_at)
SELECT g,
       n.vendor_prefix[1 + floor(r1 * 10)::int] || ' ' || n.vendor_suffix[1 + floor(r2 * 4)::int],
       n.first_names[1 + floor(r3 * 40)::int] || ' ' || n.last_names[1 + floor(r4 * 30)::int],
       '070' || lpad(g::text, 8, '0'),
       n.banks[1 + floor(r5 * 8)::int],
       lpad((1000000000 + g * 7919)::text, 10, '0'),
       CASE WHEN r6 < 0.90 THEN 'verified' WHEN r6 < 0.96 THEN 'pending' ELSE 'suspended' END::verification_status,
       CASE WHEN r6 < 0.90 OR r6 >= 0.96 THEN 1 + floor(r1 * 8)::int END,
       now() - interval '1000 days' + r2 * interval '100 days'
FROM (
  SELECT g, random() r1, random() r2, random() r3, random() r4, random() r5, random() r6
  FROM generate_series(1, 400) g
) v
CROSS JOIN names n;

-- ---------------------------------------------------------------------
-- Drivers: 1 to 4 per vendor
-- ---------------------------------------------------------------------
INSERT INTO driver (id, vendor_id, full_name, phone, licence_number)
SELECT row_number() OVER (ORDER BY v.id, s.n),
       v.id,
       n.first_names[1 + floor(s.r1 * 40)::int] || ' ' || n.last_names[1 + floor(s.r2 * 30)::int],
       '090' || lpad((v.id * 10 + s.n)::text, 8, '0'),
       'LAG-DRV-' || lpad((v.id * 10 + s.n)::text, 6, '0')
FROM vendor v
CROSS JOIN LATERAL (
  SELECT n, random() r1, random() r2
  FROM generate_series(1, 1 + floor(random() * 4)::int + (v.id * 0)) n
) s
CROSS JOIN names n;

-- ---------------------------------------------------------------------
-- Tankers: 1 to 5 per vendor, in four common capacities
-- ---------------------------------------------------------------------
INSERT INTO tanker (id, vendor_id, plate_number, capacity_litres, status)
SELECT row_number() OVER (ORDER BY v.id, s.n),
       v.id,
       'LAG-' || lpad((v.id * 10 + s.n)::text, 5, '0') || 'TK',
       CASE WHEN s.r1 < 0.30 THEN 10000 WHEN s.r1 < 0.55 THEN 15000
            WHEN s.r1 < 0.80 THEN 20000 ELSE 33000 END,
       CASE WHEN s.r2 < 0.45 THEN 'available' WHEN s.r2 < 0.65 THEN 'busy'
            WHEN s.r2 < 0.95 THEN 'offline' ELSE 'maintenance' END::tanker_status
FROM vendor v
CROSS JOIN LATERAL (
  SELECT n, random() r1, random() r2
  FROM generate_series(1, 1 + floor(random() * 5)::int + (v.id * 0)) n
) s;

-- Lookup helpers: drivers per vendor, and tankers able to carry each volume
CREATE TEMP TABLE vendor_drivers ON COMMIT DROP AS
SELECT vendor_id, array_agg(id ORDER BY id) AS ids FROM driver GROUP BY vendor_id;

CREATE TEMP TABLE volume_tankers ON COMMIT DROP AS
SELECT v.volume, array_agg(t.id ORDER BY t.id) AS ids
FROM (VALUES (2000), (3000), (5000), (10000), (15000), (20000), (33000)) v(volume)
JOIN tanker t ON t.capacity_litres >= v.volume
GROUP BY v.volume;

-- ---------------------------------------------------------------------
-- Delivery requests: 300,000, weighted towards recent months (growth)
-- ---------------------------------------------------------------------
-- A plan table fixes each request's outcome up front, so offers, trips
-- and payments can all be generated consistently from it.
CREATE TEMP TABLE request_plan ON COMMIT DROP AS
SELECT g AS id,
       a.id AS address_id,
       a.customer_id,
       a.service_area_id,
       c.customer_type,
       c.created_at + (now() - c.created_at) * power(random(), 0.6) AS created_at,
       random() AS r_vol, random() AS r_sched, random() AS r_status,
       random() AS r_retry, random() AS r_decl, random() AS r_tanker
FROM generate_series(1, 300000) g
JOIN address a ON a.id = 1 + ((g * 2654435761::bigint) % (SELECT count(*) FROM address))
JOIN customer c ON c.id = a.customer_id;

ALTER TABLE request_plan
  ADD COLUMN volume int, ADD COLUMN scheduled_for timestamptz,
  ADD COLUMN start_at timestamptz, ADD COLUMN status request_status,
  ADD COLUMN n_declines int, ADD COLUMN attempts int;

UPDATE request_plan SET
  volume = CASE WHEN customer_type = 'business'
                THEN CASE WHEN r_vol < 0.40 THEN 10000 WHEN r_vol < 0.65 THEN 15000
                          WHEN r_vol < 0.90 THEN 20000 ELSE 33000 END
                ELSE CASE WHEN r_vol < 0.30 THEN 2000 WHEN r_vol < 0.60 THEN 3000
                          WHEN r_vol < 0.95 THEN 5000 ELSE 10000 END END,
  scheduled_for = CASE WHEN r_sched < 0.20
                       THEN date_trunc('hour', created_at) + (1 + floor(r_sched * 15)::int) * interval '1 day' END;

UPDATE request_plan SET start_at = coalesce(scheduled_for, created_at);

UPDATE request_plan SET
  status = CASE
             WHEN start_at > now() THEN 'pending'
             WHEN start_at > now() - interval '8 hours'
               THEN CASE WHEN r_status < 0.3 THEN 'pending' ELSE 'assigned' END
             WHEN r_status < 0.92 THEN 'completed'
             ELSE 'cancelled'
           END::request_status,
  n_declines = floor(r_decl * 3)::int;                       -- 0 to 2 declines first

UPDATE request_plan SET
  attempts = CASE status
               WHEN 'completed' THEN CASE WHEN r_retry < 0.07 THEN 2 ELSE 1 END  -- 7% need a retry
               WHEN 'assigned'  THEN 1
               ELSE 0 END,
  n_declines = CASE WHEN status = 'cancelled' THEN n_declines + 1 ELSE n_declines END;

INSERT INTO delivery_request (id, customer_id, address_id, volume_litres, scheduled_for,
                              quoted_price, status, created_at)
SELECT rp.id, rp.customer_id, rp.address_id, rp.volume, rp.scheduled_for,
       round(rp.volume / 1000.0 * pr.price_per_1000_litres, 2),
       rp.status, rp.created_at
FROM request_plan rp
CROSS JOIN LATERAL (
  SELECT price_per_1000_litres
  FROM pricing_rule p
  WHERE p.service_area_id = rp.service_area_id AND p.effective_from <= rp.created_at
  ORDER BY p.effective_from DESC
  LIMIT 1
) pr;

-- ---------------------------------------------------------------------
-- Job offers: declined/expired offers first, then one accepted offer per attempt
-- ---------------------------------------------------------------------
CREATE TEMP TABLE offer_plan ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY rp.id, k) AS id,
       rp.id AS request_id,
       k,
       k - rp.n_declines AS attempt,                          -- <= 0 means a decline
       vt.ids[1 + (floor(rp.r_tanker * cardinality(vt.ids))::int + k) % cardinality(vt.ids)] AS tanker_id,
       rp.start_at
         + (k - 1) * interval '6 minutes'
         + CASE WHEN k - rp.n_declines = 2 THEN interval '2 hours' ELSE interval '0' END AS offered_at,
       CASE
         WHEN rp.status = 'pending'      THEN 'pending'
         WHEN k <= rp.n_declines         THEN CASE WHEN random() < 0.7 THEN 'declined' ELSE 'expired' END
         ELSE 'accepted'
       END::offer_response AS response,
       rp.status AS request_status,
       rp.attempts
FROM request_plan rp
JOIN volume_tankers vt ON vt.volume = rp.volume
CROSS JOIN LATERAL generate_series(
  1, CASE WHEN rp.status = 'pending' THEN 1 + (rp.r_decl < 0.5)::int
          ELSE rp.n_declines + rp.attempts END) k;

INSERT INTO job_offer (id, request_id, tanker_id, offered_at, responded_at, response)
SELECT id, request_id, tanker_id, offered_at,
       CASE WHEN response <> 'pending' THEN offered_at + (1 + floor(random() * 4)::int) * interval '1 minute' END,
       response
FROM offer_plan;

-- ---------------------------------------------------------------------
-- Trips: one per accepted offer. Earlier attempts fail, the last succeeds.
-- ---------------------------------------------------------------------
INSERT INTO trip (id, request_id, offer_id, tanker_id, driver_id, status,
                  volume_delivered_litres, failure_reason, assigned_at, completed_at)
SELECT row_number() OVER (ORDER BY o.id),
       o.request_id, o.id, o.tanker_id,
       vd.ids[1 + floor(x.r1 * cardinality(vd.ids))::int],
       x.status,
       CASE WHEN x.status = 'completed'
            THEN CASE WHEN x.r2 < 0.03 THEN dr.volume_litres - 1000 ELSE dr.volume_litres END END,
       CASE WHEN x.status = 'failed'
            THEN (ARRAY['Tanker broke down', 'Customer unreachable on arrival',
                        'Gate access denied at estate', 'Road blocked by flooding',
                        'Gridlock on Third Mainland Bridge', 'Driver unavailable',
                        'Fill point ran out of water'])[1 + floor(x.r2 * 7)::int] END,
       jo.responded_at,
       CASE WHEN x.status = 'completed'
            THEN jo.responded_at + (40 + floor(x.r3 * 140)::int) * interval '1 minute' END
FROM offer_plan o
JOIN job_offer jo ON jo.id = o.id
JOIN delivery_request dr ON dr.id = o.request_id
JOIN tanker t ON t.id = o.tanker_id
JOIN vendor_drivers vd ON vd.vendor_id = t.vendor_id
CROSS JOIN LATERAL (
  SELECT random() r1, random() r2, random() r3,
         CASE
           WHEN o.request_status = 'assigned'
             THEN (ARRAY['assigned', 'en_route', 'arrived'])[1 + floor(random() * 3)::int + (o.id * 0)]
           WHEN o.attempt < o.attempts THEN 'failed'
           ELSE 'completed'
         END::trip_status AS status
) x
WHERE o.response = 'accepted';

-- Tankers on an active trip are busy
UPDATE tanker SET status = 'busy'
WHERE id IN (SELECT tanker_id FROM trip WHERE status IN ('assigned', 'en_route', 'arrived'));

-- ---------------------------------------------------------------------
-- Trip status history
-- ---------------------------------------------------------------------
INSERT INTO trip_status_history (trip_id, status, changed_at)
SELECT id, 'assigned'::trip_status, assigned_at FROM trip
UNION ALL
SELECT id, 'en_route', assigned_at + (5 + floor(random() * 10)::int) * interval '1 minute'
FROM trip WHERE status IN ('en_route', 'arrived', 'completed', 'failed')
UNION ALL
SELECT id, 'arrived', coalesce(completed_at - (10 + floor(random() * 15)::int) * interval '1 minute',
                               assigned_at + interval '30 minutes')
FROM trip WHERE status IN ('arrived', 'completed')
UNION ALL
SELECT id, 'completed', completed_at FROM trip WHERE status = 'completed'
UNION ALL
SELECT id, 'failed', assigned_at + (30 + floor(random() * 60)::int) * interval '1 minute'
FROM trip WHERE status = 'failed'
ORDER BY 3;

-- ---------------------------------------------------------------------
-- Payments: one per completed request, after delivery
-- ---------------------------------------------------------------------
INSERT INTO payment (id, request_id, amount, method, gateway_reference, status, paid_at)
SELECT row_number() OVER (ORDER BY t.completed_at),
       dr.id, dr.quoted_price, x.method,
       CASE WHEN x.method = 'card' THEN 'PSTK-' ELSE 'TRF-' END || lpad(dr.id::text, 9, '0'),
       'successful',
       t.completed_at + (1 + floor(x.r * 10)::int) * interval '1 minute'
FROM delivery_request dr
JOIN trip t ON t.request_id = dr.id AND t.status = 'completed'
CROSS JOIN LATERAL (
  SELECT random() AS r,
         CASE WHEN random() < 0.6 + (dr.id * 0) THEN 'card' ELSE 'bank_transfer' END::payment_method AS method
) x;

-- Refunds on about 1.5% of payments, approved by finance staff
INSERT INTO refund (payment_id, amount, reason, approved_by, refunded_at)
SELECT p.id,
       round(p.amount * (0.1 + x.r1::numeric * 0.4), 2),
       (ARRAY['Partial delivery', 'Delivery much later than promised',
              'Water quality complaint', 'Overcharged volume'])[1 + floor(x.r2 * 4)::int],
       9 + floor(x.r3 * 8)::int,
       least(now(), p.paid_at + (1 + floor(x.r1 * 5)::int) * interval '1 day')
FROM payment p
CROSS JOIN LATERAL (SELECT random() r0, random() r1, random() r2, random() r3 WHERE p.id > 0) x
WHERE x.r0 < 0.015;

-- ---------------------------------------------------------------------
-- Vendor earnings: one per completed trip, 10% platform commission
-- ---------------------------------------------------------------------
INSERT INTO vendor_earning (id, trip_id, vendor_id, gross_amount, commission_amount)
SELECT row_number() OVER (ORDER BY t.id),
       t.id, tk.vendor_id, dr.quoted_price, round(dr.quoted_price * 0.10, 2)
FROM trip t
JOIN tanker tk ON tk.id = t.tanker_id
JOIN delivery_request dr ON dr.id = t.request_id
WHERE t.status = 'completed';

-- Monthly payouts per vendor for every month before the current one
CREATE TEMP TABLE payout_plan ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY month, ve.vendor_id) AS id,
       ve.vendor_id, month, sum(ve.net_amount) AS total
FROM vendor_earning ve
JOIN trip t ON t.id = ve.trip_id
CROSS JOIN LATERAL (SELECT date_trunc('month', t.completed_at) AS month) m
WHERE t.completed_at < date_trunc('month', now())
GROUP BY ve.vendor_id, month;

INSERT INTO payout (id, vendor_id, total_amount, status, processed_by, paid_at)
SELECT id, vendor_id, total, 'paid', 9 + (id % 8)::int, least(now(), month + interval '1 month 2 days')
FROM payout_plan;

UPDATE vendor_earning ve
SET payout_id = pp.id
FROM trip t, payout_plan pp
WHERE t.id = ve.trip_id
  AND pp.vendor_id = ve.vendor_id
  AND pp.month = date_trunc('month', t.completed_at);

-- ---------------------------------------------------------------------
-- Ratings on about 60% of completed trips, skewed positive
-- ---------------------------------------------------------------------
INSERT INTO rating (trip_id, score, comment, created_at)
SELECT t.id,
       CASE WHEN x.r1 < 0.05 THEN 1 WHEN x.r1 < 0.10 THEN 2 WHEN x.r1 < 0.20 THEN 3
            WHEN x.r1 < 0.50 THEN 4 ELSE 5 END,
       CASE WHEN x.r2 < 0.2
            THEN (ARRAY['Fast and polite driver', 'Arrived late', 'Water was clean',
                        'Driver called ahead, very helpful', 'Hose too short for our tank'])[1 + floor(x.r3 * 5)::int] END,
       least(now(), t.completed_at + (10 + floor(x.r3 * 110)::int) * interval '1 minute')
FROM trip t
CROSS JOIN LATERAL (SELECT random() r0, random() r1, random() r2, random() r3 WHERE t.id > 0) x
WHERE t.status = 'completed' AND x.r0 < 0.6;

-- ---------------------------------------------------------------------
-- Move identity counters past the explicitly inserted IDs.
-- Without this, the next INSERT that relies on an automatic ID
-- would collide with an existing row.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['staff','service_area','pricing_rule','customer','address',
    'vendor','driver','tanker','delivery_request','job_offer','trip','trip_status_history',
    'payment','refund','payout','vendor_earning','rating']
  LOOP
    EXECUTE format(
      'SELECT setval(pg_get_serial_sequence(%L, ''id''), COALESCE((SELECT max(id) FROM %I), 0) + 1, false)',
      t, t);
  END LOOP;
END $$;

COMMIT;

-- Refresh planner statistics so EXPLAIN reflects the new data
ANALYZE;

-- ---------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------
\pset pager off
SELECT 'customer' AS table_name, count(*) AS row_count FROM customer
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'vendor', count(*) FROM vendor
UNION ALL SELECT 'driver', count(*) FROM driver
UNION ALL SELECT 'tanker', count(*) FROM tanker
UNION ALL SELECT 'pricing_rule', count(*) FROM pricing_rule
UNION ALL SELECT 'delivery_request', count(*) FROM delivery_request
UNION ALL SELECT 'job_offer', count(*) FROM job_offer
UNION ALL SELECT 'trip', count(*) FROM trip
UNION ALL SELECT 'trip_status_history', count(*) FROM trip_status_history
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'refund', count(*) FROM refund
UNION ALL SELECT 'vendor_earning', count(*) FROM vendor_earning
UNION ALL SELECT 'payout', count(*) FROM payout
UNION ALL SELECT 'rating', count(*) FROM rating
UNION ALL SELECT 'staff', count(*) FROM staff
UNION ALL SELECT 'service_area', count(*) FROM service_area
ORDER BY row_count DESC;
