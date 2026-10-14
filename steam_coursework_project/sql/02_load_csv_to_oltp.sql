-- Loads the five CSV files into the OLTP database.
-- Run from this folder (paths are relative):  psql -U postgres -f 02_load_csv_to_oltp.sql
-- Rerunnable: every upsert touches a row only when at least one value differs from the CSV,
-- so unchanged rows keep their physical version and nothing is overwritten.
\connect steam_oltp_db
SET search_path TO steam_oltp;
BEGIN;

-- Reference data: countries are a fixed dictionary, not a CSV topic
INSERT INTO countries (country_code, country_name, region) VALUES
    ('LT','Lithuania','Europe'), ('PL','Poland','Europe'), ('DE','Germany','Europe'),
    ('US','United States','North America'), ('GB','United Kingdom','Europe'), ('BY','Belarus','Europe'),
    ('LV','Latvia','Europe'), ('EE','Estonia','Europe'), ('BE','Belgium','Europe'),
    ('DK','Denmark','Europe'), ('SE','Sweden','Europe')
ON CONFLICT (country_code) DO UPDATE SET country_name = EXCLUDED.country_name, region = EXCLUDED.region
WHERE (countries.country_name, countries.region) IS DISTINCT FROM (EXCLUDED.country_name, EXCLUDED.region);

-- ---------- users.csv
CREATE TEMP TABLE stg_users (username text, email text, country_code text, registration_date date) ON COMMIT DROP;
\copy stg_users FROM '../csv/users.csv' CSV HEADER
INSERT INTO users (username, email, country_id, registration_date)
SELECT s.username, s.email, c.country_id, s.registration_date
FROM stg_users s JOIN countries c ON c.country_code = s.country_code
ON CONFLICT (username) DO UPDATE
    SET email = EXCLUDED.email, country_id = EXCLUDED.country_id, registration_date = EXCLUDED.registration_date
WHERE (users.email, users.country_id, users.registration_date)
      IS DISTINCT FROM (EXCLUDED.email, EXCLUDED.country_id, EXCLUDED.registration_date);

-- ---------- games.csv  (developers, publishers, genres and links are derived from it)
CREATE TEMP TABLE stg_games (game_slug text, title text, developer_name text, developer_country text,
    publisher_name text, publisher_country text, release_date date, base_price numeric, age_rating text,
    genres text) ON COMMIT DROP;
\copy stg_games FROM '../csv/games.csv' CSV HEADER

INSERT INTO developers (developer_name, country_id)
SELECT DISTINCT ON (s.developer_name) s.developer_name, c.country_id
FROM stg_games s LEFT JOIN countries c ON c.country_code = s.developer_country
ORDER BY s.developer_name
ON CONFLICT (developer_name) DO UPDATE SET country_id = EXCLUDED.country_id
WHERE developers.country_id IS DISTINCT FROM EXCLUDED.country_id;

INSERT INTO publishers (publisher_name, country_id)
SELECT DISTINCT ON (s.publisher_name) s.publisher_name, c.country_id
FROM stg_games s LEFT JOIN countries c ON c.country_code = s.publisher_country
ORDER BY s.publisher_name
ON CONFLICT (publisher_name) DO UPDATE SET country_id = EXCLUDED.country_id
WHERE publishers.country_id IS DISTINCT FROM EXCLUDED.country_id;

INSERT INTO games (game_slug, title, developer_id, publisher_id, release_date, base_price, age_rating)
SELECT s.game_slug, s.title, d.developer_id, p.publisher_id, s.release_date, s.base_price, s.age_rating
FROM stg_games s
JOIN developers d ON d.developer_name = s.developer_name
JOIN publishers p ON p.publisher_name = s.publisher_name
ON CONFLICT (game_slug) DO UPDATE
    SET title = EXCLUDED.title, developer_id = EXCLUDED.developer_id, publisher_id = EXCLUDED.publisher_id,
        release_date = EXCLUDED.release_date, base_price = EXCLUDED.base_price, age_rating = EXCLUDED.age_rating
WHERE (games.title, games.developer_id, games.publisher_id, games.release_date, games.base_price, games.age_rating)
      IS DISTINCT FROM (EXCLUDED.title, EXCLUDED.developer_id, EXCLUDED.publisher_id, EXCLUDED.release_date,
                        EXCLUDED.base_price, EXCLUDED.age_rating);

INSERT INTO genres (genre_name)
SELECT DISTINCT trim(g) FROM stg_games s, unnest(string_to_array(s.genres, '|')) AS g
ON CONFLICT (genre_name) DO NOTHING;

INSERT INTO game_genres (game_id, genre_id)
SELECT DISTINCT ga.game_id, ge.genre_id
FROM stg_games s
JOIN games ga ON ga.game_slug = s.game_slug
CROSS JOIN LATERAL unnest(string_to_array(s.genres, '|')) AS g
JOIN genres ge ON ge.genre_name = trim(g)
ON CONFLICT DO NOTHING;

-- ---------- price_history.csv
-- A CSV row may close an interval that is still open. A closed interval is history and is never reopened or changed.
CREATE TEMP TABLE stg_price_history (game_slug text, valid_from date, valid_to date, price numeric, currency char(3))
    ON COMMIT DROP;
