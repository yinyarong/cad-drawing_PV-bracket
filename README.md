# AutoCAD AutoLISP Tools for PV Bracket Structural Drawings

![AutoLISP](https://img.shields.io/badge/AutoLISP-AutoCAD-blue)
![Platform](https://img.shields.io/badge/platform-AutoCAD%202018%2B-lightgrey)
![Language](https://img.shields.io/badge/language-AutoLISP%20%2F%20Visual%20LISP-orange)

## Overview

A set of three AutoLISP scripts that automate structural engineering drawing tasks for photovoltaic (PV) bracket systems in AutoCAD. `PVRect_Singsun.lsp` generates plan / elevation drawings and the 3D analysis model from a dialog-driven parameter set, `YYR.lsp` provides lightweight utilities for cross-section and dimension annotation, and `Mymodel.lsp` automates 3D model assembly and DXF export by reading parameters from an Excel spreadsheet.

## Features

- **Dialog-driven PV array generation** — enter panel dimensions, row/column counts, bracket spacing, clearance, and tilt angle; full engineering drawing is generated automatically
- **Plan / Elevation / MyModel output** — radio buttons at the top of the dialog pick one output; OK generates the plan view, the elevation view of the selected Type, or the 3D model
- **Excel parameter import** — reads defaults from the most recently modified `.xls*` file in the working directory (`~$` lock files skipped); auto-detects Eurocode (V1.2/EN1990) and ASCE load templates
- **Multiple elevation types** — C-post, O-post, and C-post-single cross-section views with correctly scaled geometry
- **Structural cross-section tools** — brace and C-post rectangle pairs generated perpendicular to any selected LINE
- **Aligned dimension annotation** — `DIMALIGNED` labels placed below selected lines with TSSD-compatible styles and automatic scale-based offsets
- **3D model assembly** — rotates geometry, builds full-length purlins, copies frames along Y (edge spans `zd-e` and middle spans `zd` may differ, optional east-west slope), then exports to DXF R2010
- **Error handling** — `*error*` handler restores OSMODE / CMDECHO / current layer / hidden layers on failure or Esc
- **Automatic layer management** — all required layers created on demand; post-processing cleans up unused layers and purges the drawing
- **Dynamic DCL dialogs** — DCL content written to a temp file at runtime; no separate `.dcl` file required

## How It Works

### PVRect_Singsun.lsp

1. **Excel import** — `PVRectSgs_ReadExcelDefaults` opens the newest Excel/WPS file in the current directory via COM automation and populates dialog defaults (a user's already-open Excel window is left untouched)
2. **Dialog** — `c:PVRect_Singsun` presents a DCL dialog for parameter entry and validation
3. **Drawing generation** — the script builds all geometry (PV panels, purlins, beams, axes, dimensions, elevation views, nut blocks) using `entmake` calls at a 1:5 scale (CAD units = mm × 2)
4. **Post-processing** — `PVRectSgs_PostFix` (called via `c:ZHWBZH_Singsun` / `vla-SendCommand`) generates sub-detail views, segmented horizontal dimensions, and side elevation labels

### YYR.lsp

The main `YYR` command opens a dialog to select a sub-function. Each sub-function prompts for a LINE selection, computes perpendicular geometry using `polar` + `angle`, and creates entities via `entmake`.

### Mymodel.lsp

`MyModel` runs a fixed six-step pipeline without user interaction after launch: 3D rotation → Excel read → purlin adjustment → row copy → layer cleanup → DXF export. The whole run is wrapped in one undo mark.

The same pipeline is also built into `PVRect_Singsun.lsp` (`PVRectSgs_MyModel`): select **MyModel** in the dialog and the parameters come from the dialog instead of Excel.

## Prerequisites

- **AutoCAD** with AutoLISP and DCL support (2018 or later recommended)
- **Visual LISP / VLA** — `(vl-load-com)` is called at load time; included in all full AutoCAD releases
- **Microsoft Excel or WPS Office** (COM automation) — required for Excel import in `PVRect_Singsun.lsp` and `Mymodel.lsp`
- **TSSD structural CAD plugin** — required for `TSSD_xx_100` dimension styles in `YYR.lsp` and `PVRect_Singsun.lsp`; scripts fall back to the current dimension style if TSSD is not loaded

## Installation

No build step required. AutoLISP files are interpreted directly by AutoCAD.

**Option A — drag and drop**

Drag any `.lsp` file onto an open AutoCAD window. When prompted, click **Always Load** or **Add to Trusted Paths**.

**Option B — APPLOAD**

```
Command: APPLOAD
```

Browse to the file, click **Load**.

**Option C — inline load**

```lisp
(load "PVRect_Singsun.lsp")
(load "YYR.lsp")
(load "Mymodel.lsp")
```

## Configuration

### PVRect_Singsun parameters (dialog fields)

| Parameter | Description | Default |
|-----------|-------------|---------|
| Output | Plan view / Elevation view / MyModel (only one) | Plan view |
| Type | Elevation type: C-post-double / O-post / C-post-single (elevation only) | C-post-double |
| `h` / `w` | PV panel height / width (mm) | 2382 / 1134 |
| `n` / `m` | Row count / column count | 2 / 12 |
| `hole` | Hole spacing (mm) | 1400 |
| `nop` | Purlins per PV panel (fixed, not in the dialog) | 2 |
| `zn` | Number of brackets | 3 |
| `zd` / `zd-e` | Middle-span / end-span bracket spacing (mm) | 3800 / 3800 |
| `clearance` | Ground clearance below PV panel (mm) | 400 |
| `angle` | Panel tilt angle (°) | 20 |
| `post_w` / `post_d` | C-post width / O-post diameter (mm, elevation only) | 80 / 60 |
| `purlin_H` | Purlin bracket height in elevation (mm) | 80 |
| `beam_H` | Beam section height in elevation (mm) | 100 |
| E-W Slope | East-west slope for MyModel (°); purlins tilt along their length, along-slope spacing stays `zd` / `zd-e` | 0 |

### Excel files

Both scripts look for Excel files in the folder of the current (saved) drawing. When several exist, the most recently modified one is used and `~$` lock files are ignored.

**PVRect_Singsun — dialog defaults (Import Excel)** are read from the `数据填写` sheet. Eurocode mode is detected from "V1.2" in the file name or "EN1990" in the sheet header; otherwise ASCE mode is assumed.

**Mymodel.lsp (standalone)** reads the `阵列计算` sheet:

| Cell | Variable | Description |
|------|----------|-------------|
| C13 | `dist_total` | Purlin length |
| C14 | `spacing` | Frame-to-frame spacing (uniform) |
| C15 | `rowCount` | Number of frame copies (rounded to an integer) |
| C16 | `dist1` | Distance from the original frame to the purlin's +Y end (0 ~ C13) |

MyModel inside `PVRect_Singsun` does not read Excel; see [MyModel from the dialog](#mymodel-from-the-pvrect_singsun-dialog).

### Layer system (PVRect_Singsun)

| Layer | Color | Usage |
|-------|-------|-------|
| `AXIS` | Red | Axis lines, block inserts |
| `purlin` | Green | Purlin elements |
| `beam` | Yellow / Cyan | Beam and post cross-sections |
| `PV` | White | PV panel outlines |
| `DIM` | White | Dimension entities |
| `NUM` | White | Numbering text |
| `LTPJJ` | Yellow | Lower-tier details |
| `STPM_SBEAM_THICK` | White | Thick beam lines |
| `01Purlin-01up` / `01Purlin-01down` | Green | Elevation reduced copy: purlin-bracket axis lines of the right half, split by height (higher half → `up`, lower half → `down`; with an odd count the middle line goes to `up`; at 0° tilt split by X) |
| `01Purlin-02up` / `01Purlin-02down` | Green | Same for the left half |
| `02Beam` | Cyan | Elevation reduced copy: beam axis |
| `03Brace` | Red | Elevation reduced copy: brace axes |
| `04Column` | White | Elevation reduced copy: post axes |

## Usage

### PVRect_Singsun — generate a PV bracket array drawing

```
Command: PVRect_Singsun
```

The dialog opens. Choose **Plan view**, **Elevation view** or **MyModel** at the top, fill in panel dimensions, layout counts, and structural parameters, then click **OK**. Plan / elevation output calls `ZHWBZH_Singsun` automatically for post-processing; MyModel builds the 3D model in the current drawing and saves a `.dxf`.

| Output | Result |
|--------|--------|
| Plan view | Array layout (panels, purlins, axes, dimensions). Type / Clearance / Beam H / Purlin H / post size are disabled |
| Elevation view | Side elevation of the selected Type (C-post-double / O-post / C-post-single), plus a reduced copy of the member axes at real (mm) size on layers `01Purlin-01up/down`, `01Purlin-02up/down`, `02Beam`, `03Brace`, `04Column` |
| MyModel | 3D analysis model + DXF export, see below |

Command, function and global names use `_Singsun` / `PVRectSgs_` / `*sg_`, so this file can be loaded alongside other PVRect variants. The old `PVRect` command name no longer exists.

#### MyModel from the PVRect_Singsun dialog

Only `w`, `m`, `zn`, `zd`, `zd-e` and **E-W Slope** are used; everything else is disabled. The current drawing must be saved and contain the member axis lines (e.g. the reduced copy from Elevation view). Layers are classified by name:

| Layer | Treated as |
|-------|------------|
| Name contains `Purlin` (any case) | **Purlin** — each LINE / polyline is replaced by a full-length purlin on the same layer |
| Any other layer | **Frame** — every curve (line, arc, circle, ellipse, polyline, spline) is copied to each frame position on the same layer |

- Purlin length `L = m·w + (m−1)·20 + 2·75`
- Frame offsets match the plan view: `zn = 1` → one frame; `zn = 2` → one span `zd-e`; `zn ≥ 3` → end spans `zd-e`, middle spans `zd`
- Frames are centred on the purlin: +Y overhang `= (L − total span) / 2`
- E-W Slope tilts the purlins along their length; spacings `zd` / `zd-e` are measured along the slope. A positive slope makes frames lower towards −Y

Steps: rotate all model-space objects 90° about X → build full-length purlins from lines on `*Purlin*` layers → copy the curves on all other layers to every frame → erase objects on layers without curves (text / dimension / hatch / block-only layers) and PURGE → save `<drawing-name>.dxf` next to the drawing. Every layer that holds curves is kept; layer names are compared exactly, so names containing `#`, `@`, `.`, `*` etc. no longer match other layers.

> MyModel rotates **everything** in model space and treats every non-Purlin curve as part of the frame, so other drawings (plan, full elevation) left in the file are copied into the model too. Run it on a drawing that holds only the model lines, or a copy. Block references are not curves: explode them first if their layers must survive. Running it twice on the same drawing asks for confirmation, because it would rotate another 90°.

### YYR — structural cross-section and label toolkit

```
Command: YYR
```

Select **Brace**, **C-Post**, or **Label** from the dialog.

- **Brace / C-Post** — enter `param` (integer), then select one or more LINE entities. Two concentric closed polylines are drawn perpendicular to each line.
- **Label** — select a scale (20 / 50 / 100), then select a LINE. A `DIMALIGNED` dimension is placed below it.

### Mymodel — 3D model assembly and DXF export

Save the target `.dwg` and place an Excel file (`.xls*`) with a `阵列计算` sheet in the same directory, then:

```
Command: MyModel
```

The script runs all six steps automatically and saves a `.dxf` file with the same base name as the drawing. Frames are copied at a uniform spacing (C14); use the PVRect_Singsun dialog when end spans differ from middle spans or an E-W slope is needed.

## Examples

### Example 1 — 2-row × 12-column PV array, 20° tilt

Open a blank AutoCAD drawing, load `PVRect_Singsun.lsp`, type `PVRect_Singsun`, and enter:

```
h = 2382, w = 1134, n = 2, m = 12, angle = 20, clearance = 400
zn = 3, zd = 3800, zd-e = 3800, purlin_H = 80, beam_H = 100
```

- **Plan view** → a fully dimensioned array layout.
- **Elevation view**, Type = C-post-double → the side elevation with beams, purlin brackets and post cross-sections, plus the reduced member-axis copy.

### Example 1b — 3D model from the dialog

Same drawing after Elevation view (saved), Output = **MyModel**, `w = 1134, m = 12, zn = 4, zd = 4000, zd-e = 3500, E-W Slope = 2`:

- Purlin length = 12 × 1134 + 11 × 20 + 150 = 13978
- Frame offsets = 3500, 7500, 11000 (spans 3500 / 4000 / 3500)
- +Y overhang = (13978 − 11000) / 2 = 1489
- Purlins and frames follow a 2° slope along the purlin; `<drawing-name>.dxf` is written next to the drawing.

### Example 2 — brace cross-section at 1:50 scale

Draw a line representing the brace axis, load `YYR.lsp`, type `YYR`, choose **Brace**, enter `param = 60`:

- Rect1 width = 60 × 5 = 300 CAD units
- Rect2 width = (60 − 10) × 5 = 250 CAD units

Both closed polylines are placed on layer `03Brace` (white), centered on the selected line.

### Example 3 — batch row copy with Excel parameters

With a `.dwg` open that has purlin reference lines on `*Purlin*` layers and the frame lines on other layers, and a matching Excel file with `spacing = 5000`, `rowCount = 6` in `阵列计算`:

```
Command: MyModel
```

The script copies the bracket row 6 times at −5000 mm intervals along Y, cleans up unused layers, and writes `<drawing-name>.dxf` in the same folder.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `; error: no function definition: VL-LOAD-COM` | Visual LISP not initialized | Type `(vl-load-com)` at the command line before loading |
| Excel import silently skipped | No `.xls*` file in the current drawing directory | Save the drawing first, then place the Excel file in the same folder |
| TSSD dimension styles not applied | TSSD plugin not loaded | Load the TSSD plugin before running `YYR` or `PVRect_Singsun`; scripts fall back to the active style |
| `Trusted File Warning` on every load | File not in a trusted path | Run `TRUSTEDPATHS` and add the folder, or use `APPLOAD` and click **Always Load** |
| Nut blocks not visible | Dynamic block visibility state not set | Ensure the `M14` visibility state exists in the block definition |
| `MyModel` exits immediately | COM error connecting to Excel | Close other Excel instances, or ensure the `.xls*` file is not open read-only |
| `Unknown command "PVRECT"` | Command was renamed | Load `PVRect_Singsun.lsp` and type `PVRect_Singsun` |
| `[MyModel ERR] Drawing is not saved` | MyModel exports the DXF next to the drawing | Save the drawing first |
| MyModel builds no purlins | No lines on a layer whose name contains `Purlin` | Generate the Elevation view first, or draw the reference lines on such a layer |
| Text, dimensions or blocks disappear after MyModel | Layers holding no curves are cleaned up | Expected; keep a copy of the drawing, or explode blocks first |

## Contributing

Bug reports and feature requests are welcome. Open an issue or submit a pull request on [GitHub](https://github.com/yinyarong/cad-drawing_PV-bracket).

Please keep changes scoped to the affected script and test by loading the `.lsp` file directly in AutoCAD before submitting.

## License

No license file is present in this repository. All rights reserved by the author unless otherwise stated.
