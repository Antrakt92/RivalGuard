"""Render real addon mock-frame geometry; output is a simulation, not a game screenshot."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import html
import json
import os
from pathlib import Path
import shutil
import subprocess
import unicodedata


ROOT = Path(__file__).resolve().parents[1]
ANCHORS = {"TOPLEFT": (0, 0), "TOP": (0.5, 0), "TOPRIGHT": (1, 0), "LEFT": (0, 0.5), "CENTER": (0.5, 0.5), "RIGHT": (1, 0.5), "BOTTOMLEFT": (0, 1), "BOTTOM": (0.5, 1), "BOTTOMRIGHT": (1, 1)}
STRATA = {"BACKGROUND": 0, "LOW": 1, "MEDIUM": 2, "HIGH": 3, "DIALOG": 4, "FULLSCREEN": 5, "FULLSCREEN_DIALOG": 6, "TOOLTIP": 7}


@dataclass
class Rect:
    x: float
    y: float
    width: float
    height: float
    scale: float = 1


def intersection(a: Rect, b: Rect) -> Rect:
    left, top = max(a.x, b.x), max(a.y, b.y)
    return Rect(left, top, max(0, min(a.x + a.width, b.x + b.width) - left), max(0, min(a.y + a.height, b.y + b.height) - top))


class Scene:
    def __init__(self, raw):
        self.raw = raw
        self.frames = {frame["id"]: frame for frame in raw["frames"]}
        self.rects = {}
        self.warnings = []
        self.resolving = set()
        self.root = raw["meta"]["root"]
        self.canvas = Rect(0, 0, raw["meta"]["width"], raw["meta"]["height"])
        self.rects[self.root] = Rect(0, 0, self.canvas.width, self.canvas.height, raw["meta"]["uiScale"])

    def scale(self, frame):
        parent = self.frames.get(frame.get("parent"))
        return frame.get("scale", 1) * (self.scale(parent) if parent else 1)

    @staticmethod
    def text_width(text, size):
        return sum(size * (1 if unicodedata.east_asian_width(char) in "WF" else 0.54) for char in text)

    def lines(self, text, size, width):
        result = []
        for paragraph in str(text).split("\n"):
            if width <= 0:
                result.append(paragraph)
                continue
            line = ""
            for word in paragraph.split(" "):
                candidate = (line + " " + word).strip()
                if line and self.text_width(candidate, size) > width:
                    result.append(line)
                    line = word
                else:
                    line = candidate
            result.append(line)
        return result

    def rect(self, identifier):
        if identifier in self.rects:
            return self.rects[identifier]
        frame = self.frames[identifier]
        if identifier in self.resolving:
            self.warnings.append({"id": identifier, "issue": "cyclic_anchor_dependency"})
            return Rect(0, 0, 0, 0)
        self.resolving.add(identifier)
        scale = self.scale(frame)
        parent_id = frame.get("parent", self.root)
        parent = self.rect(parent_id)
        if frame.get("allPoints"):
            target = self.rect(frame["allPoints"])
            result = Rect(target.x, target.y, target.width, target.height, scale)
        else:
            width, height = frame.get("width", 0) * scale, frame.get("height", 0) * scale
            equations = []
            for anchor in frame.get("points", []):
                target = self.rect(anchor.get("relative", parent_id))
                relative_x, relative_y = ANCHORS[anchor["relativePoint"]]
                fraction_x, fraction_y = ANCHORS[anchor["point"]]
                equations.append((fraction_x, fraction_y, target.x + target.width * relative_x + anchor["x"] * scale, target.y + target.height * relative_y - anchor["y"] * scale))
            for first in equations:
                for second in equations:
                    if width == 0 and first[0] != second[0]:
                        width = (second[2] - first[2]) / (second[0] - first[0])
                    if height == 0 and first[1] != second[1]:
                        height = (second[3] - first[3]) / (second[1] - first[1])
            size = frame.get("fontSize", 13) * scale
            text = frame.get("text", "")
            if text:
                width = width or self.text_width(text, size)
                height = height or len(self.lines(text, size, width)) * size * 1.2
            if equations:
                first = equations[0]
                x, y = first[2] - first[0] * width, first[3] - first[1] * height
            else:
                # SetScrollChild supplies the implicit top-left attachment in WoW.
                x, y = parent.x, parent.y
            parent_frame = self.frames.get(parent_id, {})
            if parent_frame.get("scrollChild") == identifier:
                y -= parent_frame.get("scroll", 0) * scale
            result = Rect(x, y, max(0, width), max(0, height), scale)
        self.resolving.remove(identifier)
        self.rects[identifier] = result
        return result

    def clip(self, frame):
        result = self.canvas
        parent = self.frames.get(frame.get("parent"))
        while parent:
            if parent["kind"] == "ScrollFrame":
                result = intersection(result, self.rect(parent["id"]))
            parent = self.frames.get(parent.get("parent"))
        return result

    def strata(self, frame):
        parent = self.frames.get(frame.get("parent"))
        return STRATA.get(frame.get("strata"), self.strata(parent) if parent else 0)

    def alpha(self, frame):
        parent = self.frames.get(frame.get("parent"))
        return frame.get("alpha", 1) * (0.6 if frame.get("enabled") is False else 1) * (self.alpha(parent) if parent else 1)

    def drawable(self):
        for frame in sorted(self.frames.values(), key=lambda value: (self.strata(value), value["id"])):
            if not frame.get("visible") or frame["id"] == self.root:
                continue
            rect = self.rect(frame["id"])
            if rect.width <= 0 or rect.height <= 0:
                continue
            if frame.get("name", "").startswith("RivalGuard") and frame["kind"] == "Frame":
                if rect.x < -1 or rect.y < -1 or rect.x + rect.width > self.canvas.width + 1 or rect.y + rect.height > self.canvas.height + 1:
                    self.warnings.append({"name": frame["name"], "issue": "window_outside_viewport", "rect": vars(rect)})
            yield frame, rect, self.clip(frame)


def color(value, fallback=(1, 1, 1, 1)):
    value = value or fallback
    return tuple(round(max(0, min(1, component)) * 255) for component in [*value[:3], value[3] if len(value) > 3 else 1])


def svg(scene: Scene) -> str:
    width, height = scene.canvas.width, scene.canvas.height
    pieces = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">', '<rect width="100%" height="100%" fill="#17212b"/>']
    for frame, rect, clip in scene.drawable():
        identifier = frame["id"]
        pieces.append(f'<defs><clipPath id="c{identifier}"><rect x="{clip.x:.2f}" y="{clip.y:.2f}" width="{clip.width:.2f}" height="{clip.height:.2f}"/></clipPath></defs>')
        pieces.append(f'<g clip-path="url(#c{identifier})" opacity="{scene.alpha(frame):.3f}">')
        if frame.get("color"):
            red, green, blue, alpha = color(frame["color"])
            pieces.append(f'<rect x="{rect.x:.2f}" y="{rect.y:.2f}" width="{rect.width:.2f}" height="{rect.height:.2f}" fill="rgb({red},{green},{blue})" fill-opacity="{alpha / 255:.3f}"/>')
        elif frame.get("texture") and frame["kind"] == "Texture":
            pieces.append(f'<rect x="{rect.x:.2f}" y="{rect.y:.2f}" width="{rect.width:.2f}" height="{rect.height:.2f}" fill="#446b7c" stroke="#8cb3c3"/>')
        elif frame["kind"] == "EditBox":
            pieces.append(f'<rect x="{rect.x:.2f}" y="{rect.y:.2f}" width="{rect.width:.2f}" height="{rect.height:.2f}" fill="#101720" stroke="#3c4f60"/>')
        elif frame["kind"] == "Slider" and frame.get("maximum", 0) > frame.get("minimum", 0):
            fraction = (frame["value"] - frame["minimum"]) / (frame["maximum"] - frame["minimum"])
            x, y = (rect.x + rect.width / 2, rect.y + fraction * rect.height) if rect.height > rect.width else (rect.x + fraction * rect.width, rect.y + rect.height / 2)
            pieces.append(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="4" fill="#5ebedc"/>')
        if frame["kind"] == "CheckButton":
            pieces.append(f'<rect x="{rect.x + 3:.2f}" y="{rect.y + 3:.2f}" width="{max(1,rect.width - 6):.2f}" height="{max(1,rect.height - 6):.2f}" fill="{"#5ebedc" if frame.get("checked") else "#17212b"}" stroke="#80909f"/>')
        text = frame.get("text", "")
        if text:
            size = frame.get("fontSize", 13) * rect.scale
            lines = scene.lines(text, size, rect.width)
            red, green, blue, _ = color(frame.get("textColor"))
            justify = frame.get("justifyH", "LEFT")
            x = rect.x + (rect.width / 2 if justify == "CENTER" else rect.width if justify == "RIGHT" else 0)
            anchor = "middle" if justify == "CENTER" else "end" if justify == "RIGHT" else "start"
            y = rect.y + size
            if frame.get("justifyV") == "MIDDLE":
                y = rect.y + max(0, (rect.height - len(lines) * size * 1.2) / 2) + size
            pieces.append(f'<text x="{x:.2f}" y="{y:.2f}" font-family="Arial,sans-serif" font-size="{size:.2f}" text-anchor="{anchor}" fill="rgb({red},{green},{blue})">')
            for index, line in enumerate(lines):
                pieces.append(f'<tspan x="{x:.2f}" dy="{0 if index == 0 else size * 1.2:.2f}">{html.escape(line)}</tspan>')
            pieces.append('</text>')
        pieces.append('</g>')
    pieces.append('<rect x="0" y="0" width="100%" height="22" fill="#101820" fill-opacity=".92"/><text x="8" y="15" font-family="Arial,sans-serif" font-size="12" fill="#e4bc62">SIMULATED ADDON FRAMES — not an in-game screenshot; stock icons and font metrics approximated</text></svg>')
    return "\n".join(pieces)


def png(scene: Scene, output: Path):
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as error:
        raise RuntimeError("PNG export requires an existing Pillow installation; SVG output does not") from error
    image = Image.new("RGBA", (int(scene.canvas.width), int(scene.canvas.height)), (23, 33, 43, 255))
    fonts = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"
    candidates = [fonts / "arial.ttf", fonts / "segoeui.ttf", Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")]
    font_path = next((path for path in candidates if path.exists()), None)
    cache = {}
    def font(size):
        size = max(5, round(size))
        if size not in cache:
            cache[size] = ImageFont.truetype(str(font_path), size) if font_path else ImageFont.load_default(size=size)
        return cache[size]
    for frame, rect, clip in scene.drawable():
        if clip.width <= 0 or clip.height <= 0:
            continue
        layer = Image.new("RGBA", image.size)
        draw = ImageDraw.Draw(layer)
        bounds = (round(rect.x), round(rect.y), round(rect.x + rect.width), round(rect.y + rect.height))
        if frame.get("color"):
            draw.rectangle(bounds, fill=color(frame["color"]))
        elif frame.get("texture") and frame["kind"] == "Texture":
            draw.rectangle(bounds, fill=(68, 107, 124, 255), outline=(140, 179, 195, 255))
        elif frame["kind"] == "EditBox":
            draw.rectangle(bounds, fill=(16, 23, 32, 255), outline=(60, 79, 96, 255))
        elif frame["kind"] == "Slider" and frame.get("maximum", 0) > frame.get("minimum", 0):
            fraction = (frame["value"] - frame["minimum"]) / (frame["maximum"] - frame["minimum"])
            x, y = (rect.x + rect.width / 2, rect.y + fraction * rect.height) if rect.height > rect.width else (rect.x + fraction * rect.width, rect.y + rect.height / 2)
            draw.ellipse((round(x - 4), round(y - 4), round(x + 4), round(y + 4)), fill=(94, 190, 220, 255))
        if frame["kind"] == "CheckButton":
            draw.rectangle((bounds[0] + 3, bounds[1] + 3, max(bounds[0] + 4, bounds[2] - 3), max(bounds[1] + 4, bounds[3] - 3)), fill=(94, 190, 220, 255) if frame.get("checked") else (23, 33, 43, 255), outline=(128, 144, 159, 255))
        text = frame.get("text", "")
        if text:
            size = frame.get("fontSize", 13) * rect.scale
            lines = scene.lines(text, size, rect.width)
            y = rect.y
            if frame.get("justifyV") == "MIDDLE":
                y += max(0, (rect.height - len(lines) * size * 1.2) / 2)
            for line in lines:
                x = rect.x
                measured = draw.textlength(line, font=font(size))
                if frame.get("justifyH") == "CENTER": x += (rect.width - measured) / 2
                elif frame.get("justifyH") == "RIGHT": x += rect.width - measured
                draw.text((round(x), round(y)), line, fill=color(frame.get("textColor")), font=font(size))
                y += size * 1.2
        opacity = scene.alpha(frame)
        if opacity < 1:
            layer.putalpha(layer.getchannel("A").point(lambda value: round(value * opacity)))
        crop = (max(0, round(clip.x)), max(0, round(clip.y)), min(image.width, round(clip.x + clip.width)), min(image.height, round(clip.y + clip.height)))
        if crop[2] > crop[0] and crop[3] > crop[1]:
            image.alpha_composite(layer.crop(crop), (crop[0], crop[1]))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, image.width, 22), fill=(16, 24, 32, 255))
    draw.text((8, 3), "SIMULATED ADDON FRAMES — not an in-game screenshot; font metrics/icons approximated", font=font(12), fill=(228, 188, 98, 255))
    image.convert("RGB").save(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--locale", choices=["enUS", "ruRU"], default="enUS")
    parser.add_argument("--view", choices=["main", "settings", "rules", "import", "export", "details", "banner"], default="settings")
    parser.add_argument("--page", default="alerts")
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--scale", type=float, default=1)
    parser.add_argument("--high-contrast", action="store_true")
    parser.add_argument("--png", action="store_true", help="Also render PNG using existing Pillow")
    parser.add_argument("--lua", default=shutil.which("lua5.1"))
    parser.add_argument("--output", type=Path, required=True, help="Output filename prefix")
    args = parser.parse_args()
    if not args.lua:
        parser.error("Lua 5.1 is required")
    result = subprocess.run([args.lua, str(ROOT / "tests/preview.lua"), str(ROOT), args.locale, args.view, args.page, str(args.width), str(args.height), str(args.scale), "contrast" if args.high_contrast else "normal"], capture_output=True, text=True, encoding="utf-8", check=False)
    if result.returncode:
        parser.exit(1, f"Preview fixture failed:\n{result.stdout}{result.stderr}")
    raw = json.loads(result.stdout)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix(".json").write_text(json.dumps(raw, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    scene = Scene(raw)
    args.output.with_suffix(".svg").write_text(svg(scene), encoding="utf-8")
    if args.png:
        png(scene, args.output.with_suffix(".png"))
    # Deduplicate reports because SVG and PNG traverse the same generated scene.
    warnings = list({json.dumps(warning, sort_keys=True): warning for warning in scene.warnings}.values())
    args.output.with_suffix(".warnings.json").write_text(json.dumps(warnings, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "simulation": True, "frames": len(raw["frames"]), "warnings": warnings}))


if __name__ == "__main__":
    main()
