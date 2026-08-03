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
    """One week row: '월   8:35   +0:35', or '금   4:29   · 근무 중'.

    Overtime is spelled out here because, unlike the macOS popover, there is no
    bar to carry it. Not for want of a transport: DBusMenu carries no custom
    widgets, true, but `icon-data` is a standard com.canonical.dbusmenu item
    property holding raw PNG bytes, so a drawn per-row bar *could* travel. It
    loses on sizing — a row icon is rendered at the panel's own small square
    menu-icon size, which cannot hold a proportional bar anyone could read.

    The marker says 근무 중 — "on the clock", not "today": `isOngoing` is
    `record.clockOut == nil`, so it marks the day still being worked, which is
    absent after clocking out and can land on an earlier weekday whose record was
    never closed. macOS can spell that as a colour; a word cannot lie about it.
    """
    worked = day.get("worked")
    if worked is None:
        return f"{day['label']}   휴무" if day.get("isDayOff") else day["label"]
    parts = [day["label"], hm(worked)]
    if day.get("overtime"):
        parts.append(f"+{hm(day['overtime'])}")
    if day.get("isOngoing"):
        parts.append("· 근무 중")
    return "   ".join(parts)
