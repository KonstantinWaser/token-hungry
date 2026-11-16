#!/usr/bin/env python3
# Minecraft mode for the usage plugins. Each plugin hands its printed menu to
# menu(), which adds the switches and, while Minecraft is on, redraws the menu
# with the game's sprites. Looks best with the Monocraft font.
# The switches in the menu run this file as `minecraft.py toggle <switch>`,
# and the icon choice as `minecraft.py set <setting> <value>`.
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


# A setting is a hidden file holding its value.
def setting(name, default):
    path = HERE / f".{name}"
    return path.read_text().strip() if path.exists() else default


ICONS = 10 if on("wide") else 5  # icons per bar in the menu bar
# The bars a limit can be drawn with, as their empty, half and full icons.
BARS = {
    "Hearts": ("container", "half", "full"),
    "Golden hearts": ("container", "absorbing_half", "absorbing_full"),
    "Poisoned hearts": ("container", "poisoned_half", "poisoned_full"),
    "Withered hearts": ("container", "withered_half", "withered_full"),
    "Frozen hearts": ("container", "frozen_half", "frozen_full"),
    "Hardcore hearts": ("container_hardcore", "hardcore_half", "hardcore_full"),
    "Hardcore golden hearts": ("container_hardcore", "absorbing_hardcore_half", "absorbing_hardcore_full"),
    "Hardcore poisoned hearts": ("container_hardcore", "poisoned_hardcore_half", "poisoned_hardcore_full"),
    "Hardcore withered hearts": ("container_hardcore", "withered_hardcore_half", "withered_hardcore_full"),
    "Hardcore frozen hearts": ("container_hardcore", "frozen_hardcore_half", "frozen_hardcore_full"),
    # vehicle_half is the game's mirrored: the game fills mount hearts from the right
    "Mount hearts": ("vehicle_container", "vehicle_half", "vehicle_full"),
    "Hunger": ("food_empty", "food_half", "food_full"),
    "Hunger effect": ("food_empty_hunger", "food_half_hunger", "food_full_hunger"),
    "Air": ("air_empty", "air_bursting", "air"),
    **{f"{material.title()} armor": ("armor_empty", f"armor_{material}_half", f"armor_{material}_full")
       for material in ("leather", "chainmail", "copper", "iron", "gold", "diamond", "netherite")},
}
# The bar each limit has until the user picks another in the settings window.
DEFAULT_BARS = {("Claude", "Session"): "Hearts", ("Claude", "Weekly"): "Golden hearts",
                ("ChatGPT", "Session"): "Iron armor", ("ChatGPT", "Weekly"): "Diamond armor"}
ITEMS = {"Session": "apple", "Weekly": "golden_apple", "Full": "totem_of_undying"}
MENU_BAR = 44  # pixels a title may be tall: the macOS menu bar's 22 points at 2x

# Armor is drawn: a grid of letters, outline (o) to highlight (h), and for
# each material the colors those letters take.
ARMOR = """
ooo...ooo
ohlo.olmo
ohllollmo
ollllllmo
.ollllmo.
.ollllmo.
.ollllmo.
.ommmmmo.
.ooooooo.
"""
PALETTES = {  # outline, dark, mid, light, highlight
    "leather": ((50, 28, 14), (115, 64, 32), (160, 101, 64), (198, 139, 94), (224, 180, 140)),
    "chainmail": ((30, 30, 30), (70, 70, 70), (110, 110, 110), (150, 150, 150), (190, 190, 190)),
    "copper": ((60, 30, 18), (156, 78, 49), (216, 122, 85), (231, 156, 120), (250, 200, 170)),
    "gold": ((60, 45, 5), (200, 140, 20), (250, 210, 50), (255, 240, 120), (255, 255, 200)),
    "netherite": ((20, 16, 18), (49, 41, 42), (68, 58, 59), (95, 82, 84), (130, 115, 117)),
    "diamond": ((14, 63, 66), (32, 158, 163), (74, 220, 212), (161, 251, 232), (235, 255, 252)),
    "iron": ((36, 36, 36), (140, 140, 140), (200, 200, 200), (226, 226, 226), (255, 255, 255)),
    "empty": ((36, 36, 36), (60, 60, 60), (60, 60, 60), (72, 72, 72), (88, 88, 88)),
}
# The icons a balance can have: Minecraft's own item textures, in sprites/.
CURRENCIES = ("emerald", "diamond", "lapis_lazuli", "amethyst_shard", "redstone", "quartz",
              "gold_ingot", "iron_ingot", "copper_ingot", "netherite_ingot", "gold_nugget", "iron_nugget")
