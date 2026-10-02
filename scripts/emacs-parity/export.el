;;; export.el --- expected exports of examples/*.org  -*- lexical-binding: t; -*-

;; Export the files of tests/fixtures/emacs/export/cases.txt (paths
;; relative to the repository root) body-only, without evaluating Babel,
;; to each listed backend and write tests/fixtures/emacs/export/<name>.<ext>,
;; the repository root in paths written as @ROOT@/.

(setq org-export-use-babel nil
      org-html-htmlize-output-type nil
      user-full-name "Parity"
      user-mail-address "parity@example.com")

(defconst parity-export-ext '(("ascii" . "txt") ("html" . "html") ("latex" . "tex") ("md" . "md")))

(let ((dir (expand-file-name "export/" parity-fixtures)))
  (dolist (case (parity-read-cases (expand-file-name "cases.txt" dir)))
    (let* ((file (expand-file-name (car case) parity-root))
           (name (file-name-base file)))
      (dolist (backend (cdr case))
        ;; the same reference ids ("orgXXXXXXX") on every run
        (random "org-parity")
        (condition-case err
            (let ((out (with-temp-buffer
                         (insert-file-contents file)
                         (setq default-directory (file-name-directory file)
                               buffer-file-name file)
                         (org-mode)
                         (unwind-protect (org-export-as (intern backend) nil nil t)
                           (set-buffer-modified-p nil)
                           (setq buffer-file-name nil)))))
              (parity-write (expand-file-name
                             (format "%s.%s" name (cdr (assoc backend parity-export-ext))) dir)
                            (replace-regexp-in-string (regexp-quote parity-root) "@ROOT@/" out t t)))
          ;; listed in cases.txt by mistake: say so, go on with the others
          (error (princ (format "FAILED %s %s: %S\n" name backend err)
                        #'external-debugging-output)))))))
