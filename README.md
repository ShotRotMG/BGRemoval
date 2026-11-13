# BGRemoval

Windows tools that turn product photos into Nordstrom-ready shoe images: pure white background, product centered, 2640 × 4048, max-quality JPG. Background removal runs locally with AI ([rembg](https://github.com/danielgatis/rembg)), so nothing is uploaded.

## Tools

| File | What it is |
|---|---|
| `Nordstrom Photo Prep.bat` | Desktop app with a window: pick a folder, see each photo's status, before/after preview, settings, progress bar. |
| `White Background.bat` | No-window version. Drop it into a folder of photos and double-click. |

Both are single files: Windows runs the first line as a batch command, which launches Python on the rest of the file.

## Setup

Just double-click either file.

- If Python isn't installed, it installs Python 3.12 with `winget`. Close the window and double-click again when it finishes.
- The first run installs the Python packages (`rembg[cpu]`, `pillow`, `pillow-heif`) and downloads the AI model (~180 MB). After that it starts right away.

## What it does to each photo

1. Removes the background (or, optionally, detects the product against an existing white background)
2. Converts colors to sRGB (iPhone photos are Display P3)
3. Trims to the product and scales it to fit the frame with an even white margin
4. Centers it on a pure white (RGB 255) 2640 × 4048 canvas
5. Saves a max-quality JPG under 20 MB into a `White Background` subfolder

Originals are never changed. Supported: JPG, PNG, HEIC, WEBP, TIFF, BMP.

### Reviewing results

When a batch finishes, a review window opens so you can check each finished photo one at a time:

- **◀ Previous / Next ▶** or the arrow keys move between photos; Home/End jump to first/last
- **After / Before / Side by side** views; **Space** flips between before and after
- **Only show problems** skips to photos that were too small, enlarged, or have a naming warning
- **Open file** and **Show in folder** for the current photo

Open it any time with the **Review…** button; it starts at the photo selected in the list.

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
