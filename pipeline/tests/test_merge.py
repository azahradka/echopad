from merge import echopad_transcript, label_speakers, merge_turns, render, timestamp


def t(start, end, speaker, channel, text="x"):
    return {"start": start, "end": end, "speaker": speaker, "channel": channel, "text": text}


def test_same_speaker_turns_merge():
    out = merge_turns([t(0, 2, "Remote S1", "system", "a"), t(2.5, 4, "Remote S1", "system", "b")])
    assert out == [t(0, 4, "Remote S1", "system", "a b")]


def test_no_merge_across_channels_or_speakers():
    turns = [t(0, 2, "S1", "mic"), t(2, 3, "S1", "system"), t(3, 4, "Remote S2", "system"), t(4, 5, "Remote S1", "system")]
    assert len(merge_turns(turns)) == 4


def test_sorted_by_start_and_interleaved():
    turns = [t(10, 12, "Remote S1", "system", "second"), t(0, 5, "Remote S1", "system", "first"),
             t(4, 11, "Aron", "mic", "mine")]
    assert [x["text"] for x in merge_turns(turns)] == ["first", "mine", "second"]


def test_label_speakers_in_order_of_first_appearance():
    raw = [{"start": 5, "end": 6, "speaker": "SPEAKER_00"}, {"start": 1, "end": 2, "speaker": "SPEAKER_03"},
           {"start": 7, "end": 8, "speaker": "SPEAKER_03"}]
    out = label_speakers(raw, "Remote S", "system")
    assert [x["speaker"] for x in out] == ["Remote S1", "Remote S2", "Remote S1"]
    assert {x["channel"] for x in out} == {"system"}


def test_render():
    assert timestamp(3725.9) == "01:02:05"
    body = render([t(3725.9, 3730, "Aron", "mic", "hello"), t(1, 2, "Remote S1", "system", "hi")])
    assert body == "[00:00:01] **Remote S1:** hi\n\n[01:02:05] **Aron:** hello\n"


def test_echopad_transcript_call():
    turns = [t(5.0, 7.5, "Remote S2", "system", "two"), t(0.5, 2.0, "Remote S1", "system", "one"),
             t(2.2, 4.0, "Remote S1", "system", "more"), t(3.0, 4.5, "Aron", "mic", "mine")]
    out = echopad_transcript(turns, "Aron", 8.0)
    assert out["speakers"] == [{"id": "local", "name": "Aron", "isLocal": True},
                               {"id": "remote-s1", "name": "Remote S1", "isLocal": False},
                               {"id": "remote-s2", "name": "Remote S2", "isLocal": False}]
    assert out["segments"] == [  # same merged turns as the Markdown, words empty (turn timings only)
        {"speakerID": "remote-s1", "start": 0.5, "end": 4.0, "text": "one more", "words": []},
        {"speakerID": "local", "start": 3.0, "end": 4.5, "text": "mine", "words": []},
        {"speakerID": "remote-s2", "start": 5.0, "end": 7.5, "text": "two", "words": []},
    ]
    assert out["language"] == "en" and out["duration"] == 8.0


def test_echopad_transcript_in_person():
    out = echopad_transcript([t(0, 1, "S1", "mic", "a"), t(1, 2, "S2", "mic", "b")], "Aron", 2.0)
    assert [s["id"] for s in out["speakers"]] == ["s1", "s2"] and not any(s["isLocal"] for s in out["speakers"])
    assert [s["speakerID"] for s in out["segments"]] == ["s1", "s2"]
