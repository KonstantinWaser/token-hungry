#!/usr/bin/env python3
# Minecraft mode for the usage plugins. Each plugin hands its printed menu to
# menu(), which adds the switches and, while Minecraft is on, redraws the menu
# with the game's sprites. Looks best with the Monocraft font.
# The switches in the menu run this file as `minecraft.py toggle <switch>`.
import base64
import re
import struct
import subprocess
import sys
import zlib
from pathlib import Path

FONT = "font=Monocraft size=13"
HERE = Path(__file__).resolve().parent
SWITCHES = "minecraft", "wide", "stacked"


# A switch is on while a hidden file of its name exists next to this script.
def on(switch):
    return (HERE / f".{switch}").exists()


ICONS = 10 if on("wide") else 5  # icons per bar in the menu bar
RED = ("container", "half", "full")
GOLD = ("container", "absorbing_half", "absorbing_full")
FOOD = ("food_empty", "food_half", "food_full")
ITEMS = {"Session": "apple", "Weekly": "golden_apple", "Full": "totem_of_undying"}

# A picture is a list of rows of (red, green, blue, alpha) pixels, each either
# solid or see-through.


def blank(width, height):
    return [[(0, 0, 0, 0)] * width for _ in range(height)]


# Reads a sprite. The sprite files are PNGs in the plain form png() writes.
def sprite(name):
    data = (HERE / "sprites" / f"{name}.png").read_bytes()
    width, height = struct.unpack(">II", data[16:24])
    packed, at = b"", 8
    while at < len(data):
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        packed += data[at + 8:at + 8 + size] if kind == b"IDAT" else b""
        at += size + 12
    rows = zlib.decompress(packed)
    return [[tuple(rows[y * (4 * width + 1) + 4 * x + 1:][:4]) for x in range(width)]
            for y in range(height)]


# Draws the solid pixels of `other` onto `picture`, its corner at (left, top).
def paste(picture, other, left=0, top=0):
    for y, row in enumerate(other):
        for x, pixel in enumerate(row):
            if pixel[3]:
                picture[top + y][left + x] = pixel


# A picture as a PNG file that claims two pixels per point, for Retina screens.
def png(picture):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + bytes(value for pixel in row for value in pixel) for row in picture)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", len(picture[0]), len(picture), 8, 6, 0, 0, 0))
            + chunk(b"pHYs", struct.pack(">IIB", 5669, 5669, 1))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


# A picture as an image parameter, drawn at `scale` screen pixels per sprite pixel.
def image(picture, scale):
    picture = [[pixel for pixel in row for _ in range(scale)] for row in picture for _ in range(scale)]
    return f"image={base64.b64encode(png(picture)).decode()}"


# A bar of icons showing what is left of a limit. Hunger fills from the right,
# as in the game.
def icons(sprites, pct):
    empty, half, full = sprites
    halves = round((100 - min(100, pct)) * 2 * ICONS / 100)
    bar = blank(8 * ICONS + 1, 9)
    for i in range(ICONS):
        x = 8 * (ICONS - 1 - i if sprites == FOOD else i)
        paste(bar, sprite(empty), x)
        if halves >= 2 * i + 1:
            paste(bar, sprite(full if halves >= 2 * i + 2 else half), x)
    return bar


# The menu bar title, with the bars side by side or stacked at a smaller size.
def title(bars):
    across, down = (0, 10) if on("stacked") else (len(bars[0][0]) + 5, 0)
    last = len(bars) - 1
    strip = blank(len(bars[0][0]) + across * last, 9 + down * last)
    for i, bar in enumerate(bars):
        paste(strip, bar, across * i, down * i)
    return image(strip, 2 if on("stacked") and last else 3)


# The experience bar, filled to the percent used.
def experience(pct):
    bar, progress = sprite("experience_bar_background"), sprite("experience_bar_progress")
    filled = round(len(bar[0]) * min(100, pct) / 100)
    paste(bar, [row[:filled] for row in progress])
    return image(bar, 2)


# An item with its stack count in the corner, as in the inventory.
def item(name, count):
    slot = blank(18, 18)
    paste(slot, sprite(name))
    if count > 1:
        digit = [row[8 * min(count, 9):][:5] for row in sprite("digits")]
        shadow = [[(63, 63, 63, pixel[3]) for pixel in row] for row in digit]
        paste(slot, shadow, 13, 10)
        paste(slot, digit, 12, 9)
    return image(slot, 2)


# Redraws a plugin's menu under a heading that names it. Hearts are the plan
# limits and golden hearts the model limits, each showing its most used one.
# ChatGPT gets hunger instead of hearts.
def skin(name, output):
    claude = name == "Claude"
    head, _, menu = output.partition("\n")
    plan, model, lines = [], [], []
    for line in menu.splitlines():
        usage = re.match(r"(.+?) +[█░]+ +(\d+)%", line)
        reset = re.match(r"(\d+)× (\w+)", line)
        if usage:
            pct = int(usage[2])
            (plan if usage[1] in ("Session", "Weekly") else model).append(pct)
            line = re.sub(r"[█░]+ ", "", line) + " " + experience(pct)
        elif reset:
            icon = ITEMS.get(reset[2], "golden_apple") if claude else "golden_carrot"
            line = line[reset.end(1) + 2:] + " " + item(icon, int(reset[1]))
        if line != "---":
            line = line.replace(" font=Menlo size=13", "")
            line += ("" if "|" in line else " |") + f" {FONT}"
        lines.append(line)
    bars = [icons(sprites, max(used))
            for sprites, used in ((RED if claude else FOOD, plan), (GOLD, model)) if used]
    if bars:
        head = f"| {title(bars)}"
    lines.insert(1, f"{name} usage | {FONT}")
    return "\n".join([head] + lines) + "\n"


# The menu a plugin shows, from what it printed. `name` is Claude or ChatGPT.
def menu(name, output):
    output += "---"
    for switch in SWITCHES if on("minecraft") else SWITCHES[:1]:
        output += f'\n{switch.title()} | bash="{Path(__file__).resolve()}" param1=toggle param2={switch} terminal=false'
        output += " checked=true" if on(switch) else ""
    return skin(name, output) if on("minecraft") else output + "\n"


if __name__ == "__main__" and sys.argv[1:2] == ["toggle"]:
    switch = HERE / f".{sys.argv[2]}"
    switch.unlink() if switch.exists() else switch.touch()
    subprocess.run(["open", "-g", "swiftbar://refreshallplugins"])
