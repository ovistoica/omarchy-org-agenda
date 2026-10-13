;;; omarchy-org-agenda.el --- Today's Org agenda for the Omarchy bar  -*- lexical-binding: t; -*-

;; Loaded into the user's running Emacs server by the Omarchy plugin through
;; emacsclient.  Nothing runs on load: the plugin calls
;; `omarchy-org-agenda-ensure' and `omarchy-org-agenda-export', and
;; `omarchy-org-agenda-teardown' removes every hook this file adds.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'seq)

(defconst omarchy-org-agenda-version "0.1.0")
(defconst omarchy-org-agenda-protocol 1)

(defvar omarchy-org-agenda-output nil
  "Absolute path of the JSON file the Omarchy bar watches.")

(defvar omarchy-org-agenda-files-override nil
  "When non-nil, files/directories used instead of `org-agenda-files'.")

(defvar omarchy-org-agenda-max-items 200)
(defvar omarchy-org-agenda-max-title 200)

(defvar omarchy-org-agenda--timer nil)
(defvar omarchy-org-agenda--push nil)
(defvar omarchy-org-agenda--exporting nil)

;;;; Extraction

(defun omarchy-org-agenda--prop (entry key)
  (get-text-property 0 key entry))

(defun omarchy-org-agenda--clean (s &optional max)
  (when s
    (let ((s (string-trim (substring-no-properties s))))
      (if (and max (> (length s) max))
          (concat (substring s 0 (1- max)) "…")
        s))))

(defun omarchy-org-agenda--priority ()
  "The explicit priority cookie of the heading at point, or nil."
  (save-excursion
    (org-back-to-heading t)
    (when (looking-at org-complex-heading-regexp)
      (let ((cookie (match-string-no-properties 3)))
        (and cookie (substring cookie 2 3))))))

(defun omarchy-org-agenda--item (entry today)
  (let ((marker (or (omarchy-org-agenda--prop entry 'org-hd-marker)
                    (omarchy-org-agenda--prop entry 'org-marker)))
        (type (omarchy-org-agenda--prop entry 'type))
        (tod (omarchy-org-agenda--prop entry 'time-of-day))
        (ts (omarchy-org-agenda--prop entry 'ts-date))
        (todo (omarchy-org-agenda--clean (omarchy-org-agenda--prop entry 'todo-state))))
    (org-with-point-at marker
      (list :id (or (org-entry-get nil "ID") :null)
            :path (buffer-file-name (buffer-base-buffer))
            :line (line-number-at-pos)
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
            :durationMin (or (omarchy-org-agenda--prop entry 'duration) :null)
            :overdueDays (if (and ts (< ts today)) (- today ts) 0)
            :habit (if (omarchy-org-agenda--prop entry 'org-habit-p) t :false)))))

(defun omarchy-org-agenda--entries ()
  "Today's agenda entries, sorted like the user's own day agenda."
  (let* ((org-agenda-files (or omarchy-org-agenda-files-override org-agenda-files))
         (org-agenda-sorting-strategy-selected nil)
         (date (calendar-current-date))
         (files (org-agenda-files nil 'ifmode)))
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
  (let ((colors (make-hash-table :test #'equal)))
    (dolist (kwd org-todo-keywords-for-agenda)
      (when-let* ((color (omarchy-org-agenda--color kwd)))
        (puthash kwd color colors)))
    (list :todo (vconcat (seq-difference org-todo-keywords-for-agenda
                                         org-done-keywords-for-agenda))
          :done (vconcat org-done-keywords-for-agenda)
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
Errors are written into the file too, so the bar can show them."
  (let* ((omarchy-org-agenda--exporting t)
         (today (calendar-absolute-from-gregorian (calendar-current-date)))
         (base (list :version omarchy-org-agenda-protocol
                     :date (format-time-string "%F")
                     :generatedAt (format-time-string "%FT%T%z")
                     :reason (or reason "pull")
                     :emacs emacs-version
                     :org (org-version))))
    (omarchy-org-agenda--write
     (condition-case err
         (let ((entries (seq-take (omarchy-org-agenda--entries)
                                  omarchy-org-agenda-max-items)))
           (append base
                   (list :keywords (omarchy-org-agenda--keywords)
                         :items (vconcat (mapcar (lambda (e) (omarchy-org-agenda--item e today))
                                                 entries))
                         :error :null)))
       (error (append base (list :items [] :error (error-message-string err))))))
    t))

;;;; Push: re-export when the agenda can have changed

(defun omarchy-org-agenda--schedule (reason)
  (when (timerp omarchy-org-agenda--timer)
    (cancel-timer omarchy-org-agenda--timer))
  (setq omarchy-org-agenda--timer
        (run-with-idle-timer 0.5 nil #'omarchy-org-agenda-export reason)))

(defun omarchy-org-agenda--on-save ()
  (when (derived-mode-p 'org-mode) (omarchy-org-agenda--schedule "save")))

(defun omarchy-org-agenda--on-revert ()
  (when (derived-mode-p 'org-mode) (omarchy-org-agenda--schedule "revert")))

(defun omarchy-org-agenda--on-todo ()
  (omarchy-org-agenda--schedule "todo"))

(defun omarchy-org-agenda--on-agenda ()
  (omarchy-org-agenda--schedule "agenda"))

(defun omarchy-org-agenda--on-files (_symbol _newval operation _where)
  ;; `set' only: our own `let' of `org-agenda-files' must not re-trigger.
  (when (and (eq operation 'set) (not omarchy-org-agenda--exporting))
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
Unfolds the entry so the heading is visible.  See `omarchy-org-agenda--locate'."
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

(provide 'omarchy-org-agenda)
;;; omarchy-org-agenda.el ends here
