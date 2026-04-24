(vl-load-com)

;; =============================================================================
;; 1. Excel Data Import & Logic (Eurocode / ASCE detection)
;; =============================================================================

(defun PVRect_CellValueToString (val as_int / num)
  (cond
    ((or (null val) (= val :vlax-null)) "")
    ((numberp val)
     (if as_int (itoa (fix (+ val 0.5))) (rtos val 2 4))
    )
    ((= (type val) 'variant) (PVRect_CellValueToString (vlax-variant-value val) as_int))
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

(defun PVRect_GetCellValueByAddr (sheet addr / range val)
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

(defun PVRect_SnapDown (val step / snapped)
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
(defun PVRect_GetProjectionDist (pt axis_start axis_end / axis_vec axis_len axis_dir pt_vec proj_dist)
  (setq axis_vec (list (- (car axis_end) (car axis_start)) (- (cadr axis_end) (cadr axis_start)))
        axis_len (distance axis_start axis_end)
        axis_dir (list (/ (car axis_vec) axis_len) (/ (cadr axis_vec) axis_len))
        pt_vec (list (- (car pt) (car axis_start)) (- (cadr pt) (cadr axis_start)))
        proj_dist (+ (* (car pt_vec) (car axis_dir)) (* (cadr pt_vec) (cadr axis_dir))))
  proj_dist
)

;; 设置动态块的可见性状态
(defun PVRect_SetBlockVisibility (blk_ent visibility_state / blk_obj props prop_count i prop found prop_name prop_allowed_values)
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

(defun PVRect_FarFromPointsP (x pt_list min_dist / ok)
  (setq ok T)
  (while (and ok pt_list)
    (if (<= (abs (- x (car pt_list))) min_dist)
      (setq ok nil)
    )
    (setq pt_list (cdr pt_list))
  )
  ok
)

(defun PVRect_UniqueSorted (vals / sorted out last_v)
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

(defun PVRect_BuildPVVerticalXs (pt_x w_eval gap m / xs i x_left)
  (setq xs nil
        i 0)
  (while (< i m)
    (setq x_left (+ pt_x (* i (+ w_eval gap))))
    (setq xs (cons (+ x_left w_eval) (cons x_left xs)))
    (setq i (1+ i))
  )
  (PVRect_UniqueSorted xs)
)

(defun PVRect_BuildBreakCandidates (start_x end_x axis_list pv_x_list zd_eval sf / min_off max_off step clear_dist axis window_start window_end pos candidates)
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
        (setq pos (PVRect_SnapDown (min window_end end_x) step))
        (while (>= pos window_start)
          (if (and (> pos start_x)
                   (< pos end_x)
                   (PVRect_FarFromPointsP pos pv_x_list clear_dist))
            (setq candidates (cons pos candidates))
          )
          (setq pos (- pos step))
        )
      )
    )
  )
  (PVRect_UniqueSorted candidates)
)

(defun PVRect_FindBreakPath (current_x end_x candidates max_len / rev_candidates candidate sub result)
  (if (<= (- end_x current_x) max_len)
    nil
    (progn
      (setq rev_candidates (reverse candidates)
            result 'pvrect_fail)
      (while (and rev_candidates (= result 'pvrect_fail))
        (setq candidate (car rev_candidates)
              rev_candidates (cdr rev_candidates))
        (if (and (> candidate current_x)
                 (<= (- candidate current_x) max_len))
          (progn
            (setq sub (PVRect_FindBreakPath candidate end_x candidates max_len))
            (if (not (= sub 'pvrect_fail))
              (setq result (cons candidate sub))
            )
          )
        )
      )
      result
    )
  )
)

(defun PVRect_AddSegmentedHorizontalDim (start_x end_x axis_y dim_y axis_list pt_x w_eval gap m zd_eval sf / max_seg_len pv_x_list candidates breaks prev_x next_x)
  (setq max_seg_len (* 11500.0 sf)
        pv_x_list (PVRect_BuildPVVerticalXs pt_x w_eval gap m)
        candidates (PVRect_BuildBreakCandidates start_x end_x axis_list pv_x_list zd_eval sf)
        breaks (PVRect_FindBreakPath start_x end_x candidates max_seg_len))
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

(defun PVRect_ReadExcelDefaults ( / dwg_dir excel_files excel_path excel_app workbooks workbook sheets sheet result err i count name found is_euro header_b3 header_c3 e11_val target_name target_sheet_name app_created wb_opened val open_err_msg b7_txt c7_txt d9_txt e9_txt b13_txt c13_txt score best_score best_sheet best_name sheet_name)
  (setq dwg_dir (getvar "DWGPREFIX"))
  (cond
    ((or (null dwg_dir) (= dwg_dir ""))
     (prompt "\n>>> Please save the drawing first.")
     nil
    )
    (t
     (setq excel_files
       (append
         (vl-directory-files dwg_dir "*.xlsx" 1)
         (vl-directory-files dwg_dir "*.xlsm" 1)
         (vl-directory-files dwg_dir "*.xlsb" 1)
         (vl-directory-files dwg_dir "*.xls" 1)
       )
     )
     (if (null excel_files)
       (progn
         (prompt "\n>>> No Excel file found in the current drawing folder.")
         nil
       )
       (progn
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

                (vlax-put-property excel_app "Visible" :vlax-false)
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
                    (setq target_sheet_name (vl-list->string '(202 253 190 221 204 238 208 180)))
                    (setq sheet (vl-catch-all-apply 'vlax-get-property (list sheets "Item" target_sheet_name)))

                    (if (vl-catch-all-error-p sheet)
                      (progn
                        (setq sheet nil)
                        (setq result nil)
                        (setq open_err_msg (strcat "worksheet not found: " target_sheet_name))
                      )
                      (progn
                        (setq sheet_name target_sheet_name)
                        (setq header_b3 (vl-princ-to-string (PVRect_GetCellValueByAddr sheet "B3")))
                        (setq header_c3 (vl-princ-to-string (PVRect_GetCellValueByAddr sheet "C3")))
                        (setq e11_val (PVRect_GetCellValueByAddr sheet "E11"))
                        (setq b7_txt  (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "B7") nil))
                        (setq c7_txt  (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "C7") nil))
                        (setq d9_txt  (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "D9") T))
                        (setq e9_txt  (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "E9") T))
                        (setq b13_txt (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "B13") T))
                        (setq c13_txt (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "C13") T))

                        (setq is_euro
                          (or
                            (vl-string-search "V1.2" excel_path)
                            (vl-string-search "EN1990" header_b3)
                            (vl-string-search "EN1990" header_c3)
                            (and (distof (PVRect_CellValueToString e11_val nil) 2)
                                 (< (distof (PVRect_CellValueToString e11_val nil) 2) 100))
                            (and (numberp e11_val) (< e11_val 100))
                          )
                        )

                        (if is_euro
                          (setq result
                            (list
                              (cons "val_h"    (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "B7") nil))
                              (cons "val_w"    (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "C7") nil))
                              (cons "val_n"    (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "B13") T))
                              (cons "val_m"    (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "C13") T))
                              (cons "val_hole" "1400")
                              (cons "val_zn"   (if (numberp e11_val)
                                                 (itoa (1+ (fix (+ e11_val 0.5))))
                                                 (PVRect_CellValueToString e11_val T)))
                              (cons "val_zd"   (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "D11") nil))
                            )
                          )
                          (progn
                            (setq raw_c9 (PVRect_GetCellValueByAddr sheet "C9")
                                  num_c9 (if (numberp raw_c9) raw_c9 (distof (PVRect_CellValueToString raw_c9 nil) 2))
                                  final_c9 (if num_c9 (PVRect_CellValueToString (* num_c9 1000.0) nil) (PVRect_CellValueToString raw_c9 nil)))
                            (setq result
                              (list
                                (cons "val_h"    (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "B7") nil))
                                (cons "val_w"    (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "C7") nil))
                                (cons "val_n"    (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "D9") T))
                                (cons "val_m"    (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "E9") T))
                                (cons "val_hole" (if (= (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "D13") nil) "")
                                                   "1400"
                                                   (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "D13") nil)))
                                (cons "val_zn"   (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "D11") T))
                                (cons "val_zd"   (PVRect_CellValueToString e11_val nil))
                                (cons "val_clearance" final_c9)
                                (cons "val_angle"     (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "F9") nil))
                                (cons "val_nop"       (PVRect_CellValueToString (PVRect_GetCellValueByAddr sheet "B13") T))
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

(defun PVRect_ImportExcel ( / data item key val)
  (setq data (PVRect_ReadExcelDefaults))
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
;;
;; 生成的轴线类型说明：
;; - post-axis: 右侧图形中的两根竖向立柱轴线（U1, U2）
;; - beam-angle-axis: 沿 angle 方向的斜轴线
;; - brace-axis: 连接 post-axis 与 beam-angle-axis 的斜向连接轴线
;; =============================================================================

(defun PVRect_PostFix ( / e_cur ss idx ent err minpt maxpt pt_min global_min_y title_y t1_str e_t1 tb t1_width t1_minX t1_maxX gap_ext line_x1 line_x2 line_top_y line_bot_y t2_x ss_copy e_cur_copy edata ss_copy_sf copy_dist y_a y_b i vx_list bottom_y bottom_dim_y lower_top_axis_y lower_top_dim_y)
  (if *last_ent_before_macro*
    (progn
      (setq e_cur *last_ent_before_macro*)
      (setq ss (ssadd))
      (while (setq e_cur (entnext e_cur)) (ssadd e_cur ss))
      (if (> (sslength ss) 0)
        (progn
          (command "_.MATCHPROP" *last_ent_before_macro* ss "")
          (command "_.MOVE" ss "" "_NON" '(0.0 0.0 0.0) "_NON" '(0.0 1500.0 0.0))
          (setq global_min_y 1e99 idx 0)
          (while (< idx (sslength ss))
            (setq ent (ssname ss idx))
            (setq err (vl-catch-all-apply 'vla-getboundingbox (list (vlax-ename->vla-object ent) 'minpt 'maxpt)))
            (if (not (vl-catch-all-error-p err))
              (progn
                (setq pt_min (vlax-safearray->list minpt))
                (if (< (cadr pt_min) global_min_y) (setq global_min_y (cadr pt_min)))
              )
            )
            (setq idx (1+ idx))
          )
          (if (> global_min_y 1e98) (setq global_min_y (- *global_axis_y2_baseline* 5000.0)))
          (if (and *global_n* *global_m* *global_center_x*)
            (progn
              (if (not (tblsearch "LAYER" "NUM")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "NUM") (70 . 0) (62 . 7))))
              (if (not (tblsearch "STYLE" "TIMES")) (entmake '((0 . "STYLE") (100 . "AcDbSymbolTableRecord") (100 . "AcDbTextStyleTableRecord") (2 . "TIMES") (70 . 0) (40 . 0.0) (41 . 1.0) (3 . "times.ttf"))))
              (setq title_y (- global_min_y 1500.0))
              (setq t1_str (strcat (itoa *global_n*) "x" (itoa *global_m*) " Module layout"))
              (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES") (cons 10 (list *global_center_x* title_y 0)) (cons 40 550.0) (cons 1 t1_str) '(72 . 1) (cons 11 (list *global_center_x* title_y 0))))
              (setq e_t1 (entlast) *title_ents_list* (list e_t1))
              (setq tb (textbox (entget e_t1)) t1_width (- (caadr tb) (caar tb)) t1_minX (- *global_center_x* (/ t1_width 2.0)) t1_maxX (+ *global_center_x* (/ t1_width 2.0)))
              (setq gap_ext 300.0 line_x1 (- t1_minX gap_ext) line_x2 (+ t1_maxX gap_ext) line_top_y (- title_y 250.0) line_bot_y (- line_top_y 150.0))
              (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "NUM") '(90 . 2) (cons 43 50.0) (list 10 line_x1 line_top_y) (list 10 line_x2 line_top_y)))
              (setq *title_ents_list* (append *title_ents_list* (list (entlast))))
              (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "NUM") '(90 . 2) '(43 . 0.0)  (list 10 line_x1 line_bot_y) (list 10 line_x2 line_bot_y)))
              (setq *title_ents_list* (append *title_ents_list* (list (entlast))))
              (setq t2_x (+ line_x2 400.0))
              (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES") (cons 10 (list t2_x title_y 0)) (cons 40 400.0) (cons 1 "1:50") '(72 . 0) (cons 11 (list t2_x title_y 0))))
              (setq *title_ents_list* (append *title_ents_list* (list (entlast))))
            )
          )
        )
      )
    )
  )
  (setq *last_ent_before_macro* nil)
  (command "_.-LAYER" "_ON" "purlin,beam" "")
  (if *global_h*
    (progn
      (setq ss_copy (ssadd))
      (if *first_ent_global* (setq e_cur_copy (entnext *first_ent_global*)) (setq e_cur_copy (entnext)))
      (while e_cur_copy
        (setq edata (entget e_cur_copy))
        (if (and (not (= (strcase (cdr (assoc 8 edata))) "PV")) (not (member e_cur_copy *title_ents_list*)) (not (member e_cur_copy *left_dims_global*)) (not (member e_cur_copy *top_dims_global*)) (not (member e_cur_copy *upper_only_ents*)))
          (ssadd e_cur_copy ss_copy)
        )
        (setq e_cur_copy (entnext e_cur_copy))
      )
      (if (> (sslength ss_copy) 0)
        (progn
          (setq ss_copy_sf (if *global_sf* *global_sf* 2.0))
          (setq copy_dist (* (+ 5000.0 (* 2.0 *global_h*)) ss_copy_sf))
          (command "_.COPY" ss_copy "" "_NON" '(0.0 0.0 0.0) "_NON" (list 0.0 (- copy_dist) 0.0))
          (if (and *global_n* *global_m* *global_center_x* title_y)
            (progn
              (setq title_y (- title_y copy_dist))
              (setq t1_str (strcat (itoa *global_n*) "x" (itoa *global_m*) " PV Mount Structure Layout"))
              (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES") (cons 10 (list *global_center_x* title_y 0)) (cons 40 550.0) (cons 1 t1_str) '(72 . 1) (cons 11 (list *global_center_x* title_y 0))))
              (setq e_t1 (entlast) tb (textbox (entget e_t1)) t1_width (- (caadr tb) (caar tb)) t1_minX (- *global_center_x* (/ t1_width 2.0)) t1_maxX (+ *global_center_x* (/ t1_width 2.0)))
              (setq gap_ext 300.0 line_x1 (- t1_minX gap_ext) line_x2 (+ t1_maxX gap_ext) line_top_y (- title_y 250.0) line_bot_y (- line_top_y 150.0))
              (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "NUM") '(90 . 2) (cons 43 50.0) (list 10 line_x1 line_top_y) (list 10 line_x2 line_top_y)))
              (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "NUM") '(90 . 2) '(43 . 0.0)  (list 10 line_x1 line_bot_y) (list 10 line_x2 line_bot_y)))
              (setq t2_x (+ line_x2 400.0))
              (entmake (list '(0 . "TEXT") '(8 . "NUM") '(7 . "TIMES") (cons 10 (list t2_x title_y 0)) (cons 40 400.0) (cons 1 "1:50") '(72 . 0) (cons 11 (list t2_x title_y 0))))
            )
          )
          (if (and *global_axis_y_list* *global_startX* *global_dim_x_vert*)
            (progn
               (if (not (tblsearch "LAYER" "DIM")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "DIM") (70 . 0) (62 . 7))))
               (setvar "CLAYER" "DIM")
               (if (tblsearch "DIMSTYLE" "TSSD_50_100") (command "-DIMSTYLE" "_R" "TSSD_50_100"))
               (setq lower_top_axis_y (- (apply 'max *global_axis_y_list*) copy_dist)
                     lower_top_dim_y (+ lower_top_axis_y (* 800.0 ss_copy_sf)))
                     
               ;; 新增：在下图最上方横向 AXIS 轴线右侧端点处往右 4000 画 22000 长的水平线
               (setq new_line_x1 (+ *global_endX* 4000.0)
                     new_line_x2 (+ new_line_x1 22000.0)
                     *global_new_line_x1* new_line_x1)  ;; 保存为全局变量，用于后续判断"右侧"
               (entmake (list '(0 . "LINE") 
                              '(8 . "DIM") 
                              (cons 10 (list new_line_x1 lower_top_axis_y 0.0)) 
                              (cons 11 (list new_line_x2 lower_top_axis_y 0.0))))
                              
               ;; 新增：在此水平直线最左端点向上 clearance*5 处，沿水平方向阵列 n 个 PV 矩形及对应的支架线，并统一旋转
               (if *global_clearance*
                 (progn
                   (if (not (tblsearch "LAYER" "PV")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "PV") (70 . 0) (62 . 7))))
                   (if (not (tblsearch "LAYER" "AXIS")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "AXIS") (70 . 0) (62 . 1))))
                   (setvar "CLAYER" "PV")
                   (setq pv_start_x new_line_x1
                         pv_start_y (+ lower_top_axis_y (* *global_clearance* 5.0))
                         pi_idx 0
                         ss_pv (ssadd)
                         min_axis_x nil
                         max_axis_x nil)
                   (if (tblsearch "DIMSTYLE" "TSSD_20_100") (command "-DIMSTYLE" "_R" "TSSD_20_100"))
                   (while (< pi_idx *global_n*)
                     (setq cur_pv_x (+ pv_start_x (* pi_idx (* (+ *global_h* 20.0) 5.0)))
                           pv_p1_x cur_pv_x
                           pv_p1_y pv_start_y
                           pv_p2_x (+ cur_pv_x (* *global_h* 5.0))
                           pv_p2_y (+ pv_start_y (* 30.0 5.0)))
                     ;; 画 PV 矩形
                     (setvar "CLAYER" "PV")
                     (entmake (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline") '(8 . "PV") '(90 . 4) '(70 . 1)
                                    (list 10 pv_p1_x pv_p1_y)
                                    (list 10 pv_p2_x pv_p1_y)
                                    (list 10 pv_p2_x pv_p2_y)
                                    (list 10 pv_p1_x pv_p2_y)))
                     (ssadd (entlast) ss_pv)
                     
                     ;; 画每块 PV 对应的向下短支架线 (图形为 AXIS，根据 *global_nop* 决定 2 根还是 3 根)
                     (if (and *global_hole* *global_h*)
                       (progn
                         (if (not (tblsearch "LAYER" "AXIS")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "AXIS") (70 . 0) (62 . 1))))
                         (setq axis_x1 (+ cur_pv_x (* (/ (- *global_h* *global_hole*) 2.0) 5.0))
                               axis_x2 (+ axis_x1 (* *global_hole* 5.0)))
                         (setvar "CLAYER" "AXIS")
                         (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                        (cons 10 (list axis_x1 pv_start_y 0.0))
                                        (cons 11 (list axis_x1 (- pv_start_y 600.0) 0.0))))
                         (ssadd (entlast) ss_pv)
                         
                         (if (and *global_nop* (= *global_nop* 3))
                           (progn
                             (setq axis_x_mid (/ (+ axis_x1 axis_x2) 2.0))
                             (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                            (cons 10 (list axis_x_mid pv_start_y 0.0))
                                            (cons 11 (list axis_x_mid (- pv_start_y 600.0) 0.0))))
                             (ssadd (entlast) ss_pv)
                           )
                         )
                         
                         (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                        (cons 10 (list axis_x2 pv_start_y 0.0))
                                        (cons 11 (list axis_x2 (- pv_start_y 600.0) 0.0))))
                         (ssadd (entlast) ss_pv)
                         
                         ;; 在每个 AXIS 线段的最低点插入命名为相应的支架块 (如果存在)
                         (setq block_name (if (and *global_nop* (= *global_nop* 3)) "Purlin-Bracket-clamp" "Purlin-Bracket"))
                         (if (tblsearch "BLOCK" block_name)
                           (progn
                             (entmake (list '(0 . "INSERT") (cons 2 block_name) '(8 . "AXIS")
                                            (cons 10 (list axis_x1 (- pv_start_y 400.0) 0.0))
                                            '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                             (ssadd (entlast) ss_pv)
                             
                             (if (and *global_nop* (= *global_nop* 3))
                               (progn
                                 (entmake (list '(0 . "INSERT") (cons 2 block_name) '(8 . "AXIS")
                                                (cons 10 (list axis_x_mid (- pv_start_y 400.0) 0.0))
                                                '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                                 (ssadd (entlast) ss_pv)
                               )
                             )
                             
                             (entmake (list '(0 . "INSERT") (cons 2 block_name) '(8 . "AXIS")
                                            (cons 10 (list axis_x2 (- pv_start_y 400.0) 0.0))
                                            '(41 . 1.0) '(42 . 1.0) '(43 . 1.0) '(50 . 0.0)))
                             (ssadd (entlast) ss_pv)
                           )
                         )
                         
                         ;; 创建分段标注 (图层为 DIM，斜向上500)
                         (setvar "CLAYER" "DIM")
                         (setq dim_loc_y (+ pv_p2_y 500.0))
                         (command "_.DIMALIGNED" "_NON" (list cur_pv_x pv_p2_y 0.0) "_NON" (list axis_x1 pv_p2_y 0.0) "_NON" (list (/ (+ cur_pv_x axis_x1) 2.0) dim_loc_y 0.0))
                         (ssadd (entlast) ss_pv)
                         
                         (if (and *global_nop* (= *global_nop* 3))
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
                         (if (< pi_idx (1- *global_n*))
                           (progn
                             (setq next_pv_x (+ pv_start_x (* (1+ pi_idx) (* (+ *global_h* 20.0) 5.0))))
                             (command "_.DIMALIGNED" "_NON" (list pv_p2_x pv_p2_y 0.0) "_NON" (list next_pv_x pv_p2_y 0.0) "_NON" (list (/ (+ pv_p2_x next_pv_x) 2.0) dim_loc_y 0.0))
                             (ssadd (entlast) ss_pv)
                           )
                         )
                         
                         ;; 新增: 距离 PV 线 1200 偏移处，添加 PV 总体边长与间隙的连贯标注
                         (setq dim_loc_y2 (+ pv_p2_y 1200.0))
                         (command "_.DIMALIGNED" "_NON" (list cur_pv_x pv_p2_y 0.0) "_NON" (list pv_p2_x pv_p2_y 0.0) "_NON" (list (/ (+ cur_pv_x pv_p2_x) 2.0) dim_loc_y2 0.0))
                         (ssadd (entlast) ss_pv)
                         (if (< pi_idx (1- *global_n*))
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
                   ;; 新增：贯穿所有短支架线最低点并两端延长 600 的横向总图层线 AXIS
                   (if (and min_axis_x max_axis_x)
                     (progn
                       (setvar "CLAYER" "AXIS")
                       (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                      (cons 10 (list (- min_axis_x 600.0) (- pv_start_y 600.0) 0.0))
                                      (cons 11 (list (+ max_axis_x 600.0) (- pv_start_y 600.0) 0.0))))
                       (ssadd (entlast) ss_pv)
                     )
                   )
                   ;; 将所有生成的图形（含 PV、短支架、长轴线）统一绕总起点一起旋转
                   (if (and *global_angle* (not (= *global_angle* 0.0)) (> (sslength ss_pv) 0))
                     (command "_.ROTATE" ss_pv "" "_NON" (list pv_start_x pv_start_y 0.0) *global_angle*)
                   )
                   
                   ;; =============================================================================
                   ;; post-axis: 右侧图形中的两根竖向立柱轴线
                   ;; 动态推算两根水平距离为 100 整数倍的绝对竖向立柱位置
                   ;; =============================================================================
                   (if (and min_axis_x max_axis_x)
                     (progn
                       (setq ang_rad (if *global_angle* (* *global_angle* (/ pi 180.0)) 0.0)
                              L_span (- max_axis_x min_axis_x)
                              ;; Annot-end-dist = (L_span/2-half_D)/5, req 450~550mm
                              ;; W_phys_max = (L_span-4500)*cos(ang)/5  [end-dist=450]
                              W_phys_max (/ (* (- L_span 3300.0) (cos ang_rad)) 5.0)
                              target_W_phys (* (fix (/ W_phys_max 100.0)) 100.0)
                              target_W_cad (* target_W_phys 5.0)
                              half_D (/ target_W_cad (* 2.0 (cos ang_rad)))
                              mid_orig_x (/ (+ min_axis_x max_axis_x) 2.0)
                              mid_orig_y (- pv_start_y 600.0)
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

                       ;; 绘制 post-axis #1（左侧竖向立柱轴线）
                       (setvar "CLAYER" "AXIS")
                       (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                      (cons 10 (list U1_rot_x U1_rot_y 0.0))
                                      (cons 11 (list U1_rot_x lower_top_axis_y 0.0))))

                       ;; 绘制 post-axis #2（右侧竖向立柱轴线）
                       (entmake (list '(0 . "LINE") '(8 . "AXIS")
                                      (cons 10 (list U2_rot_x U2_rot_y 0.0))
                                      (cons 11 (list U2_rot_x lower_top_axis_y 0.0))))

                       ;; 保存左侧post-axis的最低点作为缩放中心
                       (setq *scale_center_x* U1_rot_x
                             *scale_center_y* lower_top_axis_y)
                                      
                       (setvar "CLAYER" "DIM")
                       (command "_.DIMLINEAR" "_NON" (list U1_rot_x lower_top_axis_y 0.0) "_NON" (list U2_rot_x lower_top_axis_y 0.0) "_NON" (list (/ (+ U1_rot_x U2_rot_x) 2.0) (- lower_top_axis_y 2000.0) 0.0))

                        ;; =============================================================================
                        ;; beam-angle-axis: 斜向角度轴线（沿 angle 方向的轴线）
                        ;; 计算旋转后的斜轴线两端点，用于绘制矩形、连接线等
                        ;; =============================================================================

                        (setvar "OSMODE" 0)
                        (setq ax_L_ox (- min_axis_x 600.0)  ax_L_oy (- pv_start_y 600.0)
                              ax_R_ox (+ max_axis_x 600.0)  ax_R_oy (- pv_start_y 600.0)
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
                                                       (< (PVRect_GetProjectionDist p1 axis_start_pt axis_end_pt)
                                                          (PVRect_GetProjectionDist p2 axis_start_pt axis_end_pt)))))

                        ;; 第一道详细标注：相邻点对标注，统一偏移 1200
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

                        ;; 第二道总长标注：左端->右端，偏移 2000
                        (setq total_dim_offset 2000.0
                              total_mid_x (/ (+ ax_L_rx ax_R_rx) 2.0)
                              total_mid_y (/ (+ ax_L_ry ax_R_ry) 2.0)
                              total_dim_loc_x (+ total_mid_x (* dim_nx total_dim_offset))
                              total_dim_loc_y (+ total_mid_y (* dim_ny total_dim_offset)))
                        (command "_.DIMALIGNED"
                                 "_NON" (list ax_L_rx ax_L_ry 0.0)
                                 "_NON" (list ax_R_rx ax_R_ry 0.0)
                                 "_NON" (list total_dim_loc_x total_dim_loc_y 0.0))

                        ;; 新增: 沿着 angle 方向创建矩形（beam 图层）
                        ;; 矩形长度方向同斜轴线，宽度 400mm（实际长度，不考虑缩放）
                        ;; 以斜轴线为中轴线布置
                        (if (not (tblsearch "LAYER" "beam")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "beam") (70 . 0) (62 . 4))))
                        (setvar "CLAYER" "beam")
                        (setq beam_width 400.0)  ;; 400mm 实际宽度，不考虑缩放
                        (setq half_beam_width (/ beam_width 2.0))
                        ;; 计算矩形四个顶点
                        ;; 斜轴线方向向量为 (ax_R_rx - ax_L_rx, ax_R_ry - ax_L_ry)
                        ;; 法向向量已经计算为 (dim_nx, dim_ny)
                        (setq rect_p1_x (+ ax_L_rx (* dim_nx half_beam_width))
                              rect_p1_y (+ ax_L_ry (* dim_ny half_beam_width))
                              rect_p2_x (+ ax_R_rx (* dim_nx half_beam_width))
                              rect_p2_y (+ ax_R_ry (* dim_ny half_beam_width))
                              rect_p3_x (- ax_R_rx (* dim_nx half_beam_width))
                              rect_p3_y (- ax_R_ry (* dim_ny half_beam_width))
                              rect_p4_x (- ax_L_rx (* dim_nx half_beam_width))
                              rect_p4_y (- ax_L_ry (* dim_ny half_beam_width)))
                        ;; 创建矩形（LWPOLYLINE）
                        (entmake (list '(0 . "LWPOLYLINE")
                                       '(100 . "AcDbEntity")
                                       '(100 . "AcDbPolyline")
                                       '(8 . "beam")
                                       '(90 . 4)
                                       '(70 . 1)
                                       (list 10 rect_p1_x rect_p1_y)
                                       (list 10 rect_p2_x rect_p2_y)
                                       (list 10 rect_p3_x rect_p3_y)
                                       (list 10 rect_p4_x rect_p4_y)))

                        ;; 新增: 创建第二个矩形，宽度 380mm，线型 DASH
                        (if (not (tblsearch "LTYPE" "DASH")) (entmake '((0 . "LTYPE") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLinetypeTableRecord") (2 . "DASH") (70 . 0) (3 . "DASH") (72 . 65) (73 . 2) (40 . 15.0) (49 . 10.0) (49 . -5.0))))
                        (setq dash_width 380.0)  ;; 380mm 实际宽度，不考虑缩放
                        (setq half_dash_width (/ dash_width 2.0))
                        ;; 计算第二个矩形四个顶点
                        (setq dash_p1_x (+ ax_L_rx (* dim_nx half_dash_width))
                              dash_p1_y (+ ax_L_ry (* dim_ny half_dash_width))
                              dash_p2_x (+ ax_R_rx (* dim_nx half_dash_width))
                              dash_p2_y (+ ax_R_ry (* dim_ny half_dash_width))
                              dash_p3_x (- ax_R_rx (* dim_nx half_dash_width))
                              dash_p3_y (- ax_R_ry (* dim_ny half_dash_width))
                              dash_p4_x (- ax_L_rx (* dim_nx half_dash_width))
                              dash_p4_y (- ax_L_ry (* dim_ny half_dash_width)))
                        ;; 创建 DASH 线型矩形（LWPOLYLINE）
                        (entmake (list '(0 . "LWPOLYLINE")
                                       '(100 . "AcDbEntity")
                                       '(100 . "AcDbPolyline")
                                       '(8 . "beam")
                                       '(6 . "DASH")
                                       '(90 . 4)
                                       '(70 . 1)
                                       (list 10 dash_p1_x dash_p1_y)
                                       (list 10 dash_p2_x dash_p2_y)
                                       (list 10 dash_p3_x dash_p3_y)
                                       (list 10 dash_p4_x dash_p4_y)))

                        ;; 新增: 创建第三个矩形，宽度 250mm，线型 DASH
                        (setq dash_width3 250.0)  ;; 250mm 实际宽度，不考虑缩放
                        (setq half_dash_width3 (/ dash_width3 2.0))
                        ;; 计算第三个矩形四个顶点
                        (setq dash3_p1_x (+ ax_L_rx (* dim_nx half_dash_width3))
                              dash3_p1_y (+ ax_L_ry (* dim_ny half_dash_width3))
                              dash3_p2_x (+ ax_R_rx (* dim_nx half_dash_width3))
                              dash3_p2_y (+ ax_R_ry (* dim_ny half_dash_width3))
                              dash3_p3_x (- ax_R_rx (* dim_nx half_dash_width3))
                              dash3_p3_y (- ax_R_ry (* dim_ny half_dash_width3))
                              dash3_p4_x (- ax_L_rx (* dim_nx half_dash_width3))
                              dash3_p4_y (- ax_L_ry (* dim_ny half_dash_width3)))
                        ;; 创建 DASH 线型矩形（LWPOLYLINE）
                        (entmake (list '(0 . "LWPOLYLINE")
                                       '(100 . "AcDbEntity")
                                       '(100 . "AcDbPolyline")
                                       '(8 . "beam")
                                       '(6 . "DASH")
                                       '(90 . 4)
                                       '(70 . 1)
                                       (list 10 dash3_p1_x dash3_p1_y)
                                       (list 10 dash3_p2_x dash3_p2_y)
                                       (list 10 dash3_p3_x dash3_p3_y)
                                       (list 10 dash3_p4_x dash3_p4_y)))

                        ;; =============================================================================
                        ;; 插入块参照：Nut
                        ;; 共四个，放置于 beam-angle-axis 与两条 post-axis、两条 brace-axis 的相交点
                        ;; =============================================================================

                        (setq block_name "Nut")
                        (if (tblsearch "BLOCK" block_name)
                          (progn
                            ;; 在 beam-angle-axis 与 post-axis #1 的交点插入块 (U1_rot)，缩放 5 倍
                            (entmake (list '(0 . "INSERT")
                                           (cons 2 block_name)
                                           '(8 . "AXIS")
                                           (cons 10 (list U1_rot_x U1_rot_y 0.0))
                                           '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                            (PVRect_SetBlockVisibility (entlast) "M14")
                            (ssadd (entlast) ss_pv)

                            ;; 在 beam-angle-axis 与 post-axis #2 的交点插入块 (U2_rot)，缩放 5 倍
                            (entmake (list '(0 . "INSERT")
                                           (cons 2 block_name)
                                           '(8 . "AXIS")
                                           (cons 10 (list U2_rot_x U2_rot_y 0.0))
                                           '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                            (PVRect_SetBlockVisibility (entlast) "M14")
                            (ssadd (entlast) ss_pv)

                            ;; 在 beam-angle-axis 与 brace-axis #1 的交点插入块 (brace_int1)，缩放 5 倍
                            (entmake (list '(0 . "INSERT")
                                           (cons 2 block_name)
                                           '(8 . "AXIS")
                                           (cons 10 (list brace_int1_x brace_int1_y 0.0))
                                           '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                            (PVRect_SetBlockVisibility (entlast) "M14")
                            (ssadd (entlast) ss_pv)

                            ;; 在 beam-angle-axis 与 brace-axis #2 的交点插入块 (brace_int2)，缩放 5 倍
                            (entmake (list '(0 . "INSERT")
                                           (cons 2 block_name)
                                           '(8 . "AXIS")
                                           (cons 10 (list brace_int2_x brace_int2_y 0.0))
                                           '(41 . 5.0) '(42 . 5.0) '(43 . 5.0) '(50 . 0.0)))
                            (PVRect_SetBlockVisibility (entlast) "M14")
                            (ssadd (entlast) ss_pv)
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
                        (setq line_start_x U1_rot_x
                              line_start_y (+ lower_top_axis_y 1000.0))  ;; 向上 1000mm（实际长度）
                        ;; 终点坐标使用前面计算的 brace_int1
                        (setq line_end_x brace_int1_x  line_end_y brace_int1_y)
                        ;; 创建直线
                        (entmake (list '(0 . "LINE")
                                       '(8 . "AXIS")
                                       (cons 10 (list line_start_x line_start_y 0.0))
                                       (cons 11 (list line_end_x line_end_y 0.0))))

                        ;; brace-axis #2: 创建右侧连接直线（AXIS 图层）
                        ;; 起点：post-axis #2（右侧竖向立柱轴线 U2）最低点向上 1000mm
                        ;; 终点：beam-angle-axis 最右端点反向沿 angle 方向，长度 (总长-3000)/2 的位置（已计算的交点）
                        (setq line_start_r_x U2_rot_x
                              line_start_r_y (+ lower_top_axis_y 1000.0))  ;; 向上 1000mm（实际长度）
                        ;; 终点坐标使用前面计算的 brace_int2
                        (setq line_end_r_x brace_int2_x  line_end_r_y brace_int2_y)
                        ;; 创建直线
                        (entmake (list '(0 . "LINE")
                                       '(8 . "AXIS")
                                       (cons 10 (list line_start_r_x line_start_r_y 0.0))
                                       (cons 11 (list line_end_r_x line_end_r_y 0.0))))
                     )
                   )

                   ;; 新增: 绘制右侧起点的垂直地平线高差 (Clearance)，即 DIM 横线起点到 PV 左下角源头起点的竖向标注
                   (setvar "CLAYER" "DIM")
                   (command "_.DIMLINEAR" "_NON" (list new_line_x1 lower_top_axis_y 0.0) "_NON" (list pv_start_x pv_start_y 0.0) "_NON" (list (- new_line_x1 500.0) (/ (+ lower_top_axis_y pv_start_y) 2.0) 0.0))
                   
                   (if (tblsearch "DIMSTYLE" "TSSD_50_100") (command "-DIMSTYLE" "_R" "TSSD_50_100")) ;; 恢复 TSSD_50_100
                   (setvar "CLAYER" "DIM") ;; 恢复 CLAYER
                 )
               )
                              
               (setq my_breaks
                 (PVRect_AddSegmentedHorizontalDim
                   *global_startX*
                   *global_endX*
                   lower_top_axis_y
                   lower_top_dim_y
                   *global_vx_list*
                   *global_pt_x*
                   *global_w_eval*
                   *global_gap*
                   *global_m*
                   *global_zd_eval*
                   ss_copy_sf))
                
               ;; 为分段点绘制连接件矩形
               (if my_breaks
                 (progn
                   (if (not (tblsearch "LAYER" "LTPJJ")) 
                     (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "LTPJJ") (70 . 0) (62 . 2))))
                   (setvar "CLAYER" "LTPJJ")
                   (setq rect_half_w 250.0 rect_half_h 50.0)
                   (foreach bx my_breaks
                     (foreach y_orig *global_axis_y_list*
                       (setq cy (- y_orig copy_dist))
                       (command "_.RECTANG" 
                                "_NON" (list (- bx rect_half_w) (- cy rect_half_h) 0.0) 
                                "_NON" (list (+ bx rect_half_w) (+ cy rect_half_h) 0.0))
                     )
                   )
                   (setvar "CLAYER" "DIM") ;; 恢复到DIM图层，以免影响后续标注
                 )
               )
               (setq i 0)
               (while (< i (1- (length *global_axis_y_list*)))
                 (setq y_a (- (nth i *global_axis_y_list*) copy_dist) y_b (- (nth (1+ i) *global_axis_y_list*) copy_dist))
                 (command "_.DIMLINEAR" "_NON" (list *global_startX* y_a 0.0) "_NON" (list *global_startX* y_b 0.0) "_NON" (list *global_dim_x_vert* y_a 0.0))
                 (setq i (1+ i))
               )
            )
          )
          ;; Keep only the copied bottom detailed dimension row in the lower layout.
        )
      )
    )
  )
  ;; =============================================================================
  ;; Copy axis lines to right by 25000 units, scale 1/5, and change layers
  ;; 只复制右侧轴线（LINE对象），不复制块和属性
  ;; =============================================================================
  (if *global_new_line_x1*
    (progn
      (setq axis_layers '("AXIS" "purlin-axis" "beam-angle-axis" "brace-axis" "post-axis")
            ss_axis (ssadd)
            axis_copy_dist 25000.0
            right_threshold *global_new_line_x1*)  ;; 右侧图形的起点 X 坐标

      ;; 遍历所有轴线图层
      (foreach layer_name axis_layers
        (if (tblsearch "LAYER" layer_name)
          (progn
            (setq ss_layer (ssget "X" (list (cons 8 layer_name))))
            (if ss_layer
              (progn
                (setq j 0)
                (while (< j (sslength ss_layer))
                  (setq ent (ssname ss_layer j))
                  (setq edata (entget ent))
                  (setq ent_type (cdr (assoc 0 edata)))
                  ;; 只复制直线（LINE）
                  (if (= ent_type "LINE")
                    (progn
                      ;; 检查直线的起点和终点是否在右侧（X坐标大于阈值）
                      (setq pt10 (cdr (assoc 10 edata))
                            pt11 (cdr (assoc 11 edata))
                            x10 (car pt10)
                            x11 (car pt11))
                      ;; 如果起点或终点在右侧，则复制该轴线
                      (if (or (> x10 right_threshold) (> x11 right_threshold))
                        (ssadd ent ss_axis)
                      )
                    )
                  )
                  (setq j (1+ j))
                )
              )
            )
          )
        )
      )

      ;; 执行复制
      (if (> (sslength ss_axis) 0)
        (progn
          (prompt (strcat "\n>>> Copying " (itoa (sslength ss_axis)) " right-side axis lines to the right by " (rtos axis_copy_dist 2 0) " units..."))

          ;; 记录复制前的最后一个实体
          (setq ent_before_copy (entlast))

          ;; 执行复制
          (command "_.COPY" ss_axis "" "_NON" '(0.0 0.0 0.0) (list axis_copy_dist 0.0 0.0))

          (prompt "\n>>> Right-side axis lines copied successfully.")

          ;; 选择新复制的对象
          (setq ss_new (ssadd)
                ent_new (entnext ent_before_copy))
          (while ent_new
            (ssadd ent_new ss_new)
            (setq ent_new (entnext ent_new))
          )

          (if (> (sslength ss_new) 0)
            (progn
              (prompt (strcat "\n>>> Processing " (itoa (sslength ss_new)) " copied axis lines..."))

              ;; 创建新图层
              (if (not (tblsearch "LAYER" "01Purlin-01")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "01Purlin-01") (70 . 0) (62 . 3))))
              (if (not (tblsearch "LAYER" "01Purlin-02")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "01Purlin-02") (70 . 0) (62 . 3))))
              (if (not (tblsearch "LAYER" "02Beam")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "02Beam") (70 . 0) (62 . 4))))
              (if (not (tblsearch "LAYER" "03Brace")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "03Brace") (70 . 0) (62 . 1))))
              (if (not (tblsearch "LAYER" "04Column")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "04Column") (70 . 0) (62 . 7))))

              ;; 先修改图层（在缩放之前，基于原始尺寸判断）

              ;; 第一步：收集所有purlin-axis（短线，长度≤3000）
              (setq purlin_list '()
                    j 0)
              (while (< j (sslength ss_new))
                (setq ent (ssname ss_new j))
                (setq edata (entget ent))
                (setq pt10 (cdr (assoc 10 edata))
                      pt11 (cdr (assoc 11 edata))
                      x10 (car pt10)
                      x11 (car pt11)
                      line_len (distance pt10 pt11))

                ;; 判断是否为purlin-axis（短线）
                (if (<= line_len 3000.0)
                  (progn
                    ;; 使用复制前的X坐标来判断原位置
                    (setq x10_original (- x10 axis_copy_dist)
                          x11_original (- x11 axis_copy_dist)
                          mid_x_original (/ (+ x10_original x11_original) 2.0))
                    ;; 收集信息：(中点X坐标, 实体名)
                    (setq purlin_list (cons (list mid_x_original ent) purlin_list))
                  )
                )
                (setq j (1+ j))
              )

              ;; 第二步：按中点X坐标排序（从左到右）
              (setq purlin_list (reverse purlin_list))  ;; 反转使其从左到右
              (setq purlin_list (vl-sort purlin_list '(lambda (a b) (< (car a) (car b)))))
              (setq purlin_count (length purlin_list))
              (setq split_index (/ purlin_count 2))  ;; 分割点

              ;; 第三步：创建两个分组
              (setq purlin_left_list '()
                    purlin_right_list '())
              (setq k 0)
              (while (< k purlin_count)
                (if (< k split_index)
                  (setq purlin_left_list (cons (cadr (nth k purlin_list)) purlin_left_list))
                  (setq purlin_right_list (cons (cadr (nth k purlin_list)) purlin_right_list))
                )
                (setq k (1+ k))
              )

              ;; 第四步：处理所有轴线的图层修改
              (setq j 0)
              (while (< j (sslength ss_new))
                (setq ent (ssname ss_new j))
                (setq edata (entget ent))
                (setq pt10 (cdr (assoc 10 edata))
                      pt11 (cdr (assoc 11 edata))
                      x10 (car pt10)
                      x11 (car pt11)
                      y10 (cadr pt10)
                      y11 (cadr pt11)
                      dx (- x11 x10)
                      dy (- y11 y10)
                      line_len (distance pt10 pt11)
                      new_layer nil)

                ;; 根据轴线特征判断类型并修改图层（基于原始尺寸）
                (cond
                  ;; 1. 竖向长线（post-axis）-> 04Column
                  ((and (< (abs dx) 10.0) (> line_len 3000.0))
                    (setq new_layer "04Column")
                  )
                  ;; 2. beam-angle-axis -> 02Beam
                  ((> line_len 15000.0)
                    (setq new_layer "02Beam")
                  )
                  ;; 3. brace-axis -> 03Brace
                  ((and (> line_len 3000.0) (<= line_len 15000.0))
                    (setq new_layer "03Brace")
                  )
                  ;; 4. purlin-axis -> 根据分组分配图层
                  (t
                    ;; 检查当前实体属于哪个分组
                    (if (member ent purlin_left_list)
                      (setq new_layer "01Purlin-02")  ;; 左侧分组
                      (if (member ent purlin_right_list)
                        (setq new_layer "01Purlin-01")  ;; 右侧分组
                        (setq new_layer "01Purlin-01")  ;; 默认
                      )
                    )
                  )
                )

                ;; 执行图层修改
                (if new_layer
                  (entmod (subst (cons 8 new_layer) (assoc 8 edata) edata))
                )
                (setq j (1+ j))
              )
              (prompt (strcat "\n>>> Purlin-axis grouped: " (itoa (length purlin_left_list)) " left, " (itoa (length purlin_right_list)) " right."))
              (prompt "\n>>> Layer changes completed.")

              ;; 使用保存的缩放中心执行缩放（在图层修改之后）
              (if (and *scale_center_x* *scale_center_y*)
                (progn
                  (setq scale_center (list *scale_center_x* *scale_center_y* 0.0))
                  (prompt (strcat "\n>>> Scaling copied axis lines by 1/5, center at (" (rtos (car scale_center) 2 0) "," (rtos (cadr scale_center) 2 0) ")..."))
                  (command "_.SCALE" ss_new "" "_NON" scale_center 0.2)
                  (prompt "\n>>> Scaling completed.")
                )
                (prompt "\n>>> Warning: Scale center not found, skipping scale.")
              )
            )
          )
        )
        (prompt "\n>>> No right-side axis lines found to copy.")
      )
    )
    (prompt "\n>>> Skipping axis copy: right section not generated.")
  )

  ;; 清理全局变量（在复制轴线之后执行）
  (setq *global_h* nil *global_hole* nil *global_sf* nil *title_ents_list* nil *left_dims_global* nil *top_dims_global* nil *upper_only_ents* nil *global_axis_y_list* nil *global_startX* nil *global_endX* nil *global_dim_x_vert* nil *global_pt_x* nil *global_w_eval* nil *global_gap* nil *global_start_vx* nil *global_zd_eval* nil *global_dim_y* nil *global_dim_y2* nil *global_top_y* nil *global_axis_y2_baseline* nil *global_vx_list* nil *global_bottom_y* nil *global_bottom_dim_y* nil *global_clearance* nil *global_angle* nil *global_nop* nil *global_new_line_x1* nil *scale_center_x* nil *scale_center_y* nil)

  (if *old_osmode_global* (progn (setvar "OSMODE" *old_osmode_global*) (setq *old_osmode_global* nil)))
  (if *old_layer_global* (progn (setvar "CLAYER" *old_layer_global*) (setq *old_layer_global* nil)))
  (command "_.-LAYER" "_ON" "*" "")
  (princ)
)

;; =============================================================================
;; 3. Main Entry Command
;; =============================================================================

(defun c:PVRect ( / dcl_id dcl_file f h_str w_str n_str m_str hole_str zn_str zd_str zde_str clearance_str angle_str nop_str dialog_done w h n m hole zn zd zde clearance angle nop pt res ri ci vi ptbase axis_mid axis_y1 axis_y2 startX endX array_width center_x vert_axes_width start_vx top_y bottom_y cur_vx SF h_eval w_eval hole_eval zd_eval zde_eval gap extX axis_gap purlin_half_h beam_half_w beam_shrink dim_y dim_y2 old_osmode px1 px2 px3 old_layer old_dimstyle bottom_axis_ent click_x click_y cmd_str vert_y_list dim_x_vert dim_x2_vert y_a y_b i y_pv_bot y_pv_top cur_y_pv_bot cur_y_pv_top next_y_pv_bot vx_list brace_start_x brace_start_y brace_end_x brace_end_y brace_dx brace_dy brace_len brace_ext brace_ux brace_uy mirror_axis_x upper_only_list)
  (setq h_str "2382" w_str "1134" n_str "2" m_str "12" hole_str "1400" zn_str "3" zd_str "3800" zde_str "3800" clearance_str "400" angle_str "20" nop_str "2" dialog_done nil)
  
  (while (not dialog_done)
    (setq dcl_file (vl-filename-mktemp "pvrect.dcl") f (open dcl_file "w"))
    (write-line "pvrect_dlg : dialog {" f)
    (write-line "  label = \"PV Array Generator\";" f)
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
    
    (set_tile "val_h" h_str) (set_tile "val_w" w_str) (set_tile "val_n" n_str) (set_tile "val_m" m_str) (set_tile "val_hole" hole_str) (set_tile "val_zn" zn_str) (set_tile "val_zd" zd_str) (set_tile "val_zde" zde_str)
    (set_tile "val_clearance" clearance_str) (set_tile "val_angle" angle_str) (set_tile "val_nop" (if (= nop_str "3") "1" "0"))
    
    (action_tile "accept" "(setq h_str (get_tile \"val_h\") w_str (get_tile \"val_w\") n_str (get_tile \"val_n\") m_str (get_tile \"val_m\") hole_str (get_tile \"val_hole\") zn_str (get_tile \"val_zn\") zd_str (get_tile \"val_zd\") zde_str (get_tile \"val_zde\") clearance_str (get_tile \"val_clearance\") angle_str (get_tile \"val_angle\") nop_str (if (= (get_tile \"val_nop\") \"1\") \"3\" \"2\")) (done_dialog 1)")
    (action_tile "cancel" "(done_dialog 0)")
    (action_tile "btn_import" "(PVRect_ImportExcel)")
    
    (setq res (start_dialog))
    (unload_dialog dcl_id)
    (vl-file-delete dcl_file)
    (setq dialog_done T)
  )

  (if (= res 1)
    (progn
      (setq h (atof h_str) w (atof w_str) n (atoi n_str) m (atoi m_str) hole (atof hole_str) zn (atoi zn_str) zd (atof zd_str) zde (atof zde_str) clearance (atof clearance_str) angle (atof angle_str) nop (atoi nop_str))
      (if (and (> h 0) (> w 0) (> n 0) (> m 0) (> hole 0))
        (progn
          (setq pt (getpoint "\nSelect insertion point: "))
          (if pt
            (progn
              (setq *first_ent_global* (entlast))
              (command "_.-LAYER" "_UNLOCK" "purlin,beam" "")
              
              (if (not (tblsearch "LAYER" "AXIS")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "AXIS") (70 . 0) (62 . 1))))
              (if (not (tblsearch "LAYER" "purlin")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "purlin") (70 . 0) (62 . 3))))
              (if (not (tblsearch "LAYER" "beam")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "beam") (70 . 0) (62 . 4))))
              (if (not (tblsearch "LAYER" "PV")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "PV") (70 . 0) (62 . 7))))
              (if (not (tblsearch "LAYER" "STPM_SBEAM_THICK")) (entmake '((0 . "LAYER") (100 . "AcDbSymbolTableRecord") (100 . "AcDbLayerTableRecord") (2 . "STPM_SBEAM_THICK") (70 . 0) (62 . 7))))
              
              (setq SF 2.0 h_eval (* h SF) w_eval (* w SF) hole_eval (* hole SF) zd_eval (* zd SF) zde_eval (* zde SF) gap (* 20.0 SF) extX (* 75.0 SF) axis_gap (/ hole_eval 2.0) purlin_half_h (* 25.0 SF) beam_half_w (* 25.0 SF) beam_shrink (* 350.0 SF))
              
              (setq old_layer (getvar "CLAYER") old_osmode (getvar "OSMODE"))
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
              
              (setq *top_dims_global* nil dim_y (+ top_y (* 600.0 SF)))
              (command "_.DIMLINEAR" "_NON" (list startX top_y 0.0) "_NON" (list (car pt) top_y 0.0) "_NON" (list startX dim_y 0.0))
              (setq *top_dims_global* (append *top_dims_global* (list (entlast))))
              (setq ci 0)
              (while (< ci m)
                (setq px1 (+ (car pt) (* ci (+ w_eval gap))) px2 (+ px1 w_eval))
                (command "_.DIMLINEAR" "_NON" (list px1 top_y 0.0) "_NON" (list px2 top_y 0.0) "_NON" (list px1 dim_y 0.0))
                (setq *top_dims_global* (append *top_dims_global* (list (entlast))))
                (if (< ci (1- m)) (progn (setq px3 (+ px2 gap)) (command "_.DIMLINEAR" "_NON" (list px2 top_y 0.0) "_NON" (list px3 top_y 0.0) "_NON" (list px2 dim_y 0.0)) (setq *top_dims_global* (append *top_dims_global* (list (entlast))))))
                (setq ci (1+ ci))
              )
              (command "_.DIMLINEAR" "_NON" (list px2 top_y 0.0) "_NON" (list endX top_y 0.0) "_NON" (list px2 dim_y 0.0))
              (setq *top_dims_global* (append *top_dims_global* (list (entlast))))
              (setq dim_y2 (+ dim_y (* 600.0 SF)))
              (command "_.DIMLINEAR" "_NON" (list startX top_y 0.0) "_NON" (list endX top_y 0.0) "_NON" (list startX dim_y2 0.0))
              (setq *top_dims_global* (append *top_dims_global* (list (entlast))))
              
              (setq vert_y_list nil *global_axis_y_list* nil ri 0)
              (while (< ri n)
                (setq y_pv_bot (+ (cadr pt) (* ri (+ h_eval gap))) y_pv_top (+ y_pv_bot h_eval) axis_mid (+ y_pv_bot (/ h_eval 2.0)) axis_y1 (+ axis_mid axis_gap) axis_y2 (- axis_mid axis_gap))
                (if (= nop 3)
                  (progn
                    (setq vert_y_list (append vert_y_list (list y_pv_bot axis_y2 axis_mid axis_y1 y_pv_top)) *global_axis_y_list* (append *global_axis_y_list* (list axis_y2 axis_mid axis_y1)))
                  )
                  (progn
                    (setq vert_y_list (append vert_y_list (list y_pv_bot axis_y2 axis_y1 y_pv_top)) *global_axis_y_list* (append *global_axis_y_list* (list axis_y2 axis_y1)))
                  )
                )
                (setq ri (1+ ri))
              )
              (setq *upper_only_ents* nil)
              (if (and vx_list *global_axis_y_list*)
                (progn
                  (setq brace_start_x (car vx_list)
                        brace_start_y (- (apply 'max *global_axis_y_list*) 200.0)
                        brace_end_x (if (> (length vx_list) 1) (cadr vx_list) (car vx_list))
                        brace_end_y (+ (apply 'min *global_axis_y_list*) 200.0)
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
                                new_brace_start_y (- (apply 'max *global_axis_y_list*) 200.0)
                                new_brace_end_x right2_axis_x
                                new_brace_end_y (+ (apply 'min *global_axis_y_list*) 200.0)
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
                      (setq *upper_only_ents* upper_only_list)
                    )
                  )
                )
              )
              
              (setq dim_x_vert (- startX (* 300.0 SF)) *left_dims_global* nil i 0)
              (while (< i (1- (length vert_y_list)))
                (setq y_a (nth i vert_y_list) y_b (nth (1+ i) vert_y_list))
                (command "_.DIMLINEAR" "_NON" (list startX y_a 0.0) "_NON" (list startX y_b 0.0) "_NON" (list dim_x_vert y_a 0.0))
                (setq *left_dims_global* (append *left_dims_global* (list (entlast))))
                (setq i (1+ i))
              )
              (setq dim_x2_vert (- dim_x_vert (* 600.0 SF)) ri 0)
              (while (< ri n)
                (setq cur_y_pv_bot (+ (cadr pt) (* ri (+ h_eval gap))) cur_y_pv_top (+ cur_y_pv_bot h_eval))
                (command "_.DIMLINEAR" "_NON" (list startX cur_y_pv_bot 0.0) "_NON" (list startX cur_y_pv_top 0.0) "_NON" (list dim_x2_vert cur_y_pv_bot 0.0))
                (setq *left_dims_global* (append *left_dims_global* (list (entlast))))
                (if (< ri (1- n)) (progn (setq next_y_pv_bot (+ cur_y_pv_top gap)) (command "_.DIMLINEAR" "_NON" (list startX cur_y_pv_top 0.0) "_NON" (list startX next_y_pv_bot 0.0) "_NON" (list dim_x2_vert cur_y_pv_top 0.0)) (setq *left_dims_global* (append *left_dims_global* (list (entlast))))))
                (setq ri (1+ ri))
              )
              
              (if bottom_axis_ent
                (progn
                  (princ "\n>>> Post-processing...")
                  (setvar "CLAYER" "AXIS") 
                  ;; Turn OFF everything that could interfere with selection (especially PV)
                  (command "_.-LAYER" "_OFF" "purlin,beam,PV,DIM" "")
                  (setq *last_ent_before_macro* (entlast) *global_n* n *global_m* m *global_zn* zn *global_center_x* center_x *global_axis_y2_baseline* axis_y2 *global_h* h *global_hole* hole *global_sf* SF *global_startX* startX *global_endX* endX *global_dim_x_vert* dim_x_vert *global_pt_x* (car pt) *global_w_eval* w_eval *global_gap* gap *global_start_vx* start_vx *global_zd_eval* zd_eval *global_dim_y* dim_y *global_dim_y2* dim_y2 *global_top_y* top_y *global_vx_list* vx_list *global_bottom_y* bottom_y *global_bottom_dim_y* (- bottom_y (* 600.0 SF)) *global_clearance* clearance *global_angle* angle *global_nop* nop *global_new_line_x1* nil *scale_center_x* nil *scale_center_y* nil *old_osmode_global* old_osmode *old_layer_global* old_layer)
                  (command "_.ZOOM" "_E")
                  ;; Reverting to stable sequence with 5 Enters to ensure loop exit
                  (setq cmd_str (strcat "ZHWBZH\n" (rtos click_x 2 4) "," (rtos click_y 2 4) "\n\n\n\n\n" "(PVRect_PostFix)\n"))
                  (vla-SendCommand (vla-get-ActiveDocument (vlax-get-acad-object)) cmd_str)
                )
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
(princ "\n= PVRect Script (Base: v33/v34) Loaded      =")
(princ "\n=============================================")
(princ)
