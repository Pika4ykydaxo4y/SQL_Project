# Steam-like platform: OLTP, OLAP, ETL, Power BI

PostgreSQL course project. Two databases: `steam_oltp_db` (3NF, 13 tables) and `steam_dwh_db` (snowflake, 2 facts, SCD Type 2, bridge).

| Folder | Content |
|---|---|
| `csv/` | 5 source files: users, games, price_history, purchases, user_activity |
| `sql/` | Scripts 00 to 07 plus `99_reset.sql` |
| `diagrams/` | Logical schemas of OLTP and OLAP |
| `powerbi/` | `POWERBI_GUIDE.md` with measures and layout, and the report file |
| `docs/` | Report with run instructions (`CourseWork_Report_SteamLike.docx`) |
| `tools/` | `generate_data.py` (rebuilds the CSV files), `make_diagrams.py` (redraws the schemas) |

Run from the `sql` folder: `00` > `01` > `02` > `03` > `04`, then `05`, `06` and the SCD demo `07`. Details are in the report.
