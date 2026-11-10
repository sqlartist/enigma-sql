/* =====================================================================
   Enigma in a database, Part 2: PostgreSQL + PostGIS (3D)
   ---------------------------------------------------------------------
   Same machine as Part 1, but standing up. The rotors are drums on an
   axle (the X axis). Each rotor's 26 wires are stored ONCE, as
   LINESTRING Z, and turned with ST_Affine when the rotor moves.
   A keypress is one LINESTRING Z from the key, through the plugboard
   and three rotors, round the reflector and back to a lamp.

       x = 0     reflector face        x = 0..1  left rotor
       x = 1..2  middle rotor          x = 2..3  right rotor
       x = 3..4  plugboard             x = 4     keys and lamps

   Letter p sits at angle 90 - p * 360/26 degrees around the axle.

   Tested on PostgreSQL 16 / PostGIS 3.4; written for PostgreSQL 18 /
   PostGIS 3.6. Run with:  psql -d enigma -f enigma_postgis.sql
   ===================================================================== */
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS postgis;
DROP SCHEMA IF EXISTS enigma CASCADE;
CREATE SCHEMA enigma;

/* ---------------------------------------------------------------------
   1. THE WHEELS
   --------------------------------------------------------------------- */
CREATE TABLE enigma.wheel
(
    name   text PRIMARY KEY,
    kind   text NOT NULL,              -- rotor | reflector
    wiring text NOT NULL,
    notch  char(1)
);
INSERT INTO enigma.wheel VALUES
 ('I',   'rotor',     'EKMFLGDQVZNTOWYHXUSPAIBRCJ', 'Q'),
 ('II',  'rotor',     'AJDKSIRUXBLHWTMCQGZNPYFVOE', 'E'),
 ('III', 'rotor',     'BDFHJLCPRTXVZNYEIWGAKMUSQO', 'V'),
 ('IV',  'rotor',     'ESOVPZJAYQUIRHXLNFTGKDCMWB', 'J'),
 ('V',   'rotor',     'VZBRGITYUPSDNHLXAWMJQOFECK', 'Z'),
 ('B',   'reflector', 'YRUHQSLDPXNGOKMIEBFZCWVJAT', NULL),
 ('C',   'reflector', 'FVPJIAOYEDRZXWGCTKUQSBNMHL', NULL);

-- letter <-> number
CREATE FUNCTION enigma.n(c text) RETURNS int IMMUTABLE LANGUAGE sql
AS $$ SELECT ascii(c) - 65 $$;
CREATE FUNCTION enigma.l(n int) RETURNS text IMMUTABLE LANGUAGE sql
AS $$ SELECT chr(65 + ((n % 26) + 26) % 26) $$;

-- a point on the drum surface: axle position x, letter position p
CREATE FUNCTION enigma.pt(x float8, p float8, r float8 DEFAULT 1)
RETURNS geometry IMMUTABLE LANGUAGE sql
AS $$ SELECT ST_MakePoint(x, r * cos(pi()/2 - p * 2 * pi() / 26),
                             r * sin(pi()/2 - p * 2 * pi() / 26)) $$;

/* A wire from (x1, p1) to (x2, p2): 8 segments, the short way round,
   dipping inside the drum on the way. Reflector wires (x1 = x2) loop
   out past the end of the drum instead. */
CREATE FUNCTION enigma.wire(x1 float8, p1 int, x2 float8, p2 int)
RETURNS geometry IMMUTABLE LANGUAGE sql
AS $$
  WITH d AS (SELECT (((p2 - p1 + 13) % 26 + 26) % 26 - 13)::float8 AS dp)
  SELECT ST_MakeLine(
           CASE WHEN k = 0 THEN enigma.pt(x1, p1)
                WHEN k = 8 THEN enigma.pt(x2, p2)
                WHEN x1 = x2 THEN enigma.pt(x1 - (0.15 + 0.35 * abs(dp) / 13) * sin(pi() * k / 8),
                                            p1 + dp * k / 8, 1 - 0.1 * sin(pi() * k / 8))
                ELSE enigma.pt(x1 + (x2 - x1) * k / 8, p1 + dp * k / 8,
                               1 - 0.25 * sin(pi() * k / 8)) END
           ORDER BY k)
  FROM d, generate_series(0, 8) k
$$;

/* ---------------------------------------------------------------------
   2. EVERY ROTOR, WIRED ONCE
   ---------------------------------------------------------------------
   In the rotor's own frame: right face at x = 1, left face at x = 0,
   turned to position A. These rows never change.
   --------------------------------------------------------------------- */
CREATE TABLE enigma.rotor_wire
(
    rotor   text REFERENCES enigma.wheel,
    contact int,
    pin     int,
    geom    geometry(LineStringZ),
    PRIMARY KEY (rotor, contact)
);
INSERT INTO enigma.rotor_wire
SELECT w.name, c, enigma.n(substr(w.wiring, c + 1, 1)),
       enigma.wire(1, c, 0, enigma.n(substr(w.wiring, c + 1, 1)))
FROM enigma.wheel w, generate_series(0, 25) c
WHERE w.kind = 'rotor';

