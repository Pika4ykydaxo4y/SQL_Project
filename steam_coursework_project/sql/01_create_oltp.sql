-- OLTP schema, 3NF, 13 tables. Safe to run repeatedly (IF NOT EXISTS), existing data stays.
\connect steam_oltp_db
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- needed for the price interval exclusion constraint
CREATE SCHEMA IF NOT EXISTS steam_oltp;
SET search_path TO steam_oltp;

CREATE TABLE IF NOT EXISTS countries (
    country_id   SERIAL PRIMARY KEY,
    country_code CHAR(2) UNIQUE NOT NULL,
    country_name VARCHAR(100) NOT NULL,
    region       VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    user_id           SERIAL PRIMARY KEY,
    username          VARCHAR(50)  UNIQUE NOT NULL,
    email             VARCHAR(120) UNIQUE NOT NULL,
    country_id        INT NOT NULL REFERENCES countries(country_id),
    registration_date DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS developers (
    developer_id   SERIAL PRIMARY KEY,
    developer_name VARCHAR(120) UNIQUE NOT NULL,
    country_id     INT REFERENCES countries(country_id)
);

CREATE TABLE IF NOT EXISTS publishers (
    publisher_id   SERIAL PRIMARY KEY,
    publisher_name VARCHAR(120) UNIQUE NOT NULL,
    country_id     INT REFERENCES countries(country_id)
);

-- base_price is the launch list price. The price that applied on a given day lives in price_history.
CREATE TABLE IF NOT EXISTS games (
    game_id      SERIAL PRIMARY KEY,
    game_slug    VARCHAR(120) UNIQUE NOT NULL,
    title        VARCHAR(160) NOT NULL,
    developer_id INT NOT NULL REFERENCES developers(developer_id),
    publisher_id INT NOT NULL REFERENCES publishers(publisher_id),
    release_date DATE NOT NULL,
    base_price   NUMERIC(10,2) NOT NULL CHECK (base_price >= 0),
    age_rating   VARCHAR(10) NOT NULL
);

CREATE TABLE IF NOT EXISTS genres (
    genre_id   SERIAL PRIMARY KEY,
    genre_name VARCHAR(80) UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS game_genres (
    game_id  INT NOT NULL REFERENCES games(game_id),
    genre_id INT NOT NULL REFERENCES genres(genre_id),
    PRIMARY KEY (game_id, genre_id)
);

-- One purchase per user and game. paid_amount = list price on purchase_date * (1 - discount_percent / 100).
CREATE TABLE IF NOT EXISTS purchases (
    purchase_id      SERIAL PRIMARY KEY,
    purchase_code    VARCHAR(30) UNIQUE NOT NULL,
    user_id          INT NOT NULL REFERENCES users(user_id),
    game_id          INT NOT NULL REFERENCES games(game_id),
    purchase_date    DATE NOT NULL,
    paid_amount      NUMERIC(10,2) NOT NULL CHECK (paid_amount >= 0),
    discount_percent INT NOT NULL CHECK (discount_percent BETWEEN 0 AND 100),
    payment_method   VARCHAR(30) NOT NULL CHECK (payment_method IN ('card', 'wallet')),
    UNIQUE (user_id, game_id)
);

CREATE TABLE IF NOT EXISTS reviews (
    review_id   SERIAL PRIMARY KEY,
    user_id     INT NOT NULL REFERENCES users(user_id),
    game_id     INT NOT NULL REFERENCES games(game_id),
    review_date DATE NOT NULL,
    rating      INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment     TEXT,
    UNIQUE (user_id, game_id)
);

CREATE TABLE IF NOT EXISTS achievements (
    achievement_id   SERIAL PRIMARY KEY,
    game_id          INT NOT NULL REFERENCES games(game_id),
    achievement_name VARCHAR(120) NOT NULL,
    points           INT NOT NULL CHECK (points > 0),
    UNIQUE (game_id, achievement_name)
);

CREATE TABLE IF NOT EXISTS user_achievements (
    user_id        INT NOT NULL REFERENCES users(user_id),
    achievement_id INT NOT NULL REFERENCES achievements(achievement_id),
    earned_date    DATE NOT NULL,
    PRIMARY KEY (user_id, achievement_id)
);

CREATE TABLE IF NOT EXISTS wishlist (
    user_id    INT NOT NULL REFERENCES users(user_id),
    game_id    INT NOT NULL REFERENCES games(game_id),
    added_date DATE NOT NULL,
    PRIMARY KEY (user_id, game_id)
);

-- Price versions of a game. Intervals are inclusive, never overlap, and at most one row per game is open (valid_to IS NULL).
CREATE TABLE IF NOT EXISTS price_history (
    price_history_id SERIAL PRIMARY KEY,
    game_id          INT NOT NULL REFERENCES games(game_id),
    valid_from       DATE NOT NULL,
    valid_to         DATE,
    price            NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    currency         CHAR(3) NOT NULL DEFAULT 'EUR',
    UNIQUE (game_id, valid_from),
    CHECK (valid_to IS NULL OR valid_to >= valid_from),
    EXCLUDE USING gist (game_id WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_price_history_one_open ON price_history (game_id) WHERE valid_to IS NULL;

-- Application call for a price change: closes the open interval the day before and opens a new one.
CREATE OR REPLACE FUNCTION change_price(p_slug TEXT, p_new_price NUMERIC, p_effective DATE)
RETURNS VOID LANGUAGE plpgsql SET search_path = steam_oltp AS $$
DECLARE
    v_game INT;
    v_open price_history%ROWTYPE;
BEGIN
    SELECT game_id INTO v_game FROM games WHERE game_slug = p_slug;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown game %', p_slug;
    END IF;
    SELECT * INTO v_open FROM price_history WHERE game_id = v_game AND valid_to IS NULL FOR UPDATE;
    IF FOUND AND v_open.price = p_new_price THEN
        RETURN;                                   -- same price, nothing to do
    END IF;
    IF FOUND AND v_open.valid_from >= p_effective THEN
        RAISE EXCEPTION 'effective date must be after %', v_open.valid_from;
    END IF;
    IF FOUND THEN
        UPDATE price_history SET valid_to = p_effective - 1 WHERE price_history_id = v_open.price_history_id;
    END IF;
    INSERT INTO price_history (game_id, valid_from, valid_to, price, currency)
    VALUES (v_game, p_effective, NULL, p_new_price, 'EUR');
END $$;
