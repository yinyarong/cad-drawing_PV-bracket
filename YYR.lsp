(vl-load-com)

;; =============================================================================
;; YYR_Brace - select a LINE, generate two parallel rectangles on layer 03Brace
;;   Rect1 width = param * 5
;;   Rect2 width = (param - 10) * 5
;;   param must be > 10
;; =============================================================================

(defun YYR_Brace (param / line_ent line_data start_pt end_pt line_len line_angle perp_angle width1 width2 offset1 offset2 rect1_pt1 rect1_pt2 rect1_pt3 rect1_pt4 rect2_pt1 rect2_pt2 rect2_pt3 rect2_pt4)

  (setq width1 (* param 5.0))
  (setq width2 (* (- param 10) 5.0))

  (setq line_ent (car (entsel "\nSelect a LINE: ")))
  (if (not line_ent)
    (progn (prompt "\nNo object selected.") (exit))
  )

  (setq line_data (entget line_ent))
  (if (/= (cdr (assoc 0 line_data)) "LINE")
    (progn (alert "Selected object is not a LINE!") (exit))
  )

  (setq start_pt (cdr (assoc 10 line_data)))
  (setq end_pt   (cdr (assoc 11 line_data)))

  (setq line_len   (distance start_pt end_pt))
  (setq line_angle (angle start_pt end_pt))
  (setq perp_angle (+ line_angle (/ pi 2.0)))

  (if (< (sin perp_angle) 0)
    (setq perp_angle (+ perp_angle pi))
  )

  (if (not (tblsearch "LAYER" "03Brace"))
    (entmake (list
      '(0 . "LAYER")
      '(100 . "AcDbSymbolTableRecord")
      '(100 . "AcDbLayerTableRecord")
      '(2 . "03Brace")
      '(70 . 0)
      '(62 . 7)
    ))
  )

  ;; Rectangle 1
  (setq offset1   (/ width1 2.0))
  (setq rect1_pt1 (polar start_pt perp_angle (- offset1)))
  (setq rect1_pt2 (polar end_pt   perp_angle (- offset1)))
  (setq rect1_pt3 (polar end_pt   perp_angle offset1))
  (setq rect1_pt4 (polar start_pt perp_angle offset1))

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

  ;; Rectangle 2 (centered on the line, narrower)
  (setq offset2   (/ width2 2.0))
  (setq rect2_pt1 (polar start_pt perp_angle (- offset2)))
  (setq rect2_pt2 (polar end_pt   perp_angle (- offset2)))
  (setq rect2_pt3 (polar end_pt   perp_angle offset2))
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

  (prompt (strcat "\nCreated 2 rectangles on layer 03Brace"))
  (prompt (strcat "\n  Rect1: " (rtos width1 2 0) " x " (rtos line_len 2 0)))
  (prompt (strcat "\n  Rect2: " (rtos width2 2 0) " x " (rtos line_len 2 0)))
  (princ)
)

;; =============================================================================
;; YYR_CPost - select a LINE, generate two centered rectangles on layer 03CPost
;;   Rect1 width = param * 5
;;   Rect2 width = (param - 20) * 5
;;   param must be > 20
;; =============================================================================

