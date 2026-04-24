# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

本项目包含两个 AutoCAD AutoLISP 脚本，均直接在 AutoCAD 中解释执行，无需编译：

| 脚本 | 命令 | 功能 |
|------|------|------|
| `PVRect.lsp` | `PVRect` | 光伏支架阵列布局自动生成（完整工程图纸） |
| `YYR.lsp` | `YYR` | 轻量绘图工具：Brace 支撑架、按坐标画线/圆 |

## 运行方式

无需构建——拖放 .lsp 文件到 AutoCAD 窗口，或：

```
APPLOAD → 选择文件 → 加载
(load "PVRect.lsp")   ; 或 YYR.lsp
```

---

## PVRect.lsp — 光伏支架布局工具

### 主命令
- `PVRect` — 启动对话框，生成光伏阵列结构图纸
- `ZHWBZH` — 后处理命令（由 `PVRect` 通过 SendCommand 异步调用）

### 代码架构（约 1142 行）

1. **Excel 数据导入**（第 1–395 行）
   - `PVRect_ReadExcelDefaults` — 从当前目录 Excel 文件读取参数
   - 自动识别 Eurocode（含 "V1.2"/"EN1990"）或 ASCE 模板

2. **后处理**（第 397–797 行）
   - `PVRect_PostFix` — 生成下层详图、分段水平标注、侧视图

3. **主入口**（第 799–1142 行）
   - `c:PVRect` — DCL 对话框、参数验证、图形生成

### 关键参数

| 参数 | 说明 | 默认值 |
|------|------|-------|
| `h` / `w` | PV 板高/宽（mm） | 2382 / 1134 |
| `n` / `m` | 行数 / 列数 | 2 / 12 |
| `hole` | 孔距（mm） | 1400 |
| `nop` | 每块 PV 檩条数 | 2 |
| `zn` | 支架数量 | 3 |
| `zd` / `zd-e` | 支架间距 / 边缘间距（mm） | 3800 |
| `clearance` | 间隙（mm） | 400 |
| `angle` | 旋转角度（°） | 20 |

### 图层系统

`AXIS`（红）、`purlin`（绿）、`beam`（黄）、`PV`（白）、`DIM`（白）、`NUM`（白）、`LTPJJ`（黄）、`STPM_SBEAM_THICK`（白）

### 标注样式
`TSSD_50_100`（主）、`TSSD_20_100`（详细）

### 坐标系统
1:5 缩放（SF = 2.0），`cad_value = mm_value × 2`

---

## YYR.lsp — 轻量绘图工具集

### 主命令
- `YYR` — 启动 DCL 对话框，选择子功能

### 代码架构（363 行）

| 函数 | 功能 |
|------|------|
| `YYR_Brace(param)` | 选一条 LINE，沿其生成两个并排矩形（Brace 支撑架截面） |
| `YYR_DrawLine(...)` | 按起止坐标画线，支持 7 种颜色 |
| `YYR_DrawCircle(...)` | 按圆心+半径画圆，支持 7 种颜色 |
| `c:YYR()` | 动态生成 DCL 文件并加载，退出后自动删除 |

**Brace 参数约束**：`param > 10`（矩形1宽 = param×5，矩形2宽 = (param-10)×5）

### 关键实现细节

- **动态 DCL**：DCL 内容用 `write-line` 写入临时文件，`load_dialog` 加载，无需静态 .dcl 文件
- **图层创建**：`entmake` 创建 `03Brace` 图层，不依赖 `_.-LAYER` 命令
- **Brace 几何**：`polar` + `angle` 计算垂直偏移，基于线段方向角旋转

---

## 开发注意事项

- COM 接口用 Late Binding（`vlax-get-or-create-object`），必须用 `vlax-release-object` 释放
- 所有坐标用 `_NON` 禁用对象捕捉
- 后处理通过 `vla-SendCommand` 异步执行，用全局变量传递状态
- PVRect 全局变量：`*global_n*`、`*global_m*`、`*global_sf*` 等（详见 PVRect.lsp 头部注释）
