/* =====================================================================
   Enigma in a database, Part 3: run the Bombe (PostgreSQL)
   psql -d enigma -f enigma_postgis.sql -f enigma_bombe.sql -f enigma_bombe_run.sql
   ===================================================================== */
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\set cipher 'EDPUDNRGYSZRCXNUYTPOMRMBOFKTBZREZKMLXLVEFGUEYSIOZVEQMIKUBPMMYLKLTTDEISMDICAGYKUACTCDOMOHWXMUUIAUBSTSLRNBZSZWNRFXWFYSSXJZVIJHIDISHPRKLKAYUPADTXQSPINQMATLPIFSVKDASCTACDPBOPVHJK'
\timing on
SELECT enigma.build_menu(:'cipher', 'AUFKLXABTEILUNGXVONX');
SELECT * FROM enigma.menu ORDER BY step;
SELECT * FROM enigma.bombe();
SELECT o.rotors, chr(65 + s.l) || chr(65 + s.m) || chr(65 + s.r) AS offsets, s.plugs
FROM enigma.stop s JOIN enigma.rotor_order o USING (ord_id);
SELECT rotors, rings, start, plugs, round(ioc::numeric, 4) AS ioc, plain
FROM enigma.check_stop(:'cipher') LIMIT 3;
