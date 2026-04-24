# YYR Drawing Tools

> AutoCAD AutoLISP toolkit for structural drawing automation — brace sections, column posts, and dimension labeling from a single dialog.

## Overview

YYR is a lightweight AutoCAD AutoLISP tool that automates repetitive structural drafting tasks. It generates concentric cross-section rectangles for brace and column-post members along any selected line, and places aligned dimension annotations using TSSD-compatible styles — all driven from a single `YYR` command and dialog.

## Features

- **Brace** — selects a LINE entity and generates two centered closed polylines (LWPOLYLINE) representing a brace cross-section, on layer `03Brace`
- **C-Post** — same concentric-rectangle workflow for column posts, on layer `03CPost` (drawn in Cyan)
- **Label** — places an aligned dimension (DIMALIGNED) below a selected line on layer `DIM`, with support for TSSD dimension styles at three drawing scales
- **Auto layer creation** — `03Brace`, `03CPost`, and `DIM` layers are created automatically if they do not exist
- **Dynamic DCL dialog** — the GUI is generated at runtime; no external `.dcl` file is required
- **Non-destructive style handling** — the active dimension style and current layer are saved and restored after each Label operation

## How It Works

```
YYR (command)
 └─ generates temp .dcl → loads dialog
     ├─ Brace  → entmake 2x LWPOLYLINE centered on selected line  → layer 03Brace
     ├─ C-Post → entmake 2x LWPOLYLINE centered on selected line  → layer 03CPost (cyan)
     └─ Label  → DIMALIGNED below selected line                   → layer DIM
```

Each feature shares the same geometry pattern: the selected line's start/end points define the length; a perpendicular direction derived from `angle` + `polar` controls width and offset. Rectangle widths and dimension offsets are scaled by the numeric parameter entered in the dialog.

**Rectangle geometry (Brace example, param = 50):**

| Rectangle | Width formula | Result |
|-----------|--------------|--------|
| Rect 1 | `param x 5` | 250 |
| Rect 2 | `(param - 10) x 5` | 200 |

Both rectangles are centered on the line's midpoint axis.

**Label offsets:**

| Scale | Dimension style | Perpendicular offset |
|-------|----------------|----------------------|
| 100 | `TSSD_100_100` | 150 x 1 = **150** |
| 50 | `TSSD_50_100` | 150 x 2 = **300** |
| 20 (default) | `TSSD_20_100` | 150 x 5 = **750** |

## Prerequisites

- **AutoCAD** (any version with AutoLISP and DCL support)
- **Visual LISP / VLA** — `vl-load-com` is called at startup; standard in all full AutoCAD releases
- For TSSD dimension styles (`TSSD_100_100`, `TSSD_50_100`, `TSSD_20_100`): the **TSSD structural CAD plugin** must be loaded in the drawing. If styles are absent, Label falls back to the current dimension style.

## Installation

No build step is required — AutoLISP files are interpreted directly by AutoCAD.

**Option 1 — Drag and drop**

Drag `YYR.lsp` onto an open AutoCAD window.

**Option 2 — APPLOAD**

```
Command: APPLOAD
```

Browse to `YYR.lsp`, click **Load**. When prompted about trusted locations, click **Always Load** or **Add to Trusted Paths**.

**Option 3 — Command line**

```lisp
(load "C:/path/to/YYR.lsp")
```

A confirmation banner appears on successful load:

```
=============================================
= YYR Drawing Tools Loaded                  =
= Type YYR to launch                        =
=============================================
```

> **Note:** If the banner does not appear after loading, press **F2** to open the AutoCAD text window and check for errors. Ensure the file is loaded from a trusted path (see `SECURELOAD` system variable).

## Configuration

All parameters are set interactively through the dialog. There are no external config files.

| Parameter | Feature | Default | Constraint | Effect |
|-----------|---------|---------|-----------|--------|
| Param | Brace | `50` | > 10 | Rect1 width = param x 5; Rect2 width = (param-10) x 5 |
| Param | C-Post | `80` | > 20 | Rect1 width = param x 5; Rect2 width = (param-20) x 5 |
| Scale | Label | `20` | 100 / 50 / 20 | Selects TSSD dim style and perpendicular offset |

## Usage

Type `YYR` at the AutoCAD command prompt to open the dialog.

```
Command: YYR
```

### Brace

1. Enter a numeric parameter (default `50`, must be > 10).
2. Click **Run**.
3. Click a LINE entity in the drawing.
4. Two centered closed polylines are drawn on layer `03Brace`.

### C-Post

1. Enter a numeric parameter (default `80`, must be > 20).
2. Click **Run**.
3. Click a LINE entity in the drawing.
4. Two centered closed polylines are drawn in Cyan on layer `03CPost`.

### Label

1. Select a scale from the dropdown (`100`, `50`, or `20`; default `20`).
2. Click **Run**.
3. Click a LINE entity in the drawing.
4. An aligned dimension is placed below the line on layer `DIM`.

## Examples

**Brace, param = 50 on a 3000-unit horizontal line:**

```
Created 2 rectangles on layer 03Brace
  Rect1: 250 x 3000
  Rect2: 200 x 3000
```

**C-Post, param = 80 on a 2000-unit line:**

```
Created 2 rectangles on layer 03CPost
  Rect1: 400 x 2000
  Rect2: 300 x 2000
```

**Label, scale = 50 on a line:**

```
Labeled with TSSD_50_100 at offset 300
```

A `DIMALIGNED` dimension is created 300 drawing units below the line, on the `DIM` layer, using the `TSSD_50_100` dimension style.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `YYR` is an unknown command after loading | File loaded from wrong path or blocked by SECURELOAD | Use APPLOAD to load and add to trusted paths; ensure path is `03-CAD - Drawing` (with dashes) |
| No banner after drag-and-drop load | SECURELOAD > 0 blocking the file | Run `(setvar "SECURELOAD" 0)` or add folder via `OPTIONS > Files > Trusted Locations` |
| Dialog does not open | DCL temp file creation failed | Check write access to the Windows temp directory |
| Dimension not created after selecting line | Dimstyle command interfered with command queue | Reload the LSP; current version uses VLA for dimstyle to avoid this |
| Rectangles draw at wrong position | A non-LINE entity was selected | Only select LINE entities (not polylines, splines, etc.) |
| TSSD dimension styles not applied | TSSD plugin not loaded in the drawing | Load TSSD first, or accept the fallback to the current dim style |

## Contributing

This is a single-file AutoLISP tool. To propose changes:

1. Fork or clone the repository.
2. Edit `YYR.lsp` directly — no build step needed.
3. Test by loading the modified file in AutoCAD (`APPLOAD` or drag-and-drop).
4. Submit a pull request with a clear description of what changed and why.

Bug reports and feature requests are welcome via the repository's issue tracker.

## License

No license file is present in this repository. All rights reserved by the author unless otherwise stated.
