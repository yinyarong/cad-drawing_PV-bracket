;; =============================================================================
;; YYR - AutoCAD 绘图工具集
;; 版本: 1.0
;; 说明: 包含 Brace、绘制直线、绘制圆形功能
;; =============================================================================

(vl-load-com)

;; =============================================================================
;; 1. Brace 功能 - 选择直线生成两个矩形
;; =============================================================================

(defun YYR_Brace (param / line_ent line_data start_pt end_pt line_len line_angle perp_angle width1 width2 offset1 offset2 rect1_pt1 rect1_pt2 rect1_pt3 rect1_pt4 rect2_pt1 rect2_pt2 rect2_pt3 rect2_pt4)

  ;; 参数验证
  (if (not (numberp param))
    (progn
      (alert "参数必须是数字")
      (exit)
    )
  )

  (if (<= param 10)
    (progn
      (alert "参数必须大于 10，否则第二个矩形宽度将为负数")
      (exit)
    )
  )

  ;; 计算矩形宽度
  (setq width1 (* param 5.0))       ; 第一个矩形宽度
  (setq width2 (* (- param 10) 5.0)) ; 第二个矩形宽度

  ;; 提示用户选择直线
  (setq line_ent (car (entsel "\n选择一根直线: ")))

  (if (not line_ent)
    (progn
      (prompt "\n未选择对象。")
      (exit)
    )
  )

  ;; 获取直线数据
  (setq line_data (entget line_ent))

  ;; 验证是否为直线
  (if (/= (cdr (assoc 0 line_data)) "LINE")
    (progn
      (alert "选择的对象不是直线！")
      (exit)
    )
  )

  ;; 获取起点和终点
  (setq start_pt (cdr (assoc 10 line_data)))
  (setq end_pt (cdr (assoc 11 line_data)))

  ;; 计算直线参数
  (setq line_len (distance start_pt end_pt))
  (setq line_angle (angle start_pt end_pt))
  (setq perp_angle (+ line_angle (/ pi 2.0))) ; 垂直方向

  ;; 确保"向上"（Y 正方向）
  (if (< (sin perp_angle) 0)
    (setq perp_angle (+ perp_angle pi))
  )

  ;; 创建 03Brace 图层（如果不存在）
  (if (not (tblsearch "LAYER" "03Brace"))
    (entmake (list
      '(0 . "LAYER")
      '(100 . "AcDbSymbolTableRecord")
      '(100 . "AcDbLayerTableRecord")
      '(2 . "03Brace")
      '(70 . 0)
      '(62 . 7) ; 白色
    ))
  )

  ;; 绘制矩形 1
  (setq offset1 (/ width1 2.0))
  (setq rect1_pt1 (polar start_pt perp_angle (- offset1)))
  (setq rect1_pt2 (polar end_pt perp_angle (- offset1)))
  (setq rect1_pt3 (polar end_pt perp_angle offset1))
  (setq rect1_pt4 (polar start_pt perp_angle offset1))

  ; LWPOLYLINE 顶点必须是 2D 点
  (entmake (list
    '(0 . "LWPOLYLINE")
    '(100 . "AcDbEntity")
    '(8 . "03Brace")
    '(100 . "AcDbPolyline")
    '(90 . 4)
    '(70 . 1)
    (cons 10 (list (car rect1_pt1) (cadr rect1_pt1)))
    (cons 10 (list (car rect1_pt2) (cadr rect1_pt2)))
    (cons 10 (list (car rect1_pt3) (cadr rect1_pt3)))
    (cons 10 (list (car rect1_pt4) (cadr rect1_pt4)))
  ))

  ;; 绘制矩形 2
  (setq offset2 (+ width1 (/ width2 2.0)))
  (setq rect2_pt1 (polar start_pt perp_angle (+ offset1 (- (/ width2 2.0)))))
  (setq rect2_pt2 (polar end_pt perp_angle (+ offset1 (- (/ width2 2.0)))))
  (setq rect2_pt3 (polar end_pt perp_angle offset2))
  (setq rect2_pt4 (polar start_pt perp_angle offset2))

  (entmake (list
    '(0 . "LWPOLYLINE")
    '(100 . "AcDbEntity")
    '(8 . "03Brace")
    '(100 . "AcDbPolyline")
    '(90 . 4)
    '(70 . 1)
    (cons 10 (list (car rect2_pt1) (cadr rect2_pt1)))
    (cons 10 (list (car rect2_pt2) (cadr rect2_pt2)))
    (cons 10 (list (car rect2_pt3) (cadr rect2_pt3)))
    (cons 10 (list (car rect2_pt4) (cadr rect2_pt4)))
  ))

  (prompt (strcat "\n成功创建两个矩形！"))
  (prompt (strcat "\n  矩形1: " (rtos width1 2 0) " x " (rtos line_len 2 0)))
  (prompt (strcat "\n  矩形2: " (rtos width2 2 0) " x " (rtos line_len 2 0)))
  (prompt (strcat "\n  图层: 03Brace"))

  (princ)
)

;; =============================================================================
;; 2. 绘制直线功能
;; =============================================================================

