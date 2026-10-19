-- Scenario 4, Finance: pays out a vendor's unpaid earnings.
-- The isolation level is passed in by the runner as :iso.
\ir session-header.sql

BEGIN ISOLATION LEVEL :iso;
SELECT demo.log('BEGIN ISOLATION LEVEL ' || upper(current_setting('transaction_isolation')));

SELECT count(*) AS n, sum(net_amount) AS total
FROM vendor_earning WHERE vendor_id = :vendor AND payout_id IS NULL \gset
SELECT demo.log('Reads unpaid earnings: ' || :n || ' totalling ' || :total);
SELECT demo.pause(2, 'Finance officer checks the statement');

INSERT INTO payout (vendor_id, total_amount, status, processed_by, paid_at)
VALUES (:vendor, :total, 'paid', 9, now())
RETURNING id AS payout \gset
SELECT demo.log('Creates payout ' || :payout || ' for ' || :total);

-- Mark the earnings as paid by this payout
WITH linked AS (
  UPDATE vendor_earning SET payout_id = :payout
  WHERE vendor_id = :vendor AND payout_id IS NULL
  RETURNING net_amount
)
SELECT demo.log('Marks ' || count(*) || ' earnings worth ' || coalesce(sum(net_amount), 0) || ' as paid by payout ' || :payout)
FROM linked;

\o /dev/null
SELECT demo.set('payout', :payout);
\o
SELECT demo.log('COMMIT');
COMMIT;
