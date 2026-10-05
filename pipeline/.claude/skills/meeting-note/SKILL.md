---
name: meeting-note
description: Turn a Notetaker transcript into a draft Log Book meeting note in the Obsidian vault. Invoked headless by the pipeline as /meeting-note <absolute transcript path>.
---

# /meeting-note

Transcript: `$ARGUMENTS`

Runs headless; nobody answers questions. Tools: Read, Write/Edit (only under `Log Book/` and `_attachments/transcripts/`), the Outlook calendar search, `mcp__notes-search__search_notes`, `mcp__notes-search__get_note`. No Glob, Grep or Bash: test whether a file exists by reading it. Never ask; when unsure, decide, flag it in the note and carry on.

`<vault>` is the transcript's folder two levels up (`<vault>/_attachments/transcripts/<file>`).

## 1. Read inputs
- Read the transcript. Frontmatter: `start` (ISO with offset), `mode` (`call` | `in-person`), `title`, `app`, `duration_s`, `retain_until` or `retain` (`keep` | `none`), `status`, `glossary`. Body: `[hh:mm:ss] **Speaker:** text` under `## Transcript`. In calls, the mic speaker is Aron and remote speakers are `Remote S1..SN`; in person, all speakers are `S1..SN`.
- If `status` is not `raw`, stop and say why.
- Read the glossary at `glossary` from the frontmatter, else `<vault>/Admin/Meeting Glossary.md`. Table: `term | aliases (misheard as) | asr | notes`. If it is missing, continue without corrections and add `> [!warning] Glossary not found; no jargon corrections made.` under `## Notes`.

## 2. Calendar (one call)
- Call `mcp__claude_ai_Microsoft_365__outlook_calendar_search` once: `query: "*"`, `afterDateTime` = start − 1 h, `beforeDateTime` = start + 1 h, both local time with offset, `limit: 25`.
- Pick the event whose time span contains `start` (or the closest one starting within 10 min after it). Subject → title. Attendees → speaker-name candidates. Always add "Aron" too: as the organiser he may be missing from the list.
- If the tool errors, is unavailable, or nothing overlaps: use the transcript `title` unless it is generic (e.g. "Microsoft Teams call"), else infer a short title from the content. Add `> [!warning] No calendar match; title and attendees inferred.` under `## Notes`.

## 3. Vault context (always; 2–6 note reads)
- Run 1–3 separate `search_notes` calls: the title, the main project or client named, and attendee names (`mode: "keyword"` for exact names; `path_prefix` such as `Projects/` or `Log Book/2026/Check-ins/` to narrow). Paths are relative to `<vault>`.
- Then `get_note` at least 2 and at most 6 notes, best first: the project overview(s) under `Projects/`, attendees' Check-in notes under `Log Book/2026/Check-ins/`, and the one or two latest Log Book notes with the same title or attendees.
- Use them for speaker names, jargon and to keep the summary and action items consistent with earlier decisions. Notes with `owner: claude` or an empty `reviewed:` are unverified background.
- If the `notes-search` tools are unavailable, skip this step and add a `> [!warning]` saying so.
- Never copy earlier notes' content into this note as if it was said in this meeting. If you mention prior context, label it "(from earlier note)" and link it.

## 4. Correct jargon
- Use the glossary terms, their *misheard as* aliases, and vault context.
- Change a word only when the change is phonetically plausible and fits the context. Common words that sound like a glossary term count (e.g. "and bridge" → Enbridge when the glossary lists Enbridge).
- Never change numbers, dates, KP or chainage values silently. If unsure of one in the note, write it with `(?)`, e.g. `KP 12.4(?)`.
- Apply corrections in the note. Do not rewrite the transcript body; log every change in step 7.

## 5. Name speakers
- Map `Remote S1..SN` / `S1..SN` to names using the attendee list, self-introductions, and people addressed by name (a name a speaker says belongs to someone else, often the next speaker).
- Confidence per mapping: high (self-introduction or repeated direct address) → plain name; medium/low → `Speaker 2 (likely Devin)`; none → `Speaker 2`.
- In-person: decide which `S` is Aron (addressed as Aron or AZ, organiser's role, refers to Aron's own work). If unclear, say so in `## Notes`.

## 6. Write the note
- Date = local date of `start`. Path: `<vault>/Log Book/<YYYY>/<MM Month>/<YYYY-MM-DD> <Title>.md`, month folder like `10 October`.
- Title: Title Case, short. Replace `/ \ : * ? " < > |` with `-`.
- Read the path first. If it exists, try ` (2)`, ` (3)`, … Never overwrite.
- Create it with Write, exactly this shape:

```markdown
---
tags: [meeting]
type: meeting
date: <YYYY-MM-DD>
updated: <today, YYYY-MM-DD>
owner: claude
reviewed:
attendees: [Aron, <people identified as present, by name; no "Speaker N">]
source: <call | in-person, from mode>
status: draft
transcript: "[[_attachments/transcripts/<transcript file name without .md>|transcript]]"
---
# <Title>

## Aron's notes
> [!note] Aron-owned section
> Claude must not edit anything under this heading, up to the next `##` heading.

-

**Summary:** <2–3 sentences>
**Decisions:**
- <decision, or "None recorded">
**Action items:**
- [ ] <Aron's own items> #todo
- <Name>: <other people's items, plain bullets>

## Notes
- <topic>
	- <terse nested bullets, tab-indented>

## Glossary suggestions
- <new term or misheard alias → term, with the timestamp it came from; or "None">
```

- Omit the `transcript:` line when `retain: none`.
- `## Notes` style: terse fragments, no full sentences needed, one top-level bullet per topic, details nested with tabs; names as people say them (Matt T., Curt); "AZ to …" is fine for Aron. Keep only what was said in this meeting. Spell it "LandMARC".
- Flags (calendar, glossary, unsure speakers or numbers) go as `> [!warning]` callouts at the top of `## Notes`, one per flag, separated by blank lines.
- Glossary suggestions: every correction not already covered by an alias (suggest the heard form as an alias), and new names, clients or acronyms not in the glossary. Suggestions only; never edit the glossary.

## 7. Update the transcript
- If `retain: none`: Edit the frontmatter `status: raw` → `status: delete` (the pipeline deletes the file). Skip the rest.
- Otherwise:
	- Append the corrections. Use Edit with the transcript's last line as `old_string`, and that line plus this as `new_string`:
	  `\n\n## Corrections\n- [hh:mm:ss] "<heard>" → "<corrected>" (<reason>)` (one bullet per change, or `- None`).
	- Edit the frontmatter `status: raw` → `status: processed`.

## 8. Finish
Reply with only the note's absolute path.