(defun YYR_DrawLine (start_x start_y start_z end_x end_y end_z color_idx / start_pt end_pt)

  ;; 验证输入
  (if (not (and (numberp start_x) (numberp start_y) (numberp start_z)
                (numberp end_x) (numberp end_y) (numberp end_z)))
    (progn
      (alert "请输入有效的数字坐标")
      (exit)
    )
  )

  (setq start_pt (list start_x start_y start_z))
  (setq end_pt (list end_x end_y end_z))

  ;; 绘制直线
  (entmake (list
    '(0 . "LINE")
    '(8 . "0")
    (cons 10 start_pt)
    (cons 11 end_pt)
    (cons 62 color_idx)
  ))

  (prompt (strcat "\n已绘制直线: (" (rtos start_x 2 2) ", " (rtos start_y 2 2) ", " (rtos start_z 2 2) ") -> (" (rtos end_x 2 2) ", " (rtos end_y 2 2) ", " (rtos end_z 2 2) ")"))

  (princ)
)

;; =============================================================================
;; 3. 绘制圆形功能
;; =============================================================================

(defun YYR_DrawCircle (center_x center_y center_z radius color_idx / center_pt)

  ;; 验证输入
  (if (not (and (numberp center_x) (numberp center_y) (numberp center_z) (numberp radius)))
    (progn
      (alert "请输入有效的数字")
      (exit)
    )
  )

  (if (<= radius 0)
    (progn
      (alert "半径必须大于 0")
      (exit)
    )
  )

  (setq center_pt (list center_x center_y center_z))

  ;; 绘制圆形
  (entmake (list
    '(0 . "CIRCLE")
    '(8 . "0")
    (cons 10 center_pt)
    (cons 40 radius)
    (cons 62 color_idx)
  ))

  (prompt (strcat "\n已绘制圆形: 圆心 (" (rtos center_x 2 2) ", " (rtos center_y 2 2) ", " (rtos center_z 2 2) "), 半径 " (rtos radius 2 2)))

  (princ)
)

;; =============================================================================
;; 4. DCL 对话框与主命令
;; =============================================================================

