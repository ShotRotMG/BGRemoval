@echo off & title Nordstrom Photo Prep & (where py >nul 2>&1 || (echo Python is not installed - installing it now... & winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements & echo. & echo Done. Close this window and double-click the file again. & pause & exit /b)) & py -x "%~f0" %* || pause & exit /b
# ---------------------------------------------------------------------------
# Nordstrom Photo Prep  -  double-click this file to open the app.
# Everything below is Python. Same processing as "White Background.bat":
#   white RGB 255 background, product centered, 2640 x 4048, sRGB max-quality
#   JPG under 20 MB, never enlarged unless you allow it, originals untouched.
# ---------------------------------------------------------------------------
import io, json, os, queue, re, subprocess, sys, threading, traceback
from pathlib import Path

APP = "Nordstrom Photo Prep"
print(f"Starting {APP}...")
print("First run installs the tools it needs (a few minutes, one time only).", flush=True)


def ensure():
    try:
        import rembg, onnxruntime, PIL, pillow_heif  # noqa
    except ImportError:
        print("Installing tools...", flush=True)
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet",
                               "rembg[cpu]", "pillow", "pillow-heif"])


ensure()

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import pillow_heif
from PIL import Image, ImageCms, ImageOps, ImageTk

pillow_heif.register_heif_opener()

if os.name == "nt":  # hide the black console window once the app is up
    try:
        import ctypes
        ctypes.windll.user32.ShowWindow(ctypes.windll.kernel32.GetConsoleWindow(), 0)
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass

EXTS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".bmp", ".tif", ".tiff"}
OUT_NAME = "White Background"
SMALL_NAME = "Too small - reshoot"
MAX_MB = 20
NAME_OK = re.compile(r"^[^_]+_[^_]+_[^_]+$")  # Brand Name_VPN_Color
SRGB = ImageCms.createProfile("sRGB")
SRGB_BYTES = ImageCms.ImageCmsProfile(SRGB).tobytes()
SETTINGS_FILE = Path(os.environ.get("APPDATA", Path.home())) / "NordstromPhotoPrep" / "settings.json"
BUILTIN = "Nordstrom (default)"
BUILTIN_VALS = {"width": 2640, "height": 4048, "margin": 6.0, "fmt": "jpg", "remove_bg": True,
                "allow_up": False, "max_up": 1.25, "out_name": OUT_NAME, "quality": "best"}
PROFILE_KEYS = list(BUILTIN_VALS)

# ----------------------------------------------------------------- processing


def to_srgb(img):
    icc = img.info.get("icc_profile")
    if not icc:
        return img
    try:
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        return ImageCms.profileToProfile(img, src, SRGB, outputMode="RGB")
    except Exception:
        return img


MODELS = {"best": "birefnet-general", "fast": "isnet-general-use"}


def make_session(quality):
    """AI model session. 'best' = BiRefNet (fine detail, ~1 GB download, needs ~6 GB RAM)."""
    import onnxruntime as ort
    from rembg import new_session
    so = ort.SessionOptions()
    so.enable_cpu_mem_arena = False   # lower peak memory
    return new_session(MODELS[quality], sess_opts=so)


def mask_from_white(img, tol=12):
    from PIL import ImageChops
    diff = ImageChops.difference(img, Image.new("RGB", img.size, "white")).convert("L")
    return diff.point(lambda v: 255 if v > tol else 0)


def compose(img, mask, W, H, margin):
    """Cut the product out with its soft mask and center it on a pure white W x H canvas.
    Returns (canvas, scale) where scale > 1 means the product had to be enlarged."""
    import numpy as np
    from PIL import ImageFilter
    from pymatting import estimate_foreground_ml
    m = mask.point(lambda a: 0 if a < 12 else a)                     # drop faint noise
    bb = m.point(lambda a: 255 if a > 40 else 0).getbbox()
    if not bb:
        return None, None
    l, t, r, b = bb
    scale = min(W * (1 - 2 * margin) / (r - l), H * (1 - 2 * margin) / (b - t))
    pad = 8
    box = (max(l - pad, 0), max(t - pad, 0), min(r + pad, img.width), min(b + pad, img.height))
    size = (max(1, round((box[2] - box[0]) * scale)), max(1, round((box[3] - box[1]) * scale)))
    ci = img.crop(box).resize(size, Image.LANCZOS)
    cm = m.crop(box).resize(size, Image.LANCZOS)
    cm = cm.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.6))   # tighten edge 1 px
    rgb = np.asarray(ci).astype(np.float64) / 255
    a = np.asarray(cm).astype(np.float64) / 255
    rgb = np.clip(estimate_foreground_ml(rgb, a), 0, 1)              # remove background color from edges
    out = rgb * a[..., None] + (1 - a[..., None])                    # onto pure white
    tile = Image.fromarray((out * 255 + 0.5).astype(np.uint8))
    canvas = Image.new("RGB", (W, H), (255, 255, 255))
    x = (W - round((r - l) * scale)) // 2 - round((l - box[0]) * scale)
    y = (H - round((b - t) * scale)) // 2 - round((t - box[1]) * scale)
    canvas.paste(tile, (x, y))
    return canvas, scale


EDIT_DIR = ".photoprep"   # per-folder data for touch-ups (AI masks + edit markers)


def mask_path(folder, path):
    return Path(folder) / EDIT_DIR / f"{Path(path).stem}.mask.png"


def edited_flag(folder, path):
    return Path(folder) / EDIT_DIR / f"{Path(path).stem}.edited"


def ensure_edit_dir(folder):
    d = Path(folder) / EDIT_DIR
    if not d.exists():
        d.mkdir()
        if os.name == "nt":
            try:
                import ctypes
                ctypes.windll.kernel32.SetFileAttributesW(str(d), 2)  # hidden folder
            except Exception:
                pass
    return d


def load_source(path):
    img = ImageOps.exif_transpose(Image.open(path))
    return to_srgb(img.convert("RGB")).convert("RGB")


def save_output(canvas, scale, path, folder, s, note=""):
    """Write the finished image; returns (status, detail, output_path)."""
    path, folder = Path(path), Path(folder)
    dest_dir, status, detail = folder / s["out_name"], "Done", ""
    if scale > 1.02:
        if s["allow_up"] and scale <= s["max_up"]:
            status, detail = "Done (enlarged)", f"enlarged {scale:.2f}x"
        else:
            dest_dir, status, detail = folder / SMALL_NAME, "Too small", f"needs {scale:.2f}x enlargement"
    dest_dir.mkdir(exist_ok=True)
    for d in (folder / s["out_name"], folder / SMALL_NAME):   # no stale copy left in the other folder
        for ext in (".jpg", ".png"):
            old = d / f"{path.stem}{ext}"
            if old.exists() and old.parent != dest_dir:
                old.unlink()
    if s["fmt"] == "png":
        dest = dest_dir / f"{path.stem}.png"
        canvas.save(dest, dpi=(300, 300), icc_profile=SRGB_BYTES, optimize=True)
    else:
        dest = dest_dir / f"{path.stem}.jpg"
        for q in (100, 95, 92):
            canvas.save(dest, quality=q, subsampling=0, dpi=(300, 300), icc_profile=SRGB_BYTES)
            if dest.stat().st_size < MAX_MB * 1024 * 1024:
                break
    notes = [n for n in (detail, note) if n]
    if not NAME_OK.match(path.stem):
        notes.append("name not Brand_VPN_Color")
    return status, "; ".join(notes), dest


def process_one(path, folder, s, session, keep_edits=True):
    """Returns (status, detail, output_path)."""
    W, H, margin = s["width"], s["height"], s["margin"] / 100
    img = load_source(path)
    mp, flag = mask_path(folder, path), edited_flag(folder, path)
    mask, note = None, ""
    if keep_edits and flag.exists() and mp.exists():
        mask = Image.open(mp).convert("L")
        if mask.size == img.size:
            note = "touched up"
            img = apply_retouch(img, folder, path)
        else:
            mask = None
    if mask is None:
        if s["remove_bg"]:
            from rembg import remove
            mask = remove(img, session=session, only_mask=True,
                          post_process_mask=(s.get("quality") == "fast"))
        else:
            mask = mask_from_white(img)
        ensure_edit_dir(folder)
        mask.save(mp, compress_level=1)
        for old in (flag, retouch_path(folder, path)):
            if old.exists():
                old.unlink()
    canvas, scale = compose(img, mask, W, H, margin)
    if canvas is None:
        return "No product found", "", None
    return save_output(canvas, scale, path, folder, s, note)