\copy stg_price_history FROM '../csv/price_history.csv' CSV HEADER
INSERT INTO price_history (game_id, valid_from, valid_to, price, currency)
SELECT g.game_id, s.valid_from, s.valid_to, s.price, s.currency
FROM stg_price_history s JOIN games g ON g.game_slug = s.game_slug
ON CONFLICT (game_id, valid_from) DO UPDATE
    SET valid_to = EXCLUDED.valid_to, price = EXCLUDED.price, currency = EXCLUDED.currency
WHERE price_history.valid_to IS NULL
  AND (price_history.valid_to, price_history.price, price_history.currency)
      IS DISTINCT FROM (EXCLUDED.valid_to, EXCLUDED.price, EXCLUDED.currency);

-- ---------- purchases.csv
CREATE TEMP TABLE stg_purchases (purchase_code text, username text, game_slug text, purchase_date date,
    paid_amount numeric, discount_percent int, payment_method text) ON COMMIT DROP;
\copy stg_purchases FROM '../csv/purchases.csv' CSV HEADER
INSERT INTO purchases (purchase_code, user_id, game_id, purchase_date, paid_amount, discount_percent, payment_method)
SELECT s.purchase_code, u.user_id, g.game_id, s.purchase_date, s.paid_amount, s.discount_percent, s.payment_method
FROM stg_purchases s JOIN users u ON u.username = s.username JOIN games g ON g.game_slug = s.game_slug
ON CONFLICT (purchase_code) DO UPDATE
    SET user_id = EXCLUDED.user_id, game_id = EXCLUDED.game_id, purchase_date = EXCLUDED.purchase_date,
        paid_amount = EXCLUDED.paid_amount, discount_percent = EXCLUDED.discount_percent,
        payment_method = EXCLUDED.payment_method
WHERE (purchases.user_id, purchases.game_id, purchases.purchase_date, purchases.paid_amount,
       purchases.discount_percent, purchases.payment_method)
      IS DISTINCT FROM (EXCLUDED.user_id, EXCLUDED.game_id, EXCLUDED.purchase_date, EXCLUDED.paid_amount,
                        EXCLUDED.discount_percent, EXCLUDED.payment_method);

-- ---------- user_activity.csv  (event_type: wishlist | review | achievement)
CREATE TEMP TABLE stg_activity (event_type text, username text, game_slug text, event_date date, rating int,
    comment text, achievement_name text, points int) ON COMMIT DROP;
\copy stg_activity FROM '../csv/user_activity.csv' CSV HEADER

INSERT INTO reviews (user_id, game_id, review_date, rating, comment)
SELECT u.user_id, g.game_id, s.event_date, s.rating, s.comment
FROM stg_activity s JOIN users u ON u.username = s.username JOIN games g ON g.game_slug = s.game_slug
WHERE s.event_type = 'review'
ON CONFLICT (user_id, game_id) DO UPDATE
    SET review_date = EXCLUDED.review_date, rating = EXCLUDED.rating, comment = EXCLUDED.comment
WHERE (reviews.review_date, reviews.rating, reviews.comment)
      IS DISTINCT FROM (EXCLUDED.review_date, EXCLUDED.rating, EXCLUDED.comment);

INSERT INTO achievements (game_id, achievement_name, points)
SELECT DISTINCT ON (g.game_id, s.achievement_name) g.game_id, s.achievement_name, s.points
FROM stg_activity s JOIN games g ON g.game_slug = s.game_slug
WHERE s.event_type = 'achievement'
ORDER BY g.game_id, s.achievement_name
ON CONFLICT (game_id, achievement_name) DO UPDATE SET points = EXCLUDED.points
WHERE achievements.points IS DISTINCT FROM EXCLUDED.points;

INSERT INTO user_achievements (user_id, achievement_id, earned_date)
SELECT u.user_id, a.achievement_id, s.event_date
FROM stg_activity s
JOIN users u ON u.username = s.username
JOIN games g ON g.game_slug = s.game_slug
JOIN achievements a ON a.game_id = g.game_id AND a.achievement_name = s.achievement_name
WHERE s.event_type = 'achievement'
ON CONFLICT (user_id, achievement_id) DO UPDATE SET earned_date = EXCLUDED.earned_date
WHERE user_achievements.earned_date IS DISTINCT FROM EXCLUDED.earned_date;

INSERT INTO wishlist (user_id, game_id, added_date)
SELECT u.user_id, g.game_id, s.event_date
FROM stg_activity s JOIN users u ON u.username = s.username JOIN games g ON g.game_slug = s.game_slug
WHERE s.event_type = 'wishlist'
ON CONFLICT (user_id, game_id) DO UPDATE SET added_date = EXCLUDED.added_date
WHERE wishlist.added_date IS DISTINCT FROM EXCLUDED.added_date;

-- ---------- CSV rows that could not be resolved to a user, game or country (expected: 0 rows)
SELECT 'users: unknown country' AS issue, count(*) AS rows
FROM stg_users s WHERE NOT EXISTS (SELECT 1 FROM countries c WHERE c.country_code = s.country_code)
UNION ALL
SELECT 'purchases: unknown user or game', count(*)
FROM stg_purchases s WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.username = s.username)
                        OR NOT EXISTS (SELECT 1 FROM games g WHERE g.game_slug = s.game_slug)
UNION ALL
SELECT 'activity: unknown user or game', count(*)
FROM stg_activity s WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.username = s.username)
                       OR NOT EXISTS (SELECT 1 FROM games g WHERE g.game_slug = s.game_slug);

COMMIT;