(defun YYR_CPost (param / line_ent line_data start_pt end_pt line_len line_angle perp_angle width1 width2 offset1 offset2 rect1_pt1 rect1_pt2 rect1_pt3 rect1_pt4 rect2_pt1 rect2_pt2 rect2_pt3 rect2_pt4)

  (setq width1 (* param 5.0))
  (setq width2 (* (- param 20) 5.0))

  (setq line_ent (car (entsel "\nSelect a LINE: ")))
  (if (not line_ent)
    (progn (prompt "\nNo object selected.") (exit))
  )

  (setq line_data (entget line_ent))
  (if (/= (cdr (assoc 0 line_data)) "LINE")
    (progn (alert "Selected object is not a LINE!") (exit))
  )

  (setq start_pt (cdr (assoc 10 line_data)))
  (setq end_pt   (cdr (assoc 11 line_data)))

  (setq line_len   (distance start_pt end_pt))
  (setq line_angle (angle start_pt end_pt))
  (setq perp_angle (+ line_angle (/ pi 2.0)))

  (if (< (sin perp_angle) 0)
    (setq perp_angle (+ perp_angle pi))
  )

  (if (not (tblsearch "LAYER" "03CPost"))
    (entmake (list
      '(0 . "LAYER")
      '(100 . "AcDbSymbolTableRecord")
      '(100 . "AcDbLayerTableRecord")
      '(2 . "03CPost")
      '(70 . 0)
      '(62 . 7)
    ))
  )

  ;; Rectangle 1
  (setq offset1   (/ width1 2.0))
  (setq rect1_pt1 (polar start_pt perp_angle (- offset1)))
  (setq rect1_pt2 (polar end_pt   perp_angle (- offset1)))
  (setq rect1_pt3 (polar end_pt   perp_angle offset1))
  (setq rect1_pt4 (polar start_pt perp_angle offset1))

  (entmake (list
    '(0 . "LWPOLYLINE")
    '(100 . "AcDbEntity")
    '(8 . "03CPost")
    '(62 . 4)
    '(100 . "AcDbPolyline")
    '(90 . 4)
    '(70 . 1)
    (cons 10 (list (car rect1_pt1) (cadr rect1_pt1)))
    (cons 10 (list (car rect1_pt2) (cadr rect1_pt2)))
    (cons 10 (list (car rect1_pt3) (cadr rect1_pt3)))
    (cons 10 (list (car rect1_pt4) (cadr rect1_pt4)))
  ))

  ;; Rectangle 2 (centered on the line, narrower)
  (setq offset2   (/ width2 2.0))
  (setq rect2_pt1 (polar start_pt perp_angle (- offset2)))
  (setq rect2_pt2 (polar end_pt   perp_angle (- offset2)))
  (setq rect2_pt3 (polar end_pt   perp_angle offset2))
  (setq rect2_pt4 (polar start_pt perp_angle offset2))

  (entmake (list
    '(0 . "LWPOLYLINE")
    '(100 . "AcDbEntity")
    '(8 . "03CPost")
    '(62 . 4)
    '(100 . "AcDbPolyline")
    '(90 . 4)
    '(70 . 1)
    (cons 10 (list (car rect2_pt1) (cadr rect2_pt1)))
    (cons 10 (list (car rect2_pt2) (cadr rect2_pt2)))
    (cons 10 (list (car rect2_pt3) (cadr rect2_pt3)))
    (cons 10 (list (car rect2_pt4) (cadr rect2_pt4)))
  ))

  (prompt (strcat "\nCreated 2 rectangles on layer 03CPost"))
  (prompt (strcat "\n  Rect1: " (rtos width1 2 0) " x " (rtos line_len 2 0)))
  (prompt (strcat "\n  Rect2: " (rtos width2 2 0) " x " (rtos line_len 2 0)))
  (princ)
)

;; =============================================================================
;; YYR_Label - select a LINE, create an aligned dimension below it
;;   param 100 -> style TSSD_100_100, offset 150*1 = 150
;;   param  50 -> style TSSD_50_100,  offset 150*2 = 300
;;   param  20 -> style TSSD_20_100,  offset 150*5 = 750
;; =============================================================================

