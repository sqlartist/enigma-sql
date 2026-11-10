/* =====================================================================
   Enigma in a database: the exploded view (PostgreSQL + PostGIS)
   ---------------------------------------------------------------------
   The same idea as the Watchmaker's exploded movement:

     1. Every part is a flat profile, extruded into a closed solid
        (a TIN: lids from ST_TriangulatePolygon, walls from
        ST_DumpSegments) and placed with ST_Affine.
     2. Nobody types in the order it comes apart. Each round, every
        part still in the machine tries to slide out along its axis.
        It can go if nothing still in the machine is in its way.
     3. How many rounds a part waits is how far it sits out in the
        exploded view.

   The rotor stack slides off the axle (left half off the left end,
   right half off the right end), keys and lamps lift up, and the
   plugs pull out of the front. The case and the axle stay put.

   Units are millimetres. x runs left to right along the axle, y runs
   from the front of the box to the back, z is up. The shapes are a
   simplified Enigma I, about the right size, not a museum drawing.

   Run after enigma_postgis.sql (it only needs the enigma schema):
     psql -d enigma -f enigma_exploded.sql
   Then: python tools/export_exploded.py  (writes viewer/enigma_data.js)
   ===================================================================== */
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS enigma.removal, enigma.piece, enigma.part CASCADE;

CREATE TABLE enigma.part
(
    part    text PRIMARY KEY,
    axis    char(1) NOT NULL,            -- the axis it slides along: x, y or z
    is_base bool NOT NULL DEFAULT false, -- stays put: everything else comes off it
    out_dir int                          -- which way along its axis it leaves (+1 / -1)
);
CREATE TABLE enigma.piece
(
    part     text REFERENCES enigma.part,
    piece    text,
    material text,
    profile  geometry,                   -- flat shape, in the plane across the axis
    w0       float8,                     -- from here to here along the axis
    w1       float8,
    mesh     geometry,                   -- the solid, where it sits
    sweep    geometry,                   -- the same, pulled 1,000 mm along its way out
    PRIMARY KEY (part, piece)
);
CREATE TABLE enigma.removal
(
    part  text PRIMARY KEY REFERENCES enigma.part,
    round int,
    level int
);

/* ---------------------------------------------------------------------
   SHAPES
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION enigma.disc(cx float8, cy float8, r float8, hole float8 DEFAULT 0)
RETURNS geometry IMMUTABLE LANGUAGE sql AS $$
-- more sides for bigger circles; a hole of the same radius gets the same sides, so parts fit exactly
SELECT CASE WHEN hole > 0
            THEN ST_Difference(ST_Buffer(ST_MakePoint(cx, cy), r, greatest(3, least(24, ceil(r / 1.6)))::int),
                               ST_Buffer(ST_MakePoint(cx, cy), hole, greatest(3, least(24, ceil(hole / 1.6)))::int))
            ELSE ST_Buffer(ST_MakePoint(cx, cy), r, greatest(3, least(24, ceil(r / 1.6)))::int) END
$$;

-- n little circles of radius r on a circle of radius rr (contacts and pins)
CREATE OR REPLACE FUNCTION enigma.ring_of(cx float8, cy float8, rr float8, n int, r float8)
RETURNS geometry IMMUTABLE LANGUAGE sql AS $$
SELECT ST_Collect(ST_Buffer(ST_MakePoint(cx + rr * cos(2 * pi() * k / n), cy + rr * sin(2 * pi() * k / n)), r, 3))
FROM generate_series(0, n - 1) k
$$;

-- a toothed wheel: n teeth between radius r_root and r_tip; saw = true gives ratchet teeth
CREATE OR REPLACE FUNCTION enigma.toothed(cx float8, cy float8, n int, r_root float8, r_tip float8,
                                          hole float8, saw bool DEFAULT false)
RETURNS geometry IMMUTABLE LANGUAGE sql AS $$
WITH pts AS
(
    SELECT k, ST_MakePoint(cx + rr * cos(a), cy + rr * sin(a)) AS p
    FROM generate_series(0, 4 * n - 1) k,
         LATERAL (SELECT 2 * pi() * k / (4 * n) AS a,
                         CASE WHEN saw THEN CASE k % 4 WHEN 0 THEN r_root WHEN 1 THEN (r_root + r_tip) / 2
                                                       WHEN 2 THEN r_tip ELSE r_root END
                              ELSE CASE k % 4 WHEN 0 THEN r_root WHEN 1 THEN r_tip WHEN 2 THEN r_tip ELSE r_root END
                         END AS rr) x
)
SELECT ST_Difference(ST_MakePolygon(ST_AddPoint(ST_MakeLine(p ORDER BY k), (SELECT p FROM pts WHERE k = 0))),
                     ST_Buffer(ST_MakePoint(cx, cy), hole, greatest(3, least(24, ceil(hole / 1.6)))::int))
FROM pts
$$;

/* A flat profile (u, v) extruded from w0 to w1 into a closed TIN, then
   turned so w runs along the part's axis: the watch's prism, with y added. */