# ------------------------------------------------------------- AI heal (LaMa)
HEAL_DIR = Path.home() / ".nordstrom-photo-prep"
HEAL_FILE = HEAL_DIR / "lama_fp32.onnx"
HEAL_SHA256 = "1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6"
HEAL_URLS = ["https://huggingface.co/Carve/LaMa-ONNX/resolve/main/lama_fp32.onnx",
             "https://github.com/neureps/carousel-fit-models/releases/download/lama-v1/lama-fp32-1faef5301d78.onnx"]
_heal_session = None


def ensure_heal_model(progress=None):
    """Download the LaMa fill model once (~208 MB) and check it."""
    import hashlib, urllib.request
    if HEAL_FILE.exists():
        return HEAL_FILE
    HEAL_DIR.mkdir(parents=True, exist_ok=True)
    tmp = HEAL_FILE.with_suffix(".part")
    last = None
    for url in HEAL_URLS:
        try:
            h = hashlib.sha256()
            with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
                total, got = int(r.headers.get("Content-Length") or 0), 0
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    h.update(chunk)
                    got += len(chunk)
                    if progress and total:
                        progress(f"Downloading heal model… {got * 100 // total}%")
            if h.hexdigest() != HEAL_SHA256:
                raise IOError("download was corrupted")
            tmp.replace(HEAL_FILE)
            return HEAL_FILE
        except Exception as e:
            last = e
            try:
                tmp.unlink()
            except OSError:
                pass
    raise IOError(f"Couldn't download the heal model: {last}")


