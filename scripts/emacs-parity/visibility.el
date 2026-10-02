;;; visibility.el --- expected visibility after startup and TAB/S-TAB  -*- lexical-binding: t; -*-

;; For each case of tests/fixtures/emacs/visibility/cases.txt: open the
;; file (startup visibility), run the commands, and print every line as
;; "v <line>" (visible) or "h <line>" (hidden: the newline before it is
;; invisible).

(let* ((dir (expand-file-name "visibility/" parity-fixtures))
       (out '()))
  (dolist (case (parity-read-cases (expand-file-name "cases.txt" dir)))
    (let* ((name (nth 0 case))
           (file (expand-file-name (nth 1 case) dir))
           (cmds (delete "-" (nthcdr 2 case)))
           (buf (find-file-noselect file))
           (last 'none))
      (with-current-buffer buf
        (dolist (c cmds)
          (cond
           ((string-prefix-p "L" c)
            (goto-char (point-min))
            (forward-line (1- (string-to-number (substring c 1))))
            (setq last 'goto))
           ((string= c "T")
            (let ((last-command last) (this-command 'org-cycle)) (org-cycle))
            (setq last 'org-cycle))
           ((string= c "S")
            (let ((last-command last) (this-command 'org-shifttab)) (org-shifttab))
            (setq last 'org-shifttab))
           (t (error "Unknown command %s" c))))
        (push (format "=== %s\n" name) out)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((bol (line-beginning-position)))
            (push (format "%s %s\n"
                          (if (and (> bol 1) (org-invisible-p (1- bol))) "h" "v")
                          (buffer-substring-no-properties bol (line-end-position)))
                  out))
          (forward-line 1)))
      (kill-buffer buf)))
  (parity-write (expand-file-name "expected.txt" dir) (apply #'concat (nreverse out))))
