/* =====================================================================
   Enigma in a database, Part 3: the Bombe (SQL Server, no geometry)
   ---------------------------------------------------------------------
   Turing's idea, as set-based SQL. Given a ciphertext and a guessed
   bit of plaintext (a "crib"), throw away every machine setting that
   leads to a contradiction. Whatever is left is a "stop".

     1. Drums     : every rotor order x every rotor offset, with the
                    scrambler's whole alphabet worked out once.
                    60 x 17,576 = 1,054,560 rows.
     2. The menu  : the crib and the ciphertext as a graph of letters.
     3. The Bombe : guess the plugboard partner of one letter, follow
                    the menu, and drop every guess that contradicts
                    itself (Welchman's diagonal board included).
     4. Checking  : recover the ring settings and the last plug from
                    the stop, and read the message.

   Needs enigma_sqlserver.sql first (for enigma.Wheel and fn_Scramble).
   Like the real Bombe, it assumes the middle rotor doesn't move while
   the crib is being typed.
   ===================================================================== */
SET NOCOUNT ON;
USE Enigma;
GO
DROP TABLE IF EXISTS enigma.Drum, enigma.RotorOrder, enigma.Menu, enigma.Stop;
GO

/* ---------------------------------------------------------------------
   1. DRUMS
   --------------------------------------------------------------------- */
CREATE TABLE enigma.RotorOrder
(
    OrdId tinyint IDENTITY PRIMARY KEY,
    Rotors varchar(12) NOT NULL,
    L char(26) NOT NULL, M char(26) NOT NULL, R char(26) NOT NULL
);
INSERT enigma.RotorOrder (Rotors, L, M, R)
SELECT l.Name + ' ' + m.Name + ' ' + r.Name, l.Wiring, m.Wiring, r.Wiring
FROM enigma.Wheel l, enigma.Wheel m, enigma.Wheel r
WHERE l.Kind = 'ROTOR' AND m.Kind = 'ROTOR' AND r.Kind = 'ROTOR'
  AND l.Name NOT IN (m.Name, r.Name) AND m.Name <> r.Name
ORDER BY l.Name, m.Name, r.Name;

CREATE TABLE enigma.Drum
(
    OrdId tinyint NOT NULL,
    L tinyint NOT NULL, M tinyint NOT NULL, R tinyint NOT NULL,   -- offsets (window - ring)
    Perm char(26) NOT NULL,                                       -- where A..Z come out
    CONSTRAINT PK_Drum PRIMARY KEY (OrdId, L, M, R)
);
GO
DECLARE @t datetime2 = SYSDATETIME();
DECLARE @refB char(26) = (SELECT Wiring FROM enigma.Wheel WHERE Name = 'B');
INSERT enigma.Drum WITH (TABLOCK) (OrdId, L, M, R, Perm)
SELECT o.OrdId, a.N, b.N, c.N, p.Perm
FROM enigma.RotorOrder o
CROSS JOIN enigma.Letter a CROSS JOIN enigma.Letter b CROSS JOIN enigma.Letter c
CROSS APPLY (SELECT STRING_AGG(CHAR(65 + s.y), '') WITHIN GROUP (ORDER BY x.N) AS Perm
             FROM enigma.Letter x
             CROSS APPLY enigma.fn_Scramble(o.L, o.M, o.R, @refB, a.N, b.N, c.N, x.N) s) p;
DECLARE @msg varchar(100) = CONCAT('Drums built: ', @@ROWCOUNT, ' rows in ',
                                  DATEDIFF(ms, @t, SYSDATETIME()), ' ms');
PRINT @msg;
GO

/* ---------------------------------------------------------------------
   2. THE MENU
   ---------------------------------------------------------------------
   Crib letter i and cipher letter i are joined by an edge labelled i.
   We walk it from the busiest letter, taking loop-closing edges first,
   because loops are what kill wrong guesses.
   --------------------------------------------------------------------- */