def heal_patch(img, hole):
    """Fill the hole (L, 255 = remove) in img (RGB) with AI. Returns (box, new_patch)."""
    import numpy as np
    import onnxruntime as ort
    from PIL import ImageFilter
    global _heal_session
    if _heal_session is None:
        _heal_session = ort.InferenceSession(str(HEAL_FILE), providers=["CPUExecutionProvider"])
    l, t, r, b = hole.getbbox()
    ctx = max(int(max(r - l, b - t) * 2.5), 256)       # surrounding context for the AI
    cx, cy = (l + r) // 2, (t + b) // 2
    box = (max(cx - ctx // 2, 0), max(cy - ctx // 2, 0), min(cx + ctx // 2, img.width), min(cy + ctx // 2, img.height))
    crop = img.crop(box)
    hcrop = hole.crop(box).filter(ImageFilter.MaxFilter(5))
    x = np.asarray(crop.resize((512, 512), Image.LANCZOS)).astype(np.float32).transpose(2, 0, 1)[None] / 255
    m = (np.asarray(hcrop.resize((512, 512), Image.BILINEAR)) > 20).astype(np.float32)[None, None]
    out = _heal_session.run(None, {"image": x, "mask": m})[0][0].transpose(1, 2, 0)
    if out.max() <= 1.5:
        out = out * 255
    filled = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).resize(crop.size, Image.LANCZOS)
    return box, Image.composite(filled, crop, hcrop.filter(ImageFilter.GaussianBlur(2)))


def retouch_path(folder, path):
    return Path(folder) / EDIT_DIR / f"{Path(path).stem}.retouch.png"


def apply_retouch(img, folder, path):
    rp = retouch_path(folder, path)
    if rp.exists():
        layer = Image.open(rp).convert("RGBA")
        if layer.size == img.size:
            img = img.copy()
            img.paste(layer.convert("RGB"), (0, 0), layer.getchannel("A"))
    return img


# ------------------------------------------------------------ touch-up editor


class TouchUpWindow(tk.Toplevel):
    """Paint the cut-out mask by hand: Restore brings back parts of the shoe,
    Erase removes background the AI kept. Saves a new finished image."""

    def __init__(self, master, app, src, folder, on_saved=None):
        super().__init__(master)
        self.app, self.src, self.folder, self.on_saved = app, Path(src), Path(folder), on_saved
        self.title(f"Touch up - {self.src.name}")
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        self.geometry(f"{min(1200, sw - 60)}x{min(980, sh - 70)}")
        self.minsize(700, 560)

        self.orig_full = load_source(self.src)
        self.img_full = apply_retouch(self.orig_full, self.folder, self.src)
        self.mask_full = Image.open(mask_path(self.folder, self.src)).convert("L")
        bb = self.mask_full.point(lambda a: 255 if a > 40 else 0).getbbox() or (0, 0, *self.img_full.size)
        pw, ph = int((bb[2] - bb[0]) * 0.12) + 40, int((bb[3] - bb[1]) * 0.12) + 40
        W, H = self.img_full.size
        self.box = (max(bb[0] - pw, 0), max(bb[1] - ph, 0), min(bb[2] + pw, W), min(bb[3] + ph, H))
        self.img = self.img_full.crop(self.box)          # work area around the product
        self.mask = self.mask_full.crop(self.box)
        self.orig = self.orig_full.crop(self.box)
        self._busy = False
        self.undo, self.redo, self.dirty = [], [], False
        self.z, self.vx, self.vy = 1.0, 0.0, 0.0           # zoom and top-left of view (work-area px)
        self._photo, self._job, self._stroke = None, None, None
        self._pan = None

        # toolbar
        tb = ttk.Frame(self, padding=(10, 8))
        tb.pack(fill="x")
        self.v_mode = tk.StringVar(value="erase")
        ttk.Radiobutton(tb, text="Erase (E)", value="erase", variable=self.v_mode, command=self.draw_cursor).pack(side="left")
        ttk.Radiobutton(tb, text="Restore (R)", value="restore", variable=self.v_mode, command=self.draw_cursor).pack(side="left", padx=8)
        ttk.Radiobutton(tb, text="Heal (H)", value="heal", variable=self.v_mode, command=self.draw_cursor).pack(side="left", padx=(0, 16))
        ttk.Label(tb, text="Brush").pack(side="left")
        self.v_size = tk.DoubleVar(value=40)
        ttk.Scale(tb, from_=2, to=400, variable=self.v_size, length=150,
                  command=lambda v: self.lbl_size.config(text=f"{float(v):.0f} px")).pack(side="left", padx=4)
        self.lbl_size = ttk.Label(tb, text="40 px", width=7)
        self.lbl_size.pack(side="left")
        ttk.Label(tb, text="Softness").pack(side="left", padx=(10, 0))
        self.v_soft = tk.DoubleVar(value=1)
        ttk.Scale(tb, from_=0, to=10, variable=self.v_soft, length=90).pack(side="left", padx=4)
        self.v_view = tk.StringVar(value="result")
        ttk.Radiobutton(tb, text="Result", value="result", variable=self.v_view, command=self.render).pack(side="left", padx=(16, 0))
        ttk.Radiobutton(tb, text="Show removed in red", value="overlay", variable=self.v_view, command=self.render).pack(side="left", padx=6)

        bar = ttk.Frame(self, padding=(10, 6, 10, 10))
        bar.pack(fill="x", side="bottom")
        ttk.Button(bar, text="Undo", command=self.do_undo).pack(side="left")
        ttk.Button(bar, text="Redo", command=self.do_redo).pack(side="left", padx=4)
        ttk.Button(bar, text="Fit", command=self.fit).pack(side="left", padx=(12, 0))
        ttk.Button(bar, text="100%", command=lambda: self.zoom_at(1.0 / self.z, None)).pack(side="left", padx=4)
        ttk.Button(bar, text="Reset to AI result", command=self.reset_ai).pack(side="left", padx=(12, 0))
        ttk.Button(bar, text="Save", style="Big.TButton", command=self.save).pack(side="right")
        ttk.Button(bar, text="Cancel", command=self.close).pack(side="right", padx=8)
        self.lbl_info = ttk.Label(bar, foreground="#666")
        self.lbl_info.pack(side="right", padx=12)
        ttk.Label(self, foreground="#888", padding=(10, 0),
                  text="Left-drag paints  ·  Right-drag or Space+drag pans  ·  Wheel zooms  ·  [ ] brush size  ·  "
                       "E/R/H switch  ·  Ctrl+Z / Ctrl+Y").pack(side="bottom", anchor="w")

        self.canvas = tk.Canvas(self, bg="#9a9a9a", highlightthickness=0, cursor="none")
        self.canvas.pack(fill="both", expand=True, padx=10)
        c = self.canvas
        c.bind("<Configure>", lambda e: self.fit() if not getattr(self, "_fitted", False) else self.schedule())
        c.bind("<ButtonPress-1>", self.stroke_start)
        c.bind("<B1-Motion>", self.stroke_move)
        c.bind("<ButtonRelease-1>", self.stroke_end)
        for b in ("<ButtonPress-3>", "<ButtonPress-2>"):
            c.bind(b, self.pan_start)
        for b in ("<B3-Motion>", "<B2-Motion>"):
            c.bind(b, self.pan_move)
        c.bind("<Motion>", lambda e: self.draw_cursor(e))
        c.bind("<Leave>", lambda e: c.delete("cursor"))
        c.bind("<MouseWheel>", lambda e: self.zoom_at(1.25 if e.delta > 0 else 0.8, e))
        c.bind("<Button-4>", lambda e: self.zoom_at(1.25, e))
        c.bind("<Button-5>", lambda e: self.zoom_at(0.8, e))
        self.bind("<KeyPress-space>", lambda e: setattr(self, "_space", True))
        self.bind("<KeyRelease-space>", lambda e: setattr(self, "_space", False))
        self.bind("<Key-e>", lambda e: (self.v_mode.set("erase"), self.draw_cursor()))
        self.bind("<Key-r>", lambda e: (self.v_mode.set("restore"), self.draw_cursor()))
        self.bind("<Key-h>", lambda e: (self.v_mode.set("heal"), self.draw_cursor()))
        self.bind("<Key-bracketleft>", lambda e: self.set_size(self.v_size.get() / 1.25))
        self.bind("<Key-bracketright>", lambda e: self.set_size(self.v_size.get() * 1.25))
        self.bind("<Control-z>", lambda e: self.do_undo())
        self.bind("<Control-y>", lambda e: self.do_redo())
        self.bind("<Control-s>", lambda e: self.save())
        self.bind("<Escape>", lambda e: self.close())
        self.protocol("WM_DELETE_WINDOW", self.close)
        self._space = False
        self.transient(master)
        self.focus_set()
        self.update_info()

    # ---- view
    def fit(self):
        cw, ch = max(self.canvas.winfo_width(), 100), max(self.canvas.winfo_height(), 100)
        self.z = min(cw / self.img.width, ch / self.img.height) * 0.96
        self.vx = (self.img.width - cw / self.z) / 2
        self.vy = (self.img.height - ch / self.z) / 2
        self._fitted = True
        self.render()

    def zoom_at(self, factor, e):
        cw, ch = self.canvas.winfo_width(), self.canvas.winfo_height()
        px, py = (e.x, e.y) if e is not None else (cw / 2, ch / 2)
        ix, iy = self.vx + px / self.z, self.vy + py / self.z
        self.z = min(max(self.z * factor, 0.05), 8.0)
        self.vx, self.vy = ix - px / self.z, iy - py / self.z
        self.render()
        if e is not None:
            self.draw_cursor(e)

    def pan_start(self, e):
        self._pan = (e.x, e.y, self.vx, self.vy)

    def pan_move(self, e):
        if self._pan:
            x0, y0, vx, vy = self._pan
            self.vx, self.vy = vx - (e.x - x0) / self.z, vy - (e.y - y0) / self.z
            self.schedule(15)

    def schedule(self, ms=30):
        if self._job:
            self.after_cancel(self._job)
        self._job = self.after(ms, self.render)

    def render(self):
        self._job = None
        c = self.canvas
        cw, ch = max(c.winfo_width(), 1), max(c.winfo_height(), 1)
        x0, y0 = max(self.vx, 0), max(self.vy, 0)
        x1, y1 = min(self.vx + cw / self.z, self.img.width), min(self.vy + ch / self.z, self.img.height)
        c.delete("img")
        if x1 <= x0 or y1 <= y0:
            return
        box = (int(x0), int(y0), int(x1) + 1, int(y1) + 1)
        size = (max(1, round((box[2] - box[0]) * self.z)), max(1, round((box[3] - box[1]) * self.z)))
        rs = Image.NEAREST if self.z >= 2 else Image.BILINEAR
        im = self.img.crop(box).resize(size, rs, reducing_gap=2.0 if self.z < 1 else None)
        mk = self.mask.crop(box).resize(size, rs, reducing_gap=2.0 if self.z < 1 else None)
        if self.v_view.get() == "overlay":
            red = Image.blend(im, Image.new("RGB", size, (255, 0, 0)), 0.55)
            shown = Image.composite(im, red, mk)
        else:
            shown = Image.composite(im, Image.new("RGB", size, (255, 255, 255)), mk)
        self._photo = ImageTk.PhotoImage(shown)
        c.create_image(round((box[0] - self.vx) * self.z), round((box[1] - self.vy) * self.z),
                       image=self._photo, anchor="nw", tags="img")
        c.tag_raise("cursor")

    def draw_cursor(self, e=None):
        c = self.canvas
        if e is not None:
            self._mouse = (e.x, e.y)
        if not hasattr(self, "_mouse"):
            return
        x, y = self._mouse
        r = self.v_size.get() * self.z / 2
        c.delete("cursor")
        color = {"erase": "#d32f2f", "restore": "#1e88e5", "heal": "#2e7d32"}[self.v_mode.get()]
        c.create_oval(x - r, y - r, x + r, y + r, outline=color, width=2, tags="cursor")
        c.create_oval(x - r - 1, y - r - 1, x + r + 1, y + r + 1, outline="white", width=1, tags="cursor")

    def set_size(self, v):
        v = min(max(v, 2), 400)
        self.v_size.set(v)
        self.lbl_size.config(text=f"{v:.0f} px")
        self.draw_cursor()

    def update_info(self):
        self.lbl_info.config(text=f"Zoom {self.z * 100:.0f}%" + ("   ● unsaved edits" if self.dirty else ""))

    # ---- painting
    def to_img(self, e):
        return self.vx + e.x / self.z, self.vy + e.y / self.z

    def stroke_start(self, e):
        if self._space:
            return self.pan_start(e)
        if self._busy:
            return
        if self.v_mode.get() == "heal":
            self._stroke = [self.to_img(e)]
            w = self.v_size.get() * self.z
            self.canvas.create_oval(e.x - w / 2, e.y - w / 2, e.x + w / 2, e.y + w / 2,
                                    fill="#66bb6a", outline="", tags="healstroke")
            return
        self._before = self.mask.copy()
        self._stroke = [self.to_img(e)]
        self.paint_segment(self._stroke[0], self._stroke[0])

    def stroke_move(self, e):
        if self._space:
            return self.pan_move(e)
        self.draw_cursor(e)
        if self._stroke is None:
            return
        p = self.to_img(e)
        if self.v_mode.get() == "heal":
            a = self._stroke[-1]
            self.canvas.create_line((a[0] - self.vx) * self.z, (a[1] - self.vy) * self.z, e.x, e.y,
                                    fill="#66bb6a", width=self.v_size.get() * self.z, capstyle="round",
                                    tags="healstroke")
            self._stroke.append(p)
            self.canvas.tag_raise("cursor")
            return
        self.paint_segment(self._stroke[-1], p)
        self._stroke.append(p)
        self.schedule(25)

    def paint_segment(self, a, b):
        from PIL import ImageDraw
        d = ImageDraw.Draw(self.mask)
        w = max(1, round(self.v_size.get()))
        val = 0 if self.v_mode.get() == "erase" else 255
        d.line([a, b], fill=val, width=w)
        for (x, y) in (a, b):
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=val)

    def stroke_end(self, e):
        if self._pan and self._space:
            self._pan = None
            return
        if self._stroke is None:
            return
        if self.v_mode.get() == "heal":
            pts, self._stroke = self._stroke, None
            return self.start_heal(pts)
        from PIL import ImageChops, ImageDraw, ImageFilter
        w, soft = max(1, round(self.v_size.get())), self.v_soft.get()
        xs = [p[0] for p in self._stroke]
        ys = [p[1] for p in self._stroke]
        m = w / 2 + soft * 3 + 4
        bb = (max(int(min(xs) - m), 0), max(int(min(ys) - m), 0),
              min(int(max(xs) + m) + 1, self.mask.width), min(int(max(ys) + m) + 1, self.mask.height))
        if bb[2] > bb[0] and bb[3] > bb[1]:
            before = self._before.crop(bb)
            if soft > 0:   # redo the stroke with feathered edges
                layer = Image.new("L", (bb[2] - bb[0], bb[3] - bb[1]), 0)
                d = ImageDraw.Draw(layer)
                pts = [(x - bb[0], y - bb[1]) for x, y in self._stroke]
                d.line(pts if len(pts) > 1 else pts * 2, fill=255, width=w)
                for x, y in pts:
                    d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
                layer = layer.filter(ImageFilter.GaussianBlur(soft))
                if self.v_mode.get() == "erase":
                    new = ImageChops.darker(before, ImageChops.invert(layer))
                else:
                    new = ImageChops.lighter(before, layer)
                self.mask.paste(new, bb[:2])
            self.undo.append(("mask", bb, before))
            self.redo.clear()
            if len(self.undo) > 60:
                self.undo.pop(0)
            self.dirty = True
        self._stroke, self._before = None, None
        self.update_info()
        self.render()

    def _layer(self, kind):
        return self.mask if kind == "mask" else self.img

    def do_undo(self):
        if self.undo and not self._busy:
            kind, bb, patch = self.undo.pop()
            self.redo.append((kind, bb, self._layer(kind).crop(bb)))
            self._layer(kind).paste(patch, bb[:2])
            self.dirty = True
            self.update_info()
            self.render()

    def do_redo(self):
        if self.redo and not self._busy:
            kind, bb, patch = self.redo.pop()
            self.undo.append((kind, bb, self._layer(kind).crop(bb)))
            self._layer(kind).paste(patch, bb[:2])
            self.dirty = True
            self.update_info()
            self.render()

    def start_heal(self, pts):
        """Fill the painted area with AI, in chunks so long strokes keep full detail."""
        from PIL import ImageDraw
        w = max(2, round(self.v_size.get()))
        chunks, cur = [], [pts[0]]
        for p in pts[1:]:
            xs = [q[0] for q in cur + [p]]
            ys = [q[1] for q in cur + [p]]
            if max(max(xs) - min(xs), max(ys) - min(ys)) + w > 320 and len(cur) > 1:
                chunks.append(cur)
                cur = [cur[-1]]
            cur.append(p)
        chunks.append(cur)
        holes = []
        for ch in chunks:
            hole = Image.new("L", self.img.size, 0)
            d = ImageDraw.Draw(hole)
            d.line(ch if len(ch) > 1 else ch * 2, fill=255, width=w)
            for x, y in ch:
                d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
            if hole.getbbox():
                holes.append(hole)
        if not holes:
            self.canvas.delete("healstroke")
            return
        self._busy = True
        self.config(cursor="watch")
        self.lbl_info.config(text="Healing…")
        work = self.img.copy()

        def job():
            try:
                ensure_heal_model(lambda msg: self.after(0, lambda: self.lbl_info.config(text=msg)))
                patches = []
                for i, hole in enumerate(holes, 1):
                    self.after(0, lambda i=i: self.lbl_info.config(text=f"Healing… {i}/{len(holes)}"))
                    box, patch = heal_patch(work, hole)
                    patches.append((box, work.crop(box), patch))
                    work.paste(patch, box[:2])
                self.after(0, lambda: self.heal_done(patches, None))
            except Exception as e:
                self.after(0, lambda e=e: self.heal_done([], e))

        threading.Thread(target=job, daemon=True).start()

    def heal_done(self, patches, err):
        self._busy = False
        try:
            self.config(cursor="")
        except tk.TclError:
            return
        self.canvas.delete("healstroke")
        if err:
            messagebox.showerror("Heal", f"Heal didn't work:\n{err}", parent=self)
        if patches:   # one undo step for the whole stroke
            ub = (min(p[0][0] for p in patches), min(p[0][1] for p in patches),
                  max(p[0][2] for p in patches), max(p[0][3] for p in patches))
            self.undo.append(("img", ub, self.img.crop(ub)))
            for box, before, patch in patches:
                self.img.paste(patch, box[:2])
            self.redo.clear()
            self.dirty = True
        self.update_info()
        self.render()

    def reset_ai(self):
        if not messagebox.askyesno("Touch up", "Throw away all touch-ups on this photo and go back to the "
                                                "AI result? (The photo will be re-run through the AI when you save.)", parent=self):
            return
        self._reset = True
        self.save()

    # ---- save / close
    def save(self):
        if self._busy:
            return
        s = dict(self.app.s["current"])
        self.config(cursor="watch")
        self.update_idletasks()
        try:
            if getattr(self, "_reset", False):
                for old in (edited_flag(self.folder, self.src), retouch_path(self.folder, self.src)):
                    if old.exists():
                        old.unlink()
                session = self.app.get_session(s.get("quality", "best")) if s["remove_bg"] else None
                status, detail, dest = process_one(self.src, self.folder, s, session, keep_edits=False)
            else:
                full = self.mask_full.copy()
                full.paste(self.mask, self.box[:2])
                ensure_edit_dir(self.folder)
                full.save(mask_path(self.folder, self.src), compress_level=1)
                edited_flag(self.folder, self.src).write_text("touched up by hand\n")
                import numpy as np
                changed = (np.abs(np.asarray(self.img).astype(int) - np.asarray(self.orig).astype(int)).max(axis=2) > 0)
                rp = retouch_path(self.folder, self.src)
                img_used = self.orig_full.copy()
                if changed.any():
                    layer = Image.new("RGBA", self.orig_full.size, (0, 0, 0, 0))
                    arr = np.zeros((*changed.shape, 4), np.uint8)       # only healed pixels, rest empty
                    arr[changed, :3] = np.asarray(self.img)[changed]
                    arr[changed, 3] = 255
                    layer.paste(Image.fromarray(arr, "RGBA"), self.box[:2])
                    layer.save(rp, compress_level=6)
                    img_used.paste(self.img, self.box[:2])
                elif rp.exists():
                    rp.unlink()
                canvas, scale = compose(img_used, full, s["width"], s["height"], s["margin"] / 100)
                if canvas is None:
                    messagebox.showerror("Touch up", "Nothing left to save - the whole shoe is erased.", parent=self)
                    return
                status, detail, dest = save_output(canvas, scale, self.src, self.folder, s, "touched up")
        except Exception as e:
            messagebox.showerror("Touch up", f"Couldn't save:\n{e}", parent=self)
            return
        finally:
            try:
                self.config(cursor="")
            except tk.TclError:
                pass
        if self.on_saved:
            self.on_saved(str(self.src), status, detail, dest)
        self.dirty = False
        self.destroy()

    def close(self):
        if self.dirty and not messagebox.askyesno("Touch up", "Discard your touch-ups on this photo?", parent=self):
            return
        self.destroy()


