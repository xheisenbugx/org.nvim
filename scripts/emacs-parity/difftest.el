;;; difftest.el --- Emacs side of the differential test (make difftest)  -*- lexical-binding: t; -*-

;; Loaded after common.el (fixed "now", Org 9.8.10 check) by
;; tests/difftest/emacs.lua, which keeps this Emacs running and talks to
;; it over stdin/stdout, one request per line:
;;
;;   <oracle> TAB <input .org> TAB <output file>
;;
;; For each request it writes what the oracle prints for the input to the
;; output file and answers "done <output file>" on stdout.  An oracle that
;; signals an error writes "!error <message>" as its only line.  EOF on
;; stdin ends the process.  The oracles and their org.nvim counterparts
;; (tests/difftest/oracles.lua) must print the same things:
;;
;;   export-<backend>  org-export-as, body only, Babel off (as export.el),
;;                     broken links marked
;;   agenda            "=== <view>" + the text of a few views over the file
;;   table             the buffer after recalculating every table with a
;;                     #+TBLFM line (org-table-recalculate 'all), top down;
;;                     a table whose formulas signal an error is left as
;;                     it was, followed by an "!error <message>" line
;;   visibility        "=== <step>" + "v"/"h" per line at startup and
;;                     after each of three S-TABs (org-cycle-global), or
;;                     "!error <message>" for a step that signals one

