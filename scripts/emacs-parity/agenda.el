;;; agenda.el --- expected agenda views  -*- lexical-binding: t; -*-

;; For each case of tests/fixtures/emacs/agenda/cases.txt: build the view
;; over work.org and home.org with default settings and print its visible
;; text (overlay before-strings included).

(require 'org-agenda)

(let* ((dir (expand-file-name "agenda/" parity-fixtures))
       (out '()))
  (setq org-agenda-files (list (expand-file-name "work.org" dir)
                               (expand-file-name "home.org" dir))
        org-agenda-window-setup 'current-window
        org-agenda-sticky nil
        ;; the current-time line depends on the clock: off on both sides
        org-agenda-show-current-time-in-grid nil)
  (dolist (case (parity-read-cases (expand-file-name "cases.txt" dir)))
    (let ((name (nth 0 case))
          (kind (nth 1 case))
          (a (nth 2 case))
          (b (nth 3 case)))
      (let ((org-agenda-start-with-log-mode (equal kind "log")))
        (pcase kind
          ((or "agenda" "log") (org-agenda-list nil b (intern a)))
          ("todo" (org-todo-list (if (equal a "-") nil a)))
          ("tags" (org-tags-view nil a))
          ("tags-todo" (org-tags-view t a))
          ("search" (org-search-view nil a))
          (_ (error "Unknown kind %s" kind))))
      (push (format "=== %s\n" name) out)
      (with-current-buffer org-agenda-buffer-name
        (goto-char (point-min))
        (while (not (eobp))
          (let ((bol (line-beginning-position)))
            (dolist (ov (overlays-in bol (line-end-position)))
              (when (overlay-get ov 'before-string)
                (push (substring-no-properties (overlay-get ov 'before-string)) out)))
            (unless (invisible-p bol)
              (push (concat (buffer-substring-no-properties bol (line-end-position)) "\n") out)))
          (forward-line 1)))
      (kill-buffer org-agenda-buffer-name)))
  (parity-write (expand-file-name "expected.txt" dir) (apply #'concat (nreverse out))))
