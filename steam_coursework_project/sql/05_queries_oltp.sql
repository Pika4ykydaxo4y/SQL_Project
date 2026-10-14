-- Insight queries on the OLTP database (normalized tables, joins on every question).
\connect steam_oltp_db
SET search_path TO steam_oltp;

-- 1. Which games bring the highest revenue?
SELECT g.title, COUNT(*) AS purchases, SUM(p.paid_amount) AS revenue
FROM purchases p JOIN games g ON g.game_id = p.game_id
GROUP BY g.title
ORDER BY revenue DESC;

-- 2. Average review rating per game (games without reviews stay in the list)
SELECT g.title, ROUND(AVG(r.rating), 2) AS avg_rating, COUNT(r.review_id) AS review_count
FROM games g LEFT JOIN reviews r ON r.game_id = g.game_id
GROUP BY g.title
ORDER BY avg_rating DESC NULLS LAST;

-- 3. Purchases and revenue by country and month
SELECT c.country_name, DATE_TRUNC('month', p.purchase_date)::date AS month,
       COUNT(*) AS purchases, SUM(p.paid_amount) AS revenue
FROM purchases p
JOIN users u ON u.user_id = p.user_id
JOIN countries c ON c.country_id = u.country_id
GROUP BY c.country_name, month
ORDER BY month, revenue DESC;

-- 4. Revenue by genre; a game's revenue is split equally between its genres
SELECT ge.genre_name,
       ROUND(SUM(p.paid_amount / gc.genres_in_game), 2) AS allocated_revenue
FROM purchases p
JOIN game_genres gg ON gg.game_id = p.game_id
JOIN genres ge ON ge.genre_id = gg.genre_id
JOIN (SELECT game_id, COUNT(*) AS genres_in_game FROM game_genres GROUP BY game_id) gc ON gc.game_id = p.game_id
GROUP BY ge.genre_name
ORDER BY allocated_revenue DESC;

-- 5. Wishlist demand versus sales: how many wishlisted games were bought later by the same user
SELECT g.title,
       COUNT(*) AS wishlist_adds,
       COUNT(p.purchase_id) AS bought_by_wishlister
FROM wishlist w
JOIN games g ON g.game_id = w.game_id
LEFT JOIN purchases p ON p.user_id = w.user_id AND p.game_id = w.game_id
GROUP BY g.title
ORDER BY wishlist_adds DESC;
