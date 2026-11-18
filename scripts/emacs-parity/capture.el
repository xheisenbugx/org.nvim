;;; capture.el --- expected target files after org-capture  -*- lexical-binding: t; -*-

;; For each case of tests/fixtures/emacs/capture/cases.txt
;;
;;   <name> <key> <origin> [<answer>...]
;;
;; copy the files of capture/ (but cases.txt and expected.txt) to a fresh
;; temporary directory (the
;; `org-directory' the templates' files are relative to), capture with
;; the template at <key> of `parity-capture-templates' from <origin>,
;; finish as C-c C-c does (org-capture-finalize), and print "=== <name>"
;; and the text of the template's file, the temporary directory written
;; "@DIR@/".  <origin> is where the capture starts:
;;
;;   -                 a buffer visiting no file
;;   <file>:<l>        that file (a copy, an Org file or notes.txt), point
;;                     at the start of line <l>
;;   <file>:<l1>-<l2>  the same, lines l1 to l2 as the active region (%i)
;;   string:<text>     org-capture-string with <text> as %i ("_": space)
;;
;; Prompts get the <answer>s in turn ("_" for a space, "~" for an empty
;; answer: the default).  The checked-in files are never written.

;; The templates, in the order and with the keys of TEMPLATES in
;; tests/spec/emacs_capture_parity_spec.lua (org.nvim's format): keep the
;; two tables in step.
(defconst parity-capture-templates
  '(("e" "Entry" entry (file "inbox.org") "* TODO %?")
    ("ep" "Entry, prepended" entry (file "inbox.org") "* First %?" :prepend t)
    ("h" "Headline" entry (file+headline "inbox.org" "Tasks") "* TODO %?\n  %u")
    ("hp" "Headline, prepended" entry (file+headline "inbox.org" "Tasks") "* Urgent %?" :prepend t)
    ("hn" "New headline" entry (file+headline "inbox.org" "Later") "* Someday %?")
    ("hc" "Headline in another case" entry (file+headline "inbox.org" "notes") "* Found %?")
    ("hd" "Deeper levels" entry (file+headline "inbox.org" "Notes") "*** Deep :deep:\n**** Deeper %?")
    ("o" "Outline path" entry (file+olp "projects.org" "Projects" "Neovim") "* Idea %?")
    ("r" "Regexp" entry (file+regexp "projects.org" "^\\*\\* Emacs") "* After match %?")
    ("d" "Date tree" entry (file+olp+datetree "journal.org") "* Today %?\n%U")
    ("dw" "Week tree" entry (file+olp+datetree "weeks.org") "* This week %?" :tree-type week)
    ("dm" "Month tree" entry (file+olp+datetree "weeks.org") "* This month %?" :tree-type month)
    ("do" "Date tree under a path" entry (file+olp+datetree "projects.org" "Someday") "* Dated %?")
    ("dd" "Date tree, existing day" entry (file+olp+datetree "days.org") "* Now %?")
    ("dq" "Quarter tree" entry (file+olp+datetree "weeks.org") "* This quarter %?"
     :tree-type (year quarter month))
    ("x" "No stars" entry (file "inbox.org") "No stars here %?")
    ("nl" "No final newline" entry (file "nonl.org") "* Appended %?")
    ("np" "No final newline, plain" plain (file+headline "nonl.org" "Inbox") "More text")
    ("i" "Item" item (file+headline "lists.org" "Shopping") "eggs %?")
    ("ip" "Item, prepended" item (file+headline "lists.org" "Shopping") "- butter" :prepend t)
    ("in" "Item, ordered list" item (file+headline "lists.org" "Ordered") "three")
    ("il" "Item, empty lines" item (file+headline "lists.org" "Todo") "- spaced" :empty-lines 1)
    ("iw" "Item, no list" item (file+headline "inbox.org" "Notes") "first item")
    ("ii" "Item, initial" item (file+headline "lists.org" "Shopping") "%i")
    ("c" "Check item" checkitem (file+headline "lists.org" "Todo") "- [ ] read %?")
    ("co" "Check item, ordered list" checkitem (file+headline "lists.org" "Ordered") "four")
    ("ce" "Check item, default" checkitem (file+headline "lists.org" "Shopping") "")
    ("t" "Table line" table-line (file+headline "tables.org" "Log") "| %t | %? |")
    ("tp" "Table line, position" table-line (file+headline "tables.org" "Log") "| new | row |"
     :table-line-pos "II-1")
    ("tP" "Table line, prepended" table-line (file+headline "tables.org" "Log") "| first | row |" :prepend t)
    ("tn" "Table line, new table" table-line (file+headline "tables.org" "Empty") "| a | b |")
    ("p" "Plain" plain (file+headline "plain.org" "Notes") "Plain %U")
    ("pp" "Plain, prepended" plain (file+headline "plain.org" "Notes") "Plain first" :prepend t)
    ("pf" "Plain, file" plain (file "plain.org") "At the end")
    ("el" "Empty lines" entry (file+headline "inbox.org" "Tasks") "* Spaced %?" :empty-lines 1)
    ("eb" "Empty lines before" entry (file+headline "inbox.org" "Notes") "* Before %?"
     :empty-lines-before 2)
    ("ea" "Empty lines after" entry (file+headline "inbox.org" "Tasks") "* After %?"
     :empty-lines-after 1)
    ("T" "Dates" entry (file "inbox.org") "* Dates %t %T\n  %u %U")
    ("L" "Literal" entry (file "inbox.org") "* Literal 50% done \\%t\n  100%% sure")
    ("m" "Text after the cursor" entry (file+headline "inbox.org" "Tasks") "* Meeting %? with the team")
    ("s" "Planning" entry (file+headline "inbox.org" "Tasks") "* TODO Review %?\nSCHEDULED: %t")
    ("a" "Link" entry (file "inbox.org") "* Link %a")
    ("f" "Origin" entry (file "inbox.org") "* From %f\n  %F\n  %<%Y/%m/%d %H:%M>")
    ("I" "Initial" entry (file "inbox.org") "* Initial %i")
    ("Ir" "Initial, quoted" entry (file "inbox.org") "* Quote\n  > %i")
    ("P" "Prompts" entry (file "inbox.org") "* %^{Title}\n  Owner: %^{Owner|alice|bob}\n  Again: %\\1")
    ("g" "Tags" entry (file "inbox.org") "* Tagged %^g")
    ("pr" "Property" entry (file "inbox.org") "* Estimated %^{Effort}p")
    ("if" "Immediate" entry (file+headline "inbox.org" "Tasks") "* Quick" :immediate-finish t))
  "The capture templates of the cases, files relative to `org-directory'.")

(defvar parity-capture-answers nil
  "The answers left for the prompts of the current case.")

(defun parity-capture-answer (&rest _)
  "The next answer (\"_\" a space, \"~\" empty)."
  (unless parity-capture-answers (error "Prompted with no answer left"))
  (let ((a (pop parity-capture-answers)))
    (if (equal a "~") "" (replace-regexp-in-string "_" " " a))))

(defun parity-capture-completing-read (_prompt _coll &optional _pred _req _init _hist def &rest _)
  ;; like completing-read: an empty answer is the default
  (let ((a (parity-capture-answer)))
    (if (and (equal a "") def) (if (consp def) (car def) def) a)))

(defun parity-capture-text (file tmp)
  "The text of FILE, TMP written \"@DIR@/\"."
  (let ((text (with-current-buffer (find-buffer-visiting file)
                (buffer-substring-no-properties (point-min) (point-max)))))
    (dolist (d (delete-dups (list (file-truename tmp) tmp (abbreviate-file-name tmp))))
      (setq text (replace-regexp-in-string (regexp-quote d) "@DIR@/" text t t)))
    text))

(defun parity-capture-origin (origin tmp)
  "Make ORIGIN (see the top of this file) the selected buffer; the initial text or nil."
  (cond
   ((equal origin "-")
    (switch-to-buffer (get-buffer-create "*parity-origin*"))
    nil)
   ((string-prefix-p "string:" origin)
    (switch-to-buffer (get-buffer-create "*parity-origin*"))
    (replace-regexp-in-string "_" " " (substring origin 7)))
   ((string-match "\\`\\(.+\\):\\([0-9]+\\)\\(?:-\\([0-9]+\\)\\)?\\'" origin)
    (let ((l1 (string-to-number (match-string 2 origin)))
          (l2 (and (match-string 3 origin) (string-to-number (match-string 3 origin)))))
      (switch-to-buffer (find-file-noselect (expand-file-name (match-string 1 origin) tmp)))
      (goto-char (point-min))
      (forward-line (1- l1))
      (when l2
        (push-mark (point) t t)
        (forward-line (- l2 l1))
        (end-of-line))
      nil))
   (t (error "Unknown origin %s" origin))))

(require 'org-capture)
(transient-mark-mode 1)
(setq org-capture-bookmark nil)

(let* ((dir (expand-file-name "capture/" parity-fixtures))
       (out '()))
  (dolist (case (parity-read-cases (expand-file-name "cases.txt" dir)))
    (let* ((name (nth 0 case))
           (key (nth 1 case))
           (tmp (file-name-as-directory (make-temp-file "parity-capture" t)))
           (tpl (or (assoc key parity-capture-templates) (error "No template %s" key)))
           (file (expand-file-name (nth 1 (nth 3 tpl)) tmp))
           (org-directory tmp)
           (org-capture-templates parity-capture-templates)
           (parity-capture-answers (nthcdr 3 case)))
      (dolist (f (directory-files dir t "\\`[^.]"))
        (unless (member (file-name-nondirectory f) '("cases.txt" "expected.txt"))
          (copy-file f tmp)))
      (let ((initial (parity-capture-origin (nth 2 case) tmp)))
        (cl-letf (((symbol-function 'completing-read) #'parity-capture-completing-read)
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) (split-string (parity-capture-answer) ":" t)))
                  ((symbol-function 'read-string) #'parity-capture-answer)
                  ((symbol-function 'read-from-minibuffer) #'parity-capture-answer))
          (if initial
              (org-capture-string initial key)
            (org-capture nil key))
          ;; C-c C-c in the capture buffer (an :immediate-finish template
          ;; has none left)
          (when (and (buffer-base-buffer) (string-prefix-p "CAPTURE-" (buffer-name)))
            (org-capture-finalize))))
      (when parity-capture-answers
        (error "%s: answers left: %S" name parity-capture-answers))
      (push (format "=== %s\n" name) out)
      (let ((text (parity-capture-text file tmp)))
        (push text out)
        (unless (or (equal text "") (string-suffix-p "\n" text))
          (push "\n" out)))
      (dolist (b (buffer-list))
        (when (or (equal (buffer-name b) "*parity-origin*")
                  (let ((f (buffer-file-name b))) (and f (string-prefix-p tmp f))))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory tmp t)))
  (parity-write (expand-file-name "expected.txt" dir) (apply #'concat (nreverse out))))