CREATE OR REPLACE FUNCTION enigma.xyz(x float8, y float8, z float8) RETURNS text
IMMUTABLE LANGUAGE sql AS $$ SELECT round(x::numeric, 3) || ' ' || round(y::numeric, 3) || ' ' || round(z::numeric, 3) $$;

CREATE OR REPLACE FUNCTION enigma.prism(profile geometry, w0 float8, w1 float8, axis char)
RETURNS geometry IMMUTABLE LANGUAGE sql AS $$
WITH p AS (SELECT ST_ForcePolygonCCW(profile) AS g),            -- outer rings anticlockwise, holes clockwise
lid AS (SELECT ST_ForcePolygonCCW(d.geom) AS t FROM p, ST_Dump(ST_TriangulatePolygon(p.g)) AS d),
corner AS (
    SELECT ST_X(ST_PointN(r, 1)) AS x1, ST_Y(ST_PointN(r, 1)) AS y1, ST_X(ST_PointN(r, 2)) AS x2,
           ST_Y(ST_PointN(r, 2)) AS y2, ST_X(ST_PointN(r, 3)) AS x3, ST_Y(ST_PointN(r, 3)) AS y3
    FROM lid, LATERAL (SELECT ST_ExteriorRing(t) AS r) AS e),
edge AS (                                                       -- the solid is on the left of every edge
    SELECT ST_X(ST_StartPoint(s.geom)) AS ax, ST_Y(ST_StartPoint(s.geom)) AS ay,
           ST_X(ST_EndPoint(s.geom)) AS bx, ST_Y(ST_EndPoint(s.geom)) AS by_
    FROM p, ST_DumpSegments(p.g) AS s),
tri AS (
    SELECT enigma.xyz(x1, y1, w1) AS a, enigma.xyz(x2, y2, w1) AS b, enigma.xyz(x3, y3, w1) AS c FROM corner
    UNION ALL
    SELECT enigma.xyz(x1, y1, w0), enigma.xyz(x3, y3, w0), enigma.xyz(x2, y2, w0) FROM corner
    UNION ALL
    SELECT enigma.xyz(ax, ay, w0), enigma.xyz(bx, by_, w0), enigma.xyz(bx, by_, w1) FROM edge
    UNION ALL
    SELECT enigma.xyz(ax, ay, w0), enigma.xyz(bx, by_, w1), enigma.xyz(ax, ay, w1) FROM edge),
tin AS (SELECT ST_GeomFromText('TIN Z (' || string_agg('((' || a || ',' || b || ',' || c || ',' || a || '))', ',') || ')') AS g
        FROM tri)
SELECT CASE axis
         WHEN 'x' THEN ST_Affine(g, 0, 0, 1,  1, 0, 0,  0, 1, 0,  0, 0, 0)   -- (u, v, w) -> (w, u, v)
         WHEN 'y' THEN ST_Reverse(                                         -- (u, v, w) -> (u, w, v) is a mirror,
                         ST_Affine(g, 1, 0, 0,  0, 0, 1,  0, 1, 0,  0, 0, 0))  -- so turn the triangles back outwards
         ELSE g END
FROM tin
$$;

/* ---------------------------------------------------------------------
   THE PARTS
   --------------------------------------------------------------------- */
-- The case: a wooden box with a plate on top and the plugboard panel on the front
INSERT INTO enigma.part VALUES ('Case', 'z', true, NULL);
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1) VALUES
 ('Case', 'walls',      'wood',  ST_Difference(ST_MakeEnvelope(-175, -150, 175, 150), ST_MakeEnvelope(-165, -140, 165, 140)), -90, 6),
 ('Case', 'floor',      'wood',  ST_MakeEnvelope(-165, -140, 165, 140), -90, -84),
 ('Case', 'top plate',  'plate', ST_MakeEnvelope(-165, -140, 165, 140), 0, 6);

-- The plugboard panel and its 26 sockets, on the front of the box (profile in x, z)
INSERT INTO enigma.part VALUES ('Plugboard', 'y', true, NULL);
CREATE TEMP TABLE layout AS                      -- QWERTZ, three rows, as on the machine
SELECT r.row_no, k - 1 AS col, substr(r.letters, k, 1) AS letter,
       (k - 1 - (length(r.letters) - 1) / 2.0) * 30 AS dx
