;;; omarchy-org-agenda.el --- Today's Org agenda for the Omarchy bar  -*- lexical-binding: t; -*-

;; Loaded into the user's running Emacs server by the Omarchy plugin through
;; emacsclient.  Nothing runs on load: the plugin calls
;; `omarchy-org-agenda-ensure' and `omarchy-org-agenda-export', and
;; `omarchy-org-agenda-teardown' removes every hook this file adds.

;;; Commentary:

;; Writes today's agenda as JSON to `omarchy-org-agenda-output'.  The bar's
;; file list is `omarchy-org-agenda-files-override', else
;; `omarchy-org-agenda-files', else `org-agenda-files'.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'seq)

(defconst omarchy-org-agenda-version "0.1.0")
(defconst omarchy-org-agenda-protocol 1)

(defgroup omarchy-org-agenda nil
  "Today's Org agenda in the Omarchy bar."
  :group 'org-agenda
  :prefix "omarchy-org-agenda-")

(defcustom omarchy-org-agenda-files nil
  "Files and directories the Omarchy bar shows, instead of `org-agenda-files'.
Same format as `org-agenda-files': a list of files and directories, or
the name of a file that lists them.  nil means use `org-agenda-files'.

Set this to pin the bar's list, e.g. when your own commands narrow
`org-agenda-files' at runtime but the bar should always show everything.
The plugin's own file setting, when given, takes precedence over this."
  :type '(choice (const :tag "Use `org-agenda-files'" nil)
                 (repeat :tag "List of files and directories" file)
                 (file :tag "Store list in a file"))
  :group 'omarchy-org-agenda)

(defvar omarchy-org-agenda-output nil
  "Absolute path of the JSON file the Omarchy bar watches.")

