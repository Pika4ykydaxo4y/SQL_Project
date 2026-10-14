-- ETL: steam_oltp_db  ->  steam_dwh_db.
-- Run:  psql -U postgres -f 04_etl_oltp_to_olap.sql
-- Other host or credentials:  psql -v oltp_host=db.example.com -v oltp_port=5432 -v oltp_user=etl -v oltp_password=secret -f ...
-- Rerunnable: dimensions and facts are upserted only when a value differs, SCD rows are closed or added, never rewritten.
\connect steam_dwh_db

\if :{?oltp_host}     \else \set oltp_host 'localhost'      \endif
\if :{?oltp_port}     \else \set oltp_port '5432'           \endif
\if :{?oltp_dbname}   \else \set oltp_dbname 'steam_oltp_db' \endif
\if :{?oltp_user}     \else \set oltp_user 'postgres'       \endif

-- Step 0. Source access: the OLTP schema is mapped into oltp_src through postgres_fdw
SET client_min_messages TO warning;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DROP SERVER IF EXISTS oltp_server CASCADE;
CREATE SERVER oltp_server FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host :'oltp_host', port :'oltp_port', dbname :'oltp_dbname');
\if :{?oltp_password}
CREATE USER MAPPING FOR CURRENT_USER SERVER oltp_server OPTIONS (user :'oltp_user', password :'oltp_password');
\else
CREATE USER MAPPING FOR CURRENT_USER SERVER oltp_server OPTIONS (user :'oltp_user');
\endif
CREATE SCHEMA IF NOT EXISTS oltp_src;
IMPORT FOREIGN SCHEMA steam_oltp FROM SERVER oltp_server INTO oltp_src;

SET search_path TO steam_dwh;
BEGIN;

-- Step 1. Reference data. Permissible values come from OLTP: countries, payment methods, and a fixed calendar.
INSERT INTO dim_date (date_key, full_date, day, month, month_name, year_month, quarter, year, day_of_week, is_weekend)
SELECT to_char(d, 'YYYYMMDD')::int, d::date, extract(day FROM d)::int, extract(month FROM d)::int,
       trim(to_char(d, 'FMMonth')), to_char(d, 'YYYY-MM'), extract(quarter FROM d)::int, extract(year FROM d)::int,
       extract(isodow FROM d)::int, extract(isodow FROM d) >= 6
FROM generate_series(DATE '2025-01-01', DATE '2026-12-31', INTERVAL '1 day') AS d
ON CONFLICT (date_key) DO NOTHING;

INSERT INTO dim_country (country_code, country_name, region)
SELECT country_code, country_name, region FROM oltp_src.countries
ON CONFLICT (country_code) DO UPDATE SET country_name = EXCLUDED.country_name, region = EXCLUDED.region
WHERE (dim_country.country_name, dim_country.region) IS DISTINCT FROM (EXCLUDED.country_name, EXCLUDED.region);

INSERT INTO dim_payment_method (payment_method)
SELECT DISTINCT payment_method FROM oltp_src.purchases
ON CONFLICT (payment_method) DO NOTHING;

-- Step 2. Dimensions (snowflake: user, developer and publisher point to dim_country)
INSERT INTO dim_user (username, country_key, registration_date)
SELECT u.username, dc.country_key, u.registration_date
FROM oltp_src.users u
JOIN oltp_src.countries c ON c.country_id = u.country_id
JOIN dim_country dc ON dc.country_code = c.country_code
ON CONFLICT (username) DO UPDATE SET country_key = EXCLUDED.country_key, registration_date = EXCLUDED.registration_date
WHERE (dim_user.country_key, dim_user.registration_date) IS DISTINCT FROM (EXCLUDED.country_key, EXCLUDED.registration_date);

INSERT INTO dim_developer (developer_name, country_key)
SELECT d.developer_name, dc.country_key
FROM oltp_src.developers d
LEFT JOIN oltp_src.countries c ON c.country_id = d.country_id
LEFT JOIN dim_country dc ON dc.country_code = c.country_code
ON CONFLICT (developer_name) DO UPDATE SET country_key = EXCLUDED.country_key
WHERE dim_developer.country_key IS DISTINCT FROM EXCLUDED.country_key;

