;;; common.el --- shared setup for the Emacs parity fixture generators  -*- lexical-binding: t; -*-

;; Loaded first by every generator (see generate.sh).  It makes Emacs runs
;; deterministic: a fixed "now", no user config (emacs -Q), and the
;; environment set by generate.sh (TZ=UTC0, LC_ALL=C).

;; Defaults that depend on the display (the agenda time grid's ┄, the
;; block separator's ─, ...) are computed when the libraries load: give
;; them the values of a graphical Emacs (what org.nvim follows), not the
;; ASCII fallbacks of a batch terminal.
(require 'cl-lib)
(cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
          ((symbol-function 'char-displayable-p) (lambda (&rest _) t)))
  (dolist (lib '(org org-agenda org-clock org-lint ox ox-ascii ox-html ox-latex ox-md))
    (require lib)))
;; Help strings ("Press ‘C-u r’ ...") with curved quotes, as in a GUI.
(setq text-quoting-style 'curve)
(require 'subr-x)

(unless (string-prefix-p "9.8.10" (org-version))
  (error "Expected Org 9.8.10, got %s (set ORG_DIR)" (org-version)))

(defconst parity-root (file-name-as-directory (getenv "PARITY_ROOT"))
  "The repository root.")

(defconst parity-fixtures (expand-file-name "tests/fixtures/emacs/" parity-root)
  "Where the inputs live and the expected outputs are written.")

;;; A fixed "now": 2026-10-01 Thu 12:00 local time (the specs use the same).
(defconst parity-now (encode-time (list 0 0 12 1 10 2026 nil nil nil)))

(advice-add 'current-time :override (lambda () parity-now))
(advice-add 'org-today :override (lambda () (time-to-days parity-now)))
(dolist (fn '(format-time-string decode-time float-time time-to-days))
  (advice-add fn :filter-args
              (lambda (args)
                ;; (fn FORMAT-STRING TIME ...) or (fn TIME ...): fill a nil time
                (if (eq fn 'format-time-string)
                    (if (and (cdr args) (cadr args)) args
                      (append (list (car args) parity-now) (cddr args)))
                  (if (car args) args (cons parity-now (cdr args)))))))
(advice-add 'time-since :override
            (lambda (time) (time-subtract parity-now time)))

;; Quiet, side-effect free batch runs
(setq make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      org-id-locations-file (make-temp-file "parity-ids")
      org-id-track-globally nil
      inhibit-message t
      system-time-locale "C")

(defun parity-read-file (file)
  "Contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun parity-write (file string)
  "Write STRING to FILE (LF line endings, UTF-8)."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert string)))
  (princ (format "wrote %s\n" (file-relative-name file parity-root))
         #'external-debugging-output))

(defun parity-read-cases (file)
  "The non-comment lines of FILE, split on whitespace."
  (let (cases)
    (dolist (line (split-string (parity-read-file file) "\n" t))
      (unless (string-match-p "\\`\\s-*\\(#\\|\\'\\)" line)
        (push (split-string line) cases)))
    (nreverse cases)))

(provide 'parity-common)
;;; common.el ends here
