\pset pager off
\pset footer off
SELECT max(val) FILTER (WHERE key = 'payout') AS payout,
       max(val) FILTER (WHERE key = 'trip')   AS trip
FROM demo.ctx \gset
\echo
\echo 'Result: payout amount compared with the earnings it is recorded as covering'
SELECT p.id AS payout, p.total_amount AS amount_paid,
       count(e.id) AS earnings_marked_paid, sum(e.net_amount) AS value_marked_paid,
       CASE WHEN p.total_amount = sum(e.net_amount) THEN 'MATCH'
            ELSE 'MISMATCH: ' || (sum(e.net_amount) - p.total_amount) || ' marked paid but never paid out'
       END AS verdict
FROM payout p LEFT JOIN vendor_earning e ON e.payout_id = p.id
WHERE p.id = :payout
GROUP BY p.id;
\echo 'The new delivery''s earning (it should wait for the next payout):'
SELECT trip_id, net_amount, coalesce(payout_id::text, 'unpaid - next payout') AS payout_id
FROM vendor_earning WHERE trip_id = :trip;