# -------------------------------------------------------------- review window


class ReviewWindow(tk.Toplevel):
    """Step through finished photos one at a time."""
    COLORS = {"ok": "#2e7d32", "warn": "#b26a00", "bad": "#c62828"}

    def __init__(self, master, items, start=0):
        super().__init__(master)
        self.title("Review results")
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        self.geometry(f"{min(1000, sw - 80)}x{min(980, sh - 80)}")
        self.minsize(560, 600)
        self.all_items = items          # dicts: src, out, status, detail, tag
        self.items = list(items)
        self.i = min(start, len(items) - 1)
        self._img, self._job, self._cache = None, None, {}

        top = ttk.Frame(self, padding=(14, 10, 14, 4))
        top.pack(fill="x")
        self.lbl_name = ttk.Label(top, font=("Segoe UI", 13, "bold"))
        self.lbl_name.pack(side="left")
        self.lbl_count = ttk.Label(top, font=("Segoe UI", 11), foreground="#555")
        self.lbl_count.pack(side="right")
        info = ttk.Frame(self, padding=(14, 0, 14, 6))
        info.pack(fill="x")
        self.lbl_status = ttk.Label(info, font=("Segoe UI", 10, "bold"))
        self.lbl_status.pack(side="left")
        self.lbl_detail = ttk.Label(info, foreground="#555")
        self.lbl_detail.pack(side="left", padx=10)

        bar = ttk.Frame(self, padding=(14, 6, 14, 12))
        bar.pack(fill="x", side="bottom")
        self.btn_prev = ttk.Button(bar, text="◀  Previous", command=lambda: self.go(-1))
        self.btn_prev.pack(side="left")
        self.btn_next = ttk.Button(bar, text="Next  ▶", command=lambda: self.go(1))
        self.btn_next.pack(side="left", padx=6)
        ttk.Button(bar, text="Close", command=self.destroy).pack(side="right")
        ttk.Button(bar, text="Show in folder", command=self.show_in_folder).pack(side="right", padx=6)
        ttk.Button(bar, text="Open file", command=lambda: App.open_path(self.cur["out"])).pack(side="right")
        ttk.Button(bar, text="✎ Touch up…", command=self.touch_up).pack(side="left", padx=(16, 0))
        self.btn_reproc = ttk.Button(bar, text="↻ Reprocess", command=self.reprocess)
        self.btn_reproc.pack(side="left", padx=6)

        opts = ttk.Frame(self, padding=(14, 0, 14, 0))
        opts.pack(fill="x", side="bottom")
        self.v_view = tk.StringVar(value="after")
        for txt, val in (("After", "after"), ("Before", "before"), ("Side by side", "both")):
            ttk.Radiobutton(opts, text=txt, value=val, variable=self.v_view, command=self.render).pack(side="left", padx=(0, 10))
        self.v_problems = tk.BooleanVar(value=False)
        ttk.Checkbutton(opts, text="Only show problems", variable=self.v_problems,
                        command=self.apply_filter).pack(side="right")
        ttk.Label(self, text="← → to move  ·  Space flips before/after  ·  T touch up  ·  P reprocess  ·  Esc closes",
                  foreground="#888", padding=(14, 0)).pack(side="bottom", anchor="w")

        self.canvas = tk.Canvas(self, bg="#c8c8c8", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True, padx=14, pady=4)
        self.canvas.bind("<Configure>", lambda e: self.schedule())

        for key, fn in (("<Left>", lambda e: self.go(-1)), ("<Right>", lambda e: self.go(1)),
                        ("<Home>", lambda e: self.jump(0)), ("<End>", lambda e: self.jump(len(self.items) - 1)),
                        ("<space>", lambda e: self.flip()), ("<Escape>", lambda e: self.destroy()),
                        ("<Key-t>", lambda e: self.touch_up()), ("<Key-p>", lambda e: self.reprocess())):
            self.bind(key, fn)
        self.transient(master)
        self.focus_set()
        self.show()

    @property
    def cur(self):
        return self.items[self.i]

    def apply_filter(self):
        keep = [it for it in self.all_items if it["tag"] != "ok"] if self.v_problems.get() else list(self.all_items)
        if not keep:
            messagebox.showinfo("Review results", "No problems - every photo came out Done.", parent=self)
            self.v_problems.set(False)
            return
        current = self.cur["src"] if self.items else None
        self.items = keep
        self.i = next((n for n, it in enumerate(keep) if it["src"] == current), 0)
        self.show()

    def go(self, step):
        self.jump(self.i + step)

    def jump(self, n):
        if 0 <= n < len(self.items) and n != self.i:
            self.i = n
            self.show()

    def flip(self):
        self.v_view.set("before" if self.v_view.get() == "after" else "after")
        self.render()

    def show(self):
        it = self.cur
        self.lbl_name.config(text=Path(it["src"]).name)
        self.lbl_count.config(text=f"{self.i + 1} of {len(self.items)}")
        self.lbl_status.config(text=it["status"], foreground=self.COLORS.get(it["tag"], "#333"))
        self.lbl_detail.config(text=it["detail"])
        self.btn_prev.config(state="normal" if self.i > 0 else "disabled")
        self.btn_next.config(state="normal" if self.i < len(self.items) - 1 else "disabled")
        self.render()
        self.master.tree.selection_set(it["src"]) if self.master.tree.exists(it["src"]) else None

    def schedule(self):
        if self._job:
            self.after_cancel(self._job)
        self._job = self.after(120, self.render)

    def load(self, path, box):
        key = (str(path), box)
        if key not in self._cache:
            if len(self._cache) > 12:
                self._cache.clear()
            im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
            im.thumbnail(box, Image.LANCZOS)
            self._cache[key] = im
        return self._cache[key]

    def render(self):
        self.canvas.delete("all")
        cw, ch = max(self.canvas.winfo_width(), 100), max(self.canvas.winfo_height(), 100)
        it, view = self.cur, self.v_view.get()
        paths = {"after": [it["out"]], "before": [it["src"]], "both": [it["src"], it["out"]]}[view]
        n = len(paths)
        slot_w = (cw - 20 * (n - 1)) // n
        self._img = []
        for k, p in enumerate(paths):
            try:
                im = self.load(p, (slot_w - 10, ch - 10))
            except Exception:
                self.canvas.create_text(cw // 2, ch // 2, text="Can't open this image")
                continue
            ph = ImageTk.PhotoImage(im)
            self._img.append(ph)
            x = k * (slot_w + 20) + slot_w // 2
            self.canvas.create_image(x, ch // 2, image=ph)
            if n == 2:
                self.canvas.create_text(x, 12, text=("Before", "After")[k], font=("Segoe UI", 10, "bold"))

    def touch_up(self):
        it = self.cur
        app = self.master
        if not mask_path(app.folder, it["src"]).exists():
            messagebox.showinfo("Touch up", "Process this photo again first - this version of the app saves "
                                            "the data the touch-up tool needs.", parent=self)
            return
        TouchUpWindow(self, app, it["src"], app.folder, on_saved=self.touched)

    def reprocess(self):
        app, src = self.master, self.cur["src"]

        def done():
            if not self.winfo_exists():
                return
            self.btn_reproc.config(state="normal")
            if app.tree.exists(src) and src in app.outputs:
                self.touched(src, app.tree.set(src, "status"), app.tree.set(src, "detail"), app.outputs[src])

        if app.process([Path(src)], on_done=done):
            self.btn_reproc.config(state="disabled")
            self.lbl_status.config(text="Reprocessing…", foreground="#1e88e5")
            self.lbl_detail.config(text="")

    def touched(self, src, status, detail, dest):
        self.master.update_result(src, status, detail, dest)
        tag = {"Done": "ok", "Done (enlarged)": "warn"}.get(status, "bad")
        for lst in (self.items, self.all_items):
            for it in lst:
                if it["src"] == src:
                    it.update(status=status, detail=detail, out=dest, tag=tag)
        self._cache.clear()
        self.v_view.set("after")
        self.show()
        self.focus_set()

    def show_in_folder(self):
        p = str(self.cur["out"])
        if os.name == "nt":
            subprocess.Popen(["explorer", "/select,", p])
        else:
            App.open_path(Path(p).parent)


# ----------------------------------------------------------------------- app


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP)
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        self.geometry(f"{min(1240, sw - 40)}x{min(860, sh - 80)}")
        self.minsize(980, 680)
        self.s = self.load_settings()
        self.files, self.outputs = [], {}
        self.q, self.worker, self.cancel, self.sessions = queue.Queue(), None, threading.Event(), {}
        self._run_items, self._on_done = [], None
        self._thumbs = {}
        self.build()
        if self.s["folder"] and Path(self.s["folder"]).is_dir():
            self.set_folder(Path(self.s["folder"]))
        elif len(sys.argv) > 1 and Path(sys.argv[1]).is_dir():
            self.set_folder(Path(sys.argv[1]))
        self.after(100, self.poll)
        self.protocol("WM_DELETE_WINDOW", self.on_close)

    # ---- settings
    def load_settings(self):
        try:
            data = json.loads(SETTINGS_FILE.read_text())
        except Exception:
            data = {}
        if "profiles" not in data:  # first run, or settings from the older version
            old = {k: data[k] for k in PROFILE_KEYS if k in data}
            data = {"folder": data.get("folder", ""), "profile": BUILTIN, "profiles": {},
                    "current": {**BUILTIN_VALS, **old}}
        data.setdefault("folder", "")
        data["profiles"] = {n: {k: {**BUILTIN_VALS, **p}[k] for k in PROFILE_KEYS} for n, p in data["profiles"].items()}
        data["profiles"][BUILTIN] = dict(BUILTIN_VALS)  # built-in always restorable
        if data.get("profile") not in data["profiles"]:
            data["profile"] = BUILTIN
        cur = {**data["profiles"][data["profile"]], **data.get("current", {})}
        data["current"] = {k: cur[k] for k in PROFILE_KEYS}
        return data

    def save_settings(self):
        try:
            SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
            SETTINGS_FILE.write_text(json.dumps(self.s, indent=2))
        except Exception:
            pass

    def ui_values(self, quiet=False):
        """Settings currently shown in the window, or None if a number is invalid."""
        try:
            w, h, mu = int(self.v_w.get()), int(self.v_h.get()), float(self.v_maxup.get())
            if w < 100 or h < 100 or mu < 1:
                raise ValueError
        except ValueError:
            if not quiet:
                messagebox.showerror(APP, "Output size must be whole numbers (100 or more) and "
                                          "max enlargement must be 1 or more.")
            return None
        name = re.sub(r'[\\/:*?"<>|]', "", self.v_out.get()).strip() or OUT_NAME
        return {"width": w, "height": h, "margin": round(float(self.v_margin.get()), 1),
                "fmt": self.v_fmt.get(), "remove_bg": bool(self.v_rbg.get()),
                "allow_up": bool(self.v_up.get()), "max_up": mu, "out_name": name,
                "quality": self.v_quality.get()}

    def read_ui_settings(self, quiet=False):
        vals = self.ui_values(quiet)
        if vals is None:
            return False
        self.s["current"] = vals
        self.save_settings()
        return True

    def apply_values(self, vals):
        self._loading = True
        self.v_w.set(str(vals["width"]))
        self.v_h.set(str(vals["height"]))
        self.v_margin.set(vals["margin"])
        self.lbl_margin.config(text=f"{vals['margin']:.0f}%")
        self.v_fmt.set(vals["fmt"])
        self.v_rbg.set(vals["remove_bg"])
        self.v_up.set(vals["allow_up"])
        self.v_maxup.set(str(vals["max_up"]))
        self.v_out.set(vals["out_name"])
        self.v_quality.set(vals.get("quality", "best"))
        self._loading = False
        self.update_dirty()

    def update_dirty(self, *_):
        if getattr(self, "_loading", False) or not hasattr(self, "lbl_dirty"):
            return
        vals = self.ui_values(quiet=True)
        saved = self.s["profiles"].get(self.v_profile.get())
        dirty = vals is None or saved is None or any(vals[k] != saved.get(k) for k in PROFILE_KEYS)
        self.lbl_dirty.config(text="● unsaved" if dirty else "✓ saved")
        self.lbl_dirty.config(foreground="#b26a00" if dirty else "#2e7d32")
        self.btn_del.config(state="disabled" if self.v_profile.get() == BUILTIN else "normal")

    def refresh_profiles(self):
        names = [BUILTIN] + sorted(n for n in self.s["profiles"] if n != BUILTIN)
        self.cb_profile.config(values=names)

    def on_profile_pick(self, _=None):
        new = self.v_profile.get()
        if str(self.lbl_dirty.cget("text")).startswith("●") and not messagebox.askyesno(
                APP, f"Switch to '{new}'? Your unsaved changes to '{self.s['profile']}' will be lost."):
            self.v_profile.set(self.s["profile"])
            return
        self.s["profile"] = new
        self.apply_values(self.s["profiles"][new])
        self.read_ui_settings(quiet=True)

    def save_profile(self):
        name = self.v_profile.get()
        if name == BUILTIN:
            messagebox.showinfo(APP, f"'{BUILTIN}' can't be changed, so it's always there to go back to.\n\n"
                                     "Save your settings as a new profile instead.")
            return self.save_profile_as()
        vals = self.ui_values()
        if vals:
            self.s["profiles"][name] = vals
            self.read_ui_settings()
            self.update_dirty()
            self.v_status.set(f"Saved profile '{name}'.")

    def save_profile_as(self):
        vals = self.ui_values()
        if not vals:
            return
        from tkinter import simpledialog
        name = simpledialog.askstring(APP, "Name for this settings profile:", parent=self)
        name = (name or "").strip()
        if not name:
            return
        if name == BUILTIN:
            messagebox.showerror(APP, "That name is reserved. Pick another.")
            return
        if name in self.s["profiles"] and not messagebox.askyesno(APP, f"Replace the existing profile '{name}'?"):
            return
        self.s["profiles"][name] = vals
        self.s["profile"] = name
        self.refresh_profiles()
        self.v_profile.set(name)
        self.read_ui_settings()
        self.update_dirty()
        self.v_status.set(f"Saved profile '{name}'.")

    def delete_profile(self):
        name = self.v_profile.get()
        if name == BUILTIN or not messagebox.askyesno(APP, f"Delete the profile '{name}'?"):
            return
        del self.s["profiles"][name]
        self.s["profile"] = BUILTIN
        self.refresh_profiles()
        self.v_profile.set(BUILTIN)
        self.apply_values(self.s["profiles"][BUILTIN])
        self.read_ui_settings(quiet=True)
        self.v_status.set(f"Deleted profile '{name}'.")

    # ---- layout
    def build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista" if os.name == "nt" else "clam")
        except tk.TclError:
            pass
        style.configure("Big.TButton", font=("Segoe UI", 11, "bold"), padding=(18, 8))
        style.configure("Treeview", rowheight=26)

        top = ttk.Frame(self, padding=(12, 10, 12, 4))
        top.pack(fill="x")
        ttk.Label(top, text="Photos folder:").pack(side="left")
        self.v_folder = tk.StringVar()
        ttk.Entry(top, textvariable=self.v_folder, state="readonly").pack(side="left", fill="x", expand=True, padx=8)
        ttk.Button(top, text="Choose folder…", command=self.choose_folder).pack(side="left")
        ttk.Button(top, text="Refresh", command=lambda: self.folder and self.set_folder(self.folder)).pack(side="left", padx=(6, 0))
        ttk.Button(top, text="Open results", command=self.open_results).pack(side="left", padx=(6, 0))
        ttk.Button(top, text="Review…", command=self.review).pack(side="left", padx=(6, 0))

        # bottom bar first, so it always stays visible
        self.v_status = tk.StringVar(value="Choose a folder of photos to start.")
        ttk.Label(self, textvariable=self.v_status, padding=(12, 0, 12, 8), foreground="#444").pack(fill="x", side="bottom")
        bottom = ttk.Frame(self, padding=(12, 4, 12, 4))
        bottom.pack(fill="x", side="bottom")
        self.btn_go = ttk.Button(bottom, text="Process all", style="Big.TButton", command=self.start)
        self.btn_go.pack(side="right")
        self.btn_redo = ttk.Button(bottom, text="↻ Reprocess selected", command=self.reprocess_selected)
        self.btn_redo.pack(side="right", padx=(8, 0))
        self.btn_cancel = ttk.Button(bottom, text="Stop", command=self.cancel.set, state="disabled")
        self.btn_cancel.pack(side="right", padx=8)
        self.prog = ttk.Progressbar(bottom, mode="determinate")
        self.prog.pack(side="left", fill="x", expand=True, padx=(0, 12))

        body = ttk.Panedwindow(self, orient="horizontal")
        body.pack(fill="both", expand=True, padx=12, pady=6)

        left = ttk.Frame(body)
        body.add(left, weight=3)
        cols = ("size", "status", "detail")
        self.tree = ttk.Treeview(left, columns=cols, selectmode="extended")
        self.tree.heading("#0", text="Photo")
        self.tree.heading("size", text="Size (px)")
        self.tree.heading("status", text="Status")
        self.tree.heading("detail", text="Notes")
        self.tree.column("#0", width=240)
        self.tree.column("size", width=90, anchor="center")
        self.tree.column("status", width=110, anchor="center")
        self.tree.column("detail", width=160)
        sb = ttk.Scrollbar(left, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="left", fill="y")
        self.tree.bind("<<TreeviewSelect>>", lambda e: self.show_preview())
        self._resize_job = None
        self.tree.bind("<Double-1>", lambda e: self.open_selected_output())
        self.menu = tk.Menu(self, tearoff=0)
        self.menu.add_command(label="↻ Reprocess", command=self.reprocess_selected)
        self.menu.add_command(label="↻ Reprocess with AI (discard touch-ups)",
                              command=lambda: self.tree.selection() and self.process([Path(i) for i in self.tree.selection()], keep=False))
        self.menu.add_separator()
        self.menu.add_command(label="Review…", command=self.review)
        self.menu.add_command(label="Open finished file", command=self.open_selected_output)
        self.tree.bind("<Button-3>", self.popup)
        for tag, color in (("ok", "#e6f4ea"), ("warn", "#fff4d6"), ("bad", "#fde2e1"), ("busy", "#e3eefc")):
            self.tree.tag_configure(tag, background=color)

        right = ttk.Frame(body, padding=(10, 0, 0, 0))
        body.add(right, weight=2)
        prev = ttk.Frame(right)
        for i, title in enumerate(("Before", "After")):
            f = ttk.Frame(prev)
            f.grid(row=0, column=i, sticky="nsew", padx=4)
            ttk.Label(f, text=title, font=("Segoe UI", 10, "bold")).pack()
            lbl = tk.Label(f, bg="#d9d9d9", width=1, height=1, relief="flat")
            lbl.pack(fill="both", expand=True)
            setattr(self, "prev_" + title.lower(), lbl)
        prev.bind("<Configure>", self.on_preview_resize)
        prev.columnconfigure(0, weight=1, uniform="p")
        prev.columnconfigure(1, weight=1, uniform="p")
        prev.rowconfigure(0, weight=1)
        st = ttk.LabelFrame(right, text="Settings", padding=10)
        st.pack(fill="x", side="bottom")
        ttk.Label(right, text="Right-click photos to reprocess them. Double-click opens the finished file.", foreground="#666").pack(anchor="w", pady=(4, 6), side="bottom")
        prev.pack(fill="both", expand=True)
        cur = self.s["current"]
        r = 0
        ttk.Label(st, text="Profile:").grid(row=r, column=0, sticky="w")
        pf = ttk.Frame(st)
        pf.grid(row=r, column=1, sticky="w", pady=(0, 2))
        self.v_profile = tk.StringVar(value=self.s["profile"])
        self.cb_profile = ttk.Combobox(pf, textvariable=self.v_profile, state="readonly", width=20)
        self.cb_profile.pack(side="left")
        self.cb_profile.bind("<<ComboboxSelected>>", self.on_profile_pick)
        self.lbl_dirty = ttk.Label(pf, text="")
        self.lbl_dirty.pack(side="left", padx=(8, 0))
        r += 1
        bf = ttk.Frame(st)
        bf.grid(row=r, column=1, sticky="w", pady=(2, 8))
        ttk.Button(bf, text="Save", width=8, command=self.save_profile).pack(side="left")
        ttk.Button(bf, text="Save as new…", width=13, command=self.save_profile_as).pack(side="left", padx=(4, 0))
        self.btn_del = ttk.Button(bf, text="Delete", width=8, command=self.delete_profile)
        self.btn_del.pack(side="left", padx=(4, 0))
        r += 1
        ttk.Label(st, text="Output size:").grid(row=r, column=0, sticky="w")
        sz = ttk.Frame(st)
        sz.grid(row=r, column=1, sticky="w", pady=2)
        self.v_w, self.v_h = tk.StringVar(value=str(cur["width"])), tk.StringVar(value=str(cur["height"]))
        ttk.Entry(sz, textvariable=self.v_w, width=6).pack(side="left")
        ttk.Label(sz, text=" × ").pack(side="left")
        ttk.Entry(sz, textvariable=self.v_h, width=6).pack(side="left")

        r += 1
        ttk.Label(st, text="White margin:").grid(row=r, column=0, sticky="w")
        mf = ttk.Frame(st)
        mf.grid(row=r, column=1, sticky="we", pady=2)
        self.v_margin = tk.DoubleVar(value=cur["margin"])
        self.lbl_margin = ttk.Label(mf, width=5)
        ttk.Scale(mf, from_=0, to=15, variable=self.v_margin, length=180,
                  command=lambda v: self.lbl_margin.config(text=f"{round(float(v)):.0f}%")).pack(side="left")
        self.lbl_margin.pack(side="left", padx=6)
        self.lbl_margin.config(text=f"{cur['margin']:.0f}%")

        r += 1
        ttk.Label(st, text="Save as:").grid(row=r, column=0, sticky="w")
        ff = ttk.Frame(st)
        ff.grid(row=r, column=1, sticky="w", pady=2)
        self.v_fmt = tk.StringVar(value=cur["fmt"])
        ttk.Radiobutton(ff, text="JPG (Nordstrom preferred)", value="jpg", variable=self.v_fmt).pack(side="left")
        ttk.Radiobutton(ff, text="PNG", value="png", variable=self.v_fmt).pack(side="left", padx=8)

        r += 1
        ttk.Label(st, text="Results folder:").grid(row=r, column=0, sticky="w")
        self.v_out = tk.StringVar(value=cur["out_name"])
        ttk.Entry(st, textvariable=self.v_out, width=28).grid(row=r, column=1, sticky="w", pady=2)

        r += 1
        self.v_rbg = tk.BooleanVar(value=cur["remove_bg"])
        ttk.Checkbutton(st, text="Remove background with AI (untick if already on white)",
                        variable=self.v_rbg).grid(row=r, column=0, columnspan=2, sticky="w", pady=2)

        r += 1
        ttk.Label(st, text="Quality:").grid(row=r, column=0, sticky="w")
        qf = ttk.Frame(st)
        qf.grid(row=r, column=1, sticky="w", pady=2)
        self.v_quality = tk.StringVar(value=cur.get("quality", "best"))
        ttk.Radiobutton(qf, text="Best (cleanest edges, slower)", value="best", variable=self.v_quality).pack(side="left")
        ttk.Radiobutton(qf, text="Fast", value="fast", variable=self.v_quality).pack(side="left", padx=8)

        r += 1
        uf = ttk.Frame(st)
        uf.grid(row=r, column=0, columnspan=2, sticky="w", pady=2)
        self.v_up = tk.BooleanVar(value=cur["allow_up"])
        self.v_maxup = tk.StringVar(value=str(cur["max_up"]))
        ttk.Checkbutton(uf, text="Allow enlarging small photos, up to", variable=self.v_up).pack(side="left")
        ttk.Entry(uf, textvariable=self.v_maxup, width=5).pack(side="left", padx=4)
        ttk.Label(uf, text="×").pack(side="left")
        ttk.Label(st, text="Enlarged photos look softer, and Nordstrom's guide says they may be rejected.",
                  foreground="#8a6d00", wraplength=420).grid(row=r + 1, column=0, columnspan=2, sticky="w")

        self.refresh_profiles()
        for v in (self.v_w, self.v_h, self.v_margin, self.v_fmt, self.v_rbg, self.v_up, self.v_maxup, self.v_out, self.v_quality):
            v.trace_add("write", self.update_dirty)
        self.update_dirty()


    # ---- folder / list
    folder = None

    def choose_folder(self):
        d = filedialog.askdirectory(initialdir=self.s["folder"] or str(Path.home()))
        if d:
            self.set_folder(Path(d))

    def set_folder(self, folder):
        self.folder = folder
        self.s["folder"] = str(folder)
        self.save_settings()
        self.v_folder.set(str(folder))
        self.tree.delete(*self.tree.get_children())
        self._thumbs.clear()
        self.files = sorted(p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in EXTS)
        self.outputs = {}
        for p in self.files:
            try:
                with Image.open(p) as im:
                    w, h = ImageOps.exif_transpose(im).size if im.format != "HEIF" else im.size
                size = f"{w}×{h}"
                note = "" if max(w, h) >= 2600 else "low resolution"
            except Exception:
                size, note = "?", "can't read"
            for d in (self.s["current"]["out_name"], SMALL_NAME):
                for ext in (".jpg", ".png"):
                    o = folder / d / (p.stem + ext)
                    if o.exists():
                        self.outputs[str(p)] = o
            status = "Processed before" if str(p) in self.outputs else "Waiting"
            self.tree.insert("", "end", iid=str(p), text=p.name, values=(size, status, note),
                             tags=("warn",) if note else ())
        n = len(self.files)
        self.v_status.set(f"{n} photo(s) found." if n else "No photos in this folder.")
        if self.files:
            self.tree.selection_set(str(self.files[0]))

    def open_results(self):
        if self.folder:
            self.read_ui_settings(quiet=True)
            d = self.folder / self.s["current"]["out_name"]
            d.mkdir(exist_ok=True)
            self.open_path(d)

    def popup(self, e):
        row = self.tree.identify_row(e.y)
        if row and row not in self.tree.selection():
            self.tree.selection_set(row)
        if self.tree.selection():
            self.menu.tk_popup(e.x_root, e.y_root)

    def update_result(self, iid, status, detail, dest):
        tag = {"Done": "ok", "Done (enlarged)": "warn"}.get(status, "bad")
        if self.tree.exists(iid):
            self.tree.item(iid, values=(self.tree.set(iid, "size"), status, detail), tags=(tag,))
        if dest:
            self.outputs[iid] = dest
        self._thumbs.clear()
        self.show_preview()

    def review(self, only=None):
        ids = only if only is not None else list(self.tree.get_children())
        items = []
        for iid in ids:
            out = self.outputs.get(iid)
            if out and Path(out).exists() and self.tree.exists(iid):
                status, detail = self.tree.set(iid, "status"), self.tree.set(iid, "detail")
                tags = self.tree.item(iid, "tags")
                tag = tags[0] if tags else ("bad" if "small" in status.lower() else "ok")
                items.append({"src": iid, "out": out, "status": status, "detail": detail, "tag": tag})
        if not items:
            messagebox.showinfo(APP, "Nothing to review yet. Process some photos first.")
            return
        if getattr(self, "_review", None) and self._review.winfo_exists():
            self._review.destroy()
        sel = self.tree.selection()
        start = next((n for n, it in enumerate(items) if sel and it["src"] == sel[0]), 0) if only is None else 0
        self._review = ReviewWindow(self, items, start)

    def open_selected_output(self):
        sel = self.tree.selection()
        if sel and sel[0] in self.outputs:
            self.open_path(self.outputs[sel[0]])

    @staticmethod
    def open_path(p):
        if os.name == "nt":
            os.startfile(p)
        else:
            subprocess.Popen(["xdg-open", str(p)])

    # ---- preview
    def on_preview_resize(self, _=None):
        if self._resize_job:
            self.after_cancel(self._resize_job)
        self._resize_job = self.after(150, self.show_preview)

    def thumb(self, path, box):
        key = (str(path), box, os.path.getmtime(path))
        if key not in self._thumbs:
            im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
            im.thumbnail(box, Image.LANCZOS)
            self._thumbs[key] = ImageTk.PhotoImage(im)
        return self._thumbs[key]

    def show_preview(self):
        sel = self.tree.selection()
        if not sel:
            return
        box = (max(self.prev_before.winfo_width() - 8, 80), max(self.prev_before.winfo_height() - 8, 120))
        if len(self._thumbs) > 60:
            self._thumbs.clear()
        try:
            self.prev_before.config(image=self.thumb(sel[0], box), width=0, height=0)
        except Exception:
            self.prev_before.config(image="", text="Can't preview")
        out = self.outputs.get(sel[0])
        if out and out.exists():
            self.prev_after.config(image=self.thumb(out, box), text="", width=0, height=0)
        else:
            self.prev_after.config(image="", text="Not processed yet")

    # ---- processing
    def start(self):
        """Process every photo in the folder."""
        if not self.files:
            messagebox.showinfo(APP, "Choose a folder with photos first.")
            return
        self.process(list(self.files))

    def reprocess_selected(self):
        sel = [Path(i) for i in self.tree.selection()]
        if not sel:
            messagebox.showinfo(APP, "Select one or more photos in the list first "
                                     "(Ctrl+click or Shift+click to pick several).")
            return
        self.process(sel)

    def busy(self):
        return self.worker is not None and self.worker.is_alive()

    def process(self, files, keep=None, on_done=None):
        """Run photos through the pipeline. keep=None asks about touch-ups if any exist."""
        if self.busy():
            messagebox.showinfo(APP, "Already processing - wait for it to finish or click Stop.")
            return False
        if not self.read_ui_settings():
            return False
        if keep is None:
            edited = [p for p in files if edited_flag(self.folder, p).exists()]
            keep = True
            if edited:
                what = "this photo has" if len(files) == 1 else f"{len(edited)} of these photos have"
                ans = messagebox.askyesnocancel(APP, f"{what[0].upper() + what[1:]} hand touch-ups.\n\n"
                                                     "Yes = keep the touch-ups (just rebuild)\n"
                                                     "No = throw them away and redo with the AI")
                if ans is None:
                    return False
                keep = ans
        self.cancel.clear()
        self._run_items, self._on_done = [], on_done
        for b in (self.btn_go, self.btn_redo):
            b.config(state="disabled")
        self.btn_cancel.config(state="normal")
        self.prog.config(maximum=len(files), value=0)
        self.worker = threading.Thread(target=self.run, args=(list(files), dict(self.s["current"]), self.folder, keep), daemon=True)
        self.worker.start()
        return True

    def get_session(self, quality):
        if quality not in self.sessions:
            if quality == "best":
                self.q.put(("status", "Loading the Best-quality model (first time downloads ~1 GB)…"))
            else:
                self.q.put(("status", "Loading the Fast model (first time downloads ~180 MB)…"))
            self.sessions[quality] = make_session(quality)
        return self.sessions[quality]

    def run(self, files, s, folder, keep_edits=True):
        try:
            session = self.get_session(s.get("quality", "best")) if s["remove_bg"] else None
            if not getattr(self, "_matting_ready", False):
                self.q.put(("status", "Preparing edge tools (first time can take a minute)…"))
                import pymatting  # noqa  (first import compiles; slow once)
                self._matting_ready = True
            counts = {"ok": 0, "small": 0, "fail": 0}
            for i, p in enumerate(files, 1):
                if self.cancel.is_set():
                    self.q.put(("status", "Stopped."))
                    break
                self.q.put(("row", str(p), "Working…", "", "busy", None))
                self.q.put(("status", f"Processing {i} of {len(files)}: {p.name}"))
                try:
                    try:
                        status, detail, dest = process_one(p, folder, s, session, keep_edits)
                    except Exception as e:
                        out_of_memory = isinstance(e, MemoryError) or "alloc" in str(e).lower()
                        if s.get("quality") != "best" or not out_of_memory:
                            raise
                        self.q.put(("warn", "Not enough memory for Best quality - switching this run to Fast."))
                        s["quality"] = "fast"
                        self.sessions.pop("best", None)
                        session = self.get_session("fast")
                        status, detail, dest = process_one(p, folder, s, session, keep_edits)
                    tag = {"Done": "ok", "Done (enlarged)": "warn", "Too small": "bad"}.get(status, "bad")
                    if "touched up" in detail and tag == "ok":
                        tag = "ok"
                    counts["ok" if status.startswith("Done") else "small" if status == "Too small" else "fail"] += 1
                    self.q.put(("row", str(p), status, detail, tag, dest))
                except Exception as e:
                    counts["fail"] += 1
                    self.q.put(("row", str(p), "Failed", str(e)[:120], "bad", None))
                self.q.put(("prog", i))
            else:
                msg = f"Finished: {counts['ok']} ready in '{s['out_name']}'."
                if counts["small"]:
                    msg += f"  {counts['small']} too small (in '{SMALL_NAME}')."
                if counts["fail"]:
                    msg += f"  {counts['fail']} failed."
                self.q.put(("status", msg))
        except Exception:
            self.q.put(("error", traceback.format_exc()))
        self.q.put(("end",))

    def poll(self):
        try:
            while True:
                m = self.q.get_nowait()
                if m[0] == "status":
                    self.v_status.set(m[1])
                elif m[0] == "prog":
                    self.prog.config(value=m[1])
                elif m[0] == "row":
                    _, iid, status, detail, tag, dest = m
                    if self.tree.exists(iid):
                        size = self.tree.set(iid, "size")
                        self.tree.item(iid, values=(size, status, detail), tags=(tag,))
                        if dest:
                            self.outputs[iid] = dest
                        if tag != "busy":
                            self._run_items.append(iid)
                        if tag == "busy":
                            self.tree.see(iid)
                        if self.tree.selection() and self.tree.selection()[0] == iid:
                            self.show_preview()
                elif m[0] == "warn":
                    messagebox.showwarning(APP, m[1])
                elif m[0] == "error":
                    messagebox.showerror(APP, m[1][-1500:])
                elif m[0] == "end":
                    for b in (self.btn_go, self.btn_redo):
                        b.config(state="normal")
                    self.btn_cancel.config(state="disabled")
                    done, self._on_done = self._on_done, None
                    if done:
                        done()
                    elif any(i in self.outputs for i in self._run_items):
                        self.review(only=self._run_items)
        except queue.Empty:
            pass
        self.after(100, self.poll)

    def on_close(self):
        self.read_ui_settings(quiet=True)
        self.cancel.set()
        self.destroy()


if __name__ == "__main__":
    try:
        App().mainloop()
    except Exception:
        if os.name == "nt":
            try:
                import ctypes
                ctypes.windll.user32.ShowWindow(ctypes.windll.kernel32.GetConsoleWindow(), 5)
            except Exception:
                pass
        traceback.print_exc()
        sys.exit(1)
