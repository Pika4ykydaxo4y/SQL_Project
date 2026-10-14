-- OLAP (DWH) in its own database. Snowflake schema: 2 facts, 1 SCD Type 2, 1 bridge.
-- Safe to run repeatedly (IF NOT EXISTS).
\connect steam_dwh_db
CREATE SCHEMA IF NOT EXISTS steam_dwh;
CREATE SCHEMA IF NOT EXISTS steam_stg;     -- staging area used by the ETL
SET search_path TO steam_dwh;

CREATE TABLE IF NOT EXISTS dim_date (
    date_key    INT PRIMARY KEY,                -- YYYYMMDD
    full_date   DATE UNIQUE NOT NULL,
    day         INT NOT NULL,
    month       INT NOT NULL,
    month_name  VARCHAR(20) NOT NULL,
    year_month  CHAR(7) NOT NULL,               -- YYYY-MM, sortable label for charts
    quarter     INT NOT NULL,
    year        INT NOT NULL,
    day_of_week INT NOT NULL,                   -- 1 = Monday
    is_weekend  BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_country (
    country_key  SERIAL PRIMARY KEY,
    country_code CHAR(2) UNIQUE NOT NULL,
    country_name VARCHAR(100) NOT NULL,
    region       VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_user (
    user_key          SERIAL PRIMARY KEY,
    username          VARCHAR(50) UNIQUE NOT NULL,
    country_key       INT REFERENCES dim_country(country_key),
    registration_date DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_publisher (
    publisher_key  SERIAL PRIMARY KEY,
    publisher_name VARCHAR(120) UNIQUE NOT NULL,
    country_key    INT REFERENCES dim_country(country_key)
);

CREATE TABLE IF NOT EXISTS dim_developer (
    developer_key  SERIAL PRIMARY KEY,
    developer_name VARCHAR(120) UNIQUE NOT NULL,
    country_key    INT REFERENCES dim_country(country_key)
);

CREATE TABLE IF NOT EXISTS dim_game (
    game_key      SERIAL PRIMARY KEY,
    game_slug     VARCHAR(120) UNIQUE NOT NULL,
    title         VARCHAR(160) NOT NULL,
    release_year  INT NOT NULL,
    age_rating    VARCHAR(10) NOT NULL,
    developer_key INT REFERENCES dim_developer(developer_key),
    publisher_key INT REFERENCES dim_publisher(publisher_key)
);

CREATE TABLE IF NOT EXISTS dim_genre (
    genre_key  SERIAL PRIMARY KEY,
    genre_name VARCHAR(80) UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_payment_method (
    payment_method_key SERIAL PRIMARY KEY,
    payment_method     VARCHAR(30) UNIQUE NOT NULL
);

-- Bridge: a game has several genres, weight = 1 / number of genres, so allocated revenue adds up to the total.
CREATE TABLE IF NOT EXISTS bridge_game_genre (
    game_key  INT NOT NULL REFERENCES dim_game(game_key),
    genre_key INT NOT NULL REFERENCES dim_genre(genre_key),
    weight    NUMERIC(10,9) NOT NULL CHECK (weight > 0 AND weight <= 1),
    PRIMARY KEY (game_key, genre_key)
);

-- SCD Type 2: one row per price version of a game.
-- A price change closes the current row (valid_to, is_current = FALSE) and adds a new current row.
CREATE TABLE IF NOT EXISTS dim_game_price_scd (
    game_price_key SERIAL PRIMARY KEY,
    game_key       INT NOT NULL REFERENCES dim_game(game_key),
    price          NUMERIC(10,2) NOT NULL,
    currency       CHAR(3) NOT NULL,
    valid_from     DATE NOT NULL,
    valid_to       DATE,
    is_current     BOOLEAN NOT NULL,
    UNIQUE (game_key, valid_from),
    CHECK (is_current = (valid_to IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_scd_one_current ON dim_game_price_scd (game_key) WHERE is_current;

-- Fact 1: one row per purchase. gross_revenue is the list price of the SCD version valid on the purchase date.
CREATE TABLE IF NOT EXISTS fact_sales (
    sales_key          SERIAL PRIMARY KEY,
    purchase_code      VARCHAR(30) UNIQUE NOT NULL,    -- degenerate dimension
    date_key           INT NOT NULL REFERENCES dim_date(date_key),
    user_key           INT NOT NULL REFERENCES dim_user(user_key),
    game_key           INT NOT NULL REFERENCES dim_game(game_key),
    payment_method_key INT NOT NULL REFERENCES dim_payment_method(payment_method_key),
    game_price_key     INT NOT NULL REFERENCES dim_game_price_scd(game_price_key),
    units_sold         INT NOT NULL DEFAULT 1,
    gross_revenue      NUMERIC(12,2) NOT NULL,
    discount_amount    NUMERIC(12,2) NOT NULL,
    net_revenue        NUMERIC(12,2) NOT NULL
);

-- Fact 2: aggregated. Reviews, achievements and wishlist adds are summed per day, user and game.
CREATE TABLE IF NOT EXISTS fact_user_activity (
    activity_key       SERIAL PRIMARY KEY,
    date_key           INT NOT NULL REFERENCES dim_date(date_key),
    user_key           INT NOT NULL REFERENCES dim_user(user_key),
    game_key           INT NOT NULL REFERENCES dim_game(game_key),
    reviews_count      INT NOT NULL DEFAULT 0,
    achievements_count INT NOT NULL DEFAULT 0,
    achievement_points INT NOT NULL DEFAULT 0,
    wishlist_adds      INT NOT NULL DEFAULT 0,
    avg_rating         NUMERIC(4,2),
    UNIQUE (date_key, user_key, game_key)
);

-- Rows the ETL refused to load, with the reason. One line per record and reason.
CREATE TABLE IF NOT EXISTS etl_rejects (
    entity       VARCHAR(30)  NOT NULL,
    business_key VARCHAR(200) NOT NULL,
    reason       VARCHAR(200) NOT NULL,
    first_seen   TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (entity, business_key, reason)
);

-- Staging tables (truncated and refilled on every ETL run)
CREATE TABLE IF NOT EXISTS steam_stg.stg_sales (
    purchase_code text PRIMARY KEY, purchase_date date, registration_date date, paid_amount numeric,
    discount_percent int, date_key int, user_key int, game_key int, payment_method_key int,
    game_price_key int, list_price numeric, reject_reason text
);
CREATE TABLE IF NOT EXISTS steam_stg.stg_activity (
    business_key text PRIMARY KEY, event_type text, event_date date, rating int, points int,
    date_key int, user_key int, game_key int, reject_reason text
);