INSERT INTO dim_publisher (publisher_name, country_key)
SELECT p.publisher_name, dc.country_key
FROM oltp_src.publishers p
LEFT JOIN oltp_src.countries c ON c.country_id = p.country_id
LEFT JOIN dim_country dc ON dc.country_code = c.country_code
ON CONFLICT (publisher_name) DO UPDATE SET country_key = EXCLUDED.country_key
WHERE dim_publisher.country_key IS DISTINCT FROM EXCLUDED.country_key;

INSERT INTO dim_game (game_slug, title, release_year, age_rating, developer_key, publisher_key)
SELECT g.game_slug, g.title, extract(year FROM g.release_date)::int, g.age_rating, dd.developer_key, dp.publisher_key
FROM oltp_src.games g
JOIN oltp_src.developers d ON d.developer_id = g.developer_id
JOIN dim_developer dd ON dd.developer_name = d.developer_name
JOIN oltp_src.publishers p ON p.publisher_id = g.publisher_id
JOIN dim_publisher dp ON dp.publisher_name = p.publisher_name
ON CONFLICT (game_slug) DO UPDATE
    SET title = EXCLUDED.title, release_year = EXCLUDED.release_year, age_rating = EXCLUDED.age_rating,
        developer_key = EXCLUDED.developer_key, publisher_key = EXCLUDED.publisher_key
WHERE (dim_game.title, dim_game.release_year, dim_game.age_rating, dim_game.developer_key, dim_game.publisher_key)
      IS DISTINCT FROM (EXCLUDED.title, EXCLUDED.release_year, EXCLUDED.age_rating, EXCLUDED.developer_key,
                        EXCLUDED.publisher_key);

INSERT INTO dim_genre (genre_name) SELECT genre_name FROM oltp_src.genres
ON CONFLICT (genre_name) DO NOTHING;

-- Bridge with weights 1 / number of genres per game
CREATE TEMP TABLE tmp_bridge ON COMMIT DROP AS
SELECT dg.game_key, dge.genre_key, round(1.0 / count(*) OVER (PARTITION BY dg.game_key), 9) AS weight
FROM oltp_src.game_genres gg
JOIN oltp_src.games g ON g.game_id = gg.game_id
JOIN dim_game dg ON dg.game_slug = g.game_slug
JOIN oltp_src.genres ge ON ge.genre_id = gg.genre_id
JOIN dim_genre dge ON dge.genre_name = ge.genre_name;

INSERT INTO bridge_game_genre (game_key, genre_key, weight)
SELECT game_key, genre_key, weight FROM tmp_bridge
ON CONFLICT (game_key, genre_key) DO UPDATE SET weight = EXCLUDED.weight
WHERE bridge_game_genre.weight IS DISTINCT FROM EXCLUDED.weight;

DELETE FROM bridge_game_genre b
WHERE NOT EXISTS (SELECT 1 FROM tmp_bridge t WHERE t.game_key = b.game_key AND t.genre_key = b.genre_key);

-- Step 3. SCD Type 2 for game prices
-- 3a. A version that ended in OLTP gets valid_to and is_current = FALSE (the price itself is never changed)
UPDATE dim_game_price_scd s
SET valid_to = ph.valid_to, is_current = (ph.valid_to IS NULL)
FROM oltp_src.price_history ph
JOIN oltp_src.games g ON g.game_id = ph.game_id
JOIN dim_game dg ON dg.game_slug = g.game_slug
WHERE s.game_key = dg.game_key AND s.valid_from = ph.valid_from AND s.price = ph.price
  AND (s.valid_to, s.is_current) IS DISTINCT FROM (ph.valid_to, ph.valid_to IS NULL);

-- 3b. Price versions that do not exist yet become new rows
INSERT INTO dim_game_price_scd (game_key, price, currency, valid_from, valid_to, is_current)
SELECT dg.game_key, ph.price, ph.currency, ph.valid_from, ph.valid_to, ph.valid_to IS NULL
FROM oltp_src.price_history ph
JOIN oltp_src.games g ON g.game_id = ph.game_id
JOIN dim_game dg ON dg.game_slug = g.game_slug
WHERE NOT EXISTS (SELECT 1 FROM dim_game_price_scd s WHERE s.game_key = dg.game_key AND s.valid_from = ph.valid_from);

