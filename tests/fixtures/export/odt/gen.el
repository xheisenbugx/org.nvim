;; -*- lexical-binding: t -*-
;; Regenerate the Emacs reference content.xml bodies of the ODT fixtures:
;;   cd tests/fixtures/export/odt
;;   emacs -Q --batch -l gen.el basic.org features.org images.org math.org
(require 'ox-odt)
(setq org-odt-fontify-srcblocks nil)
(setq user-full-name "Tester")
(dolist (f command-line-args-left)
  ;; only math.org uses the (fake) LaTeX to MathML converter
  (setq org-latex-to-mathml-convert-command
        (and (equal f "math.org")
             (concat "sh " (expand-file-name "fakemml.sh") " %I %o")))
  (find-file f)
  (let ((out (org-odt-export-to-odt)))
    (with-temp-buffer
      (call-process "unzip" nil t nil "-p" out "content.xml")
      (goto-char (point-min))
      (search-forward "<office:body>")
      (delete-region (point-min) (match-beginning 0))
      (write-region nil nil (concat (file-name-sans-extension f) ".emacs.xml")))
    (delete-file out)))
(delete-directory "ltxmathml" t)
(setq command-line-args-left nil)
