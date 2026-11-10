/* =====================================================================
   Enigma in a database, Part 3: run the Bombe (SQL Server)
   Run enigma_sqlserver.sql and enigma_bombe.sql first.
   The ciphertext is the Barbarossa message; the crib is a guess at how
   it starts: AUFKLXABTEILUNGXVONX ("reconnaissance unit from ...").
   ===================================================================== */
SET NOCOUNT ON;
USE Enigma;
GO
DECLARE @cipher varchar(max) = 'EDPUDNRGYSZRCXNUYTPOMRMBOFKTBZREZKMLXLVEFGUEYSIOZVEQMIKUBPMMYLKLTTDEISMDICAGYKUACTCDOMOHWXMUUIAUBSTSLRNBZSZWNRFXWFYSSXJZVIJHIDISHPRKLKAYUPADTXQSPINQMATLPIFSVKDASCTACDPBOPVHJK';

-- Bletchley's first trick: a crib can't sit where any letter would map to itself
SELECT 'Crib can sit at offset' AS Slide, o.N AS StartsAt,
       CASE WHEN EXISTS (SELECT 1 FROM enigma.Letter i
                         WHERE i.N < 20 AND SUBSTRING('AUFKLXABTEILUNGXVONX', i.N + 1, 1)
                                          = SUBSTRING(@cipher, o.N + i.N + 1, 1))
            THEN 'no: a letter would map to itself' ELSE 'yes' END AS Possible
FROM enigma.Letter o WHERE o.N < 10;

EXEC enigma.usp_BuildMenu @cipher, 'AUFKLXABTEILUNGXVONX';
SELECT * FROM enigma.Menu ORDER BY Step;

DECLARE @t datetime2 = SYSDATETIME();
EXEC enigma.usp_Bombe;
SELECT 'Bombe' AS Stage, DATEDIFF(ms, @t, SYSDATETIME()) AS Ms;

SELECT o.Rotors, CHAR(65 + s.L) + CHAR(65 + s.M) + CHAR(65 + s.R) AS Cores, s.Plugs
FROM enigma.Stop s JOIN enigma.RotorOrder o ON o.OrdId = s.OrdId;

SET @t = SYSDATETIME();
EXEC enigma.usp_Check @cipher;
SELECT 'Checking machine' AS Stage, DATEDIFF(ms, @t, SYSDATETIME()) AS Ms;
GO
