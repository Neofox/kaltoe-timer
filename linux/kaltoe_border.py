"""Perimeter geometry for the tray icon's progress border.

Split out of kaltoe-tray.py for the same reason kaltoe_rows.py is: that module
raises SystemExit at import time when the GTK introspection data is missing,
which makes anything inside it untestable outside a configured Linux desktop.
Everything here is arithmetic on numbers, so test_kaltoe_border.py runs it
anywhere Python does — which matters more than usual, because this is the one
piece of the tray whose output nobody can eyeball without a Plasma panel.

Cairo has no way to trim a path to a fraction of its length. The border is
therefore built as an explicit list of segments — four sides and four rounded
corners — walked clockwise from the top centre, matching the macOS ring, which
starts its arc at twelve o'clock. The walk is cut where the running length
reaches `fill` of the perimeter, splitting whichever segment straddles it.

Angles are Cairo's: radians, 0 pointing +x, increasing toward +y. Because the
surface is y-down, increasing angle draws clockwise on screen.
"""

import math

HALF_PI = math.pi / 2


def perimeter(size, inset, radius):
    """Total stroke length of the rounded square, corners included."""
    side = max(0.0, size - 2 * inset)
    radius = min(radius, side / 2)
    return 4 * (side - 2 * radius) + 2 * math.pi * radius


def _walk(size, inset, radius):
    """The whole border, clockwise from top centre, as (length, segment) pairs.

    Straights and corners alternate, and the first and last segments are the two
    halves of the top edge — that split is what puts the start at twelve o'clock
    rather than at a corner.
    """
    side = max(0.0, size - 2 * inset)
    radius = max(0.0, min(radius, side / 2))
    left = top = float(inset)
    right = bottom = float(inset + side)
    middle = inset + side / 2
    straight = side - 2 * radius
    corner = HALF_PI * radius

    # (cx, cy, start angle) for each corner, in clockwise order from top-right.
    corners = [(right - radius, top + radius, 3 * HALF_PI),     # top-right
               (right - radius, bottom - radius, 0.0),          # bottom-right
               (left + radius, bottom - radius, HALF_PI),       # bottom-left
               (left + radius, top + radius, math.pi)]          # top-left
    straights = [((right, top + radius), (right, bottom - radius)),      # right edge
                 ((right - radius, bottom), (left + radius, bottom)),    # bottom, R→L
                 ((left, bottom - radius), (left, top + radius))]        # left, B→T

    # Both halves of the top edge measure side/2 − radius; written as the two
    # endpoints subtracting so the arithmetic reads against the diagram above.
    walk = [(right - radius - middle, ("line", middle, top, right - radius, top))]
    for index, (cx, cy, angle) in enumerate(corners):
        walk.append((corner, ("arc", cx, cy, radius, angle, angle + HALF_PI)))
        if index < len(straights):
            (x1, y1), (x2, y2) = straights[index]
            walk.append((straight, ("line", x1, y1, x2, y2)))
    walk.append((middle - (left + radius), ("line", left + radius, top, middle, top)))
    return walk


def _cut_line(segment, ratio):
    _, x1, y1, x2, y2 = segment
    return ("line", x1, y1, x1 + (x2 - x1) * ratio, y1 + (y2 - y1) * ratio)


def _cut_arc(segment, ratio):
    _, cx, cy, radius, a0, a1 = segment
    return ("arc", cx, cy, radius, a0, a0 + (a1 - a0) * ratio)


def segments(fill, size, inset, radius):
    """Segments to stroke for `fill` (0…1) of the perimeter, clockwise from top.

    `fill` at or below zero gives nothing to draw; at or above one, the closed
    border. Anything between splits one segment, so the drawn length is `fill`
    of `perimeter(...)` to within floating point — which is the property
    test_kaltoe_border.py checks, since it is the only claim here that a reader
    cannot verify by eye.
    """
    if not isinstance(fill, (int, float)) or fill != fill:   # None, or NaN
        return []
    if fill <= 0:
        return []
    total = perimeter(size, inset, radius)
    if total <= 0:
        return []
    budget = min(1.0, fill) * total
    drawn = []
    for length, segment in _walk(size, inset, radius):
        if length <= 0:
            continue                      # radius == side/2 leaves no straights
        if budget >= length:
            drawn.append(segment)
            budget -= length
            continue
        ratio = budget / length
        if ratio > 0:
            drawn.append(_cut_line(segment, ratio) if segment[0] == "line"
                         else _cut_arc(segment, ratio))
        break
    return drawn


def segment_length(segment):
    """Length of one segment — the inverse of the split above, for the tests."""
    if segment[0] == "line":
        _, x1, y1, x2, y2 = segment
        return math.hypot(x2 - x1, y2 - y1)
    _, _, _, radius, a0, a1 = segment
    return abs(a1 - a0) * radius


def rgb(value):
    """'#rrggbb' → (r, g, b) floats, or None for anything unusable.

    Tolerant on purpose: the colour arrives over the wire, and a tray that
    raises on a malformed string would take the whole panel icon down over a
    cosmetic border.
    """
    if not isinstance(value, str):
        return None
    text = value.lstrip("#")
    if len(text) != 6:
        return None
    try:
        return tuple(int(text[i:i + 2], 16) / 255 for i in (0, 2, 4))
    except ValueError:
        return None
