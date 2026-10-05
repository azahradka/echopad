import glossary
from conftest import FIXTURES


def test_load_fixture():
    rows = glossary.load(FIXTURES / "glossary.md")
    assert [r["term"] for r in rows][:3] == ["Aron", "Devin", "Curt"]
    assert len(rows) == 10
    land = next(r for r in rows if r["term"] == "LandMARC")
    assert land["aliases"] == ["Land Mark", "landmark"] and land["asr"] and land["notes"] == "Cambio product"


def test_context_only_asr_yes_in_file_order():
    ctx = glossary.context(glossary.load(FIXTURES / "glossary.md"))
    assert ctx == glossary.PREAMBLE + "Aron, Devin, Curt, LandMARC, Watermarc, Enbridge, ILI, IMU, girth weld."
    assert "KP" not in ctx


def test_context_capped_at_80_terms(tmp_path):
    p = tmp_path / "g.md"
    p.write_text("| term | aliases (misheard as) | asr (yes/no) | notes |\n|---|---|---|---|\n"
                 + "".join(f"| T{i} | | yes | |\n" for i in range(100)))
    ctx = glossary.context(glossary.load(p))
    assert "T79." in ctx and "T80" not in ctx


def test_no_asr_terms_means_no_context(tmp_path):
    p = tmp_path / "g.md"
    p.write_text("| term | aliases (misheard as) | asr (yes/no) | notes |\n|---|---|---|---|\n| KP | | no | |\n")
    assert glossary.context(glossary.load(p)) is None


def test_replacements_table():
    table = glossary.replacements(glossary.load(FIXTURES / "glossary.md"))
    assert table["Land Mark"] == "LandMARC" and table["Kurt"] == "Curt" and table["I.L.I."] == "ILI"
    assert "" not in table
