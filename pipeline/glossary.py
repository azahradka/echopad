"""Meeting glossary: the context paragraph passed to Qwen3-ASR as its system prompt.

The glossary is an Obsidian note with a Markdown table (PLAN.md section 4):

    | term | aliases (misheard as) | asr (yes/no) | notes |
    |---|---|---|---|
    | LandMARC | Land Mark, landmark | yes | Cambio product |

Rows marked `asr: yes`, in file order (most important first), become the context.
Every alias becomes a post-ASR replacement alias -> term.

TERMS / CONTEXT below are the fixed 80-term spike glossary used by asr_probe.py and
bench_asr.py; the pipeline reads the real glossary with load().
"""

from pathlib import Path

MAX_TERMS = 80
PREAMBLE = "Meeting at Cambio. Vocabulary, names and spellings: "


def load(path: str | Path) -> list[dict]:
    """Rows of the first table whose first header cell is `term`."""
    rows, header = [], None
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line.startswith("|"):
            if header:
                break  # end of the glossary table
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if header is None:
            if cells[0].lower() == "term":
                header = cells
            continue
        if set(cells[0]) <= set("-: "):
            continue  # |---|---| separator
        term, aliases, asr = cells[0], cells[1], cells[2]
        rows.append({
            "term": term,
            "aliases": [a.strip() for a in aliases.split(",") if a.strip()],
            "asr": asr.lower() == "yes",
            "notes": cells[3] if len(cells) > 3 else "",
        })
    if header is None:
        raise ValueError(f"no `| term | aliases | asr | notes |` table in {path}")
    return rows


def context(rows: list[dict]) -> str | None:
    """The ASR context paragraph: the first MAX_TERMS `asr: yes` terms, or None if there are none."""
    terms = [r["term"] for r in rows if r["asr"]][:MAX_TERMS]
    return PREAMBLE + ", ".join(terms) + "." if terms else None


def replacements(rows: list[dict]) -> dict[str, str]:
    """Alias -> term, from every row."""
    return {a: r["term"] for r in rows for a in r["aliases"]}


TERMS = [
    # people
    "Aron", "Devin", "Curt", "Mackenzie", "Colin", "Matt T.", "Priya", "Siobhan", "Tarek", "Rhys",
    # organisations and products
    "Cambio", "Cambio Earth", "BGC", "BGC Engineering", "Enbridge", "Pembina", "TC Energy", "CER",
    "Rosen", "Baker Hughes", "LandMARC", "LandMARC-LCD", "Watermarc",
    # inspection
    "ILI", "in-line inspection", "IMU", "inertial measurement unit", "MFL", "magnetic flux leakage",
    "EMAT", "UT", "caliper", "r2r", "run-to-run", "odometer", "girth weld", "seam weld",
    "bending strain", "axial strain", "ovality", "dent", "wrinkle", "metal loss", "SCC",
    # location
    "chainage", "KP", "KP 123+450", "centreline", "as-built", "right-of-way", "ROW",
    # geohazards
    "geohazard", "slope creep", "translational slide", "watercourse crossing", "scour",
    "depth of cover", "DoC", "inclinometer", "piezometer", "strain gauge", "InSAR", "LiDAR",
    # integrity management
    "dig program", "excavation", "NDE", "cathodic protection", "CP", "fitness for service",
    "probability of failure", "MAOP", "SMYS", "CSA Z662", "API 1163", "pigging", "launcher",
    "receiver", "reroute", "backfill", "Gwen",
]

CONTEXT = (
    "Pipeline integrity project meeting at Cambio about LandMARC and Watermarc. "
    "Vocabulary, names and spellings: " + ", ".join(TERMS) + "."
)

if __name__ == "__main__":
    print(len(TERMS), "terms")
    print(CONTEXT)