CREATE TABLE enigma.Menu
(
    Step  tinyint PRIMARY KEY,
    Pos   tinyint NOT NULL,          -- index into the crib (0-based)
    Known char(1) NOT NULL,          -- the end whose partner we already know
    Other char(1) NOT NULL,
    Closes bit NOT NULL              -- both ends already known: a loop
);
GO
CREATE OR ALTER PROCEDURE enigma.usp_BuildMenu @Cipher varchar(max), @Crib varchar(100)
AS
BEGIN
    SET NOCOUNT ON;
    DELETE enigma.Menu;
    DECLARE @e TABLE (Pos tinyint PRIMARY KEY, A char(1), B char(1), Used bit DEFAULT 0);
    INSERT @e (Pos, A, B)
    SELECT n.N, SUBSTRING(@Crib, n.N + 1, 1), SUBSTRING(@Cipher, n.N + 1, 1)
    FROM enigma.Letter n WHERE n.N < LEN(@Crib)
    UNION ALL   -- cribs longer than 26 letters
    SELECT 26 + n.N, SUBSTRING(@Crib, 27 + n.N, 1), SUBSTRING(@Cipher, 27 + n.N, 1)
    FROM enigma.Letter n WHERE 26 + n.N < LEN(@Crib);

    IF EXISTS (SELECT 1 FROM @e WHERE A = B)
    BEGIN RAISERROR('The crib puts a letter on itself. Enigma cannot do that: slide it along.', 16, 1); RETURN; END;

    DECLARE @known TABLE (L char(1) PRIMARY KEY);
    INSERT @known
    SELECT TOP (1) L FROM (SELECT A AS L FROM @e UNION ALL SELECT B FROM @e) x
    GROUP BY L ORDER BY COUNT(*) DESC, L;

    DECLARE @step tinyint = 0, @pos tinyint, @k char(1), @o char(1), @closes bit;
    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @pos = e.Pos,
               @k = CASE WHEN ka.L IS NOT NULL THEN e.A ELSE e.B END,
               @o = CASE WHEN ka.L IS NOT NULL THEN e.B ELSE e.A END,
               @closes = CASE WHEN ka.L IS NOT NULL AND kb.L IS NOT NULL THEN 1 ELSE 0 END
        FROM @e e
        LEFT JOIN @known ka ON ka.L = e.A
        LEFT JOIN @known kb ON kb.L = e.B
        WHERE e.Used = 0 AND (ka.L IS NOT NULL OR kb.L IS NOT NULL)
        ORDER BY CASE WHEN ka.L IS NOT NULL AND kb.L IS NOT NULL THEN 0 ELSE 1 END, e.Pos;
        IF @@ROWCOUNT = 0 BREAK;

        INSERT enigma.Menu VALUES (@step, @pos, @k, @o, @closes);
        UPDATE @e SET Used = 1 WHERE Pos = @pos;
        IF NOT EXISTS (SELECT 1 FROM @known WHERE L = @o) INSERT @known VALUES (@o);
        SET @step += 1;
    END;
END;
GO

/* ---------------------------------------------------------------------
   3. THE BOMBE
   ---------------------------------------------------------------------
   A candidate is (rotor order, offsets, plugboard so far). The
   plugboard so far is a 26-letter string, '.' for "don't know yet".
   Every menu step works out one more plug and keeps the candidate only
   if the plugboard still makes sense:
     * the letter's partner is unknown, or is the one we just worked out;
     * the partner's partner is unknown, or is the letter (a plug is a
       pair: this is Welchman's diagonal board).
   --------------------------------------------------------------------- */