/* Turning a rotor: a rotation about the axle (X) as an affine matrix.
   ST_RotateX(g, a) is the same thing; spelled out, it's this: */
CREATE FUNCTION enigma.turn(g geometry, steps int)
RETURNS geometry IMMUTABLE LANGUAGE sql
AS $$
  SELECT ST_Affine(g,
           1, 0,                              0,
           0, cos(steps * 2 * pi() / 26), -sin(steps * 2 * pi() / 26),
           0, sin(steps * 2 * pi() / 26),  cos(steps * 2 * pi() / 26),
           0, 0, 0)
$$;

/* ---------------------------------------------------------------------
   3. THE MACHINE
   --------------------------------------------------------------------- */
CREATE TABLE enigma.machine
(
    id          int PRIMARY KEY CHECK (id = 1),
    rotors      text[] NOT NULL,     -- left, middle, right
    reflector   text   NOT NULL,
    rings       text   NOT NULL,
    plugboard   text   NOT NULL,     -- what each letter is plugged to
    pos         text   NOT NULL      -- the windows
);

-- the parts that don't move: plugboard (x 3..4) and reflector (x = 0)
CREATE TABLE enigma.fixed_wire (part text, a int, b int, geom geometry(LineStringZ));
CREATE TABLE enigma.lamp (n int PRIMARY KEY, letter text, geom geometry(PointZ));
INSERT INTO enigma.lamp SELECT n, enigma.l(n), enigma.pt(4, n) FROM generate_series(0, 25) n;

CREATE TABLE enigma.key_log
(
    seq     serial PRIMARY KEY,
    pos     text,
    key_in  text,
    lamp    text,
    hops    int,
    path    geometry(LineStringZ)
);