(defun c:YYR ( / dcl_file f dcl_id res brace_param line_start_x line_start_y line_start_z line_end_x line_end_y line_end_z line_color circle_center_x circle_center_y circle_center_z circle_radius circle_color)

  ;; 设置默认值
  (setq brace_param 50)
  (setq line_start_x 0.0 line_start_y 0.0 line_start_z 0.0)
  (setq line_end_x 100.0 line_end_y 100.0 line_end_z 0.0)
  (setq line_color 1) ; 红色
  (setq circle_center_x 0.0 circle_center_y 0.0 circle_center_z 0.0)
  (setq circle_radius 50.0)
  (setq circle_color 3) ; 绿色

  ;; 创建 DCL 文件
  (setq dcl_file (vl-filename-mktemp "yyr.dcl"))
  (setq f (open dcl_file "w"))

  ;; 写入 DCL 对话框定义
  (write-line "yyr_dlg : dialog {" f)
  (write-line "  label = \"YYR 绘图工具\";" f)
  (write-line "  width = 50;" f)

  ;; Brace 功能
  (write-line "  : boxed_column { label = \"Brace - 支撑架生成\";" f)
  (write-line "    : row {" f)
  (write-line "      : text { label = \"参数值:\"; width = 12; fixed_width = true; alignment = right; }" f)
  (write-line "      : edit_box { key = \"brace_param\"; edit_width = 10; value = \"50\"; }" f)
  (write-line "      : button { label = \"执行\"; key = \"btn_brace\"; width = 12; fixed_width = true; }" f)
  (write-line "    }" f)
  (write-line "    : text { value = \"说明: 选择直线生成两个矩形\"; }" f)
  (write-line "    : text { value = \"矩形1宽度 = 参数 × 5\"; }" f)
  (write-line "    : text { value = \"矩形2宽度 = (参数-10) × 5\"; }" f)
  (write-line "    : text { value = \"图层: 03Brace\"; }" f)
  (write-line "  }" f)

  (write-line "  : spacer { height = 1; }" f)

  ;; 绘制直线功能
  (write-line "  : boxed_column { label = \"绘制直线\";" f)
  (write-line "    : row { : text { label = \"起点 X:\"; width = 10; } : edit_box { key = \"line_sx\"; edit_width = 8; value = \"0\"; } : text { label = \"Y:\"; width = 3; } : edit_box { key = \"line_sy\"; edit_width = 8; value = \"0\"; } : text { label = \"Z:\"; width = 3; } : edit_box { key = \"line_sz\"; edit_width = 8; value = \"0\"; } }" f)
  (write-line "    : row { : text { label = \"终点 X:\"; width = 10; } : edit_box { key = \"line_ex\"; edit_width = 8; value = \"100\"; } : text { label = \"Y:\"; width = 3; } : edit_box { key = \"line_ey\"; edit_width = 8; value = \"100\"; } : text { label = \"Z:\"; width = 3; } : edit_box { key = \"line_ez\"; edit_width = 8; value = \"0\"; } }" f)
  (write-line "    : row { : text { label = \"颜色:\"; width = 10; } : popup_list { key = \"line_color\"; edit_width = 12; } }" f)
  (write-line "    : row { : button { label = \"绘制直线\"; key = \"btn_line\"; width = 20; fixed_width = true; } }" f)
  (write-line "  }" f)

  (write-line "  : spacer { height = 1; }" f)

  ;; 绘制圆形功能
  (write-line "  : boxed_column { label = \"绘制圆形\";" f)
  (write-line "    : row { : text { label = \"圆心 X:\"; width = 10; } : edit_box { key = \"circ_cx\"; edit_width = 8; value = \"0\"; } : text { label = \"Y:\"; width = 3; } : edit_box { key = \"circ_cy\"; edit_width = 8; value = \"0\"; } : text { label = \"Z:\"; width = 3; } : edit_box { key = \"circ_cz\"; edit_width = 8; value = \"0\"; } }" f)
  (write-line "    : row { : text { label = \"半径:\"; width = 10; } : edit_box { key = \"circ_radius\"; edit_width = 8; value = \"50\"; } }" f)
  (write-line "    : row { : text { label = \"颜色:\"; width = 10; } : popup_list { key = \"circ_color\"; edit_width = 12; } }" f)
  (write-line "    : row { : button { label = \"绘制圆形\"; key = \"btn_circle\"; width = 20; fixed_width = true; } }" f)
  (write-line "  }" f)

  (write-line "  : spacer { height = 1; }" f)
  (write-line "  ok_cancel;" f)
  (write-line "}" f)

  (close f)

  ;; 加载并显示对话框
  (setq dcl_id (load_dialog dcl_file))

  (if (not (new_dialog "yyr_dlg" dcl_id))
    (progn
      (princ "\n无法加载对话框")
      (exit)
    )
  )

  ;; 初始化颜色列表
  (start_list "line_color")
  (add_list "红色 (1)")
  (add_list "黄色 (2)")
  (add_list "绿色 (3)")
  (add_list "青色 (4)")
  (add_list "蓝色 (5)")
  (add_list "品红 (6)")
  (add_list "白色 (7)")
  (end_list)
  (set_tile "line_color" "0") ; 默认红色

  (start_list "circ_color")
  (add_list "红色 (1)")
  (add_list "黄色 (2)")
  (add_list "绿色 (3)")
  (add_list "青色 (4)")
  (add_list "蓝色 (5)")
  (add_list "品红 (6)")
  (add_list "白色 (7)")
  (end_list)
  (set_tile "circ_color" "2") ; 默认绿色

  ;; 设置动作
  (action_tile "btn_brace" "(done_dialog 1)") ; Brace 按钮
  (action_tile "btn_line" "(done_dialog 2)")  ; 绘制直线按钮
  (action_tile "btn_circle" "(done_dialog 3)") ; 绘制圆形按钮
  (action_tile "accept" "(done_dialog 0)")      ; 确定按钮
  (action_tile "cancel" "(done_dialog -1)")    ; 取消按钮

  ;; 显示对话框
  (setq res (start_dialog))

  ;; 在卸载对话框之前读取所有 tile 值
  (setq brace_param     (atof (get_tile "brace_param")))
  (setq line_start_x    (atof (get_tile "line_sx")))
  (setq line_start_y    (atof (get_tile "line_sy")))
  (setq line_start_z    (atof (get_tile "line_sz")))
  (setq line_end_x      (atof (get_tile "line_ex")))
  (setq line_end_y      (atof (get_tile "line_ey")))
  (setq line_end_z      (atof (get_tile "line_ez")))
  (setq line_color      (+ 1 (atoi (get_tile "line_color"))))
  (setq circle_center_x (atof (get_tile "circ_cx")))
  (setq circle_center_y (atof (get_tile "circ_cy")))
  (setq circle_center_z (atof (get_tile "circ_cz")))
  (setq circle_radius   (atof (get_tile "circ_radius")))
  (setq circle_color    (+ 1 (atoi (get_tile "circ_color"))))

  ;; 卸载对话框并删除临时文件
  (unload_dialog dcl_id)
  (vl-file-delete dcl_file)

  ;; 处理结果
  (cond
    ;; Brace 功能
    ((= res 1)
      (if (or (not brace_param) (<= brace_param 10))
        (alert "参数必须是大于 10 的数字")
        (YYR_Brace brace_param)
      )
    )

    ;; 绘制直线
    ((= res 2)
      (YYR_DrawLine line_start_x line_start_y line_start_z line_end_x line_end_y line_end_z line_color)
    )

    ;; 绘制圆形
    ((= res 3)
      (YYR_DrawCircle circle_center_x circle_center_y circle_center_z circle_radius circle_color)
    )

    ;; 确定或取消
    (t
      (if (/= res -1)
        (prompt "\n命令已取消。")
      )
    )
  )

  (princ)
)

;; =============================================================================
;; 加载提示
;; =============================================================================

(princ "\n=============================================")
(princ "\n= YYR 绘图工具集已加载                 =")
(princ "\n= 输入 YYR 启动工具                    =")
(princ "\n= 版本: 1.0                            =")
(princ "\n=============================================")
(princ)