CREATE TABLE enigma.Stop
(
    OrdId tinyint, L tinyint, M tinyint, R tinyint, Plugs char(26)
);
GO
CREATE OR ALTER PROCEDURE enigma.usp_Bombe
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t datetime2 = SYSDATETIME(), @step int = 0, @n bigint,
            @pos int, @k char(1), @o char(1);
    DECLARE @log TABLE (Step int, Edge varchar(12), Survivors bigint, Ms int);

    DROP TABLE IF EXISTS #cur, #next;

    -- the test register: every drum position, with all 26 guesses for the busiest letter
    DECLARE @test char(1) = (SELECT Known FROM enigma.Menu WHERE Step = 0);
    SELECT d.OrdId, d.L, d.M, d.R,
           CAST(STUFF(STUFF(REPLICATE('.', 26), ASCII(@test) - 64, 1, g.L),
                      g.N + 1, 1, @test) AS char(26)) AS Plugs
    INTO #cur
    FROM enigma.Drum d CROSS JOIN enigma.Letter g;
    INSERT @log VALUES (-1, 'guess ' + @test + '=?', @@ROWCOUNT, DATEDIFF(ms, @t, SYSDATETIME()));

    WHILE 1 = 1
    BEGIN
        SELECT @pos = Pos, @k = Known, @o = Other FROM enigma.Menu WHERE Step = @step;
        IF @@ROWCOUNT = 0 BREAK;

        SELECT c.OrdId, c.L, c.M, c.R,
               CAST(STUFF(STUFF(c.Plugs, ASCII(@o) - 64, 1, v.V), ASCII(v.V) - 64, 1, @o) AS char(26)) AS Plugs
        INTO #next
        FROM #cur c
        JOIN enigma.Drum d
          ON d.OrdId = c.OrdId AND d.L = c.L AND d.M = c.M AND d.R = (c.R + @pos + 1) % 26
        CROSS APPLY (SELECT SUBSTRING(d.Perm, ASCII(SUBSTRING(c.Plugs, ASCII(@k) - 64, 1)) - 64, 1) AS V) v
        WHERE SUBSTRING(c.Plugs, ASCII(@o) - 64, 1) IN ('.', v.V)
          AND SUBSTRING(c.Plugs, ASCII(v.V) - 64, 1) IN ('.', @o);
        SET @n = @@ROWCOUNT;

        INSERT @log VALUES (@step, CONCAT(@k, '-', @o, ' @', @pos), @n, DATEDIFF(ms, @t, SYSDATETIME()));
        TRUNCATE TABLE #cur;
        INSERT #cur WITH (TABLOCK) SELECT * FROM #next;
        DROP TABLE #next;
        SET @step += 1;
    END;

    DELETE enigma.Stop;
    INSERT enigma.Stop SELECT OrdId, L, M, R, Plugs FROM #cur;
    SELECT * FROM @log ORDER BY Step;
END;
GO
PRINT 'Bombe built.';
GO

