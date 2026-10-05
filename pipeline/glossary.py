"""Meeting glossary: the context paragraph passed to Qwen3-ASR as its system prompt.

The glossary is an Obsidian note with a Markdown table (PLAN.md section 4):

    | term | aliases (misheard as) | asr (yes/no) | notes |
    |---|---|---|---|
    | LandMARC | Land Mark, landmark | yes | Cambio product |

Rows marked `asr: yes`, in file order (most important first), become the context.
Every alias becomes a post-ASR replacement alias -> term.
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
