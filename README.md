# AutoCAD AutoLISP Tools

AutoLISP scripts for PV bracket layout generation and structural drawing automation in AutoCAD.

## Scripts

| Script | Command | Purpose |
|--------|---------|---------|
| `PVRect.lsp` | `PVRect` | Photovoltaic bracket array layout — full engineering drawing generation |
| `YYR.lsp` | `YYR` | Structural drawing toolkit: brace sections, column posts, dimension labels |

## Installation

No build step required — AutoLISP is interpreted directly by AutoCAD.

Drag `PVRect.lsp` or `YYR.lsp` onto an open AutoCAD window, or:

```
Command: APPLOAD
```

Browse to the file, click **Load**. When prompted about trusted locations, click **Always Load** or **Add to Trusted Paths**.

---

## PVRect — PV Bracket Layout

Generates complete photovoltaic bracket array structural drawings from a dialog.

### Commands

- `PVRect` — opens the parameter dialog and generates the array drawing
- `ZHWBZH` — post-processing command (called automatically by `PVRect` via SendCommand)

### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `h` / `w` | PV panel height / width (mm) | 2382 / 1134 |
| `n` / `m` | Row count / column count | 2 / 12 |
| `hole` | Hole spacing (mm) | 1400 |
| `nop` | Purlins per PV panel | 2 |
| `zn` | Bracket count | 3 |
| `zd` / `zd-e` | Bracket spacing / edge spacing (mm) | 3800 |
| `clearance` | Gap between panels (mm) | 400 |
| `angle` | Tilt angle (°) | 20 |

### Excel Import

`PVRect_ReadExcelDefaults` reads parameters from an Excel file in the working directory. Automatically detects Eurocode (V1.2 / EN1990) or ASCE templates.

### Layers

`AXIS` (red), `purlin` (green), `beam` (yellow), `PV` (white), `DIM` (white), `NUM` (white), `LTPJJ` (yellow), `STPM_SBEAM_THICK` (white)

### Dimension Styles

`TSSD_50_100` (primary), `TSSD_20_100` (detail)

### Coordinate System

1:5 scale factor (SF = 2.0) — `cad_value = mm_value × 2`

---

## YYR — Drawing Toolkit

A lightweight tool for generating structural cross-sections and aligned dimension annotations. Type `YYR` to open the dialog.

### Brace

Select a LINE entity; generates two centered closed polylines (LWPOLYLINE) on layer `03Brace` (white).

| Parameter | Default | Constraint | Rect sizes |
|-----------|---------|-----------|------------|
| param | 50 | > 10 | Rect1 width = param × 5; Rect2 width = (param−10) × 5 |

### C-Post

Same workflow for column posts on layer `03CPost` (cyan).

| Parameter | Default | Constraint | Rect sizes |
|-----------|---------|-----------|------------|
| param | 80 | > 20 | Rect1 width = param × 5; Rect2 width = (param−20) × 5 |

### Label

Places a `DIMALIGNED` dimension below a selected LINE on layer `DIM`. Active dimension style and layer are saved and restored after each operation.

| Scale | Dimension style | Perpendicular offset |
|-------|----------------|----------------------|
| 100 | `TSSD_100_100` | 150 |
| 50 | `TSSD_50_100` | 300 |
| 20 (default) | `TSSD_20_100` | 750 |

TSSD dimension styles require the TSSD structural CAD plugin to be loaded; otherwise the current style is used as fallback.

### Auto Layer Creation

`03Brace`, `03CPost`, and `DIM` layers are created automatically if they do not exist.

---

## Requirements

- AutoCAD with AutoLISP and DCL support
- Visual LISP / VLA (`vl-load-com`) — standard in all full AutoCAD releases
- For Excel import in PVRect: Microsoft Excel installed (COM automation via Late Binding)
- For TSSD label styles in YYR: TSSD structural CAD plugin loaded in the drawing