GLYPHS = {  # letters for big stack counts, in the 5x7 style of the digit sprite
    "k": ["#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."],
    "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#", "#...#"],
}

# A picture is a list of rows of (red, green, blue, alpha) pixels, each either
# solid or see-through.


def blank(width, height):
    return [[(0, 0, 0, 0)] * width for _ in range(height)]


def draw(grid, material, width=None, height=None):
    colors = dict(zip("odmlh", (color + (255,) for color in PALETTES[material])))
    rows = grid.split()
    picture = blank(width or len(rows[0]), height or len(rows))
    top = (len(picture) - len(rows)) // 2
    for y, row in enumerate(rows):
        for x, letter in enumerate(row):
            if letter != ".":
                picture[top + y][x] = colors[letter]
    return picture


# Reads a sprite: drawn armor or one of the PNGs in
# sprites/, which are in the plain form png() writes.
def sprite(name):
    if name.startswith("armor_"):  # armor_empty, armor_<material>_full, armor_<material>_half
        material, _, size = name.removeprefix("armor_").partition("_")
        picture = draw(ARMOR, material)
        return [row[:5] + [(0, 0, 0, 0)] * 4 for row in picture] if size == "half" else picture
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


# A picture as a base64 PNG, drawn at `scale` screen pixels per sprite pixel.
def encoded(picture, scale):
    picture = [[pixel for pixel in row for _ in range(scale)] for row in picture for _ in range(scale)]
    return base64.b64encode(png(picture)).decode()


def image(picture, scale):
    return f"image={encoded(picture, scale)}"


# A bar of icons showing what is left of a limit.
def icons(sprites, pct):
    empty, half, full = sprites
    halves = round((100 - min(100, pct)) * 2 * ICONS / 100)
    bar = blank(8 * ICONS + 1, 9)
    for i in range(ICONS):
        paste(bar, sprite(empty), 8 * i)
        if halves >= 2 * i + 1:
            paste(bar, sprite(full if halves >= 2 * i + 2 else half), 8 * i)
    return bar


