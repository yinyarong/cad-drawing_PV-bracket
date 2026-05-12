# AutoCAD AutoLISP Tools for PV Bracket Structural Drawings

![AutoLISP](https://img.shields.io/badge/AutoLISP-AutoCAD-blue)
![Platform](https://img.shields.io/badge/platform-AutoCAD%202018%2B-lightgrey)
![Language](https://img.shields.io/badge/language-AutoLISP%20%2F%20Visual%20LISP-orange)

## Overview

A set of three AutoLISP scripts that automate structural engineering drawing tasks for photovoltaic (PV) bracket systems in AutoCAD. `PVRect.lsp` generates complete array layout drawings from a dialog-driven parameter set, `YYR.lsp` provides lightweight utilities for cross-section and dimension annotation, and `Mymodel.lsp` automates 3D model assembly and DXF export by reading parameters from an Excel spreadsheet.

## Features

- **Dialog-driven PV array generation** — enter panel dimensions, row/column counts, bracket spacing, clearance, and tilt angle; full engineering drawing is generated automatically
- **Excel parameter import** — reads defaults from the first `.xls*` file in the working directory; auto-detects Eurocode (V1.2/EN1990) and ASCE load templates
- **Multiple elevation types** — C-post, O-post, and C-post-single cross-section views with correctly scaled geometry
- **Structural cross-section tools** — brace and C-post rectangle pairs generated perpendicular to any selected LINE
- **Aligned dimension annotation** — `DIMALIGNED` labels placed below selected lines with TSSD-compatible styles and automatic scale-based offsets
- **3D model assembly** — rotates geometry, adjusts purlin lengths from Excel data, copies structural rows along Y-axis, then exports to DXF R2010
- **Automatic layer management** — all required layers created on demand; post-processing cleans up unused layers and purges the drawing
- **Dynamic DCL dialogs** — DCL content written to a temp file at runtime; no separate `.dcl` file required

## How It Works

### PVRect.lsp

1. **Excel import** — `PVRect_ReadExcelDefaults` opens the first Excel/WPS file in the current directory via COM automation and populates dialog defaults
2. **Dialog** — `c:PVRect` presents a DCL dialog for parameter entry and validation
3. **Drawing generation** — the script builds all geometry (PV panels, purlins, beams, axes, dimensions, elevation views, nut blocks) using `entmake` calls at a 1:5 scale (CAD units = mm × 2)
4. **Post-processing** — `PVRect_PostFix` (called via `vla-SendCommand`) generates sub-detail views, segmented horizontal dimensions, and side elevation labels

### YYR.lsp

The main `YYR` command opens a dialog to select a sub-function. Each sub-function prompts for a LINE selection, computes perpendicular geometry using `polar` + `angle`, and creates entities via `entmake`.

### Mymodel.lsp

`MyModel` runs a fixed six-step pipeline without user interaction after launch: 3D rotation → Excel read → purlin adjustment → row copy → layer cleanup → DXF export.

## Prerequisites

- **AutoCAD** with AutoLISP and DCL support (2018 or later recommended)
- **Visual LISP / VLA** — `(vl-load-com)` is called at load time; included in all full AutoCAD releases
- **Microsoft Excel or WPS Office** (COM automation) — required for Excel import in `PVRect.lsp` and `Mymodel.lsp`
- **TSSD structural CAD plugin** — required for `TSSD_xx_100` dimension styles in `YYR.lsp` and `PVRect.lsp`; scripts fall back to the current dimension style if TSSD is not loaded

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
(load "PVRect.lsp")
(load "YYR.lsp")
(load "Mymodel.lsp")
```

## Configuration

### PVRect parameters (dialog fields)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `h` / `w` | PV panel height / width (mm) | 2382 / 1134 |
| `n` / `m` | Row count / column count | 2 / 12 |
| `hole` | Hole spacing (mm) | 1400 |
| `nop` | Purlins per PV panel | 2 |
| `zn` | Number of brackets | 3 |
| `zd` / `zd-e` | Bracket spacing / edge spacing (mm) | 3800 |
| `clearance` | Ground clearance below PV panel (mm) | 400 |
| `angle` | Panel tilt angle (°) | 20 |
| `purlin_H` | Purlin bracket height in elevation (mm) | 120 |
| `beam_H` | Beam section height in elevation (mm) | 100 |

### Excel template (PVRect / Mymodel)

| Sheet / Cell | Variable | Description |
|--------------|----------|-------------|
| `排列计算` C13 | `dist_total` | Total row span distance |
| `排列计算` C14 | `spacing` | Row-to-row spacing |
| `排列计算` C15 | `rowCount` | Number of rows to copy |
| `排列计算` C16 | `dist1` | First purlin offset distance |

PVRect reads from the first sheet that contains "V1.2" or "EN1990" in any cell for Eurocode mode, otherwise ASCE mode is assumed.

### Layer system (PVRect)

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

## Usage

### PVRect — generate a PV bracket array drawing

```
Command: PVRect
```

The dialog opens. Fill in panel dimensions, layout counts, and structural parameters, then click **OK**. The script generates the full drawing and calls `ZHWBZH` automatically for post-processing.

### YYR — structural cross-section and label toolkit

```
Command: YYR
```

Select **Brace**, **C-Post**, or **Label** from the dialog.

- **Brace / C-Post** — enter `param` (integer), then select one or more LINE entities. Two concentric closed polylines are drawn perpendicular to each line.
- **Label** — select a scale (20 / 50 / 100), then select a LINE. A `DIMALIGNED` dimension is placed below it.

### Mymodel — 3D model assembly and DXF export

Place the target `.dwg` and an Excel file (`.xls` or `.xlsx`) with a `排列计算` sheet in the same directory, then:

```
Command: MyModel
```

The script runs all six steps automatically and saves a `.dxf` file with the same base name as the drawing.

## Examples

### Example 1 — 2-row × 12-column PV array, 20° tilt

Open a blank AutoCAD drawing, load `PVRect.lsp`, type `PVRect`, and enter:

```
h = 2382, w = 1134, n = 2, m = 12, angle = 20, clearance = 400
zn = 3, zd = 3800, purlin_H = 120, beam_H = 100
```

Result: a fully dimensioned top-view array layout plus an elevation view with beams, purlins, and post cross-sections, all on separate layers.

### Example 2 — brace cross-section at 1:50 scale

Draw a line representing the brace axis, load `YYR.lsp`, type `YYR`, choose **Brace**, enter `param = 60`:

- Rect1 width = 60 × 5 = 300 CAD units
- Rect2 width = (60 − 10) × 5 = 250 CAD units

Both closed polylines are placed on layer `03Brace` (white), centered on the selected line.

### Example 3 — batch row copy with Excel parameters

With a `.dwg` open that has structural entities on layers `02Beam`, `03Brace`, `04Column`, and a matching Excel file with `spacing = 5000`, `rowCount = 6` in `排列计算`:

```
Command: MyModel
```

The script copies the bracket row 6 times at −5000 mm intervals along Y, cleans up unused layers, and writes `<drawing-name>.dxf` in the same folder.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `; error: no function definition: VL-LOAD-COM` | Visual LISP not initialized | Type `(vl-load-com)` at the command line before loading |
| Excel import silently skipped | No `.xls*` file in the current drawing directory | Save the drawing first, then place the Excel file in the same folder |
| TSSD dimension styles not applied | TSSD plugin not loaded | Load the TSSD plugin before running `YYR` or `PVRect`; scripts fall back to the active style |
| `Trusted File Warning` on every load | File not in a trusted path | Run `TRUSTEDPATHS` and add the folder, or use `APPLOAD` and click **Always Load** |
| Nut blocks not visible | Dynamic block visibility state not set | Ensure the `M14` visibility state exists in the block definition |
| `MyModel` exits immediately | COM error connecting to Excel | Close other Excel instances, or ensure the `.xls*` file is not open read-only |

## Contributing

Bug reports and feature requests are welcome. Open an issue or submit a pull request on [GitHub](https://github.com/yinyarong/cad-drawing_PV-bracket).

Please keep changes scoped to the affected script and test by loading the `.lsp` file directly in AutoCAD before submitting.

## License

No license file is present in this repository. All rights reserved by the author unless otherwise stated.