(defun YYR_Label (param / line_ent line_data start_pt end_pt line_angle perp_angle below_angle offset_dist mid_pt dim_loc style_name n old_dimstyle old_layer doc)

  (cond
    ((= param 100) (setq n 1 style_name "TSSD_100_100"))
    ((= param  50) (setq n 2 style_name "TSSD_50_100"))
    (t             (setq n 5 style_name "TSSD_20_100"))
  )
  (setq offset_dist (* 150.0 n))

  (setq line_ent (car (entsel "\nSelect a LINE to label: ")))
  (if (not line_ent)
    (progn (prompt "\nNo object selected.") (exit))
  )

  (setq line_data (entget line_ent))
  (if (/= (cdr (assoc 0 line_data)) "LINE")
    (progn (alert "Selected object is not a LINE!") (exit))
  )

  (setq start_pt (cdr (assoc 10 line_data)))
  (setq end_pt   (cdr (assoc 11 line_data)))

  ;; Perpendicular direction pointing "below" (negative Y component)
  (setq line_angle (angle start_pt end_pt))
  (setq perp_angle (+ line_angle (/ pi 2.0)))
  (if (> (sin perp_angle) 0)
    (setq below_angle (+ perp_angle pi))
    (setq below_angle perp_angle)
  )

  ;; Dimension line location: midpoint offset below by 150*n
  (setq mid_pt (list
    (/ (+ (car start_pt) (car end_pt)) 2.0)
    (/ (+ (cadr start_pt) (cadr end_pt)) 2.0)
    0.0))
  (setq dim_loc (polar mid_pt below_angle offset_dist))

  ;; Ensure DIM layer exists, then switch to it
  (if (not (tblsearch "LAYER" "DIM"))
    (entmake (list
      '(0 . "LAYER")
      '(100 . "AcDbSymbolTableRecord")
      '(100 . "AcDbLayerTableRecord")
      '(2 . "DIM")
      '(70 . 0)
      '(62 . 7)
    ))
  )
  (setq old_layer (getvar "CLAYER"))
  (setvar "CLAYER" "DIM")

  ;; Set dimension style via VLA (avoids polluting the command queue)
  (setq old_dimstyle (getvar "DIMSTYLE"))
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (if (tblsearch "DIMSTYLE" style_name)
    (vl-catch-all-apply
      '(lambda ()
         (vla-put-ActiveDimStyle doc
           (vla-item (vla-get-DimStyles doc) style_name)))
    )
  )

  ;; Create aligned dimension (2D points — DIMALIGNED ignores Z)
  (command "_.DIMALIGNED"
    (list (car start_pt) (cadr start_pt))
    (list (car end_pt)   (cadr end_pt))
    (list (car dim_loc)  (cadr dim_loc))
  )

  ;; Restore previous dimension style and layer
  (if (tblsearch "DIMSTYLE" old_dimstyle)
    (vl-catch-all-apply
      '(lambda ()
         (vla-put-ActiveDimStyle doc
           (vla-item (vla-get-DimStyles doc) old_dimstyle)))
    )
  )
  (setvar "CLAYER" old_layer)

  (prompt (strcat "\nLabeled with " style_name " at offset " (rtos offset_dist 2 0)))
  (princ)
)

;; =============================================================================
;; Main command - DCL dialog
;; =============================================================================