# The menu bar title: the bars side by side or stacked, then the items, drawn
# as large as still fits the menu bar.
def title(bars, items):
    width = max(len(bar[0]) for bar in bars) if bars else 0
    across, down = (0, 10) if on("stacked") else (width + 5, 0)
    bars_width = width + across * (len(bars) - 1) if bars else 0
    bars_height = 9 + down * (len(bars) - 1) if bars else 0
    gap = 4 if bars and items else 0
    height = max(bars_height, 18 if items else 0)
    strip = blank(bars_width + gap + sum(len(item[0]) for item in items), height)
    for i, bar in enumerate(bars):
        paste(strip, bar, across * i, (height - bars_height) // 2 + down * i)
    left = bars_width + gap
    for item in items:
        paste(strip, item, left)
        left += len(item[0])
    return image(strip, max(1, min(3, MENU_BAR // height)))


# The experience bar, filled to the percent used.
def experience(pct):
    bar, progress = sprite("experience_bar_background"), sprite("experience_bar_progress")
    filled = round(len(bar[0]) * min(100, pct) / 100)
    paste(bar, [row[:filled] for row in progress])
    return image(bar, 2)


# A stack size as the game would print it, shortened from a thousand on: 1k, 12k, 3M.
def amount(value):
    value = max(0, value)  # a balance below zero is an empty stack
    for size, letter in ((1_000_000, "M"), (1000, "k")):
        if round(value) >= size:
            return f"{round(value / size)}{letter}"
    return str(round(value))


# An item in its slot with a count in the corner, as in the inventory. A long
# count widens the slot to the left, as a stack of 64 overhangs its item.
def slot(name, count=""):
    digits = sprite("digits")
    glyphs = [[row[8 * int(c):][:5] for row in digits] if c.isdigit()
              else [[(255, 255, 255, 255) if p == "#" else (0, 0, 0, 0) for p in row] for row in GLYPHS[c]]
              for c in count]
    text = blank(max(0, 6 * len(glyphs) - 1), 7)
    for i, glyph in enumerate(glyphs):
        paste(text, glyph, 6 * i)
    width = max(18, len(text[0]) + 2)
    picture = blank(width, 18)
    paste(picture, sprite(name), width - 18)
    if glyphs:
        shadow = [[(63, 63, 63, pixel[3]) for pixel in row] for row in text]
        paste(picture, shadow, width - len(text[0]) - 1, 10)
        paste(picture, text, width - len(text[0]) - 2, 9)
    return picture


def item(name, count=""):
    return image(slot(name, count), 2)


# A setting's file name, from what it is about: key("hide", "Claude", "Weekly")
# is hide-claude-weekly.
def key(*parts):
    return re.sub(r"\W+", "-", "-".join(parts)).lower()


# Each bar can be switched off in the settings, which leaves a hidden file
# named after the plugin and the bar.
def hidden(name, label):
    return key("hide", name, label)


def bar(name, label):
    return setting(key("bar", name, label), DEFAULT_BARS.get((name, label), "Hearts"))


# Redraws a plugin's menu under a heading that names it, with a bar of icons
# for each limit (see BARS), a stack of the chosen currency for a balance and
# the banked resets as items with their count.
def skin(name, output, currency):
    head, _, menu = output.partition("\n")
    bars, items, lines = [], [], []
    for line in menu.splitlines():
        usage = re.match(r"(.+?) +[█░]+ +(\d+)%", line)
        reset = re.match(r"(\d+)× (\w+)", line)
        balance = re.match(r"Balance +[^\d-]*(-?[\d.]+)", line)
        if balance:
            count = amount(float(balance[1]))
            if not on(hidden(name, "Balance")):
                items.append(slot(currency, count))
            line += " " + item(currency, count)
        elif usage:
            pct = int(usage[2])
            if not on(hidden(name, usage[1])):
                bars.append(icons(BARS.get(bar(name, usage[1]), BARS["Hearts"]), pct))
            line = re.sub(r"[█░]+ ", "", line) + " " + experience(pct)
        elif reset:
            icon, count = ITEMS.get(reset[2], "golden_apple"), int(reset[1])
            if not on(hidden(name, "Resets")):
                items.append(slot(icon, str(count) if count > 1 else ""))
            line = line[reset.end(1) + 2:] + " " + item(icon, str(count) if count > 1 else "")
        if line != "---" and not line.startswith("--"):
            line = line.replace(" font=Menlo size=13", "")
            line += ("" if "|" in line else " |") + f" {FONT}"
        lines.append(line)
    if bars or items:
        head = f"| {title(bars, items)}"
    lines.insert(1, f"{name} usage | {FONT}")
    return "\n".join([head] + lines) + "\n"


# The menu a plugin shows, from what it printed. `name` is Claude, ChatGPT or
# a balance provider, whose stack is drawn in `currency` unless the user chose
# another in the menu.
def menu(name, output, currency="emerald"):
    def action(text, *params, checked=False):
        args = " ".join(f"param{i}={p}" for i, p in enumerate(params, 1))
        return (f'\n{text} | bash="{Path(__file__).resolve()}" {args} terminal=false'
                + (" checked=true" if checked else ""))

    output += "---" + action("Minecraft", "toggle", "minecraft", checked=on("minecraft"))
    if on("minecraft"):
        output += action("Settings…", "settings")
    icon = setting(key("icon", name), currency)
    return skin(name, output, icon) if on("minecraft") else output + "\n"


# The settings window: the switches, and for each plugin which bars show and
# what they are drawn with. Nothing changes until Save.
def window():
    import tkinter as tk

    import balances
    root = tk.Tk()
    root.title("token-hungry settings")
    root.resizable(False, False)
    flags, choices, pictures = {}, {}, []  # pictures: Tk forgets images nobody holds

    def picture(sprite_name):
        try:
            pictures.append(tk.PhotoImage(data=encoded(sprite(sprite_name), 3)))
            return pictures[-1]
        except tk.TclError:  # Tk 8.5, as in macOS's own Python, reads no PNG
            return None

    def check(parent, text, name, inverted=False):
        flags[name] = tk.BooleanVar(value=on(name) != inverted), inverted
        tk.Checkbutton(parent, text=text, variable=flags[name][0], width=16, anchor="w").pack(side="left")

    def pick(parent, name, options, current):  # options: value -> the sprite showing it
        choices[name] = tk.StringVar(value=current), current
        grid = tk.Frame(parent)
        grid.pack(side="left")
        for i, (value, sprite_name) in enumerate(options.items()):
            shown = picture(sprite_name)
            tk.Radiobutton(grid, variable=choices[name][0], value=value, indicatoron=False, padx=4, pady=2,
                           **({"image": shown} if shown else {"text": value.replace("_", " ")})
                           ).grid(row=i // 12, column=i % 12)  # twelve to a line

    switches = tk.Frame(root, padx=12, pady=8)
    switches.pack(fill="x")
    for switch in SWITCHES:
        check(switches, switch.title(), switch)
    plugins = [(name, ("Session", "Weekly", "Resets")) for name in ("Claude", "ChatGPT")]
    plugins += [(name, ("Balance",)) for name in balances.PROVIDERS]
    for name, shows in plugins:
        frame = tk.LabelFrame(root, text=name, padx=8, pady=4)
        frame.pack(fill="x", padx=12, pady=4)
        for label in shows:
            row = tk.Frame(frame)
            row.pack(fill="x")
            check(row, f"Show {label}", hidden(name, label), inverted=True)
            if label == "Balance":
                pick(row, key("icon", name), {c: c for c in CURRENCIES},
                     setting(key("icon", name), balances.PROVIDERS[name]["icon"]))
            elif label != "Resets":
                pick(row, key("bar", name, label), {style: full for style, (_, _, full) in BARS.items()},
                     bar(name, label))

    def save():
        for name, (var, inverted) in flags.items():
            path = HERE / f".{name}"
            path.touch() if var.get() != inverted else path.unlink(missing_ok=True)
        for name, (var, current) in choices.items():
            if var.get() != current:
                (HERE / f".{name}").write_text(var.get())
        root.destroy()

    buttons = tk.Frame(root, padx=12, pady=8)
    buttons.pack(fill="x")
    tk.Button(buttons, text="Cancel", width=10, command=root.destroy).pack(side="right")
    tk.Button(buttons, text="Save", width=10, command=save).pack(side="right", padx=6)
    root.attributes("-topmost", True)  # opened from the taskbar, it would start behind other windows
    root.after(500, root.attributes, "-topmost", False)
    root.focus_force()
    root.mainloop()


if __name__ == "__main__" and sys.argv[1:2] in (["toggle"], ["settings"]):
    if sys.argv[1] == "settings":
        window()
    else:
        path = HERE / f".{sys.argv[2]}"
        path.unlink() if path.exists() else path.touch()
    if sys.platform == "darwin":  # taskbar.ps1 on Windows refreshes once this exits
        subprocess.run(["open", "-g", "swiftbar://refreshallplugins"])