(defvar omarchy-org-agenda-files-override nil
  "When non-nil, files/directories used instead of `org-agenda-files'.
Set by the plugin on every `omarchy-org-agenda-ensure'; it takes
precedence over `omarchy-org-agenda-files'.")

(defvar omarchy-org-agenda-max-items 200)
(defvar omarchy-org-agenda-max-title 200)

(defvar omarchy-org-agenda--timer nil)
(defvar omarchy-org-agenda--push nil)
(defvar omarchy-org-agenda--exporting nil)

(defvar omarchy-org-agenda--source-mtime nil
  "Modification time of the file this helper was last loaded from.
The plugin compares it with the file on disk and reloads when they differ.")

;;;; Extraction

(defun omarchy-org-agenda--prop (entry key)
  "Text property KEY of the agenda ENTRY string."
  (get-text-property 0 key entry))

(defun omarchy-org-agenda--clean (s &optional max)
  "S trimmed and without properties, cut to MAX chars with an ellipsis."
  (when s
    (let ((s (string-trim (substring-no-properties s))))
      (if (and max (> (length s) max))
          (concat (substring s 0 (1- max)) "…")
        s))))

(defun omarchy-org-agenda--priority ()
  "The explicit priority cookie of the heading at point, or nil."
  (save-excursion
    ;; A diary sexp may sit before the first heading.
    (org-back-to-heading-or-point-min t)
    (when (looking-at org-complex-heading-regexp)
      (let ((cookie (match-string-no-properties 3)))
        (and cookie (substring cookie 2 3))))))

(defun omarchy-org-agenda--item (entry today)
  "The JSON plist for agenda ENTRY; TODAY is an absolute day number."
  (let ((marker (or (omarchy-org-agenda--prop entry 'org-hd-marker)
                    (omarchy-org-agenda--prop entry 'org-marker)))
        (type (omarchy-org-agenda--prop entry 'type))
        (tod (omarchy-org-agenda--prop entry 'time-of-day))
        (ts (omarchy-org-agenda--prop entry 'ts-date))
        (todo (omarchy-org-agenda--clean (omarchy-org-agenda--prop entry 'todo-state))))
    (org-with-point-at marker
      (list :id (or (org-entry-get nil "ID") :null)
            :path (buffer-file-name (buffer-base-buffer))
            ;; The heading's line, even for a diary sexp in its body.
            :line (save-excursion (org-back-to-heading t) (line-number-at-pos))
            :type type
            :todo (or todo :null)
            :done (if (member todo org-done-keywords-for-agenda) t :false)
            ;; A diary sexp's text is its result ("Ana is 36 years old"),
            ;; not the heading it happens to sit under.
            :title (omarchy-org-agenda--clean
                    (org-link-display-format
                     (if (equal type "sexp")
                         (omarchy-org-agenda--prop entry 'txt)
                       (org-get-heading t t t t)))
                    omarchy-org-agenda-max-title)
            :priority (or (omarchy-org-agenda--priority) :null)
            :category (or (omarchy-org-agenda--clean
                           (omarchy-org-agenda--prop entry 'org-category))
                          :null)
            :tags (vconcat (mapcar #'substring-no-properties
                                   (omarchy-org-agenda--prop entry 'tags)))
            :time (if tod (format "%02d:%02d" (/ tod 100) (% tod 100)) :null)
            ;; Org keeps durations as floats; the bar wants whole minutes.
            :durationMin (let ((duration (omarchy-org-agenda--prop entry 'duration)))
                           (if duration (round duration) :null))
            :overdueDays (if (and ts (< ts today)) (- today ts) 0)
            :habit (if (omarchy-org-agenda--prop entry 'org-habit-p) t :false)))))

(defun omarchy-org-agenda--files ()
  "Absolute agenda files the bar shows, as Org expands them; may not exist.
Precedence: `omarchy-org-agenda-files-override', then
`omarchy-org-agenda-files', then `org-agenda-files'."
  (let ((org-agenda-files (or omarchy-org-agenda-files-override
                              omarchy-org-agenda-files
                              org-agenda-files)))
    ;; Expansion only: unlike `org-agenda-prepare-buffers', this never
    ;; asks about missing files.
    (org-agenda-files nil 'ifmode)))

(defun omarchy-org-agenda--entries (files)
  "Today's agenda entries in FILES, sorted like the user's own day agenda.
Every file in FILES must exist, or Org prompts to remove it from the list."
  (let* ((org-agenda-files files)
         (org-agenda-sorting-strategy-selected nil)
         (date (calendar-current-date)))
    (org-agenda-prepare-buffers files)
    (org-set-sorting-strategy 'agenda)
    (sort (mapcan (lambda (file)
                    (org-agenda-get-day-entries file date
                                                :deadline :scheduled :timestamp :sexp))
                  files)
          #'org-entries-lessp)))

(defun omarchy-org-agenda--color (kwd)
  "Foreground of the TODO face for KWD as #rrggbb, or nil."
  (let* ((face (org-get-todo-face kwd))
         (fg (cond ((facep face) (face-foreground face nil t))
                   ((listp face) (plist-get face :foreground)))))
    (and (stringp fg) (string-prefix-p "#" fg) fg)))

(defun omarchy-org-agenda--keywords ()
  "TODO and DONE keywords of the exported files, with their face colors."
  ;; `org-agenda-prepare-buffers' pushes keywords, so they come out in
  ;; reverse; restore the order they are declared in.
  (let ((all (reverse org-todo-keywords-for-agenda))
        (done (reverse org-done-keywords-for-agenda))
        (colors (make-hash-table :test #'equal)))
    (dolist (kwd all)
      (when-let* ((color (omarchy-org-agenda--color kwd)))
        (puthash kwd color colors)))
    (list :todo (vconcat (seq-difference all done))
          :done (vconcat done)
          :colors colors)))

;;;; Output

(defun omarchy-org-agenda--write (payload)
  "Write PAYLOAD as JSON, atomically, so the bar never reads half a file."
  (let ((tmp (concat omarchy-org-agenda-output ".tmp")))
    (make-directory (file-name-directory omarchy-org-agenda-output) t)
    (with-temp-buffer
      (insert (json-serialize payload))
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region nil nil tmp nil 'silent)))
    (rename-file tmp omarchy-org-agenda-output t)))

(defun omarchy-org-agenda-export (&optional reason)
  "Write today's agenda to `omarchy-org-agenda-output'.
REASON (default \"pull\") is echoed in the payload.  Agenda files that
don't exist are skipped and listed under :missing.  Errors are written
into the file too, so the bar can show them."
  (let* ((omarchy-org-agenda--exporting t)
         ;; Collected afresh from this export's files, without disturbing
         ;; the user's agenda buffer, which reads them too.
         (org-todo-keywords-for-agenda nil)
         (org-done-keywords-for-agenda nil)
         (today (calendar-absolute-from-gregorian (calendar-current-date)))
         (base (list :version omarchy-org-agenda-protocol
                     :date (format-time-string "%F")
                     :generatedAt (format-time-string "%FT%T%z")
                     :reason (or reason "pull")
                     :emacs emacs-version
                     :org (org-version))))
    (omarchy-org-agenda--write
     (condition-case err
         (let* ((files (omarchy-org-agenda--files))
                (missing (seq-remove #'file-exists-p files))
                (entries (seq-take (omarchy-org-agenda--entries
                                    (seq-difference files missing))
                                   omarchy-org-agenda-max-items)))
           (append base
                   (list :keywords (omarchy-org-agenda--keywords)
                         :items (vconcat (mapcar (lambda (e) (omarchy-org-agenda--item e today))
                                                 entries))
                         :missing (vconcat missing)
                         :error :null)))
       (error (append base (list :items []
                                 :missing []
                                 :error (error-message-string err))))))
    t))

;;;; Push: re-export when the agenda can have changed

(defun omarchy-org-agenda--schedule (reason)
  "Export with REASON once Emacs is idle, replacing any pending export."
  (when (timerp omarchy-org-agenda--timer)
    (cancel-timer omarchy-org-agenda--timer))
  (setq omarchy-org-agenda--timer
        (run-with-idle-timer 0.5 nil #'omarchy-org-agenda-export reason)))

(defun omarchy-org-agenda--on-save ()
  "Re-export after an Org buffer is saved."
  (when (derived-mode-p 'org-mode) (omarchy-org-agenda--schedule "save")))

(defun omarchy-org-agenda--on-revert ()
  "Re-export after an Org buffer is reverted."
  (when (derived-mode-p 'org-mode) (omarchy-org-agenda--schedule "revert")))

(defun omarchy-org-agenda--on-todo ()
  "Re-export after a TODO state change."
  (omarchy-org-agenda--schedule "todo"))

(defun omarchy-org-agenda--on-agenda ()
  "Re-export after an agenda buffer is built."
  (omarchy-org-agenda--schedule "agenda"))

(defun omarchy-org-agenda--on-files (_symbol _newval operation _where)
  "Re-export when `org-agenda-files' is set and the bar follows it.
OPERATION is the watcher's operation; only `set' counts, so the
exporter's own `let' of `org-agenda-files' never re-triggers.  A pinned
list doesn't follow `org-agenda-files', so its changes don't matter."
  (when (and (eq operation 'set)
             (not omarchy-org-agenda--exporting)
             (not (or omarchy-org-agenda-files-override
                      omarchy-org-agenda-files)))
    (omarchy-org-agenda--schedule "files")))

(defun omarchy-org-agenda-ensure (output &optional files push)
  "Point the exporter at OUTPUT; idempotent, called by the plugin on every pull.
FILES overrides `org-agenda-files'.  PUSH installs the change hooks."
  (setq omarchy-org-agenda-output (expand-file-name output)
        omarchy-org-agenda-files-override files)
  (unless (eq (and push t) omarchy-org-agenda--push)
    (omarchy-org-agenda-teardown)
    (when push
      (add-hook 'after-save-hook #'omarchy-org-agenda--on-save)
      (add-hook 'after-revert-hook #'omarchy-org-agenda--on-revert)
      (add-hook 'org-after-todo-state-change-hook #'omarchy-org-agenda--on-todo)
      (add-hook 'org-agenda-finalize-hook #'omarchy-org-agenda--on-agenda)
      (add-variable-watcher 'org-agenda-files #'omarchy-org-agenda--on-files)
      (setq omarchy-org-agenda--push t)))
  t)

(defun omarchy-org-agenda-teardown ()
  "Remove every hook, watcher and timer this package installed."
  (remove-hook 'after-save-hook #'omarchy-org-agenda--on-save)
  (remove-hook 'after-revert-hook #'omarchy-org-agenda--on-revert)
  (remove-hook 'org-after-todo-state-change-hook #'omarchy-org-agenda--on-todo)
  (remove-hook 'org-agenda-finalize-hook #'omarchy-org-agenda--on-agenda)
  (remove-variable-watcher 'org-agenda-files #'omarchy-org-agenda--on-files)
  (when (timerp omarchy-org-agenda--timer)
    (cancel-timer omarchy-org-agenda--timer))
  (setq omarchy-org-agenda--timer nil
        omarchy-org-agenda--push nil)
  t)

(defun omarchy-org-agenda-unload-function ()
  "Tear down before `unload-feature', then let it continue."
  (omarchy-org-agenda-teardown)
  nil)

;;;; Click: open the source file at the entry's line

(defun omarchy-org-agenda--locate (path line &optional id)
  "Marker for the entry at LINE of PATH.
When ID is given and the heading at LINE no longer carries it (the file
was edited since the export), follow the ID instead."
  (with-current-buffer (find-file-noselect path)
    (org-with-wide-buffer
     (goto-char (point-min))
     (forward-line (1- line))
     (or (and id
              (not (equal id (ignore-errors (org-entry-get nil "ID"))))
              (org-id-find id 'marker))
         (point-marker)))))

(defun omarchy-org-agenda-goto (path line &optional id)
  "Show PATH at LINE in the selected frame, like `emacsclient +LINE PATH'.
Unfolds the entry so the heading is visible.  ID, when given, finds
the entry if LINE is stale; see `omarchy-org-agenda--locate'."
  (let ((marker (omarchy-org-agenda--locate path line id)))
    (pop-to-buffer-same-window (marker-buffer marker))
    (unless (<= (point-min) marker (point-max)) (widen))
    (goto-char marker)
    (when (derived-mode-p 'org-mode)
      (org-fold-show-context 'agenda)
      (org-fold-show-entry))
    (recenter 2)
    t))

(defun omarchy-org-agenda-open-agenda (&optional key)
  "Open the user's agenda dispatcher entry KEY (default \"a\")."
  (org-agenda nil (or key "a"))
  t)

;; Updated on every load, not just the first, so the plugin's mtime check
;; sees the version that is actually loaded.
(setq omarchy-org-agenda--source-mtime
      (when-let* ((file (or load-file-name buffer-file-name)))
        (file-attribute-modification-time (file-attributes file))))

(provide 'omarchy-org-agenda)
;;; omarchy-org-agenda.el ends here
