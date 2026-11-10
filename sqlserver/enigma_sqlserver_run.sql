/* =====================================================================
   Enigma in a database, Part 1: the run script (SQL Server 2025)
   Run enigma_sqlserver.sql first. In SSMS, look at the Spatial results
   tab for the queries that return geometry.
   ===================================================================== */
SET NOCOUNT ON;
USE Enigma;
GO

/* ---------------------------------------------------------------------
   Episode 1: one rotor. Rotor I on its own, in the right-hand slot.
   --------------------------------------------------------------------- */
EXEC enigma.usp_Setup 'III II I', 'B', 'AAA', '', 'AAA';
SELECT 'Rotor I: contact -> pin' AS Episode1, CHAR(65 + PIn) AS Contact, CHAR(65 + POut) AS Pin,
       Geom, ROUND(Geom.STLength(), 3) AS WireLength
FROM enigma.Wire WHERE Slot = 1 ORDER BY PIn;
GO

/* ---------------------------------------------------------------------
   Episode 2: stepping. Start at ADU with I II III and watch the middle
   rotor step twice in a row: ADU -> ADV -> AEW -> BFX.
   --------------------------------------------------------------------- */
EXEC enigma.usp_Setup 'I II III', 'B', 'AAA', '', 'ADU';
DECLARE @i int = 0, @moved varchar(3);
DECLARE @steps TABLE (KeyNo int, Windows char(3), Moved varchar(3));
INSERT @steps SELECT 0, Pos, '' FROM enigma.Machine;
WHILE @i < 5
BEGIN
    EXEC enigma.usp_Step @moved OUTPUT;
    SET @i += 1;
    INSERT @steps SELECT @i, Pos, @moved FROM enigma.Machine;
END;
SELECT 'Double step' AS Episode2, * FROM @steps;
GO

/* ---------------------------------------------------------------------
   Episode 3: the whole machine, and the textbook test.
   I II III, reflector B, rings AAA, start AAA: AAAAA -> BDZGO
   --------------------------------------------------------------------- */
DECLARE @o varchar(max);
EXEC enigma.usp_Setup 'I II III', 'B', 'AAA', '', 'AAA';
EXEC enigma.usp_Type 'AAAAA', @o OUTPUT;
SELECT 'AAAAA ->' AS Episode3, @o AS Lamps, 'BDZGO' AS Expected;

-- one keypress, start to finish: nine wires, one line
SELECT TOP (1) 'First keypress' AS Episode3, KeyIn, LampOut, Hops, Path.STNumPoints() AS Points,
       ROUND(Path.STLength(), 2) AS PathLength, Path
FROM enigma.KeyLog ORDER BY Seq;
GO

/* ---------------------------------------------------------------------
   Why no letter can ever light itself.
   --------------------------------------------------------------------- */
-- 1. The reflector never wires a contact to itself (a wire from a point
--    to the same point isn't a wire: SQL Server won't even call it valid)
SELECT 'Reflector wires' AS Proof, COUNT(*) AS Wires,
       SUM(CASE WHEN P1.STEquals(P2) = 1 THEN 1 ELSE 0 END) AS LoopsBackOnItself,
       ROUND(MIN(Geom.STLength()), 3) AS ShortestWire
FROM enigma.Wire WHERE Slot = 4;

SELECT 'LINESTRING(1 1, 1 1)' AS Proof, geometry::STGeomFromText('LINESTRING(1 1, 1 1)', 0).STIsValid() AS IsValid;

-- 2. The path is reversible: press the lamp's letter and you get the
--    same path backwards. So if A lit A, the path would have to come
--    back on itself at the reflector.
DECLARE @o1 varchar(max), @o2 varchar(max), @p1 geometry, @p2 geometry;
EXEC enigma.usp_Setup 'I II III', 'B', 'AAA', '', 'AAA';
EXEC enigma.usp_Type 'A', @o1 OUTPUT;                  -- A lights B
SELECT @p1 = Path FROM enigma.KeyLog;
EXEC enigma.usp_Setup 'I II III', 'B', 'AAA', '', 'AAA';
EXEC enigma.usp_Type @o1, @o2 OUTPUT;                  -- so B should light A
SELECT @p2 = Path FROM enigma.KeyLog;
SELECT 'Same path both ways' AS Proof, 'A->' + @o1 AS FirstKey, @o1 + '->' + @o2 AS SecondKey,
       @p1.STEquals(@p2) AS SameShape,
       @p1.STStartPoint().STEquals(@p2.STEndPoint()) AS StartIsOtherEnd;
GO

