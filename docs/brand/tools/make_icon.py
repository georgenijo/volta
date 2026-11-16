#!/usr/bin/env python3
"""Generate every Volta app icon file from one geometry.

usage: python3 docs/brand/tools/make_icon.py        (from the repository root)

Writes the SVG sources in docs/brand/app-icon/, the Icon Composer layers in
ios/Volta/Resources/AppIcon.icon/, and, when Google Chrome is installed, the
three 1024 px PNGs in the asset catalog. Standard library only.
"""
import json
import math
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
SOURCES = os.path.join(ROOT, "docs", "brand", "app-icon")
COMPOSER = os.path.join(ROOT, "ios", "Volta", "Resources", "AppIcon.icon")
CATALOG = os.path.join(ROOT, "ios", "Volta", "Resources", "Assets.xcassets", "AppIcon.appiconset")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Two capsules lean together into a V. All units are pixels on a 1024 canvas.
WIDTH, LENGTH, TILT_DEGREES = 228, 690, 26
OFFSET_X, CENTER_Y = 101, 508

COLOR = {
    "field": ("#16233F", "#060912"),     # radial, top centre outwards
    "left": ("#86B6FF", "#2F69EC"),      # top to bottom
    "right": ("#7DF3FF", "#19BBD8"),
    "crossing": ("#EAFBFF", "#B4EEFF"),  # where the two currents overlap
}
TINTED = {
    "field": ("#000000", "#000000"),
    "left": ("#C6C6C6", "#9A9A9A"),
    "right": ("#F4F4F4", "#D4D4D4"),
    "crossing": ("#FFFFFF", "#FFFFFF"),
}


def capsule(center_x, degrees, steps=48):
    radius = WIDTH / 2
    half = LENGTH / 2 - radius
    points = [(radius * math.cos(math.pi + math.pi * i / steps), -half + radius * math.sin(math.pi + math.pi * i / steps)) for i in range(steps + 1)]
    points += [(radius * math.cos(math.pi * i / steps), half + radius * math.sin(math.pi * i / steps)) for i in range(steps + 1)]
    turn = math.radians(degrees)
    c, s = math.cos(turn), math.sin(turn)
    return [(center_x + x * c - y * s, CENTER_Y + x * s + y * c) for x, y in points]


def signed_area(polygon):
    return sum(polygon[i][0] * polygon[(i + 1) % len(polygon)][1] - polygon[(i + 1) % len(polygon)][0] * polygon[i][1] for i in range(len(polygon))) / 2


def intersection(subject, clipper):
    """Sutherland-Hodgman clip of two convex polygons."""
    if signed_area(clipper) < 0:
        clipper = clipper[::-1]
    result = subject
    for i in range(len(clipper)):
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]
        source, result = result, []
        if not source:
            break

        def inside(p):
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]) >= 0

        def crossing(p, q):
            d = (a[0] - b[0]) * (p[1] - q[1]) - (a[1] - b[1]) * (p[0] - q[0])
            ab = a[0] * b[1] - a[1] * b[0]
            pq = p[0] * q[1] - p[1] * q[0]
            return ((ab * (p[0] - q[0]) - (a[0] - b[0]) * pq) / d, (ab * (p[1] - q[1]) - (a[1] - b[1]) * pq) / d)

        previous = source[-1]
        for point in source:
            if inside(point):
                if not inside(previous):
                    result.append(crossing(previous, point))
                result.append(point)
            elif inside(previous):
                result.append(crossing(previous, point))
            previous = point
    return result


def path(polygon):
    return "M" + "L".join(f"{x:.1f} {y:.1f}" for x, y in polygon) + "Z"


LEFT = capsule(512 - OFFSET_X, -TILT_DEGREES)
RIGHT = capsule(512 + OFFSET_X, TILT_DEGREES)
CROSSING = intersection(LEFT, RIGHT)
EXTENT = (LENGTH - WIDTH) / 2 * math.cos(math.radians(TILT_DEGREES)) + WIDTH / 2
TOP, BOTTOM = round(CENTER_Y - EXTENT), round(CENTER_Y + EXTENT)