-- 3c. A different price for an existing version is a correction of history: refuse and log it
INSERT INTO etl_rejects (entity, business_key, reason)
SELECT 'price_version', g.game_slug || ' from ' || ph.valid_from, 'price differs from stored SCD version, history is immutable'
FROM oltp_src.price_history ph
JOIN oltp_src.games g ON g.game_id = ph.game_id
JOIN dim_game dg ON dg.game_slug = g.game_slug
JOIN dim_game_price_scd s ON s.game_key = dg.game_key AND s.valid_from = ph.valid_from
WHERE s.price <> ph.price
ON CONFLICT DO NOTHING;

-- Step 4. fact_sales: extract and transform into staging, validate, publish
TRUNCATE steam_stg.stg_sales;
INSERT INTO steam_stg.stg_sales (purchase_code, purchase_date, registration_date, paid_amount, discount_percent,
    date_key, user_key, game_key, payment_method_key, game_price_key, list_price)
SELECT p.purchase_code, p.purchase_date, du.registration_date, p.paid_amount, p.discount_percent,
       dd.date_key, du.user_key, dg.game_key, pm.payment_method_key, sc.game_price_key, sc.price
FROM oltp_src.purchases p
JOIN oltp_src.users u ON u.user_id = p.user_id
JOIN oltp_src.games g ON g.game_id = p.game_id
LEFT JOIN dim_date dd ON dd.full_date = p.purchase_date
LEFT JOIN dim_user du ON du.username = u.username
LEFT JOIN dim_game dg ON dg.game_slug = g.game_slug
LEFT JOIN dim_payment_method pm ON pm.payment_method = p.payment_method
LEFT JOIN dim_game_price_scd sc ON sc.game_key = dg.game_key
     AND p.purchase_date BETWEEN sc.valid_from AND COALESCE(sc.valid_to, DATE '9999-12-31');

UPDATE steam_stg.stg_sales SET reject_reason = CASE
    WHEN date_key IS NULL                                  THEN 'purchase date outside dim_date range'
    WHEN user_key IS NULL OR game_key IS NULL              THEN 'unknown user or game'
    WHEN payment_method_key IS NULL                        THEN 'unknown payment method'
    WHEN game_price_key IS NULL                            THEN 'no price version valid on purchase date'
    WHEN discount_percent NOT BETWEEN 0 AND 100            THEN 'discount outside 0-100'
    WHEN paid_amount < 0                                   THEN 'negative paid amount'
    WHEN purchase_date < registration_date                 THEN 'purchase before user registration'
    WHEN abs(paid_amount - round(list_price * (100 - discount_percent) / 100.0, 2)) > 0.01
                                                           THEN 'paid amount does not match price version and discount'
    END;

INSERT INTO etl_rejects (entity, business_key, reason)
SELECT 'purchase', purchase_code, reject_reason FROM steam_stg.stg_sales WHERE reject_reason IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO fact_sales (purchase_code, date_key, user_key, game_key, payment_method_key, game_price_key,
                        units_sold, gross_revenue, discount_amount, net_revenue)
SELECT purchase_code, date_key, user_key, game_key, payment_method_key, game_price_key,
       1, list_price, list_price - paid_amount, paid_amount
FROM steam_stg.stg_sales WHERE reject_reason IS NULL
ON CONFLICT (purchase_code) DO UPDATE
    SET date_key = EXCLUDED.date_key, user_key = EXCLUDED.user_key, game_key = EXCLUDED.game_key,
        payment_method_key = EXCLUDED.payment_method_key, game_price_key = EXCLUDED.game_price_key,
        units_sold = EXCLUDED.units_sold, gross_revenue = EXCLUDED.gross_revenue,
        discount_amount = EXCLUDED.discount_amount, net_revenue = EXCLUDED.net_revenue
WHERE (fact_sales.date_key, fact_sales.user_key, fact_sales.game_key, fact_sales.payment_method_key,
       fact_sales.game_price_key, fact_sales.units_sold, fact_sales.gross_revenue, fact_sales.discount_amount,
       fact_sales.net_revenue)
      IS DISTINCT FROM (EXCLUDED.date_key, EXCLUDED.user_key, EXCLUDED.game_key, EXCLUDED.payment_method_key,
                        EXCLUDED.game_price_key, EXCLUDED.units_sold, EXCLUDED.gross_revenue,
                        EXCLUDED.discount_amount, EXCLUDED.net_revenue);

