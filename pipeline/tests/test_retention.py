from datetime import datetime, timedelta

from process import cleanup_transcripts, frontmatter

NOW = datetime(2026, 10, 10, 12, 0).astimezone()


def write(dir, name, fm):
    p = dir / f"{name}.transcript.md"
    p.write_text("---\n" + "".join(f"{k}: {v}\n" for k, v in fm.items()) + "---\n\nbody\n")
    return p


def test_cleanup(tmp_path):
    past = (NOW - timedelta(hours=1)).isoformat(timespec="seconds")
    future = (NOW + timedelta(hours=1)).isoformat(timespec="seconds")
    expired = write(tmp_path, "expired", {"status": "raw", "retain_until": past})
    kept = write(tmp_path, "kept", {"retain": "keep", "retain_until": past})
    fresh = write(tmp_path, "fresh", {"retain_until": future})
    no_date = write(tmp_path, "no-date", {"status": "processed"})
    naive = write(tmp_path, "naive", {"retain_until": "2026-10-09T08:00"})  # Obsidian may drop the offset
    other = tmp_path / "note.md"
    other.write_text(f"---\nretain_until: {past}\n---\n")

    cleanup_transcripts(tmp_path, NOW)
    assert not expired.exists() and not naive.exists()
    assert kept.exists() and fresh.exists() and no_date.exists() and other.exists()


def test_frontmatter_quoted_values():
    fm = frontmatter('---\ntitle: "a: b"\nstart: 2026-10-05T12:35:00-07:00\n---\nx: y\n')
    assert fm == {"title": "a: b", "start": "2026-10-05T12:35:00-07:00"}
