;;; lint.el --- expected org-lint reports  -*- lexical-binding: t; -*-

;; Lint examples/*.org and tests/fixtures/emacs/lint/*.org with every
;; default checker and print one "=== <file>" section per file, a report
;; per line: "<line>:<col> [<checker>] <message>".

;; Every Babel language Org ships, as with a configured Emacs: the
;; header-argument checkers know the language-specific arguments (:async
;; of ob-shell, ...) only once its ob-<lang> library is loaded.
(dolist (f (directory-files (file-name-directory (locate-library "ob-core")) nil
                            "\\`ob-[a-z0-9+-]+\\.elc?\\'"))
  (ignore-errors (require (intern (file-name-sans-extension f)))))

(let* ((dir (expand-file-name "lint/" parity-fixtures))
       (files (append (directory-files (expand-file-name "examples/" parity-root) t "\\.org\\'")
                      (directory-files dir t "\\.org\\'")))
       (out '()))
  (dolist (f files)
    (let ((buf (find-file-noselect f)))
      (push (format "=== %s\n" (file-relative-name f parity-root)) out)
      (with-current-buffer buf
        (dolist (r (org-lint--generate-reports (current-buffer) org-lint--checkers))
          (let* ((v (cadr r))
                 (m (get-text-property 0 'org-lint-marker (aref v 0))))
            (push (format "%d:%d [%s] %s\n"
                          (line-number-at-pos m)
                          (save-excursion (goto-char m) (1+ (current-column)))
                          (org-lint-checker-name (aref v 3))
                          (replace-regexp-in-string "\n" " " (aref v 2)))
                  out))))
      (kill-buffer buf)))
  (parity-write (expand-file-name "expected.txt" dir) (apply #'concat (nreverse out))))
