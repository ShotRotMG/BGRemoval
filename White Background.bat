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
FINE_EDGES = True      # better edges on fur, hair and soft shadows (a few seconds slower per photo)

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

MATTE_MAX_PX = 3_000_000   # edge refinement resolution cap (keeps memory around 2-3 GB)


def fine_cutout(img, session, W, H, margin):
    """img: full-res RGB. Returns (RGBA cutout at final scale, scale) or (None, None)."""
    mask = remove(img, session=session, only_mask=True, post_process_mask=True)
    bbox = mask.point(lambda a: 255 if a > 40 else 0).getbbox()
    if not bbox:
        return None, None
    l, t, r, b = bbox
    scale = min(W * (1 - 2 * margin) / (r - l), H * (1 - 2 * margin) / (b - t))
    pad = int(0.04 * max(r - l, b - t))
    box = (max(l - pad, 0), max(t - pad, 0), min(r + pad, img.width), min(b + pad, img.height))
    crop = img.crop(box)
    crop = crop.resize((round(crop.width * scale), round(crop.height * scale)), Image.LANCZOS)

    # refine edges (fur, hair, shadows) at a capped resolution
    k = min(1.0, (MATTE_MAX_PX / (crop.width * crop.height)) ** 0.5)
    small = crop if k == 1 else crop.resize((round(crop.width * k), round(crop.height * k)), Image.LANCZOS)
    cut = remove(small, session=session, alpha_matting=True,
                 alpha_matting_foreground_threshold=240, alpha_matting_background_threshold=20,
                 alpha_matting_erode_size=max(5, round(15 * k)))
    if k != 1:
        cut = cut.resize(crop.size, Image.BICUBIC)
    a = np.asarray(cut).astype(np.float32)
    lum = a[..., :3] @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    alpha = a[..., 3]
    alpha[(alpha < 150) & (lum > 165)] = 0      # faint shadow haze -> clean white
    alpha[alpha < 8] = 0
    out = crop.convert("RGBA")
    out.putalpha(Image.fromarray(np.clip(alpha, 0, 255).astype(np.uint8), "L"))
    return out, scale

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
print("Loading background-removal model (first run downloads ~180 MB)...")
session = new_session("isnet-general-use")

ok, too_small, bad_names = 0, [], []
for i, f in enumerate(files, 1):
    print(f"[{i}/{len(files)}] {f.name}", end=" ... ", flush=True)
    try:
        img = ImageOps.exif_transpose(Image.open(f))
        img = to_srgb(img.convert("RGB")).convert("RGBA")
        pre = 1.0
        if FINE_EDGES:
            cut, pre = fine_cutout(img.convert("RGB"), session, W, H, MARGIN)
        else:
            cut = remove(img, session=session, post_process_mask=True)
        bbox = cut.getchannel("A").point(lambda a: 255 if a > 10 else 0).getbbox() if cut else None
        if not bbox:
            print("no product found, skipped")
            continue
        cut = cut.crop(bbox)
        fit = min(W * (1 - 2 * MARGIN) / cut.width, H * (1 - 2 * MARGIN) / cut.height)
        scale = pre * fit
        dest_dir = out
        if scale > 1.02:   # would need enlarging -> Nordstrom rejects upscaled images
            small.mkdir(exist_ok=True)
            dest_dir = small
            too_small.append(f"{f.name} (needs {scale:.1f}x enlargement)")
        cut = cut.resize((min(W, round(cut.width * fit)), min(H, round(cut.height * fit))), Image.LANCZOS)
        canvas = Image.new("RGB", (W, H), (255, 255, 255))
        canvas.paste(cut, ((W - cut.width) // 2, (H - cut.height) // 2), cut)
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
