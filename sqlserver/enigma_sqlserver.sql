/* =====================================================================
   Enigma in a database, Part 1: SQL Server 2025 (geometry, 2D)
   ---------------------------------------------------------------------
   The Wehrmacht Enigma I, rebuilt as shapes.

     1. The wheels   : rotors I-V and reflectors B and C, as wiring
                       tables (the real 1930s wiring).
     2. The rings    : the machine is drawn as concentric rings, from
                       the keyboard in the middle to the reflector on
                       the outside. Every contact is a POINT, every
                       wire is a LINESTRING from one ring to the next.
     3. Stepping     : notches and pawls are points; a pawl drops into
                       a notch when the two points are equal. The
                       middle rotor's double step falls out of that.
     4. A keypress   : the signal is traced by following wires: from
                       the point where it is, find the other wire that
                       touches that point. It stops when it runs out of
                       wire, on a lamp.
     5. Proof        : no letter can ever encrypt to itself.

   Run with sqlcmd or SSMS. Needs SQL Server 2025 (compat level 170).
   Then run enigma_sqlserver_run.sql.
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF DB_ID('Enigma') IS NULL CREATE DATABASE Enigma;
GO
ALTER DATABASE Enigma SET COMPATIBILITY_LEVEL = 170;
GO
USE Enigma;
GO
IF SCHEMA_ID('enigma') IS NULL EXEC('CREATE SCHEMA enigma');
GO

DROP TABLE IF EXISTS enigma.KeyLog, enigma.Wire, enigma.Lamp, enigma.Machine,
                     enigma.Ring, enigma.Wheel, enigma.Letter;
GO

/* ---------------------------------------------------------------------
   1. THE WHEELS
   --------------------------------------------------------------------- */
CREATE TABLE enigma.Letter (N tinyint PRIMARY KEY, L char(1) NOT NULL UNIQUE);
INSERT enigma.Letter (N, L)
SELECT TOP (26) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1,
               CHAR(64 + ROW_NUMBER() OVER (ORDER BY (SELECT 1)))
FROM sys.all_objects;

CREATE TABLE enigma.Wheel
(
    Name    varchar(4) PRIMARY KEY,
    Kind    varchar(9) NOT NULL,          -- ROTOR | REFLECTOR
    Wiring  char(26)   NOT NULL,          -- what A, B, C ... are wired to
    Notch   char(1)    NULL               -- window letter at which it kicks the next rotor
);
INSERT enigma.Wheel VALUES
 ('I',   'ROTOR',     'EKMFLGDQVZNTOWYHXUSPAIBRCJ', 'Q'),
 ('II',  'ROTOR',     'AJDKSIRUXBLHWTMCQGZNPYFVOE', 'E'),
 ('III', 'ROTOR',     'BDFHJLCPRTXVZNYEIWGAKMUSQO', 'V'),
 ('IV',  'ROTOR',     'ESOVPZJAYQUIRHXLNFTGKDCMWB', 'J'),
 ('V',   'ROTOR',     'VZBRGITYUPSDNHLXAWMJQOFECK', 'Z'),
 ('B',   'REFLECTOR', 'YRUHQSLDPXNGOKMIEBFZCWVJAT', NULL),
 ('C',   'REFLECTOR', 'FVPJIAOYEDRZXWGCTKUQSBNMHL', NULL);
GO

/* ---------------------------------------------------------------------
   2. THE RINGS
   ---------------------------------------------------------------------
   Seen from the front, the machine becomes a target:
     radius 1 : keyboard and lamps        radius 2 : plugboard -> rotors
     2 to 3   : right rotor               3 to 4   : middle rotor
     4 to 5   : left rotor                5        : the reflector
   Letter p sits at angle 90 - p * 360/26 degrees (A at the top,
   then clockwise). Every point is made by the same formula from a
   whole number, so the same contact always gets exactly the same
   float, bit for bit. That matters later.
   --------------------------------------------------------------------- */
