@echo off & title White Background & (where py >nul 2>&1 || (echo Python is not installed - installing it now... & winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements & echo. & echo Done. Close this window and double-click the file again. & pause & exit /b)) & py -u -x "%~f0" %* & pause & exit /b
# ---------------------------------------------------------------------------
# Everything below is Python. Drop this .bat into a folder of photos and
# double-click it (or drag a folder onto it).
#
# Built to Nordstrom's vendor image specs for shoes:
#   - 2640 x 4048 portrait (Nordstrom's in-house size, 2:3 crop)
#   - pure white background, RGB 255
#   - product centered, whole item in frame (never cropped into)
#   - NEVER enlarged: photos too small to fill the frame without upscaling
#     go to a "Too small - reshoot" folder instead (Nordstrom rejects
#     upscaled images)
#   - sRGB JPG at max quality, well under 20 MB
#   - warns if the file name isn't Brand Name_VPN_Color.jpg
# Your original photos are never changed.
# ---------------------------------------------------------------------------
W, H = 2640, 4048      # output size in pixels
MARGIN = 0.06          # white space on each side (0.06 = 6%); lower = bigger product
OUT_NAME = "White Background"
SMALL_NAME = "Too small - reshoot"
MAX_MB = 20
QUALITY = "best"       # "best" = cleanest edges (BiRefNet, ~1 GB download, slower); "fast" = quicker, rougher edges

import io, re, subprocess, sys
from pathlib import Path
print("Starting... loading the background-removal tools.")
print("The first run can sit here quietly for 1-3 minutes while they set up - that is normal.\n", flush=True)


def ensure(pkgs, test):
    try:
        test()
    except ImportError:
        print("First run: installing tools (one time only, a few minutes)...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", *pkgs])


def _t1():
    import rembg, onnxruntime, PIL, pillow_heif  # noqa


ensure(["rembg[cpu]", "pillow", "pillow-heif"], _t1)

import pillow_heif
from PIL import Image, ImageCms, ImageOps
from rembg import new_session, remove

pillow_heif.register_heif_opener()  # lets it read iPhone .HEIC photos
import numpy as np

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



EXTS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".bmp", ".tif", ".tiff"}
NAME_OK = re.compile(r"^[^_]+_[^_]+_[^_]+$")   # Brand Name_VPN_Color
SRGB = ImageCms.createProfile("sRGB")
SRGB_BYTES = ImageCms.ImageCmsProfile(SRGB).tobytes()


def to_srgb(img):
    """iPhones shoot in Display P3; convert so colors look right on Nordstrom's site."""
    icc = img.info.get("icc_profile")
    if not icc:
        return img
    try:
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        mode = "RGBA" if "A" in img.getbands() else "RGB"
        return ImageCms.profileToProfile(img, src, SRGB, outputMode=mode)
    except Exception:
        return img


src = Path(sys.argv[1]) if len(sys.argv) > 1 and Path(sys.argv[1]).is_dir() else Path(__file__).resolve().parent
out, small = src / OUT_NAME, src / SMALL_NAME
files = sorted(p for p in src.iterdir() if p.is_file() and p.suffix.lower() in EXTS)
if not files:
    print(f"No photos found in {src}")
    sys.exit()
out.mkdir(exist_ok=True)

print(f"Processing {len(files)} photo(s) in {src}")
print("Loading background-removal model...")
print("(Best quality downloads ~1 GB the first time.)" if QUALITY == "best" else "")
session = make_session(QUALITY)

ok, too_small, bad_names = 0, [], []
for i, f in enumerate(files, 1):
    print(f"[{i}/{len(files)}] {f.name}", end=" ... ", flush=True)
    try:
        img = ImageOps.exif_transpose(Image.open(f))
        img = to_srgb(img.convert("RGB")).convert("RGB")
        mask = remove(img, session=session, only_mask=True, post_process_mask=(QUALITY == "fast"))
        canvas, scale = compose(img, mask, W, H, MARGIN)
        if canvas is None:
            print("no product found, skipped")
            continue
        dest_dir = out
        if scale > 1.02:   # would need enlarging -> Nordstrom rejects upscaled images
            small.mkdir(exist_ok=True)
            dest_dir = small
            too_small.append(f"{f.name} (needs {scale:.1f}x enlargement)")
        dest = dest_dir / f"{f.stem}.jpg"
        for q in (100, 95, 92):
            canvas.save(dest, quality=q, subsampling=0, dpi=(300, 300), icc_profile=SRGB_BYTES)
            if dest.stat().st_size < MAX_MB * 1024 * 1024:
                break
        if not NAME_OK.match(f.stem):
            bad_names.append(f.name)
        print("TOO SMALL - see list below" if dest_dir is small else "done")
        if dest_dir is out:
            ok += 1
    except Exception as e:
        print(f"FAILED: {e}")

print(f"\nFinished: {ok} ready for Nordstrom in '{OUT_NAME}'")
if too_small:
    print(f"\n{len(too_small)} photo(s) are too small - Nordstrom rejects enlarged images.")
    print(f"Use the original full-size camera photo instead. (Saved in '{SMALL_NAME}' for reference only.)")
    for t in too_small:
        print("   -", t)
if bad_names:
    print("\nRename these to Nordstrom's format  Brand Name_VPN_Color.jpg  (e.g. Leith_TL351309MI_Blue.jpg):")
    for n in bad_names:
        print("   -", n)
print("\nStill check by eye: whole shoe visible, single shoe (not a pair), clean edges, no text or logos added.")
