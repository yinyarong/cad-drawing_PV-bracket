# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

这是 **YYR 绘图工具集**，一个精简的 AutoCAD AutoLISP 工具，包含三个核心功能：Brace 支撑架生成、按坐标绘制直线、按坐标绘制圆形。

父目录 `../PVRect.lsp` 是功能更复杂的光伏支架布局工具，可作为高级 AutoLISP 技法的参考。

## 运行方式

无需构建或编译——AutoLISP 直接在 AutoCAD 中解释执行。

**加载 YYR.lsp（三选一）：**
```
; 方式 1：拖放 YYR.lsp 到 AutoCAD 窗口
; 方式 2：APPLOAD → 选择 YYR.lsp → 加载
; 方式 3：(load "YYR.lsp") 在命令行执行
```

**运行主命令：**
```
YYR
```

## 代码架构（YYR.lsp，363 行）

文件包含四个函数，通过 DCL 对话框统一入口：

### `YYR_Brace(param)`
核心功能。用户选择一条 LINE 实体，沿其自动生成两个并排矩形：
- 矩形1 宽度 = `param × 5`（默认 param=50，即宽 250）
- 矩形2 宽度 = `(param - 10) × 5`（默认宽 200）
- 两个矩形均延伸整条线段的长度，垂直于选定直线
- 自动创建 `03Brace` 图层

**参数约束**：param 必须 > 10（否则矩形2 宽度 ≤ 0）

### `YYR_DrawLine(sx, sy, sz, ex, ey, ez, color_idx)`
按起止坐标绘制直线，支持 7 种颜色（color 1–7）。

### `YYR_DrawCircle(cx, cy, cz, radius, color_idx)`
按圆心坐标和半径绘制圆形，支持 7 种颜色（color 1–7）。

### `c:YYR()`
主命令。**在运行时动态生成 DCL 文件**（写到临时文件，而非静态 .dcl 文件），展示统一对话框。用户点击按钮后返回 1/2/3，分别路由到三个子功能。对话框关闭后自动删除临时 DCL 文件。

## 关键实现细节

- **动态 DCL**：DCL 内容用 `write-line` 逐行写入临时文件，再用 `load_dialog` 加载。这是 YYR 不依赖外部 .dcl 文件的原因。
- **图层自动创建**：使用 `entmake` 创建 `LAYER` 类型实体实现图层创建，不依赖 `_.-LAYER` 命令。
- **Brace 几何**：矩形通过 `polar` + `angle` 计算垂直偏移方向，基于选定线段的方向角旋转生成。
- **颜色映射**：固定使用 AutoCAD 标准 7 色（1=红、2=黄、3=绿、4=青、5=蓝、6=洋红、7=白）。

## 与父目录的关系

此目录通过 `.claude/settings.local.json` 获得了对 `../`（03-CAD）的访问权限。修改 YYR.lsp 时可参考 `../PVRect.lsp` 中的 DCL 对话框、COM 接口、`entmake` 图层操作等高级用法。