-- 3. Brute force, because we can: every rotor order, every rotor
--    position, every letter, reflector B. 27,418,560 keypresses.
DECLARE @t datetime2 = SYSDATETIME();
DECLARE @refB char(26) = (SELECT Wiring FROM enigma.Wheel WHERE Name = 'B');
WITH Ord AS
(
    SELECT l.Wiring AS L, m.Wiring AS M, r.Wiring AS R
    FROM enigma.Wheel l, enigma.Wheel m, enigma.Wheel r
    WHERE l.Kind = 'ROTOR' AND m.Kind = 'ROTOR' AND r.Kind = 'ROTOR'
      AND l.Name NOT IN (m.Name, r.Name) AND m.Name <> r.Name
)
SELECT 'Every keypress' AS Proof, COUNT_BIG(*) AS Keypresses,
       SUM(CASE WHEN s.y = x.N THEN 1 ELSE 0 END) AS LitItself,
       SUM(CASE WHEN s2.y <> x.N THEN 1 ELSE 0 END) AS NotReversible
FROM Ord o
CROSS JOIN enigma.Letter a CROSS JOIN enigma.Letter b CROSS JOIN enigma.Letter c
CROSS JOIN enigma.Letter x
CROSS APPLY enigma.fn_Scramble(o.L, o.M, o.R, @refB, a.N, b.N, c.N, x.N) s
CROSS APPLY enigma.fn_Scramble(o.L, o.M, o.R, @refB, a.N, b.N, c.N, s.y) s2;
SELECT 'Every keypress' AS Proof, DATEDIFF(ms, @t, SYSDATETIME()) AS Ms;
GO

/* ---------------------------------------------------------------------
   How many ways to set it up? 3 rotors from 5, in order; 26^3 start
   positions; 10 plugboard cables. (Ring settings left out, as usual.)
   --------------------------------------------------------------------- */
DECLARE @f TABLE (n int PRIMARY KEY, f decimal(38, 0));
DECLARE @n int = 0, @acc decimal(38, 0) = 1;
WHILE @n <= 26 BEGIN IF @n > 0 SET @acc *= @n; INSERT @f VALUES (@n, @acc); SET @n += 1; END;
SELECT 'Keyspace' AS What,
       5 * 4 * 3 AS RotorOrders,
       26 * 26 * 26 AS StartPositions,
       CAST((SELECT f FROM @f WHERE n = 26) /
            ((SELECT f FROM @f WHERE n = 6) * (SELECT f FROM @f WHERE n = 10) * POWER(CAST(2 AS decimal(38,0)), 10))
            AS decimal(38, 0)) AS PlugboardWays,
       CAST(60 * 17576 * ((SELECT f FROM @f WHERE n = 26) /
            ((SELECT f FROM @f WHERE n = 6) * (SELECT f FROM @f WHERE n = 10) * POWER(CAST(2 AS decimal(38,0)), 10)))
            AS decimal(38, 0)) AS Total;
GO

/* ---------------------------------------------------------------------
   A real message: 7 July 1941, Operation Barbarossa.
   Key: II IV V, reflector B, rings BUL, plugs AV BS CG DL FU HZ IN KM OW RX,
   start BLA.
   --------------------------------------------------------------------- */
DECLARE @t datetime2 = SYSDATETIME(), @o varchar(max);
EXEC enigma.usp_Setup 'II IV V', 'B', 'BUL', 'AV BS CG DL FU HZ IN KM OW RX', 'BLA';
EXEC enigma.usp_Type 'EDPUDNRGYSZRCXNUYTPOMRMBOFKTBZREZKMLXLVEFGUEYSIOZVEQMIKUBPMMYLKLTTDEISMDICAGYKUACTCDOMOHWXMUUIAUBSTSLRNBZSZWNRFXWFYSSXJZVIJHIDISHPRKLKAYUPADTXQSPINQMATLPIFSVKDASCTACDPBOPVHJK', @o OUTPUT;
SELECT 'Barbarossa' AS Message, LEN(@o) AS Letters, DATEDIFF(ms, @t, SYSDATETIME()) AS Ms,
       DATEDIFF(ms, @t, SYSDATETIME()) * 1.0 / LEN(@o) AS MsPerKey, @o AS Plain;
GO

/* ---------------------------------------------------------------------
   Where SQL Server ran out of road: there is no way to turn a shape.
   Turn a point by hand, 1/26 of a turn, 26 times. It should come back
   to where it started. It doesn't, quite.
   --------------------------------------------------------------------- */
DECLARE @x float = 0, @y float = 1, @a float = 2 * PI() / 26, @i int = 0, @nx float;
WHILE @i < 26
BEGIN
    SET @nx = @x * COS(@a) + @y * SIN(@a);
    SET @y  = -@x * SIN(@a) + @y * COS(@a);
    SET @x  = @nx;
    SET @i += 1;
END;
SELECT 'Turned 26 times' AS RanOutOfRoad,
       geometry::Point(@x, @y, 0).STEquals(geometry::Point(0, 1, 0)) AS BackWhereItStarted,
       geometry::Point(@x, @y, 0).STDistance(geometry::Point(0, 1, 0)) AS MissedBy;
GO