FROM (VALUES (1, 'QWERTZUIO'), (2, 'ASDFGHJK'), (3, 'PYXCVBNML')) r(row_no, letters),
     LATERAL generate_series(1, length(r.letters)) k;
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1)
SELECT 'Plugboard', 'panel', 'bakelite',                     -- with a hole for every socket pin
       ST_Difference(ST_MakeEnvelope(-150, -80, 150, -6),
                     ST_Union(ST_Union(enigma.disc(dx - 5, -23 - 21 * (row_no - 1), 1.6),
                                       enigma.disc(dx + 5, -23 - 21 * (row_no - 1), 1.6)))), -152, -150
FROM layout;
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1)
SELECT 'Plugboard', 'sockets', 'gilt',
       ST_Union(ST_Union(enigma.disc(dx - 5, -23 - 21 * (row_no - 1), 3.2, 1.6),
                         enigma.disc(dx + 5, -23 - 21 * (row_no - 1), 3.2, 1.6))), -153, -152
FROM layout;

-- The axle: the rotors slide off it, so it stays
INSERT INTO enigma.part VALUES ('Axle', 'x', true, NULL);
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1) VALUES
 ('Axle', 'axle', 'steel', enigma.disc(100, 60, 5), -95, 70);
-- the brackets that hold the axle come off its ends first
INSERT INTO enigma.part VALUES ('Left bracket', 'x', false, -1), ('Right bracket', 'x', false, 1);
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1) VALUES
 ('Left bracket',  'bracket', 'plate', ST_Union(enigma.disc(100, 60, 9, 5.2), ST_MakeEnvelope(91, 6.5, 109, 50)), -100, -94),
 ('Right bracket', 'bracket', 'plate', ST_Union(enigma.disc(100, 60, 9, 5.2), ST_MakeEnvelope(91, 6.5, 109, 50)), 66, 72);

-- Reflector (UKW) and entry wheel (ETW)
INSERT INTO enigma.part VALUES ('Reflector', 'x', false, -1), ('Entry wheel', 'x', false, 1);
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1) VALUES
 ('Reflector',   'body',     'plate', enigma.disc(100, 60, 40, 5.2), -88, -74),
 ('Reflector',   'contacts', 'gilt',  enigma.ring_of(100, 60, 28, 26, 2.2), -74, -73),
 ('Entry wheel', 'body',     'plate', enigma.disc(100, 60, 40, 5.2), 46, 60),
 ('Entry wheel', 'contacts', 'gilt',  enigma.ring_of(100, 60, 28, 26, 2.2), 45, 46);

-- Three rotors, each in four parts. x0 is the rotor's left face.
CREATE TEMP TABLE rotor_slot AS
SELECT * FROM (VALUES ('Left rotor', -70.0, -1), ('Middle rotor', -36.0, 1), ('Right rotor', -2.0, 1)) s(name, x0, dir);

INSERT INTO enigma.part
SELECT s.name || ': ' || c.part, 'x', false, s.dir
FROM rotor_slot s CROSS JOIN (VALUES ('thumbwheel'), ('alphabet ring'), ('wiring core'), ('ratchet')) c(part);

INSERT INTO enigma.piece (part, piece, material, profile, w0, w1)
SELECT s.name || ': ' || v.part, v.piece, v.material, v.profile, s.x0 + v.a, s.x0 + v.b
FROM rotor_slot s CROSS JOIN LATERAL (VALUES
 ('thumbwheel',    'wheel',          'bakelite', enigma.toothed(100, 60, 52, 44, 46, 33),            0.0,  4.0),
 ('alphabet ring', 'tyre',           'dial',     enigma.disc(100, 60, 42.5, 38.3),                     5.0, 15.0),
 ('alphabet ring', 'letters',        'bakelite', enigma.ring_of(100, 60, 42.6, 26, 1.1),             8.0, 12.0),
 ('alphabet ring', 'notch ring',     'steel',    ST_Difference(enigma.disc(100, 60, 41, 38.3),
                                                   ST_MakeEnvelope(97, 96, 103, 106)),               15.0, 18.0),
 ('wiring core',   'core',           'bakelite', enigma.disc(100, 60, 38, 5.2),                        5.0, 25.0),
 ('wiring core',   'spring pins',    'gilt',     enigma.ring_of(100, 60, 28, 26, 1.4),               1.0,  5.0),
 ('wiring core',   'contact plates', 'gilt',     enigma.ring_of(100, 60, 28, 26, 2.2),              25.0, 25.8),
 ('ratchet',       'ratchet',        'steel',    enigma.toothed(100, 60, 26, 35, 38, 31, true),     26.0, 29.0)
) v(part, piece, material, profile, a, b);

