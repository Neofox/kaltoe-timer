#!/usr/bin/env python3
"""Cases for kaltoe_border. Run it: `python3 linux/test_kaltoe_border.py`.

No pytest, no runner, no CI — the same arrangement kaltoe_rows has, and for a
sharper reason. This module's output is a tray icon on a Plasma panel, which is
the one surface nobody working on this repo can look at. If the split arithmetic
is wrong the border is silently the wrong length, so these assert the property
directly: the segments handed to Cairo measure `fill` of the perimeter.

install.sh copies files by name, so this is not shipped to users.
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kaltoe_border import perimeter, rgb, segment_length, segments

SIZE, INSET, RADIUS = 64, 2, 10
TOTAL = perimeter(SIZE, INSET, RADIUS)


def drawn(fill):
    return sum(segment_length(s) for s in segments(fill, SIZE, INSET, RADIUS))


def main():
    checks = 0

    # The property the whole module exists to get right, across the fractions
    # that land mid-line, mid-corner, and exactly on a joint.
    for fill in (0.01, 0.1, 0.125, 0.25, 1 / 3, 0.5, 0.66, 0.75, 0.9, 0.99):
        assert math.isclose(drawn(fill), fill * TOTAL, rel_tol=1e-9), fill
        checks += 1

    # Endpoints. Nothing at all below zero, the closed border at and above one —
    # `fill` is clamped rather than allowed to wrap around a second lap.
    assert segments(0, SIZE, INSET, RADIUS) == []
    assert segments(-0.5, SIZE, INSET, RADIUS) == []
    assert math.isclose(drawn(1), TOTAL, rel_tol=1e-9)
    assert math.isclose(drawn(2), TOTAL, rel_tol=1e-9)
    checks += 4

    # Garbage off the wire draws nothing rather than raising: a malformed status
    # line must not take the panel icon down over a decoration.
    assert segments(None, SIZE, INSET, RADIUS) == []
    assert segments(float("nan"), SIZE, INSET, RADIUS) == []
    checks += 2

    # Monotonic, and every prefix is a prefix: growing `fill` only ever extends
    # the last segment or appends to it, never redraws the border differently.
    previous = -1.0
    for step in range(0, 101):
        length = drawn(step / 100)
        assert length >= previous - 1e-9, step
        previous = length
    for fill in (0.2, 0.45, 0.8):
        short, long = segments(fill, SIZE, INSET, RADIUS), segments(fill + 0.1, SIZE, INSET, RADIUS)
        assert short[:-1] == long[:len(short) - 1], fill
        checks += 1
    checks += 1

    # Starts at twelve o'clock, heading right — the macOS ring's origin. A border
    # that began at a corner would read as a different feature entirely.
    first = segments(0.01, SIZE, INSET, RADIUS)[0]
    assert first[0] == "line", first
    assert math.isclose(first[1], SIZE / 2) and math.isclose(first[2], INSET), first
    assert first[3] > first[1], "must run clockwise, i.e. to the right along the top"
    checks += 3

    # A radius at half the side is a circle: no straights left, four quarter arcs.
    circle = segments(1, SIZE, INSET, (SIZE - 2 * INSET) / 2)
    assert all(s[0] == "arc" for s in circle), circle
    assert math.isclose(sum(segment_length(s) for s in circle),
                        math.pi * (SIZE - 2 * INSET), rel_tol=1e-9)
    checks += 2

    # Colours off the wire.
    assert rgb("#ff9500") == (1.0, 149 / 255, 0.0)
    assert rgb("258ef7") == (0x25 / 255, 0x8e / 255, 0xf7 / 255)
    for bad in (None, "", "#abc", "#gggggg", 42):
        assert rgb(bad) is None, bad
    checks += 7

    print(f"{checks} checks pass")


if __name__ == "__main__":
    main()
