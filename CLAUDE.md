# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

本项目包含三个 AutoCAD AutoLISP 脚本，均直接在 AutoCAD 中解释执行，无需编译：

| 脚本 | 命令 | 功能 |
|------|------|------|
| `PVRect.lsp` | `PVRect` | 光伏支架阵列布局自动生成（完整工程图纸） |
| `YYR.lsp` | `YYR` | 轻量绘图工具：Brace 支撑架、C-Post 柱截面、Label 标注、Shorten 缩短 |
| `Mymodel.lsp` | `MyModel` | 3D 旋转 + Excel 读取 + 行复制 + 导出 DXF 的自动建模脚本 |

## 运行方式

无需构建——拖放 .lsp 文件到 AutoCAD 窗口，或：

```
APPLOAD → 选择文件 → 加载
(load "PVRect.lsp")   ; 或 YYR.lsp / Mymodel.lsp
```

---

## PVRect.lsp — 光伏支架布局工具

### 主命令
- `PVRect` — 启动对话框，生成光伏阵列结构图纸
- `ZHWBZH` — 后处理命令（由 `PVRect` 通过 SendCommand 异步调用）

### 代码架构（约 2779 行）

1. **工具函数 + Excel 数据导入**（第 1–541 行）
   - `PVRect_ReadExcelDefaults`（第 262 行）— 从当前目录 Excel 文件读取参数；自动识别 Eurocode（含 "V1.2"/"EN1990"）或 ASCE 模板
   - `PVRect_ImportExcel`（第 479 行）— 解析导入结果，返回参数字典
   - 辅助函数：`PVRect_SnapDown`、`PVRect_GetProjectionDist`、`PVRect_SetBlockVisibility`、`PVRect_FarFromPointsP`、`PVRect_UniqueSorted`、`PVRect_BuildPVVerticalXs`、`PVRect_BuildBreakCandidates`、`PVRect_FindBreakPath`、`PVRect_AddSegmentedHorizontalDim`

2. **立面图绘制与后处理**（第 515–2412 行）
   - `PVRect_FindPurlinBlock`（第 515 行）— 在块表中查找最近匹配高度的 `Purlin-Bracket-xx` 块
   - `PVRect_PostFix`（第 542 行）— 生成立面图、分段水平标注、侧视图；根据 `*global_elev_type*` 分支处理各种立面类型（0/1/2/3）

3. **主入口**（第 2413–2779 行）
   - `c:PVRect`（第 2416 行）— DCL 对话框、参数验证、平面图形生成；在末尾通过 `setq` 写入全局变量后 `vla-SendCommand` 调用 `ZHWBZH`

### 立面图类型（`elev_type` / `*global_elev_type*`）

| 值 | 对话框选项 | 说明 |
|----|-----------|------|
| `0` | No | 仅平面阵列，不生成立面图 |
| `1` | C-post-double | 双立柱 C 型钢截面；插入 U 型螺栓块（U1/U2），上延 175、下延 7500 |
| `2` | O-post | 圆管截面；绘制 Triangle-Connector 块，post-axis 轴线平移至连接块底点 |
| `3` | C-post-single | 单立柱 C 型钢截面；中心对称的螺旋桩块、两条斜撑轴线，无 U 型螺栓块 |

### 关键参数

| 参数 | 说明 | 默认值 |
|------|------|-------|
| `h` / `w` | PV 板高/宽（mm） | 2382 / 1134 |
| `n` / `m` | 行数 / 列数 | 2 / 12 |
| `hole` | 孔距（mm） | 1400 |
| `nop` | 每块 PV 檩条数 | 2 |
| `zn` | 支架数量 | 3 |
| `zd` / `zd-e` | 支架间距 / 边缘间距（mm） | 3800 |
| `clearance` | 净空高度（mm） | 400 |
| `angle` | 旋转角度（°） | 20 |
| `purlin_H` | 檩条支架高度（mm），立面图中 PV 底部向下延伸量 | 80 |
| `beam_H` | 梁截面高度（mm），立面图中梁矩形高度 | 100 |
| `post_w` | 立柱宽度 W（mm），C-post 类型（1/3）使用 | 80 |
| `post_d` | 立柱直径 D（mm），O-post 类型（2）使用 | 60 |

### 立面图几何优先级（元素紧密对齐）

1. **净空**：地平线（`lower_top_axis_y`）→ PV 底部（`pv_start_y = ground + clearance × 5`）精确控制
2. **檩条支架**：从 `pv_start_y` 向下 `purlin_H × 5` CAD 单位到 `purlin_bot_y`（底部 = 梁顶面）
3. **梁**：梁中心轴（`beam_axis_y = purlin_bot_y − beam_H × 2.5`），梁顶面与檩条底部对齐

### 轴线类型（立面图）

- **post-axis**：右侧图形中的两根竖向立柱轴线（U1, U2）
- **beam-angle-axis**：沿 `angle` 方向的斜轴线
- **brace-axis**：连接 post-axis 与 beam-angle-axis 的斜向连接轴线

