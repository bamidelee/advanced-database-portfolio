-- =====================================================================
-- Scenario 5 setup: a new vendor with exactly two active drivers.
-- Business rule: a vendor must always keep at least one active driver.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
DELETE FROM demo.ctx;

INSERT INTO vendor (business_name, owner_name, phone, bank_name, account_number,
                    verification_status, verified_by)
VALUES ('Lagoon Express Tankers', 'Demo Owner', 'DEMO-' || (SELECT count(*) + 1 FROM vendor),
        'GTBank', '0123456789', 'verified', 1)
RETURNING id AS vendor \gset

INSERT INTO driver (vendor_id, full_name, phone, licence_number)
VALUES (:vendor, 'Sola Adewale', 'DEMO-D-' || :vendor || '-1', 'DEMO-LIC-' || :vendor || '-1')
RETURNING id AS driver_a \gset
INSERT INTO driver (vendor_id, full_name, phone, licence_number)
VALUES (:vendor, 'Ifeanyi Obi', 'DEMO-D-' || :vendor || '-2', 'DEMO-LIC-' || :vendor || '-2')
RETURNING id AS driver_b \gset

\o /dev/null
SELECT demo.set('vendor', :vendor), demo.set('driver_a', :driver_a), demo.set('driver_b', :driver_b);
\o
\echo 'Setup: vendor' :vendor 'with 2 active drivers (' :driver_a 'and' :driver_b ')'
\echo
\o /dev/null
SELECT demo.start_clock();
\o
