/* =====================================================================
   Enigma in a database, Part 3: the Bombe (PostgreSQL, no geometry)
   ---------------------------------------------------------------------
   The same Bombe as the SQL Server version, line for line, so the
   race is fair. Needs enigma_postgis.sql first (for enigma.wheel_map
   and enigma.scramble). Run with:  psql -d enigma -f enigma_bombe.sql
   ===================================================================== */
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS enigma.cur, enigma.nxt, enigma.rotor_order, enigma.drum, enigma.menu, enigma.stop CASCADE;

/* 1. DRUMS: 60 rotor orders x 17,576 offsets, whole alphabet each */
CREATE TABLE enigma.rotor_order AS
SELECT row_number() OVER (ORDER BY l.name, m.name, r.name)::int AS ord_id,
       l.name || ' ' || m.name || ' ' || r.name AS rotors,
       l.fw AS lf, l.bw AS lb, m.fw AS mf, m.bw AS mb, r.fw AS rf, r.bw AS rb,
       (SELECT fw FROM enigma.wheel_map WHERE name = 'B') AS ref
FROM enigma.wheel_map l, enigma.wheel_map m, enigma.wheel_map r
WHERE l.name IN ('I','II','III','IV','V') AND m.name IN ('I','II','III','IV','V')
  AND r.name IN ('I','II','III','IV','V')
  AND l.name NOT IN (m.name, r.name) AND m.name <> r.name;

\timing on
-- one row per drum position; the alphabet is worked out in a subquery so
-- PostgreSQL doesn't sort 27 million rows to group them back together
CREATE TABLE enigma.drum AS
SELECT o.ord_id, a AS l, b AS m, c AS r,
       (SELECT string_agg(chr(65 + enigma.scramble(o.lf, o.lb, o.mf, o.mb, o.rf, o.rb, o.ref, a, b, c, x)), ''
                          ORDER BY x)
        FROM generate_series(0, 25) x) AS perm
FROM enigma.rotor_order o, generate_series(0, 25) a, generate_series(0, 25) b, generate_series(0, 25) c;
\timing off
ALTER TABLE enigma.drum ADD PRIMARY KEY (ord_id, l, m, r);
ANALYZE enigma.drum;

/* 2. THE MENU: same walk as SQL Server (busiest letter, loops first) */
CREATE TABLE enigma.menu (step int PRIMARY KEY, pos int, known char(1), other char(1), closes bool);

