;;; clocktable.el --- expected clock tables  -*- lexical-binding: t; -*-

;; Update every dynamic block of tests/fixtures/emacs/clocktable/tables.org
;; (org-update-all-dblocks) and write the result to tables.expected.org,
;; with the fixture directory in links written as @DIR@/.

(let* ((dir (expand-file-name "clocktable/" parity-fixtures))
       (buf (find-file-noselect (expand-file-name "tables.org" dir))))
  (with-current-buffer buf
    (org-update-all-dblocks)
    (parity-write (expand-file-name "tables.expected.org" dir)
                  (replace-regexp-in-string (regexp-quote dir) "@DIR@/" (buffer-string) t t))
    (set-buffer-modified-p nil))
  (kill-buffer buf))