-- Step 5. fact_user_activity: events from three OLTP tables into staging, validate, aggregate
TRUNCATE steam_stg.stg_activity;
INSERT INTO steam_stg.stg_activity (business_key, event_type, event_date, rating, points, date_key, user_key, game_key)
SELECT e.business_key, e.event_type, e.event_date, e.rating, e.points, dd.date_key, du.user_key, dg.game_key
FROM (
    SELECT 'review:' || u.username || ':' || g.game_slug AS business_key, 'review' AS event_type,
           r.review_date AS event_date, r.rating, NULL::int AS points, u.username, g.game_slug
    FROM oltp_src.reviews r JOIN oltp_src.users u ON u.user_id = r.user_id JOIN oltp_src.games g ON g.game_id = r.game_id
    UNION ALL
    SELECT 'achievement:' || u.username || ':' || g.game_slug || ':' || a.achievement_name, 'achievement',
           ua.earned_date, NULL, a.points, u.username, g.game_slug
    FROM oltp_src.user_achievements ua JOIN oltp_src.users u ON u.user_id = ua.user_id
    JOIN oltp_src.achievements a ON a.achievement_id = ua.achievement_id JOIN oltp_src.games g ON g.game_id = a.game_id
    UNION ALL
    SELECT 'wishlist:' || u.username || ':' || g.game_slug, 'wishlist', w.added_date, NULL, NULL, u.username, g.game_slug
    FROM oltp_src.wishlist w JOIN oltp_src.users u ON u.user_id = w.user_id JOIN oltp_src.games g ON g.game_id = w.game_id
) e
LEFT JOIN dim_date dd ON dd.full_date = e.event_date
LEFT JOIN dim_user du ON du.username = e.username
LEFT JOIN dim_game dg ON dg.game_slug = e.game_slug;

UPDATE steam_stg.stg_activity SET reject_reason = CASE
    WHEN date_key IS NULL                                   THEN 'event date outside dim_date range'
    WHEN user_key IS NULL OR game_key IS NULL               THEN 'unknown user or game'
    WHEN event_type = 'review' AND rating NOT BETWEEN 1 AND 5 THEN 'rating outside 1-5'
    END;

INSERT INTO etl_rejects (entity, business_key, reason)
SELECT 'activity', business_key, reject_reason FROM steam_stg.stg_activity WHERE reject_reason IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO fact_user_activity (date_key, user_key, game_key, reviews_count, achievements_count,
                                achievement_points, wishlist_adds, avg_rating)
SELECT date_key, user_key, game_key,
       count(*) FILTER (WHERE event_type = 'review'),
       count(*) FILTER (WHERE event_type = 'achievement'),
       COALESCE(sum(points), 0),
       count(*) FILTER (WHERE event_type = 'wishlist'),
       round(avg(rating), 2)
FROM steam_stg.stg_activity WHERE reject_reason IS NULL
GROUP BY date_key, user_key, game_key
ON CONFLICT (date_key, user_key, game_key) DO UPDATE
    SET reviews_count = EXCLUDED.reviews_count, achievements_count = EXCLUDED.achievements_count,
        achievement_points = EXCLUDED.achievement_points, wishlist_adds = EXCLUDED.wishlist_adds,
        avg_rating = EXCLUDED.avg_rating
WHERE (fact_user_activity.reviews_count, fact_user_activity.achievements_count, fact_user_activity.achievement_points,
       fact_user_activity.wishlist_adds, fact_user_activity.avg_rating)
      IS DISTINCT FROM (EXCLUDED.reviews_count, EXCLUDED.achievements_count, EXCLUDED.achievement_points,
                        EXCLUDED.wishlist_adds, EXCLUDED.avg_rating);

COMMIT;

-- Step 6. Control totals
SELECT 'fact_sales' AS object, count(*) AS rows, sum(net_revenue) AS net_revenue FROM fact_sales
UNION ALL SELECT 'fact_user_activity', count(*), NULL FROM fact_user_activity
UNION ALL SELECT 'dim_game_price_scd', count(*), NULL FROM dim_game_price_scd
UNION ALL SELECT 'etl_rejects', count(*), NULL FROM etl_rejects;