CREATE FUNCTION enigma.setup(p_rotors text, p_reflector text, p_rings text,
                             p_plugs text, p_start text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE pb text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'; pair text;
BEGIN
    FOREACH pair IN ARRAY coalesce(string_to_array(nullif(p_plugs, ''), ' '), '{}') LOOP
        pb := overlay(pb placing substr(pair, 2, 1) from enigma.n(substr(pair, 1, 1)) + 1 for 1);
        pb := overlay(pb placing substr(pair, 1, 1) from enigma.n(substr(pair, 2, 1)) + 1 for 1);
    END LOOP;
    DELETE FROM enigma.machine;
    INSERT INTO enigma.machine VALUES (1, string_to_array(p_rotors, ' '), p_reflector, p_rings, pb, p_start);

    TRUNCATE enigma.fixed_wire, enigma.key_log RESTART IDENTITY;
    INSERT INTO enigma.fixed_wire
    SELECT 'plugboard', a, enigma.n(substr(pb, a + 1, 1)),
           enigma.wire(4, a, 3, enigma.n(substr(pb, a + 1, 1)))
    FROM generate_series(0, 25) a;
    INSERT INTO enigma.fixed_wire
    SELECT 'reflector', a, b, enigma.wire(0, a, 0, b)
    FROM enigma.wheel w, generate_series(0, 25) a,
         LATERAL (SELECT enigma.n(substr(w.wiring, a + 1, 1)) AS b) x
    WHERE w.name = p_reflector AND a < b;
END $$;

/* ---------------------------------------------------------------------
   4. STEPPING (same pawls as Part 1, done with numbers this time)
   --------------------------------------------------------------------- */
CREATE FUNCTION enigma.step() RETURNS text LANGUAGE plpgsql AS $$
DECLARE m enigma.machine; nm int; nr int; pl int; pm int; pr int;
        pawl2 bool; pawl3 bool;
BEGIN
    SELECT * INTO m FROM enigma.machine;
    SELECT enigma.n(notch) INTO nm FROM enigma.wheel WHERE name = m.rotors[2];
    SELECT enigma.n(notch) INTO nr FROM enigma.wheel WHERE name = m.rotors[3];
    pl := enigma.n(substr(m.pos, 1, 1)); pm := enigma.n(substr(m.pos, 2, 1)); pr := enigma.n(substr(m.pos, 3, 1));
    pawl2 := (pr = nr);   -- pawl 2 drops into the right rotor's notch
    pawl3 := (pm = nm);   -- pawl 3 drops into the middle rotor's notch
    UPDATE enigma.machine SET pos =
        enigma.l(pl + pawl3::int) || enigma.l(pm + (pawl2 OR pawl3)::int) || enigma.l(pr + 1);
    RETURN CASE WHEN pawl3 THEN 'L' ELSE '' END || CASE WHEN pawl2 OR pawl3 THEN 'M' ELSE '' END || 'R';
END $$;

/* ---------------------------------------------------------------------
   5. THE WIRES WHERE THEY ARE RIGHT NOW
   ---------------------------------------------------------------------
   Every rotor wire: turned by (window - ring) and slid along the
   axle into its slot. No text, no rebuilding: turn and slide.
   --------------------------------------------------------------------- */
CREATE VIEW enigma.live_wire AS
SELECT row_number() OVER () AS wire_id, part, geom FROM
(
    SELECT s.part,
           ST_Translate(enigma.turn(rw.geom,
                enigma.n(substr(m.pos, s.i, 1)) - enigma.n(substr(m.rings, s.i, 1))),
                s.x0, 0, 0) AS geom
    FROM enigma.machine m
    CROSS JOIN (VALUES (1, 'left', 0.0), (2, 'middle', 1.0), (3, 'right', 2.0)) s(i, part, x0)
    JOIN enigma.rotor_wire rw ON rw.rotor = m.rotors[s.i]
    UNION ALL
    SELECT part, geom FROM enigma.fixed_wire
) w;

/* ---------------------------------------------------------------------
   6. A KEYPRESS
   ---------------------------------------------------------------------
   Same rule as Part 1: from where the signal is, take the other wire
   that touches this point. But turned shapes don't land exactly on
   each other (floating point), so "touches" means "within a
   nanometre", ST_3DDWithin(..., 1e-9). The wires it used, end to end,
   become one LINESTRING Z.
   --------------------------------------------------------------------- */
CREATE FUNCTION enigma.press(p_key text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_lamp text; v_hops int; v_path geometry; v_pos text;
BEGIN
    PERFORM enigma.step();
    SELECT pos INTO v_pos FROM enigma.machine;

    SET LOCAL client_min_messages = warning;
    CREATE TEMP TABLE IF NOT EXISTS w (wire_id bigint, part text, geom geometry);
    TRUNCATE w;
    INSERT INTO w SELECT * FROM enigma.live_wire;

    WITH RECURSIVE trace AS
    (
        SELECT 0 AS hop, l.geom::geometry AS here, 0::bigint AS last_wire, NULL::geometry AS seg
        FROM enigma.lamp l WHERE l.letter = p_key
        UNION ALL
        SELECT t.hop + 1, ST_EndPoint(o.g), w.wire_id, o.g
        FROM trace t
        JOIN w ON w.wire_id <> t.last_wire                  -- not the wire we came in on
              AND (ST_3DDWithin(t.here, ST_StartPoint(w.geom), 1e-9)
                OR ST_3DDWithin(t.here, ST_EndPoint(w.geom), 1e-9))
        CROSS JOIN LATERAL (SELECT CASE WHEN ST_3DDWithin(t.here, ST_StartPoint(w.geom), 1e-9)
                                        THEN w.geom ELSE ST_Reverse(w.geom) END AS g) o
        WHERE t.hop < 20
    )
    , path AS
    (
        SELECT max(hop) AS hops,
               ST_RemoveRepeatedPoints(ST_MakeLine(seg ORDER BY hop), 1e-9) AS path
        FROM trace WHERE hop > 0
    )
    SELECT p.hops, p.path, l.letter       -- the signal ran out of wire: on which lamp?
    INTO v_hops, v_path, v_lamp
    FROM path p
    JOIN enigma.lamp l ON ST_3DDWithin(l.geom, ST_EndPoint(p.path), 1e-9);

    INSERT INTO enigma.key_log (pos, key_in, lamp, hops, path)
    VALUES (v_pos, p_key, v_lamp, v_hops, v_path);
    RETURN v_lamp;
END $$;

-- The planner can't guess how few rows a trace touches, so it thinks the
-- query is huge and JIT-compiles it: 140 ms of compiling for 1 ms of work.
ALTER FUNCTION enigma.press(text) SET jit = off;

CREATE FUNCTION enigma.type(p_text text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE c text; out text := '';
BEGIN
    FOREACH c IN ARRAY regexp_split_to_array(regexp_replace(upper(p_text), '[^A-Z]', '', 'g'), '') LOOP
        out := out || enigma.press(c);
    END LOOP;
    RETURN out;
END $$;

/* ---------------------------------------------------------------------
   7. THE ARITHMETIC MACHINE (for the proof and the Bombe)
   ---------------------------------------------------------------------
   Wiring as arrays: fw[c+1] = pin, bw[pin+1] = contact.
   --------------------------------------------------------------------- */
CREATE TABLE enigma.wheel_map AS
SELECT name,
       array_agg(enigma.n(substr(wiring, c + 1, 1)) ORDER BY c) AS fw,
       array_agg(strpos(wiring, enigma.l(c)) - 1 ORDER BY c)    AS bw
FROM enigma.wheel, generate_series(0, 25) c GROUP BY name;

CREATE FUNCTION enigma.scramble(lf int[], lb int[], mf int[], mb int[], rf int[], rb int[],
                                ref int[], sl int, sm int, sr int, x int)
RETURNS int IMMUTABLE PARALLEL SAFE LANGUAGE sql
AS $$
-- right, middle, left, reflector, left, middle, right: generated, not typed
SELECT (rb[(((mb[(((lb[((ref[((lf[(((mf[(((rf[((x) + sr) % 26 + 1] - sr + 26) % 26) + sm) % 26 + 1] - sm + 26) % 26) + sl) % 26 + 1] - sl + 26) % 26) + 1]) + sl) % 26 + 1] - sl + 26) % 26) + sm) % 26 + 1] - sm + 26) % 26) + sr) % 26 + 1] - sr + 26) % 26
$$;
