(vl-load-com)

;; vl-file-systime 结果（年 月 星期 日 时 分 秒 毫秒）-> 可比较的数值
(defun MyModel_SystimeKey (st)
  (if st
    (+ (* (nth 0 st) 1e10) (* (nth 1 st) 1e8) (* (nth 3 st) 1e6)
       (* (nth 4 st) 1e4) (* (nth 5 st) 1e2) (nth 6 st))
    0.0
  )
)

;; 列出目录下的 Excel 文件：排除 ~$ 临时锁文件，按修改时间从新到旧排序（同时间按名称）
(defun MyModel_ListExcelFiles (dir / names)
  (foreach nm (vl-directory-files dir "*.xls*" 1)
    (if (/= (substr nm 1 2) "~$")
      (setq names (cons nm names))
    )
  )
  (vl-sort names
           '(lambda (a b / ka kb)
              (setq ka (MyModel_SystimeKey (vl-file-systime (strcat dir a)))
                    kb (MyModel_SystimeKey (vl-file-systime (strcat dir b))))
              (if (= ka kb) (< (strcase a) (strcase b)) (> ka kb))))
)

;; 工作表名“阵列计算”：先按 GBK 字节构造（中文代码页），再按 Unicode 码点构造（AutoCAD 2021+）
(defun MyModel_TargetSheetNames ( / names uni)
  (setq names (list (vl-list->string '(213 243 193 208 188 198 203 227))))
  (setq uni (vl-catch-all-apply '(lambda () (apply 'strcat (mapcar 'chr '(38453 21015 35745 31639))))))
  (if (and (not (vl-catch-all-error-p uni)) (= (type uni) 'STR) (not (member uni names)))
    (setq names (append names (list uni)))
  )
  names
)

(defun c:MyModel (/ *error* xlApp xlWbooks xlWb xlSh xlPath spacing rowCount ss ss_all i offset_y old_osmode
                   old_cmdecho pt0 pt1 targetWbName tempWb wbCount i_wb isOpenedByMe wbOpenedByMe obj newObj moveVec
                   dist1 dist2 dist_total ss_pur en p1 p2 base_pt mSpace j failCount sheetName
                   curLayer dwg_dir excel_files dwg_full dwg_path dxf_name dxf_path acadDoc ans
                   _collect-curve-layers _erase-entities-outside _layer-name-list
                   _prepare-layers-for-delete _delete-extra-layers _close-excel _cell-num)

  ;; 关闭/释放 Excel：只关闭本脚本打开的工作簿，只退出本脚本启动的 Excel 实例
  (defun _close-excel (/ o)
    (if (and xlWb wbOpenedByMe (= (type xlWb) 'VLA-OBJECT))
      (vl-catch-all-apply 'vlax-invoke-method (list xlWb "Close" :vlax-false))
    )
    (if (and xlApp isOpenedByMe (= (type xlApp) 'VLA-OBJECT))
      (vl-catch-all-apply 'vlax-invoke-method (list xlApp "Quit"))
    )
    (foreach o (list xlSh xlWb xlWbooks xlApp)
      (if (and (= (type o) 'VLA-OBJECT) (not (vlax-object-released-p o)))
        (vl-catch-all-apply 'vlax-release-object (list o))
      )
    )
    (setq xlSh nil xlWb nil xlWbooks nil xlApp nil isOpenedByMe nil wbOpenedByMe nil)
    (gc)
  )

  (defun *error* (msg)
    (_close-excel)
    (if old_osmode (setvar "OSMODE" old_osmode))
    (if old_cmdecho (setvar "CMDECHO" old_cmdecho))
    (if acadDoc (vl-catch-all-apply 'vla-EndUndoMark (list acadDoc)))
    (if (not (wcmatch (strcase (vl-princ-to-string msg)) "*CANCEL*,*QUIT*,*EXIT*"))
      (princ (strcat "\n[ERR] " (vl-princ-to-string msg)))
    )
    (princ)
  )

  ;; 读取单元格数值：字符串转数值，空/错误返回 0.0
  (defun _cell-num (sh addr / v)
    (setq v (vl-catch-all-apply
              '(lambda (/ r val)
                 (setq r (vlax-get-property sh "Range" addr)
                       val (vlax-variant-value (vlax-get-property r "Value2")))
                 (vlax-release-object r)
                 val)))
    (cond ((vl-catch-all-error-p v) 0.0)
          ((= (type v) 'STR) (atof v))
          ((numberp v) (float v))
          (T 0.0))
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

  ;; 删除不在 keepLayers 中的图层上的全部对象（按图层名精确比较，不作通配匹配；外部参照图层除外）
  (defun _erase-entities-outside (keepLayers / ss_all_e idx en layName removedCount)
    (setq removedCount 0)
    (if (setq ss_all_e (ssget "_X"))
      (progn
        (setq idx 0)
        (repeat (sslength ss_all_e)
          (setq en (ssname ss_all_e idx)
                layName (cdr (assoc 8 (entget en))))
          (if (and (/= (strcase layName) "0")
                   (not (member (strcase layName) keepLayers))
                   (not (wcmatch layName "*|*"))
                   (not (vl-catch-all-error-p
                          (vl-catch-all-apply 'vla-delete (list (vlax-ename->vla-object en))))))
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

    (setq removedCount (_erase-entities-outside keepLayers))

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

  ;; 0. 前置检查：图纸必须已保存（DWGPREFIX 才是真实目录）；防止对同一模型重复旋转
  (if (= (getvar "DWGTITLED") 0)
    (progn
      (princ "\n[ERR] 当前图纸尚未保存，请先保存到 Excel 所在文件夹后再运行 MyModel。")
      (exit)
    )
  )
  (setq acadDoc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (if (or (= (strcase (cond ((vl-filename-extension (getvar "DWGNAME"))) (""))) ".DXF")
          (vlax-ldata-get "MyModel" "Rotated"))
    (progn
      (princ "\n[Warn] 当前图纸已由 MyModel 处理过（或为导出的 DXF），再次运行会重复旋转 90 度。")
      (initget "Yes No")
      (setq ans (getkword "\n仍要继续吗？[Yes/No] <No>: "))
      (if (/= ans "Yes") (progn (princ "\n>>> 已取消。") (exit)))
    )
  )

  (vla-StartUndoMark acadDoc)
  (setq old_osmode (getvar "OSMODE")
        old_cmdecho (getvar "CMDECHO"))
  (setvar "OSMODE" 0)
  (setvar "CMDECHO" 0)
  (princ "\n[System] 正在初始化自动化建模脚本...")

  ;; 1. 执行三维旋转（仅模型空间；先解锁图层，避免锁定图层上的对象旋转失败）
  (princ "\n[Step 1] 正在执行全选并绕 X 轴旋转 90 度...")
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
      (princ "\n>>> 旋转步骤完成。")
      (if (> failCount 0)
        (princ (strcat "\n[Warn] 有 " (itoa failCount) " 个对象旋转失败，请检查。"))
      )
    )
  )

  ;; 2. 读取 Excel 参数
  (princ "\n[Step 2] 正在连接 Excel 获取参数...")

  (setq dwg_dir (getvar "DWGPREFIX"))
  (setq excel_files (MyModel_ListExcelFiles dwg_dir))

  (if excel_files
    (progn
      (setq targetWbName (car excel_files))
      (setq xlPath (strcat dwg_dir targetWbName))
      (princ (strcat "\n[System] 已自动匹配 Excel：" targetWbName))
      (if (> (length excel_files) 1)
        (princ (strcat "\n[Warn] 文件夹下有 " (itoa (length excel_files)) " 个 Excel 文件，已选用最新修改的一个。"))
      )
    )
    (progn
      (setq xlPath nil targetWbName "")
      (princ "\n[Warn] 当前文件夹下未发现任何 Excel 文件！")
    )
  )

  (setq spacing 0.0 rowCount 0 dist_total 0.0 dist1 0.0 dist2 0.0
        xlWb nil xlApp nil isOpenedByMe nil wbOpenedByMe nil)

  (if (and xlPath (findfile xlPath))
    (progn
      ;; 优先接管已运行的 Excel；没有才新建（新建的实例结束时退出）
      (setq xlApp (vl-catch-all-apply 'vlax-get-object (list "Excel.Application")))
      (if (or (null xlApp) (vl-catch-all-error-p xlApp))
        (progn
          (setq xlApp (vl-catch-all-apply 'vlax-create-object (list "Excel.Application")))
          (if (vl-catch-all-error-p xlApp) (setq xlApp nil))
          (if xlApp
            (progn
              (setq isOpenedByMe T)
              (vl-catch-all-apply 'vlax-put-property (list xlApp "DisplayAlerts" :vlax-false))
            )
          )
        )
      )

      (if xlApp
        (progn
          (setq xlWbooks (vlax-get-property xlApp "Workbooks"))
          (setq wbCount (vlax-get-property xlWbooks "Count"))
          (setq i_wb 1)
          ;; 按完整路径匹配已打开的工作簿，避免误用其他文件夹下的同名文件
          (while (and (<= i_wb wbCount) (null xlWb))
            (setq tempWb (vlax-get-property xlWbooks "Item" i_wb))
            (if (= (strcase (vlax-get-property tempWb "FullName")) (strcase xlPath))
                (setq xlWb tempWb)
                (vlax-release-object tempWb)
            )
            (setq i_wb (1+ i_wb))
          )
          (if (null xlWb)
            (progn
              (setq xlWb (vl-catch-all-apply 'vlax-invoke-method (list xlWbooks "Open" xlPath)))
              (if (vl-catch-all-error-p xlWb)
                (progn
                  (princ (strcat "\n[Warn] 无法打开 Excel：" (vl-catch-all-error-message xlWb)))
                  (setq xlWb nil)
                )
                (setq wbOpenedByMe T)
              )
            )
          )

          (if xlWb
            (progn
              (foreach sheetName (MyModel_TargetSheetNames)
                (if (null xlSh)
                  (progn
                    (setq xlSh (vl-catch-all-apply 'vlax-get-property (list (vlax-get-property xlWb "Sheets") "Item" sheetName)))
                    (if (vl-catch-all-error-p xlSh) (setq xlSh nil))
                  )
                )
              )
              (if xlSh
                (progn
                  (setq spacing    (_cell-num xlSh "C14"))
                  (setq rowCount   (fix (+ (_cell-num xlSh "C15") 0.5)))
                  (setq dist_total (_cell-num xlSh "C13"))
                  (setq dist1      (_cell-num xlSh "C16"))
                  (setq dist2 (- dist_total dist1))
                  (princ (strcat "\n[Data] 间距=" (rtos spacing 2 2) " | 副本数=" (itoa rowCount) " | 檩条长度=" (rtos dist_total 2 2)))
                )
                (princ "\n[Warn] Excel 中未找到工作表“阵列计算”，跳过檩条与阵列步骤。")
              )
            )
          )
        )
        (princ "\n[Warn] 无法启动 Excel，跳过檩条与阵列步骤。")
      )
      (_close-excel)
    )
  )

  (if (and (> dist_total 0) (or (< dist1 0) (> dist1 dist_total)))
    (princ "\n[Warn] C16 不在 0 ~ C13 范围内，檩条一侧将反向伸出，请核对 Excel。")
  )

  (if (and (> dist_total 0) (setq ss_pur (ssget "_X" '((410 . "Model") (0 . "LINE,LWPOLYLINE,POLYLINE") (8 . "*[Pp][Uu][Rr][Ll][Ii][Nn]*")))))
    (progn
      (princ "\n[Step 2.5] 正在根据参考段生成完整檩条...")
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
                        (vlax-3d-point (list (car base_pt) (+ (cadr base_pt) dist1) (caddr base_pt)))
                        (vlax-3d-point (list (car base_pt) (- (cadr base_pt) dist2) (caddr base_pt)))))
        (vla-put-Layer newObj curLayer)
        (vla-delete obj)
        (setq i (1+ i))
      )
      (princ "\n>>> 檩条线修正完成。")
    )
  )

  (if (and (> rowCount 0) (<= spacing 0))
    (princ "\n[Warn] 间距 C14 不大于 0，跳过阵列步骤。")
  )
  (if (and (> rowCount 0) (> spacing 0))
    (progn
      (princ "\n[Step 3] 正在对目标图层进行静默阵列...")
      (setq ss (ssget "_X" '((410 . "Model") (0 . "LINE,ARC,CIRCLE,ELLIPSE,LWPOLYLINE,POLYLINE,SPLINE")
                                (-4 . "<NOT") (8 . "*[Pp][Uu][Rr][Ll][Ii][Nn]*") (-4 . "NOT>"))))
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

  (princ "\n[Step 4] 正在导出为 DXF 模型...")
  (setq dwg_full (getvar "DWGNAME"))
  (setq dwg_path (getvar "DWGPREFIX"))
  (setq dxf_name (vl-filename-base dwg_full))
  (setq dxf_path (strcat dwg_path dxf_name ".dxf"))

  (_delete-extra-layers acadDoc)
  (princ "\n[Step 4] 正在执行 PU 清理...")
  (command-s "_.-PURGE" "_A" "*" "_N")

  (vla-EndUndoMark acadDoc)
  (if (and (findfile dxf_path)
           (/= (strcase dxf_path) (strcase (strcat dwg_path dwg_full)))
           (not (vl-file-delete dxf_path)))
    (princ (strcat "\n[ERR] 无法覆盖 " dxf_path "（文件可能被占用），未导出 DXF。"))
    (progn
      ;; 当前文件本身就是该 DXF 时，SAVEAS 会询问是否替换
      (if (= (strcase dxf_path) (strcase (strcat dwg_path dwg_full)))
        (command-s "_.SAVEAS" "DXF" "16" dxf_path "_Y")
        (command-s "_.SAVEAS" "DXF" "16" dxf_path)
      )
      (princ (strcat "\n>>> 已成功保存至：" dxf_path))
    )
  )

  (setvar "OSMODE" old_osmode)
  (setvar "CMDECHO" old_cmdecho)
  (princ "\n[Model] 全部任务成功完成！")
  (princ)
)

(princ "\n>>> 脚本已加载成功。命令行输入：MyModel 即可运行。")
(princ)