/* ---------------------------------------------------------------------
   4. THE CHECKING MACHINE
   ---------------------------------------------------------------------
   A stop gives the rotor order, the offsets (window minus ring) and
   most of the plugboard. What it can't give is the ring settings,
   because they only decide WHEN the middle rotor kicks. So try them
   all, decrypt the whole message each time, and keep the one that
   looks most like German: the index of coincidence (German is about
   0.076, gibberish about 0.038). Then do the same for the last plug.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION enigma.fn_Decrypt
    (@OrdId tinyint, @Reflector varchar(4), @Rings char(3), @Start char(3),
     @Plugs char(26), @Cipher varchar(max))
RETURNS TABLE
AS RETURN
WITH m AS
(
    SELECT o.L, o.M, o.R, (SELECT Wiring FROM enigma.Wheel WHERE Name = @Reflector) AS Ref,
           ASCII(wm.Notch) - 65 AS nM, ASCII(wr.Notch) - 65 AS nR,
           ASCII(SUBSTRING(@Rings, 1, 1)) - 65 AS gL,
           ASCII(SUBSTRING(@Rings, 2, 1)) - 65 AS gM,
           ASCII(SUBSTRING(@Rings, 3, 1)) - 65 AS gR
    FROM enigma.RotorOrder o
    JOIN enigma.Wheel wm ON wm.Name = PARSENAME(REPLACE(o.Rotors, ' ', '.'), 2)
    JOIN enigma.Wheel wr ON wr.Name = PARSENAME(REPLACE(o.Rotors, ' ', '.'), 1)
    WHERE o.OrdId = @OrdId
),
k AS   -- the windows, one keypress at a time (double step included)
(
    SELECT 0 AS i,
           ASCII(SUBSTRING(@Start, 1, 1)) - 65 AS pL,
           ASCII(SUBSTRING(@Start, 2, 1)) - 65 AS pM,
           ASCII(SUBSTRING(@Start, 3, 1)) - 65 AS pR
    UNION ALL
    SELECT k.i + 1,
           (k.pL + CASE WHEN k.pM = m.nM THEN 1 ELSE 0 END) % 26,
           (k.pM + CASE WHEN k.pM = m.nM OR k.pR = m.nR THEN 1 ELSE 0 END) % 26,
           (k.pR + 1) % 26
    FROM k CROSS JOIN m
    WHERE k.i < LEN(@Cipher)
)
SELECT k.i, SUBSTRING(@Plugs, s.y + 1, 1) AS P      -- and back out through the plugboard
FROM k CROSS JOIN m
CROSS APPLY (SELECT ASCII(SUBSTRING(@Plugs, ASCII(SUBSTRING(@Cipher, k.i, 1)) - 64, 1)) - 65 AS x) c
CROSS APPLY enigma.fn_Scramble(m.L, m.M, m.R, m.Ref, k.pL - m.gL, k.pM - m.gM, k.pR - m.gR, c.x) s
WHERE k.i > 0;
GO
CREATE OR ALTER FUNCTION enigma.fn_IoC (@Text varchar(max))
RETURNS float
AS
BEGIN
    RETURN (SELECT SUM(CAST(n AS float) * (n - 1)) / (LEN(@Text) * (LEN(@Text) - 1.0))
            FROM (SELECT LEN(@Text) - LEN(REPLACE(@Text, l.L, '')) AS n FROM enigma.Letter l) c);
END;
GO
CREATE OR ALTER PROCEDURE enigma.usp_Check @Cipher varchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ord tinyint, @offs char(3), @plugs char(26);
    SELECT TOP (1) @ord = OrdId, @offs = CHAR(65 + L) + CHAR(65 + M) + CHAR(65 + R),
           @plugs = REPLACE(Plugs, '.', '?') FROM enigma.Stop;

    -- unknown plugs: plug them to themselves for now
    DECLARE @p0 char(26) = (SELECT STRING_AGG(CASE WHEN SUBSTRING(@plugs, N + 1, 1) = '?' THEN L
                                                   ELSE SUBSTRING(@plugs, N + 1, 1) END, '')
                                   WITHIN GROUP (ORDER BY N) FROM enigma.Letter);

    -- ring settings: left ring changes nothing we can see, so it stays A
    DROP TABLE IF EXISTS #rings;
    SELECT g.Rings,
           CHAR(65 + (ASCII(SUBSTRING(@offs, 1, 1)) - 65 + ASCII(SUBSTRING(g.Rings, 1, 1)) - 65) % 26) +
           CHAR(65 + (ASCII(SUBSTRING(@offs, 2, 1)) - 65 + ASCII(SUBSTRING(g.Rings, 2, 1)) - 65) % 26) +
           CHAR(65 + (ASCII(SUBSTRING(@offs, 3, 1)) - 65 + ASCII(SUBSTRING(g.Rings, 3, 1)) - 65) % 26) AS Start,
           CAST(NULL AS varchar(max)) AS Plain
    INTO #rings
    FROM (SELECT 'A' + m.L + r.L AS Rings FROM enigma.Letter m CROSS JOIN enigma.Letter r) g;

    UPDATE g SET Plain = (SELECT STRING_AGG(P, '') WITHIN GROUP (ORDER BY i)
                          FROM enigma.fn_Decrypt(@ord, 'B', g.Rings, g.Start, @p0, @Cipher))
    FROM #rings g
    OPTION (MAXRECURSION 0);

    SELECT TOP (5) Rings, Start, enigma.fn_IoC(Plain) AS IoC, LEFT(Plain, 60) AS Plain
    FROM #rings ORDER BY enigma.fn_IoC(Plain) DESC, Rings;

    DECLARE @rings char(3), @start char(3);
    SELECT TOP (1) @rings = Rings, @start = Start FROM #rings ORDER BY enigma.fn_IoC(Plain) DESC, Rings;

    -- the last plug: try no plug, then every pair of the unknown letters
    DROP TABLE IF EXISTS #plug;
    SELECT '--' AS Pair, @p0 AS Plugs, CAST(NULL AS varchar(max)) AS Plain INTO #plug;
    INSERT #plug (Pair, Plugs)
    SELECT a.L + b.L,
           STUFF(STUFF(@p0, a.N + 1, 1, b.L), b.N + 1, 1, a.L)
    FROM enigma.Letter a JOIN enigma.Letter b ON a.N < b.N
    WHERE SUBSTRING(@plugs, a.N + 1, 1) = '?' AND SUBSTRING(@plugs, b.N + 1, 1) = '?';

    UPDATE p SET Plain = (SELECT STRING_AGG(P, '') WITHIN GROUP (ORDER BY i)
                          FROM enigma.fn_Decrypt(@ord, 'B', @rings, @start, p.Plugs, @Cipher))
    FROM #plug p
    OPTION (MAXRECURSION 0);

    SELECT Pair, enigma.fn_IoC(Plain) AS IoC, LEFT(Plain, 60) AS Plain
    FROM #plug ORDER BY IoC DESC;

    SELECT TOP (1) (SELECT Rotors FROM enigma.RotorOrder WHERE OrdId = @ord) AS Rotors,
           @rings AS Rings, @start AS Start, Plugs, Plain
    FROM #plug ORDER BY enigma.fn_IoC(Plain) DESC;
END;
GO
PRINT 'Checking machine built.';
GO
