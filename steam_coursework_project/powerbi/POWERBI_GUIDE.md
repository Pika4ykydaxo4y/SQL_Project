# Power BI report: build guide

The shipped `Steam_OLAP_Dashboard.pbix` has an empty page and points to the old model. Build the report in a new file or repoint the old one as described below.

## 1. Connect and transform

1. Home > Get data > PostgreSQL database. Server `localhost`, database `steam_dwh_db`. Choose Import.
2. Select from schema `steam_dwh`: `fact_sales`, `fact_user_activity`, `dim_date`, `dim_user`, `dim_game`, `dim_genre`, `bridge_game_genre`, `dim_game_price_scd`, `dim_country`, `dim_payment_method`. Skip `etl_rejects`.
3. Transform data (Power Query). These steps cover the "few transformations" requirement:
   - `fact_sales`: change `gross_revenue`, `discount_amount`, `net_revenue` to Fixed decimal number; `units_sold` to Whole number.
   - `dim_game`: change `age_rating` to Uppercase (Transform > Format > UPPERCASE).
   - `dim_date`: Keep rows where `year` is 2025 or 2026. Change `full_date` to Date.
   - `dim_game_price_scd`: change `valid_from` and `valid_to` to Date.
4. Close and apply.
5. Data view > `dim_date[month_name]` > Column tools > Sort by column > `month`.

## 2. Relationships (Model view)

Active, many-to-one, single direction from the dimension to the fact:

| From (many) | To (one) |
|---|---|
| fact_sales[date_key], fact_user_activity[date_key] | dim_date[date_key] |
| fact_sales[user_key], fact_user_activity[user_key] | dim_user[user_key] |
| fact_sales[game_key], fact_user_activity[game_key] | dim_game[game_key] |
| fact_sales[payment_method_key] | dim_payment_method[payment_method_key] |
| fact_sales[game_price_key] | dim_game_price_scd[game_price_key] |
| dim_user[country_key] | dim_country[country_key] |
| bridge_game_genre[game_key] | dim_game[game_key] |
| bridge_game_genre[genre_key] | dim_genre[genre_key] |

Set these as **inactive** to avoid ambiguous paths: `dim_game_price_scd[game_key]` to `dim_game[game_key]`, and the country relationships of `dim_developer` and `dim_publisher` if you import them.

## 3. Measures

```DAX
Net Revenue = SUM ( fact_sales[net_revenue] )
Gross Revenue = SUM ( fact_sales[gross_revenue] )
Units Sold = SUM ( fact_sales[units_sold] )
Discount Share = DIVIDE ( SUM ( fact_sales[discount_amount] ), [Gross Revenue] )

Avg Rating =
DIVIDE (
    SUMX ( fact_user_activity, fact_user_activity[avg_rating] * fact_user_activity[reviews_count] ),
    SUM ( fact_user_activity[reviews_count] )
)

Current Price =
CALCULATE (
    MAX ( dim_game_price_scd[price] ),
    dim_game_price_scd[is_current] = TRUE (),
    USERELATIONSHIP ( dim_game_price_scd[game_key], dim_game[game_key] )
)

Allocated Revenue by Genre =
SUMX (
    VALUES ( dim_game[game_key] ),
    CALCULATE ( [Net Revenue] ) * CALCULATE ( SUM ( bridge_game_genre[weight] ) )
)
```

`Allocated Revenue by Genre` multiplies each game's revenue by its weight under the selected genre. A game outside the genre has weight 0.

## 4. Page layout

| Element | Type | Fields |
|---|---|---|
| Title | Text box | Steam-like Platform Sales Dashboard |
| KPI cards (3) | Card | Net Revenue, Units Sold, Avg Rating |
| Slicer 1 | Slicer (dropdown) | dim_date[year], dim_date[month_name] |
| Slicer 2 | Slicer (list) | dim_country[country_name] |
| Line chart | Line chart | X: dim_date[year_month], Y: Net Revenue |
| Bar chart | Clustered bar | Y: dim_game[title], X: Net Revenue, sorted descending |
| Donut chart | Donut | Legend: dim_genre[genre_name], Values: Allocated Revenue by Genre |
| Table | Table | dim_game[title], Current Price, Units Sold, Net Revenue |

Optional: a filled map with `dim_country[country_name]` and `Net Revenue`.

## 5. Check the numbers

With no slicer selected, the card Net Revenue shows 2,953.24. The donut chart adds up to the same value. After running `07_demo_scd2.sql`, the table shows Hades with current price 19.99.

Save the file as `powerbi/Steam_OLAP_Dashboard.pbix`.
