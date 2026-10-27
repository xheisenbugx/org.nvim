;;; faces.el --- expected faces and hidden text, every face  -*- lexical-binding: t; -*-

;; Fontify examples/*.org, tests/fixtures/emacs/fontify/*.org and
;; tests/fixtures/emacs/faces/*.org (or the files in FACES_FILES, separated
;; by spaces) and write, per input, tests/fixtures/emacs/faces/expected/
;; <path with / as ->.txt: per line with a face or hidden text,
;; "<line>\t<runs>". A run is "<count>:<code>": "." for nothing, else the
;; faces of the bytes ("org-" left out, sorted, joined by "+"; an anonymous
;; face is "strike-through" for (:strike-through t), else "anon"), then "#"
;; when they are invisible (emphasis markers, link brackets and paths).
;; org-hide-emphasis-markers is on; the rest are Org's defaults. Columns
;; count bytes, as in Neovim.

(setq org-hide-emphasis-markers t)

(defun faces-names (f)
  "The names of face property value F."
  (cond ((null f) nil)
        ((symbolp f) (list (string-remove-prefix "org-" (symbol-name f))))
        ((and (consp f) (keywordp (car f)))
         (list (if (equal f '(:strike-through t)) "strike-through" "anon")))
        ((consp f) (apply #'append (mapcar #'faces-names f)))))

(defun faces-code (pos)
  "The code of the character at POS."
  (let* ((names (delete-dups (sort (faces-names (get-text-property pos 'face)) #'string<)))
         (code (if names (mapconcat #'identity names "+") "."))
         (inv (memq (get-text-property pos 'invisible) '(t org-link))))
    (if inv (concat (if (string= code ".") "" code) "#") code)))

(defun faces-line ()
  "The runs of the current line, or nil when it has no face or hidden text."
  (let ((runs '()) (cur nil) (n 0) (any nil)
        (end (line-end-position)))
    (goto-char (line-beginning-position))
    (while (< (point) end)
      (let ((code (faces-code (point)))
            (bytes (string-bytes (string (char-after)))))
        (unless (string= code ".") (setq any t))
        (if (equal code cur)
            (setq n (+ n bytes))
          (when cur (push (format "%d:%s" n cur) runs))
          (setq cur code n bytes)))
      (forward-char))
    (when cur (push (format "%d:%s" n cur) runs))
    (and any (mapconcat #'identity (nreverse runs) ","))))

(let* ((dir (expand-file-name "faces/" parity-fixtures))
       (out-dir (expand-file-name "expected/" dir))
       (only (getenv "FACES_FILES"))
       (files (if (and only (not (string= only "")))
                  (mapcar (lambda (f) (expand-file-name f parity-root)) (split-string only))
                (append (directory-files (expand-file-name "examples/" parity-root) t "\\.org\\'")
                        (directory-files (expand-file-name "fontify/" parity-fixtures) t "\\.org\\'")
                        (directory-files dir t "\\.org\\'")))))
  (make-directory out-dir t)
  (dolist (f files)
    (let ((out '()))
      (with-temp-buffer
        (insert-file-contents f)
        (org-mode)
        ;; (#+STARTUP: overview and the like fold the file)
        (org-fold-show-all)
        (font-lock-ensure)
        (goto-char (point-min))
        (let ((lnum 1))
          (while (not (eobp))
            (let ((runs (save-excursion (faces-line))))
              (when runs (push (format "%d\t%s\n" lnum runs) out)))
            (forward-line 1)
            (setq lnum (1+ lnum)))))
      (parity-write (expand-file-name
                     (concat (replace-regexp-in-string "/" "-" (file-relative-name f parity-root)) ".txt")
                     out-dir)
                    (apply #'concat (nreverse out))))))