;; the documents are UTF-8, whatever the locale (LC_ALL=C); and the
;; terminal too: org-string-width measures text as displayed, and a C
;; terminal shows non-ASCII characters as octal escapes (table and tag
;; alignment would count 4 columns per byte)
(prefer-coding-system 'utf-8-unix)
(set-terminal-coding-system 'utf-8-unix)
(require 'ox-org)
;; org.nvim always knows habits (agenda.habits)
(require 'org-habit)
(require 'org-table)

(setq org-export-use-babel nil
      org-export-with-broken-links 'mark
      org-html-htmlize-output-type nil
      org-confirm-babel-evaluate nil
      user-full-name "Parity"
      user-mail-address "parity@example.com"
      org-agenda-window-setup 'current-window
      org-agenda-sticky nil
      org-agenda-show-current-time-in-grid nil
      ;; never ask anything: a question would read the next request
      ;; from stdin
      enable-local-variables nil
      revert-without-query '(".*"))

(defconst difftest-agenda-views
  '(("week" . (lambda () (org-agenda-list nil "2026-09-28" 'week)))
    ("day" . (lambda () (org-agenda-list nil "2026-10-01" 'day)))
    ("todo" . (lambda () (org-todo-list nil)))
    ("tags" . (lambda () (org-tags-view nil "work|@ctx")))
    ("tags-todo" . (lambda () (org-tags-view t "home"))))
  "The agenda views of the agenda oracle, by name.")

(defun difftest-agenda-text ()
  "The visible text of the agenda buffer (overlay before-strings included)."
  (let (out)
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
    (apply #'concat (nreverse out))))

(defun difftest-oracle-agenda (file)
  (let ((org-agenda-files (list file))
        (out '()))
    (dolist (view difftest-agenda-views)
      (push (format "=== %s\n" (car view)) out)
      (condition-case err
          (progn
            (funcall (cdr view))
            (push (difftest-agenda-text) out))
        (error (push (format "!error %s\n" (error-message-string err)) out)))
      (when (get-buffer org-agenda-buffer-name)
        (kill-buffer org-agenda-buffer-name)))
    (apply #'concat (nreverse out))))

(defun difftest-oracle-export (file backend)
  ;; the same reference ids on every run
  (random "org-parity")
  (with-temp-buffer
    (insert-file-contents file)
    (setq default-directory (file-name-directory file)
          buffer-file-name file)
    (org-mode)
    (unwind-protect (org-export-as backend nil nil t)
      (set-buffer-modified-p nil)
      (setq buffer-file-name nil))))

(defun difftest-oracle-table (file)
  ;; a table whose recalculation signals an error is put back as it was
  ;; and followed by an "!error <message>" line: the other tables are
  ;; still compared (tests/difftest/compare.lua)
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*|" nil t)
      (let ((beg (line-beginning-position))
            (end (org-table-end)))
        (goto-char end)
        (if (not (looking-at-p "[ \t]*#\\+TBLFM:"))
            (forward-line 1)
          (let ((saved (buffer-substring beg (line-beginning-position 2))))
            (condition-case err
                (progn
                  (goto-char (1- end))
                  (org-table-recalculate 'all)
                  (goto-char (org-table-end))
                  (forward-line 1))
              (error
               (goto-char beg)
               (re-search-forward "^[ \t]*#\\+TBLFM:.*\n?" nil t)
               (delete-region beg (point))
               (goto-char beg)
               (insert saved)
               (unless (bolp) (insert "\n"))
               (insert (format "!error %s\n"
                               (replace-regexp-in-string
                                "\n" " " (error-message-string err))))))))))
    (buffer-string)))

(defun difftest-visibility-lines ()
  (let (out)
    (goto-char (point-min))
    (while (not (eobp))
      (let ((bol (line-beginning-position)))
        (push (format "%s %s\n"
                      (if (and (> bol 1) (org-invisible-p (1- bol))) "h" "v")
                      (buffer-substring-no-properties bol (line-end-position)))
              out))
      (forward-line 1))
    (apply #'concat (nreverse out))))

(defun difftest-oracle-visibility (file)
  ;; S-TAB as `org-cycle-global': `org-shifttab' at point-min moves to
  ;; the previous table field when the file starts with a table (and
  ;; signals an error there)
  (let ((buf (find-file-noselect file))
        (out '())
        (last 'none))
    (unwind-protect
        (with-current-buffer buf
          (push "=== startup\n" out)
          (push (difftest-visibility-lines) out)
          (dotimes (i 3)
            (goto-char (point-min))
            (push (format "=== S%d\n" (1+ i)) out)
            (condition-case err
                (progn
                  (let ((last-command last) (this-command 'org-cycle-global))
                    (call-interactively #'org-cycle-global))
                  (setq last 'org-cycle-global)
                  (push (difftest-visibility-lines) out))
              (error
               (setq last 'none)
               (push (format "!error %s\n" (error-message-string err)) out)))))
      (kill-buffer buf))
    (apply #'concat (nreverse out))))

(defun difftest-run (oracle file)
  "What ORACLE prints for FILE."
  (cond
   ((string-prefix-p "export-" oracle)
    (difftest-oracle-export file (intern (substring oracle 7))))
   ((equal oracle "agenda") (difftest-oracle-agenda file))
   ((equal oracle "table") (difftest-oracle-table file))
   ((equal oracle "visibility") (difftest-oracle-visibility file))
   (t (error "Unknown oracle %s" oracle))))

(defun difftest-prompt (&rest args)
  (error "Prompted: %S" (car args)))

(defun difftest-serve ()
  "Answer requests from stdin until EOF."
  (let (line)
    (while (setq line (condition-case nil (read-from-minibuffer "") (error nil)))
      (let* ((parts (split-string line "\t"))
             (oracle (nth 0 parts))
             (file (nth 1 parts))
             (outfile (nth 2 parts))
             (result (condition-case err
                         ;; a prompt would read the next request from stdin
                         (cl-letf (((symbol-function 'read-from-minibuffer) #'difftest-prompt)
                                   ((symbol-function 'read-string) #'difftest-prompt)
                                   ((symbol-function 'yes-or-no-p) #'difftest-prompt)
                                   ((symbol-function 'y-or-n-p) #'difftest-prompt)
                                   ((symbol-function 'read-char) #'difftest-prompt)
                                   ((symbol-function 'read-char-exclusive) #'difftest-prompt)
                                   ((symbol-function 'read-event) #'difftest-prompt))
                           (difftest-run oracle file))
                       (error (format "!error %s\n" (error-message-string err))))))
        ;; the agenda leaves the file visited: forget it, a later request
        ;; may use the same name for other contents
        (let ((buf (get-file-buffer file)))
          (when buf
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
        (let ((coding-system-for-write 'utf-8-unix))
          (make-directory (file-name-directory outfile) t)
          (with-temp-file outfile (insert result)))
        (princ (format "done %s\n" outfile))))))

(difftest-serve)
;;; difftest.el ends here
