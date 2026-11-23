;;; inventory.el --- List every Org command, option, executor, link type and transcoder  -*- lexical-binding: t; -*-

;; Loads every library of an Org source tree and writes, one
;; "LIBRARY<TAB>SYMBOL" line each, sorted:
;;
;;   commands.tsv     interactive commands
;;   options.tsv      user options (defcustoms)
;;   executors.tsv    Babel executors, org-babel-execute:LANG (a language
;;                    whose ob-LANG.el has no command or option shows up
;;                    only here)
;;   links.tsv        link types in `org-link-parameters', as link:TYPE
;;   transcoders.tsv  the transcoders each export back-end defines itself
;;                    (not the ones a derived back-end inherits), as
;;                    BACKEND:ELEMENT-TYPE
;;
;; Obsolete aliases are skipped.
;;
;;   emacs -Q --batch -l docs/parity/inventory.el \
;;     --eval '(org-parity-inventory "/path/to/org-9.8.13/" "out/")'
;;
;; The commands and options in inventory.tsv were listed from Org 9.8.10
;; and checked against Org 9.8.11, 9.8.12 and 9.8.13 (the same ones); the
;; executors, link types and transcoders were listed from Org 9.8.12 (the
;; same in 9.8.10).  A link type belongs to the library of its functions,
;; else to the library whose loading registered it.  A transcoder may name
;; a function Org never defines (ox-man has several): it is listed anyway.

(require 'cl-lib)
(defvar org-link-parameters)
(defvar org-export-registered-backends)
(declare-function org-export-backend-name "ox" (backend))
(declare-function org-export-backend-transcoders "ox" (backend))

(defun org-parity--link-types ()
  "The link types of `org-link-parameters'."
  (mapcar #'car org-link-parameters))

(defun org-parity--write (out-dir name lines)
  "Write LINES, sorted, to OUT-DIR/NAME."
  (with-temp-file (expand-file-name name out-dir)
    (insert (mapconcat #'identity (sort lines #'string<) "\n") "\n")))

(defun org-parity-inventory (org-dir out-dir)
  "Write the inventory files for the Org sources in ORG-DIR to OUT-DIR."
  (setq load-prefer-newer t)
  (add-to-list 'load-path org-dir)
  (let ((re (concat (regexp-quote (file-name-as-directory (expand-file-name org-dir)))
                    "\\([^/]+\\)\\.elc?\\'"))
        (link-lib (make-hash-table :test #'equal))
        cmds vars execs links trans)
    ;; A link type belongs to the library whose require registered it,
    ;; unless one of its functions says otherwise (below).
    (cl-flet ((note-links (lib)
                (dolist (type (org-parity--link-types))
                  (unless (gethash type link-lib) (puthash type lib link-lib)))))
      (require 'ol)
      (note-links "ol")
      (require 'org)
      (note-links "org")
      (dolist (f (directory-files org-dir nil "^\\(org\\|ox\\|ob\\|ol\\|oc\\)[-a-zA-Z0-9]*\\.el$"))
        (let ((lib (file-name-sans-extension f)))
          (unless (member lib '("org-loaddefs" "org-autoloads" "org-pkg" "org-version"))
            (condition-case err (require (intern lib))
              (error (message "Could not load %s: %S" lib err)))
            (note-links lib)))))
    (mapatoms
     (lambda (s)
       (let ((file (or (symbol-file s 'defun) "")))
         (when (and (commandp s) (fboundp s) (not (get s 'byte-obsolete-info))
                    (string-match re file))
           (push (format "%s\t%s" (match-string 1 file) s) cmds)))
       (let ((file (or (symbol-file s 'defvar) "")))
         (when (and (custom-variable-p s) (not (get s 'byte-obsolete-variable))
                    (string-match re file))
           (push (format "%s\t%s" (match-string 1 file) s) vars)))
       (let ((file (or (symbol-file s 'defun) "")))
         (when (and (fboundp s) (string-prefix-p "org-babel-execute:" (symbol-name s))
                    (not (get s 'byte-obsolete-info))
                    (string-match re file))
           (push (format "%s\t%s" (match-string 1 file) s) execs)))))
    (dolist (entry org-link-parameters)
      (let* ((type (car entry))
             (fns (cl-loop for (_k v) on (cdr entry) by #'cddr
                           when (and (symbolp v) (fboundp v)) collect v))
             (file (cl-some (lambda (f)
                              (let ((sf (or (symbol-file f 'defun) "")))
                                (and (string-match re sf) (match-string 1 sf))))
                            fns)))
        (push (format "%s\tlink:%s" (or file (gethash type link-lib) "?") type) links)))
    (dolist (backend org-export-registered-backends)
      (let* ((name (symbol-name (org-export-backend-name backend)))
             (lib (if (file-exists-p (expand-file-name (format "ox-%s.el" name) org-dir))
                      (format "ox-%s" name)
                    "ox")))
        (dolist (tr (org-export-backend-transcoders backend))
          (push (format "%s\t%s:%s" lib name (car tr)) trans))))
    (make-directory out-dir t)
    (org-parity--write out-dir "commands.tsv" cmds)
    (org-parity--write out-dir "options.tsv" vars)
    (org-parity--write out-dir "executors.tsv" execs)
    (org-parity--write out-dir "links.tsv" (delete-dups links))
    (org-parity--write out-dir "transcoders.tsv" (delete-dups trans))
    (message "Org %s: %d commands, %d options, %d executors, %d link types, %d transcoders"
             (org-version) (length cmds) (length vars) (length execs)
             (length (delete-dups links)) (length (delete-dups trans)))))

;;; inventory.el ends here