CREATE TABLE enigma.Ring
(
    Slot  tinyint PRIMARY KEY,
    Part  varchar(10) NOT NULL,
    RIn   float NOT NULL,
    ROut  float NOT NULL
);
INSERT enigma.Ring VALUES
 (0, 'PLUGBOARD', 1, 2), (1, 'RIGHT', 2, 3), (2, 'MIDDLE', 3, 4),
 (3, 'LEFT',      4, 5), (4, 'REFLECTOR', 5, 5);
GO

-- A point on ring r at letter position p, as WKT text (style 3 = all 17 digits)
CREATE OR ALTER FUNCTION enigma.fn_XY (@r float, @p float)
RETURNS varchar(80)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @a float = PI() / 2 - @p * 2 * PI() / 26;
    RETURN CONVERT(varchar(40), @r * COS(@a), 3) + ' ' + CONVERT(varchar(40), @r * SIN(@a), 3);
END;
GO
CREATE OR ALTER FUNCTION enigma.fn_Pt (@r float, @p float)
RETURNS geometry
AS
BEGIN
    RETURN geometry::STGeomFromText('POINT(' + enigma.fn_XY(@r, @p) + ')', 0);
END;
GO

/* A wire from (r1, p1) to (r2, p2) as an 8-segment polyline that stays
   between the two rings, taking the short way round. Reflector wires
   (r1 = r2) bulge outwards instead. Returns the WKT for the whole wire,
   and the tails used when the signal enters from either end. */
CREATE OR ALTER FUNCTION enigma.fn_WireWkt (@r1 float, @p1 int, @r2 float, @p2 int)
RETURNS TABLE
AS RETURN
WITH k AS (SELECT v AS k FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8)) t(v)),
d AS (SELECT CAST((@p2 - @p1 + 13 + 26) % 26 - 13 AS float) AS dp),
v AS
(
    SELECT k.k,
           CASE WHEN k.k = 0 THEN enigma.fn_XY(@r1, @p1)
                WHEN k.k = 8 THEN enigma.fn_XY(@r2, @p2)
                ELSE enigma.fn_XY(
                       CASE WHEN @r1 = @r2   -- reflector: a bump outwards
                            THEN @r1 + (0.15 + 0.5 * ABS(d.dp) / 13) * SIN(PI() * k.k / 8)
                            ELSE @r1 + (@r2 - @r1) * k.k / 8.0 END,
                       @p1 + d.dp * k.k / 8.0) END AS xy
    FROM k CROSS JOIN d
)
SELECT f.Wkt, f.FwdTail, r.RevTail
FROM (SELECT 'LINESTRING(' + STRING_AGG(xy, ', ') WITHIN GROUP (ORDER BY k) + ')' AS Wkt,
             ', ' + STRING_AGG(CASE WHEN k > 0 THEN xy END, ', ') WITHIN GROUP (ORDER BY k) AS FwdTail
      FROM v) f
CROSS JOIN   -- "mutually incompatible orderings": the backwards copy needs its own query
     (SELECT ', ' + STRING_AGG(CASE WHEN k < 8 THEN xy END, ', ') WITHIN GROUP (ORDER BY k DESC) AS RevTail
      FROM v) r;
GO

/* ---------------------------------------------------------------------
   The machine itself: one row. Rotors are listed left, middle, right
   (the way an operator reads them), so 'II IV V' puts V on the right.
   --------------------------------------------------------------------- */
CREATE TABLE enigma.Machine
(
    Id         tinyint PRIMARY KEY CHECK (Id = 1),
    LeftRotor  varchar(4) NOT NULL REFERENCES enigma.Wheel,
    MidRotor   varchar(4) NOT NULL REFERENCES enigma.Wheel,
    RightRotor varchar(4) NOT NULL REFERENCES enigma.Wheel,
    Reflector  varchar(4) NOT NULL REFERENCES enigma.Wheel,
    Rings      char(3)    NOT NULL,     -- Ringstellung, e.g. 'BUL'
    Plugboard  char(26)   NOT NULL,     -- what each letter is plugged to
    Pos        char(3)    NOT NULL      -- the three letters in the windows
);

CREATE TABLE enigma.Lamp
(
    N    tinyint PRIMARY KEY,
    L    char(1) NOT NULL,
    Geom geometry NOT NULL
);
INSERT enigma.Lamp SELECT N, L, enigma.fn_Pt(1, N) FROM enigma.Letter;

