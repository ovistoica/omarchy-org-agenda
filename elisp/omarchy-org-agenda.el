;;; omarchy-org-agenda.el --- Today's Org agenda for the Omarchy bar  -*- lexical-binding: t; -*-

;; Loaded into the user's running Emacs server by the Omarchy plugin through
;; emacsclient.  Nothing runs on load: the plugin calls
;; `omarchy-org-agenda-ensure' and `omarchy-org-agenda-export', and
;; `omarchy-org-agenda-teardown' removes every hook this file adds.

;;; Commentary:

;; Writes today's agenda as JSON to `omarchy-org-agenda-output', followed
;; by the scheduled tasks and timestamped entries (such as calendar
;; events) of the next `omarchy-org-agenda-upcoming-days' days.  The
;; bar's file list is `omarchy-org-agenda-files-override', else
;; `omarchy-org-agenda-files', else `org-agenda-files'.
;;
;; `omarchy-org-agenda-set-state' changes an exported entry's TODO state
;; for the bar, after checking the entry still is what the bar showed.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'seq)

;; A reload replaces the previous version instead of stacking on it.  The
;; plugin reloads this file whenever it changes on disk, and Emacs keeps
;; the replaced definitions in `function-history', which `unload-feature'
;; would bring back.  Hooks come off first, so a load that fails halfway
;; leaves nothing pointing at a missing function; the plugin's next
;; `omarchy-org-agenda-ensure' puts them back.
(declare-function feature-file "loadhist" (feature))
(when (featurep 'omarchy-org-agenda)
  (require 'loadhist)
  (when (fboundp 'omarchy-org-agenda-teardown)
    (omarchy-org-agenda-teardown))
  (dolist (elt (cdr (assoc (feature-file 'omarchy-org-agenda) load-history)))
    (when (eq (car-safe elt) 'defun)
      (put (cdr elt) 'function-history nil)
      (fmakunbound (cdr elt)))))

(defconst omarchy-org-agenda-version "0.2.0")
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

(defvar omarchy-org-agenda-upcoming-days 7
  "How many days after today the export looks ahead.
The scheduled tasks and timestamped entries (such as calendar events,
date ranges included) of those days follow today's agenda in the
export, once per heading at its first date, for the bar's \"Coming up\"
section; 0 exports today only.
Set by the plugin on `omarchy-org-agenda-ensure', within 0..31.")

(defvar omarchy-org-agenda-max-items 200
  "Bound on the exported items, today's first.")
(defvar omarchy-org-agenda-max-title 200)

(defvar omarchy-org-agenda--timer nil)
(defvar omarchy-org-agenda--push nil)
(defvar omarchy-org-agenda--exporting nil)

