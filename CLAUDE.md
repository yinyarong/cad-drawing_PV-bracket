# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project and runtime

This repository is a collection of AutoCAD AutoLISP/Visual LISP automation scripts for PV-bracket structural drawings. There is no compiler, package manager, or automated test/lint setup; AutoCAD is the runtime and the authoritative place to validate drawing behavior. The scripts use DCL dialogs, `entmake`/`entmod`, AutoCAD commands, and Visual LISP COM (`vl-load-com`). Excel/WPS COM is used by spreadsheet-import workflows.

Load a script in AutoCAD with `APPLOAD` or at the command line:

```lisp
(load "PVRect_Singsun.lsp")
(load "PVRect_Enertrack.lsp")
(load "YYR.lsp")
(load "Mymodel.lsp")
```

Then run `PVRect_Singsun`, `PVRect_Enertrack`, `YYR`, or `MyModel` as appropriate. There is no build, lint, or automated test command: AutoLISP is interpreted by AutoCAD. For a focused/manual test, load only the changed script (or the intended pair of variants), invoke its public command, and exercise the changed path on a disposable drawing. Spreadsheet-dependent commands need a saved drawing and a compatible workbook in its folder. Keep a backup before running MyModel workflows: they transform drawing entities and export/overwrite DXF output.

The commonly used load/run pairs are:

| Script | Load | Main command(s) |
|---|---|---|
| `PVRect_Singsun.lsp` | `(load "PVRect_Singsun.lsp")` | `PVRect_Singsun`; post-processing: `ZHWBZH_Singsun` |
| `PVRect_Enertrack.lsp` | `(load "PVRect_Enertrack.lsp")` | `PVRect_Enertrack`; post-processing: `ZHWBZH_Enertrack` |
| `YYR.lsp` | `(load "YYR.lsp")` | `YYR` |
| `Mymodel.lsp` | `(load "Mymodel.lsp")` | `MyModel` |

To test one workflow, load the corresponding LSP in AutoCAD and run that command; there is no standalone single-test runner. `MyModel` is destructive to drawing contents, so test it on a copy.

## Architecture

- `PVRect_Singsun.lsp` and `PVRect_Enertrack.lsp` are separate, parallel product variants. Each is a largely self-contained implementation of Excel default import, parameter dialog/input validation, plan/elevation drawing, post-processing, and an in-dialog 3D MyModel/DXF workflow. Their public commands and helper/global names are deliberately variant-specific (`PVRect_Sgs` / `*sg_*` / `_Singsun` versus `PVRectEnt` / `*et_*` / `_Enertrack`) so both can be loaded together. Keep variant-specific fixes and behavior isolated unless deliberately porting between them.
- The PVRect command is the front end: it collects and validates parameters, creates the primary drawing geometry, and records state in variant-specific globals. Plan-view post-processing still uses a separate `ZHWBZH_*` command via asynchronous `vla-SendCommand`; elevation output now calls the postfix routine directly so it skips plan-only post-processing and completes insertion centering synchronously. Changes to these flows must preserve their distinct sequencing and state contracts.
- Each PVRect variant has its own Excel-import routine and workbook mapping. It searches the saved drawing's directory for Excel files, selects the newest non-lock workbook, and reads its own expected worksheet/template fields. The dialogs also have defaults, so Excel import is optional. Keep sheet names, units conversions, and variant mappings aligned with the specific implementation.
- Both variants implement the PHC pile elevation as elevation type `4` (dialog label “PHC Pile”), with diameter and above-ground exposure inputs. The new `C-3P4B` elevation type is internal type `5` and currently follows the C-post-double elevation and post-processing branches; keep its enum distinct so its geometry can be customized independently. The PHC geometry helper builds hoop/crossbeam and brace/post axes, member section outlines, and optional `Nut` block inserts; the post-fix path also classifies axis entities for the reduced elevation thumbnail. Thumbnail layer mapping is fixed: beam `02Beam`, brace `03Brace`, post `04Column`, loop/hoop `05Loop`, pile `06Pile`. Keep PHC pile and column axis tracking separate; trace both model-space creation and post-fix copying/classification in both variant files, whose helper/global prefixes remain separate.
- Both in-dialog MyModel implementations build frame offsets from `zn`, `zd`, and `zd-e`, transform model geometry, extend purlins, replicate frame curves, clean non-curve layers, and export DXF. Their input is the drawing geometry and dialog parameters rather than the standalone script's Excel-based inputs.
- `Mymodel.lsp` is the independent legacy `MyModel` command: it reads its row/purlin inputs from an Excel workbook, transforms and copies drawing geometry, removes unused layer content, and saves DXF. Its text is legacy encoded (not UTF-8); preserve its encoding if editing it.
- `YYR.lsp` is an independent interactive utility command for brace/C-post section polylines, aligned labels, and shortening LINE endpoints. Its DCL definition is generated in a temporary file at runtime; no checked-in DCL file is needed.
- `图纸模板.dwg` supplies drawing/template resources (including blocks/styles consumed by drawing routines). PHC/purlin workflows look up named blocks such as `Nut` and `Purlin-Bracket-XX`; missing definitions can omit those inserts even when geometry is otherwise generated. Some routines fall back when optional dimension styles are unavailable. Excel workbooks are input data, not source code.

## Important operational constraints

- Excel lookup is based on the current saved drawing's folder (`DWGPREFIX`), not necessarily the repository root. A running Excel/WPS workbook may be reused; cleanup should not close a workbook or application that the script did not open.
- `MyModel` output routines modify the active drawing and may erase non-curve entities/layers before exporting. Test against a copy, especially when drawings contain unrelated views or block-only layers.
- Maintain the AutoCAD state-restoration/error-handling paths (`OSMODE`, `CMDECHO`, current layer/dimension style, Excel COM objects, undo marks) when changing long-running command flows.
- Geometry is expressed in CAD units with variant-specific scale factors; trace the caller and downstream geometry before changing a scale or unit conversion. Do not assume values labeled in millimeters are stored directly as millimeters in the drawing.

## Repository notes

`README.md` documents installation and user workflows mainly for the Singsun variant and utility scripts; it does not cover Enertrack or the newer PHC elevation workflow and may contain older parameter/layer details. Treat the implementation in each LSP as authoritative when documentation differs. There are no `.cursor/rules/` or Copilot instruction files in this repository. `.gitignore` excludes AutoCAD lock/temp files and historical `.bak*` variants; do not treat those as active source.