-- Insight queries on the OLAP database (facts and dimensions, fewer joins, pre-computed measures).
\connect steam_dwh_db
SET search_path TO steam_dwh;

-- 1. Revenue by genre through the bridge weights (same question as OLTP query 4)
SELECT dg.genre_name, ROUND(SUM(fs.net_revenue * b.weight), 2) AS allocated_revenue
FROM fact_sales fs
JOIN bridge_game_genre b ON b.game_key = fs.game_key
JOIN dim_genre dg ON dg.genre_key = b.genre_key
GROUP BY dg.genre_name
ORDER BY allocated_revenue DESC;

-- 2. Revenue, units and discount by month
SELECT dd.year_month, SUM(fs.units_sold) AS units, SUM(fs.gross_revenue) AS gross_revenue,
       SUM(fs.discount_amount) AS discounts, SUM(fs.net_revenue) AS net_revenue
FROM fact_sales fs JOIN dim_date dd ON dd.date_key = fs.date_key
GROUP BY dd.year_month
ORDER BY dd.year_month;

-- 3. Sales by price version (SCD Type 2): what each game earned at each list price
SELECT g.title, sc.valid_from, sc.valid_to, sc.price AS list_price, sc.is_current,
       COUNT(fs.sales_key) AS units, COALESCE(SUM(fs.net_revenue), 0) AS net_revenue
FROM dim_game_price_scd sc
JOIN dim_game g ON g.game_key = sc.game_key
LEFT JOIN fact_sales fs ON fs.game_price_key = sc.game_price_key
WHERE sc.price > 0
GROUP BY g.title, sc.valid_from, sc.valid_to, sc.price, sc.is_current
ORDER BY g.title, sc.valid_from;

-- 4. Current price against historical sales per game
SELECT g.title, cur.price AS current_price, SUM(fs.units_sold) AS units_sold, SUM(fs.net_revenue) AS net_revenue
FROM fact_sales fs
JOIN dim_game g ON g.game_key = fs.game_key
JOIN dim_game_price_scd cur ON cur.game_key = g.game_key AND cur.is_current
GROUP BY g.title, cur.price
ORDER BY net_revenue DESC;

-- 5. Revenue by region and country
SELECT c.region, c.country_name, COUNT(*) AS purchases, SUM(fs.net_revenue) AS net_revenue
FROM fact_sales fs
JOIN dim_user u ON u.user_key = fs.user_key
JOIN dim_country c ON c.country_key = u.country_key
GROUP BY c.region, c.country_name
ORDER BY net_revenue DESC;

-- 6. Engagement per game from the aggregated activity fact
SELECT g.title, SUM(a.reviews_count) AS reviews, ROUND(AVG(a.avg_rating), 2) AS avg_rating,
       SUM(a.achievements_count) AS achievements, SUM(a.achievement_points) AS points, SUM(a.wishlist_adds) AS wishlist_adds
FROM fact_user_activity a JOIN dim_game g ON g.game_key = a.game_key
GROUP BY g.title
ORDER BY achievements DESC;