CREATE TABLE enigma.Wire
(
    WireId  int IDENTITY PRIMARY KEY,
    Slot    tinyint NOT NULL,
    PIn     tinyint NOT NULL,           -- position on the inner ring
    POut    tinyint NOT NULL,           -- position on the outer ring
    Geom    geometry NOT NULL,
    P1      AS Geom.STStartPoint() PERSISTED,
    P2      AS Geom.STEndPoint() PERSISTED,
    FwdTail varchar(max) NOT NULL,
    RevTail varchar(max) NOT NULL
);

CREATE TABLE enigma.KeyLog
(
    Seq    int IDENTITY PRIMARY KEY,
    Pos    char(3) NOT NULL,            -- windows when the key went down
    KeyIn  char(1) NOT NULL,
    LampOut char(1) NOT NULL,
    Hops   tinyint NOT NULL,
    Path   geometry NOT NULL
);
GO

/* ---------------------------------------------------------------------
   Wiring a slot. This is where SQL Server hurts: there is no way to
   turn a shape, so every time a rotor moves its 26 wires are rebuilt
   from text at the new angle. Shift = window letter - ring setting.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE enigma.usp_WireSlot @Slot tinyint
AS
BEGIN
    SET NOCOUNT ON;
    DELETE enigma.Wire WHERE Slot = @Slot;

    DECLARE @rIn float, @rOut float, @wiring char(26), @shift int;
    SELECT @rIn = RIn, @rOut = ROut FROM enigma.Ring WHERE Slot = @Slot;

    SELECT @wiring = CASE @Slot WHEN 0 THEN m.Plugboard ELSE w.Wiring END,
           @shift  = CASE @Slot
                       WHEN 1 THEN ASCII(SUBSTRING(m.Pos, 3, 1)) - ASCII(SUBSTRING(m.Rings, 3, 1))
                       WHEN 2 THEN ASCII(SUBSTRING(m.Pos, 2, 1)) - ASCII(SUBSTRING(m.Rings, 2, 1))
                       WHEN 3 THEN ASCII(SUBSTRING(m.Pos, 1, 1)) - ASCII(SUBSTRING(m.Rings, 1, 1))
                       ELSE 0 END
    FROM enigma.Machine m
    JOIN enigma.Wheel w ON w.Name = CASE @Slot WHEN 1 THEN m.RightRotor WHEN 2 THEN m.MidRotor
                                               WHEN 3 THEN m.LeftRotor ELSE m.Reflector END;

    -- contact c of the wheel is wired to pin Wiring[c]; turned by @shift
    INSERT enigma.Wire (Slot, PIn, POut, Geom, FwdTail, RevTail)
    SELECT @Slot, a.PIn, a.POut, geometry::STGeomFromText(t.Wkt, 0), t.FwdTail, t.RevTail
    FROM enigma.Letter c
    CROSS APPLY (SELECT PIn  = ((c.N - @shift) % 26 + 26) % 26,
                        POut = ((ASCII(SUBSTRING(@wiring, c.N + 1, 1)) - 65 - @shift) % 26 + 26) % 26) a
    CROSS APPLY enigma.fn_WireWkt(@rIn, a.PIn, @rOut, a.POut) t
    WHERE @Slot <> 4 OR c.N < ASCII(SUBSTRING(@wiring, c.N + 1, 1)) - 65;  -- reflector: one wire per pair
END;
GO

/* ---------------------------------------------------------------------
   Set the machine up from a key sheet:
     EXEC enigma.usp_Setup 'II IV V', 'B', 'BUL', 'AV BS CG DL FU HZ IN KM OW RX', 'BLA';
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE enigma.usp_Setup
    @Rotors varchar(20), @Reflector varchar(4), @Rings char(3),
    @Plugs varchar(40), @Start char(3)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (i int, n varchar(4));
    INSERT @r SELECT ordinal, value FROM STRING_SPLIT(@Rotors, ' ', 1);

    -- plugboard: start with every letter plugged to itself, then swap pairs
    DECLARE @pb char(26) = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    SELECT @pb = STUFF(STUFF(@pb, ASCII(LEFT(value, 1)) - 64, 1, RIGHT(value, 1)),
                       ASCII(RIGHT(value, 1)) - 64, 1, LEFT(value, 1))
    FROM STRING_SPLIT(@Plugs, ' ') WHERE LEN(value) = 2;

    DELETE enigma.Machine;
    INSERT enigma.Machine
    SELECT 1, (SELECT n FROM @r WHERE i = 1), (SELECT n FROM @r WHERE i = 2),
              (SELECT n FROM @r WHERE i = 3), @Reflector, @Rings, @pb, @Start;

    DELETE enigma.Wire;
    TRUNCATE TABLE enigma.KeyLog;
    EXEC enigma.usp_WireSlot 0;  EXEC enigma.usp_WireSlot 4;   -- these never move
    EXEC enigma.usp_WireSlot 1;  EXEC enigma.usp_WireSlot 2;  EXEC enigma.usp_WireSlot 3;
END;
GO

/* ---------------------------------------------------------------------
   3. STEPPING
   ---------------------------------------------------------------------
   Each rotor carries a notch, a point on its ring. Three pawls sit at
   the top (position 0). A pawl drops into a notch when the notch point
   and the pawl point are the same point.
     pawl 1 always pushes the right rotor;
     pawl 2 rests on the right rotor's notch ring: if it drops in, it
            pushes the middle rotor;
     pawl 3 rests on the middle rotor's notch ring: if it drops in, it
            pushes the left rotor AND the middle rotor's own notch.
   That last "and" is the double step.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE enigma.usp_Step @Moved varchar(3) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pos char(3), @nMid char(1), @nRight char(1);
    SELECT @pos = m.Pos, @nMid = wm.Notch, @nRight = wr.Notch
    FROM enigma.Machine m
    JOIN enigma.Wheel wm ON wm.Name = m.MidRotor
    JOIN enigma.Wheel wr ON wr.Name = m.RightRotor;

    DECLARE @pawl geometry = enigma.fn_Pt(6, 0);
    DECLARE @midNotch   geometry = enigma.fn_Pt(6, (ASCII(@nMid)   - ASCII(SUBSTRING(@pos, 2, 1)) + 26) % 26);
    DECLARE @rightNotch geometry = enigma.fn_Pt(6, (ASCII(@nRight) - ASCII(SUBSTRING(@pos, 3, 1)) + 26) % 26);

    DECLARE @pawl2 bit = @rightNotch.STEquals(@pawl),
            @pawl3 bit = @midNotch.STEquals(@pawl);

    DECLARE @stepL bit = @pawl3,
            @stepM bit = CASE WHEN @pawl2 = 1 OR @pawl3 = 1 THEN 1 ELSE 0 END;

    UPDATE enigma.Machine SET Pos =
        CHAR(65 + (ASCII(SUBSTRING(Pos, 1, 1)) - 65 + @stepL) % 26) +
        CHAR(65 + (ASCII(SUBSTRING(Pos, 2, 1)) - 65 + @stepM) % 26) +
        CHAR(65 + (ASCII(SUBSTRING(Pos, 3, 1)) - 65 + 1) % 26);

    SET @Moved = CASE WHEN @stepL = 1 THEN 'L' ELSE '' END
               + CASE WHEN @stepM = 1 THEN 'M' ELSE '' END + 'R';
END;
GO

/* ---------------------------------------------------------------------
   4. A KEYPRESS
   ---------------------------------------------------------------------
   Step, re-wire the rotors that moved, then follow the wire. From
   wherever the signal is, the next wire is "the other wire that
   touches this point". Nothing says which way is out and which is
   back: the reflector just happens to be where the wires turn round.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE enigma.usp_Press @Key char(1), @Lamp char(1) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @moved varchar(3);
    EXEC enigma.usp_Step @moved OUTPUT;
    EXEC enigma.usp_WireSlot 1;
    IF @moved LIKE '%M%' EXEC enigma.usp_WireSlot 2;
    IF @moved LIKE '%L%' EXEC enigma.usp_WireSlot 3;

    DECLARE @start geometry, @startXY varchar(80);
    SELECT @start = Geom, @startXY = enigma.fn_XY(1, N) FROM enigma.Lamp WHERE L = @Key;
    DECLARE @t TABLE (Hop int, Here geometry, Coords varchar(max));

    WITH Trace AS
    (
        SELECT 0 AS Hop, @start AS Here, 0 AS LastWire,
               CAST(@startXY AS varchar(max)) AS Coords
        UNION ALL
        SELECT t.Hop + 1,
               CASE WHEN w.P1.STEquals(t.Here) = 1 THEN w.P2 ELSE w.P1 END,
               w.WireId,
               CAST(t.Coords + CASE WHEN w.P1.STEquals(t.Here) = 1 THEN w.FwdTail ELSE w.RevTail END
                    AS varchar(max))
        FROM Trace t
        JOIN enigma.Wire w
          ON w.WireId <> t.LastWire                       -- not the wire we came in on
         AND (w.P1.STEquals(t.Here) = 1 OR w.P2.STEquals(t.Here) = 1)
        WHERE t.Hop < 20
    )
    INSERT @t SELECT Hop, Here, Coords FROM Trace;

    -- the signal ran out of wire: which lamp is it sitting on?
    SELECT TOP (1) @Lamp = l.L
    FROM @t t JOIN enigma.Lamp l ON l.Geom.STEquals(t.Here) = 1
    WHERE t.Hop > 0
    ORDER BY t.Hop DESC;

    INSERT enigma.KeyLog (Pos, KeyIn, LampOut, Hops, Path)
    SELECT TOP (1) (SELECT Pos FROM enigma.Machine), @Key, @Lamp, Hop,
           geometry::STGeomFromText('LINESTRING(' + Coords + ')', 0)
    FROM @t ORDER BY Hop DESC;
END;
GO

-- Type a message. Anything that isn't A-Z is skipped (Enigma had no spaces).
CREATE OR ALTER PROCEDURE enigma.usp_Type @Text varchar(max), @Out varchar(max) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 1, @c char(1), @lamp char(1);
    SET @Text = UPPER(@Text);
    SET @Out = '';
    WHILE @i <= LEN(@Text)
    BEGIN
        SET @c = SUBSTRING(@Text, @i, 1);
        IF @c LIKE '[A-Z]'
        BEGIN
            EXEC enigma.usp_Press @c, @lamp OUTPUT;
            SET @Out += @lamp;
        END;
        SET @i += 1;
    END;
END;
GO

/* ---------------------------------------------------------------------
   5. THE ARITHMETIC MACHINE
   ---------------------------------------------------------------------
   The same scrambler with no geometry at all, for the proof and for
   the Bombe: shift in, look up the wiring, shift out. Seven lookups.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION enigma.fn_Scramble
    (@L char(26), @M char(26), @R char(26), @Ref char(26),
     @sL int, @sM int, @sR int, @x int)
RETURNS TABLE
AS RETURN
SELECT y7.v AS y
FROM      (SELECT (ASCII(SUBSTRING(@R, (@x + @sR + 26) % 26 + 1, 1)) - 65 - @sR + 26) % 26 AS v) y1
CROSS APPLY (SELECT (ASCII(SUBSTRING(@M, (y1.v + @sM + 26) % 26 + 1, 1)) - 65 - @sM + 26) % 26 AS v) y2
CROSS APPLY (SELECT (ASCII(SUBSTRING(@L, (y2.v + @sL + 26) % 26 + 1, 1)) - 65 - @sL + 26) % 26 AS v) y3
CROSS APPLY (SELECT ASCII(SUBSTRING(@Ref, y3.v + 1, 1)) - 65 AS v) y4
CROSS APPLY (SELECT (CHARINDEX(CHAR(65 + (y4.v + @sL + 26) % 26), @L) - 1 - @sL + 26) % 26 AS v) y5
CROSS APPLY (SELECT (CHARINDEX(CHAR(65 + (y5.v + @sM + 26) % 26), @M) - 1 - @sM + 26) % 26 AS v) y6
CROSS APPLY (SELECT (CHARINDEX(CHAR(65 + (y6.v + @sR + 26) % 26), @R) - 1 - @sR + 26) % 26 AS v) y7;
GO
PRINT 'Enigma built. Now run enigma_sqlserver_run.sql';
GO
