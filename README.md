# BGRemoval

Windows tools that turn product photos into Nordstrom-ready shoe images: pure white background, product centered, 2640 × 4048, max-quality JPG. Background removal runs locally with AI ([rembg](https://github.com/danielgatis/rembg)), so nothing is uploaded.

## Tools

| File | What it is |
|---|---|
| `Visual Photo Prep.bat` | Desktop app with a window: pick a folder, see each photo's status, before/after preview, settings, progress bar. |
| `Photo Prep.bat` | No-window version. Drop it into a folder of photos and double-click. |

Both are single files: Windows runs the first line as a batch command, which launches Python on the rest of the file.

## Setup

Just double-click either file.

- If Python isn't installed, it installs Python 3.12 with `winget`. Close the window and double-click again when it finishes.
- The first run installs the Python packages (`rembg[cpu]`, `pillow`, `pillow-heif`) and downloads the AI model (~180 MB). After that it starts right away.

## What it does to each photo

1. Removes the background (or, optionally, detects the product against an existing white background)
2. Converts colors to sRGB (iPhone photos are Display P3)
3. Finds the product with AI and scales it to fit the frame with an even white margin
4. Centers it on a pure white (RGB 255) 2640 × 4048 canvas
5. Saves a max-quality JPG under 20 MB into a `White Background` subfolder

**Quality.** *Best* (the default) uses the BiRefNet AI model, which gives the cleanest edges on fur, light soles against a light backdrop, and the gaps between tread lugs, and doesn't keep shadows as part of the shoe. It also runs the Fast model as a cross-check: white parts BiRefNet can miss on a light backdrop (white toe caps, rubber sidewalls) are added back when the Fast model is confident about them and they aren't shadows. It's a ~1 GB one-time download, takes roughly 10–50 seconds per photo depending on your PC, and needs about 6 GB of free memory; if memory runs out, the app switches that run to Fast. *Fast* uses a smaller model (a few seconds per photo) with rougher edges. Either way, edges are cleaned of background color and tightened by 1 px so the background is pure white. Set it in the app's settings, or with `QUALITY = "best"` / `"fast"` near the top of `Photo Prep.bat`.

Originals are never changed. Supported: JPG, PNG, HEIC, WEBP, TIFF, BMP.

### Reprocessing

- **Process all** runs every photo in the folder.
- **↻ Reprocess selected** runs only the photos you've selected in the list (Ctrl+click or Shift+click to pick several) — handy after changing a setting, or to retry one photo.
- **Right-click** photos in the list for Reprocess, Reprocess with AI (discarding touch-ups), Review and Open finished file.
- In the review window, **↻ Reprocess** (or **P**) reruns the photo you're looking at and shows the new result.

If a photo has hand touch-ups, you're asked whether to keep them or redo it with the AI.

### Speed

The **Time** column shows how long each photo took, and the status bar shows elapsed time and an estimate of what's left. Click a finished photo to see where its time went (loading, each AI model, combining, edge cleanup, saving). Every run also adds a line per photo to `.photoprep/timings.csv` in the photos folder, so slow steps can be tracked down.

### Reviewing results

When a batch finishes, a review window opens so you can check each finished photo one at a time:

- **◀ Previous / Next ▶** or the arrow keys move between photos; Home/End jump to first/last
- **After / Before / Side by side** views; **Space** flips between before and after
- **Only show problems** skips to photos that were too small, enlarged, or have a naming warning
- **Open file** and **Show in folder** for the current photo

Open it any time with the **Review…** button; it starts at the photo selected in the list.

### Touching up by hand

For anything the AI gets wrong, click **✎ Touch up…** in the review window (or press **T**):

- **Erase (E)** paints away background the AI kept (shadows, bits of the floor); **Restore (R)** paints back parts of the shoe it cut off
- **Heal (H)** removes wear on samples (scuffs, dirt, stains, creasing on white outsoles and socks): paint over the mark and AI fills it in to match the surrounding material. Uses the [LaMa](https://github.com/advimman/lama) inpainting model (Apache-2.0, ~208 MB one-time download, checksum-verified). Heal small areas at a time and zoom in for best results; check that logos, stitching and tread patterns stay intact so the photo still shows the real product
- **Brush** size (or **[** / **]**) and **Softness** for feathered edges
- **Mouse wheel** zooms at the cursor; **right-drag** (or Space+drag) pans; **Fit** and **100%** buttons
- **Show removed in red** highlights everything that's been cut away, so holes and leftovers are easy to spot
- **✨ Heal all wear (auto)** finds dark marks on light areas (dirt, specks, scuffs on white outsoles and socks) and heals them all in one go. **Strength** (Gentle / Normal / Strong) controls how much it picks up. It skips thin lines (stitching, tread grooves) and the outline, so expect to finish a few marks with the Heal brush. **Show healed in green** (or **G**) highlights every pixel that was changed; one Undo takes the whole pass back
- **Ctrl+Z / Ctrl+Y** undo and redo; **Reset to AI result** throws the touch-ups away
- **Save** (Ctrl+S) rebuilds the finished image with the same size, centering and edge cleanup

Touched-up photos are marked "touched up". When you process a folder again, the app asks whether to keep the touch-ups (fast — no AI needed) or redo everything with the AI. Touch-up data (edited cut-outs and healed pixels) lives in a hidden `.photoprep` folder inside your photos folder.

### Settings profiles

The app's settings (output size, white margin, JPG/PNG, results folder name, AI background removal, enlargement limit) can be saved as named profiles:

- **Nordstrom (default)** is built in and can't be changed, so you can always go back to the Nordstrom specs.
- **Save as new…** saves the current settings under a new name. **Save** updates the selected profile; **Delete** removes it.
- "● unsaved" next to the profile means the settings on screen differ from the saved profile.
- Give each profile its own **Results folder** name so different setups don't overwrite each other's output.

The app also remembers your last folder and the settings on screen when you close it. Everything is stored in `%APPDATA%\NordstromPhotoPrep\settings.json`, outside the repo.

### Too-small photos

Nordstrom's guide says not to enlarge smaller images to meet size requirements. A photo that would need enlarging goes to a `Too small - reshoot` subfolder instead. In the app, **Allow enlarging small photos** lets you permit small enlargements (default limit 1.25×).

## Nordstrom image specs (shoes)

From [Nordstrom's vendor image requirements](https://vendorassetacquisition.helpscoutdocs.com/article/84-specific-image-requirements-shoes):

- Portrait 2:3, recommended 2600 × 4000 or larger (Nordstrom's in-house size is 2640 × 4048)
- White background, RGB 255
- JPG preferred, 20 MB max
- File name: `Brand Name_VPN_Color.jpg` (e.g. `Leith_TL351309MI_Blue.jpg`)
- Required views: front angle, back angle, side, front, top, bottom
- Single shoe, not a pair; whole item in frame; photos only, no added text or logos

The tools warn when a file name doesn't match the naming format. Shot angles, direction and styling are up to you.

## License

MIT — see [LICENSE](LICENSE).
