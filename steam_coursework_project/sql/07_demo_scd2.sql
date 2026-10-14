-- Demo for the defense: a price change in OLTP becomes a new SCD Type 2 version in the DWH.
-- Run from this folder with the same -v options as 04 if the OLTP database is not on localhost.
\connect steam_oltp_db
SELECT steam_oltp.change_price('hades', 19.99, DATE '2026-07-01');   -- no-op if the price is already 19.99

\i 04_etl_oltp_to_olap.sql

\connect steam_dwh_db
SET search_path TO steam_dwh;
SELECT g.title, sc.price, sc.valid_from, sc.valid_to, sc.is_current
FROM dim_game_price_scd sc JOIN dim_game g ON g.game_key = sc.game_key
WHERE g.game_slug = 'hades'
ORDER BY sc.valid_from;