-- Lamps under a cover plate with a little window for each letter
INSERT INTO enigma.part VALUES ('Lamp cover', 'z', false, 1);
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1)
SELECT 'Lamp cover', 'cover', 'plate',
       ST_Difference(ST_MakeEnvelope(-150, -28, 150, 54), ST_Union(enigma.disc(dx, 40 - 26 * (row_no - 1), 6))), 18, 20
FROM layout;
INSERT INTO enigma.part SELECT 'Lamp ' || letter, 'z', false, 1 FROM layout;
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1)
SELECT 'Lamp ' || letter, 'bulb', 'lamp', enigma.disc(dx, 40 - 26 * (row_no - 1), 8), 6, 16 FROM layout
UNION ALL
SELECT 'Lamp ' || letter, 'holder', 'steel', enigma.disc(dx, 40 - 26 * (row_no - 1), 9.5, 8), 6, 9 FROM layout;

-- Keys: a cap on a stem
INSERT INTO enigma.part
SELECT 'Key ' || letter || ': ' || p, 'z', false, 1 FROM layout CROSS JOIN (VALUES ('cap'), ('stem')) x(p);
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1)
SELECT 'Key ' || letter || ': cap', 'cap', 'bakelite', enigma.disc(dx, -45 - 30 * (row_no - 1), 9), 24, 30 FROM layout
UNION ALL
SELECT 'Key ' || letter || ': cap', 'face', 'dial', enigma.disc(dx, -45 - 30 * (row_no - 1), 7), 30, 30.6 FROM layout
UNION ALL
SELECT 'Key ' || letter || ': stem', 'stem', 'steel', enigma.disc(dx, -45 - 30 * (row_no - 1), 2.5), 6, 24 FROM layout;

-- Ten plug cables (the Barbarossa key): a pair of plugs for each
INSERT INTO enigma.part
SELECT 'Plug ' || c, 'y', false, -1
FROM unnest(string_to_array('A V B S C G D L F U H Z I N K M O W R X', ' ')) c;
INSERT INTO enigma.piece (part, piece, material, profile, w0, w1)
SELECT 'Plug ' || l.letter, 'plug', 'bakelite',
       ST_Union(enigma.disc(l.dx - 5, -23 - 21 * (l.row_no - 1), 3), enigma.disc(l.dx + 5, -23 - 21 * (l.row_no - 1), 3)), -166, -153
FROM layout l JOIN enigma.part p ON p.part = 'Plug ' || l.letter
UNION ALL
SELECT 'Plug ' || l.letter, 'pins', 'gilt',
       ST_Union(enigma.disc(l.dx - 5, -23 - 21 * (l.row_no - 1), 1.5), enigma.disc(l.dx + 5, -23 - 21 * (l.row_no - 1), 1.5)), -153, -150.5
FROM layout l JOIN enigma.part p ON p.part = 'Plug ' || l.letter;

/* every piece's solid, where it sits */
UPDATE enigma.piece AS pc SET mesh = enigma.prism(pc.profile, pc.w0, pc.w1, p.axis)
FROM enigma.part p WHERE p.part = pc.part;
UPDATE enigma.piece AS pc
SET sweep = enigma.prism(pc.profile, CASE WHEN p.out_dir < 0 THEN pc.w0 - 1000 ELSE pc.w0 END,
                                     CASE WHEN p.out_dir < 0 THEN pc.w1 ELSE pc.w1 + 1000 END, p.axis)
FROM enigma.part p WHERE p.part = pc.part AND NOT p.is_base;

