;;; lists.el --- expected buffers after plain-list commands  -*- lexical-binding: t; -*-

;; For each case of tests/fixtures/emacs/lists/cases.txt
;;
;;   <name> <file> <line>:<col> <command>...
;;
;; visit the file with everything shown, put point at <line>:<col>, run
;; the commands the keys are bound to, each as a command of its own
;; (`this-command', `post-command-hook'), and print "=== <name>", the
;; buffer (lines as Neovim counts them), and "@ <line>", point's line.
;; A command that signals an error without changing the buffer has
;; declined; one that changed it first adds an "!error <message>" line.
;; The file itself is never written.

(defconst parity-lists-commands
  '(("M-RET" . org-meta-return)
    ("M-S-RET" . org-insert-todo-heading)
    ("M-left" . org-metaleft)
    ("M-right" . org-metaright)
    ("M-S-left" . org-shiftmetaleft)
    ("M-S-right" . org-shiftmetaright)
    ("M-up" . org-metaup)
    ("M-down" . org-metadown)
    ("S-left" . org-shiftleft)
    ("S-right" . org-shiftright)
    ("S-up" . org-shiftup)
    ("S-down" . org-shiftdown)
    ("C-c-" . org-ctrl-c-minus)
    ("C-c*" . org-ctrl-c-star)
    ("C-cC-c" . org-ctrl-c-ctrl-c))
  "The keys of the cases and the commands they run (org-keys.el).")

(defun parity-lists-goto (spec)
  "Move point to SPEC, \"<line>:<col>\"."
  (let ((lc (mapcar #'string-to-number (split-string spec ":"))))
    (goto-char (point-min))
    (forward-line (1- (car lc)))
    (move-to-column (cadr lc))))

(defun parity-lists-lines ()
  "The lines of the buffer, as Neovim counts them."
  (let ((lines (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")))
    (if (and (cdr lines) (equal (car (last lines)) ""))
        (butlast lines)
      lines)))

(defun parity-lists-prompted (&rest args)
  (error "Prompted: %S" (car args)))

(defun parity-lists-run (cmd prefix)
  "Run the command of CMD (a key of the cases) with PREFIX."
  (let* ((sort-key (and (string-prefix-p "C-c^" cmd) (aref cmd 4)))
         (fn (if sort-key #'org-sort
               (or (cdr (assoc cmd parity-lists-commands))
                   (error "Unknown command %s" cmd)))))
    ;; C-c ^ asks for the sorting type with read-char-exclusive; nothing
    ;; else may prompt
    (cl-letf (((symbol-function 'read-char-exclusive)
               (if sort-key (lambda (&rest _) sort-key) #'parity-lists-prompted))
              ((symbol-function 'read-char) #'parity-lists-prompted)
              ((symbol-function 'read-string) #'parity-lists-prompted)
              ((symbol-function 'read-from-minibuffer) #'parity-lists-prompted)
              ((symbol-function 'completing-read) #'parity-lists-prompted)
              ((symbol-function 'y-or-n-p) #'parity-lists-prompted)
              ((symbol-function 'yes-or-no-p) #'parity-lists-prompted))
      (let ((current-prefix-arg prefix)
            (last-command 'parity-previous)
            (this-command fn)
            (deactivate-mark nil))
        (unwind-protect
            (progn
              (call-interactively fn)
              (run-hooks 'post-command-hook))
          ;; as the command loop does: a command that changed the buffer
          ;; ends the region it made (C-u C-c * marks the list)
          (when deactivate-mark (deactivate-mark)))))))

;; The region of a command (org-mark-element in C-u C-c *) is active, as
;; in an interactive Emacs: a batch one starts with this off.
(transient-mark-mode 1)

(let* ((dir (expand-file-name "lists/" parity-fixtures))
       (out '()))
  (dolist (case (parity-read-cases (expand-file-name "cases.txt" dir)))
    (let* ((name (nth 0 case))
           (buf (find-file-noselect (expand-file-name (nth 1 case) dir)))
           (prefix nil))
      (with-current-buffer buf
        (org-fold-show-all)
        (parity-lists-goto (nth 2 case))
        (push (format "=== %s\n" name) out)
        (dolist (cmd (nthcdr 3 case))
          (cond
           ((equal cmd "C-u") (setq prefix '(4)))
           ((string-prefix-p "ins:" cmd) (insert (substring cmd 4)))
           ((string-match "\\`L\\([0-9]+:[0-9]+\\)\\'" cmd)
            (parity-lists-goto (match-string 1 cmd)))
           (t
            (let ((before (buffer-string)))
              (condition-case err
                  (parity-lists-run cmd prefix)
                (error
                 (unless (equal before (buffer-string))
                   (push (format "!error %s\n"
                                 (replace-regexp-in-string
                                  "\n" " " (error-message-string err)))
                         out)))))
            (setq prefix nil))))
        (dolist (l (parity-lists-lines))
          (push (concat l "\n") out))
        (push (format "@ %d\n" (line-number-at-pos)) out)
        (set-buffer-modified-p nil))
      (kill-buffer buf)))
  (parity-write (expand-file-name "expected.txt" dir) (apply #'concat (nreverse out))))
