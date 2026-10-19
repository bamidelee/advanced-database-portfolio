\pset pager off
\pset footer off
SELECT val AS request FROM demo.ctx WHERE key = 'request' \gset
\echo
\echo 'Result: trips created for the request (expected exactly one)'
SELECT t.id AS trip, t.offer_id AS offer, t.tanker_id AS tanker, t.status, r.status AS request_status
FROM trip t JOIN delivery_request r ON r.id = t.request_id
WHERE t.request_id = :request;
