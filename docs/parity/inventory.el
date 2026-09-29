;;; inventory.el --- List every Org command and user option  -*- lexical-binding: t; -*-

;; Loads every library of an Org source tree and writes commands.tsv
;; (interactive commands) and options.tsv (defcustoms), one
;; "LIBRARY<TAB>SYMBOL" line each, sorted.  Obsolete aliases are skipped.
;;
;;   emacs -Q --batch -l docs/parity/inventory.el \
;;     --eval '(org-parity-inventory "/path/to/org-9.8.10/" "out/")'
;;
;; The inventory in inventory.tsv was made from Org 9.8.10.

(defun org-parity-inventory (org-dir out-dir)
  "Write commands.tsv and options.tsv for the Org sources in ORG-DIR to OUT-DIR."
  (setq load-prefer-newer t)
  (add-to-list 'load-path org-dir)
  (require 'org)
  (dolist (f (directory-files org-dir nil "^\\(org\\|ox\\|ob\\|ol\\|oc\\)[-a-zA-Z0-9]*\\.el$"))
    (let ((lib (file-name-sans-extension f)))
      (unless (member lib '("org-loaddefs" "org-autoloads" "org-pkg" "org-version"))
        (condition-case err (require (intern lib))
          (error (message "Could not load %s: %S" lib err))))))
  (let ((re (concat (regexp-quote (file-name-as-directory (expand-file-name org-dir)))
                    "\\([^/]+\\)\\.elc?\\'"))
        cmds vars)
    (mapatoms
     (lambda (s)
       (let ((file (or (symbol-file s 'defun) "")))
         (when (and (commandp s) (fboundp s) (not (get s 'byte-obsolete-info))
                    (string-match re file))
           (push (format "%s\t%s" (match-string 1 file) s) cmds)))
       (let ((file (or (symbol-file s 'defvar) "")))
         (when (and (custom-variable-p s) (not (get s 'byte-obsolete-variable))
                    (string-match re file))
           (push (format "%s\t%s" (match-string 1 file) s) vars)))))
    (make-directory out-dir t)
    (with-temp-file (expand-file-name "commands.tsv" out-dir)
      (insert (mapconcat #'identity (sort cmds #'string<) "\n") "\n"))
    (with-temp-file (expand-file-name "options.tsv" out-dir)
      (insert (mapconcat #'identity (sort vars #'string<) "\n") "\n"))
    (message "Org %s: %d commands, %d options" (org-version) (length cmds) (length vars))))

;;; inventory.el ends here
