"""Draw the logical schemas (PNG) from the live databases. Needs psql and graphviz (dot).

Usage:  python tools/make_diagrams.py [psql connection args, e.g. -h localhost -p 5432 -U postgres]
Writes diagrams/oltp_schema.png and diagrams/olap_schema.png.
"""
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONN = sys.argv[1:]


def q(db, sql):
    out = subprocess.run(["psql", *CONN, "-d", db, "-At", "-F", "|", "-c", sql],
                         check=True, capture_output=True, text=True).stdout
    return [line.split("|") for line in out.splitlines() if line]


def load(db, schema, skip=()):
    cols = OrderedDict()
    for t, c, typ in q(db, f"""select table_name, column_name,
            case when data_type='character varying' then 'varchar' when data_type='character' then 'char'
                 when data_type='integer' then 'int' else data_type end
            from information_schema.columns where table_schema='{schema}' order by table_name, ordinal_position"""):
        if t not in skip:
            cols.setdefault(t, []).append((c, typ))
    pk = {(t, c) for t, c in q(db, f"""select tc.table_name, kcu.column_name from information_schema.table_constraints tc
            join information_schema.key_column_usage kcu on kcu.constraint_name=tc.constraint_name and kcu.table_schema=tc.table_schema
            where tc.constraint_type='PRIMARY KEY' and tc.table_schema='{schema}'""")}
    fk = q(db, f"""select tc.table_name, kcu.column_name, ccu.table_name from information_schema.table_constraints tc
            join information_schema.key_column_usage kcu on kcu.constraint_name=tc.constraint_name and kcu.table_schema=tc.table_schema
            join information_schema.constraint_column_usage ccu on ccu.constraint_name=tc.constraint_name and ccu.table_schema=tc.table_schema
            where tc.constraint_type='FOREIGN KEY' and tc.table_schema='{schema}'""")
    fkcols = {(t, c) for t, c, _ in fk}
    return cols, pk, fk, fkcols


def draw(name, title, cols, pk, fk, fkcols, color):
    lines = ['digraph G {', 'rankdir=LR; nodesep=0.35; ranksep=0.9; pad=0.3; bgcolor="white";',
             f'labelloc=t; fontsize=20; fontname="Helvetica-Bold"; label="{title}";',
             'node [shape=plaintext fontname="Helvetica" fontsize=11];', 'edge [color="#555555" arrowsize=0.7];']
    for t, cs in cols.items():
        rows = []
        for c, typ in cs:
            tag = "PK " if (t, c) in pk else ("FK " if (t, c) in fkcols else "")
            bold = ("<B>", "</B>") if tag else ("", "")
            rows.append(f'<TR><TD ALIGN="LEFT" PORT="{c}">{bold[0]}{tag}{c}{bold[1]}</TD>'
                        f'<TD ALIGN="LEFT"><FONT COLOR="#777777">{typ}</FONT></TD></TR>')
        lines.append(f'"{t}" [label=<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" '
                     f'BGCOLOR="white"><TR><TD COLSPAN="2" BGCOLOR="{color(t)}"><B>{t}</B></TD></TR>{"".join(rows)}</TABLE>>];')
    for t, c, ref in fk:
        if t in cols and ref in cols:
            lines.append(f'"{t}":"{c}" -> "{ref}";')
    lines.append("}")
    dot = ROOT / "diagrams" / f"{name}.dot"
    dot.write_text("\n".join(lines), encoding="utf-8")
    subprocess.run(["dot", "-Tpng", "-Gdpi=130", str(dot), "-o", str(ROOT / "diagrams" / f"{name}.png")], check=True)
    dot.unlink()


(ROOT / "diagrams").mkdir(exist_ok=True)
draw("oltp_schema", "OLTP schema steam_oltp (3NF)", *load("steam_oltp_db", "steam_oltp"), lambda t: "#cfe3f5")


def olap_color(t):
    if t.startswith("fact_"):
        return "#f4b6b6"
    if t == "dim_game_price_scd":
        return "#fbd9a0"
    if t.startswith("bridge_"):
        return "#bfe5bf"
    return "#cfe3f5"


draw("olap_schema", "OLAP schema steam_dwh (snowflake)", *load("steam_dwh_db", "steam_dwh", skip=("etl_rejects",)), olap_color)
print("diagrams written")
