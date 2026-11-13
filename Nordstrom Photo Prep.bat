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
                "allow_up": False, "max_up": 1.25, "out_name": OUT_NAME}
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


def cutout_from_white(img, tol=12):
    from PIL import ImageChops
    diff = ImageChops.difference(img.convert("RGB"), Image.new("RGB", img.size, "white")).convert("L")
    out = img.convert("RGBA")
    out.putalpha(diff.point(lambda v: 255 if v > tol else 0))
    return out


def process_one(path, folder, s, session):
    """Returns (status, detail, output_path)."""
    W, H, margin = s["width"], s["height"], s["margin"] / 100
    img = ImageOps.exif_transpose(Image.open(path))
    img = to_srgb(img.convert("RGB"))
    if s["remove_bg"]:
        from rembg import remove
        cut = remove(img.convert("RGBA"), session=session, post_process_mask=True)
    else:
        cut = cutout_from_white(img)
    bbox = cut.getchannel("A").point(lambda a: 255 if a > 10 else 0).getbbox()
    if not bbox:
        return "No product found", "", None
    cut = cut.crop(bbox)
    scale = min(W * (1 - 2 * margin) / cut.width, H * (1 - 2 * margin) / cut.height)

    dest_dir, status, detail = folder / s["out_name"], "Done", ""
    if scale > 1.02:
        if s["allow_up"] and scale <= s["max_up"]:
            status, detail = "Done (enlarged)", f"enlarged {scale:.2f}x"
        else:
            dest_dir, status, detail = folder / SMALL_NAME, "Too small", f"needs {scale:.2f}x enlargement"
    dest_dir.mkdir(exist_ok=True)

    cut = cut.resize((round(cut.width * scale), round(cut.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGB", (W, H), (255, 255, 255))
    canvas.paste(cut, ((W - cut.width) // 2, (H - cut.height) // 2), cut)

    if s["fmt"] == "png":
        dest = dest_dir / f"{path.stem}.png"
        canvas.save(dest, dpi=(300, 300), icc_profile=SRGB_BYTES, optimize=True)
    else:
        dest = dest_dir / f"{path.stem}.jpg"
        for q in (100, 95, 92):
            canvas.save(dest, quality=q, subsampling=0, dpi=(300, 300), icc_profile=SRGB_BYTES)
            if dest.stat().st_size < MAX_MB * 1024 * 1024:
                break
    if not NAME_OK.match(path.stem):
        detail = (detail + "; " if detail else "") + "name not Brand_VPN_Color"
    return status, detail, dest


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
        self.q, self.worker, self.cancel, self.session = queue.Queue(), None, threading.Event(), None
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
        data["profiles"][BUILTIN] = dict(BUILTIN_VALS)  # built-in always restorable
        if data.get("profile") not in data["profiles"]:
            data["profile"] = BUILTIN
        data["current"] = {**data["profiles"][data["profile"]], **data.get("current", {})}
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
                "allow_up": bool(self.v_up.get()), "max_up": mu, "out_name": name}

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

        # bottom bar first, so it always stays visible
        self.v_status = tk.StringVar(value="Choose a folder of photos to start.")
        ttk.Label(self, textvariable=self.v_status, padding=(12, 0, 12, 8), foreground="#444").pack(fill="x", side="bottom")
        bottom = ttk.Frame(self, padding=(12, 4, 12, 4))
        bottom.pack(fill="x", side="bottom")
        self.btn_go = ttk.Button(bottom, text="Process photos", style="Big.TButton", command=self.start)
        self.btn_go.pack(side="right")
        self.btn_cancel = ttk.Button(bottom, text="Stop", command=self.cancel.set, state="disabled")
        self.btn_cancel.pack(side="right", padx=8)
        self.prog = ttk.Progressbar(bottom, mode="determinate")
        self.prog.pack(side="left", fill="x", expand=True, padx=(0, 12))

        body = ttk.Panedwindow(self, orient="horizontal")
        body.pack(fill="both", expand=True, padx=12, pady=6)

        left = ttk.Frame(body)
        body.add(left, weight=3)
        cols = ("size", "status", "detail")
        self.tree = ttk.Treeview(left, columns=cols, selectmode="browse")
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
        ttk.Label(right, text="Double-click a photo to open the finished file.", foreground="#666").pack(anchor="w", pady=(4, 6), side="bottom")
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
        for v in (self.v_w, self.v_h, self.v_margin, self.v_fmt, self.v_rbg, self.v_up, self.v_maxup, self.v_out):
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
        if not self.files:
            messagebox.showinfo(APP, "Choose a folder with photos first.")
            return
        if not self.read_ui_settings():
            return
        self.cancel.clear()
        self.btn_go.config(state="disabled")
        self.btn_cancel.config(state="normal")
        self.prog.config(maximum=len(self.files), value=0)
        self.worker = threading.Thread(target=self.run, args=(list(self.files), dict(self.s["current"]), self.folder), daemon=True)
        self.worker.start()

    def run(self, files, s, folder):
        try:
            if s["remove_bg"] and self.session is None:
                self.q.put(("status", "Loading the AI model (first time downloads ~180 MB)…"))
                from rembg import new_session
                self.session = new_session("isnet-general-use")
            counts = {"ok": 0, "small": 0, "fail": 0}
            for i, p in enumerate(files, 1):
                if self.cancel.is_set():
                    self.q.put(("status", "Stopped."))
                    break
                self.q.put(("row", str(p), "Working…", "", "busy", None))
                self.q.put(("status", f"Processing {i} of {len(files)}: {p.name}"))
                try:
                    status, detail, dest = process_one(p, folder, s, self.session)
                    tag = {"Done": "ok", "Done (enlarged)": "warn", "Too small": "bad"}.get(status, "bad")
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
                        if tag == "busy":
                            self.tree.see(iid)
                        if self.tree.selection() and self.tree.selection()[0] == iid:
                            self.show_preview()
                elif m[0] == "error":
                    messagebox.showerror(APP, m[1][-1500:])
                elif m[0] == "end":
                    self.btn_go.config(state="normal")
                    self.btn_cancel.config(state="disabled")
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
