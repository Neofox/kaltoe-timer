#!/usr/bin/env python3
"""Cases for kaltoe_rows.day_label. Run it: `python3 linux/test_kaltoe_rows.py`.

No pytest, no runner, no CI — day_label is a pure function with no imports, and
the point is that these cases exist somewhere a future editor will trip over.
The one they protect is `worked is None`: tidied into `worked or 0` it would
render a day never worked exactly like a day worked zero minutes, and the wire
omits `worked` rather than sending 0 precisely to keep those apart.

install.sh copies files by name, so this is not shipped to users.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kaltoe_rows import day_label, hm

CASES = [
    ({"label": "월", "worked": 30900, "overtime": 2100, "isDayOff": False, "isOngoing": False},
     "월   8:35   +0:35"),
    ({"label": "수", "worked": 27600, "overtime": 0, "isDayOff": False, "isOngoing": False},
     "수   7:40"),
    ({"label": "목", "worked": None, "overtime": 0, "isDayOff": True, "isOngoing": False},
     "목   휴무"),
    ({"label": "금", "worked": 16140, "overtime": 0, "isDayOff": False, "isOngoing": True},
     "금   4:29   · 근무 중"),
    # No record at all: the label alone, never "0:00" — the distinction the wire's
    # absent `worked` exists to carry.
    ({"label": "화", "worked": None, "overtime": 0, "isDayOff": False, "isOngoing": False},
     "화"),
    # The marker rides `isOngoing`, i.e. "still clocked in", not "is today": a day
    # worked and closed carries no marker (case 1 above), and overtime still shows
    # alongside it while the clock runs.
    ({"label": "월", "worked": 32400, "overtime": 3600, "isDayOff": False, "isOngoing": True},
     "월   9:00   +1:00   · 근무 중"),
]


def main():
    for day, expected in CASES:
        got = day_label(day)
        assert got == expected, f"{got!r} != {expected!r}"
    assert hm(-5) == "0:00" and hm(43200) == "12:00"
    print(f"{len(CASES) + 1} cases pass")


if __name__ == "__main__":
    main()