/* ---------------------------------------------------------------------
   TAKING IT APART
   ---------------------------------------------------------------------
   A part can leave if no piece of a part still in the machine is in
   its way: on the same axis, their profiles overlap (not just touch)
   and the other piece is further along the way out. Across axes, the
   part's swept solid (pulled 1,000 mm along the way out) must not
   reach any other solid.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION enigma.blocked(mover text) RETURNS bool STABLE LANGUAGE sql AS $$
SELECT EXISTS (
    SELECT 1
    FROM enigma.piece a
    JOIN enigma.part pa ON pa.part = a.part
    JOIN enigma.piece q ON q.part <> a.part
    JOIN enigma.part pq ON pq.part = q.part
    WHERE a.part = mover
      AND NOT EXISTS (SELECT 1 FROM enigma.removal r WHERE r.part = q.part)
      AND CASE
            WHEN pa.axis = pq.axis THEN
                 CASE WHEN pa.out_dir < 0 THEN q.w0 < a.w1 - 1e-9 ELSE q.w1 > a.w0 + 1e-9 END
                 AND a.profile && q.profile
                 AND ST_Relate(a.profile, q.profile, '2********')
            ELSE a.sweep &&& q.mesh AND ST_3DIntersects(a.sweep, q.mesh)
          END)
$$;

CREATE OR REPLACE FUNCTION enigma.take_apart() RETURNS TABLE (round int, parts text) LANGUAGE plpgsql AS $$
DECLARE r int := 0; free text[];
BEGIN
    DELETE FROM enigma.removal;
    LOOP
        r := r + 1;
        free := ARRAY(SELECT p.part FROM enigma.part p
                      WHERE NOT p.is_base
                        AND NOT EXISTS (SELECT 1 FROM enigma.removal m WHERE m.part = p.part)
                        AND NOT enigma.blocked(p.part));
        EXIT WHEN cardinality(free) = 0;
        INSERT INTO enigma.removal (part, round) SELECT unnest(free), r;
    END LOOP;

    IF EXISTS (SELECT 1 FROM enigma.part p WHERE NOT p.is_base
               AND NOT EXISTS (SELECT 1 FROM enigma.removal m WHERE m.part = p.part)) THEN
        RAISE EXCEPTION 'stuck: % cannot come out',
            (SELECT string_agg(p.part, ', ') FROM enigma.part p WHERE NOT p.is_base
             AND NOT EXISTS (SELECT 1 FROM enigma.removal m WHERE m.part = p.part));
    END IF;

    /* the exploded view: last off sits one layer out, first off furthest (per way out) */
    UPDATE enigma.removal m SET level = g.last_round - m.round + 1
    FROM enigma.part p,
         (SELECT p2.axis, p2.out_dir, max(m2.round) AS last_round
          FROM enigma.removal m2 JOIN enigma.part p2 ON p2.part = m2.part GROUP BY 1, 2) g
    WHERE p.part = m.part AND g.axis = p.axis AND g.out_dir = p.out_dir;

    RETURN QUERY
    SELECT m.round, string_agg(m.part, ', ' ORDER BY m.part)
    FROM enigma.removal m GROUP BY m.round ORDER BY m.round;
END $$;

\timing on
SELECT * FROM enigma.take_apart();
\timing off

-- Every solid closed? (each edge used by exactly two triangles)
SELECT count(*) AS pieces, sum(ST_NumGeometries(mesh)) AS triangles,
       count(*) FILTER (WHERE NOT ST_IsClosed(mesh)) AS not_closed
FROM enigma.piece;

/* for the viewer: every triangle, every part's round, level and way out */
CREATE OR REPLACE FUNCTION enigma.mesh_json(tin geometry) RETURNS json IMMUTABLE LANGUAGE sql AS $$
SELECT json_agg(c.v ORDER BY d.path[1], k, c.i)          -- triangle, corner, then x y z
FROM ST_Dump(tin) d,
     generate_series(1, 3) k,
     LATERAL (SELECT ST_PointN(ST_ExteriorRing(d.geom), k) AS pt) p,
     LATERAL unnest(ARRAY[round(ST_X(p.pt)::numeric, 2), round(ST_Y(p.pt)::numeric, 2),
                          round(ST_Z(p.pt)::numeric, 2)]) WITH ORDINALITY AS c(v, i)
$$;

CREATE OR REPLACE FUNCTION enigma.export_json() RETURNS json STABLE LANGUAGE sql AS $$
SELECT json_build_object('units', 'mm', 'parts', json_agg(json_build_object(
         'part', p.part, 'axis', p.axis, 'base', p.is_base, 'round', r.round, 'level', coalesce(r.level, 0),
         'dir', json_build_array(CASE WHEN p.axis = 'x' THEN coalesce(p.out_dir, 0) ELSE 0 END,
                                 CASE WHEN p.axis = 'y' THEN coalesce(p.out_dir, 0) ELSE 0 END,
                                 CASE WHEN p.axis = 'z' THEN coalesce(p.out_dir, 0) ELSE 0 END),
         'pieces', (SELECT json_agg(json_build_object('piece', pc.piece, 'material', pc.material,
                                                      'pos', enigma.mesh_json(pc.mesh)) ORDER BY pc.piece)
                    FROM enigma.piece pc WHERE pc.part = p.part))
       ORDER BY coalesce(r.round, 0), p.part))
FROM enigma.part p LEFT JOIN enigma.removal r ON r.part = p.part
$$;