CREATE OR REPLACE FUNCTION enigma.build_menu(p_cipher text, p_crib text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e record; known text[]; s int := 0;
BEGIN
    DELETE FROM enigma.menu;
    CREATE TEMP TABLE IF NOT EXISTS edge (pos int, a char(1), b char(1), used bool);
    TRUNCATE edge;
    INSERT INTO edge SELECT i, substr(p_crib, i + 1, 1), substr(p_cipher, i + 1, 1), false
    FROM generate_series(0, length(p_crib) - 1) i;
    IF EXISTS (SELECT 1 FROM edge WHERE a = b) THEN
        RAISE EXCEPTION 'The crib puts a letter on itself. Enigma cannot do that: slide it along.';
    END IF;
    SELECT ARRAY[x] INTO known FROM (SELECT a AS x FROM edge UNION ALL SELECT b FROM edge) q
    GROUP BY x ORDER BY count(*) DESC, x LIMIT 1;
    LOOP
        SELECT pos, CASE WHEN a = ANY(known) THEN a ELSE b END AS k,
                    CASE WHEN a = ANY(known) THEN b ELSE a END AS o,
                    (a = ANY(known) AND b = ANY(known)) AS c
        INTO e FROM edge
        WHERE NOT used AND (a = ANY(known) OR b = ANY(known))
        ORDER BY (a = ANY(known) AND b = ANY(known)) DESC, pos LIMIT 1;
        EXIT WHEN NOT FOUND;
        INSERT INTO enigma.menu VALUES (s, e.pos, e.k, e.o, e.c);
        UPDATE edge SET used = true WHERE pos = e.pos;
        IF NOT e.o = ANY(known) THEN known := known || e.o::text; END IF;
        s := s + 1;
    END LOOP;
END $$;

/* 3. THE BOMBE: guess, follow the menu, drop contradictions */
CREATE TABLE enigma.stop (ord_id int, l int, m int, r int, plugs text);

CREATE OR REPLACE FUNCTION enigma.bombe()
RETURNS TABLE (step int, edge text, survivors bigint, ms int) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp(); mm record; n bigint; test char(1);
BEGIN
    SELECT known INTO test FROM enigma.menu WHERE menu.step = 0;
    -- unlogged, not temp: PostgreSQL won't use parallel workers on temp tables
    DROP TABLE IF EXISTS enigma.cur, enigma.nxt;
    CREATE UNLOGGED TABLE enigma.cur AS
    SELECT d.ord_id, d.l, d.m, d.r,
           overlay(overlay(repeat('.', 26) placing chr(65 + g) from ascii(test) - 64 for 1)
                   placing test from g + 1 for 1) AS plugs
    FROM enigma.drum d, generate_series(0, 25) g;
    GET DIAGNOSTICS n = ROW_COUNT;
    step := -1; edge := 'guess ' || test || '=?'; survivors := n;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000; RETURN NEXT;

    FOR mm IN SELECT * FROM enigma.menu ORDER BY menu.step LOOP
        CREATE UNLOGGED TABLE enigma.nxt AS
        SELECT c.ord_id, c.l, c.m, c.r,
               overlay(overlay(c.plugs placing v from ascii(mm.other) - 64 for 1)
                       placing mm.other from ascii(v) - 64 for 1) AS plugs
        FROM enigma.cur c
        JOIN enigma.drum d
          ON d.ord_id = c.ord_id AND d.l = c.l AND d.m = c.m AND d.r = (c.r + mm.pos + 1) % 26
        CROSS JOIN LATERAL (SELECT substr(d.perm, ascii(substr(c.plugs, ascii(mm.known) - 64, 1)) - 64, 1) AS v) x
        WHERE substr(c.plugs, ascii(mm.other) - 64, 1) IN ('.', v)
          AND substr(c.plugs, ascii(v) - 64, 1) IN ('.', mm.other);
        GET DIAGNOSTICS n = ROW_COUNT;
        DROP TABLE enigma.cur;
        ALTER TABLE enigma.nxt RENAME TO cur;   -- PostgreSQL will just rename a table
        step := mm.step; edge := mm.known || '-' || mm.other || ' @' || mm.pos; survivors := n;
        ms := extract(epoch FROM clock_timestamp() - t0) * 1000; RETURN NEXT;
    END LOOP;

    DELETE FROM enigma.stop;
    INSERT INTO enigma.stop SELECT * FROM enigma.cur;
    DROP TABLE enigma.cur;
END $$;

/* 4. THE CHECKING MACHINE: rings and the last plug, by index of coincidence */
CREATE OR REPLACE FUNCTION enigma.decrypt(p_ord int, p_rings text, p_start text, p_plugs text, p_cipher text)
RETURNS text LANGUAGE sql STABLE AS $$
WITH RECURSIVE m AS
(
    SELECT o.*, enigma.n(wm.notch) AS nm, enigma.n(wr.notch) AS nr,
           enigma.n(substr(p_rings, 1, 1)) AS gl, enigma.n(substr(p_rings, 2, 1)) AS gm,
           enigma.n(substr(p_rings, 3, 1)) AS gr
    FROM enigma.rotor_order o
    JOIN enigma.wheel wm ON wm.name = split_part(o.rotors, ' ', 2)
    JOIN enigma.wheel wr ON wr.name = split_part(o.rotors, ' ', 3)
    WHERE o.ord_id = p_ord
),
k AS
(
    SELECT 0 AS i, enigma.n(substr(p_start, 1, 1)) AS pl, enigma.n(substr(p_start, 2, 1)) AS pm,
           enigma.n(substr(p_start, 3, 1)) AS pr
    UNION ALL
    SELECT k.i + 1, (k.pl + (k.pm = m.nm)::int) % 26,
           (k.pm + (k.pm = m.nm OR k.pr = m.nr)::int) % 26, (k.pr + 1) % 26
    FROM k, m WHERE k.i < length(p_cipher)
)
SELECT string_agg(substr(p_plugs, enigma.scramble(m.lf, m.lb, m.mf, m.mb, m.rf, m.rb, m.ref,
                    (k.pl - m.gl + 26) % 26, (k.pm - m.gm + 26) % 26, (k.pr - m.gr + 26) % 26,
                    enigma.n(substr(p_plugs, enigma.n(substr(p_cipher, k.i, 1)) + 1, 1))) + 1, 1), ''
                  ORDER BY k.i)
FROM k, m WHERE k.i > 0
$$;

CREATE OR REPLACE FUNCTION enigma.ioc(t text) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$
SELECT sum(n * (n - 1))::float8 / (length(t) * (length(t) - 1))
FROM (SELECT length(t) - length(replace(t, chr(65 + i), '')) AS n FROM generate_series(0, 25) i) c
$$;

CREATE OR REPLACE FUNCTION enigma.check_stop(p_cipher text)
RETURNS TABLE (rotors text, rings text, start text, plugs text, ioc float8, plain text)
LANGUAGE plpgsql AS $$
DECLARE s enigma.stop; p0 text; best record;
BEGIN
    SELECT * INTO s FROM enigma.stop LIMIT 1;
    p0 := (SELECT string_agg(CASE WHEN substr(s.plugs, i + 1, 1) = '.' THEN chr(65 + i)
                                  ELSE substr(s.plugs, i + 1, 1) END, '' ORDER BY i)
           FROM generate_series(0, 25) i);
    -- every middle and right ring setting (the left ring changes nothing we can see)
    SELECT g.rings, g.start, enigma.ioc(enigma.decrypt(s.ord_id, g.rings, g.start, p0, p_cipher)) AS score
    INTO best
    FROM (SELECT 'A' || chr(65 + mr) || chr(65 + rr) AS rings,
                 chr(65 + s.l) || chr(65 + (s.m + mr) % 26) || chr(65 + (s.r + rr) % 26) AS start
          FROM generate_series(0, 25) mr, generate_series(0, 25) rr) g
    ORDER BY score DESC, g.rings LIMIT 1;
    -- then the last plug, from the letters the menu never reached
    RETURN QUERY
    WITH cand AS
    (
        SELECT p0 AS pl
        UNION ALL
        SELECT overlay(overlay(p0 placing chr(65 + b) from a + 1 for 1) placing chr(65 + a) from b + 1 for 1)
        FROM generate_series(0, 25) a, generate_series(0, 25) b
        WHERE a < b AND substr(s.plugs, a + 1, 1) = '.' AND substr(s.plugs, b + 1, 1) = '.'
    )
    SELECT o.rotors, best.rings, best.start, c.pl,
           enigma.ioc(enigma.decrypt(s.ord_id, best.rings, best.start, c.pl, p_cipher)) AS ioc,
           enigma.decrypt(s.ord_id, best.rings, best.start, c.pl, p_cipher)
    FROM cand c, enigma.rotor_order o WHERE o.ord_id = s.ord_id
    ORDER BY 5 DESC;
END $$;
