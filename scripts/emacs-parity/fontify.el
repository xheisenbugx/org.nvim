;;; fontify.el --- expected emphasis faces and hidden text  -*- lexical-binding: t; -*-

;; Fontify examples/*.org and tests/fixtures/emacs/fontify/*.org with
;; org-hide-emphasis-markers on and print one "=== <file>" section per
;; file: per line with emphasis or hidden text, "<line>\t<runs>". A run is
;; "<count><code>": "." for nothing, else the emphasis faces of the bytes
;; (b bold, i italic, u underline, s strike-through, v org-verbatim, c
;; org-code), then "#" when they are invisible (emphasis markers, link
;; brackets and paths). Columns count bytes, as in Neovim.

(setq org-hide-emphasis-markers t)

(defun fontify-code (pos)
  "The code of the character at POS."
  (let* ((f (get-text-property pos 'face))
         (fs (if (and (listp f) (not (keywordp (car-safe f)))) f (list f)))
         (k ""))
    (when (memq 'bold fs) (setq k (concat k "b")))
    (when (memq 'italic fs) (setq k (concat k "i")))
    (when (memq 'underline fs) (setq k (concat k "u")))
    (when (member '(:strike-through t) fs) (setq k (concat k "s")))
    (when (memq 'org-verbatim fs) (setq k (concat k "v")))
    (when (memq 'org-code fs) (setq k (concat k "c")))
    ;; (emphasis markers: t; link brackets and paths: org-link; not folds)
    (when (memq (get-text-property pos 'invisible) '(t org-link)) (setq k (concat k "#")))
    (if (string= k "") "." k)))

(defun fontify-line ()
  "The runs of the current line, or nil when it has no face or hidden text."
  (let ((runs '()) (cur nil) (n 0) (any nil)
        (end (line-end-position)))
    (goto-char (line-beginning-position))
    (while (< (point) end)
      (let ((code (fontify-code (point)))
            (bytes (string-bytes (string (char-after)))))
        (unless (string= code ".") (setq any t))
        (if (equal code cur)
            (setq n (+ n bytes))
          (when cur (push (format "%d%s" n cur) runs))
          (setq cur code n bytes)))
      (forward-char))
    (when cur (push (format "%d%s" n cur) runs))
    (and any (mapconcat #'identity (nreverse runs) ","))))

(let* ((dir (expand-file-name "fontify/" parity-fixtures))
       (files (append (directory-files (expand-file-name "examples/" parity-root) t "\\.org\\'")
                      (directory-files dir t "\\.org\\'")))
       (out '()))
  (dolist (f files)
    (with-temp-buffer
      (insert-file-contents f)
      (org-mode)
      ;; (#+STARTUP: overview and the like fold the file)
      (org-fold-show-all)
      (font-lock-ensure)
      (push (format "=== %s\n" (file-relative-name f parity-root)) out)
      (goto-char (point-min))
      (let ((lnum 1))
        (while (not (eobp))
          (let ((runs (save-excursion (fontify-line))))
            (when runs (push (format "%d\t%s\n" lnum runs) out)))
          (forward-line 1)
          (setq lnum (1+ lnum))))))
  (parity-write (expand-file-name "expected.txt" dir) (apply #'concat (nreverse out))))
