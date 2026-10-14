"""Generate the five CSV files for the Steam-like coursework project.

Run from the project root:  python tools/generate_data.py
users.csv is read as is (60 accounts). The other four files are rebuilt with a fixed seed,
so every run produces identical output.

Consistency rules enforced here:
  * one purchase and one review per (user, game)
  * purchase date >= user registration date and >= game release date
  * review and achievement dates >= purchase date
  * achievements only for owned games, wishlist only for games the user does not own
  * paid_amount = list price valid on the purchase date * (1 - discount_percent / 100)
  * price intervals of one game never overlap
"""
import csv
import random
from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSV = ROOT / "csv"
random.seed(42)

END = date(2026, 5, 31)          # last business date in the data set
SALE_FROM, SALE_TO = date(2025, 11, 20), date(2025, 11, 30)
REPRICE = date(2026, 3, 1)

# slug, title, developer, dev country, publisher, pub country, release, base price, age rating, genres
GAMES = [
    ("counter-strike-2", "Counter-Strike 2", "Valve", "US", "Valve", "US", "2023-09-27", "0", "M", "Action|Co-op"),
    ("baldurs-gate-3", "Baldur's Gate 3", "Larian Studios", "BE", "Larian Studios", "BE", "2023-08-03", "59.99", "M", "RPG|Adventure"),
    ("hades", "Hades", "Supergiant Games", "US", "Supergiant Games", "US", "2020-09-17", "24.99", "T", "Action|Indie"),
    ("stardew-valley", "Stardew Valley", "ConcernedApe", "US", "Chucklefish", "GB", "2016-02-26", "14.99", "E", "Simulation|Indie"),
    ("terraria", "Terraria", "Re-Logic", "US", "Re-Logic", "US", "2011-05-16", "9.99", "T", "Sandbox|Adventure|Survival"),
    ("rust", "Rust", "Facepunch Studios", "GB", "Facepunch Studios", "GB", "2018-02-08", "39.99", "M", "Survival|Sandbox"),
    ("phasmophobia", "Phasmophobia", "Kinetic Games", "GB", "Kinetic Games", "GB", "2020-09-18", "19.99", "T", "Horror|Co-op|Indie"),
    ("deep-rock-galactic", "Deep Rock Galactic", "Ghost Ship Games", "DK", "Coffee Stain Publishing", "SE", "2020-05-13", "29.99", "T", "Action|Co-op|Adventure"),
    ("no-mans-sky", "No Man's Sky", "Hello Games", "GB", "Hello Games", "GB", "2016-08-12", "59.99", "T", "Adventure|Sandbox|Survival"),
    ("the-witcher-3", "The Witcher 3", "CD Projekt Red", "PL", "CD Projekt", "PL", "2015-05-18", "39.99", "M", "RPG|Adventure"),
    ("portal-2", "Portal 2", "Valve", "US", "Valve", "US", "2011-04-18", "9.99", "E10", "Adventure|Co-op"),
    ("dota-2", "Dota 2", "Valve", "US", "Valve", "US", "2013-07-09", "0", "T", "Strategy|Co-op"),
]
ACHIEVEMENTS = [("First Steps", 10), ("Veteran", 40), ("Completionist", 100), ("Hidden Secret", 70)]
COMMENTS = ["Great game", "Good value", "Fun with friends", "Needs updates", "Not my type"]
DISCOUNTS = [0, 0, 0, 10, 20, 25, 50]
PAYMENTS = ["card", "card", "wallet"]


def money(x):
    return Decimal(x).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def d(s):
    return date.fromisoformat(s)


def rand_date(lo, hi):
    return lo + timedelta(days=random.randint(0, (hi - lo).days))


def write(name, header, rows):
    with open(CSV / name, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)


# ---- games.csv
write("games.csv",
      ["game_slug", "title", "developer_name", "developer_country", "publisher_name",
       "publisher_country", "release_date", "base_price", "age_rating", "genres"],
      GAMES)