(defun c:YYR ( / dcl_file f dcl_id res brace_param_str cpost_param_str label_param_str)

  (setq brace_param_str "50")
  (setq cpost_param_str "80")
  (setq label_param_str "2") ; index 2 = param 20 (default)

  (setq dcl_file (vl-filename-mktemp "yyr.dcl"))
  (setq f (open dcl_file "w"))

  (write-line "yyr_dlg : dialog {" f)
  (write-line "  label = \"YYR Drawing Tools\";" f)
  (write-line "  width = 50;" f)

  (write-line "  : boxed_column { label = \"Brace - Generate Rectangles\";" f)
  (write-line "    : row {" f)
  (write-line "      : text { label = \"Param:\"; width = 10; fixed_width = true; }" f)
  (write-line "      : edit_box { key = \"brace_param\"; edit_width = 10; }" f)
  (write-line "      : button { label = \"Run\"; key = \"btn_brace\"; width = 10; fixed_width = true; }" f)
  (write-line "    }" f)
  (write-line "    : text { value = \"Select a line to generate 2 rectangles (param > 10)\"; }" f)
  (write-line "    : text { value = \"Rect1 width = param x 5,  Rect2 width = (param-10) x 5\"; }" f)
  (write-line "  }" f)

  (write-line "  : spacer { height = 1; }" f)

  (write-line "  : boxed_column { label = \"C-Post - Generate Rectangles\";" f)
  (write-line "    : row {" f)
  (write-line "      : text { label = \"Param:\"; width = 10; fixed_width = true; }" f)
  (write-line "      : edit_box { key = \"cpost_param\"; edit_width = 10; }" f)
  (write-line "      : button { label = \"Run\"; key = \"btn_cpost\"; width = 10; fixed_width = true; }" f)
  (write-line "    }" f)
  (write-line "    : text { value = \"Select a line to generate 2 rectangles (param > 20)\"; }" f)
  (write-line "    : text { value = \"Rect1 width = param x 5,  Rect2 width = (param-20) x 5\"; }" f)
  (write-line "  }" f)

  (write-line "  : spacer { height = 1; }" f)

  (write-line "  : boxed_column { label = \"Label - Dimension Line Length\";" f)
  (write-line "    : row {" f)
  (write-line "      : text { label = \"Scale:\"; width = 10; fixed_width = true; }" f)
  (write-line "      : popup_list { key = \"label_param\"; edit_width = 14; }" f)
  (write-line "      : button { label = \"Run\"; key = \"btn_label\"; width = 10; fixed_width = true; }" f)
  (write-line "    }" f)
  (write-line "    : text { value = \"100: TSSD_100_100, offset 150\"; }" f)
  (write-line "    : text { value = \" 50: TSSD_50_100,  offset 300\"; }" f)
  (write-line "    : text { value = \" 20: TSSD_20_100,  offset 750 (default)\"; }" f)
  (write-line "  }" f)

  (write-line "  : spacer { height = 1; }" f)
  (write-line "  ok_cancel;" f)
  (write-line "}" f)

  (close f)

  (setq dcl_id (load_dialog dcl_file))
  (if (not (new_dialog "yyr_dlg" dcl_id))
    (progn (princ "\nError loading DCL.") (exit))
  )

  (set_tile "brace_param"  brace_param_str)
  (set_tile "cpost_param"  cpost_param_str)

  (start_list "label_param")
  (add_list "100")
  (add_list "50")
  (add_list "20")
  (end_list)
  (set_tile "label_param" label_param_str)

  (action_tile "btn_brace"
    "(setq brace_param_str (get_tile \"brace_param\")) (done_dialog 1)")
  (action_tile "btn_cpost"
    "(setq cpost_param_str (get_tile \"cpost_param\")) (done_dialog 3)")
  (action_tile "btn_label"
    "(setq label_param_str (get_tile \"label_param\")) (done_dialog 2)")
  (action_tile "accept"  "(done_dialog 0)")
  (action_tile "cancel"  "(done_dialog -1)")

  (setq res (start_dialog))
  (unload_dialog dcl_id)
  (vl-file-delete dcl_file)

  (cond
    ((= res 1)
      (setq brace_param (atof brace_param_str))
      (if (<= brace_param 10)
        (alert "Parameter must be > 10")
        (YYR_Brace brace_param)
      )
    )
    ((= res 3)
      (setq cpost_param (atof cpost_param_str))
      (if (<= cpost_param 20)
        (alert "Parameter must be > 20")
        (YYR_CPost cpost_param)
      )
    )
    ((= res 2)
      (setq label_param
        (cond
          ((= label_param_str "0") 100)
          ((= label_param_str "1")  50)
          (t                         20)
        )
      )
      (YYR_Label label_param)
    )
  )

  (princ)
)

;; =============================================================================

(princ "\n=============================================")
(princ "\n= YYR Drawing Tools Loaded                  =")
(princ "\n= Type YYR to launch                        =")
(princ "\n=============================================")
