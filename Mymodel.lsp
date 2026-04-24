(vl-load-com)

(defun c:MyModel (/ *error* xlApp xlWbooks xlWb xlSh xlPath spacing rowCount ss ss_all i offset_y old_osmode 
                   pt0 pt1 targetWbName tempWb wbCount i_wb isOpenedByMe obj newObj moveVec
                   val1 val2 val3 val4 dist1 dist2 dist_total ss_pur en p1 p2 base_pt mSpace j 
                   curLayer dwg_dir excel_files dwg_full dwg_path dxf_name dxf_path acadDoc)
  
  (defun *error* (msg)
    (if old_osmode (setvar "OSMODE" old_osmode))
    (setvar "cmdecho" 1)
    (if (and isOpenedByMe xlApp) (vl-catch-all-apply 'vlax-invoke-method (list xlApp "Quit")))
    (if (not (member msg '("Function cancelled" "quit / exit abort")))
      (princ (strcat "\n[ERR] " (vl-princ-to-string msg)))
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
    (princ "\n[Step 4] 正在清理多余图层...")
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

    (princ (strcat "\n>>> 图层清理完成：保留含线图层 "
                   (itoa (length keepLayers))
                   " 个，删除多余图层 "
                   (itoa deletedCount)
                   " 个，清除对象 "
                   (itoa removedCount)
                   " 个。"))
  )

  (setq old_osmode (getvar "OSMODE"))
  (setvar "OSMODE" 0)
  (setvar "cmdecho" 0)
  (princ "\n[System] 正在初始化自动化建模脚本...")

  ;; 1. 执行三维旋转
  (princ "\n[Step 1] 正在执行全选并绕 X 轴旋转 90 度...")
  (setq pt0 (list 0.0 0.0 0.0)
        pt1 (list 1.0 0.0 0.0))
  (if (setq ss_all (ssget "_X"))
    (progn
      (setq i 0)
      (repeat (sslength ss_all)
        (vla-Rotate3D 
          (vlax-ename->vla-object (ssname ss_all i)) 
          (vlax-3d-point pt0) 
          (vlax-3d-point pt1) 
          (/ pi 2.0)
        )
        (setq i (1+ i))
      )
      (princ "\n>>> 旋转步骤完成。")
    )
  )

  ;; 2. 读取 Excel 参数
  (princ "\n[Step 2] 正在连接 Excel 获取参数...")
  
  (setq dwg_dir (getvar "DWGPREFIX"))
  (setq excel_files (vl-directory-files dwg_dir "*.xls*" 1))
  
  (if (and excel_files (> (length excel_files) 0))
    (progn
      (setq targetWbName (car excel_files)) 
      (setq xlPath (strcat dwg_dir targetWbName))
      (princ (strcat "\n[System] 已自动匹配 Excel：" targetWbName))
    )
    (progn
      (setq xlPath nil targetWbName "")
      (princ "\n[Warn] 当前文件夹下未发现任何 Excel 文件！")
    )
  )

  (setq spacing 0.0 rowCount 0 xlWb nil xlApp nil isOpenedByMe nil)

  (if (and xlPath (findfile xlPath))
    (progn
      (setq xlApp (vl-catch-all-apply 'vlax-get-object (list "Excel.Application")))
      (if (or (null xlApp) (vl-catch-all-error-p xlApp))
        (progn (setq xlApp (vlax-get-or-create-object "Excel.Application")) (setq isOpenedByMe t))
      )

      (if (and xlApp (not (vl-catch-all-error-p xlApp)))
        (progn
          (setq xlWbooks (vlax-get-property xlApp "Workbooks"))
          (setq wbCount (vlax-get-property xlWbooks "Count"))
          (setq i_wb 1)
          (while (and (<= i_wb wbCount) (null xlWb))
            (setq tempWb (vlax-get-property xlWbooks "Item" i_wb))
            (if (= (strcase (vlax-get-property tempWb "Name")) (strcase targetWbName))
                (setq xlWb tempWb)
                (vlax-release-object tempWb)
            )
            (setq i_wb (1+ i_wb))
          )
          (if (null xlWb)
            (setq xlWb (vl-catch-all-apply 'vlax-invoke (list xlWbooks "Open" xlPath))))

          (if (and xlWb (not (vl-catch-all-error-p xlWb)))
            (progn
              (setq xlSh (vl-catch-all-apply 'vlax-get-property (list (vlax-get-property xlWb "Sheets") "Item" "阵列计算")))
              (if (not (vl-catch-all-error-p xlSh))
                (progn
                  (setq val1 (vlax-variant-value (vlax-get-property (vlax-get-property xlSh "Range" "C14") "Value2")))
                  (setq val2 (vlax-variant-value (vlax-get-property (vlax-get-property xlSh "Range" "C15") "Value2")))
                  (setq val3 (vlax-variant-value (vlax-get-property (vlax-get-property xlSh "Range" "C13") "Value2")))
                  (setq val4 (vlax-variant-value (vlax-get-property (vlax-get-property xlSh "Range" "C16") "Value2")))
                  (setq spacing (if (= (type val1) 'STR) (atof val1) (float (if val1 val1 0.0))))
                  (setq rowCount (if (= (type val2) 'STR) (fix (atof val2)) (fix (if val2 val2 0))))
                  (setq dist_total (if (= (type val3) 'STR) (atof val3) (float (if val3 val3 0.0))))
                  (setq dist1 (if (= (type val4) 'STR) (atof val4) (float (if val4 val4 0.0))))
                  (setq dist2 (- dist_total dist1))
                  (princ (strcat "\n[Data] 间距=" (rtos spacing 2 2) " | 副本数=" (itoa rowCount) " | 檩条长度=" (rtos dist_total 2 2)))
                  (vlax-release-object xlSh)
                )
              )
              (if isOpenedByMe (vlax-invoke-method xlApp "Quit") (vlax-release-object xlWb))
            )
          )
          (if (not isOpenedByMe) (progn (vlax-release-object xlWbooks) (vlax-release-object xlApp)))
          (gc)
        )
      )
    )
  )

  (if (and (> dist_total 0) (setq ss_pur (ssget "_X" '((8 . "01Purlin-01,01Purlin-02")))))
    (progn
      (princ "\n[Step 2.5] 正在根据参考段生成完整檩条...")
      (setq mSpace (vla-get-ModelSpace (vla-get-ActiveDocument (vlax-get-acad-object))))
      (setq i 0)
      (repeat (sslength ss_pur)
        (setq en (ssname ss_pur i))
        (setq obj (vlax-ename->vla-object en))
        (setq p1 (vlax-curve-getStartPoint obj)
              p2 (vlax-curve-getEndPoint obj)
              curLayer (vla-get-Layer obj))
        (if (<= (last p1) (last p2)) (setq base_pt p1) (setq base_pt p2))
        (setq newObj (vla-AddLine mSpace 
                        (vlax-3d-point (list (car base_pt) (+ (cadr base_pt) dist1) (caddr base_pt)))
                        (vlax-3d-point (list (car base_pt) (- (cadr base_pt) dist2) (caddr base_pt)))))
        (vla-put-Layer newObj curLayer)
        (vla-delete obj) 
        (setq i (1+ i))
      )
      (princ "\n>>> 檩条线修正完成。")
    )
  )

  (if (> rowCount 0)
    (progn
      (princ "\n[Step 3] 正在对目标图层进行静默阵列...")
      (setq ss (ssget "_X" '((8 . "02Beam,03Brace,04Column"))))
      (if ss
        (progn
          (setq i 1)
          (repeat rowCount
            (setq offset_y (* spacing i -1.0))
            (setq moveVec (vlax-3d-point (list 0.0 offset_y 0.0)))
            (setq j 0)
            (repeat (sslength ss)
              (setq obj (vlax-ename->vla-object (ssname ss j)))
              (setq newObj (vla-copy obj)) 
              (vla-move newObj (vlax-3d-point '(0 0 0)) moveVec) 
              (setq j (1+ j))
            )
            (setq i (1+ i))
          )
          (princ (strcat "\n>>> 阵列完成：已生成 " (itoa rowCount) " 组建模副本。"))
        )
      )
    )
  )

  (setvar "OSMODE" old_osmode)
  (setvar "cmdecho" 1)
  
  (princ "\n[Step 4] 正在导出为 DXF 模型...")
  (setq dwg_full (getvar "DWGNAME"))
  (setq dwg_path (getvar "DWGPREFIX"))
  (setq dxf_name (vl-filename-base dwg_full))
  (setq dxf_path (strcat dwg_path dxf_name ".dxf"))
  
  (setq acadDoc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (_delete-extra-layers acadDoc)
  (princ "\n[Step 4] 正在执行 PU 清理...")
  (command-s "_.-PURGE" "_A" "*" "_N")

  (if (findfile dxf_path) (vl-file-delete dxf_path))
  (command-s "_.SAVEAS" "DXF" "16" dxf_path)
  (princ (strcat "\n>>> 已成功保存至：" dxf_path))

  (princ "\n[Model] 全部任务成功完成！")
  (princ)
)

(princ "\n>>> 脚本已加载成功。命令行输入：MyModel 即可运行。")
(princ)
(princ)