# ---- price_history.csv: contiguous, non-overlapping intervals; one open row per game
price_rows, timeline = [], {}
for g in GAMES:
    slug, base = g[0], money(g[7])
    if base == 0:
        periods = [(date(2025, 1, 1), None, base)]
    else:
        periods = [
            (date(2025, 1, 1), SALE_FROM - timedelta(days=1), base),
            (SALE_FROM, SALE_TO, money(base * Decimal("0.75"))),
            (SALE_TO + timedelta(days=1), REPRICE - timedelta(days=1), base),
            (REPRICE, None, money(base * Decimal("0.90"))),
        ]
    timeline[slug] = periods
    for vf, vt, price in periods:
        price_rows.append([slug, vf.isoformat(), vt.isoformat() if vt else "", price, "EUR"])
write("price_history.csv", ["game_slug", "valid_from", "valid_to", "price", "currency"], price_rows)


def list_price(slug, on):
    for vf, vt, price in timeline[slug]:
        if vf <= on and (vt is None or on <= vt):
            return price
    raise ValueError((slug, on))


# ---- users (kept)
with open(CSV / "users.csv", newline="", encoding="utf-8") as f:
    users = [(r["username"], d(r["registration_date"])) for r in csv.DictReader(f)]

# ---- purchases.csv
release = {g[0]: d(g[6]) for g in GAMES}
slugs = [g[0] for g in GAMES]
purchases, owned = [], {}
for username, reg in users:
    for slug in random.sample(slugs, random.randint(1, 5)):
        lo = max(reg, release[slug], date(2025, 1, 1))
        if lo > END:
            continue
        in_window = lo <= SALE_TO and random.random() < 0.15
        when = rand_date(max(lo, SALE_FROM), SALE_TO) if in_window else rand_date(lo, END)
        price = list_price(slug, when)
        disc = 0 if price == 0 else random.choice(DISCOUNTS)
        paid = money(price * (Decimal(100 - disc) / 100))
        purchases.append([username, slug, when, paid, disc, random.choice(PAYMENTS)])
        owned.setdefault(username, {})[slug] = when
purchases.sort(key=lambda r: (r[2], r[0], r[1]))
write("purchases.csv",
      ["purchase_code", "username", "game_slug", "purchase_date", "paid_amount", "discount_percent", "payment_method"],
      [[f"P{i:05d}", u, s, w.isoformat(), p, dsc, pm] for i, (u, s, w, p, dsc, pm) in enumerate(purchases, 1)])

# ---- user_activity.csv: wishlist, review and achievement events in one file
header = ["event_type", "username", "game_slug", "event_date", "rating", "comment", "achievement_name", "points"]
events = []
reg_of = dict(users)
for username, games in owned.items():
    for slug, bought in games.items():
        if random.random() < 0.55:
            events.append(["review", username, slug, min(bought + timedelta(days=random.randint(0, 60)), END),
                           random.randint(1, 5), random.choice(COMMENTS), "", ""])
        for name, pts in random.sample(ACHIEVEMENTS, random.randint(0, 4)):
            events.append(["achievement", username, slug, min(bought + timedelta(days=random.randint(0, 90)), END),
                           "", "", name, pts])
for username, reg in users:
    pool = [s for s in slugs if s not in owned.get(username, {})]
    for slug in random.sample(pool, min(len(pool), random.randint(0, 4))):
        events.append(["wishlist", username, slug,
                       rand_date(max(reg, release[slug], date(2025, 1, 1)), END), "", "", "", ""])
events.sort(key=lambda r: (r[3], r[0], r[1], r[2]))
write("user_activity.csv", header, [[*e[:3], e[3].isoformat(), *e[4:]] for e in events])

print(f"games={len(GAMES)} price_history={len(price_rows)} purchases={len(purchases)} activity={len(events)}")
