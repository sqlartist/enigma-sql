/* =====================================================================
   Enigma in a database, Part 2: the run script (PostgreSQL + PostGIS)
   psql -d enigma -f enigma_postgis.sql -f enigma_postgis_run.sql
   Writes keypress.csv and wires.csv (for drawing the pictures).
   ===================================================================== */
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\pset footer off

\echo '--- The textbook test: I II III, B, AAA, AAA: AAAAA -> BDZGO'
SELECT enigma.setup('I II III', 'B', 'AAA', '', 'AAA');
SELECT enigma.type('AAAAA') AS lamps, 'BDZGO' AS expected;

\echo '--- The double step: ADU -> ADV -> AEW -> BFX'
SELECT enigma.setup('I II III', 'B', 'AAA', '', 'ADU');
SELECT enigma.type('AAAA');
SELECT seq, pos, key_in, lamp FROM enigma.key_log ORDER BY seq;

\echo '--- One keypress is one LINESTRING Z'
SELECT enigma.setup('I II III', 'B', 'AAA', '', 'AAA');
SELECT enigma.press('A');
SELECT key_in, lamp, hops, ST_NPoints(path) AS points, ST_NDims(path) AS dims,
       round(ST_3DLength(path)::numeric, 2) AS length_3d,
       round(ST_Length(path)::numeric, 2) AS length_flat,
       ST_AsText(ST_StartPoint(path)) AS starts, ST_AsText(ST_EndPoint(path)) AS ends
FROM enigma.key_log;

\echo '--- Turning a rotor: one ST_Affine. But turned shapes do not land exactly.'
WITH RECURSIVE spin AS
(
    SELECT 0 AS i, geom::geometry FROM enigma.rotor_wire WHERE rotor = 'I' AND contact = 0
    UNION ALL
    SELECT i + 1, enigma.turn(geom, 1) FROM spin WHERE i < 26
)
SELECT 'turned 1/26, 26 times' AS test,
       ST_Equals(s.geom, w.geom) AS back_where_it_started,
       ST_3DDistance(ST_StartPoint(s.geom), ST_StartPoint(w.geom)) AS missed_by
FROM spin s, enigma.rotor_wire w
WHERE s.i = 26 AND w.rotor = 'I' AND w.contact = 0;

\echo '--- A real message: Barbarossa, 1941'
\timing on
SELECT enigma.setup('II IV V', 'B', 'BUL', 'AV BS CG DL FU HZ IN KM OW RX', 'BLA');
SELECT enigma.type('EDPUDNRGYSZRCXNUYTPOMRMBOFKTBZREZKMLXLVEFGUEYSIOZVEQMIKUBPMMYLKLTTDEISMDICAGYKUACTCDOMOHWXMUUIAUBSTSLRNBZSZWNRFXWFYSSXJZVIJHIDISHPRKLKAYUPADTXQSPINQMATLPIFSVKDASCTACDPBOPVHJK') AS plain;
\timing off

\echo '--- Why no letter lights itself, in 3D: every path ends somewhere else'
SELECT count(*) AS keypresses,
       round(min(ST_3DDistance(ST_StartPoint(path), ST_EndPoint(path)))::numeric, 3) AS closest_finish,
       count(*) FILTER (WHERE ST_3DDWithin(ST_StartPoint(path), ST_EndPoint(path), 1e-9)) AS lit_itself
FROM enigma.key_log;

\echo '--- ...and the way back is the same wire, reversed'
-- Save the Barbarossa paths, then type the plaintext back from the same start.
CREATE TEMP TABLE first_pass AS SELECT seq, key_in, lamp, path FROM enigma.key_log;
SELECT enigma.setup('II IV V', 'B', 'BUL', 'AV BS CG DL FU HZ IN KM OW RX', 'BLA');
SELECT length(enigma.type((SELECT string_agg(lamp, '' ORDER BY seq) FROM first_pass))) AS typed_back;
SELECT count(*) AS keypresses,
       count(*) FILTER (WHERE b.lamp = a.key_in) AS came_back,
       count(*) FILTER (WHERE ST_OrderingEquals(
                          ST_SnapToGrid(b.path, ST_MakePoint(0, 0, 0), 1e-9, 1e-9, 1e-9, 0),
                          ST_SnapToGrid(ST_Reverse(a.path), ST_MakePoint(0, 0, 0), 1e-9, 1e-9, 1e-9, 0)))
         AS same_wire_reversed
FROM first_pass a JOIN enigma.key_log b USING (seq);

\echo '--- Brute force: every rotor order, position and letter (27,418,560 keypresses)'
\timing on
SELECT count(*) AS keypresses,
       count(*) FILTER (WHERE y = x) AS lit_itself,
       count(*) FILTER (WHERE enigma.scramble(lf, lb, mf, mb, rf, rb, ref, a, b, c, y) <> x) AS not_reversible
FROM (SELECT o.*, a, b, c, x,
             enigma.scramble(o.lf, o.lb, o.mf, o.mb, o.rf, o.rb, o.ref, a, b, c, x) AS y
      FROM (SELECT l.fw AS lf, l.bw AS lb, m.fw AS mf, m.bw AS mb, r.fw AS rf, r.bw AS rb,
                   (SELECT fw FROM enigma.wheel_map WHERE name = 'B') AS ref
            FROM enigma.wheel_map l, enigma.wheel_map m, enigma.wheel_map r
            WHERE l.name IN ('I','II','III','IV','V') AND m.name IN ('I','II','III','IV','V')
              AND r.name IN ('I','II','III','IV','V')
              AND l.name NOT IN (m.name, r.name) AND m.name <> r.name) o,
           generate_series(0, 25) a, generate_series(0, 25) b,
           generate_series(0, 25) c, generate_series(0, 25) x) k;
\timing off

\echo '--- Pictures: the first Barbarossa keypress, and the wires it used'
SELECT enigma.setup('II IV V', 'B', 'BUL', 'AV BS CG DL FU HZ IN KM OW RX', 'BLA');
SELECT enigma.step();                    -- the machine as it is for the first key
\copy (SELECT part, ST_AsText(geom) FROM enigma.live_wire) TO 'wires.csv' WITH CSV
SELECT enigma.setup('II IV V', 'B', 'BUL', 'AV BS CG DL FU HZ IN KM OW RX', 'BLA');
SELECT enigma.press('E');
\copy (SELECT key_in, lamp, ST_AsText(path) FROM enigma.key_log) TO 'keypress.csv' WITH CSV