def vertical(name, colors, prefix=""):
    return (f'<linearGradient id="{prefix}{name}" x1="0" y1="{TOP}" x2="0" y2="{BOTTOM}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{colors[0]}"/><stop offset="1" stop-color="{colors[1]}"/></linearGradient>')


def composite(colors, prefix, field=True):
    defs = (f'<radialGradient id="{prefix}field" cx="512" cy="0" r="1100" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{colors["field"][0]}"/><stop offset="1" stop-color="{colors["field"][1]}"/></radialGradient>')
    defs += "".join(vertical(name, colors[name], prefix) for name in ("left", "right", "crossing"))
    background = f'<rect width="1024" height="1024" fill="url(#{prefix}field)"/>' if field else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f"<defs>{defs}</defs>\n{background}"
            f'<path d="{path(LEFT)}" fill="url(#{prefix}left)"/>'
            f'<path d="{path(RIGHT)}" fill="url(#{prefix}right)"/>'
            f'<path d="{path(CROSSING)}" fill="url(#{prefix}crossing)"/>\n</svg>\n')


def layer(polygon, colors):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f'  <defs>{vertical("g", colors)}</defs>\n  <path fill="url(#g)" d="{path(polygon)}"/>\n</svg>\n')


def p3(color):
    return "display-p3:" + ",".join(f"{int(color[i:i + 2], 16) / 255:.5f}" for i in (1, 3, 5)) + ",1.00000"


def write(directory, name, text):
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, name), "w") as handle:
        handle.write(text)


def rasterize(svg_name, png_name, background):
    with tempfile.TemporaryDirectory() as scratch:
        page = os.path.join(scratch, "icon.html")
        with open(os.path.join(SOURCES, svg_name)) as handle:
            svg = handle.read()
        with open(page, "w") as handle:
            handle.write("<!doctype html><meta charset=utf-8><style>html,body{margin:0;background:transparent}svg{display:block}</style>" + svg)
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--window-size=1024,1024", f"--default-background-color={background}",
                        "--screenshot=" + os.path.join(CATALOG, png_name), "file://" + page],
                       check=True, capture_output=True)


def main():
    write(SOURCES, "icon.svg", composite(COLOR, "a-"))
    write(SOURCES, "icon-dark.svg", composite(COLOR, "d-", field=False))
    write(SOURCES, "icon-tinted.svg", composite(TINTED, "t-"))

    assets = os.path.join(COMPOSER, "Assets")
    write(assets, "current-left.svg", layer(LEFT, COLOR["left"]))
    write(assets, "current-right.svg", layer(RIGHT, COLOR["right"]))
    write(assets, "crossing.svg", layer(CROSSING, COLOR["crossing"]))
    flat = {"enabled": False, "value": 0.5}
    document = {
        "fill": {"linear-gradient": [p3(COLOR["field"][0]), p3(COLOR["field"][1])]},
        "groups": [
            {"layers": [{"image-name": "crossing.svg", "name": "Crossing"}],
             "shadow": {"kind": "none", "opacity": 0.5}, "translucency": flat},
            {"layers": [{"image-name": "current-right.svg", "name": "Right current"},
                        {"image-name": "current-left.svg", "name": "Left current"}],
             "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": flat},
        ],
        "supported-platforms": {"squares": ["iOS"]},
    }
    write(COMPOSER, "icon.json", json.dumps(document, indent=2).replace('": ', '" : ') + "\n")

    if not os.path.exists(CHROME):
        sys.exit("SVG and Icon Composer files written. Google Chrome not found, so the catalog PNGs were not regenerated.")
    rasterize("icon.svg", "AppIcon.png", "000000ff")
    rasterize("icon-dark.svg", "AppIcon-Dark.png", "00000000")
    rasterize("icon-tinted.svg", "AppIcon-Tinted.png", "000000ff")


if __name__ == "__main__":
    main()