### 全局变量（`c:PVRect` 末尾设置，`PVRect_PostFix` 读取）

`*global_n*`、`*global_m*`、`*global_sf*`、`*global_h*`、`*global_purlin_H*`、`*global_beam_h*`、`*global_clearance*`、`*global_elev_type*`、`*global_axis_y_list*`、`*global_startX*`、`*global_endX*`、`*global_center_x*`、`*global_dim_x_vert*`、`*global_bottom_y*`、`*global_bottom_dim_y*`、`*global_axis_y2_baseline*`、`*global_new_line_x1*`、`*last_ent_before_macro*`

### 图层系统

`AXIS`（红）、`purlin`（绿）、`beam`（黄）、`PV`（白）、`DIM`（白）、`NUM`（白）、`LTPJJ`（黄）、`STPM_SBEAM_THICK`（白）

### 标注样式
`TSSD_50_100`（主）、`TSSD_20_100`（详细）

### 坐标系统
1:5 缩放（SF = 2.0），`cad_value = mm_value × 2`

---

## YYR.lsp — 轻量绘图工具集（463 行）

### 主命令
- `YYR` — 启动 DCL 对话框，选择子功能（Brace / C-Post / Label / Shorten）

### 子功能

| 功能 | 图层 | 说明 |
|------|------|------|
| **Brace** | `03Brace`（白） | 选一条 LINE，生成两个并排 LWPOLYLINE（Brace 支撑架截面）；`param > 10`，Rect1宽 = param×5，Rect2宽 = (param-10)×5 |
| **C-Post** | `03CPost`（青） | 与 Brace 相同工作流，用于柱截面；`param > 20`，Rect1宽 = param×5，Rect2宽 = (param-20)×5 |
| **Label** | `DIM`（白） | 选一条 LINE，在其下方放置 `DIMALIGNED` 标注；比例 20/50/100 对应不同偏移和标注样式 |
| **Shorten** | — | 点击 LINE 的靠近端，将该端向对侧收缩 `param` 个 CAD 单位；循环操作直到按 Enter |

### Label 标注样式

| 比例 | 标注样式 | 垂直偏移 |
|------|---------|---------|
| 100 | `TSSD_100_100` | 150 |
| 50 | `TSSD_50_100` | 300 |
| 20（默认） | `TSSD_20_100` | 750 |

TSSD 标注样式需 TSSD 结构 CAD 插件；否则回退到当前样式。操作完成后自动恢复原有标注样式和图层。

### 关键实现细节

- **动态 DCL**：DCL 内容用 `write-line` 写入临时文件，`load_dialog` 加载，退出后自动删除，无需静态 .dcl 文件
- **图层创建**：`entmake` 创建图层（`03Brace`、`03CPost`、`DIM`），不依赖 `_.-LAYER` 命令
- **Brace/C-Post 几何**：`polar` + `angle` 计算垂直偏移，基于线段方向角旋转

---

## Mymodel.lsp — 自动建模脚本（290 行）

### 主命令
- `MyModel` — 一键执行：3D旋转 → Excel读取 → 檩条调整 → 行复制 → 清理图层 → 导出DXF

### 执行流程（顺序）

1. **3D 旋转**：全选所有实体，绕 X 轴旋转 90°（`vla-Rotate3D`）
2. **Excel 读取**：从图纸目录第一个 `.xls*` 文件的 **"排列计算"** 工作表读取参数
   - `C13` = 总距离 `dist_total`，`C14` = 间距 `spacing`，`C15` = 行数 `rowCount`，`C16` = `dist1`（`dist2 = dist_total - dist1`）
3. **檩条调整**：对图层 `01Purlin-01` / `01Purlin-02` 上的线段，以 Z 最小端点为基点，按 `dist1`/`dist2` 重绘
4. **行复制**：将图层 `02Beam`、`03Brace`、`04Column` 上的实体复制 `rowCount` 次，每次沿 Y 轴偏移 `-spacing × i`
5. **清理图层**：保留有曲线实体的图层和图层 `0`，删除其余图层及其实体，运行 `PURGE`
6. **导出 DXF**：保存为同名 `.dxf`（R2010 格式，`SAVEAS DXF 16`），覆盖已有文件

### 关键实现细节
- 用 Late Binding 连接 Excel/WPS COM，优先复用已开启的工作簿；`isOpenedByMe` 标记控制是否退出 Excel
- `*error*` 处理函数负责恢复 `OSMODE`、`cmdecho` 及关闭 Excel
- `_delete-extra-layers` 需要两轮删除（图层间依赖），每轮后调用 `PURGE`

---

## 开发注意事项

- COM 接口用 Late Binding（`vlax-get-or-create-object`），必须用 `vlax-release-object` 释放
- 所有坐标用 `_NON` 禁用对象捕捉
- 后处理通过 `vla-SendCommand` 异步执行，用全局变量传递状态
- PVRect 全局变量在 `c:PVRect`（第 2416 行）末尾通过 `setq` 写入，在 `PVRect_PostFix`（第 542 行）读取
