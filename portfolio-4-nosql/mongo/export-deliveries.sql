-- =====================================================================
-- AquaFlow - Export delivery documents from PostgreSQL
-- MIT 8103 Advanced Database Systems - Portfolio 4
--
-- Builds one MongoDB document per delivery request from the last 60
-- days, joining the request with its customer, address, trips, status
-- history, tanker, driver, vendor, payment, refunds and rating.
-- Prints one JSON document per line, for mongoimport.
--
-- Dates and money use MongoDB Extended JSON ({"$date": ...},
-- {"$numberDecimal": ...}) so they import as real date and decimal
-- types rather than strings or floating point numbers.
-- json_strip_nulls() removes empty optional fields, so a delivery with
-- no rating simply has no "rating" field.
-- =====================================================================
\pset tuples_only on
\pset format unaligned
\pset pager off
SET client_min_messages = warning;

CREATE FUNCTION pg_temp.jdate(timestamptz) RETURNS json LANGUAGE sql STRICT AS $$
  SELECT json_build_object('$date', to_char($1 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
$$;
CREATE FUNCTION pg_temp.jdec(numeric) RETURNS json LANGUAGE sql STRICT AS $$
  SELECT json_build_object('$numberDecimal', $1::text)
$$;

SELECT json_strip_nulls(json_build_object(
  '_id', r.id,
  'customer', json_build_object(
      'id', c.id, 'name', c.full_name, 'type', c.customer_type, 'phone', c.phone),
  'address', json_build_object(
      'label', a.label,
      'street', a.street_address,
      'area', sa.name,
      'location', json_build_object('type', 'Point', 'coordinates', json_build_array(a.longitude, a.latitude)),
      'tank_capacity_litres', a.tank_capacity_litres,
      'contact', json_build_object('name', a.contact_name, 'phone', a.contact_phone),
      'access_notes', a.access_notes),
  'volume_litres', r.volume_litres,
  'quoted_price', pg_temp.jdec(r.quoted_price),
  'scheduled_for', pg_temp.jdate(r.scheduled_for),
  'status', r.status,
  'created_at', pg_temp.jdate(r.created_at),
  'attempts', coalesce((
      SELECT json_agg(json_build_object(
               'trip_id', t.id,
               'tanker', json_build_object('id', tk.id, 'plate', tk.plate_number,
                                           'capacity_litres', tk.capacity_litres,
                                           'vendor_id', v.id, 'vendor_name', v.business_name),
               'driver', json_build_object('id', d.id, 'name', d.full_name, 'phone', d.phone),
               'status', t.status,
               'failure_reason', t.failure_reason,
               'assigned_at', pg_temp.jdate(t.assigned_at),
               'completed_at', pg_temp.jdate(t.completed_at),
               'volume_delivered_litres', t.volume_delivered_litres,
               'timeline', (SELECT json_agg(json_build_object('status', h.status, 'at', pg_temp.jdate(h.changed_at))
                                            ORDER BY h.changed_at)
                            FROM trip_status_history h WHERE h.trip_id = t.id))
             ORDER BY t.assigned_at)
      FROM trip t
      JOIN tanker tk ON tk.id = t.tanker_id
      JOIN vendor v  ON v.id = tk.vendor_id
      JOIN driver d  ON d.id = t.driver_id
      WHERE t.request_id = r.id), '[]'::json),
  'payment', (
      SELECT json_build_object(
               'method', p.method, 'amount', pg_temp.jdec(p.amount),
               'reference', p.gateway_reference, 'status', p.status,
               'paid_at', pg_temp.jdate(p.paid_at),
               'refunds', (SELECT json_agg(json_build_object('amount', pg_temp.jdec(f.amount),
                                                             'reason', f.reason,
                                                             'at', pg_temp.jdate(f.refunded_at)))
                           FROM refund f WHERE f.payment_id = p.id))
      FROM payment p WHERE p.request_id = r.id),
  'rating', (
      SELECT json_build_object('score', rt.score, 'comment', rt.comment, 'at', pg_temp.jdate(rt.created_at))
      FROM rating rt JOIN trip t2 ON t2.id = rt.trip_id
      WHERE t2.request_id = r.id)
))
FROM delivery_request r
JOIN customer c      ON c.id = r.customer_id
JOIN address a       ON a.id = r.address_id
JOIN service_area sa ON sa.id = a.service_area_id
WHERE r.created_at >= now() - interval '60 days'
ORDER BY r.id;
