"""Label formatting for the tray's week rows.

Split out of kaltoe-tray.py so it imports without GTK: that module raises
SystemExit at import time when the introspection data is missing, which makes
its formatting untestable anywhere but a configured Linux desktop.
"""


def hm(seconds):
    """'8:35' — whole minutes, negatives clamped. Mirrors Formatting.hm."""
    minutes = max(0, int(seconds)) // 60
    return f"{minutes // 60}:{minutes % 60:02d}"


def day_label(day):
    """One week row: 'Mon   8:35   +0:35', or 'Fri   4:29   · on the clock'.

    Overtime is spelled out here because, unlike the macOS popover, there is no
    bar to carry it — DBusMenu carries no custom widgets.

    The marker says "on the clock", not "today": `isOngoing` is
    `record.clockOut == nil`, so it marks the day still being worked, which is
    absent after clocking out and can land on an earlier weekday whose record was
    never closed. macOS can spell that as a colour; a word cannot lie about it.
    """
    worked = day.get("worked")
    if worked is None:
        return f"{day['label']}   off" if day.get("isDayOff") else day["label"]
    parts = [day["label"], hm(worked)]
    if day.get("overtime"):
        parts.append(f"+{hm(day['overtime'])}")
    if day.get("isOngoing"):
        parts.append("· on the clock")
    return "   ".join(parts)