(defvar omarchy-org-agenda--index nil
  "What the last export wrote, for `omarchy-org-agenda-set-state' to check.
A hash table keyed by (PATH . LINE), holding (:title :todo :id) as the
JSON has them, `:null' included.  Diary sexps are left out.")

(defvar omarchy-org-agenda-max-detail 200
  "Bound on the user-visible detail of a state change result.")

(defvar omarchy-org-agenda-note-timeout 15
  "Seconds a note queued for `omarchy-org-agenda-take-note' stays queued.")

(defvar omarchy-org-agenda--note nil
  "The note a state change left queued or open, or nil.
A plist: :marker, a copy of `org-log-note-marker' that moves with it;
:time, its `org-log-note-effective-time'; :save, non-nil to save the
buffer once the note is stored; :timer, the timer that drops it if no
frame takes it.")

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

(defun omarchy-org-agenda--title (&optional raw)
  "The bar's title for RAW text, or for the heading at point.
Links show their description; the result is bounded.  Both the export
and `omarchy-org-agenda-set-state''s check use it, so they agree."
  (omarchy-org-agenda--clean
   (org-link-display-format (or raw (org-get-heading t t t t)))
   omarchy-org-agenda-max-title))

(defun omarchy-org-agenda--priority ()
  "The explicit priority cookie of the heading at point, or nil."
  (save-excursion
    ;; A diary sexp may sit before the first heading.
    (org-back-to-heading-or-point-min t)
    (when (looking-at org-complex-heading-regexp)
      (let ((cookie (match-string-no-properties 3)))
        (and cookie (substring cookie 2 3))))))

(defun omarchy-org-agenda--item (entry today &optional day)
  "The JSON plist for agenda ENTRY; TODAY is an absolute day number.
DAY is the later day ENTRY was collected for, nil for today's agenda.
:inDays counts the days until DAY, or until an upcoming deadline."
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
            :title (omarchy-org-agenda--title
                    (and (equal type "sexp")
                         (omarchy-org-agenda--prop entry 'txt)))
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
            ;; On a later day, `ts-date' can be a repeater's past base
            ;; date: that occurrence isn't overdue.
            :overdueDays (if (and ts (< ts today) (not day)) (- today ts) 0)
            :inDays (cond (day (- day today))
                          ((and ts (> ts today)) (- ts today))
                          (t 0))
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

(defun omarchy-org-agenda--day-entries (files date types)
  "Agenda entries of TYPES on DATE in FILES, sorted like a day agenda.
DATE is (MONTH DAY YEAR); TYPES are `org-agenda-get-day-entries' keywords.
Call it within `omarchy-org-agenda--entries', which prepares FILES."
  (sort (mapcan (lambda (file)
                  (apply #'org-agenda-get-day-entries file date types))
                files)
        #'org-entries-lessp))

(defun omarchy-org-agenda--entries (files &optional days)
  "Agenda entries in FILES for today and the DAYS days after it.
Returns a list of (OFFSET . ENTRIES), one per day in order: OFFSET 0
holds today's whole agenda, each later day only its scheduled tasks
and timestamped entries (such as calendar events): no deadlines, whose
warnings today's agenda already has, and no diary sexps.
Each day is sorted like the user's own day agenda.
Every file in FILES must exist, or Org prompts to remove it from the list."
  (let* ((org-agenda-files files)
         (org-agenda-sorting-strategy-selected nil)
         ;; Org 9.6's element cache drops DEADLINE entries from the first
         ;; scan of a freshly visited file; 9.7 fixed it.  Parse without the
         ;; cache there, at about 5x the cost (still ~40 ms for 10 files).
         (org-element-use-cache (and (version<= "9.7" (org-release))
                                     org-element-use-cache))
         (today (calendar-absolute-from-gregorian (calendar-current-date))))
    (org-agenda-prepare-buffers files)
    (org-set-sorting-strategy 'agenda)
    (cons (cons 0 (omarchy-org-agenda--day-entries
                   files (calendar-current-date)
                   '(:deadline :scheduled :timestamp :sexp)))
          (mapcar (lambda (offset)
                    (cons offset (omarchy-org-agenda--day-entries
                                  files
                                  (calendar-gregorian-from-absolute (+ today offset))
                                  ;; :timestamp covers date ranges too.
                                  '(:scheduled :timestamp))))
                  (number-sequence 1 (or days 0))))))

(defun omarchy-org-agenda--key (item)
  "The (PATH . LINE) of the heading behind the JSON ITEM."
  (cons (plist-get item :path) (plist-get item :line)))

(defun omarchy-org-agenda--items (days today)
  "JSON plists for DAYS, the (OFFSET . ENTRIES) list of `--entries'.
TODAY is an absolute day number.  Today's entries come first, as Org
lists them; a later day's entry is dropped when its heading is already
listed, so a repeating task or event shows once, at its next occurrence,
and a date range once, on its first day.  At most
`omarchy-org-agenda-max-items' in all, today's kept first."
  (let* ((max omarchy-org-agenda-max-items)
         (now (mapcar (lambda (entry) (omarchy-org-agenda--item entry today))
                      (seq-take (cdar days) max)))
         (seen (make-hash-table :test #'equal))
         (later nil))
    ;; A diary sexp's row isn't its heading's, which may be scheduled.
    (dolist (item now)
      (unless (equal (plist-get item :type) "sexp")
        (puthash (omarchy-org-agenda--key item) t seen)))
    (when (< (length now) max)
      (pcase-dolist (`(,offset . ,entries) (cdr days))
        (dolist (entry entries)
          (let ((item (omarchy-org-agenda--item entry today (+ today offset))))
            (unless (gethash (omarchy-org-agenda--key item) seen)
              (puthash (omarchy-org-agenda--key item) t seen)
              (push item later))))))
    (seq-take (append now (nreverse later)) max)))

(defun omarchy-org-agenda--color (kwd)
  "Foreground of the TODO face for KWD as #rrggbb, or nil."
  (let* ((face (org-get-todo-face kwd))
         (fg (cond ((facep face) (face-foreground face nil t))
                   ((listp face) (plist-get face :foreground)))))
    (and (stringp fg) (string-prefix-p "#" fg) fg)))

(defun omarchy-org-agenda--fast-keys (files keywords)
  "Fast selection keys of KEYWORDS in the buffers of FILES, as a hash.
Maps keyword to a one-char string; the first file declaring a key wins."
  (let ((keys (make-hash-table :test #'equal)))
    (dolist (file files)
      (when-let* ((buf (find-buffer-visiting file)))
        (dolist (cell (buffer-local-value 'org-todo-key-alist buf))
          (when (and (stringp (car-safe cell))
                     (characterp (cdr cell))
                     (member (car cell) keywords)
                     (not (gethash (car cell) keys)))
            (puthash (car cell) (char-to-string (cdr cell)) keys)))))
    keys))

(defun omarchy-org-agenda--keywords (files)
  "TODO and DONE keywords of the exported FILES, with face colors and keys."
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
          :colors colors
          :keys (omarchy-org-agenda--fast-keys files all))))

(defun omarchy-org-agenda--build-index (items)
  "Index of the exported ITEMS (JSON plists) by (PATH . LINE).
See `omarchy-org-agenda--index'."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (item items)
      (let ((key (cons (plist-get item :path) (plist-get item :line))))
        (unless (or (equal (plist-get item :type) "sexp")
                    (gethash key index))
          (puthash key (list :title (plist-get item :title)
                             :todo (plist-get item :todo)
                             :id (plist-get item :id))
                   index))))
    index))

;;;; Output

(defun omarchy-org-agenda--private-dir (dir)
  "Make sure DIR is a directory only the user can enter; return its name.
A missing DIR is created, with its missing parents, as 0700.  An
existing one must be a real directory, not a symlink, owned by the
user; one others can use is narrowed to 0700.  Anything else signals
an error: whoever owns DIR could read the agenda or replace it."
  (let ((dir (directory-file-name (expand-file-name dir))))
    ;; A dangling symlink can't be created over; the check below names it.
    (ignore-error file-already-exists
      (with-file-modes #o700
        (make-directory dir t)))
    (let ((attrs (file-attributes dir 'integer)))
      (unless (and attrs
                   (not (file-symlink-p dir))
                   (eq t (file-attribute-type attrs))
                   (eql (file-attribute-user-id attrs) (user-uid)))
        (error "Unsafe agenda directory %s: not a private directory owned by you"
               dir))
      (unless (zerop (logand #o077 (file-modes dir 'nofollow)))
        (set-file-modes dir #o700 'nofollow))
      dir)))

(defun omarchy-org-agenda--write (payload)
  "Write PAYLOAD as JSON, atomically, so the bar never reads half a file.
The file is readable by the user only, in a private directory; see
`omarchy-org-agenda--private-dir'.  Neither the temp file nor the
output follows a symlink planted in their place."
  (let* ((out omarchy-org-agenda-output)
         (tmp (concat out ".tmp")))
    (omarchy-org-agenda--private-dir (file-name-directory out))
    ;; Removes a leftover, or a symlink itself, never its target; the
    ;; exclusive create then refuses whatever appears there meanwhile.
    (delete-file tmp)
    (with-temp-buffer
      (insert (json-serialize payload))
      (let ((coding-system-for-write 'utf-8-unix))
        (with-file-modes #o600
          (write-region nil nil tmp nil 'silent nil 'excl))))
    ;; rename(2) replaces whatever is at OUT, a symlink included.
    (rename-file tmp out t)))

(defun omarchy-org-agenda-export (&optional reason)
  "Write today's agenda to `omarchy-org-agenda-output'.
The scheduled tasks and timestamped entries (such as calendar events)
of the next `omarchy-org-agenda-upcoming-days' days follow it, with
their :inDays.  REASON (default \"pull\") is echoed in
the payload.  Agenda files that don't exist are skipped and listed
under :missing.  Errors are written into the file too, so the bar can
show them; only a failure to write it, such as an output directory
that isn't private (see `omarchy-org-agenda--private-dir'), signals."
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
                (present (seq-difference files missing))
                (items (omarchy-org-agenda--items
                        (omarchy-org-agenda--entries
                         present omarchy-org-agenda-upcoming-days)
                        today)))
           (setq omarchy-org-agenda--index (omarchy-org-agenda--build-index items))
           (append base
                   (list :keywords (omarchy-org-agenda--keywords present)
                         :items (vconcat items)
                         :missing (vconcat missing)
                         :error :null)))
       (error (setq omarchy-org-agenda--index (omarchy-org-agenda--build-index nil))
              (append base (list :items []
                                 :missing []
                                 :error (error-message-string err))))))
    t))

;;;; Push: re-export when the agenda can have changed

(defun omarchy-org-agenda--push-export (reason)
  "Export with REASON for a hook or timer; never signal.
The user didn't ask for this export, so a failure, such as an unsafe
output directory, is only mentioned in the echo area; the bar's next
pull reports it."
  (condition-case err
      (omarchy-org-agenda-export reason)
    (error (message "Org agenda for the bar not updated: %s"
                    (error-message-string err))
           nil)))

(defun omarchy-org-agenda--schedule (reason)
  "Export with REASON once Emacs is idle, replacing any pending export."
  (when (timerp omarchy-org-agenda--timer)
    (cancel-timer omarchy-org-agenda--timer))
  (setq omarchy-org-agenda--timer
        (run-with-idle-timer 0.5 nil #'omarchy-org-agenda--push-export reason)))

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

(defun omarchy-org-agenda-ensure (output &optional files push upcoming)
  "Point the exporter at OUTPUT; idempotent, called by the plugin on every pull.
FILES overrides `org-agenda-files'.  PUSH installs the change hooks.
UPCOMING, an integer clamped to 0..31, sets
`omarchy-org-agenda-upcoming-days', the days of scheduled tasks and
timestamped entries (such as calendar events) exported after today;
nil, as older plugins send, keeps it.
Exports the hooks trigger use these settings too."
  (setq omarchy-org-agenda-output (expand-file-name output)
        omarchy-org-agenda-files-override files)
  (when (integerp upcoming)
    (setq omarchy-org-agenda-upcoming-days (min 31 (max 0 upcoming))))
  (unless (eq (and push t) omarchy-org-agenda--push)
    (omarchy-org-agenda--remove-push-hooks)
    (when push
      (add-hook 'after-save-hook #'omarchy-org-agenda--on-save)
      (add-hook 'after-revert-hook #'omarchy-org-agenda--on-revert)
      (add-hook 'org-after-todo-state-change-hook #'omarchy-org-agenda--on-todo)
      (add-hook 'org-agenda-finalize-hook #'omarchy-org-agenda--on-agenda)
      (add-variable-watcher 'org-agenda-files #'omarchy-org-agenda--on-files)
      (setq omarchy-org-agenda--push t)))
  t)

(defun omarchy-org-agenda--remove-push-hooks ()
  "Remove the hooks, watcher and export timer `omarchy-org-agenda-ensure' adds."
  (remove-hook 'after-save-hook #'omarchy-org-agenda--on-save)
  (remove-hook 'after-revert-hook #'omarchy-org-agenda--on-revert)
  (remove-hook 'org-after-todo-state-change-hook #'omarchy-org-agenda--on-todo)
  (remove-hook 'org-agenda-finalize-hook #'omarchy-org-agenda--on-agenda)
  (remove-variable-watcher 'org-agenda-files #'omarchy-org-agenda--on-files)
  (when (timerp omarchy-org-agenda--timer)
    (cancel-timer omarchy-org-agenda--timer))
  (setq omarchy-org-agenda--timer nil
        omarchy-org-agenda--push nil))

(defun omarchy-org-agenda-teardown ()
  "Remove every hook, watcher, advice and timer this package installed.
A note a state change left queued is dropped too, and the export index
is cleared."
  (omarchy-org-agenda--remove-push-hooks)
  (omarchy-org-agenda--drop-note)
  (setq omarchy-org-agenda--index nil)
  t)

(defun omarchy-org-agenda-unload-function ()
  "Tear down before `unload-feature', then let it continue."
  (omarchy-org-agenda-teardown)
  nil)

;;;; Click: open the source file at the entry's line

(defun omarchy-org-agenda--locate (path line &optional id local)
  "Marker for the entry at LINE of PATH.
When ID is given and the heading at LINE no longer carries it (the file
was edited since the export), follow the ID instead: within PATH only
when LOCAL is non-nil, else wherever Org's ID index says."
  (with-current-buffer (find-file-noselect path)
    (org-with-wide-buffer
     (goto-char (point-min))
     (forward-line (1- line))
     (or (and id
              (not (equal id (ignore-errors (org-entry-get nil "ID"))))
              (if local
                  (when-let* ((pos (org-find-entry-with-id id)))
                    (copy-marker pos))
                (org-id-find id 'marker)))
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

;;;; State change: `omarchy-org-agenda-set-state'
;;
;; Org queues a log note by putting `org-add-log-note' on the global
;; `post-command-hook'; `org-store-log-note' stores it, or drops it when
;; `org-note-abort' is set (C-c C-k).  The note's identity is the pair
;; `org-log-note-marker' / `org-log-note-effective-time': a copy of the
;; marker moves with it through edits, and every new note resets both.
;;
;; The save after a note can't use `org-after-note-stored-hook': Org 9.6
;; doesn't have it, and it never runs on cancel, which must clean up too.
;; A transient advice around `org-store-log-note' sees every outcome on
;; every version; it removes itself on the first store, ours or not.

(defun omarchy-org-agenda--detail (s)
  "S as a bounded, single-line detail string, or nil."
  (when (stringp s)
    (omarchy-org-agenda--clean (replace-regexp-in-string "[\0-\37\177]" " " s)
                               omarchy-org-agenda-max-detail)))

(defun omarchy-org-agenda--ascii (json)
  "JSON with every non-ASCII char as a \\u escape.
The output of `emacsclient --eval' then is plain ASCII, whatever the
client's locale; JSON allows non-ASCII only inside strings."
  (replace-regexp-in-string
   "[^[:ascii:]]"
   (lambda (s)
     (let ((c (string-to-char s)))
       (cond ((> c #x10ffff) "\\ufffd")
             ((> c #xffff)
              (let ((v (- c #x10000)))
                (format "\\u%04x\\u%04x"
                        (+ #xd800 (ash v -10)) (+ #xdc00 (logand v #x3ff)))))
             (t (format "\\u%04x" c)))))
   (if (multibyte-string-p json) json (decode-coding-string json 'utf-8 t))
   t t))

(defun omarchy-org-agenda--json-result (result)
  "RESULT, a plist (:result :state :saved :detail), as a JSON string."
  (omarchy-org-agenda--ascii
   (json-serialize
    (list :result (plist-get result :result)
          :state (or (plist-get result :state) :null)
          :saved (if (plist-get result :saved) t :false)
          :detail (or (omarchy-org-agenda--detail (plist-get result :detail))
                      :null)))))

(defun omarchy-org-agenda--nullish (v)
  "V, with JSON's `:null' as nil."
  (unless (eq v :null) v))

(defun omarchy-org-agenda--note-queued-p ()
  "Non-nil when Org has a note queued on the global `post-command-hook'."
  (memq #'org-add-log-note (default-value 'post-command-hook)))

(defun omarchy-org-agenda--busy-p ()
  "Non-nil while a note is queued or being written.
Another state change would retarget Org's single pending note."
  (or (omarchy-org-agenda--note-queued-p)
      (buffer-live-p (get-buffer "*Org Note*"))))

(defun omarchy-org-agenda--our-note-p ()
  "Non-nil when Org's pending note is the one recorded in `--note'."
  (when-let* ((note omarchy-org-agenda--note)
              (ours (plist-get note :marker))
              (buf (marker-buffer org-log-note-marker)))
    (and (eq buf (marker-buffer ours))
         (= org-log-note-marker ours)
         (equal org-log-note-effective-time (plist-get note :time)))))

(defun omarchy-org-agenda--forget-note ()
  "Stop tracking our note: its timer, its marker and the store advice."
  (when-let* ((note omarchy-org-agenda--note))
    (when (timerp (plist-get note :timer))
      (cancel-timer (plist-get note :timer)))
    (set-marker (plist-get note :marker) nil))
  (advice-remove 'org-store-log-note #'omarchy-org-agenda--around-store-note)
  (setq omarchy-org-agenda--note nil))

(defun omarchy-org-agenda--drop-note ()
  "Unqueue our note if Org still has it queued, then forget it."
  (when (and (omarchy-org-agenda--note-queued-p)
             (omarchy-org-agenda--our-note-p))
    (remove-hook 'post-command-hook #'org-add-log-note)
    (setq org-log-setup nil))
  (omarchy-org-agenda--forget-note))

(defun omarchy-org-agenda--expire-note ()
  "Drop our note if it is still queued: no frame came to take it."
  (when (and (omarchy-org-agenda--note-queued-p)
             (omarchy-org-agenda--our-note-p))
    (omarchy-org-agenda--drop-note)))

(defun omarchy-org-agenda--track-note (save &optional timeout)
  "Record Org's pending note as ours; SAVE its buffer once it is stored.
With TIMEOUT, drop the note after that many seconds unless taken."
  (omarchy-org-agenda--forget-note)
  (setq omarchy-org-agenda--note
        (list :marker (copy-marker org-log-note-marker)
              :time org-log-note-effective-time
              :save save
              :timer (and timeout
                          (run-at-time timeout nil
                                       #'omarchy-org-agenda--expire-note))))
  (advice-add 'org-store-log-note :around
              #'omarchy-org-agenda--around-store-note))

(defun omarchy-org-agenda--save (buf)
  "Save BUF without prompting; return (SAVED . DETAIL)."
  (condition-case err
      (with-current-buffer buf
        (if (not (verify-visited-file-modtime buf))
            (cons nil "the file changed on disk")
          (let ((save-silently t)
                (inhibit-message t)
                (require-final-newline (and (not (eq require-final-newline 'ask))
                                            require-final-newline)))
            (save-buffer)
            (cons t nil))))
    (error (cons nil (error-message-string err)))))

(defun omarchy-org-agenda--around-store-note (store &rest args)
  "Call STORE (`org-store-log-note') with ARGS; save after our note.
Removes itself first: any store ends the note it was waiting for."
  (let* ((note omarchy-org-agenda--note)
         (buf (marker-buffer org-log-note-marker))
         (save (and (omarchy-org-agenda--our-note-p)
                    (not org-note-abort)
                    (plist-get note :save))))
    (omarchy-org-agenda--forget-note)
    (prog1 (apply store args)
      (when (and save (buffer-live-p buf))
        (omarchy-org-agenda--save buf)))))

(defun omarchy-org-agenda--graphic-frame-p ()
  "Non-nil when the selected frame is a visible graphic frame."
  (and (display-graphic-p) (eq t (frame-visible-p (selected-frame)))))

(defun omarchy-org-agenda--refuse-prompt (&rest _)
  "Stand-in for Emacs's lock and supersession questions: refuse."
  (error "The file is locked or changed on disk"))

(defun omarchy-org-agenda--changed ()
  "The `changed' result, with an export to refresh the bar."
  (when omarchy-org-agenda-output
    (omarchy-org-agenda--schedule "changed"))
  (list :result "changed"))

(defun omarchy-org-agenda--valid-args-p (path line id from to)
  "Non-nil when PATH, LINE, ID, FROM and TO have the expected types."
  (and (stringp path) (file-name-absolute-p path)
       (natnump line) (> line 0)
       (or (null id) (stringp id))
       (or (null from) (stringp from))
       (stringp to)))

(defun omarchy-org-agenda--entry-matches-p (marker buf entry id from)
  "Non-nil when MARKER is still the heading the bar showed.
It must be in BUF, at a heading whose title and keyword match the
index ENTRY, and FROM; and the index's ID, if any, must be ID."
  (and (eq (marker-buffer marker) buf)
       (or (null id) (equal id (omarchy-org-agenda--nullish (plist-get entry :id))))
       (with-current-buffer buf
         (org-with-wide-buffer
          (goto-char marker)
          (and (org-at-heading-p)
               (equal (omarchy-org-agenda--title) (plist-get entry :title))
               (let ((todo (org-get-todo-state)))
                 (and (equal todo from)
                      (equal todo (omarchy-org-agenda--nullish
                                   (plist-get entry :todo))))))))))

(defun omarchy-org-agenda--apply (buf marker to)
  "Run `org-todo' TO on the entry at MARKER in BUF, in a widened view.
Return (:changed BOOL :state KEYWORD :blocking STRING)."
  (with-current-buffer buf
    (org-with-wide-buffer
     (goto-char marker)
     (let ((tick (buffer-chars-modified-tick))
           (org-block-entry-blocking nil))
       (save-window-excursion (org-todo to))
       (list :changed (/= tick (buffer-chars-modified-tick))
             :state (save-excursion (goto-char marker) (org-get-todo-state))
             :blocking org-block-entry-blocking)))))

(defun omarchy-org-agenda--finish-log (was-modified)
  "Handle the log Org queued for a state change; return a result plist.
Time and state logs are stored now, out of sight.  A note opens in a
visible graphic frame (`note'), else stays queued for
`omarchy-org-agenda-take-note' (`note-frame').  WAS-MODIFIED says the
buffer had unsaved edits before the change, so it isn't saved."
  (if (memq org-log-note-how '(time state))
      (progn
        (save-window-excursion (org-add-log-note))
        (list :result "done"))
    (if (omarchy-org-agenda--graphic-frame-p)
        (progn
          (omarchy-org-agenda--track-note (not was-modified))
          (org-add-log-note)
          (list :result "note"))
      ;; No frame to show it in: only `omarchy-org-agenda-take-note' may
      ;; open it, never whatever command the user runs next.
      (setq org-log-note-this-command 'omarchy-org-agenda-take-note)
      (omarchy-org-agenda--track-note (not was-modified)
                                      omarchy-org-agenda-note-timeout)
      (list :result "note-frame"))))

(defun omarchy-org-agenda--change (path line id from to entry)
  "Change the indexed ENTRY at LINE (or ID) of PATH from FROM to TO."
  (let* ((buf (or (find-buffer-visiting path)
                  (let ((large-file-warning-threshold nil))
                    (find-file-noselect path t))))
         (marker (omarchy-org-agenda--locate path line id t)))
    (cond
     ((not (omarchy-org-agenda--entry-matches-p marker buf entry id from))
      (omarchy-org-agenda--changed))
     ((not (member to (buffer-local-value 'org-todo-keywords-1 buf)))
      (list :result "invalid" :detail (concat to " isn't a keyword of this file")))
     ((equal from to)
      (list :result "done" :state to
            :saved (not (buffer-modified-p buf))))
     (t
      (let* ((was-modified (buffer-modified-p buf))
             (change (omarchy-org-agenda--apply buf marker to))
             (state (plist-get change :state))
             (result
              (cond ((not (plist-get change :changed))
                     (list :result "blocked"
                           :detail (org-string-nw-p (plist-get change :blocking))))
                    ((omarchy-org-agenda--note-queued-p)
                     (omarchy-org-agenda--finish-log was-modified))
                    (t (list :result "done")))))
        (if (and (equal (plist-get result :result) "done") (not was-modified))
            (pcase-let ((`(,saved . ,detail) (omarchy-org-agenda--save buf)))
              (append (list :state state :saved saved :detail detail) result))
          (append (list :state (and (plist-get change :changed) state)) result)))))))

(defun omarchy-org-agenda--set-state (path line id from to)
  "The steps of `omarchy-org-agenda-set-state'; return a result plist."
  (let ((entry (and omarchy-org-agenda--index
                    (gethash (cons path line) omarchy-org-agenda--index)))
        (buf (and (stringp path) (find-buffer-visiting path))))
    (cond
     ((not (omarchy-org-agenda--valid-args-p path line id from to))
      (list :result "invalid" :detail "bad arguments"))
     ((omarchy-org-agenda--busy-p) (list :result "busy"))
     ((not (and entry (file-exists-p path))) (omarchy-org-agenda--changed))
     ((and buf (not (verify-visited-file-modtime buf)) (buffer-modified-p buf))
      (list :result "conflict"))
     (t
      (when (and buf (not (verify-visited-file-modtime buf)))
        (with-current-buffer buf (revert-buffer t t t)))
      (omarchy-org-agenda--change path line id from to entry)))))

(defun omarchy-org-agenda-set-state (path line id from to)
  "Change the TODO state of the exported entry at LINE of PATH to TO.
ID, when non-nil, finds the entry if lines moved.  FROM is the keyword
the bar showed (nil for none).  Called by the plugin through
`emacsclient --eval'; never prompts.

Returns a JSON string {result, state, saved, detail}.  result is one of
done, note, note-frame, blocked, changed, conflict, busy, invalid or
error; state is the keyword after the change; saved says the file was
saved, which happens when it had no unsaved edits before the change."
  (omarchy-org-agenda--json-result
   (condition-case err
       (let ((inhibit-message t))
         (cl-letf (((symbol-function 'ask-user-about-lock)
                    #'omarchy-org-agenda--refuse-prompt)
                   ((symbol-function 'ask-user-about-supersession-threat)
                    #'omarchy-org-agenda--refuse-prompt))
           (omarchy-org-agenda--set-state path line id from to)))
     (error (list :result "error" :detail (error-message-string err))))))

(defun omarchy-org-agenda-take-note ()
  "Open the note a state change left queued, in the selected frame.
Returns t, or nil when there is no such note any more."
  (when (and (omarchy-org-agenda--note-queued-p)
             (omarchy-org-agenda--our-note-p))
    (let ((note omarchy-org-agenda--note))
      (when (timerp (plist-get note :timer))
        (cancel-timer (plist-get note :timer)))
      (setq omarchy-org-agenda--note (plist-put note :timer nil)))
    ;; Org 9.6+ only opens a note from the command that queued it.
    (let ((this-command org-log-note-this-command))
      (setq org-log-note-recursion-depth (recursion-depth))
      (org-add-log-note))
    t))

;; Updated on every load, not just the first, so the plugin's mtime check
;; sees the version that is actually loaded.
(setq omarchy-org-agenda--source-mtime
      (when-let* ((file (or load-file-name buffer-file-name)))
        (file-attribute-modification-time (file-attributes file))))

(provide 'omarchy-org-agenda)
;;; omarchy-org-agenda.el ends here
