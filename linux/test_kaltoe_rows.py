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
    ({"label": "Mon", "worked": 30900, "overtime": 2100, "isDayOff": False, "isOngoing": False},
     "Mon   8:35   +0:35"),
    ({"label": "Wed", "worked": 27600, "overtime": 0, "isDayOff": False, "isOngoing": False},
     "Wed   7:40"),
    ({"label": "Thu", "worked": None, "overtime": 0, "isDayOff": True, "isOngoing": False},
     "Thu   off"),
    ({"label": "Fri", "worked": 16140, "overtime": 0, "isDayOff": False, "isOngoing": True},
     "Fri   4:29   · on the clock"),
    # No record at all: the label alone, never "0:00" — the distinction the wire's
    # absent `worked` exists to carry.
    ({"label": "Tue", "worked": None, "overtime": 0, "isDayOff": False, "isOngoing": False},
     "Tue"),
    # The marker rides `isOngoing`, i.e. "still clocked in", not "is today": a day
    # worked and closed carries no marker (case 1 above), and overtime still shows
    # alongside it while the clock runs.
    ({"label": "Mon", "worked": 32400, "overtime": 3600, "isDayOff": False, "isOngoing": True},
     "Mon   9:00   +1:00   · on the clock"),
]


def main():
    for day, expected in CASES:
        got = day_label(day)
        assert got == expected, f"{got!r} != {expected!r}"
    assert hm(-5) == "0:00" and hm(43200) == "12:00"
    print(f"{len(CASES) + 1} cases pass")


if __name__ == "__main__":
    main()
