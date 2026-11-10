# Enigma in a database

The Wehrmacht Enigma I (rotors I–V, reflectors B and C, plugboard, ring settings, double step),
built with SQL Server 2025 geometry (2D) and PostgreSQL/PostGIS (3D), plus Turing's Bombe as set-based SQL.

| Folder | What |
|---|---|
| `sqlserver/enigma_sqlserver.sql` | Builds the machine in a database called `Enigma` (schema `enigma`). Needs SQL Server 2025. |
| `sqlserver/enigma_sqlserver_run.sql` | One rotor, the double step, test vectors, the no-self-encryption proof (27.4M keypresses), keyspace, the Barbarossa message, the "can't turn a shape" test. |
| `sqlserver/enigma_bombe.sql`, `enigma_bombe_run.sql` | Drums (1,054,560 rows), menu, Bombe, checking machine. Recovers the Barbarossa key from a 20-letter crib. |
| `postgresql/enigma_postgis.sql` | The machine as 3D drums on an axle: rotor wires stored once, turned with `ST_Affine`; a keypress is one `LINESTRING Z`. |
| `postgresql/enigma_postgis_run.sql` | Same tests, plus the 3D proofs (`ST_Reverse`). Writes `wires.csv` and `keypress.csv` for drawing. |
| `postgresql/enigma_bombe.sql`, `enigma_bombe_run.sql` | The same Bombe in PostgreSQL. |
| `postgresql/enigma_exploded.sql` | The exploded Enigma: every part as a closed 3D solid (TIN), and the order it comes apart in, worked out by the database. |
| `tools/export_exploded.py` | Copies the solids and the take-apart order to `viewer/enigma_data.js`. |
| `viewer/index.html` | three.js viewer: drag to turn, slider to explode, in the database's take-apart order, round by round. Serve the folder: `python -m http.server 8765 --directory viewer`. |
| `tools/draw.py` | Draws the 2D/3D keypress pictures and charts from the scripts' output (matplotlib). |
| `images/` | Pictures for the post, and the explosion as a video (`09-enigma-explode.mp4`) and a GIF. |
| `enigma-post-draft.md` | The blog post draft. |

Order: `enigma_sqlserver.sql` → `enigma_sqlserver_run.sql` → `enigma_bombe.sql` → `enigma_bombe_run.sql`
(PostgreSQL: `enigma_postgis.sql` → `enigma_postgis_run.sql` → `enigma_bombe.sql` → `enigma_bombe_run.sql`, all with `psql -d enigma -f`).

Checked against: AAAAA → BDZGO (I II III, B, AAA/AAA), rings BBB → EWTYX, the double step ADU → ADV → AEW → BFX,
and the 1941 Barbarossa test message (II IV V, B, BUL, AV BS CG DL FU HZ IN KM OW RX, BLA).

Tested on SQL Server 2025 (Linux container, mcr.microsoft.com/mssql/server:2025-latest) and PostgreSQL 16 / PostGIS 3.4, 4 cores.
