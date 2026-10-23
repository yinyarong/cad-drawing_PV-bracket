(vl-load-com)

;; =============================================================================
;; 1. Excel Data Import & Logic (Eurocode / ASCE detection)
;; =============================================================================

(defun PVRectSgs_CellValueToString (val as_int / num)
  (cond
    ((or (null val) (= val :vlax-null)) "")
    ((numberp val)
     (if as_int (itoa (fix (+ val 0.5))) (rtos val 2 4))
    )
    ((= (type val) 'variant) (PVRectSgs_CellValueToString (vlax-variant-value val) as_int))
    (t
     (setq val (vl-string-trim " " (vl-princ-to-string val)))
     (if (= val "")
       ""
       (progn
         (setq num (distof val 2))
         (if num
           (if as_int (itoa (fix (+ num 0.5))) (rtos num 2 4))
           val
         )
       )
     )
    )
  )
)

(defun PVRectSgs_GetCellValueByAddr (sheet addr / range val)
  (setq val "")
  ;; WPS/Excel COM is more reliable here with property access than invoke.
  (setq range (vl-catch-all-apply 'vlax-get-property (list sheet "Range" addr)))
  (if (not (vl-catch-all-error-p range))
    (progn
      (setq val (vl-catch-all-apply 'vlax-get-property (list range "Value2")))
      (if (vl-catch-all-error-p val) 
          (setq val (vl-catch-all-apply 'vlax-get-property (list range "Value")))
      )
      (if (not (vl-catch-all-error-p val))
          (progn
             (if (= (type val) 'variant) (setq val (vlax-variant-value val)))
          )
          (setq val "")
      )
      (vlax-release-object range)
    )
  )
  val
)

(defun PVRectSgs_SnapDown (val step / snapped)
  (if (and step (> step 0.0))
    (progn
      (setq snapped (* step (fix (/ val step))))
      (if (> snapped val)
        (setq snapped (- snapped step))
      )
      snapped
    )
    val
  )
)

;; 计算点在斜轴线上的投影距离（从 axis_start 沿轴线方向到投影点的距离）
(defun PVRectSgs_GetProjectionDist (pt axis_start axis_end / axis_vec axis_len axis_dir pt_vec proj_dist)
  (setq axis_vec (list (- (car axis_end) (car axis_start)) (- (cadr axis_end) (cadr axis_start)))
        axis_len (distance axis_start axis_end)
        axis_dir (list (/ (car axis_vec) axis_len) (/ (cadr axis_vec) axis_len))
        pt_vec (list (- (car pt) (car axis_start)) (- (cadr pt) (cadr axis_start)))
        proj_dist (+ (* (car pt_vec) (car axis_dir)) (* (cadr pt_vec) (cadr axis_dir))))
  proj_dist
)

;; 设置动态块的可见性状态
(defun PVRectSgs_SetBlockVisibility (blk_ent visibility_state / blk_obj props prop_count i prop found prop_name prop_allowed_values)
  (setq blk_obj (vlax-ename->vla-object blk_ent))
  (prompt (strcat "\n>>> Attempting to set block visibility to: " visibility_state))
  (vl-catch-all-apply
    '(lambda ()
       (setq props (vlax-invoke blk_obj 'GetDynamicBlockProperties))
       (setq prop_count (vlax-get props 'Count))
       (setq i 0
             found nil)
       ;; 首先列出所有可用的动态属性
       (prompt (strcat "\n>>> Dynamic block properties count: " (itoa prop_count)))
       (while (< i prop_count)
         (setq prop (vlax-get props 'Item i))
         (vl-catch-all-apply
           '(lambda ()
              (setq prop_name (vlax-get-property prop 'PropertyName))
              ;; 只显示前几个字符，避免输出过长
              (if (< i 5)
                (prompt (strcat "\n    Property " (itoa i) ": " prop_name))
              )
              ;; 查找可见性属性
              (if (and (not found)
                       (or (= (strcase prop_name) "VISIBILITY")
                           (= (strcase prop_name) "VISIBLE")
                           (= (strcase prop_name) "VISIBILITY1")
                           (vl-string-search "VISIB" (strcase prop_name))))
                (progn
                  (prompt (strcat "\n>>> Found visibility property: " prop_name))
                  ;; 尝试获取允许值列表
                  (setq prop_allowed_values (vlax-get-property prop 'AllowedValues))
                  (prompt (strcat "\n>>> Allowed values: " (vl-princ-to-string prop_allowed_values)))
                  ;; 设置值
                  (vlax-put-property prop 'Value visibility_state)
                  (setq found T)
                  (prompt (strcat "\n>>> Successfully set visibility to: " visibility_state))
                )
              )
            )
         )
         (setq i (1+ i))
       )
       (if (not found)
         (prompt "\n>>> Warning: Visibility property not found!")
       )
       ;; 更新块参照
       (vlax-invoke blk_obj 'Update)
     )
  )
)

(defun PVRectSgs_FarFromPointsP (x pt_list min_dist / ok)
  (setq ok T)
  (while (and ok pt_list)
    (if (<= (abs (- x (car pt_list))) min_dist)
      (setq ok nil)
    )
    (setq pt_list (cdr pt_list))
  )
  ok
)

(defun PVRectSgs_UniqueSorted (vals / sorted out last_v)
  (setq sorted (vl-sort vals '<)
        out nil
        last_v nil)
  (foreach v sorted
    (if (or (null last_v) (> (abs (- v last_v)) 1e-6))
      (progn
        (setq out (cons v out))
        (setq last_v v)
      )
    )
  )
  (reverse out)
)

(defun PVRectSgs_BuildPVVerticalXs (pt_x w_eval gap m / xs i x_left)
  (setq xs nil
        i 0)
  (while (< i m)
    (setq x_left (+ pt_x (* i (+ w_eval gap))))
    (setq xs (cons (+ x_left w_eval) (cons x_left xs)))
    (setq i (1+ i))
  )
  (PVRectSgs_UniqueSorted xs)
)

(defun PVRectSgs_BuildBreakCandidates (start_x end_x axis_list pv_x_list zd_eval sf / min_off max_off step clear_dist axis window_start window_end pos candidates)
  (setq min_off (* 0.2 zd_eval)
        max_off (* 0.4 zd_eval)
        step (* 5.0 sf)
        clear_dist (* 300.0 sf)
        candidates nil)
  (foreach axis axis_list
    (setq window_start (+ axis min_off)
          window_end (+ axis max_off))
    (if (and (> window_end start_x) (< window_start end_x))
      (progn
        (setq pos (PVRectSgs_SnapDown (min window_end end_x) step))
        (while (>= pos window_start)
          (if (and (> pos start_x)
                   (< pos end_x)
                   (PVRectSgs_FarFromPointsP pos pv_x_list clear_dist))
            (setq candidates (cons pos candidates))
          )
          (setq pos (- pos step))
        )
      )
    )
  )
  (PVRectSgs_UniqueSorted candidates)
)

(defun PVRectSgs_FindBreakPath (start_x end_x candidates max_len / total n_segs ideal_len breaks i ideal_x best_c best_dist prev_x c d valid)
  (if (<= (- end_x start_x) max_len)
    nil
    (progn
      ;; Minimum segments needed and ideal equal length per segment
      (setq total     (- end_x start_x)
            n_segs    (1+ (fix (/ (- total 1e-9) max_len)))
            ideal_len (/ total (float n_segs))
            breaks    nil
            prev_x    start_x
            valid     T
            i         1)
      ;; Place n_segs-1 break points, each as close to its ideal position as possible
      (while (and valid (< i n_segs))
        (setq ideal_x   (+ start_x (* ideal_len i))
              best_c    nil
              best_dist 1e99)
        (foreach c candidates
          (if (and (> c prev_x)
                   (<= (- c prev_x) max_len))
            (progn
              (setq d (abs (- c ideal_x)))
              (if (< d best_dist)
                (setq best_c    c
                      best_dist d)
              )
            )
          )
        )
        (if best_c
          (setq breaks (append breaks (list best_c))
                prev_x best_c)
          (setq valid nil)
        )
        (setq i (1+ i))
      )
      ;; Final segment must also fit within max_len
      (if (and valid (> (- end_x prev_x) max_len))
        (setq valid nil)
      )
      (if valid breaks 'pvrect_fail)
    )
  )
)

(defun PVRectSgs_AddSegmentedHorizontalDim (start_x end_x axis_y dim_y axis_list pt_x w_eval gap m zd_eval sf / max_seg_len pv_x_list candidates breaks prev_x next_x)
  (setq max_seg_len (* 11500.0 sf)
        pv_x_list (PVRectSgs_BuildPVVerticalXs pt_x w_eval gap m)
        candidates (PVRectSgs_BuildBreakCandidates start_x end_x axis_list pv_x_list zd_eval sf)
        breaks (PVRectSgs_FindBreakPath start_x end_x candidates max_seg_len))
  (if (= breaks 'pvrect_fail)
    (progn
      (prompt "\n>>> Warning: segmented top dim could not satisfy all constraints; using single total dimension.")
      (command "_.DIMLINEAR"
               "_NON" (list start_x axis_y 0.0)
               "_NON" (list end_x axis_y 0.0)
               "_NON" (list start_x dim_y 0.0))
      (setq breaks nil)
    )
    (progn
      (setq prev_x start_x)
      (foreach next_x (append breaks (list end_x))
        (command "_.DIMLINEAR"
                 "_NON" (list prev_x axis_y 0.0)
                 "_NON" (list next_x axis_y 0.0)
                 "_NON" (list prev_x dim_y 0.0))
        (setq prev_x next_x)
      )
    )
  )
  breaks
)

;; 文件修改时间 -> 可比较的数值（vl-file-systime: 年 月 星期 日 时 分 秒 毫秒）
(defun PVRectSgs_SystimeKey (st)
  (if st
    (+ (* (nth 0 st) 1e10) (* (nth 1 st) 1e8) (* (nth 3 st) 1e6)
       (* (nth 4 st) 1e4) (* (nth 5 st) 100.0) (nth 6 st))
    0.0
  )
)

;; 列出目录下的 Excel 文件：去重（Windows 下 *.xls 也会匹配 .xlsx）、排除 ~$ 锁文件，
;; 按修改时间从新到旧排序
(defun PVRectSgs_ListExcelFiles (dir / files out)
  (setq files (append
                (vl-directory-files dir "*.xlsx" 1)
                (vl-directory-files dir "*.xlsm" 1)
                (vl-directory-files dir "*.xlsb" 1)
                (vl-directory-files dir "*.xls" 1))
        out nil)
  (foreach f files
    (if (and (wcmatch (strcase f) "*.XLSX,*.XLSM,*.XLSB,*.XLS")
             (not (= (substr f 1 2) "~$"))
             (not (member (strcase f) (mapcar 'strcase out))))
      (setq out (cons f out))
    )
  )
  (vl-sort out
    '(lambda (a b)
       (> (PVRectSgs_SystimeKey (vl-file-systime (strcat dir a)))
          (PVRectSgs_SystimeKey (vl-file-systime (strcat dir b))))))
)

;; 工作表名“数据填写”：先按 GBK 字节构造（中文代码页），再按 Unicode 码点构造（AutoCAD 2021+）
(defun PVRectSgs_TargetSheetNames ( / names uni)
  (setq names (list (vl-list->string '(202 253 190 221 204 238 208 180))))
  (setq uni (vl-catch-all-apply '(lambda () (apply 'strcat (mapcar 'chr '(25968 25454 22635 20889))))))
  (if (and (not (vl-catch-all-error-p uni)) (= (type uni) 'STR) (not (member uni names)))
    (setq names (append names (list uni)))
  )
  names
)

(defun PVRectSgs_ReadExcelDefaults ( / dwg_dir excel_files excel_path excel_app workbooks workbook sheets sheet result err i count name found is_euro header_b3 header_c3 e11_val target_name target_sheet_name app_created wb_opened val open_err_msg b7_txt c7_txt d9_txt e9_txt b13_txt c13_txt score best_score best_sheet best_name sheet_name raw_c9 num_c9 final_c9 old_alerts)
  (setq dwg_dir (getvar "DWGPREFIX"))
  (cond
    ((or (null dwg_dir) (= dwg_dir ""))
     (prompt "\n>>> Please save the drawing first.")
     nil
    )
    (t
     (setq excel_files (PVRectSgs_ListExcelFiles dwg_dir))
     (if (null excel_files)
       (progn
         (prompt "\n>>> No Excel file found in the current drawing folder.")
         nil
       )
       (progn
         (if (> (length excel_files) 1)
           (prompt (strcat "\n>>> " (itoa (length excel_files)) " Excel files found, using the most recently modified one."))
         )
         (prompt (strcat "\n>>> Excel file: " (car excel_files)))
         (setq excel_path (strcat dwg_dir (car excel_files)))
         (if (not (findfile excel_path))
           (progn
             (prompt (strcat "\n>>> Excel read error: file not found: " excel_path))
             (setq err nil result nil)
           )
           (setq err
            (vl-catch-all-apply
              '(lambda ()
                 (setq excel_app (vl-catch-all-apply 'vlax-get-object (list "Excel.Application")))
                (if (or (vl-catch-all-error-p excel_app) (null excel_app))
                  (progn
                    (setq excel_app (vlax-get-or-create-object "Excel.Application"))
                    (setq app_created T)
                  )
                  (setq app_created nil)
                )

                ;; 只隐藏我们自己启动的 Excel；复用用户已打开的实例时不改变其可见性
                (if app_created
                  (vlax-put-property excel_app "Visible" :vlax-false)
                )
                (setq old_alerts (vl-catch-all-apply 'vlax-get-property (list excel_app "DisplayAlerts")))
                (if (vl-catch-all-error-p old_alerts) (setq old_alerts nil))
                (vlax-put-property excel_app "DisplayAlerts" :vlax-false)

                (setq excel_path (vl-string-translate "/" "\\" excel_path))
                (setq workbooks (vlax-get-property excel_app "Workbooks"))
                (setq i 1
                      count (vlax-get-property workbooks "Count")
                      found nil
                      wb_opened nil)

                (while (and (<= i count) (not found))
                  (setq workbook (vlax-get-property workbooks "Item" i))
                  (setq name (vl-catch-all-apply 'vlax-get-property (list workbook "Name")))
                  (if (not (vl-catch-all-error-p name))
                    (progn
                      (setq name (vl-princ-to-string name))
                      (if (= (strcase name) (strcase (car excel_files)))
                        (progn
                          (setq found T)
                          (setq wb_opened T)
                        )
                        (progn
                          (vlax-release-object workbook)
                          (setq i (1+ i))
                        )
                      )
                    )
                    (progn
                      (vlax-release-object workbook)
                      (setq i (1+ i))
                    )
                  )
                )

                (if (not found)
                  (progn
                    (setq open_err_msg nil)
                    (setq workbook
                      (vl-catch-all-apply 'vlax-invoke (list workbooks "Open" excel_path))
                    )
                    (if (vl-catch-all-error-p workbook)
                      (setq open_err_msg (vl-catch-all-error-message workbook))
                    )
                    ;; Fallback only if the normal writable open fails.
                    (if (vl-catch-all-error-p workbook)
                      (setq workbook
                        (vl-catch-all-apply 'vlax-invoke (list workbooks "Open" excel_path :vlax-false :vlax-true))
                      )
                    )
                    (if (vl-catch-all-error-p workbook)
                      (setq open_err_msg (vl-catch-all-error-message workbook))
                    )
                  )
                )

                (if (or (null workbook) (vl-catch-all-error-p workbook))
                  (setq result nil)
                  (progn
                    (setq sheets (vlax-get-property workbook "Sheets"))
                    (setq sheet nil)
                    (foreach target_name (PVRectSgs_TargetSheetNames)
                      (if (or (null sheet) (vl-catch-all-error-p sheet))
                        (setq target_sheet_name target_name
                              sheet (vl-catch-all-apply 'vlax-get-property (list sheets "Item" target_name)))
                      )
                    )

                    (if (or (null sheet) (vl-catch-all-error-p sheet))
                      (progn
                        (setq sheet nil)
                        (setq result nil)
                        (setq open_err_msg (strcat "worksheet not found: " target_sheet_name))
                      )
                      (progn
                        (setq sheet_name target_sheet_name)
                        (setq header_b3 (vl-princ-to-string (PVRectSgs_GetCellValueByAddr sheet "B3")))
                        (setq header_c3 (vl-princ-to-string (PVRectSgs_GetCellValueByAddr sheet "C3")))
                        (setq e11_val (PVRectSgs_GetCellValueByAddr sheet "E11"))
                        (setq b7_txt  (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "B7") nil))
                        (setq c7_txt  (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "C7") nil))
                        (setq d9_txt  (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "D9") T))
                        (setq e9_txt  (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "E9") T))
                        (setq b13_txt (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "B13") T))
                        (setq c13_txt (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "C13") T))

                        (setq is_euro
                          (or
                            (vl-string-search "V1.2" excel_path)
                            (vl-string-search "EN1990" header_b3)
                            (vl-string-search "EN1990" header_c3)
                            (and (distof (PVRectSgs_CellValueToString e11_val nil) 2)
                                 (< (distof (PVRectSgs_CellValueToString e11_val nil) 2) 100))
                            (and (numberp e11_val) (< e11_val 100))
                          )
                        )

                        (if is_euro
                          (setq result
                            (list
                              (cons "val_h"    (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "B7") nil))
                              (cons "val_w"    (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "C7") nil))
                              (cons "val_n"    (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "B13") T))
                              (cons "val_m"    (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "C13") T))
                              (cons "val_hole" "1400")
                              (cons "val_zn"   (if (numberp e11_val)
                                                 (itoa (1+ (fix (+ e11_val 0.5))))
                                                 (PVRectSgs_CellValueToString e11_val T)))
                              (cons "val_zd"   (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "D11") nil))
                            )
                          )
                          (progn
                            (setq raw_c9 (PVRectSgs_GetCellValueByAddr sheet "C9")
                                  num_c9 (if (numberp raw_c9) raw_c9 (distof (PVRectSgs_CellValueToString raw_c9 nil) 2))
                                  final_c9 (if num_c9 (PVRectSgs_CellValueToString (* num_c9 1000.0) nil) (PVRectSgs_CellValueToString raw_c9 nil)))
                            (setq result
                              (list
                                (cons "val_h"    (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "B7") nil))
                                (cons "val_w"    (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "C7") nil))
                                (cons "val_n"    (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "D9") T))
                                (cons "val_m"    (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "E9") T))
                                (cons "val_hole" (if (= (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "D13") nil) "")
                                                   "1400"
                                                   (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "D13") nil)))
                                (cons "val_zn"   (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "D11") T))
                                (cons "val_zd"   (PVRectSgs_CellValueToString e11_val nil))
                                (cons "val_clearance" final_c9)
                                (cons "val_angle"     (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "F9") nil))
                                (cons "val_nop"       (PVRectSgs_CellValueToString (PVRectSgs_GetCellValueByAddr sheet "B13") T))
                              )
                            )
                          )
                        )
                      )
                    )
                  )
                )
             )
             '()
           )
         ))

         (if (and workbook (not wb_opened))
           (vl-catch-all-apply 'vlax-invoke (list workbook "Close" :vlax-false))
         )
         (if (and excel_app (= (type excel_app) 'VLA-OBJECT) (not app_created) old_alerts)
           (vl-catch-all-apply 'vlax-put-property (list excel_app "DisplayAlerts" old_alerts))
         )
         (if (and excel_app app_created)
           (vl-catch-all-apply 'vlax-invoke (list excel_app "Quit"))
         )

         (foreach obj (list sheet sheets workbook workbooks excel_app)
           (if (and obj (= (type obj) 'VLA-OBJECT))
             (vlax-release-object obj)
           )
         )
         (gc)

         (if (vl-catch-all-error-p err)
           (progn
             (prompt (strcat "\n>>> Excel read error: " (vl-catch-all-error-message err)))
             nil
           )
           (if result
             (progn
              (if is_euro
                (prompt "\n>>> Eurocode template detected.")
                (prompt "\n>>> ASCE template detected.")
              )
              (prompt (strcat "\n>>> Excel sheet: " sheet_name))
              (prompt (strcat "\n>>> B7=" b7_txt " C7=" c7_txt " D9=" d9_txt " E9=" e9_txt " B13=" b13_txt " C13=" c13_txt))
              result
            )
              (progn
                (prompt (strcat "\n>>> Excel read error: " (if open_err_msg open_err_msg "unknown error")))
                nil
              )
            )
         )
       )
     )
    )
  )
)

(defun PVRectSgs_ImportExcel ( / data item key val)
  (setq data (PVRectSgs_ReadExcelDefaults))
  (if data
    (progn
      (foreach item data
        (setq key (car item) val (cdr item))
        (if (= key "val_nop")
          (set_tile key (if (= val "3") "1" "0"))
          (set_tile key val)
        )
        (cond
          ((= key "val_h")    (setq h_str    val))
          ((= key "val_w")    (setq w_str    val))
          ((= key "val_n")    (setq n_str    val))
          ((= key "val_m")    (setq m_str    val))
          ((= key "val_hole") (setq hole_str val))
          ((= key "val_zn")   (setq zn_str   val))
          ((= key "val_zd")   (setq zd_str   val) (set_tile "val_zde" val) (setq zde_str val))
          ((= key "val_clearance") (setq clearance_str val))
          ((= key "val_angle")     (setq angle_str val))
          ((= key "val_nop")       (setq nop_str (if (= val "3") "3" "2")))
        )
      )
      (prompt "\n>>> Excel data imported.")
    )
    (prompt "\n>>> Import failed.")
  )
  (princ)
)

;; =============================================================================
;; 2. Post-processing (Stable logic from v33/v34)

;; 根据 purlin_H (mm) 找最近的 Purlin-Bracket-XX 块（XX 为 5mm 步进，最小 60）
;; 返回块名字符串，若范围内无任何块则返回 nil
;; 从 h_round 开始向外扩展搜索，每次 ±5mm，先查低侧再查高侧
(defun PVRectSgs_FindPurlinBlock (purlin_H / h_round step found_name)
  (setq h_round (max 60 (* 5 (fix (/ (+ purlin_H 2.5) 5.0))))
        found_name nil
        step 0)
  (while (and (null found_name) (<= step 35))
    ;; 先尝试 h_round-step（含 step=0 即精确值）
    (if (and (>= (- h_round step) 60)
             (tblsearch "BLOCK" (strcat "Purlin-Bracket-" (itoa (- h_round step)))))
      (setq found_name (strcat "Purlin-Bracket-" (itoa (- h_round step))))
    )
    ;; 再尝试 h_round+step（step>0 时才有意义）
    (if (and (null found_name) (> step 0)
             (tblsearch "BLOCK" (strcat "Purlin-Bracket-" (itoa (+ h_round step)))))
      (setq found_name (strcat "Purlin-Bracket-" (itoa (+ h_round step))))
    )
    (if (null found_name) (setq step (+ step 5)))
  )
  found_name
)
;;
;; 生成的轴线类型说明：
;; - post-axis: 右侧图形中的两根竖向立柱轴线（U1, U2）
;; - beam-angle-axis: 沿 angle 方向的斜轴线
;; - brace-axis: 连接 post-axis 与 beam-angle-axis 的斜向连接轴线
;; =============================================================================

(defun PVRectSgs_PostFix ( / e_cur ss idx ent err minpt maxpt pt_min global_min_y title_y t1_str e_t1 tb t1_width t1_minX t1_maxX gap_ext line_x1 line_x2 line_top_y line_bot_y t2_x ss_copy e_cur_copy edata ss_copy_sf copy_dist y_a y_b i vx_list bottom_y bottom_dim_y lower_top_axis_y lower_top_dim_y lower_bottom_axis_y lower_bottom_dim_y post1_top_y post1_bot_y post2_top_y post2_bot_y post_half_w1 post_half_w2 purlin_H_cad purlin_bot_y beam_axis_y ss_scaled_all ss_purlin ss_beam ss_post ss_brace ss_new_purlin ent_before en_new purlin_xlist split_idx k px tgt scale_center axis_copy_dist ss_del e_del postfix_start_ent post_copy_list beam_y_scaled post_bot_clamp post_top_clamp ss_bt pt10 pt11 y10 y11 new_y10 new_y11 U1_top_clamp U2_top_clamp sorted_posts clip_pairs pair brace_ext_cad brace_dx brace_dy brace_len brace_nx brace_ny brace_mid_x brace_mid_y brace_perp_x brace_perp_y brace_hl brace_hw1 brace_hw2 dim_perp_x dim_perp_y brace_dim_x brace_dim_y post_mid_y post_dim_x brace_all_info cps_copy_cx blp top_code bot_code top_pt bot_pt new_top new_bot conn_half_x conn_cx_l conn_cx_r obrace_conn_block ax_line_len ax_r ax_cy ax_th ax_dim_y ax_n ax_vx_prev ax_vx_next a1 a2 al ang_align_x ang_rad ar ax_l_ox ax_l_oy ax_l_rot ax_l_rx ax_l_ry ax_r_ox ax_r_oy ax_r_rot ax_r_rx ax_r_ry axis_angle axis_end_pt axis_start_pt axis_total_len axis_x1 axis_x2 axis_x_mid beam_dy_per_dx beam_half_h beam_half_h2 block_name brace_int1_x brace_int1_y brace_int2_x brace_int2_y cps_bdim_pos_l cps_bdim_pos_r cps_bext_l_bot cps_bext_l_top cps_bext_r_bot cps_bext_r_top cps_blp1 cps_blp2 cps_blp3 cps_blp4 cps_bperp_l cps_bperp_r cps_brace_bot_y cps_brace_top_l cps_brace_top_r cps_brace_xoff cps_brp1 cps_brp2 cps_brp3 cps_brp4 cps_hw_new cps_hy_new cps_hy_new2 cps_nut_xoff cps_post_bot cps_post_hw1 cps_post_hw2 cps_post_top cps_post_x cps_post_y cps_split_offset cur_pv_x cy dim_loc_x dim_loc_y dim_loc_y2 dim_nx dim_ny dim_offset e_elev elev_center_x elev_line_bot_y elev_line_top_y elev_line_x1 elev_line_x2 elev_t1_maxx elev_t1_minx elev_t1_str elev_t1_width elev_title_y en half_d key_points l_span line_end_pt line_end_r_pt line_end_r_x line_end_r_y line_end_x line_end_y line_start_r_x line_start_r_y line_start_x line_start_y max_axis_x mid_orig_x mid_orig_y mid_x mid_y min_axis_x my_breaks new_line_x1 new_line_x2 next_pv_x obolt_offset_cad offset_dist opost_ang_arc_x opost_ang_arc_y opost_ang_t opost_ang_vx opost_base_dist opost_post_x1 opost_post_x2 opost_tri_dist_cad opost_tri_top_y1 opost_tri_top_y2 p1 p2 pi_idx post1_x post2_x pv_p1_x pv_p1_y pv_p2_x pv_p2_y pv_start_x pv_start_y r1 r2 rect_half_h rect_half_w rl rr screw_pile_block seg1_loc_x seg1_loc_y seg1_mid_x seg1_mid_y seg2_loc_x seg2_loc_y seg2_mid_x seg2_mid_y seg3_loc_x seg3_loc_y seg3_mid_x seg3_mid_y seg4_loc_x seg4_loc_y seg4_mid_x seg4_mid_y sorted_points sp_vla ss_obs ss_pv target_w_cad target_w_phys tb_elev total_dim_loc_x total_dim_loc_y total_dim_offset total_mid_x total_mid_y tri_conn_block u1_clamp_y u1_orig_x u1_rot u1_rot_x u1_rot_y u2_clamp_y u2_orig_x u2_rot u2_rot_x u2_rot_y w_phys_max sp_bbmin sp_bbmax)
  ;; For C/O-post: capture last entity before PostFix draws anything.
  ;; This boundary covers the main array AND any ZHWBZH_Singsun-generated entities.
  (setq postfix_start_ent (if (not (= *sg_global_elev_type* 0)) (entlast) nil))
  ;; Create upper "Module layout" title (axis bubbles/dims handled by c:ZHWBZH_Singsun before PostFix)
  (if (and (= *sg_global_elev_type* 0) *sg_global_n* *sg_global_m* *sg_global_center_x*)
    (progn
      (if (not (tblsearch "STYLE" "TIMES")) (entmake '((0 . "STYLE") (100 . "AcDbSymbolTableRecord") (100 . "AcDbTextStyleTableRecord") (2 . "TIMES") (70 . 0) (40 . 0.0) (41 . 1.0) (3 . "times.ttf"))))
      (if (not (tblsearch "LAYER" "NUM")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "NUM") (70 . 0) (62 . 7))))
      (setq title_y (if *sg_global_bottom_y*
                         (- *sg_global_bottom_y* (* 3200.0 (if *sg_global_sf* *sg_global_sf* 2.0)))
                         (if *sg_global_bottom_dim_y* *sg_global_bottom_dim_y* (- *sg_global_axis_y2_baseline* 6500.0))))
      (setq t1_str (strcat (itoa *sg_global_n*) "x" (itoa *sg_global_m*) " Module layout"))
      (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES") (cons 10 (list *sg_global_center_x* title_y 0)) (cons 40 550.0) (cons 1 t1_str) '(72 . 1) (cons 11 (list *sg_global_center_x* title_y 0))))
      (setq e_t1 (entlast) *sg_title_ents_list* (list e_t1))
      (setq tb (textbox (entget e_t1)) t1_width (- (caadr tb) (caar tb)) t1_minX (- *sg_global_center_x* (/ t1_width 2.0)) t1_maxX (+ *sg_global_center_x* (/ t1_width 2.0)))
      (setq gap_ext 300.0 line_x1 (- t1_minX gap_ext) line_x2 (+ t1_maxX gap_ext) line_top_y (- title_y 250.0) line_bot_y (- line_top_y 150.0))
      (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "DIM") '(90 . 2) (cons 43 50.0) (list 10 line_x1 line_top_y) (list 10 line_x2 line_top_y)))
      (setq *sg_title_ents_list* (append *sg_title_ents_list* (list (entlast))))
      (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "DIM") '(90 . 2) '(43 . 0.0)  (list 10 line_x1 line_bot_y) (list 10 line_x2 line_bot_y)))
      (setq *sg_title_ents_list* (append *sg_title_ents_list* (list (entlast))))
      (setq t2_x (+ line_x2 400.0))
      (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES") (cons 10 (list t2_x title_y 0)) (cons 40 400.0) (cons 1 "1:50") '(72 . 0) (cons 11 (list t2_x title_y 0))))
      (setq *sg_title_ents_list* (append *sg_title_ents_list* (list (entlast))))
    )
  )
  (command "_.-LAYER" "_ON" "purlin,beam" "")
  (if *sg_global_h*
    (progn
      (setq ss_copy (ssadd))
      (if *sg_first_ent_global* (setq e_cur_copy (entnext *sg_first_ent_global*)) (setq e_cur_copy (entnext)))
      (while e_cur_copy
        (setq edata (entget e_cur_copy))
        (if (and (not (= (strcase (cdr (assoc 8 edata))) "PV")) (not (member e_cur_copy *sg_title_ents_list*)) (not (member e_cur_copy *sg_left_dims_global*)) (not (member e_cur_copy *sg_top_dims_global*)) (not (member e_cur_copy *sg_upper_only_ents*)))
          (ssadd e_cur_copy ss_copy)
        )
        (setq e_cur_copy (entnext e_cur_copy))
      )
      (if (> (sslength ss_copy) 0)
        (progn
          (setq ss_copy_sf (if *sg_global_sf* *sg_global_sf* 2.0))
          (setq copy_dist (* (+ 5000.0 (* 2.0 *sg_global_h*)) ss_copy_sf))
          (if (= *sg_global_elev_type* 0)
            (progn
              (command "_.COPY" ss_copy "" "_NON" '(0.0 0.0 0.0) "_NON" (list 0.0 (- copy_dist) 0.0))
              (if (and *sg_global_n* *sg_global_m* *sg_global_center_x* title_y)
                (progn
                  (setq title_y (- title_y copy_dist))
                  (setq t1_str (strcat (itoa *sg_global_n*) "x" (itoa *sg_global_m*) " PV Mount Structure Layout"))
                  (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES") (cons 10 (list *sg_global_center_x* title_y 0)) (cons 40 550.0) (cons 1 t1_str) '(72 . 1) (cons 11 (list *sg_global_center_x* title_y 0))))
                  (setq e_t1 (entlast) tb (textbox (entget e_t1)) t1_width (- (caadr tb) (caar tb)) t1_minX (- *sg_global_center_x* (/ t1_width 2.0)) t1_maxX (+ *sg_global_center_x* (/ t1_width 2.0)))
                  (setq gap_ext 300.0 line_x1 (- t1_minX gap_ext) line_x2 (+ t1_maxX gap_ext) line_top_y (- title_y 250.0) line_bot_y (- line_top_y 150.0))
                  (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "DIM") '(90 . 2) (cons 43 50.0) (list 10 line_x1 line_top_y) (list 10 line_x2 line_top_y)))
                  (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "DIM") '(90 . 2) '(43 . 0.0)  (list 10 line_x1 line_bot_y) (list 10 line_x2 line_bot_y)))
                  (setq t2_x (+ line_x2 400.0))
                  (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES") (cons 10 (list t2_x title_y 0)) (cons 40 400.0) (cons 1 "1:50") '(72 . 0) (cons 11 (list t2_x title_y 0))))
                )
              )
            )
            (setq copy_dist 0.0)
          )
          (if (and *sg_global_axis_y_list* *sg_global_startX* *sg_global_dim_x_vert*)
            (progn
               (if (not (tblsearch "LAYER" "DIM")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "DIM") (70 . 0) (62 . 7))))
               (setvar "CLAYER" "DIM")
               (if (tblsearch "DIMSTYLE" "TSSD_50_100") (command "-DIMSTYLE" "_R" "TSSD_50_100"))
               (setq lower_top_axis_y (- (apply 'max *sg_global_axis_y_list*) copy_dist)
                     lower_top_dim_y (+ lower_top_axis_y (* 800.0 ss_copy_sf))
                     lower_bottom_axis_y (- (apply 'min *sg_global_axis_y_list*) copy_dist)
                     lower_bottom_dim_y (- lower_bottom_axis_y (* 800.0 ss_copy_sf)))
                     
               ;; 右侧立面图：仅在 elevation != No 时绘制水平基线及全部内容
               (if (and *sg_global_clearance* (not (= *sg_global_elev_type* 0)))
                 (progn
                   ;; 在下图最上方横向 AXIS 轴线右侧端点处往右 4000 画 22000 长的水平线
                   (setq new_line_x1 (+ *sg_global_endX* 4000.0)
                         new_line_x2 (+ new_line_x1 22000.0)
                         *sg_global_new_line_x1* new_line_x1)
                   (entmake (list '(0 . "LINE")
                                  '(8 . "DIM")
                                  (cons 10 (list new_line_x1 lower_top_axis_y 0.0))
                                  (cons 11 (list new_line_x2 lower_top_axis_y 0.0))))
                   (if (not (tblsearch "LAYER" "PV")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "PV") (70 . 0) (62 . 7))))
                   (if (not (tblsearch "LAYER" "AXIS")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "AXIS") (70 . 0) (62 . 1))))
                   (setvar "CLAYER" "PV")
                   (setq pv_start_x new_line_x1
                         pv_start_y (+ lower_top_axis_y (* *sg_global_clearance* 5.0))
                         purlin_H_cad (* (if *sg_global_purlin_H* *sg_global_purlin_H* 80.0) 5.0)
                         purlin_bot_y (- pv_start_y purlin_H_cad)
                         beam_axis_y  (- purlin_bot_y (* (if *sg_global_beam_h* *sg_global_beam_h* 100.0) 2.5))
                         pi_idx 0
                         ss_pv (ssadd)
                         min_axis_x nil
                         max_axis_x nil)
                   (setq *sg_elev_purlin_ents* nil *sg_elev_cross_ent* nil *sg_elev_beam_ent* nil *sg_elev_post_ents* nil *sg_elev_brace_ents* nil *sg_brace_track_ents* nil *sg_brace_vis_ents* nil *sg_opost_brace_src_ents* nil *sg_opost_screw_pile_bot_y* nil)
                   (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
                   (while (< pi_idx *sg_global_n*)
                     (setq cur_pv_x (+ pv_start_x (* pi_idx (* (+ *sg_global_h* 20.0) 5.0)))
                           pv_p1_x cur_pv_x
                           pv_p1_y pv_start_y
                           pv_p2_x (+ cur_pv_x (* *sg_global_h* 5.0))
                           pv_p2_y (+ pv_start_y (* 30.0 5.0)))
                     ;; 画 PV 矩形
                     (setvar "CLAYER" "PV")
                     (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "PV") '(90 . 4) '(70 . 1)
                                    (list 10 pv_p1_x pv_p1_y)
                                    (list 10 pv_p2_x pv_p1_y)
                                    (list 10 pv_p2_x pv_p2_y)
                                    (list 10 pv_p1_x pv_p2_y)))
                     (ssadd (entlast) ss_pv)
                     
                     ;; 画每块 PV 对应的向下短支架线 (图形为 AXIS，根据 *sg_global_nop* 决定 2 根还是 3 根)
                     (if (and *sg_global_hole* *sg_global_h*)
                       (progn
                         (if (not (tblsearch "LAYER" "AXIS")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "AXIS") (70 . 0) (62 . 1))))
                         (setq axis_x1 (+ cur_pv_x (* (/ (- *sg_global_h* *sg_global_hole*) 2.0) 5.0))
                               axis_x2 (+ axis_x1 (* *sg_global_hole* 5.0)))
                         ;; 短支架轴线：从 PV 底部延伸至梁中心轴（beam_axis_y），使端点落在 beam-angle-axis 上
                         (setvar "CLAYER" "AXIS")
                         (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                        (cons 10 (list axis_x1 pv_start_y 0.0))
                                        (cons 11 (list axis_x1 beam_axis_y 0.0))))
                         (ssadd (entlast) ss_pv)
                         (setq *sg_elev_purlin_ents* (cons (entlast) *sg_elev_purlin_ents*))

                         (if (and *sg_global_nop* (= *sg_global_nop* 3))
                           (progn
                             (setq axis_x_mid (/ (+ axis_x1 axis_x2) 2.0))
                             (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                            (cons 10 (list axis_x_mid pv_start_y 0.0))
                                            (cons 11 (list axis_x_mid beam_axis_y 0.0))))
                             (ssadd (entlast) ss_pv)
                             (setq *sg_elev_purlin_ents* (cons (entlast) *sg_elev_purlin_ents*))
                           )
                         )

                         (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                        (cons 10 (list axis_x2 pv_start_y 0.0))
                                        (cons 11 (list axis_x2 beam_axis_y 0.0))))
                         (ssadd (entlast) ss_pv)
                         (setq *sg_elev_purlin_ents* (cons (entlast) *sg_elev_purlin_ents*))

                         ;; 按 purlin_H 选取对应的 Purlin-Bracket-XX 块。
                         ;; 插入点 = purlin_bot_y（梁顶面 = 支架底部），使支架底部贴梁、顶部贴 PV 底线，
                         ;; 夹在 PV 底线与梁矩形之间。整个 ss_pv 组随后绕 pv_start 旋转 *sg_global_angle* 度。
                         (setq block_name (PVRectSgs_FindPurlinBlock (if *sg_global_purlin_H* *sg_global_purlin_H* 80.0)))
                         (if block_name
                           (progn
                             (entmake (list '(0 . "INSERT") (cons 2 block_name) '(8 . "AXIS")
                                            (cons 10 (list axis_x1 purlin_bot_y 0.0))
                                            '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                             (ssadd (entlast) ss_pv)

                             (if (and *sg_global_nop* (= *sg_global_nop* 3))
                               (progn
                                 (entmake (list '(0 . "INSERT") (cons 2 block_name) '(8 . "AXIS")
                                                (cons 10 (list axis_x_mid purlin_bot_y 0.0))
                                                '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                                 (ssadd (entlast) ss_pv)
                               )
                             )

                             (entmake (list '(0 . "INSERT") (cons 2 block_name) '(8 . "AXIS")
                                            (cons 10 (list axis_x2 purlin_bot_y 0.0))
                                            '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                             (ssadd (entlast) ss_pv)
                             (prompt (strcat "\n>>> Purlin bracket block: " block_name))
                           )
                           (prompt "\n>>> Warning: no Purlin-Bracket-XX block found within +/-35mm of purlin H.")
                         )
                         
                         ;; 创建分段标注 (图层为 DIM，斜向上500)
                         (setvar "CLAYER" "DIM")
                         (setq dim_loc_y (+ pv_p2_y 500.0))
                         (command "_.DIMALIGNED" "_NON" (list cur_pv_x pv_p2_y 0.0) "_NON" (list axis_x1 pv_p2_y 0.0) "_NON" (list (/ (+ cur_pv_x axis_x1) 2.0) dim_loc_y 0.0))
                         (ssadd (entlast) ss_pv)
                         
                         (if (and *sg_global_nop* (= *sg_global_nop* 3))
                           (progn
                             (command "_.DIMALIGNED" "_NON" (list axis_x1 pv_p2_y 0.0) "_NON" (list axis_x_mid pv_p2_y 0.0) "_NON" (list (/ (+ axis_x1 axis_x_mid) 2.0) dim_loc_y 0.0))
                             (ssadd (entlast) ss_pv)
                             (command "_.DIMALIGNED" "_NON" (list axis_x_mid pv_p2_y 0.0) "_NON" (list axis_x2 pv_p2_y 0.0) "_NON" (list (/ (+ axis_x_mid axis_x2) 2.0) dim_loc_y 0.0))
                             (ssadd (entlast) ss_pv)
                           )
                           (progn
                             (command "_.DIMALIGNED" "_NON" (list axis_x1 pv_p2_y 0.0) "_NON" (list axis_x2 pv_p2_y 0.0) "_NON" (list (/ (+ axis_x1 axis_x2) 2.0) dim_loc_y 0.0))
                             (ssadd (entlast) ss_pv)
                           )
                         )
                         
                         (command "_.DIMALIGNED" "_NON" (list axis_x2 pv_p2_y 0.0) "_NON" (list pv_p2_x pv_p2_y 0.0) "_NON" (list (/ (+ axis_x2 pv_p2_x) 2.0) dim_loc_y 0.0))
                         (ssadd (entlast) ss_pv)
                         
                         ;; 标注相邻 PV 之间的间隙
                         (if (< pi_idx (1- *sg_global_n*))
                           (progn
                             (setq next_pv_x (+ pv_start_x (* (1+ pi_idx) (* (+ *sg_global_h* 20.0) 5.0))))
                             (command "_.DIMALIGNED" "_NON" (list pv_p2_x pv_p2_y 0.0) "_NON" (list next_pv_x pv_p2_y 0.0) "_NON" (list (/ (+ pv_p2_x next_pv_x) 2.0) dim_loc_y 0.0))
                             (ssadd (entlast) ss_pv)
                           )
                         )
                         
                         ;; 新增: 距离 PV 线 1200 偏移处，添加 PV 总体边长与间隙的连贯标注
                         (setq dim_loc_y2 (+ pv_p2_y 1200.0))
                         (command "_.DIMALIGNED" "_NON" (list cur_pv_x pv_p2_y 0.0) "_NON" (list pv_p2_x pv_p2_y 0.0) "_NON" (list (/ (+ cur_pv_x pv_p2_x) 2.0) dim_loc_y2 0.0))
                         (ssadd (entlast) ss_pv)
                         (if (< pi_idx (1- *sg_global_n*))
                           (progn
                             (command "_.DIMALIGNED" "_NON" (list pv_p2_x pv_p2_y 0.0) "_NON" (list next_pv_x pv_p2_y 0.0) "_NON" (list (/ (+ pv_p2_x next_pv_x) 2.0) dim_loc_y2 0.0))
                             (ssadd (entlast) ss_pv)
                           )
                         )
                         
                         ;; 记录最小最大 X，用于绘制贯穿轴线
                         (if (or (null min_axis_x) (< axis_x1 min_axis_x)) (setq min_axis_x axis_x1))
                         (if (or (null max_axis_x) (> axis_x2 max_axis_x)) (setq max_axis_x axis_x2))
                       )
                     )
                     (setq pi_idx (1+ pi_idx))
                   )
                   ;; 贯穿所有短支架线最低点（purlin底部）并两端延长 600 的横向 AXIS 线
                   (if (and min_axis_x max_axis_x)
                     (progn
                       (setvar "CLAYER" "AXIS")
                       (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                      (cons 10 (list (- min_axis_x 600.0) purlin_bot_y 0.0))
                                      (cons 11 (list (+ max_axis_x 600.0) purlin_bot_y 0.0))))
                       (ssadd (entlast) ss_pv)
                       (setq *sg_elev_cross_ent* (entlast))
                     )
                   )
                   ;; 将所有生成的图形（含 PV、短支架、长轴线）统一绕总起点一起旋转
                   (if (and *sg_global_angle* (not (= *sg_global_angle* 0.0)) (> (sslength ss_pv) 0))
                     (command "_.ROTATE" ss_pv "" "_NON" (list pv_start_x pv_start_y 0.0) *sg_global_angle*)
                   )
                   
                   ;; =============================================================================
                   ;; post-axis: 右侧图形中的两根竖向立柱轴线
                   ;; 动态推算两根水平距离为 100 整数倍的绝对竖向立柱位置
                   ;; =============================================================================
                   (if (and min_axis_x max_axis_x)
                     (progn
                       (setq ang_rad (if *sg_global_angle* (* *sg_global_angle* (/ pi 180.0)) 0.0)
                              L_span (- max_axis_x min_axis_x)
                              ;; Annot-end-dist = (L_span/2-half_D)/5, req 450~550mm
                              ;; W_phys_max = (L_span-4500)*cos(ang)/5  [end-dist=450]
                              W_phys_max (/ (* (- L_span 3300.0) (cos ang_rad)) 5.0)
                              target_W_phys (* (fix (/ W_phys_max 100.0)) 100.0)
                              target_W_cad (* target_W_phys 5.0)
                              half_D (/ target_W_cad (* 2.0 (cos ang_rad)))
                              mid_orig_x (/ (+ min_axis_x max_axis_x) 2.0)
                              mid_orig_y beam_axis_y
                              U1_orig_x (- mid_orig_x half_D)
                              U2_orig_x (+ mid_orig_x half_D))
                       
                       ;; 计算旋转后 U1 点坐标
                       (setq r1 (distance (list pv_start_x pv_start_y 0.0) (list U1_orig_x mid_orig_y 0.0))
                             a1 (angle (list pv_start_x pv_start_y 0.0) (list U1_orig_x mid_orig_y 0.0))
                             U1_rot (polar (list pv_start_x pv_start_y 0.0) (+ a1 ang_rad) r1)
                             U1_rot_x (car U1_rot)
                             U1_rot_y (cadr U1_rot))
                             
                       ;; 计算旋转后 U2 点坐标
                       (setq r2 (distance (list pv_start_x pv_start_y 0.0) (list U2_orig_x mid_orig_y 0.0))
                             a2 (angle (list pv_start_x pv_start_y 0.0) (list U2_orig_x mid_orig_y 0.0))
                             U2_rot (polar (list pv_start_x pv_start_y 0.0) (+ a2 ang_rad) r2)
                             U2_rot_x (car U2_rot)
                             U2_rot_y (cadr U2_rot))

                       ;; O-post: 预算 Triangle-Connector Y (dim_ny 尚未定义，直接用 -cos(ang_rad))
                       (if (= *sg_global_elev_type* 2)
                         (progn
                           (setq opost_base_dist
                             (cond
                               ((and (>= *sg_global_post_d* 60.0) (<= *sg_global_post_d* 76.0)) 60.0)
                               ((and (>  *sg_global_post_d* 76.0) (<= *sg_global_post_d* 89.0)) 65.0)
                               (t 60.0)
                             )
                           )
                           (setq opost_tri_dist_cad (* (+ opost_base_dist (/ *sg_global_beam_h* 2.0)) 5.0)
                                 opost_post_x1      (+ U1_rot_x (* (sin ang_rad) opost_tri_dist_cad))
                                 opost_post_x2      (+ U2_rot_x (* (sin ang_rad) opost_tri_dist_cad))
                                 opost_tri_top_y1   (+ U1_rot_y (* (- (cos ang_rad)) opost_tri_dist_cad))
                                 opost_tri_top_y2   (+ U2_rot_y (* (- (cos ang_rad)) opost_tri_dist_cad)))
                         )
                       )

                       ;; 绘制 post-axis #1/#2，C/O-post 时延伸轴线并绘制截面矩形
                       (setvar "CLAYER" "AXIS")
                       (cond
                         ((or (= *sg_global_elev_type* 1) (= *sg_global_elev_type* 3))  ;; C-post: 上延 175, 下延 7500
                          (setq post1_x     U1_rot_x
                                post2_x     U2_rot_x
                                post1_top_y  (+ U1_rot_y 175.0)
                                post1_bot_y  (- lower_top_axis_y 7500.0)
                                post2_top_y  (+ U2_rot_y 175.0)
                                post2_bot_y  (- lower_top_axis_y 7500.0)
                                post_half_w1 (* *sg_global_post_w* 2.5)
                                post_half_w2 (* (- *sg_global_post_w* 15.0) 2.5))
                         )
                         ((= *sg_global_elev_type* 2)  ;; O-post: 立柱顶端至 Triangle-Connector 插入点，轴线平移至连接块底点
                          (setq post1_x     opost_post_x1
                                post2_x     opost_post_x2
                                post1_top_y  (+ opost_tri_top_y1 175.0)
                                post1_bot_y  lower_top_axis_y
                                post2_top_y  (+ opost_tri_top_y2 175.0)
                                post2_bot_y  lower_top_axis_y
                                post_half_w1 (* *sg_global_post_d* 2.5)
                                post_half_w2 (* (- *sg_global_post_d* 6.0) 2.5))
                         )
                         (t  ;; fallback
                          (setq post1_x     U1_rot_x
                                post2_x     U2_rot_x
                                post1_top_y U1_rot_y  post1_bot_y lower_top_axis_y
                                post2_top_y U2_rot_y  post2_bot_y lower_top_axis_y)
                         )
                       )
                       (if (or (= *sg_global_elev_type* 1) (= *sg_global_elev_type* 2))
                         (progn
                           (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                         (cons 10 (list post1_x post1_top_y 0.0))
                                         (cons 11 (list post1_x post1_bot_y 0.0))))
                           (setq *sg_elev_post_ents* (cons (entlast) *sg_elev_post_ents*))
                           (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                         (cons 10 (list post2_x post2_top_y 0.0))
                                         (cons 11 (list post2_x post2_bot_y 0.0))))
                           (setq *sg_elev_post_ents* (cons (entlast) *sg_elev_post_ents*))
                         )
                       )
                       ;; C-post only: 每根立柱各画两个居中截面矩形
                       (if (= *sg_global_elev_type* 1)
                         (progn
                           (setvar "CLAYER" "beam")
                           ;; U1 outer rect
                           (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                          '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                          (list 10 (- U1_rot_x post_half_w1) post1_top_y)
                                          (list 10 (+ U1_rot_x post_half_w1) post1_top_y)
                                          (list 10 (+ U1_rot_x post_half_w1) post1_bot_y)
                                          (list 10 (- U1_rot_x post_half_w1) post1_bot_y)))
                           ;; U1 inner rect
                           (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                          '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                          (list 10 (- U1_rot_x post_half_w2) post1_top_y)
                                          (list 10 (+ U1_rot_x post_half_w2) post1_top_y)
                                          (list 10 (+ U1_rot_x post_half_w2) post1_bot_y)
                                          (list 10 (- U1_rot_x post_half_w2) post1_bot_y)))
                           ;; U2 outer rect
                           (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                          '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                          (list 10 (- U2_rot_x post_half_w1) post2_top_y)
                                          (list 10 (+ U2_rot_x post_half_w1) post2_top_y)
                                          (list 10 (+ U2_rot_x post_half_w1) post2_bot_y)
                                          (list 10 (- U2_rot_x post_half_w1) post2_bot_y)))
                           ;; U2 inner rect
                           (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                          '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                          (list 10 (- U2_rot_x post_half_w2) post2_top_y)
                                          (list 10 (+ U2_rot_x post_half_w2) post2_top_y)
                                          (list 10 (+ U2_rot_x post_half_w2) post2_bot_y)
                                          (list 10 (- U2_rot_x post_half_w2) post2_bot_y)))
                           (setvar "CLAYER" "AXIS")
                         )
                       )
                       ;; O-post only: 每根立柱各画两个居中截面矩形（宽 D 和 D-6）
                       (if (= *sg_global_elev_type* 2)
                         (progn
                           (setvar "CLAYER" "beam")
                           ;; post1 outer rect (width = D)
                           (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                          '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                          (list 10 (- post1_x post_half_w1) post1_top_y)
                                          (list 10 (+ post1_x post_half_w1) post1_top_y)
                                          (list 10 (+ post1_x post_half_w1) post1_bot_y)
                                          (list 10 (- post1_x post_half_w1) post1_bot_y)))
                           ;; post1 inner rect (width = D-6)
                           (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                          '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                          (list 10 (- post1_x post_half_w2) post1_top_y)
                                          (list 10 (+ post1_x post_half_w2) post1_top_y)
                                          (list 10 (+ post1_x post_half_w2) post1_bot_y)
                                          (list 10 (- post1_x post_half_w2) post1_bot_y)))
                           ;; post2 outer rect (width = D)
                           (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                          '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                          (list 10 (- post2_x post_half_w1) post2_top_y)
                                          (list 10 (+ post2_x post_half_w1) post2_top_y)
                                          (list 10 (+ post2_x post_half_w1) post2_bot_y)
                                          (list 10 (- post2_x post_half_w1) post2_bot_y)))
                           ;; post2 inner rect (width = D-6)
                           (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                          '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                          (list 10 (- post2_x post_half_w2) post2_top_y)
                                          (list 10 (+ post2_x post_half_w2) post2_top_y)
                                          (list 10 (+ post2_x post_half_w2) post2_bot_y)
                                          (list 10 (- post2_x post_half_w2) post2_bot_y)))
                           (setvar "CLAYER" "AXIS")
                         )
                       )

                       ;; 保存左侧post-axis的最低点作为缩放中心
                       (setq *sg_scale_center_x* U1_rot_x
                             *sg_scale_center_y* lower_top_axis_y)
                                      
                       (setvar "CLAYER" "DIM")
                       (if (not (= *sg_global_elev_type* 3))
                         (command "_.DIMLINEAR" "_NON" (list post1_x lower_top_axis_y 0.0) "_NON" (list post2_x lower_top_axis_y 0.0) "_NON" (list (/ (+ post1_x post2_x) 2.0) (- lower_top_axis_y 2000.0) 0.0))
                       )

                        ;; =============================================================================
                        ;; beam-angle-axis: 斜向角度轴线（沿 angle 方向的轴线）
                        ;; 计算旋转后的斜轴线两端点，用于绘制矩形、连接线等
                        ;; =============================================================================

                        (setvar "OSMODE" 0)
                        (setq ax_L_ox (- min_axis_x 600.0)  ax_L_oy beam_axis_y
                              ax_R_ox (+ max_axis_x 600.0)  ax_R_oy beam_axis_y
                              rL (distance (list pv_start_x pv_start_y 0.0) (list ax_L_ox ax_L_oy 0.0))
                              aL (angle   (list pv_start_x pv_start_y 0.0) (list ax_L_ox ax_L_oy 0.0))
                              ax_L_rot (polar (list pv_start_x pv_start_y 0.0) (+ aL ang_rad) rL)
                              ax_L_rx (car ax_L_rot)  ax_L_ry (cadr ax_L_rot)
                              rR (distance (list pv_start_x pv_start_y 0.0) (list ax_R_ox ax_R_oy 0.0))
                              aR (angle   (list pv_start_x pv_start_y 0.0) (list ax_R_ox ax_R_oy 0.0))
                              ax_R_rot (polar (list pv_start_x pv_start_y 0.0) (+ aR ang_rad) rR)
                              ax_R_rx (car ax_R_rot)  ax_R_ry (cadr ax_R_rot))
                        ;; 法向偏移单位向量(斜轴正上方)
                        (setq dim_nx (sin ang_rad) dim_ny (- (cos ang_rad)))

                        ;; 绘制梁中心轴线（beam-angle-axis），始终绘制，与旋转后的 purlin-axis 端点相交
                        (setvar "CLAYER" "AXIS")
                        (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                       (cons 10 (list ax_L_rx ax_L_ry 0.0))
                                       (cons 11 (list ax_R_rx ax_R_ry 0.0))))
                        (setq *sg_elev_beam_ent* (entlast))

                        ;; 先计算两个交点坐标（brace-axis 与 beam-angle-axis 的交点）
                        (setq axis_total_len (distance (list ax_L_rx ax_L_ry 0.0) (list ax_R_rx ax_R_ry 0.0))
                              axis_angle (angle (list ax_L_rx ax_L_ry 0.0) (list ax_R_rx ax_R_ry 0.0))
                              offset_dist (/ (- axis_total_len 3000.0) 2.0))
                        ;; 左侧交点（brace-axis #1 与 beam-angle-axis 的交点）
                        (setq line_end_pt (polar (list ax_L_rx ax_L_ry 0.0) axis_angle offset_dist)
                              brace_int1_x (car line_end_pt)  brace_int1_y (cadr line_end_pt))
                        ;; 右侧交点（brace-axis #2 与 beam-angle-axis 的交点）
                        (setq line_end_r_pt (polar (list ax_R_rx ax_R_ry 0.0) (+ axis_angle pi) offset_dist)
                              brace_int2_x (car line_end_r_pt)  brace_int2_y (cadr line_end_r_pt))

                        ;; C-post-single: single vertical post-axis + two brace-axis
                        (if (= *sg_global_elev_type* 3)
                          (progn
                            (setq cps_post_x      (/ (+ ax_L_rx ax_R_rx) 2.0)
                                  cps_post_y      (/ (+ ax_L_ry ax_R_ry) 2.0)
                                  cps_brace_top_L (polar (list ax_L_rx ax_L_ry 0.0) axis_angle 2000.0)
                                  cps_brace_top_R (polar (list ax_R_rx ax_R_ry 0.0) (+ axis_angle pi) 2000.0)
                                  cps_brace_bot_y (+ lower_top_axis_y 1000.0)
                                  cps_brace_xoff  (* (+ (/ *sg_global_post_w* 2.0) 60.0) 5.0))
                            (setvar "CLAYER" "AXIS")
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list cps_post_x cps_post_y 0.0))
                                           (cons 11 (list cps_post_x lower_top_axis_y 0.0))))
                            (setq *sg_elev_post_ents* (cons (entlast) *sg_elev_post_ents*))
                            (setq cps_bext_L_top (polar (list (car cps_brace_top_L) (cadr cps_brace_top_L))
                                                         (angle (list (- cps_post_x cps_brace_xoff) cps_brace_bot_y)
                                                                (list (car cps_brace_top_L) (cadr cps_brace_top_L)))
                                                         150.0)
                                  cps_bext_L_bot (polar (list (- cps_post_x cps_brace_xoff) cps_brace_bot_y)
                                                         (angle (list (car cps_brace_top_L) (cadr cps_brace_top_L))
                                                                (list (- cps_post_x cps_brace_xoff) cps_brace_bot_y))
                                                         150.0)
                                  cps_bext_R_top (polar (list (car cps_brace_top_R) (cadr cps_brace_top_R))
                                                         (angle (list (+ cps_post_x cps_brace_xoff) cps_brace_bot_y)
                                                                (list (car cps_brace_top_R) (cadr cps_brace_top_R)))
                                                         150.0)
                                  cps_bext_R_bot (polar (list (+ cps_post_x cps_brace_xoff) cps_brace_bot_y)
                                                         (angle (list (car cps_brace_top_R) (cadr cps_brace_top_R))
                                                                (list (+ cps_post_x cps_brace_xoff) cps_brace_bot_y))
                                                         150.0))
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list (car cps_bext_L_top) (cadr cps_bext_L_top) 0.0))
                                           (cons 11 (list (car cps_bext_L_bot) (cadr cps_bext_L_bot) 0.0))))
                            (setq *sg_elev_brace_ents* (cons (entlast) *sg_elev_brace_ents*))
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list (car cps_bext_R_top) (cadr cps_bext_R_top) 0.0))
                                           (cons 11 (list (car cps_bext_R_bot) (cadr cps_bext_R_bot) 0.0))))
                            (setq *sg_elev_brace_ents* (cons (entlast) *sg_elev_brace_ents*))
                            ;; brace cross-section rectangles: 50mm (hw=125) and 40mm (hw=100), on beam layer
                            (setvar "CLAYER" "beam")
                            (setq cps_bperp_L (+ (angle cps_bext_L_top cps_bext_L_bot) (/ pi 2.0))
                                  cps_bperp_R (+ (angle cps_bext_R_top cps_bext_R_bot) (/ pi 2.0)))
                            (foreach cps_br_hw (list 125.0 100.0)
                              (setq cps_blp1 (polar cps_bext_L_top cps_bperp_L (- cps_br_hw))
                                    cps_blp2 (polar cps_bext_L_bot cps_bperp_L (- cps_br_hw))
                                    cps_blp3 (polar cps_bext_L_bot cps_bperp_L    cps_br_hw)
                                    cps_blp4 (polar cps_bext_L_top cps_bperp_L    cps_br_hw))
                              (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                             '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                             (list 10 (car cps_blp1) (cadr cps_blp1))
                                             (list 10 (car cps_blp2) (cadr cps_blp2))
                                             (list 10 (car cps_blp3) (cadr cps_blp3))
                                             (list 10 (car cps_blp4) (cadr cps_blp4))))
                              (setq cps_brp1 (polar cps_bext_R_top cps_bperp_R (- cps_br_hw))
                                    cps_brp2 (polar cps_bext_R_bot cps_bperp_R (- cps_br_hw))
                                    cps_brp3 (polar cps_bext_R_bot cps_bperp_R    cps_br_hw)
                                    cps_brp4 (polar cps_bext_R_top cps_bperp_R    cps_br_hw))
                              (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                             '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                             (list 10 (car cps_brp1) (cadr cps_brp1))
                                             (list 10 (car cps_brp2) (cadr cps_brp2))
                                             (list 10 (car cps_brp3) (cadr cps_brp3))
                                             (list 10 (car cps_brp4) (cadr cps_brp4))))
                            )
                            (setvar "CLAYER" "DIM")
                            (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
                            (setq cps_bdim_pos_L (polar (list (/ (+ (car cps_bext_L_top) (car cps_bext_L_bot)) 2.0)
                                                               (/ (+ (cadr cps_bext_L_top) (cadr cps_bext_L_bot)) 2.0))
                                                         cps_bperp_L 925.0)
                                  cps_bdim_pos_R (polar (list (/ (+ (car cps_bext_R_top) (car cps_bext_R_bot)) 2.0)
                                                               (/ (+ (cadr cps_bext_R_top) (cadr cps_bext_R_bot)) 2.0))
                                                         cps_bperp_R 925.0))
                            (command "_.DIMALIGNED"
                                     "_NON" (list (car cps_bext_L_top) (cadr cps_bext_L_top) 0.0)
                                     "_NON" (list (car cps_bext_L_bot) (cadr cps_bext_L_bot) 0.0)
                                     "_NON" (list (car cps_bdim_pos_L) (cadr cps_bdim_pos_L) 0.0))
                            (command "_.DIMALIGNED"
                                     "_NON" (list (car cps_bext_R_top) (cadr cps_bext_R_top) 0.0)
                                     "_NON" (list (car cps_bext_R_bot) (cadr cps_bext_R_bot) 0.0)
                                     "_NON" (list (car cps_bdim_pos_R) (cadr cps_bdim_pos_R) 0.0))
                            (setvar "CLAYER" "AXIS")
                            ;; post cross-section rectangles at brace/post intersection
                            ;; x = 2*(W/2+60+30), y = 100, centered on (cps_post_x, cps_brace_bot_y)
                            (setq cps_hw_new (* (+ (/ *sg_global_post_w* 2.0) 90.0) 5.0)
                                  cps_hy_new 250.0)
                            (setvar "CLAYER" "beam")
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                           '(8 . "beam") '(62 . 2) '(90 . 4) '(70 . 1)
                                           (list 10 (- cps_post_x cps_hw_new) (- cps_brace_bot_y cps_hy_new))
                                           (list 10 (+ cps_post_x cps_hw_new) (- cps_brace_bot_y cps_hy_new))
                                           (list 10 (+ cps_post_x cps_hw_new) (+ cps_brace_bot_y cps_hy_new))
                                           (list 10 (- cps_post_x cps_hw_new) (+ cps_brace_bot_y cps_hy_new))))
                            ;; inner rectangles: x = 2*(W/2+60+30), y = 100-6, same center
                            (setq cps_hy_new2 235.0)
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                           '(8 . "beam") '(62 . 2) '(90 . 4) '(70 . 1)
                                           (list 10 (- cps_post_x cps_hw_new) (- cps_brace_bot_y cps_hy_new2))
                                           (list 10 (+ cps_post_x cps_hw_new) (- cps_brace_bot_y cps_hy_new2))
                                           (list 10 (+ cps_post_x cps_hw_new) (+ cps_brace_bot_y cps_hy_new2))
                                           (list 10 (- cps_post_x cps_hw_new) (+ cps_brace_bot_y cps_hy_new2))))
                            ;; post body rectangles: width W and W-30, centered on post-axis
                            ;; extended 35mm (175 CAD) upward and 1500mm (7500 CAD) downward
                            (setq cps_post_hw1  (* *sg_global_post_w* 2.5)
                                  cps_post_hw2  (* (- *sg_global_post_w* 30.0) 2.5)
                                  cps_post_top  (+ cps_post_y 175.0)
                                  cps_post_bot  (- lower_top_axis_y 7500.0))
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                           '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                           (list 10 (- cps_post_x cps_post_hw1) cps_post_top)
                                           (list 10 (+ cps_post_x cps_post_hw1) cps_post_top)
                                           (list 10 (+ cps_post_x cps_post_hw1) cps_post_bot)
                                           (list 10 (- cps_post_x cps_post_hw1) cps_post_bot)))
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                           '(8 . "beam") '(62 . 4) '(90 . 4) '(70 . 1)
                                           (list 10 (- cps_post_x cps_post_hw2) cps_post_top)
                                           (list 10 (+ cps_post_x cps_post_hw2) cps_post_top)
                                           (list 10 (+ cps_post_x cps_post_hw2) cps_post_bot)
                                           (list 10 (- cps_post_x cps_post_hw2) cps_post_bot)))
                            ;; DIMALIGNED for post-axis full length, 185mm (925 CAD) to the right
                            (setvar "CLAYER" "DIM")
                            (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
                            (command "_.DIMALIGNED"
                                     "_NON" (list cps_post_x cps_post_top 0.0)
                                     "_NON" (list cps_post_x cps_post_bot 0.0)
                                     "_NON" (list (+ cps_post_x 925.0)
                                                  (/ (+ cps_post_top cps_post_bot) 2.0) 0.0))
                            ;; DIMALIGNED for below-ground portion of post-axis, 185mm (925 CAD) to the left
                            (command "_.DIMALIGNED"
                                     "_NON" (list cps_post_x lower_top_axis_y 0.0)
                                     "_NON" (list cps_post_x cps_post_bot 0.0)
                                     "_NON" (list (- cps_post_x 925.0)
                                                  (/ (+ lower_top_axis_y cps_post_bot) 2.0) 0.0))
                            (setvar "CLAYER" "AXIS")
                          )
                        )

                        ;; =============================================================================
                        ;; beam-angle-axis 详细标注：同一法向偏移线，标注点为沿轴线方向最相近两点
                        ;; =============================================================================

                        ;; 定义关键点列表（按顺序：左端、交点1、post-axis#1(U1)、post-axis#2(U2)、交点2、右端）
                        ;; U1/U2 为 post-axis 轴线位置，brace_int1/brace_int2 为 brace-axis 与 beam-angle-axis 的交点
                        (setq key_points (list (list ax_L_rx ax_L_ry "L")
                                                (list brace_int1_x brace_int1_y "I1")
                                                (list U1_rot_x U1_rot_y "U1")
                                                (list U2_rot_x U2_rot_y "U2")
                                                (list brace_int2_x brace_int2_y "I2")
                                                (list ax_R_rx ax_R_ry "R"))
                              axis_start_pt (list ax_L_rx ax_L_ry)
                              axis_end_pt (list ax_R_rx ax_R_ry))

                        ;; 计算每个点在斜轴线上的投影距离，并排序
                        (setq sorted_points (vl-sort key_points
                                                    '(lambda (p1 p2)
                                                       (< (PVRectSgs_GetProjectionDist p1 axis_start_pt axis_end_pt)
                                                          (PVRectSgs_GetProjectionDist p2 axis_start_pt axis_end_pt)))))

                        ;; 第一道详细标注：相邻点对标注，统一偏移 1200（C-post-single 跳过，无立柱/支撑参考点）
                        (if (not (= *sg_global_elev_type* 3))
                          (progn
                            (setvar "CLAYER" "DIM")
                            (setq dim_offset 1200.0
                                  i 0)
                            (while (< i (1- (length sorted_points)))
                              (setq p1 (nth i sorted_points)
                                    p2 (nth (1+ i) sorted_points)
                                    mid_x (/ (+ (car p1) (car p2)) 2.0)
                                    mid_y (/ (+ (cadr p1) (cadr p2)) 2.0)
                                    dim_loc_x (+ mid_x (* dim_nx dim_offset))
                                    dim_loc_y (+ mid_y (* dim_ny dim_offset)))
                              (command "_.DIMALIGNED"
                                       "_NON" (list (car p1) (cadr p1) 0.0)
                                       "_NON" (list (car p2) (cadr p2) 0.0)
                                       "_NON" (list dim_loc_x dim_loc_y 0.0))
                              (setq i (1+ i))
                            )
                          )
                        )

                        ;; 第二道总长标注：左端->右端，偏移 2000
                        (setvar "CLAYER" "DIM")
                        (setq total_dim_offset 2000.0
                              total_mid_x (/ (+ ax_L_rx ax_R_rx) 2.0)
                              total_mid_y (/ (+ ax_L_ry ax_R_ry) 2.0)
                              total_dim_loc_x (+ total_mid_x (* dim_nx total_dim_offset))
                              total_dim_loc_y (+ total_mid_y (* dim_ny total_dim_offset)))
                        (command "_.DIMALIGNED"
                                 "_NON" (list ax_L_rx ax_L_ry 0.0)
                                 "_NON" (list ax_R_rx ax_R_ry 0.0)
                                 "_NON" (list total_dim_loc_x total_dim_loc_y 0.0))

                        ;; C-post-single: split beam-axis dim at brace intersection points (DIM layer, offset 1200)
                        (if (= *sg_global_elev_type* 3)
                          (progn
                            (setvar "CLAYER" "DIM")
                            (setq cps_split_offset 1200.0
                                  seg1_mid_x (/ (+ ax_L_rx (car cps_brace_top_L)) 2.0)
                                  seg1_mid_y (/ (+ ax_L_ry (cadr cps_brace_top_L)) 2.0)
                                  seg1_loc_x (+ seg1_mid_x (* dim_nx cps_split_offset))
                                  seg1_loc_y (+ seg1_mid_y (* dim_ny cps_split_offset)))
                            (command "_.DIMALIGNED"
                                     "_NON" (list ax_L_rx ax_L_ry 0.0)
                                     "_NON" (list (car cps_brace_top_L) (cadr cps_brace_top_L) 0.0)
                                     "_NON" (list seg1_loc_x seg1_loc_y 0.0))
                            (setq seg2_mid_x (/ (+ (car cps_brace_top_L) cps_post_x) 2.0)
                                  seg2_mid_y (/ (+ (cadr cps_brace_top_L) cps_post_y) 2.0)
                                  seg2_loc_x (+ seg2_mid_x (* dim_nx cps_split_offset))
                                  seg2_loc_y (+ seg2_mid_y (* dim_ny cps_split_offset)))
                            (command "_.DIMALIGNED"
                                     "_NON" (list (car cps_brace_top_L) (cadr cps_brace_top_L) 0.0)
                                     "_NON" (list cps_post_x cps_post_y 0.0)
                                     "_NON" (list seg2_loc_x seg2_loc_y 0.0))
                            (setq seg3_mid_x (/ (+ cps_post_x (car cps_brace_top_R)) 2.0)
                                  seg3_mid_y (/ (+ cps_post_y (cadr cps_brace_top_R)) 2.0)
                                  seg3_loc_x (+ seg3_mid_x (* dim_nx cps_split_offset))
                                  seg3_loc_y (+ seg3_mid_y (* dim_ny cps_split_offset)))
                            (command "_.DIMALIGNED"
                                     "_NON" (list cps_post_x cps_post_y 0.0)
                                     "_NON" (list (car cps_brace_top_R) (cadr cps_brace_top_R) 0.0)
                                     "_NON" (list seg3_loc_x seg3_loc_y 0.0))
                            (setq seg4_mid_x (/ (+ (car cps_brace_top_R) ax_R_rx) 2.0)
                                  seg4_mid_y (/ (+ (cadr cps_brace_top_R) ax_R_ry) 2.0)
                                  seg4_loc_x (+ seg4_mid_x (* dim_nx cps_split_offset))
                                  seg4_loc_y (+ seg4_mid_y (* dim_ny cps_split_offset)))
                            (command "_.DIMALIGNED"
                                     "_NON" (list (car cps_brace_top_R) (cadr cps_brace_top_R) 0.0)
                                     "_NON" (list ax_R_rx ax_R_ry 0.0)
                                     "_NON" (list seg4_loc_x seg4_loc_y 0.0))
                          )
                        )

                        ;; 仅 C-post / O-post: 沿 beam-angle-axis 绘制斜向截面矩形（beam 元素）
                        (if (or (= *sg_global_elev_type* 1) (= *sg_global_elev_type* 2) (= *sg_global_elev_type* 3))
                          (progn
                            (if (not (tblsearch "LAYER" "beam")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "beam") (70 . 0) (62 . 4))))
                            (setvar "CLAYER" "beam")
                            (setq beam_half_h  (* *sg_global_beam_h* 2.5)
                                  beam_half_h2 (* (- *sg_global_beam_h* 30.0) 2.5))
                            ;; outer rectangle
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                           '(8 . "beam") '(90 . 4) '(70 . 1)
                                           (list 10 (+ ax_L_rx (* dim_nx beam_half_h)) (+ ax_L_ry (* dim_ny beam_half_h)))
                                           (list 10 (+ ax_R_rx (* dim_nx beam_half_h)) (+ ax_R_ry (* dim_ny beam_half_h)))
                                           (list 10 (- ax_R_rx (* dim_nx beam_half_h)) (- ax_R_ry (* dim_ny beam_half_h)))
                                           (list 10 (- ax_L_rx (* dim_nx beam_half_h)) (- ax_L_ry (* dim_ny beam_half_h)))))
                            ;; inner rectangle (h-beam - 2×15)
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                           '(8 . "beam") '(90 . 4) '(70 . 1)
                                           (list 10 (+ ax_L_rx (* dim_nx beam_half_h2)) (+ ax_L_ry (* dim_ny beam_half_h2)))
                                           (list 10 (+ ax_R_rx (* dim_nx beam_half_h2)) (+ ax_R_ry (* dim_ny beam_half_h2)))
                                           (list 10 (- ax_R_rx (* dim_nx beam_half_h2)) (- ax_R_ry (* dim_ny beam_half_h2)))
                                           (list 10 (- ax_L_rx (* dim_nx beam_half_h2)) (- ax_L_ry (* dim_ny beam_half_h2)))))
                            (setvar "CLAYER" "AXIS")
                          )
                        )

                        ;; =============================================================================
                        ;; 插入块参照：Nut
                        ;; 共四个，放置于 beam-angle-axis 与两条 post-axis、两条 brace-axis 的相交点
                        ;; =============================================================================

                        (setq block_name "Nut")
                        (if (tblsearch "BLOCK" block_name)
                          (progn
                            ;; 在 beam-angle-axis 与 post-axis #1 的交点插入块 (U1_rot)，O-post/C-post-single 不插入
                            (if (not (or (= *sg_global_elev_type* 2) (= *sg_global_elev_type* 3)))
                              (progn
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list U1_rot_x U1_rot_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                              )
                            )

                            ;; 在 beam-angle-axis 与 post-axis #2 的交点插入块 (U2_rot)，O-post/C-post-single 不插入
                            (if (not (or (= *sg_global_elev_type* 2) (= *sg_global_elev_type* 3)))
                              (progn
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list U2_rot_x U2_rot_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                              )
                            )

                            ;; 在 beam-angle-axis 与 brace-axis #1 的交点插入块 (brace_int1)，C-post-single 不插入
                            (if (not (= *sg_global_elev_type* 3))
                              (progn
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list brace_int1_x brace_int1_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                              )
                            )

                            ;; 在 beam-angle-axis 与 brace-axis #2 的交点插入块 (brace_int2)，C-post-single 不插入
                            (if (not (= *sg_global_elev_type* 3))
                              (progn
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list brace_int2_x brace_int2_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                              )
                            )

                            ;; C-post-single: two nuts on post-axis, ±25 from brace/post intersection
                            (if (= *sg_global_elev_type* 3)
                              (progn
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list cps_post_x (+ cps_brace_bot_y 125.0) 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list cps_post_x (- cps_brace_bot_y 125.0) 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                                ;; two nuts at brace/post intersection, x = post_x ± (W/2+60)*5
                                (setq cps_nut_xoff (* (+ (/ *sg_global_post_w* 2.0) 60.0) 5.0))
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list (+ cps_post_x cps_nut_xoff) cps_brace_bot_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list (- cps_post_x cps_nut_xoff) cps_brace_bot_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                                ;; nuts on beam-axis: beam/post intersection + beam/brace intersections
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list cps_post_x cps_post_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list (car cps_brace_top_L) (cadr cps_brace_top_L) 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 block_name)
                                               '(8 . "AXIS")
                                               (cons 10 (list (car cps_brace_top_R) (cadr cps_brace_top_R) 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14")
                                (ssadd (entlast) ss_pv)
                              )
                            )
                          )
                          (prompt (strcat "\n>>> Warning: Block '" block_name "' not found. Skipping block insertion."))
                        )

                        ;; =============================================================================
                        ;; brace-axis: 斜向连接轴线（两条对称连接线）
                        ;; 连接 post-axis 竖向立柱与 beam-angle-axis 斜轴线，用于表示结构构件关系
                        ;; =============================================================================

                        ;; brace-axis #1: 创建左侧连接直线（AXIS 图层）
                        ;; 起点：post-axis #1（左侧竖向立柱轴线 U1）最低点向上 1000mm
                        ;; 终点：beam-angle-axis 最左端点沿 angle 方向，长度 (总长-3000)/2 的位置（已计算的交点）
                        (setvar "CLAYER" "AXIS")
                        ;; O-post: bolt offset along brace direction (mm × 5 CAD)
                        (setq obolt_offset_cad
                          (cond
                            ((or (= *sg_global_post_d* 60.0) (= *sg_global_post_d* 63.0)) 600.0)
                            ((= *sg_global_post_d* 76.0) 625.0)
                            ((= *sg_global_post_d* 89.0) 675.0)
                            (t 600.0)))
                        (setq line_start_x (if (= *sg_global_elev_type* 2) opost_post_x1 U1_rot_x)
                              line_start_y (if (= *sg_global_elev_type* 2) (+ lower_top_axis_y 1500.0) (+ lower_top_axis_y 1000.0)))
                        ;; 终点坐标使用前面计算的 brace_int1
                        (setq line_end_x brace_int1_x  line_end_y brace_int1_y)
                        ;; 创建直线
                        (if (= *sg_global_elev_type* 1)
                          (progn
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list (+ line_start_x (+ post_half_w1 250.0)) line_start_y 0.0))
                                           (cons 11 (list line_end_x line_end_y 0.0))))
                            (setq *sg_brace_vis_ents* (cons (entlast) *sg_brace_vis_ents*))
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list line_start_x line_start_y 0.0))
                                           (cons 11 (list line_end_x line_end_y 0.0))))
                            (setq *sg_elev_brace_ents* (cons (entlast) *sg_elev_brace_ents*))
                            (setq *sg_brace_track_ents* (cons (entlast) *sg_brace_track_ents*))
                          )
                        )
                        (if (= *sg_global_elev_type* 2)
                          (progn
                            ;; O-post brace #1: vis line with lower endpoint shifted horizontally inward (+X)
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list (+ line_start_x obolt_offset_cad) line_start_y 0.0))
                                           (cons 11 (list line_end_x line_end_y 0.0))))
                            (setq *sg_brace_vis_ents* (cons (entlast) *sg_brace_vis_ents*))
                            ;; scale-copy source: original unshifted lower endpoint (erased after copy)
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list line_start_x line_start_y 0.0))
                                           (cons 11 (list line_end_x line_end_y 0.0))))
                            (setq *sg_elev_brace_ents* (cons (entlast) *sg_elev_brace_ents*))
                            (setq *sg_opost_brace_src_ents* (cons (entlast) *sg_opost_brace_src_ents*))
                          )
                        )

                        ;; brace-axis #2: 创建右侧连接直线（AXIS 图层）
                        ;; 起点：post-axis #2（右侧竖向立柱轴线 U2）最低点向上 1000mm
                        ;; 终点：beam-angle-axis 最右端点反向沿 angle 方向，长度 (总长-3000)/2 的位置（已计算的交点）
                        (setq line_start_r_x (if (= *sg_global_elev_type* 2) opost_post_x2 U2_rot_x)
                              line_start_r_y (if (= *sg_global_elev_type* 2) (+ lower_top_axis_y 1500.0) (+ lower_top_axis_y 1000.0)))
                        ;; 终点坐标使用前面计算的 brace_int2
                        (setq line_end_r_x brace_int2_x  line_end_r_y brace_int2_y)
                        ;; 创建直线
                        (if (= *sg_global_elev_type* 1)
                          (progn
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list (- line_start_r_x (+ post_half_w1 250.0)) line_start_r_y 0.0))
                                           (cons 11 (list line_end_r_x line_end_r_y 0.0))))
                            (setq *sg_brace_vis_ents* (cons (entlast) *sg_brace_vis_ents*))
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list line_start_r_x line_start_r_y 0.0))
                                           (cons 11 (list line_end_r_x line_end_r_y 0.0))))
                            (setq *sg_elev_brace_ents* (cons (entlast) *sg_elev_brace_ents*))
                            (setq *sg_brace_track_ents* (cons (entlast) *sg_brace_track_ents*))
                          )
                        )
                        (if (= *sg_global_elev_type* 2)
                          (progn
                            ;; O-post brace #2: vis line with lower endpoint shifted horizontally inward (-X)
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list (- line_start_r_x obolt_offset_cad) line_start_r_y 0.0))
                                           (cons 11 (list line_end_r_x line_end_r_y 0.0))))
                            (setq *sg_brace_vis_ents* (cons (entlast) *sg_brace_vis_ents*))
                            ;; scale-copy source: original unshifted lower endpoint (erased after copy)
                            (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                           (cons 10 (list line_start_r_x line_start_r_y 0.0))
                                           (cons 11 (list line_end_r_x line_end_r_y 0.0))))
                            (setq *sg_elev_brace_ents* (cons (entlast) *sg_elev_brace_ents*))
                            (setq *sg_opost_brace_src_ents* (cons (entlast) *sg_opost_brace_src_ents*))
                          )
                        )

                        ;; Brace-connector c-post: two nested yellow rectangles + 3 Nut blocks per post
                        ;; Total X = post_half_w1 + 550 CAD  ->  half X (conn_half_x) = (post_half_w1 + 550) / 2
                        ;; Inward offset = conn_half_x - 150 CAD
                        ;; Y outer 100 mm -> half 250 CAD;  Y inner 94 mm -> half 235 CAD
                        ;; Nuts: ±25 mm = ±125 CAD on Y; w/2+50 mm = post_half_w1+250 CAD outboard on X
                        (if (= *sg_global_elev_type* 1)
                          (progn
                            (setq conn_half_x (/ (+ post_half_w1 550.0) 2.0)
                                  conn_cx_l   (+ line_start_x   (- conn_half_x 150.0))
                                  conn_cx_r   (- line_start_r_x (- conn_half_x 150.0)))
                            ;; Left post outer (100 mm)
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(8 . "AXIS") '(62 . 2)
                                           '(100 . "AcDbPolyline") '(90 . 4) '(70 . 1)
                                           (cons 10 (list (- conn_cx_l conn_half_x) (- line_start_y 250.0)))
                                           (cons 10 (list (+ conn_cx_l conn_half_x) (- line_start_y 250.0)))
                                           (cons 10 (list (+ conn_cx_l conn_half_x) (+ line_start_y 250.0)))
                                           (cons 10 (list (- conn_cx_l conn_half_x) (+ line_start_y 250.0)))))
                            ;; Left post inner (94 mm)
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(8 . "AXIS") '(62 . 2)
                                           '(100 . "AcDbPolyline") '(90 . 4) '(70 . 1)
                                           (cons 10 (list (- conn_cx_l conn_half_x) (- line_start_y 235.0)))
                                           (cons 10 (list (+ conn_cx_l conn_half_x) (- line_start_y 235.0)))
                                           (cons 10 (list (+ conn_cx_l conn_half_x) (+ line_start_y 235.0)))
                                           (cons 10 (list (- conn_cx_l conn_half_x) (+ line_start_y 235.0)))))
                            ;; Right post outer (100 mm)
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(8 . "AXIS") '(62 . 2)
                                           '(100 . "AcDbPolyline") '(90 . 4) '(70 . 1)
                                           (cons 10 (list (- conn_cx_r conn_half_x) (- line_start_r_y 250.0)))
                                           (cons 10 (list (+ conn_cx_r conn_half_x) (- line_start_r_y 250.0)))
                                           (cons 10 (list (+ conn_cx_r conn_half_x) (+ line_start_r_y 250.0)))
                                           (cons 10 (list (- conn_cx_r conn_half_x) (+ line_start_r_y 250.0)))))
                            ;; Right post inner (94 mm)
                            (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(8 . "AXIS") '(62 . 2)
                                           '(100 . "AcDbPolyline") '(90 . 4) '(70 . 1)
                                           (cons 10 (list (- conn_cx_r conn_half_x) (- line_start_r_y 235.0)))
                                           (cons 10 (list (+ conn_cx_r conn_half_x) (- line_start_r_y 235.0)))
                                           (cons 10 (list (+ conn_cx_r conn_half_x) (+ line_start_r_y 235.0)))
                                           (cons 10 (list (- conn_cx_r conn_half_x) (+ line_start_r_y 235.0)))))
                            (if (tblsearch "BLOCK" "Nut")
                              (progn
                                ;; Left post (U1): two on post-axis ±125, one outboard +post_half_w1+250
                                (entmake (list '(0 . "INSERT") '(2 . "Nut") '(8 . "AXIS")
                                               (cons 10 (list line_start_x (- line_start_y 125.0) 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14") (ssadd (entlast) ss_pv)
                                (entmake (list '(0 . "INSERT") '(2 . "Nut") '(8 . "AXIS")
                                               (cons 10 (list line_start_x (+ line_start_y 125.0) 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14") (ssadd (entlast) ss_pv)
                                (entmake (list '(0 . "INSERT") '(2 . "Nut") '(8 . "AXIS")
                                               (cons 10 (list (+ line_start_x (+ post_half_w1 250.0)) line_start_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14") (ssadd (entlast) ss_pv)
                                ;; Right post (U2): mirrored — outboard nut goes left
                                (entmake (list '(0 . "INSERT") '(2 . "Nut") '(8 . "AXIS")
                                               (cons 10 (list line_start_r_x (- line_start_r_y 125.0) 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14") (ssadd (entlast) ss_pv)
                                (entmake (list '(0 . "INSERT") '(2 . "Nut") '(8 . "AXIS")
                                               (cons 10 (list line_start_r_x (+ line_start_r_y 125.0) 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14") (ssadd (entlast) ss_pv)
                                (entmake (list '(0 . "INSERT") '(2 . "Nut") '(8 . "AXIS")
                                               (cons 10 (list (- line_start_r_x (+ post_half_w1 250.0)) line_start_r_y 0.0))
                                               '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                                (PVRectSgs_SetBlockVisibility (entlast) "M14") (ssadd (entlast) ss_pv)
                              )
                            )
                            (prompt "\n>>> Drew brace-connector rectangles and nuts at both post/brace intersections.")
                          )
                        )
                        ;; O-brace-connector blocks for O-post at post-axis/brace-axis intersections
                        (if (= *sg_global_elev_type* 2)
                          (progn
                            (setq obrace_conn_block
                              (cond
                                ((or (= *sg_global_post_d* 60.0) (= *sg_global_post_d* 63.0)) "o-brace-connector-2")
                                ((= *sg_global_post_d* 76.0) "o-brace-connector-5")
                                ((= *sg_global_post_d* 89.0) "o-brace-connector-8")
                                (t nil)))
                            (if (and obrace_conn_block (tblsearch "BLOCK" obrace_conn_block))
                              (progn
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 obrace_conn_block)
                                               '(8 . "AXIS")
                                               (cons 10 (list line_start_x line_start_y 0.0))
                                               '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                                (entmake (list '(0 . "INSERT")
                                               (cons 2 obrace_conn_block)
                                               '(8 . "AXIS")
                                               (cons 10 (list line_start_r_x line_start_r_y 0.0))
                                               '(41 . -1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                                (prompt (strcat "\n>>> Inserted '" obrace_conn_block "' at both post/brace intersections."))
                              )
                              (if obrace_conn_block
                                (prompt (strcat "\n>>> Warning: Block '" obrace_conn_block "' not found. Skipping."))
                                (prompt "\n>>> Warning: Post diameter not matched for o-brace-connector. Skipping.")
                              )
                            )
                          )
                        )
                        ;; Triangle-Connector blocks for O-post
                        (if (= *sg_global_elev_type* 2)
                          (progn
                            (setq tri_conn_block
                              (cond
                                ((and (>= *sg_global_post_d* 60.0) (<= *sg_global_post_d* 76.0)) "Triangle-Connector-60~76")
                                ((and (>  *sg_global_post_d* 76.0) (<= *sg_global_post_d* 89.0)) "Triangle-Connector-76~89")
                                (t nil)
                              )
                            )
                            (if tri_conn_block
                              (if (tblsearch "BLOCK" tri_conn_block)
                                (progn
                                  (entmake (list '(0 . "INSERT")
                                                 (cons 2 tri_conn_block)
                                                 '(8 . "DIM")
                                                 (cons 10 (list (+ U1_rot_x (* dim_nx opost_tri_dist_cad)) opost_tri_top_y1 0.0))
                                                 '(41 . 1.0) '(42 . 1.0) '(43 . 1.0)
                                                 (cons 50 ang_rad)))
                                  (entmake (list '(0 . "INSERT")
                                                 (cons 2 tri_conn_block)
                                                 '(8 . "DIM")
                                                 (cons 10 (list (+ U2_rot_x (* dim_nx opost_tri_dist_cad)) opost_tri_top_y2 0.0))
                                                 '(41 . 1.0) '(42 . 1.0) '(43 . 1.0)
                                                 (cons 50 ang_rad)))
                                  (prompt (strcat "\n>>> Inserted '" tri_conn_block "' at U1 and U2 post/beam intersections."))
                                )
                                (prompt (strcat "\n>>> Warning: Block '" tri_conn_block "' not found. Skipping."))
                              )
                            )
                          )
                        )
                        ;; Screw pile blocks for O-post at the bottom of each post-axis
                        (if (= *sg_global_elev_type* 2)
                          (progn
                            (setq screw_pile_block
                              (cond
                                ((or (= *sg_global_post_d* 60.0) (= *sg_global_post_d* 63.0)) "screw pile-76")
                                ((= *sg_global_post_d* 76.0) "screw pile-89")
                                ((= *sg_global_post_d* 89.0) "screw pile-102")
                                (t nil)))
                            (if screw_pile_block
                              (if (tblsearch "BLOCK" screw_pile_block)
                                (progn
                                  (entmake (list '(0 . "INSERT")
                                                 (cons 2 screw_pile_block)
                                                 '(8 . "AXIS")
                                                 (cons 10 (list opost_post_x1 lower_top_axis_y 0.0))
                                                 '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                                  (entmake (list '(0 . "INSERT")
                                                 (cons 2 screw_pile_block)
                                                 '(8 . "AXIS")
                                                 (cons 10 (list opost_post_x2 lower_top_axis_y 0.0))
                                                 '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                                  ;; capture screw pile block bottom Y for title placement
                                  (setq sp_vla (vlax-ename->vla-object (entlast)))
                                  (vla-GetBoundingBox sp_vla 'sp_bbmin 'sp_bbmax)
                                  (setq *sg_opost_screw_pile_bot_y* (vlax-safearray-get-element sp_bbmin 1))
                                  (vlax-release-object sp_vla)
                                  (prompt (strcat "\n>>> Inserted '" screw_pile_block "' at both post-axis bottom points."))
                                )
                                (prompt (strcat "\n>>> Warning: Block '" screw_pile_block "' not found. Skipping."))
                              )
                              (prompt "\n>>> Warning: Post diameter not matched for screw pile. Skipping.")
                            )
                          )
                        )
                        ;; C/O-post: angle label between beam-axis and DIM horizontal line
                        ;; 角度为 0 时梁轴与地面平行，无交点可标注（且下面要除以 sin），跳过
                        (if (and (or (= *sg_global_elev_type* 1) (= *sg_global_elev_type* 2) (= *sg_global_elev_type* 3))
                                 (> (abs (sin ang_rad)) 1e-6))
                          (progn
                            (setvar "CLAYER" "DIM")
                            ;; Vertex at intersection of beam-axis (extended) with DIM horizontal (lower_top_axis_y)
                            (setq opost_ang_t     (/ (- lower_top_axis_y ax_L_ry) (sin ang_rad))
                                  opost_ang_vx    (+ ax_L_rx (* opost_ang_t (cos ang_rad)))
                                  opost_ang_arc_x (+ new_line_x1 1700.0)
                                  opost_ang_arc_y (+ lower_top_axis_y (* (- (+ new_line_x1 1700.0) opost_ang_vx) (/ (sin (/ ang_rad 2.0)) (cos (/ ang_rad 2.0)))))
                                  ang_align_x     (if (= *sg_global_elev_type* 2) opost_post_x1 U1_rot_x))
                            (command "_.DIMANGULAR" ""
                                     "_NON" (list opost_ang_vx lower_top_axis_y 0.0)
                                     "_NON" (list (+ opost_ang_vx 4000.0) lower_top_axis_y 0.0)
                                     "_NON" (list (+ opost_ang_vx (* 4000.0 (cos ang_rad))) (+ lower_top_axis_y (* 4000.0 (sin ang_rad))) 0.0)
                                     "_NON" (list opost_ang_arc_x opost_ang_arc_y 0.0))
                            (if (not (= *sg_global_elev_type* 3))
                              ;; XCHQQ 为外部命令（LISP 或 ARX），未加载时跳过以免命令序列错乱
                              (if (or (and (boundp 'c:XCHQQ) (eval 'c:XCHQQ)) (getcname "XCHQQ"))
                                (command "XCHQQ"
                                         (list opost_ang_arc_x opost_ang_arc_y 0.0)
                                         "_NON" (list ang_align_x lower_top_axis_y 0.0))
                                (prompt "\n>>> Warning: command XCHQQ not available, angle label alignment skipped.")
                              )
                            )
                          )
                        )
                     )
                   )

                   ;; 新增: 绘制右侧起点的垂直地平线高差 (Clearance)，即 DIM 横线起点到 PV 左下角源头起点的竖向标注
                   (setvar "CLAYER" "DIM")
                   (command "_.DIMLINEAR" "_NON" (list new_line_x1 lower_top_axis_y 0.0) "_NON" (list pv_start_x pv_start_y 0.0) "_NON" (list (- new_line_x1 500.0) (/ (+ lower_top_axis_y pv_start_y) 2.0) 0.0))
                   
                   ;; 为右侧立面图添加标题、双下划线和比例 1:20
                   (setq elev_center_x   (/ (+ new_line_x1 new_line_x2) 2.0)
                         elev_title_y    (cond
                                           ((and (= *sg_global_elev_type* 2) *sg_opost_screw_pile_bot_y*)
                                            (- *sg_opost_screw_pile_bot_y* 2000.0))
                                           ((= *sg_global_elev_type* 3)
                                            (- lower_top_axis_y 9500.0))
                                           (t
                                            (- post1_bot_y 2000.0)))
                         elev_t1_str     "PV Mount Structure Elevation layout")
                   (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES")
                                  (cons 10 (list elev_center_x elev_title_y 0))
                                  (cons 40 550.0) (cons 1 elev_t1_str) '(72 . 1)
                                  (cons 11 (list elev_center_x elev_title_y 0))))
                   (setq e_elev         (entlast)
                         tb_elev        (textbox (entget e_elev))
                         elev_t1_width  (- (caadr tb_elev) (caar tb_elev))
                         elev_t1_minX   (- elev_center_x (/ elev_t1_width 2.0))
                         elev_t1_maxX   (+ elev_center_x (/ elev_t1_width 2.0))
                         elev_line_x1   (- elev_t1_minX 300.0)
                         elev_line_x2   (+ elev_t1_maxX 300.0)
                         elev_line_top_y (- elev_title_y 250.0)
                         elev_line_bot_y (- elev_line_top_y 150.0))
                   (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                  '(8 . "DIM") '(90 . 2) (cons 43 50.0)
                                  (list 10 elev_line_x1 elev_line_top_y)
                                  (list 10 elev_line_x2 elev_line_top_y)))
                   (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                                  '(8 . "DIM") '(90 . 2) '(43 . 0.0)
                                  (list 10 elev_line_x1 elev_line_bot_y)
                                  (list 10 elev_line_x2 elev_line_bot_y)))
                   (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES")
                                  (cons 10 (list (+ elev_line_x2 400.0) elev_title_y 0))
                                  (cons 40 400.0) (cons 1 "1:20") '(72 . 0)
                                  (cons 11 (list (+ elev_line_x2 400.0) elev_title_y 0))))

                   (if (tblsearch "DIMSTYLE" "TSSD_50_100") (command "-DIMSTYLE" "_R" "TSSD_50_100")) ;; 恢复 TSSD_50_100
                   (setvar "CLAYER" "DIM") ;; 恢复 CLAYER
                 )
               )
                              
               (if (= *sg_global_elev_type* 0)
                 (progn
                   (setq my_breaks
                     (PVRectSgs_AddSegmentedHorizontalDim
                       *sg_global_startX*
                       *sg_global_endX*
                       lower_top_axis_y
                       lower_top_dim_y
                       *sg_global_vx_list*
                       *sg_global_pt_x*
                       *sg_global_w_eval*
                       *sg_global_gap*
                       *sg_global_m*
                       *sg_global_zd_eval*
                       ss_copy_sf))

                   ;; 为分段点绘制连接件：优先插入 LTPJJ 块，无块时回退矩形
                   (if my_breaks
                     (progn
                       (if (not (tblsearch "LAYER" "LTPJJ"))
                         (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "LTPJJ") (70 . 0) (62 . 2))))
                       (setvar "CLAYER" "LTPJJ")
                       (setq rect_half_w 250.0 rect_half_h 50.0)
                       (foreach bx my_breaks
                         (foreach y_orig *sg_global_axis_y_list*
                           (setq cy (- y_orig copy_dist))
                           (if (tblsearch "BLOCK" "LTPJJ")
                             (entmake (list '(0 . "INSERT")
                                            '(2 . "LTPJJ")
                                            '(8 . "LTPJJ")
                                            (cons 10 (list bx cy 0.0))
                                            '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                             (command "_.RECTANG"
                                      "_NON" (list (- bx rect_half_w) (- cy rect_half_h) 0.0)
                                      "_NON" (list (+ bx rect_half_w) (+ cy rect_half_h) 0.0))
                           )
                         )
                       )
                       (setvar "CLAYER" "DIM") ;; 恢复到DIM图层，以免影响后续标注
                     )
                   )
                   (setq i 0)
                   (while (< i (1- (length *sg_global_axis_y_list*)))
                     (setq y_a (- (nth i *sg_global_axis_y_list*) copy_dist) y_b (- (nth (1+ i) *sg_global_axis_y_list*) copy_dist))
                     (command "_.DIMLINEAR" "_NON" (list *sg_global_startX* y_a 0.0) "_NON" (list *sg_global_startX* y_b 0.0) "_NON" (list *sg_global_dim_x_vert* y_a 0.0))
                     (setq i (1+ i))
                   )
                 )
               )
            )
          )
          ;; Keep only the copied bottom detailed dimension row in the lower layout.
        )
      )
    )
  )
  ;; For C/O-post: erase everything drawn before PostFix (main array + ZHWBZH_Singsun entities).
  ;; postfix_start_ent was captured at the very start of this function as the boundary.
  (if (and postfix_start_ent *sg_first_ent_global*
           (not (equal *sg_first_ent_global* postfix_start_ent)))
    (progn
      (setq ss_del (ssadd)
            e_del (entnext *sg_first_ent_global*))
      (while e_del
        (ssadd e_del ss_del)
        (if (equal e_del postfix_start_ent)
          (setq e_del nil)
          (setq e_del (entnext e_del))
        )
      )
      (if (> (sslength ss_del) 0)
        (command "_.ERASE" ss_del "")
      )
    )
  )
  (setq *sg_last_ent_before_macro* nil)
  ;; =============================================================================
  ;; Entity-tracked axis copy: scale 1/5, assign target layers by type.
  ;; Uses entities recorded during elevation drawing — no length heuristics.
  ;; Cross AXIS line (*sg_elev_cross_ent*) is excluded (it is not a structural member).
  ;; =============================================================================
  (if (and *sg_global_new_line_x1* *sg_scale_center_x* *sg_scale_center_y* (not (= *sg_global_elev_type* 0)))
    (progn
      (setq axis_copy_dist 86500.0
            scale_center   (list *sg_scale_center_x* *sg_scale_center_y* 0.0)
            ss_scaled_all  (ssadd))

      ;; Create target layers
      (if (not (tblsearch "LAYER" "01Purlin-01")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "01Purlin-01") (70 . 0) (62 . 3))))
      (if (not (tblsearch "LAYER" "01Purlin-02")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "01Purlin-02") (70 . 0) (62 . 3))))
      (if (not (tblsearch "LAYER" "02Beam"))      (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "02Beam")      (70 . 0) (62 . 4))))
      (if (not (tblsearch "LAYER" "03Brace"))     (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "03Brace")     (70 . 0) (62 . 1))))
      (if (not (tblsearch "LAYER" "04Column"))    (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "04Column")    (70 . 0) (62 . 7))))

      ;; == 1. PURLIN short lines → 01Purlin-01 / 01Purlin-02 (left half / right half) ==
      (if *sg_elev_purlin_ents*
        (progn
          (setq ss_purlin (ssadd))
          (foreach en *sg_elev_purlin_ents*
            (if (and en (entget en)) (ssadd en ss_purlin))
          )
          (if (> (sslength ss_purlin) 0)
            (progn
              (setq ent_before (entlast))
              (command "_.COPY" ss_purlin "" "_NON" (list 0.0 0.0 0.0) (list axis_copy_dist 0.0 0.0))
              ;; Collect new entities
              (setq ss_new_purlin (ssadd)
                    en_new (entnext ent_before))
              (while en_new
                (ssadd en_new ss_new_purlin)
                (ssadd en_new ss_scaled_all)
                (setq en_new (entnext en_new))
              )
              ;; Sort by start-point X to split left→01Purlin-02, right→01Purlin-01
              (setq purlin_xlist nil
                    i 0)
              (while (< i (sslength ss_new_purlin))
                (setq ent (ssname ss_new_purlin i)
                      edata (entget ent)
                      pt10 (cdr (assoc 10 edata)))
                (setq purlin_xlist (cons (list (car pt10) ent) purlin_xlist))
                (setq i (1+ i))
              )
              (setq purlin_xlist (vl-sort purlin_xlist '(lambda (a b) (< (car a) (car b)))))
              (setq split_idx (/ (length purlin_xlist) 2)
                    k 0)
              (foreach px purlin_xlist
                (setq ent (cadr px)
                      edata (entget ent)
                      tgt (if (< k split_idx) "01Purlin-02" "01Purlin-01"))
                (entmod (subst (cons 8 tgt) (assoc 8 edata) edata))
                (setq k (1+ k))
              )
              (prompt (strcat "\n>>> Purlin: " (itoa (sslength ss_new_purlin)) " lines copied ("
                              (itoa split_idx) "->01Purlin-02, "
                              (itoa (- (sslength ss_new_purlin) split_idx)) "->01Purlin-01)."))
            )
          )
        )
        (prompt "\n>>> No purlin axis lines tracked, skipping 01Purlin copy.")
      )

      ;; == 2. BEAM-ANGLE-AXIS → 02Beam ==
      (if (and *sg_elev_beam_ent* (entget *sg_elev_beam_ent*))
        (progn
          (setq ss_beam (ssadd))
          (ssadd *sg_elev_beam_ent* ss_beam)
          (setq ent_before (entlast))
          (command "_.COPY" ss_beam "" "_NON" (list 0.0 0.0 0.0) (list axis_copy_dist 0.0 0.0))
          (setq en_new (entnext ent_before))
          (while en_new
            (setq edata (entget en_new))
            (entmod (subst (cons 8 "02Beam") (assoc 8 edata) edata))
            (ssadd en_new ss_scaled_all)
            (setq en_new (entnext en_new))
          )
          (prompt "\n>>> Beam-angle-axis copied -> 02Beam.")
        )
        (prompt "\n>>> No beam-angle-axis tracked, skipping 02Beam copy.")
      )

      ;; == 3. POST-AXIS → 04Column ==
      (if *sg_elev_post_ents*
        (progn
          (setq ss_post (ssadd))
          (foreach en *sg_elev_post_ents*
            (if (and en (entget en)) (ssadd en ss_post))
          )
          (if (> (sslength ss_post) 0)
            (progn
              (setq ent_before (entlast))
              (command "_.COPY" ss_post "" "_NON" (list 0.0 0.0 0.0) (list axis_copy_dist 0.0 0.0))
              (setq en_new (entnext ent_before)
                    post_copy_list nil)
              (while en_new
                (setq edata (entget en_new))
                (entmod (subst (cons 8 "04Column") (assoc 8 edata) edata))
                (ssadd en_new ss_scaled_all)
                (setq post_copy_list (cons en_new post_copy_list))
                (setq en_new (entnext en_new))
              )
              (prompt (strcat "\n>>> Post-axis: " (itoa (sslength ss_post)) " lines copied -> 04Column."))
            )
          )
        )
        (prompt "\n>>> No post-axis lines tracked, skipping 04Column copy.")
      )

      ;; C-post-single: extend main-view post-axis after copy (75mm up, 1500mm down)
      (if (and (= *sg_global_elev_type* 3) *sg_elev_post_ents*)
        (foreach en *sg_elev_post_ents*
          (if (and en (entget en))
            (progn
              (setq edata (entget en)
                    pt10  (cdr (assoc 10 edata))
                    pt11  (cdr (assoc 11 edata)))
              (setq edata (subst (cons 10 (list (car pt10) (+ (cadr pt10) 175.0) 0.0)) (assoc 10 edata) edata))
              (setq edata (subst (cons 11 (list (car pt11) (- (cadr pt11) 7500.0) 0.0)) (assoc 11 edata) edata))
              (entmod edata)
            )
          )
        )
      )

      ;; == 4. BRACE-AXIS → 03Brace ==
      (if *sg_elev_brace_ents*
        (progn
          (setq ss_brace (ssadd))
          (foreach en *sg_elev_brace_ents*
            (if (and en (entget en)) (ssadd en ss_brace))
          )
          (if (> (sslength ss_brace) 0)
            (progn
              (setq ent_before (entlast))
              (command "_.COPY" ss_brace "" "_NON" (list 0.0 0.0 0.0) (list axis_copy_dist 0.0 0.0))
              (setq en_new (entnext ent_before))
              (while en_new
                (setq edata (entget en_new))
                (entmod (subst (cons 8 "03Brace") (assoc 8 edata) edata))
                (ssadd en_new ss_scaled_all)
                (setq en_new (entnext en_new))
              )
              (prompt (strcat "\n>>> Brace-axis: " (itoa (sslength ss_brace)) " lines copied -> 03Brace."))
              ;; C-post-single: restore brace-copy to original — un-extend both ends + center lower x
              (if (= *sg_global_elev_type* 3)
                (progn
                  (setq brace_all_info nil
                        en_new (entnext ent_before))
                  (while en_new
                    (setq edata (entget en_new)
                          pt10  (cdr (assoc 10 edata))
                          pt11  (cdr (assoc 11 edata)))
                    (if (> (cadr pt10) (cadr pt11))
                      (setq brace_all_info (cons (list en_new 10 pt10 11 pt11) brace_all_info))
                      (setq brace_all_info (cons (list en_new 11 pt11 10 pt10) brace_all_info))
                    )
                    (setq en_new (entnext en_new))
                  )
                  (if brace_all_info
                    (progn
                      (setq cps_copy_cx (+ cps_post_x axis_copy_dist))
                      (foreach blp brace_all_info
                        (setq en       (car blp)
                              top_code (cadr blp)
                              top_pt   (caddr blp)
                              bot_code (cadddr blp)
                              bot_pt   (nth 4 blp)
                              new_top  (polar top_pt (angle top_pt bot_pt) 150.0)
                              new_bot  (polar bot_pt (angle bot_pt top_pt) 150.0))
                        (setq new_bot (list cps_copy_cx (cadr new_bot) 0.0))
                        (setq edata (entget en))
                        (entmod (subst (cons top_code (list (car new_top) (cadr new_top) 0.0))
                                       (assoc top_code edata) edata))
                        (setq edata (entget en))
                        (entmod (subst (cons bot_code new_bot) (assoc bot_code edata) edata))
                      )
                      (prompt "\n>>> C-post-single: brace-copy endpoints restored (un-extended, centered).")
                    )
                  )
                )
              )
            )
          )
        )
        (prompt "\n>>> No brace-axis lines tracked, skipping 03Brace copy.")
      )

      ;; == Scale all copied lines 1/5 about the saved scale center ==
      (if (> (sslength ss_scaled_all) 0)
        (progn
          (prompt (strcat "\n>>> Scaling " (itoa (sslength ss_scaled_all)) " lines 1/5 about ("
                          (rtos (car scale_center) 2 0) "," (rtos (cadr scale_center) 2 0) ")..."))
          (command "_.SCALE" ss_scaled_all "" "_NON" scale_center 0.2)
          (prompt "\n>>> Scale-down completed.")
          ;; Extend/clip post-axis copies to exact beam-angle-axis intersection + ground
          ;; (skipped for C-post-single: scale already places endpoints exactly)
          (if (and post_copy_list lower_top_axis_y U1_rot_y U2_rot_y (not (= *sg_global_elev_type* 3)))
            (progn
              ;; For O-post the post has shifted X; find beam Y at new post X via slope
              (setq beam_dy_per_dx (if (not (= U2_rot_x U1_rot_x))
                                     (/ (- U2_rot_y U1_rot_y) (- U2_rot_x U1_rot_x))
                                     0.0)
                    U1_clamp_y    (if (= *sg_global_elev_type* 2)
                                    (+ U1_rot_y (* beam_dy_per_dx (- opost_post_x1 U1_rot_x)))
                                    U1_rot_y)
                    U2_clamp_y    (if (= *sg_global_elev_type* 2)
                                    (+ U2_rot_y (* beam_dy_per_dx (- opost_post_x2 U2_rot_x)))
                                    U2_rot_y)
                    U1_top_clamp  (+ lower_top_axis_y (* (- U1_clamp_y lower_top_axis_y) 0.2))
                    U2_top_clamp  (+ lower_top_axis_y (* (- U2_clamp_y lower_top_axis_y) 0.2))
                    post_bot_clamp lower_top_axis_y
                    sorted_posts  (vl-sort post_copy_list
                                    '(lambda (a b)
                                       (< (car (cdr (assoc 10 (entget a))))
                                          (car (cdr (assoc 10 (entget b)))))))
                    clip_pairs    (list (cons (nth 0 sorted_posts) U1_top_clamp)
                                        (cons (nth 1 sorted_posts) U2_top_clamp)))
              (foreach pair clip_pairs
                (setq en             (car pair)
                      post_top_clamp (cdr pair))
                (if (and en (entget en))
                  (progn
                    (setq edata (entget en)
                          pt10  (cdr (assoc 10 edata))
                          pt11  (cdr (assoc 11 edata))
                          y10   (cadr pt10)
                          y11   (cadr pt11))
                    (if (> y10 y11)
                      (progn
                        (setq edata (entget en))
                        (entmod (subst (cons 10 (list (car pt10) post_top_clamp (caddr pt10))) (assoc 10 edata) edata))
                        (setq edata (entget en))
                        (entmod (subst (cons 11 (list (car pt11) post_bot_clamp (caddr pt11))) (assoc 11 edata) edata))
                      )
                      (progn
                        (setq edata (entget en))
                        (entmod (subst (cons 10 (list (car pt10) post_bot_clamp (caddr pt10))) (assoc 10 edata) edata))
                        (setq edata (entget en))
                        (entmod (subst (cons 11 (list (car pt11) post_top_clamp (caddr pt11))) (assoc 11 edata) edata))
                      )
                    )
                  )
                )
              )
              (prompt "\n>>> Post-axis copies extended to exact beam-intersection/ground bounds.")
            )
          )
        )
        (prompt "\n>>> No axis lines to scale.")
      )
    )
    (prompt "\n>>> Skipping axis copy: right section not generated or scale center missing.")
  )

  ;; Erase original-position brace tracking lines from elevation (C-post only)
  (if *sg_brace_track_ents*
    (progn
      (setq ss_bt (ssadd))
      (foreach en *sg_brace_track_ents*
        (if (and en (entget en)) (ssadd en ss_bt)))
      (if (> (sslength ss_bt) 0)
        (command "_.ERASE" ss_bt ""))
    )
  )

  ;; Erase O-post unshifted brace-axis source lines (kept only for scale-copy, now redundant)
  (if *sg_opost_brace_src_ents*
    (progn
      (setq ss_obs (ssadd))
      (foreach en *sg_opost_brace_src_ents*
        (if (and en (entget en)) (ssadd en ss_obs)))
      (if (> (sslength ss_obs) 0)
        (command "_.ERASE" ss_obs ""))
    )
  )

  ;; Extend visible brace-axis lines both ends by 30mm (150 CAD units)
  (if (and *sg_brace_vis_ents* (= *sg_global_elev_type* 1))
    (progn
      (setq brace_ext_cad (* 30.0 5.0))
      (foreach en *sg_brace_vis_ents*
        (if (and en (entget en))
          (progn
            (setq edata (entget en)
                  pt10  (cdr (assoc 10 edata))
                  pt11  (cdr (assoc 11 edata))
                  brace_dx  (- (car pt11) (car pt10))
                  brace_dy  (- (cadr pt11) (cadr pt10))
                  brace_len (sqrt (+ (* brace_dx brace_dx) (* brace_dy brace_dy))))
            (if (> brace_len 0.0)
              (progn
                (setq brace_nx (/ brace_dx brace_len)
                      brace_ny (/ brace_dy brace_len))
                (setq edata (entget en))
                (entmod (subst (cons 10 (list (- (car pt10) (* brace_nx brace_ext_cad))
                                              (- (cadr pt10) (* brace_ny brace_ext_cad))
                                              (caddr pt10)))
                               (assoc 10 edata) edata))
                (setq edata (entget en))
                (entmod (subst (cons 11 (list (+ (car pt11) (* brace_nx brace_ext_cad))
                                              (+ (cadr pt11) (* brace_ny brace_ext_cad))
                                              (caddr pt11)))
                               (assoc 11 edata) edata))
              )
            )
          )
        )
      )
      (prompt "\n>>> Brace-axis lines extended 30mm at both ends.")
    )
  )

  ;; Draw brace-section rectangles (outer 50mm, inner 30mm wide) centered on each brace-axis line
  (if (and *sg_brace_vis_ents* (= *sg_global_elev_type* 1))
    (progn
      (setq brace_hw1 (* 25.0 5.0)
            brace_hw2 (* 15.0 5.0))
      (setvar "CLAYER" "beam")
      (foreach en *sg_brace_vis_ents*
        (if (and en (entget en))
          (progn
            (setq edata     (entget en)
                  pt10      (cdr (assoc 10 edata))
                  pt11      (cdr (assoc 11 edata))
                  brace_dx  (- (car pt11) (car pt10))
                  brace_dy  (- (cadr pt11) (cadr pt10))
                  brace_len (sqrt (+ (* brace_dx brace_dx) (* brace_dy brace_dy))))
            (if (> brace_len 0.0)
              (progn
                (setq brace_nx    (/ brace_dx brace_len)
                      brace_ny    (/ brace_dy brace_len)
                      brace_mid_x (/ (+ (car pt10) (car pt11)) 2.0)
                      brace_mid_y (/ (+ (cadr pt10) (cadr pt11)) 2.0)
                      brace_hl    (/ brace_len 2.0)
                      brace_perp_x (- brace_ny)
                      brace_perp_y brace_nx)
                ;; Outer rect: width 50mm
                (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                               '(8 . "beam") '(90 . 4) '(70 . 1)
                               (list 10 (+ brace_mid_x (* brace_nx brace_hl) (* brace_perp_x brace_hw1))
                                        (+ brace_mid_y (* brace_ny brace_hl) (* brace_perp_y brace_hw1)))
                               (list 10 (+ brace_mid_x (* brace_nx brace_hl) (* brace_perp_x (- brace_hw1)))
                                        (+ brace_mid_y (* brace_ny brace_hl) (* brace_perp_y (- brace_hw1))))
                               (list 10 (+ brace_mid_x (* brace_nx (- brace_hl)) (* brace_perp_x (- brace_hw1)))
                                        (+ brace_mid_y (* brace_ny (- brace_hl)) (* brace_perp_y (- brace_hw1))))
                               (list 10 (+ brace_mid_x (* brace_nx (- brace_hl)) (* brace_perp_x brace_hw1))
                                        (+ brace_mid_y (* brace_ny (- brace_hl)) (* brace_perp_y brace_hw1)))))
                ;; Inner rect: width 30mm
                (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                               '(8 . "beam") '(90 . 4) '(70 . 1)
                               (list 10 (+ brace_mid_x (* brace_nx brace_hl) (* brace_perp_x brace_hw2))
                                        (+ brace_mid_y (* brace_ny brace_hl) (* brace_perp_y brace_hw2)))
                               (list 10 (+ brace_mid_x (* brace_nx brace_hl) (* brace_perp_x (- brace_hw2)))
                                        (+ brace_mid_y (* brace_ny brace_hl) (* brace_perp_y (- brace_hw2))))
                               (list 10 (+ brace_mid_x (* brace_nx (- brace_hl)) (* brace_perp_x (- brace_hw2)))
                                        (+ brace_mid_y (* brace_ny (- brace_hl)) (* brace_perp_y (- brace_hw2))))
                               (list 10 (+ brace_mid_x (* brace_nx (- brace_hl)) (* brace_perp_x brace_hw2))
                                        (+ brace_mid_y (* brace_ny (- brace_hl)) (* brace_perp_y brace_hw2)))))
              )
            )
          )
        )
      )
      (prompt "\n>>> Brace-section rectangles drawn (50mm outer, 30mm inner).")
    )
  )

  ;; O-post: extend visible brace-axis lines both ends by 30mm (150 CAD units)
  (if (and *sg_brace_vis_ents* (= *sg_global_elev_type* 2))
    (progn
      (setq brace_ext_cad (* 30.0 5.0))
      (foreach en *sg_brace_vis_ents*
        (if (and en (entget en))
          (progn
            (setq edata (entget en)
                  pt10  (cdr (assoc 10 edata))
                  pt11  (cdr (assoc 11 edata))
                  brace_dx  (- (car pt11) (car pt10))
                  brace_dy  (- (cadr pt11) (cadr pt10))
                  brace_len (sqrt (+ (* brace_dx brace_dx) (* brace_dy brace_dy))))
            (if (> brace_len 0.0)
              (progn
                (setq brace_nx (/ brace_dx brace_len)
                      brace_ny (/ brace_dy brace_len))
                (setq edata (entget en))
                (entmod (subst (cons 10 (list (- (car pt10) (* brace_nx brace_ext_cad))
                                              (- (cadr pt10) (* brace_ny brace_ext_cad))
                                              (caddr pt10)))
                               (assoc 10 edata) edata))
                (setq edata (entget en))
                (entmod (subst (cons 11 (list (+ (car pt11) (* brace_nx brace_ext_cad))
                                              (+ (cadr pt11) (* brace_ny brace_ext_cad))
                                              (caddr pt11)))
                               (assoc 11 edata) edata))
              )
            )
          )
        )
      )
      (prompt "\n>>> O-post brace-axis lines extended 30mm at both ends.")
    )
  )

  ;; O-post: brace-section rectangles (outer 50mm, inner 30mm) centered on each brace-axis line
  (if (and *sg_brace_vis_ents* (= *sg_global_elev_type* 2))
    (progn
      (setq brace_hw1 (* 25.0 5.0)
            brace_hw2 (* 15.0 5.0))
      (setvar "CLAYER" "beam")
      (foreach en *sg_brace_vis_ents*
        (if (and en (entget en))
          (progn
            (setq edata     (entget en)
                  pt10      (cdr (assoc 10 edata))
                  pt11      (cdr (assoc 11 edata))
                  brace_dx  (- (car pt11) (car pt10))
                  brace_dy  (- (cadr pt11) (cadr pt10))
                  brace_len (sqrt (+ (* brace_dx brace_dx) (* brace_dy brace_dy))))
            (if (> brace_len 0.0)
              (progn
                (setq brace_nx    (/ brace_dx brace_len)
                      brace_ny    (/ brace_dy brace_len)
                      brace_mid_x (/ (+ (car pt10) (car pt11)) 2.0)
                      brace_mid_y (/ (+ (cadr pt10) (cadr pt11)) 2.0)
                      brace_hl    (/ brace_len 2.0)
                      brace_perp_x (- brace_ny)
                      brace_perp_y brace_nx)
                ;; Outer rect: width 50mm
                (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                               '(8 . "beam") '(90 . 4) '(70 . 1)
                               (list 10 (+ brace_mid_x (* brace_nx brace_hl) (* brace_perp_x brace_hw1))
                                        (+ brace_mid_y (* brace_ny brace_hl) (* brace_perp_y brace_hw1)))
                               (list 10 (+ brace_mid_x (* brace_nx brace_hl) (* brace_perp_x (- brace_hw1)))
                                        (+ brace_mid_y (* brace_ny brace_hl) (* brace_perp_y (- brace_hw1))))
                               (list 10 (+ brace_mid_x (* brace_nx (- brace_hl)) (* brace_perp_x (- brace_hw1)))
                                        (+ brace_mid_y (* brace_ny (- brace_hl)) (* brace_perp_y (- brace_hw1))))
                               (list 10 (+ brace_mid_x (* brace_nx (- brace_hl)) (* brace_perp_x brace_hw1))
                                        (+ brace_mid_y (* brace_ny (- brace_hl)) (* brace_perp_y brace_hw1)))))
                ;; Inner rect: width 30mm
                (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                               '(8 . "beam") '(90 . 4) '(70 . 1)
                               (list 10 (+ brace_mid_x (* brace_nx brace_hl) (* brace_perp_x brace_hw2))
                                        (+ brace_mid_y (* brace_ny brace_hl) (* brace_perp_y brace_hw2)))
                               (list 10 (+ brace_mid_x (* brace_nx brace_hl) (* brace_perp_x (- brace_hw2)))
                                        (+ brace_mid_y (* brace_ny brace_hl) (* brace_perp_y (- brace_hw2))))
                               (list 10 (+ brace_mid_x (* brace_nx (- brace_hl)) (* brace_perp_x (- brace_hw2)))
                                        (+ brace_mid_y (* brace_ny (- brace_hl)) (* brace_perp_y (- brace_hw2))))
                               (list 10 (+ brace_mid_x (* brace_nx (- brace_hl)) (* brace_perp_x brace_hw2))
                                        (+ brace_mid_y (* brace_ny (- brace_hl)) (* brace_perp_y brace_hw2)))))
              )
            )
          )
        )
      )
      (prompt "\n>>> O-post brace-section rectangles drawn (50mm outer, 30mm inner).")
    )
  )

  ;; Label brace-axis length with TSSD_20_100, 185mm below the axis line
  (if (and *sg_brace_vis_ents* (= *sg_global_elev_type* 1))
    (progn
      (setvar "CLAYER" "DIM")
      (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
      (foreach en *sg_brace_vis_ents*
        (if (and en (entget en))
          (progn
            (setq edata     (entget en)
                  pt10      (cdr (assoc 10 edata))
                  pt11      (cdr (assoc 11 edata))
                  brace_dx  (- (car pt11) (car pt10))
                  brace_dy  (- (cadr pt11) (cadr pt10))
                  brace_len (sqrt (+ (* brace_dx brace_dx) (* brace_dy brace_dy))))
            (if (> brace_len 0.0)
              (progn
                (setq brace_nx    (/ brace_dx brace_len)
                      brace_ny    (/ brace_dy brace_len)
                      brace_mid_x (/ (+ (car pt10) (car pt11)) 2.0)
                      brace_mid_y (/ (+ (cadr pt10) (cadr pt11)) 2.0))
                ;; Perpendicular toward negative Y (below the brace line in the drawing)
                (if (>= brace_nx 0.0)
                  (setq dim_perp_x brace_ny  dim_perp_y (- brace_nx))
                  (setq dim_perp_x (- brace_ny) dim_perp_y brace_nx)
                )
                (setq brace_dim_x (+ brace_mid_x (* dim_perp_x (* 185.0 5.0)))
                      brace_dim_y (+ brace_mid_y (* dim_perp_y (* 185.0 5.0))))
                (command "_.DIMALIGNED"
                         "_NON" (list (car pt10) (cadr pt10) 0.0)
                         "_NON" (list (car pt11) (cadr pt11) 0.0)
                         "_NON" (list brace_dim_x brace_dim_y 0.0))
              )
            )
          )
        )
      )
      (prompt "\n>>> Brace-axis length labels added (TSSD_20_100, 185mm below).")
    )
  )

  ;; Label post-axis length with TSSD_20_100, 185mm outside the drawing
  (if (and *sg_elev_post_ents* (= *sg_global_elev_type* 1))
    (progn
      (setvar "CLAYER" "DIM")
      (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
      (setq sorted_posts (vl-sort *sg_elev_post_ents*
                            '(lambda (a b)
                               (< (car (cdr (assoc 10 (entget a))))
                                  (car (cdr (assoc 10 (entget b)))))))
            i 0)
      (foreach en sorted_posts
        (if (and en (entget en))
          (progn
            (setq edata      (entget en)
                  pt10       (cdr (assoc 10 edata))
                  pt11       (cdr (assoc 11 edata))
                  post_mid_y (/ (+ (cadr pt10) (cadr pt11)) 2.0))
            (if (= i 0)
              (setq post_dim_x (- (car pt10) (* 185.0 5.0)))
              (setq post_dim_x (+ (car pt10) (* 185.0 5.0)))
            )
            (command "_.DIMALIGNED"
                     "_NON" (list (car pt10) (cadr pt10) 0.0)
                     "_NON" (list (car pt11) (cadr pt11) 0.0)
                     "_NON" (list post_dim_x post_mid_y 0.0))
            (setq i (1+ i))
          )
        )
      )
      (prompt "\n>>> Post-axis length labels added (TSSD_20_100, 185mm outside).")
    )
  )

  ;; Label post-axis length BELOW the DIM horizontal line, 185mm inside the drawing
  (if (and *sg_elev_post_ents* lower_top_axis_y (= *sg_global_elev_type* 1))
    (progn
      (setvar "CLAYER" "DIM")
      (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
      (setq sorted_posts (vl-sort *sg_elev_post_ents*
                            '(lambda (a b)
                               (< (car (cdr (assoc 10 (entget a))))
                                  (car (cdr (assoc 10 (entget b)))))))
            i 0)
      (foreach en sorted_posts
        (if (and en (entget en))
          (progn
            (setq edata     (entget en)
                  pt10      (cdr (assoc 10 edata))
                  post_bot_clamp (if (= i 0) post1_bot_y post2_bot_y))
            ;; Only label when the post extends below the DIM horizontal line
            (if (< post_bot_clamp lower_top_axis_y)
              (progn
                (setq post_mid_y (/ (+ lower_top_axis_y post_bot_clamp) 2.0))
                (if (= i 0)
                  (setq post_dim_x (+ (car pt10) (* 185.0 5.0)))
                  (setq post_dim_x (- (car pt10) (* 185.0 5.0)))
                )
                (command "_.DIMALIGNED"
                         "_NON" (list (car pt10) lower_top_axis_y 0.0)
                         "_NON" (list (car pt10) post_bot_clamp 0.0)
                         "_NON" (list post_dim_x post_mid_y 0.0))
              )
            )
            (setq i (1+ i))
          )
        )
      )
      (prompt "\n>>> Post-axis below-DIM length labels added (TSSD_20_100, 185mm inside).")
    )
  )

  ;; O-post: label brace-axis length, 185mm below the axis line
  (if (and *sg_brace_vis_ents* (= *sg_global_elev_type* 2))
    (progn
      (setvar "CLAYER" "DIM")
      (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
      (foreach en *sg_brace_vis_ents*
        (if (and en (entget en))
          (progn
            (setq edata     (entget en)
                  pt10      (cdr (assoc 10 edata))
                  pt11      (cdr (assoc 11 edata))
                  brace_dx  (- (car pt11) (car pt10))
                  brace_dy  (- (cadr pt11) (cadr pt10))
                  brace_len (sqrt (+ (* brace_dx brace_dx) (* brace_dy brace_dy))))
            (if (> brace_len 0.0)
              (progn
                (setq brace_nx    (/ brace_dx brace_len)
                      brace_ny    (/ brace_dy brace_len)
                      brace_mid_x (/ (+ (car pt10) (car pt11)) 2.0)
                      brace_mid_y (/ (+ (cadr pt10) (cadr pt11)) 2.0))
                (if (>= brace_nx 0.0)
                  (setq dim_perp_x brace_ny  dim_perp_y (- brace_nx))
                  (setq dim_perp_x (- brace_ny) dim_perp_y brace_nx))
                (setq brace_dim_x (+ brace_mid_x (* dim_perp_x (* 185.0 5.0)))
                      brace_dim_y (+ brace_mid_y (* dim_perp_y (* 185.0 5.0))))
                (command "_.DIMALIGNED"
                         "_NON" (list (car pt10) (cadr pt10) 0.0)
                         "_NON" (list (car pt11) (cadr pt11) 0.0)
                         "_NON" (list brace_dim_x brace_dim_y 0.0))
              )
            )
          )
        )
      )
      (prompt "\n>>> O-post brace-axis length labels added (TSSD_20_100, 185mm below).")
    )
  )

  ;; O-post: label post-axis length, 185mm outside the drawing
  (if (and *sg_elev_post_ents* (= *sg_global_elev_type* 2))
    (progn
      (setvar "CLAYER" "DIM")
      (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
      (setq sorted_posts (vl-sort *sg_elev_post_ents*
                            '(lambda (a b)
                               (< (car (cdr (assoc 10 (entget a))))
                                  (car (cdr (assoc 10 (entget b)))))))
            i 0)
      (foreach en sorted_posts
        (if (and en (entget en))
          (progn
            (setq edata      (entget en)
                  pt10       (cdr (assoc 10 edata))
                  pt11       (cdr (assoc 11 edata))
                  post_mid_y (/ (+ (cadr pt10) (cadr pt11)) 2.0))
            (if (= i 0)
              (setq post_dim_x (- (car pt10) (* 185.0 5.0)))
              (setq post_dim_x (+ (car pt10) (* 185.0 5.0))))
            (command "_.DIMALIGNED"
                     "_NON" (list (car pt10) (cadr pt10) 0.0)
                     "_NON" (list (car pt11) (cadr pt11) 0.0)
                     "_NON" (list post_dim_x post_mid_y 0.0))
            (setq i (1+ i))
          )
        )
      )
      (prompt "\n>>> O-post post-axis length labels added (TSSD_20_100, 185mm outside).")
    )
  )

  ;; 清理全局变量（在复制轴线之后执行）
  (setq *sg_global_h* nil *sg_global_hole* nil *sg_global_sf* nil *sg_title_ents_list* nil *sg_left_dims_global* nil *sg_top_dims_global* nil *sg_upper_only_ents* nil *sg_global_axis_y_list* nil *sg_global_startX* nil *sg_global_endX* nil *sg_global_dim_x_vert* nil *sg_global_pt_x* nil *sg_global_w_eval* nil *sg_global_gap* nil *sg_global_start_vx* nil *sg_global_zd_eval* nil *sg_global_dim_y* nil *sg_global_dim_y2* nil *sg_global_top_y* nil *sg_global_axis_y2_baseline* nil *sg_global_vx_list* nil *sg_global_bottom_y* nil *sg_global_bottom_dim_y* nil *sg_global_clearance* nil *sg_global_angle* nil *sg_global_nop* nil *sg_global_elev_type* nil *sg_global_post_w* nil *sg_global_post_d* nil *sg_global_beam_h* nil *sg_global_purlin_H* nil *sg_global_new_line_x1* nil *sg_scale_center_x* nil *sg_scale_center_y* nil *sg_elev_purlin_ents* nil *sg_elev_cross_ent* nil *sg_elev_beam_ent* nil *sg_elev_post_ents* nil *sg_elev_brace_ents* nil *sg_brace_track_ents* nil *sg_brace_vis_ents* nil *sg_opost_brace_src_ents* nil *sg_opost_screw_pile_bot_y* nil)

  (PVRectSgs_RestoreEnv)
  (command "_.-LAYER" "_ON" "*" "")
  (princ)
)

;; =============================================================================
;; Environment restore / error handling (shared by PVRect_Singsun and ZHWBZH_Singsun)
;; =============================================================================

;; 恢复 OSMODE / CLAYER，并重新打开 PVRect_Singsun 后处理前关闭的图层（仅当确实是本插件关闭的）
(defun PVRectSgs_RestoreEnv ( / layers lay)
  (if *sg_old_osmode_global*
    (progn (setvar "OSMODE" *sg_old_osmode_global*) (setq *sg_old_osmode_global* nil))
  )
  (if *sg_old_layer_global*
    (progn (vl-catch-all-apply 'setvar (list "CLAYER" *sg_old_layer_global*)) (setq *sg_old_layer_global* nil))
  )
  (if *sg_pvrect_layers_off*
    (progn
      (setq layers (vla-get-Layers (vla-get-ActiveDocument (vlax-get-acad-object))))
      (foreach name '("purlin" "beam" "PV" "DIM")
        (setq lay (vl-catch-all-apply 'vla-item (list layers name)))
        (if (not (vl-catch-all-error-p lay))
          (vl-catch-all-apply 'vla-put-LayerOn (list lay :vlax-true))
        )
      )
      (setq *sg_pvrect_layers_off* nil)
    )
  )
)

(defun PVRectSgs_OnError (msg)
  (if (and msg (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*EXIT*,*BREAK*")))
    (princ (strcat "\n>>> PVRect_Singsun error: " msg))
  )
  (PVRectSgs_RestoreEnv)
  (princ)
)

;; =============================================================================
;; 3. Post-Process Command (axis bubbles + inter-axis dims, then PostFix)
;; =============================================================================

(defun c:ZHWBZH_Singsun ( / ax_r ax_cy ax_th ax_dim_y ax_total_y ax_n ax_vx_prev ax_vx_next *error*)
  (defun *error* (msg) (PVRectSgs_OnError msg))
  (if (and (= *sg_global_elev_type* 0) *sg_global_vx_list* *sg_global_bottom_y* *sg_global_sf*)
    (progn
      ;; Layout (top→bottom): plan bottom → per-axis dims → total dim → circles → title
      (setq ax_r       (* 300.0 *sg_global_sf*)
            ax_dim_y   (- *sg_global_bottom_y* (* 700.0 *sg_global_sf*))
            ax_total_y (- *sg_global_bottom_y* (* 1150.0 *sg_global_sf*))
            ax_cy      (- *sg_global_bottom_y* (* 1820.0 *sg_global_sf*))
            ax_th      (* 0.85 ax_r)
            ax_n       1)
      (if (not (tblsearch "LAYER" "AXIS")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "AXIS") (70 . 0) (62 . 1))))
      (if (not (tblsearch "LAYER" "NUM"))  (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "NUM")  (70 . 0) (62 . 7))))
      (if (not (tblsearch "STYLE" "TIMES")) (entmake '((0 . "STYLE") (100 . "AcDbSymbolTableRecord") (100 . "AcDbTextStyleTableRecord") (2 . "TIMES") (70 . 0) (40 . 0.0) (41 . 1.0) (3 . "times.ttf"))))
      (foreach vx *sg_global_vx_list*
        ;; White approach line: plan bottom to circle top
        (entmake (list '(0 . "LINE") '(8 . "AXIS") '(62 . 7)
                       (cons 10 (list vx *sg_global_bottom_y* 0.0))
                       (cons 11 (list vx (+ ax_cy ax_r) 0.0))))
        (entmake (list '(0 . "CIRCLE") '(8 . "NUM")
                       (cons 10 (list vx ax_cy 0.0))
                       (cons 40 ax_r)))
        (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES")
                       (cons 10 (list vx ax_cy 0.0))
                       (cons 40 ax_th)
                       (cons 1 (itoa ax_n))
                       '(72 . 1) '(73 . 2)
                       (cons 11 (list vx ax_cy 0.0))))
        (setq ax_n (1+ ax_n))
      )
      (if (not (tblsearch "LAYER" "DIM")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "DIM") (70 . 0) (62 . 7))))
      (command "_.-LAYER" "_ON" "DIM" "")
      (setvar "CLAYER" "DIM")
      (if (tblsearch "DIMSTYLE" "TSSD_50_100") (command "-DIMSTYLE" "_R" "TSSD_50_100"))
      ;; Left edge dim: array start to first axis
      (if (and *sg_global_startX* (car *sg_global_vx_list*))
        (command "_.DIMLINEAR"
                 "_NON" (list *sg_global_startX* *sg_global_bottom_y* 0.0)
                 "_NON" (list (car *sg_global_vx_list*) *sg_global_bottom_y* 0.0)
                 "_NON" (list (/ (+ *sg_global_startX* (car *sg_global_vx_list*)) 2.0) ax_dim_y 0.0))
      )
      ;; Inter-axis dims
      (setq ax_vx_prev (car *sg_global_vx_list*))
      (foreach ax_vx_next (cdr *sg_global_vx_list*)
        (command "_.DIMLINEAR"
                 "_NON" (list ax_vx_prev *sg_global_bottom_y* 0.0)
                 "_NON" (list ax_vx_next *sg_global_bottom_y* 0.0)
                 "_NON" (list (/ (+ ax_vx_prev ax_vx_next) 2.0) ax_dim_y 0.0))
        (setq ax_vx_prev ax_vx_next)
      )
      ;; Right edge dim: last axis to array end
      (if (and *sg_global_endX* (last *sg_global_vx_list*))
        (command "_.DIMLINEAR"
                 "_NON" (list (last *sg_global_vx_list*) *sg_global_bottom_y* 0.0)
                 "_NON" (list *sg_global_endX* *sg_global_bottom_y* 0.0)
                 "_NON" (list (/ (+ (last *sg_global_vx_list*) *sg_global_endX*) 2.0) ax_dim_y 0.0))
      )
      ;; Total span dim: leftmost to rightmost axis, one row below per-axis dims
      (if (and (car *sg_global_vx_list*) (last *sg_global_vx_list*)
               (not (equal (car *sg_global_vx_list*) (last *sg_global_vx_list*))))
        (command "_.DIMLINEAR"
                 "_NON" (list (car *sg_global_vx_list*) *sg_global_bottom_y* 0.0)
                 "_NON" (list (last *sg_global_vx_list*) *sg_global_bottom_y* 0.0)
                 "_NON" (list (/ (+ (car *sg_global_vx_list*) (last *sg_global_vx_list*)) 2.0) ax_total_y 0.0))
      )
    )
  )
  (PVRectSgs_PostFix)
  (princ)
)

;; =============================================================================
;; 3b. MyModel: 3D analysis model (rotate → purlins → frames → DXF)
;;     由对话框 Output = MyModel 触发；参数全部来自对话框（不再读取 Excel“阵列计算”）
;; =============================================================================

;; 各榀支架相对首榀（原始榀）的沿檩条距离，与平面图竖向轴线一致：
;; zn=1 无副本；zn=2 一跨 zde；zn>=3 首尾跨 zde、中间各跨 zd
(defun PVRectSgs_FrameOffsets (zn zd zde / spans acc out)
  (cond ((<= zn 1) (setq spans nil))
        ((= zn 2) (setq spans (list zde)))
        (T (setq spans (append (list zde) (PVRectSgs_Repeat zd (- zn 3)) (list zde)))))
  (setq acc 0.0)
  (foreach sp spans
    (setq acc (+ acc sp) out (cons acc out))
  )
  (reverse out)
)

(defun PVRectSgs_Repeat (x k / out)
  (repeat (max k 0) (setq out (cons x out)))
  out
)

;; ew_slope     东西向坡度（度）：檩条在长度方向绕 X 轴倾斜，沿坡长度不变
;; purlin_len   檩条总长
;; dist1        原始榀到檩条 +Y 端的沿坡距离（另一侧 = purlin_len - dist1）
;; frame_offs   各副本榀相对原始榀的沿坡距离（向 -Y 方向）
(defun PVRectSgs_MyModel (ew_slope purlin_len dist1 frame_offs / *error* ss ss_all i old_osmode old_cmdecho
                           pt0 pt1 obj newObj moveVec dist2 ss_pur en p1 p2 base_pt mSpace j failCount
                           curLayer dwg_full dwg_path dxf_name dxf_path acadDoc ans off
                           _collect-curve-layers _erase-entities-on-layer _layer-name-list
                           _prepare-layers-for-delete _delete-extra-layers ew_r ew_c ew_s)

  (defun *error* (msg)
    (if old_osmode (setvar "OSMODE" old_osmode))
    (if old_cmdecho (setvar "CMDECHO" old_cmdecho))
    (if acadDoc (vl-catch-all-apply 'vla-EndUndoMark (list acadDoc)))
    (if (not (wcmatch (strcase (vl-princ-to-string msg)) "*CANCEL*,*QUIT*,*EXIT*"))
      (princ (strcat "\n[MyModel ERR] " (vl-princ-to-string msg)))
    )
    (princ)
  )

  (defun _collect-curve-layers (/ ss_curve idx curveObj layerName keepLayers)
    (setq keepLayers '())
    (if (setq ss_curve
              (ssget "_X"
                     '((0 . "LINE,ARC,CIRCLE,ELLIPSE,LWPOLYLINE,POLYLINE,SPLINE,XLINE,RAY"))))
      (progn
        (setq idx 0)
        (repeat (sslength ss_curve)
          (setq curveObj (vlax-ename->vla-object (ssname ss_curve idx))
                layerName (strcase (vla-get-Layer curveObj)))
          (if (not (member layerName keepLayers))
            (setq keepLayers (cons layerName keepLayers))
          )
          (setq idx (1+ idx))
        )
      )
    )
    keepLayers
  )

  (defun _erase-entities-on-layer (layName / ss_layer idx removedCount)
    (setq removedCount 0)
    (if (setq ss_layer (ssget "_X" (list (cons 8 layName))))
      (progn
        (setq idx 0)
        (repeat (sslength ss_layer)
          (if (not (vl-catch-all-error-p
                     (vl-catch-all-apply 'vla-delete
                                         (list (vlax-ename->vla-object (ssname ss_layer idx))))))
            (setq removedCount (1+ removedCount))
          )
          (setq idx (1+ idx))
        )
      )
    )
    removedCount
  )

  (defun _layer-name-list (doc / layerNames layerObj)
    (setq layerNames '())
    (vlax-for layerObj (vla-get-Layers doc)
      (setq layerNames (cons (vla-get-Name layerObj) layerNames))
    )
    (reverse layerNames)
  )

  (defun _prepare-layers-for-delete (doc / layerObj)
    (vlax-for layerObj (vla-get-Layers doc)
      (vl-catch-all-apply 'vla-put-Lock (list layerObj :vlax-false))
      (vl-catch-all-apply 'vla-put-Freeze (list layerObj :vlax-false))
      (vl-catch-all-apply 'vla-put-LayerOn (list layerObj :vlax-true))
    )
  )

  (defun _delete-extra-layers (doc / keepLayers layerName removedCount deletedCount pass)
    (princ "\n[Step 4] Removing unused layers...")
    (_prepare-layers-for-delete doc)
    (setq keepLayers (_collect-curve-layers))
    (if (not (member "0" keepLayers))
      (setq keepLayers (cons "0" keepLayers))
    )
    (if (/= (getvar "CLAYER") "0")
      (setvar "CLAYER" "0")
    )

    (setq removedCount 0)
    (foreach layerName (_layer-name-list doc)
      (if (and (/= (strcase layerName) "0")
               (not (member (strcase layerName) keepLayers))
               (not (wcmatch layerName "*|*")))
        (setq removedCount (+ removedCount (_erase-entities-on-layer layerName)))
      )
    )

    (command-s "_.-PURGE" "_A" "*" "_N")

    (setq deletedCount 0
          pass 0)
    (repeat 2
      (setq pass (1+ pass))
      (foreach layerName (_layer-name-list doc)
        (if (and (/= (strcase layerName) "0")
                 (not (member (strcase layerName) keepLayers))
                 (not (wcmatch layerName "*|*")))
          (if (not (vl-catch-all-error-p
                     (vl-catch-all-apply 'vla-delete
                                         (list (vla-Item (vla-get-Layers doc) layerName)))))
            (setq deletedCount (1+ deletedCount))
          )
        )
      )
      (command-s "_.-PURGE" "_A" "*" "_N")
    )

    (princ (strcat "\n>>> Layers cleaned: kept "
                   (itoa (length keepLayers))
                   " layer(s) with curves, deleted "
                   (itoa deletedCount)
                   " layer(s), erased "
                   (itoa removedCount)
                   " object(s)."))
  )

  ;; 0. 前置检查：图纸必须已保存（DXF 导出到图纸所在目录）；防止对同一模型重复旋转
  (if (= (getvar "DWGTITLED") 0)
    (progn
      (princ "\n[MyModel ERR] Drawing is not saved. Save it first, then run again.")
      (exit)
    )
  )
  (setq acadDoc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (if (or (= (strcase (cond ((vl-filename-extension (getvar "DWGNAME"))) (""))) ".DXF")
          (vlax-ldata-get "MyModel" "Rotated"))
    (progn
      (princ "\n[Warn] This drawing was already processed by MyModel (or is the exported DXF). Running again rotates it another 90 degrees.")
      (initget "Yes No")
      (setq ans (getkword "\nContinue anyway? [Yes/No] <No>: "))
      (if (/= ans "Yes") (progn (princ "\n>>> Cancelled.") (exit)))
    )
  )

  ;; 檩条方向单位向量 (0, ew_c, ew_s)：正值时副本方向（-Y）逐榀降低
  (setq ew_r (* (if (numberp ew_slope) ew_slope 0.0) (/ pi 180.0))
        ew_c (cos ew_r)
        ew_s (sin ew_r)
        dist2 (- purlin_len dist1))
  (princ (strcat "\n[Data] Purlin length=" (rtos purlin_len 2 2)
                 " | +Y overhang=" (rtos dist1 2 2)
                 " | Frames=" (itoa (1+ (length frame_offs)))
                 " | Offsets=" (if frame_offs (apply 'strcat (mapcar '(lambda (x) (strcat (rtos x 2 0) " ")) frame_offs)) "-")
                 " | E-W slope=" (rtos ew_slope 2 2) " deg"))

  (vla-StartUndoMark acadDoc)
  (setq old_osmode (getvar "OSMODE")
        old_cmdecho (getvar "CMDECHO"))
  (setvar "OSMODE" 0)
  (setvar "CMDECHO" 0)
  (princ "\n[MyModel] Building 3D analysis model...")

  ;; 1. 执行三维旋转（仅模型空间；先解锁图层，避免锁定图层上的对象旋转失败）
  (princ "\n[Step 1] Rotating all model-space objects 90 deg about X...")
  (vlax-for obj (vla-get-Layers acadDoc)
    (vl-catch-all-apply 'vla-put-Lock (list obj :vlax-false))
  )
  (setq pt0 (list 0.0 0.0 0.0)
        pt1 (list 1.0 0.0 0.0)
        failCount 0)
  (if (setq ss_all (ssget "_X" '((410 . "Model"))))
    (progn
      (setq i 0)
      (repeat (sslength ss_all)
        (if (vl-catch-all-error-p
              (vl-catch-all-apply 'vla-Rotate3D
                                  (list (vlax-ename->vla-object (ssname ss_all i))
                                        (vlax-3d-point pt0)
                                        (vlax-3d-point pt1)
                                        (/ pi 2.0))))
          (setq failCount (1+ failCount))
        )
        (setq i (1+ i))
      )
      (vlax-ldata-put "MyModel" "Rotated" T)
      (princ "\n>>> Rotation done.")
      (if (> failCount 0)
        (princ (strcat "\n[Warn] " (itoa failCount) " object(s) failed to rotate, please check."))
      )
    )
  )

  ;; 2. 由参考段生成整根檩条：自原始榀沿坡向 +Y 伸出 dist1、向 -Y 伸出 dist2
  (if (and (> purlin_len 0) (setq ss_pur (ssget "_X" '((410 . "Model") (8 . "01Purlin-01,01Purlin-02")))))
    (progn
      (princ "\n[Step 2] Building full-length purlins from reference segments...")
      (setq mSpace (vla-get-ModelSpace acadDoc))
      (setq i 0)
      (repeat (sslength ss_pur)
        (setq en (ssname ss_pur i))
        (setq obj (vlax-ename->vla-object en))
        (setq p1 (vlax-curve-getStartPoint obj)
              p2 (vlax-curve-getEndPoint obj)
              curLayer (vla-get-Layer obj))
        (if (<= (last p1) (last p2)) (setq base_pt p1) (setq base_pt p2))
        (setq newObj (vla-AddLine mSpace
                        (vlax-3d-point (list (car base_pt) (+ (cadr base_pt) (* dist1 ew_c)) (+ (caddr base_pt) (* dist1 ew_s))))
                        (vlax-3d-point (list (car base_pt) (- (cadr base_pt) (* dist2 ew_c)) (- (caddr base_pt) (* dist2 ew_s))))))
        (vla-put-Layer newObj curLayer)
        (vla-delete obj)
        (setq i (1+ i))
      )
      (princ "\n>>> Purlins done.")
    )
  )

  ;; 3. 按实际跨距（端跨 zde / 中间跨 zd）逐榀复制支架；沿坡距离 off：水平 off*cos、竖向 off*sin
  (if frame_offs
    (progn
      (princ "\n[Step 3] Placing frames...")
      (setq ss (ssget "_X" '((410 . "Model") (8 . "02Beam,03Brace,04Column"))))
      (if ss
        (progn
          (foreach off frame_offs
            (setq moveVec (vlax-3d-point (list 0.0 (* off ew_c -1.0) (* off ew_s -1.0))))
            (setq j 0)
            (repeat (sslength ss)
              (setq obj (vlax-ename->vla-object (ssname ss j)))
              (setq newObj (vla-copy obj))
              (vla-move newObj (vlax-3d-point '(0 0 0)) moveVec)
              (setq j (1+ j))
            )
          )
          (princ (strcat "\n>>> Frames done: " (itoa (length frame_offs)) " copies created."))
        )
        (princ "\n[Warn] No objects on 02Beam / 03Brace / 04Column; frames not copied.")
      )
    )
  )

  (princ "\n[Step 4] Exporting DXF model...")
  (setq dwg_full (getvar "DWGNAME"))
  (setq dwg_path (getvar "DWGPREFIX"))
  (setq dxf_name (vl-filename-base dwg_full))
  (setq dxf_path (strcat dwg_path dxf_name ".dxf"))

  (_delete-extra-layers acadDoc)
  (princ "\n[Step 4] Purging...")
  (command-s "_.-PURGE" "_A" "*" "_N")

  (vla-EndUndoMark acadDoc)
  (if (and (findfile dxf_path)
           (/= (strcase dxf_path) (strcase (strcat dwg_path dwg_full)))
           (not (vl-file-delete dxf_path)))
    (princ (strcat "\n[MyModel ERR] Cannot overwrite " dxf_path " (file may be in use); DXF not exported."))
    (progn
      ;; 当前文件本身就是该 DXF 时，SAVEAS 会询问是否替换
      (if (= (strcase dxf_path) (strcase (strcat dwg_path dwg_full)))
        (command-s "_.SAVEAS" "DXF" "16" dxf_path "_Y")
        (command-s "_.SAVEAS" "DXF" "16" dxf_path)
      )
      (princ (strcat "\n>>> Saved: " dxf_path))
    )
  )

  (setvar "OSMODE" old_osmode)
  (setvar "CMDECHO" old_cmdecho)
  (princ "\n[MyModel] All done!")
  (princ)
)

;; 对话框控件启用状态：
;;   平面图：禁用仅立面使用的参数（Type / Clearance / Beam H / Purlin H / 立柱尺寸）
;;   立面图：按类型启用立柱参数（0 C-post-double / 1 O-post / 2 C-post-single）
;;   MyModel：仅开放 w / m / zn / zd / zde / 东西向坡度（及 Import Excel）
(defun PVRectSgs_DlgModes ( / model plan typ)
  (setq model (= (get_tile "view_mode") "rb_model")
        plan  (/= (get_tile "view_mode") "rb_elev")
        typ   (get_tile "val_elevation"))
  (foreach k '("val_h" "val_n" "val_hole" "val_nop" "val_angle")
    (mode_tile k (if model 1 0))
  )
  (foreach k '("val_elevation" "val_clearance" "val_beam_h" "val_purlin_H")
    (mode_tile k (if plan 1 0))
  )
  (mode_tile "val_post_w" (if (and (not plan) (or (= typ "0") (= typ "2"))) 0 1))
  (mode_tile "val_post_d" (if (and (not plan) (= typ "1")) 0 1))
  (mode_tile "val_ew_slope" (if model 0 1))
)

;; =============================================================================
;; 4. Main Entry Command
;; =============================================================================

(defun c:PVRect_Singsun ( / dcl_id dcl_file f h_str w_str n_str m_str hole_str zn_str zd_str zde_str clearance_str angle_str nop_str elev_str view_str ew_slope_str ew_slope mm_len mm_offs mm_dist1 post_w_str post_d_str beam_h_str purlin_H_str dialog_done elev_type post_w post_d beam_h purlin_H w h n m hole zn zd zde clearance angle_val nop pt res ri ci vi ptbase axis_mid axis_y1 axis_y2 startX endX array_width center_x vert_axes_width start_vx top_y bottom_y cur_vx SF h_eval w_eval hole_eval zd_eval zde_eval gap extX axis_gap purlin_half_h beam_half_w beam_shrink dim_y dim_y2 old_osmode px1 px2 px3 old_layer old_dimstyle bottom_axis_ent click_x click_y cmd_str vert_y_list dim_x_vert dim_x2_vert y_a y_b i y_pv_bot y_pv_top cur_y_pv_bot cur_y_pv_top next_y_pv_bot vx_list brace_start_x brace_start_y brace_end_x brace_end_y brace_dx brace_dy brace_len brace_ext brace_ux brace_uy mirror_axis_x upper_only_list actual_len dim_dx dim_dy dim_loc_x dim_loc_y dim_nx dim_ny dim_p1_x dim_p1_y dim_p2_x dim_p2_y new_brace_dx new_brace_dy new_brace_end_x new_brace_end_y new_brace_ext new_brace_len new_brace_start_x new_brace_start_y new_brace_ux new_brace_uy new_mirror_axis_x ptbase_x ptbase_y right2_axis_x right_axis_x *error*)
  (defun *error* (msg) (PVRectSgs_OnError msg))
  (setq *sg_old_osmode_global* nil *sg_old_layer_global* nil *sg_pvrect_layers_off* nil)
  (setq h_str "2382" w_str "1134" n_str "2" m_str "12" hole_str "1400" zn_str "3" zd_str "3800" zde_str "3800" clearance_str "400" angle_str "20" nop_str "2" elev_str "0" view_str "plan" ew_slope_str "0" post_w_str "80" post_d_str "60" beam_h_str "100" purlin_H_str "80" dialog_done nil)
  
  (while (not dialog_done)
    (setq dcl_file (vl-filename-mktemp "pvrect_sg.dcl") f (open dcl_file "w"))
    (write-line "pvrect_dlg : dialog {" f)
    (write-line "  label = \"PV Array Generator (Singsun)\";" f)
    (write-line "  : radio_row { key = \"view_mode\"; label = \"Output\";" f)
    (write-line "    : radio_button { label = \"Plan view\"; key = \"rb_plan\"; }" f)
    (write-line "    : radio_button { label = \"Elevation view\"; key = \"rb_elev\"; }" f)
    (write-line "    : radio_button { label = \"MyModel\"; key = \"rb_model\"; }" f)
    (write-line "  }" f)
    (write-line "  : row {" f)
    (write-line "    : button { label = \"Import Excel\"; key = \"btn_import\"; width = 15; fixed_width = true; }" f)
    (write-line "    : spacer { width = 1; }" f)
    (write-line "  }" f)
    (write-line "  : boxed_column { label = \"Module Parameters\";" f)
    (write-line "    : row { : edit_box { label = \"Height (h):\"; key = \"val_h\"; edit_width = 10; } : spacer { width = 15; } }" f)
    (write-line "    : row { : edit_box { label = \"Width (w):\"; key = \"val_w\"; edit_width = 10; } : spacer { width = 15; } }" f)
    (write-line "    : row { : edit_box { label = \"Rows (n):\"; key = \"val_n\"; edit_width = 10; } : spacer { width = 15; } }" f)
    (write-line "    : row { : edit_box { label = \"Cols (m):\"; key = \"val_m\"; edit_width = 10; } : spacer { width = 15; } }" f)
    (write-line "    : row {" f)
    (write-line "      : edit_box { label = \"Hole Dist.:\"; key = \"val_hole\"; edit_width = 10; }" f)
    (write-line "      : popup_list { label = \"Purlin per PV:\"; key = \"val_nop\"; edit_width = 10; }" f)
    (write-line "    }" f)
    (write-line "    : row {" f)
    (write-line "      : edit_box { label = \"Clearance:\"; key = \"val_clearance\"; edit_width = 10; }" f)
    (write-line "      : edit_box { label = \"Angle:\"; key = \"val_angle\"; edit_width = 10; }" f)
    (write-line "    }" f)
    (write-line "  }" f)
    (write-line "  : boxed_column { label = \"Support Parameters\";" f)
    (write-line "    : row { : edit_box { label = \"Supports (zn):\"; key = \"val_zn\"; edit_width = 10; } : spacer { width = 15; } }" f)
    (write-line "    : row {" f)
    (write-line "      : edit_box { label = \"Spacing (zd):\"; key = \"val_zd\"; edit_width = 10; }" f)
    (write-line "      : edit_box { label = \"S-edge (zd-e):\"; key = \"val_zde\"; edit_width = 10; }" f)
    (write-line "    }" f)
    (write-line "    : row { : edit_box { label = \"E-W Slope (deg):\"; key = \"val_ew_slope\"; edit_width = 10; } : spacer { width = 15; } }" f)
    (write-line "  }" f)
    (write-line "  : boxed_column { label = \"Elevation\";" f)
    (write-line "    : row { : popup_list { label = \"Type:\"; key = \"val_elevation\"; edit_width = 12; } : spacer { width = 5; } }" f)
    (write-line "    : row { : edit_box { label = \"Post Width W (mm):\"; key = \"val_post_w\"; edit_width = 8; } : spacer { width = 10; } }" f)
    (write-line "    : row { : edit_box { label = \"Post Diam D (mm):\"; key = \"val_post_d\"; edit_width = 8; } : spacer { width = 10; } }" f)
    (write-line "    : row { : edit_box { label = \"Beam H (mm):\"; key = \"val_beam_h\"; edit_width = 8; } : spacer { width = 10; } }" f)
    (write-line "    : row { : edit_box { label = \"Purlin H (mm):\"; key = \"val_purlin_H\"; edit_width = 8; } : spacer { width = 10; } }" f)
    (write-line "  }" f)
    (write-line "  : spacer { height = 1; }" f)
    (write-line "  ok_cancel;" f)
    (write-line "}" f)
    (close f)
    
    (setq dcl_id (load_dialog dcl_file))
    (if (not (new_dialog "pvrect_dlg" dcl_id)) (progn (princ "\nError loading DCL.") (exit)))
    
    (start_list "val_nop")
    (add_list "2")
    (add_list "3")
    (end_list)
    
    (set_tile "val_h" h_str) (set_tile "val_w" w_str) (set_tile "val_n" n_str) (set_tile "val_m" m_str) (set_tile "val_hole" hole_str) (set_tile "val_zn" zn_str) (set_tile "val_zd" zd_str) (set_tile "val_zde" zde_str) (set_tile "val_ew_slope" ew_slope_str)
    (set_tile "val_clearance" clearance_str) (set_tile "val_angle" angle_str) (set_tile "val_nop" (if (= nop_str "3") "1" "0"))
    (start_list "val_elevation")
    ;; 类型：0 C-post-double / 1 O-post / 2 C-post-single（仅立面图使用）
    (add_list "C-post-double") (add_list "O-post") (add_list "C-post-single")
    (end_list)
    (set_tile "val_elevation" elev_str)
    (set_tile "view_mode" (cond ((= view_str "elev") "rb_elev") ((= view_str "model") "rb_model") (T "rb_plan")))
    (set_tile "val_post_w" post_w_str)
    (set_tile "val_post_d" post_d_str)
    (set_tile "val_purlin_H" purlin_H_str)
    (set_tile "val_beam_h" beam_h_str)
    (PVRectSgs_DlgModes)

    (action_tile "val_elevation" "(PVRectSgs_DlgModes)")
    (action_tile "view_mode" "(PVRectSgs_DlgModes)")
    (action_tile "accept" "(setq h_str (get_tile \"val_h\") w_str (get_tile \"val_w\") n_str (get_tile \"val_n\") m_str (get_tile \"val_m\") hole_str (get_tile \"val_hole\") zn_str (get_tile \"val_zn\") zd_str (get_tile \"val_zd\") zde_str (get_tile \"val_zde\") ew_slope_str (get_tile \"val_ew_slope\") view_str (cond ((= (get_tile \"view_mode\") \"rb_elev\") \"elev\") ((= (get_tile \"view_mode\") \"rb_model\") \"model\") (T \"plan\")) clearance_str (get_tile \"val_clearance\") angle_str (get_tile \"val_angle\") nop_str (if (= (get_tile \"val_nop\") \"1\") \"3\" \"2\") elev_str (get_tile \"val_elevation\") post_w_str (get_tile \"val_post_w\") post_d_str (get_tile \"val_post_d\") beam_h_str (get_tile \"val_beam_h\") purlin_H_str (get_tile \"val_purlin_H\")) (done_dialog 1)")
    (action_tile "cancel" "(done_dialog 0)")
    (action_tile "btn_import" "(PVRectSgs_ImportExcel)")
    
    (setq res (start_dialog))
    (unload_dialog dcl_id)
    (vl-file-delete dcl_file)
    (setq dialog_done T)
  )

  (if (and (= res 1) (= view_str "model"))
    (progn
      (setq ew_slope (distof ew_slope_str 2) w (distof w_str 2) m (atoi m_str) zn (atoi zn_str)
            zd (distof zd_str 2) zde (distof zde_str 2))
      (cond
        ((not (and ew_slope (< (abs ew_slope) 90.0)))
         (princ "\n>>> Invalid E-W slope (must be a number between -90 and 90 deg)."))
        ((not (and w (> w 0) (> m 0) (> zn 0)))
         (princ "\n>>> Invalid input: Width (w), Cols (m) and Supports (zn) must be > 0."))
        ((and (>= zn 2) (not (and zde (> zde 0))))
         (princ "\n>>> Invalid input: S-edge (zd-e) must be > 0."))
        ((and (>= zn 4) (not (and zd (> zd 0))))
         (princ "\n>>> Invalid input: Spacing (zd) must be > 0."))
        (T
         ;; 与平面图一致：檩条长 = m*w + (m-1)*20 缝 + 两端各 75；支架轴线居中
         (setq mm_len  (+ (* m w) (* (1- m) 20.0) (* 2.0 75.0))
               mm_offs (PVRectSgs_FrameOffsets zn zd zde)
               mm_dist1 (/ (- mm_len (if mm_offs (last mm_offs) 0.0)) 2.0))
         (PVRectSgs_MyModel ew_slope mm_len mm_dist1 mm_offs))
      )
      (setq res 0)
    )
  )
  (if (= res 1)
    (progn
      (setq h (atof h_str) w (atof w_str) n (atoi n_str) m (atoi m_str) hole (atof hole_str) zn (atoi zn_str) zd (atof zd_str) zde (atof zde_str) clearance (atof clearance_str) angle_val (atof angle_str) nop (atoi nop_str) elev_type (if (= view_str "elev") (1+ (atoi elev_str)) 0) post_w (atof post_w_str) post_d (atof post_d_str) beam_h (max 50.0 (if (> (atof beam_h_str) 0) (atof beam_h_str) 100.0)) purlin_H (max 60.0 (if (> (atof purlin_H_str) 0) (atof purlin_H_str) 80.0)))
      (if (and (> h 0) (> w 0) (> n 0) (> m 0) (> hole 0))
        (progn
          (setq pt (getpoint "\nSelect insertion point: "))
          (if pt
            (progn
              (setq *sg_first_ent_global* (entlast))
              (command "_.-LAYER" "_UNLOCK" "purlin,beam" "")
              
              (if (not (tblsearch "LAYER" "AXIS")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "AXIS") (70 . 0) (62 . 1))))
              (if (not (tblsearch "LAYER" "purlin")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "purlin") (70 . 0) (62 . 3))))
              (if (not (tblsearch "LAYER" "beam")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "beam") (70 . 0) (62 . 4))))
              (if (not (tblsearch "LAYER" "PV")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "PV") (70 . 0) (62 . 7))))
              (if (not (tblsearch "LAYER" "STPM_SBEAM_THICK")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "STPM_SBEAM_THICK") (70 . 0) (62 . 7))))
              
              (setq SF 2.0 h_eval (* h SF) w_eval (* w SF) hole_eval (* hole SF) zd_eval (* zd SF) zde_eval (* zde SF) gap (* 20.0 SF) extX (* 75.0 SF) axis_gap (/ hole_eval 2.0) purlin_half_h 50.0 beam_half_w (* 25.0 SF) beam_shrink (* 350.0 SF))
              
              (setq old_layer (getvar "CLAYER") old_osmode (getvar "OSMODE"))
              ;; 立即登记，出错/取消时由 PVRectSgs_RestoreEnv 恢复
              (setq *sg_old_osmode_global* old_osmode *sg_old_layer_global* old_layer)
              (setvar "OSMODE" 0)
              
              (if (> zn 0)
                (progn
                  (setq vx_list (list))
                  (setq array_width (+ (* m w_eval) (* (1- m) gap)) center_x (+ (car pt) (/ array_width 2.0)))
                  (cond 
                    ((= zn 1) (setq vert_axes_width 0.0))
                    ((= zn 2) (setq vert_axes_width zde_eval))
                    (t (setq vert_axes_width (+ (* 2.0 zde_eval) (* (- zn 3) zd_eval))))
                  )
                  (setq start_vx (- center_x (/ vert_axes_width 2.0)) top_y (+ (cadr pt) (* n h_eval) (* (1- n) gap)) bottom_y (cadr pt))
                  (setq vi 0 cur_vx start_vx)
                  (while (< vi zn)
                    (setq vx_list (append vx_list (list cur_vx)))
                    (entmake (list '(0 . "LINE") '(8 . "AXIS") (cons 10 (list cur_vx bottom_y 0.0)) (cons 11 (list cur_vx top_y 0.0))))
                    (setvar "CLAYER" "beam")
                    (command "_.RECTANG" "_NON" (list (- cur_vx beam_half_w) (- top_y beam_shrink) 0.0) "_NON" (list (+ cur_vx beam_half_w) (+ bottom_y beam_shrink) 0.0))
                    (if (< vi (1- zn))
                      (if (or (= vi 0) (= vi (- zn 2))) (setq cur_vx (+ cur_vx zde_eval)) (setq cur_vx (+ cur_vx zd_eval)))
                    )
                    (setq vi (1+ vi))
                  )
                )
              )
              
              (setq ri 0 bottom_axis_ent nil)
              (while (< ri n)
                (setq axis_mid (+ (cadr pt) (* ri (+ h_eval gap)) (/ h_eval 2.0)) startX (- (car pt) extX) endX (+ (car pt) (* (1- m) (+ w_eval gap)) w_eval extX))
                (setq axis_y1 (+ axis_mid axis_gap))
                (entmake (list '(0 . "LINE") '(8 . "AXIS") (cons 10 (list startX axis_y1 0.0)) (cons 11 (list endX axis_y1 0.0))))
                (setvar "CLAYER" "purlin")
                (command "_.RECTANG" "_NON" (list startX (- axis_y1 purlin_half_h) 0.0) "_NON" (list endX (+ axis_y1 purlin_half_h) 0.0))
                
                (if (= nop 3)
                  (progn
                    (entmake (list '(0 . "LINE") '(8 . "AXIS") (cons 10 (list startX axis_mid 0.0)) (cons 11 (list endX axis_mid 0.0))))
                    (setvar "CLAYER" "purlin")
                    (command "_.RECTANG" "_NON" (list startX (- axis_mid purlin_half_h) 0.0) "_NON" (list endX (+ axis_mid purlin_half_h) 0.0))
                  )
                )
                
                (setq axis_y2 (- axis_mid axis_gap))
                (entmake (list '(0 . "LINE") '(8 . "AXIS") (cons 10 (list startX axis_y2 0.0)) (cons 11 (list endX axis_y2 0.0))))
                
                ;; Reverting to stable click point: 100 units from the first vertical axis
                (if (and (= ri 0) vx_list) (progn (setq bottom_axis_ent (entlast) click_x (+ (car vx_list) 100.0) click_y axis_y2)))
                (setvar "CLAYER" "purlin")
                (command "_.RECTANG" "_NON" (list startX (- axis_y2 purlin_half_h) 0.0) "_NON" (list endX (+ axis_y2 purlin_half_h) 0.0))
                
                (setq ci 0)
                (while (< ci m)
                  (setq ptbase_X (+ (car pt) (* ci (+ w_eval gap))) ptbase_Y (+ (cadr pt) (* ri (+ h_eval gap))))
                  (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "PV") '(90 . 4) '(70 . 1) (list 10 ptbase_X ptbase_Y) (list 10 (+ ptbase_X w_eval) ptbase_Y) (list 10 (+ ptbase_X w_eval) (+ ptbase_Y h_eval)) (list 10 ptbase_X (+ ptbase_Y h_eval))))
                  (setq ci (1+ ci))
                )
                (setq ri (1+ ri))
              )
              
              (if (not (tblsearch "LAYER" "DIM")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "DIM") (70 . 0) (62 . 7))))
              (setvar "CLAYER" "DIM")
              (setq old_dimstyle (getvar "DIMSTYLE"))
              (if (tblsearch "DIMSTYLE" "TSSD_50_100") (command "-DIMSTYLE" "R" "TSSD_50_100") (princ "\n>>> [Info] Dimstyle TSSD_50_100 not found."))
              
              (setq *sg_top_dims_global* nil dim_y (+ top_y (* 600.0 SF)))
              (command "_.DIMLINEAR" "_NON" (list startX top_y 0.0) "_NON" (list (car pt) top_y 0.0) "_NON" (list startX dim_y 0.0))
              (setq *sg_top_dims_global* (append *sg_top_dims_global* (list (entlast))))
              (setq ci 0)
              (while (< ci m)
                (setq px1 (+ (car pt) (* ci (+ w_eval gap))) px2 (+ px1 w_eval))
                (command "_.DIMLINEAR" "_NON" (list px1 top_y 0.0) "_NON" (list px2 top_y 0.0) "_NON" (list px1 dim_y 0.0))
                (setq *sg_top_dims_global* (append *sg_top_dims_global* (list (entlast))))
                (if (< ci (1- m)) (progn (setq px3 (+ px2 gap)) (command "_.DIMLINEAR" "_NON" (list px2 top_y 0.0) "_NON" (list px3 top_y 0.0) "_NON" (list px2 dim_y 0.0)) (setq *sg_top_dims_global* (append *sg_top_dims_global* (list (entlast))))))
                (setq ci (1+ ci))
              )
              (command "_.DIMLINEAR" "_NON" (list px2 top_y 0.0) "_NON" (list endX top_y 0.0) "_NON" (list px2 dim_y 0.0))
              (setq *sg_top_dims_global* (append *sg_top_dims_global* (list (entlast))))
              (setq dim_y2 (+ dim_y (* 600.0 SF)))
              (command "_.DIMLINEAR" "_NON" (list startX top_y 0.0) "_NON" (list endX top_y 0.0) "_NON" (list startX dim_y2 0.0))
              (setq *sg_top_dims_global* (append *sg_top_dims_global* (list (entlast))))
              
              (setq vert_y_list nil *sg_global_axis_y_list* nil ri 0)
              (while (< ri n)
                (setq y_pv_bot (+ (cadr pt) (* ri (+ h_eval gap))) y_pv_top (+ y_pv_bot h_eval) axis_mid (+ y_pv_bot (/ h_eval 2.0)) axis_y1 (+ axis_mid axis_gap) axis_y2 (- axis_mid axis_gap))
                (if (= nop 3)
                  (progn
                    (setq vert_y_list (append vert_y_list (list y_pv_bot axis_y2 axis_mid axis_y1 y_pv_top)) *sg_global_axis_y_list* (append *sg_global_axis_y_list* (list axis_y2 axis_mid axis_y1)))
                  )
                  (progn
                    (setq vert_y_list (append vert_y_list (list y_pv_bot axis_y2 axis_y1 y_pv_top)) *sg_global_axis_y_list* (append *sg_global_axis_y_list* (list axis_y2 axis_y1)))
                  )
                )
                (setq ri (1+ ri))
              )
              (setq *sg_upper_only_ents* nil)
              (if (and vx_list *sg_global_axis_y_list*)
                (progn
                  (setq brace_start_x (car vx_list)
                        brace_start_y (- (apply 'max *sg_global_axis_y_list*) 200.0)
                        brace_end_x (if (> (length vx_list) 1) (cadr vx_list) (car vx_list))
                        brace_end_y (+ (apply 'min *sg_global_axis_y_list*) 200.0)
                        brace_dx (- brace_end_x brace_start_x)
                        brace_dy (- brace_end_y brace_start_y)
                        brace_len (distance (list brace_start_x brace_start_y 0.0) (list brace_end_x brace_end_y 0.0))
                        upper_only_list nil)
                  (if (> brace_len 1e-8)
                    (progn
                      (setq brace_ext 200.0
                            brace_ux (/ brace_dx brace_len)
                            brace_uy (/ brace_dy brace_len)
                            brace_start_x (- brace_start_x (* brace_ext brace_ux))
                            brace_start_y (- brace_start_y (* brace_ext brace_uy))
                            brace_end_x (+ brace_end_x (* brace_ext brace_ux))
                            brace_end_y (+ brace_end_y (* brace_ext brace_uy)))
                      (entmake
                        (list
                          '(0 . "LWPOLYLINE")
                          '(100 . "AcDbEntity")
                          '(8 . "STPM_SBEAM_THICK")
                          '(100 . "AcDbPolyline")
                          '(90 . 2)
                          '(70 . 0)
                          (list 10 brace_start_x brace_start_y)
                          (list 10 brace_end_x brace_end_y)
                        )
                      )
                      (setq upper_only_list (list (entlast)))
                      (if (> (length vx_list) 1)
                        (progn
                          (setq mirror_axis_x (/ (+ (car vx_list) (cadr vx_list)) 2.0))
                          (entmake
                            (list
                              '(0 . "LWPOLYLINE")
                              '(100 . "AcDbEntity")
                              '(8 . "STPM_SBEAM_THICK")
                              '(100 . "AcDbPolyline")
                              '(90 . 2)
                              '(70 . 0)
                              (list 10 (- (* 2.0 mirror_axis_x) brace_start_x) brace_start_y)
                              (list 10 (- (* 2.0 mirror_axis_x) brace_end_x) brace_end_y)
                            )
                          )
                          (setq upper_only_list (append upper_only_list (list (entlast))))
                        )
                      )
                      ;; 新增：在上方图形右侧增加多段线（仅保留在上方）
                      (if (>= (length vx_list) 2)
                        (progn
                          (setq right_axis_x (last vx_list)
                                right2_axis_x (nth (- (length vx_list) 2) vx_list)
                                new_brace_start_x right_axis_x
                                new_brace_start_y (- (apply 'max *sg_global_axis_y_list*) 200.0)
                                new_brace_end_x right2_axis_x
                                new_brace_end_y (+ (apply 'min *sg_global_axis_y_list*) 200.0)
                                new_brace_dx (- new_brace_end_x new_brace_start_x)
                                new_brace_dy (- new_brace_end_y new_brace_start_y)
                                new_brace_len (distance (list new_brace_start_x new_brace_start_y 0.0) (list new_brace_end_x new_brace_end_y 0.0)))
                          (if (> new_brace_len 1e-8)
                            (progn
                              (setq new_brace_ext 200.0
                                    new_brace_ux (/ new_brace_dx new_brace_len)
                                    new_brace_uy (/ new_brace_dy new_brace_len)
                                    new_brace_start_x (- new_brace_start_x (* new_brace_ext new_brace_ux))
                                    new_brace_start_y (- new_brace_start_y (* new_brace_ext new_brace_uy))
                                    new_brace_end_x (+ new_brace_end_x (* new_brace_ext new_brace_ux))
                                    new_brace_end_y (+ new_brace_end_y (* new_brace_ext new_brace_uy)))
                              (entmake
                                (list
                                  '(0 . "LWPOLYLINE")
                                  '(100 . "AcDbEntity")
                                  '(8 . "STPM_SBEAM_THICK")
                                  '(100 . "AcDbPolyline")
                                  '(90 . 2)
                                  '(70 . 0)
                                  (list 10 new_brace_start_x new_brace_start_y)
                                  (list 10 new_brace_end_x new_brace_end_y)
                                )
                              )
                              (setq upper_only_list (append upper_only_list (list (entlast))))
                              
                              ;; 镜像
                              (setq new_mirror_axis_x (/ (+ right_axis_x right2_axis_x) 2.0))
                              (setq dim_p1_x (- (* 2.0 new_mirror_axis_x) new_brace_start_x)
                                    dim_p1_y new_brace_start_y
                                    dim_p2_x (- (* 2.0 new_mirror_axis_x) new_brace_end_x)
                                    dim_p2_y new_brace_end_y)
                              (entmake
                                (list
                                  '(0 . "LWPOLYLINE")
                                  '(100 . "AcDbEntity")
                                  '(8 . "STPM_SBEAM_THICK")
                                  '(100 . "AcDbPolyline")
                                  '(90 . 2)
                                  '(70 . 0)
                                  (list 10 dim_p1_x dim_p1_y)
                                  (list 10 dim_p2_x dim_p2_y)
                                )
                              )
                              (setq upper_only_list (append upper_only_list (list (entlast))))
                              
                              ;; 为镜像后的斜线添加标注 (DIMALIGNED)
                              (setq dim_dx (- dim_p2_x dim_p1_x)
                                    dim_dy (- dim_p2_y dim_p1_y)
                                    actual_len (distance (list dim_p1_x dim_p1_y 0.0) (list dim_p2_x dim_p2_y 0.0))
                                    dim_nx (/ (- dim_dy) actual_len)
                                    dim_ny (/ dim_dx actual_len)
                                    dim_loc_x (+ (/ (+ dim_p1_x dim_p2_x) 2.0) (* dim_nx (* 400.0 SF)))
                                    dim_loc_y (+ (/ (+ dim_p1_y dim_p2_y) 2.0) (* dim_ny (* 400.0 SF))))
                              (command "_.DIMALIGNED"
                                       "_NON" (list dim_p1_x dim_p1_y 0.0)
                                       "_NON" (list dim_p2_x dim_p2_y 0.0)
                                       "_NON" (list dim_loc_x dim_loc_y 0.0))
                              (setq upper_only_list (append upper_only_list (list (entlast))))
                            )
                          )
                        )
                      )
                      (setq *sg_upper_only_ents* upper_only_list)
                    )
                  )
                )
              )
              
              (setq dim_x_vert (- startX (* 300.0 SF)) *sg_left_dims_global* nil i 0)
              (while (< i (1- (length vert_y_list)))
                (setq y_a (nth i vert_y_list) y_b (nth (1+ i) vert_y_list))
                (command "_.DIMLINEAR" "_NON" (list startX y_a 0.0) "_NON" (list startX y_b 0.0) "_NON" (list dim_x_vert y_a 0.0))
                (setq *sg_left_dims_global* (append *sg_left_dims_global* (list (entlast))))
                (setq i (1+ i))
              )
              (setq dim_x2_vert (- dim_x_vert (* 600.0 SF)) ri 0)
              (while (< ri n)
                (setq cur_y_pv_bot (+ (cadr pt) (* ri (+ h_eval gap))) cur_y_pv_top (+ cur_y_pv_bot h_eval))
                (command "_.DIMLINEAR" "_NON" (list startX cur_y_pv_bot 0.0) "_NON" (list startX cur_y_pv_top 0.0) "_NON" (list dim_x2_vert cur_y_pv_bot 0.0))
                (setq *sg_left_dims_global* (append *sg_left_dims_global* (list (entlast))))
                (if (< ri (1- n)) (progn (setq next_y_pv_bot (+ cur_y_pv_top gap)) (command "_.DIMLINEAR" "_NON" (list startX cur_y_pv_top 0.0) "_NON" (list startX next_y_pv_bot 0.0) "_NON" (list dim_x2_vert cur_y_pv_top 0.0)) (setq *sg_left_dims_global* (append *sg_left_dims_global* (list (entlast))))))
                (setq ri (1+ ri))
              )
              
              (if bottom_axis_ent
                (progn
                  (princ "\n>>> Post-processing...")
                  (setvar "CLAYER" "AXIS") 
                  ;; Turn OFF everything that could interfere with selection (especially PV)
                  (command "_.-LAYER" "_OFF" "purlin,beam,PV,DIM" "")
                  (setq *sg_pvrect_layers_off* T)
                  (setq *sg_last_ent_before_macro* (entlast) *sg_global_n* n *sg_global_m* m *sg_global_zn* zn *sg_global_center_x* center_x *sg_global_axis_y2_baseline* axis_y2 *sg_global_h* h *sg_global_hole* hole *sg_global_sf* SF *sg_global_startX* startX *sg_global_endX* endX *sg_global_dim_x_vert* dim_x_vert *sg_global_pt_x* (car pt) *sg_global_w_eval* w_eval *sg_global_gap* gap *sg_global_start_vx* start_vx *sg_global_zd_eval* zd_eval *sg_global_dim_y* dim_y *sg_global_dim_y2* dim_y2 *sg_global_top_y* top_y *sg_global_vx_list* vx_list *sg_global_bottom_y* bottom_y *sg_global_bottom_dim_y* (- bottom_y (* 600.0 SF)) *sg_global_clearance* clearance *sg_global_angle* angle_val *sg_global_nop* nop *sg_global_elev_type* elev_type *sg_global_post_w* post_w *sg_global_post_d* post_d *sg_global_beam_h* beam_h *sg_global_purlin_H* purlin_H *sg_global_new_line_x1* nil *sg_scale_center_x* nil *sg_scale_center_y* nil *sg_old_osmode_global* old_osmode *sg_old_layer_global* old_layer)
                  (command "_.ZOOM" "_E")
                  (setq cmd_str "ZHWBZH_Singsun\n")
                  (vla-SendCommand (vla-get-ActiveDocument (vlax-get-acad-object)) cmd_str)
                )
                ;; 无竖向轴线（zn=0）时不进入后处理，这里直接恢复 OSMODE / 图层
                (PVRectSgs_RestoreEnv)
              )
              (princ (strcat "\n>>> Array generated!"))
            )
          )
        )
        (princ "\n>>> Invalid input.")
      )
    )
  )
  (princ)
)

(princ "\n=============================================")
(princ "\n= PVRect_Singsun Loaded                   =")
(princ "\n= Command: PVRect_Singsun                =")
(princ "\n=============================================")
(princ)
