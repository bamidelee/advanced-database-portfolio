-- =====================================================================
-- AquaFlow - Transactional Business Functions
-- MIT 8103 Advanced Database Systems - Portfolio 3
--
-- Two operations that each change several tables and must succeed or
-- fail as a whole. A PL/pgSQL function runs inside the caller's
-- transaction, so if any statement in it raises an error, every change
-- the function made is undone along with the rest of the transaction.
--
-- Run with:  psql -U postgres -d aquaflow -f functions.sql
-- =====================================================================

\set ON_ERROR_STOP on


-- ---------------------------------------------------------------------
-- assign_trip: a vendor accepts a job offer
--
-- Changes: job_offer (accepted), trip (new), trip_status_history (new),
--          delivery_request (assigned), tanker (busy)
--
-- Concurrency control: the request row and the tanker row are locked
-- with SELECT ... FOR UPDATE before anything is checked. If two vendors
-- accept the same request at the same moment, the second waits until
-- the first finishes, then sees the request is no longer pending and
-- is refused. The same applies to two requests competing for one tanker.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assign_trip(p_offer_id bigint, p_driver_id bigint)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_offer          job_offer%ROWTYPE;
  v_request_status request_status;
  v_tanker         tanker%ROWTYPE;
  v_driver         driver%ROWTYPE;
  v_trip_id        bigint;
BEGIN
  SELECT * INTO v_offer FROM job_offer WHERE id = p_offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Offer % does not exist', p_offer_id;
  END IF;

  -- Lock the request first, then the tanker. Always locking in this
  -- order prevents two transactions deadlocking on the same pair.
  SELECT status INTO v_request_status
  FROM delivery_request WHERE id = v_offer.request_id
  FOR UPDATE;

  IF v_request_status <> 'pending' THEN
    RAISE EXCEPTION 'Request % is already %', v_offer.request_id, v_request_status;
  END IF;

  SELECT * INTO v_tanker FROM tanker WHERE id = v_offer.tanker_id FOR UPDATE;

  IF v_tanker.status <> 'available' THEN
    RAISE EXCEPTION 'Tanker % is %, not available', v_tanker.plate_number, v_tanker.status;
  END IF;

  -- Business rule from Portfolio 1 that a foreign key cannot express:
  -- the driver must work for the vendor who owns the tanker.
  SELECT * INTO v_driver FROM driver WHERE id = p_driver_id;
  IF NOT FOUND OR v_driver.vendor_id <> v_tanker.vendor_id THEN
    RAISE EXCEPTION 'Driver % does not work for the vendor that owns tanker %',
      p_driver_id, v_tanker.plate_number;
  END IF;
  IF NOT v_driver.is_active THEN
    RAISE EXCEPTION 'Driver % is not active', v_driver.full_name;
  END IF;

  UPDATE job_offer SET response = 'accepted', responded_at = now()
  WHERE id = p_offer_id;

  INSERT INTO trip (request_id, offer_id, tanker_id, driver_id, status)
  VALUES (v_offer.request_id, p_offer_id, v_offer.tanker_id, p_driver_id, 'assigned')
  RETURNING id INTO v_trip_id;

  INSERT INTO trip_status_history (trip_id, status) VALUES (v_trip_id, 'assigned');

  UPDATE delivery_request SET status = 'assigned' WHERE id = v_offer.request_id;
  UPDATE tanker SET status = 'busy' WHERE id = v_offer.tanker_id;

  RETURN v_trip_id;
END;
$$;


-- ---------------------------------------------------------------------
-- complete_trip: driver confirms delivery and the customer pays
--
-- Changes: trip (completed), trip_status_history (new),
--          delivery_request (completed), payment (new),
--          vendor_earning (new), tanker (available)
--
-- If the payment cannot be recorded (for example, the gateway sends a
-- reference that already exists), the trip must NOT be left marked as
-- completed with no payment. Because everything runs in one
-- transaction, the failure undoes the earlier steps too.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION complete_trip(
  p_trip_id           bigint,
  p_volume_delivered  integer,
  p_method            payment_method,
  p_gateway_reference varchar
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip       trip%ROWTYPE;
  v_price      numeric(12,2);
  v_vendor_id  bigint;
  v_payment_id bigint;
BEGIN
  SELECT * INTO v_trip FROM trip WHERE id = p_trip_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trip % does not exist', p_trip_id;
  END IF;
  IF v_trip.status <> 'arrived' THEN
    RAISE EXCEPTION 'Trip % is %, it must have arrived before it can be completed',
      p_trip_id, v_trip.status;
  END IF;

  SELECT quoted_price INTO v_price FROM delivery_request WHERE id = v_trip.request_id;
  SELECT vendor_id INTO v_vendor_id FROM tanker WHERE id = v_trip.tanker_id;

  -- Step 1: mark the trip completed
  UPDATE trip
  SET status = 'completed', completed_at = now(), volume_delivered_litres = p_volume_delivered
  WHERE id = p_trip_id;

  INSERT INTO trip_status_history (trip_id, status) VALUES (p_trip_id, 'completed');
  RAISE NOTICE 'Step 1 done: trip % marked completed', p_trip_id;

  -- Step 2: mark the request completed
  UPDATE delivery_request SET status = 'completed' WHERE id = v_trip.request_id;
  RAISE NOTICE 'Step 2 done: request % marked completed', v_trip.request_id;

  -- Step 3: record the payment (fails on a duplicate gateway reference)
  INSERT INTO payment (request_id, amount, method, gateway_reference, status, paid_at)
  VALUES (v_trip.request_id, v_price, p_method, p_gateway_reference, 'successful', now())
  RETURNING id INTO v_payment_id;
  RAISE NOTICE 'Step 3 done: payment % recorded (%)', v_payment_id, p_gateway_reference;

  -- Step 4: credit the vendor, minus 10% platform commission
  INSERT INTO vendor_earning (trip_id, vendor_id, gross_amount, commission_amount)
  VALUES (p_trip_id, v_vendor_id, v_price, round(v_price * 0.10, 2));
  RAISE NOTICE 'Step 4 done: vendor % credited', v_vendor_id;

  -- Step 5: free the tanker for its next job
  UPDATE tanker SET status = 'available' WHERE id = v_trip.tanker_id;
  RAISE NOTICE 'Step 5 done: tanker released';

  RETURN v_payment_id;
END;
$$;
