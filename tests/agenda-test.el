;;; agenda-test.el --- ERT tests for omarchy-org-agenda  -*- lexical-binding: t; -*-

;; Run with tests/run.sh, which isolates HOME and the XDG directories.
;; Fixtures are generated in a temp dir with dates relative to today.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'org-habit)
(require 'org-id)
(require 'omarchy-org-agenda)

(defconst omarchy-org-agenda-test--source
  (expand-file-name "../elisp/omarchy-org-agenda.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The helper under test, in the repo.")

(defconst omarchy-org-agenda-test--root
  (file-name-as-directory (make-temp-file "omarchy-org-agenda-test-" t))
  "Scratch directory for every fixture and every file Org persists.")

(add-hook 'kill-emacs-hook
          (lambda () (delete-directory omarchy-org-agenda-test--root t)))

;; Belt and braces on top of run.sh's isolated HOME: Org must not write
;; into the user's real config or cache.
(setq org-id-locations-file
      (expand-file-name "org-id-locations" omarchy-org-agenda-test--root)
      org-persist-directory
      (expand-file-name "org-persist/" omarchy-org-agenda-test--root)
      org-element-cache-persistent nil)

;;;; Fixtures

(defun omarchy-org-agenda-test--day (offset)
  "Decoded time of noon, OFFSET days from today."
  (let ((now (decode-time)))
    (setf (decoded-time-hour now) 12
          (decoded-time-minute now) 0
          (decoded-time-second now) 0)
    (decoded-time-add now (make-decoded-time :day offset))))

(defun omarchy-org-agenda-test--ts (offset &optional range repeater)
  "Active Org timestamp OFFSET days from today.
RANGE is a time range like \"13:00-13:30\", REPEATER one like \".+1d\"."
  (let ((system-time-locale "C"))
    (format "<%s>"
            (string-join
             (delq nil (list (format-time-string
                              "%F %a"
                              (encode-time (omarchy-org-agenda-test--day offset)))
                             range
                             repeater))
             " "))))

(defconst omarchy-org-agenda-test--long-title
  (concat "Long " (mapconcat #'identity (make-list 60 "word") " "))
  "A title well over the 200 character bound.")

(defun omarchy-org-agenda-test--fixture-text ()
  "The main fixture: one heading per case the exporter must handle."
  (let ((ts #'omarchy-org-agenda-test--ts)
        (today (omarchy-org-agenda-test--day 0)))
    (concat
     "#+TODO: NEXT TODO WAIT | DONE CANCELED\n\n"
     "* NEXT [#A] Timed meeting today\n"
     "SCHEDULED: " (funcall ts 0 "13:00-13:30") "\n"
     ":PROPERTIES:\n:ID: fixture-timed\n:END:\n"
     "* TODO Overdue task with [[https://example.com][a link]]   :work:\n"
     "SCHEDULED: " (funcall ts -12) "\n"
     ":PROPERTIES:\n:ID: fixture-overdue\n:END:\n"
     "* WAIT Deadline today\n"
     "DEADLINE: " (funcall ts 0) "\n"
     "* TODO Upcoming deadline\n"
     "DEADLINE: " (funcall ts 3) "\n"
     "* TODO <img src=\"https://example.invalid/x\"> markup-shaped title\n"
     "SCHEDULED: " (funcall ts 0) "\n"
     "* DONE Finished earlier today\n"
     "SCHEDULED: " (funcall ts 0) "\n"
     "* Birthday\n"
     (format "%%%%(org-anniversary 1990 %d %d) Someone is %%d years old\n"
             (decoded-time-month today) (decoded-time-day today))
     "* TODO Daily habit\n"
     "SCHEDULED: " (funcall ts -2 nil ".+1d") "\n"
     ":PROPERTIES:\n:STYLE: habit\n:END:\n"
     "* [#A] TODO Malformed priority before keyword\n"
     "SCHEDULED: " (funcall ts 0) "\n"
     "* TODO Not on the agenda today\n"
     "SCHEDULED: " (funcall ts 20) "\n"
     "* TODO " omarchy-org-agenda-test--long-title "\n"
     "SCHEDULED: " (funcall ts 0) "\n")))

(defun omarchy-org-agenda-test--write (file text)
  "Write TEXT to FILE and return FILE."
  (with-temp-file file (insert text))
  file)

(defun omarchy-org-agenda-test--small (dir name)
  "Write a one-heading fixture NAME.org in DIR; return its path."
  (omarchy-org-agenda-test--write
   (expand-file-name (concat name ".org") dir)
   (concat "* TODO Item in " name "\n"
           "SCHEDULED: " (omarchy-org-agenda-test--ts 0) "\n")))

(defun omarchy-org-agenda-test--kill-buffers (dir)
  "Kill every buffer visiting a file under DIR, discarding changes."
  (dolist (buf (buffer-list))
    (when-let* ((file (buffer-file-name buf)))
      (when (file-in-directory-p file dir)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(defmacro omarchy-org-agenda-test--with-dir (spec &rest body)
  "Run BODY with (car SPEC) bound to a fresh temp dir and clean state.
The agenda file variables are let-bound, so `omarchy-org-agenda-ensure'
cannot leak settings into other tests; hooks, timers and buffers are
cleaned up afterwards."
  (declare (indent 1) (debug ((symbolp) body)))
  (let ((dir (car spec)))
    `(let ((,dir (file-name-as-directory
                  (make-temp-file
                   (expand-file-name "case-" omarchy-org-agenda-test--root) t)))
           (org-agenda-files nil)
           (omarchy-org-agenda-files nil)
           (omarchy-org-agenda-files-override nil)
           (omarchy-org-agenda-output nil))
       (unwind-protect (progn ,@body)
         (omarchy-org-agenda-teardown)
         (omarchy-org-agenda-test--kill-buffers ,dir)
         (delete-directory ,dir t)))))

;;;; Reading the payload

(defun omarchy-org-agenda-test--read (out)
  "The JSON payload in OUT, as a plist."
  (json-parse-string (with-temp-buffer
                       (insert-file-contents out)
                       (buffer-string))
                     :object-type 'plist
                     :null-object :null
                     :false-object :false))

(defun omarchy-org-agenda-test--export (dir files &optional reason)
  "Export FILES (the plugin's override) to DIR/agenda.json; return the payload."
  (let ((out (expand-file-name "agenda.json" dir)))
    (omarchy-org-agenda-ensure out files nil)
    (omarchy-org-agenda-export reason)
    (omarchy-org-agenda-test--read out)))

(defun omarchy-org-agenda-test--items (payload)
  "The items of PAYLOAD, as a list."
  (append (plist-get payload :items) nil))

(defun omarchy-org-agenda-test--titles (payload)
  "The item titles of PAYLOAD, in order."
  (mapcar (lambda (item) (plist-get item :title))
          (omarchy-org-agenda-test--items payload)))

(defun omarchy-org-agenda-test--item (payload title)
  "The single item of PAYLOAD whose title contains TITLE."
  (let ((found (seq-filter (lambda (item)
                             (string-search title (plist-get item :title)))
                           (omarchy-org-agenda-test--items payload))))
    (should (= 1 (length found)))
    (car found)))

(defun omarchy-org-agenda-test--fixture-payload (dir)
  "Write the main fixture into DIR, export it and return (FILE . PAYLOAD)."
  (let ((file (omarchy-org-agenda-test--write
               (expand-file-name "fixture.org" dir)
               (omarchy-org-agenda-test--fixture-text))))
    (cons file (omarchy-org-agenda-test--export dir (list file) "test"))))

(defun omarchy-org-agenda-test--hooks-installed ()
  "How many of the package's hooks and watchers are installed, as a plist."
  (list :save (cl-count #'omarchy-org-agenda--on-save after-save-hook)
        :revert (cl-count #'omarchy-org-agenda--on-revert after-revert-hook)
        :todo (cl-count #'omarchy-org-agenda--on-todo
                        org-after-todo-state-change-hook)
        :agenda (cl-count #'omarchy-org-agenda--on-agenda
                          org-agenda-finalize-hook)
        :watcher (cl-count #'omarchy-org-agenda--on-files
                           (get-variable-watchers 'org-agenda-files))))

;;;; Tests

(ert-deftest omarchy-org-agenda-test-payload-shape ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let ((payload (cdr (omarchy-org-agenda-test--fixture-payload dir))))
      (should (equal 1 (plist-get payload :version)))
      (should (equal (format-time-string "%F") (plist-get payload :date)))
      (should (eq :null (plist-get payload :error)))
      (should (equal "test" (plist-get payload :reason)))
      (should (equal [] (plist-get payload :missing)))
      (should (equal ["NEXT" "TODO" "WAIT"]
                     (plist-get (plist-get payload :keywords) :todo)))
      (should (equal ["DONE" "CANCELED"]
                     (plist-get (plist-get payload :keywords) :done))))))

(ert-deftest omarchy-org-agenda-test-item-fields ()
  (omarchy-org-agenda-test--with-dir (dir)
    (pcase-let* ((`(,file . ,payload) (omarchy-org-agenda-test--fixture-payload dir))
                 (item (apply-partially #'omarchy-org-agenda-test--item payload)))
      (let ((timed (funcall item "Timed meeting today")))
        (should (equal "fixture-timed" (plist-get timed :id)))
        (should (equal "13:00" (plist-get timed :time)))
        ;; Org's `duration' is a float; the export rounds it to an integer.
        (should (eql 30 (plist-get timed :durationMin)))
        (should (equal "A" (plist-get timed :priority)))
        (should (equal "NEXT" (plist-get timed :todo)))
        (should (eq :false (plist-get timed :done)))
        (should (equal "Timed meeting today" (plist-get timed :title))))
      (let ((overdue (funcall item "Overdue task")))
        (should (equal "Overdue task with a link" (plist-get overdue :title)))
        (should (equal ["work"] (plist-get overdue :tags)))
        (should (equal 12 (plist-get overdue :overdueDays)))
        (should (equal "fixture-overdue" (plist-get overdue :id))))
      (let ((deadline (funcall item "Deadline today")))
        (should (equal "WAIT" (plist-get deadline :todo)))
        (should (eq :null (plist-get deadline :id)))
        (should (eq :null (plist-get deadline :time)))
        (should (eq :null (plist-get deadline :priority))))
      (let ((upcoming (funcall item "Upcoming deadline")))
        (should (equal "upcoming-deadline" (plist-get upcoming :type)))
        (should (equal 0 (plist-get upcoming :overdueDays))))
      (should (funcall item
                       "<img src=\"https://example.invalid/x\"> markup-shaped title"))
      (let ((done (funcall item "Finished earlier today")))
        (should (eq t (plist-get done :done)))
        (should (equal "DONE" (plist-get done :todo))))
      (let ((birthday (funcall item "years old")))
        (should (equal (format "Someone is %d years old"
                               (- (decoded-time-year (decode-time)) 1990))
                       (plist-get birthday :title)))
        (should (equal "sexp" (plist-get birthday :type))))
      (let ((habit (funcall item "Daily habit")))
        (should (eq t (plist-get habit :habit)))
        (should (equal 2 (plist-get habit :overdueDays))))
      (let ((malformed (funcall item "Malformed priority")))
        ;; Without a leading keyword Org sees no TODO state, so "TODO"
        ;; stays in the title.  The cookie right after the stars still
        ;; matches `org-complex-heading-regexp''s priority group, so Org
        ;; does report priority A for it.
        (should (eq :null (plist-get malformed :todo)))
        (should (equal "TODO Malformed priority before keyword"
                       (plist-get malformed :title)))
        (should (equal "A" (plist-get malformed :priority))))
      (should-not (member "Not on the agenda today"
                          (omarchy-org-agenda-test--titles payload)))
      (dolist (it (omarchy-org-agenda-test--items payload))
        (should (file-name-absolute-p (plist-get it :path)))
        (should (file-equal-p file (plist-get it :path)))
        (with-current-buffer (find-file-noselect (plist-get it :path))
          (org-with-wide-buffer
           (goto-char (point-min))
           (forward-line (1- (plist-get it :line)))
           (should (looking-at "^\\*"))))))))

(ert-deftest omarchy-org-agenda-test-bounds ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((payload (cdr (omarchy-org-agenda-test--fixture-payload dir)))
           (title (plist-get (omarchy-org-agenda-test--item payload "Long word")
                             :title)))
      (should (= 200 (length title)))
      (should (string-suffix-p "…" title))
      (should (string-prefix-p (substring title 0 199)
                               omarchy-org-agenda-test--long-title)))
    (let ((omarchy-org-agenda-max-items 3))
      (should (= 3 (length (plist-get (cdr (omarchy-org-agenda-test--fixture-payload dir))
                                      :items)))))))

(ert-deftest omarchy-org-agenda-test-ordering ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((titles (omarchy-org-agenda-test--titles
                    (cdr (omarchy-org-agenda-test--fixture-payload dir))))
           (pos (lambda (needle)
                  (seq-position titles needle
                                (lambda (title needle) (string-search needle title))))))
      ;; Org's default agenda strategy starts with (habit-down time-up ...):
      ;; habits sink below everything else, and among the rest timed
      ;; entries come before untimed ones, whatever their type or priority.
      ;; The order after that depends on Org's urgency arithmetic.
      (should (= 0 (funcall pos "Timed meeting today")))
      (dolist (untimed '("Deadline today" "Finished earlier today" "Overdue task"
                         "markup-shaped title" "Malformed priority" "years old"))
        (should (< (funcall pos "Timed meeting today") (funcall pos untimed)))
        (should (< (funcall pos untimed) (funcall pos "Daily habit")))))))

(ert-deftest omarchy-org-agenda-test-file-precedence ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let ((a (omarchy-org-agenda-test--small dir "A"))
          (b (omarchy-org-agenda-test--small dir "B"))
          (c (omarchy-org-agenda-test--small dir "C")))
      (setq org-agenda-files (list a)
            omarchy-org-agenda-files (list b))
      (should (equal '("Item in C")
                     (omarchy-org-agenda-test--titles
                      (omarchy-org-agenda-test--export dir (list c)))))
      (should (equal '("Item in B")
                     (omarchy-org-agenda-test--titles
                      (omarchy-org-agenda-test--export dir nil))))
      (setq omarchy-org-agenda-files nil)
      (should (equal '("Item in A")
                     (omarchy-org-agenda-test--titles
                      (omarchy-org-agenda-test--export dir nil)))))))

(ert-deftest omarchy-org-agenda-test-missing-file ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let ((a (omarchy-org-agenda-test--small dir "A"))
          (gone (expand-file-name "gone.org" dir)))
      ;; Any prompt fails the export loudly instead of reading stdin.
      (cl-letf (((symbol-function 'read-char-exclusive)
                 (lambda (&rest _) (error "Prompted")))
                ((symbol-function 'read-from-minibuffer)
                 (lambda (&rest _) (error "Prompted"))))
        (let ((payload (omarchy-org-agenda-test--export dir (list a gone))))
          (should (eq :null (plist-get payload :error)))
          (should (equal '("Item in A") (omarchy-org-agenda-test--titles payload)))
          (should (equal (vector gone) (plist-get payload :missing))))))))

(ert-deftest omarchy-org-agenda-test-error-payload ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let ((a (omarchy-org-agenda-test--small dir "A")))
      (cl-letf (((symbol-function 'omarchy-org-agenda--entries)
                 (lambda (&rest _) (error "boom"))))
        (let ((payload (omarchy-org-agenda-test--export dir (list a) "test")))
          (should (equal "boom" (plist-get payload :error)))
          (should (equal [] (plist-get payload :items)))
          (should (equal [] (plist-get payload :missing)))
          (should (equal 1 (plist-get payload :version)))
          (should (equal (format-time-string "%F") (plist-get payload :date)))
          (should (equal "test" (plist-get payload :reason)))
          (should (stringp (plist-get payload :generatedAt)))
          (should (equal emacs-version (plist-get payload :emacs)))
          (should (equal (org-version) (plist-get payload :org))))))))

(ert-deftest omarchy-org-agenda-test-atomic-write ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((a (omarchy-org-agenda-test--small dir "A"))
           (out-dir (expand-file-name "not/yet/there/" dir))
           (out (expand-file-name "agenda.json" out-dir)))
      (omarchy-org-agenda-ensure out (list a) nil)
      (should (omarchy-org-agenda-export))
      (should (file-exists-p out))
      (should-not (file-exists-p (concat out ".tmp")))
      (should (equal '("agenda.json")
                     (directory-files out-dir nil
                                      directory-files-no-dot-files-regexp))))))

(ert-deftest omarchy-org-agenda-test-locate ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((file (car (omarchy-org-agenda-test--fixture-payload dir)))
           (copy (expand-file-name "copy.org" dir))
           (stale (with-temp-buffer
                    (insert-file-contents file)
                    (re-search-forward "^\\* TODO Overdue")
                    (line-number-at-pos))))
      (copy-file file copy)
      (with-current-buffer (find-file-noselect copy)
        (goto-char (point-min))
        (forward-line 2)
        (insert "* Inserted 1\n* Inserted 2\n* Inserted 3\n")
        (save-buffer))
      (org-id-add-location "fixture-overdue" copy)
      ;; The ID moved: follow it to the heading.
      (let ((marker (omarchy-org-agenda--locate copy stale "fixture-overdue")))
        (with-current-buffer (marker-buffer marker)
          (should (file-equal-p copy buffer-file-name))
          (goto-char marker)
          (should (looking-at "^\\* TODO Overdue"))))
      ;; No ID: trust the line.
      (let ((marker (omarchy-org-agenda--locate copy stale)))
        (with-current-buffer (marker-buffer marker)
          (should (= stale (line-number-at-pos marker)))))
      ;; The entry at the stale line now belongs to the timed meeting; its
      ;; own ID matches, so the line is trusted.
      (let ((marker (omarchy-org-agenda--locate copy stale "fixture-timed")))
        (with-current-buffer (marker-buffer marker)
          (should (= stale (line-number-at-pos marker))))))))

(ert-deftest omarchy-org-agenda-test-goto ()
  (omarchy-org-agenda-test--with-dir (dir)
    (pcase-let* ((`(,file . ,payload) (omarchy-org-agenda-test--fixture-payload dir))
                 (line (plist-get (omarchy-org-agenda-test--item payload "Overdue")
                                  :line)))
      (save-window-excursion
        (should (eq t (omarchy-org-agenda-goto file line)))
        (should (file-equal-p file (buffer-file-name (window-buffer))))
        (with-current-buffer (window-buffer)
          (should (= line (line-number-at-pos (window-point))))
          (should (looking-at "^\\* TODO Overdue")))))))

(ert-deftest omarchy-org-agenda-test-push-hooks ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let ((out (expand-file-name "agenda.json" dir))
          (none '(:save 0 :revert 0 :todo 0 :agenda 0 :watcher 0))
          (once '(:save 1 :revert 1 :todo 1 :agenda 1 :watcher 1)))
      (should (equal none (omarchy-org-agenda-test--hooks-installed)))
      (omarchy-org-agenda-ensure out nil t)
      (should (equal once (omarchy-org-agenda-test--hooks-installed)))
      (omarchy-org-agenda-ensure out nil t)
      (should (equal once (omarchy-org-agenda-test--hooks-installed)))
      (omarchy-org-agenda-ensure out nil nil)
      (should (equal none (omarchy-org-agenda-test--hooks-installed)))
      (omarchy-org-agenda-ensure out nil t)
      (omarchy-org-agenda--schedule "test")
      (let ((timer omarchy-org-agenda--timer))
        (should (timerp timer))
        (omarchy-org-agenda-teardown)
        (should-not omarchy-org-agenda--timer)
        (should-not (memq timer timer-idle-list)))
      (should (equal none (omarchy-org-agenda-test--hooks-installed)))
      (should-not (get-variable-watchers 'org-agenda-files)))))

(ert-deftest omarchy-org-agenda-test-debounce ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let ((org (omarchy-org-agenda-test--small dir "A"))
          (txt (omarchy-org-agenda-test--write
                (expand-file-name "notes.txt" dir) "plain\n")))
      (omarchy-org-agenda-ensure (expand-file-name "agenda.json" dir) nil t)
      (with-current-buffer (find-file-noselect txt)
        (insert "more\n")
        (save-buffer))
      (should-not omarchy-org-agenda--timer)
      (with-current-buffer (find-file-noselect org)
        (should (derived-mode-p 'org-mode))
        (goto-char (point-max))
        (insert "* TODO Another\n")
        (save-buffer))
      (should (timerp omarchy-org-agenda--timer)))))

(ert-deftest omarchy-org-agenda-test-files-watcher ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let ((a (omarchy-org-agenda-test--small dir "A"))
          (out (expand-file-name "agenda.json" dir)))
      (cl-flet ((scheduled-by (fn)
                  (omarchy-org-agenda-teardown)
                  (omarchy-org-agenda-ensure out
                                             omarchy-org-agenda-files-override
                                             t)
                  (funcall fn)
                  (timerp omarchy-org-agenda--timer)))
        (should (scheduled-by (lambda () (setq org-agenda-files (list a)))))
        ;; The export's own `let' of `org-agenda-files' is ignored.
        (should-not (scheduled-by #'omarchy-org-agenda-export))
        (setq omarchy-org-agenda-files-override (list a))
        (should-not (scheduled-by (lambda () (setq org-agenda-files nil))))
        (setq omarchy-org-agenda-files-override nil
              omarchy-org-agenda-files (list a))
        (should-not (scheduled-by (lambda () (setq org-agenda-files (list a)))))))))

(ert-deftest omarchy-org-agenda-test-pull-form-reload ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((copy (expand-file-name "omarchy-org-agenda.el" dir))
           (fixture (omarchy-org-agenda-test--small dir "A"))
           (out (expand-file-name "agenda.json" dir))
           (form (car (read-from-string
                       (format "(progn
  (unless (and (boundp 'omarchy-org-agenda--source-mtime)
               (equal omarchy-org-agenda--source-mtime
                      (file-attribute-modification-time (file-attributes %S))))
    (load %S nil t))
  (omarchy-org-agenda-ensure %S (list %S) nil)
  (omarchy-org-agenda-export %S))"
                               copy copy out fixture "pull"))))
           (loads 0)
           (count-loads (lambda (file)
                          (when (file-equal-p file copy) (cl-incf loads)))))
      (copy-file omarchy-org-agenda-test--source copy)
      (set-file-times copy (time-subtract nil 3600))
      (add-hook 'after-load-functions count-loads)
      (unwind-protect
          (progn
            (should (eval form t))
            (should (= 1 loads))
            (should (eval form t))
            (should (= 1 loads))
            (set-file-times copy (time-add nil 3600))
            (should (eval form t))
            (should (= 2 loads))
            (should (equal '("Item in A")
                           (omarchy-org-agenda-test--titles
                            (omarchy-org-agenda-test--read out)))))
        (remove-hook 'after-load-functions count-loads)
        ;; Back to the repo's definitions for the remaining tests.
        (load omarchy-org-agenda-test--source nil t)))))

;; Named to run last; it reloads the helper anyway, so order doesn't matter.
(ert-deftest omarchy-org-agenda-test-zz-unload ()
  (let ((out (expand-file-name "unload/agenda.json" omarchy-org-agenda-test--root)))
    (unwind-protect
        (progn
          (omarchy-org-agenda-ensure out nil t)
          (should (equal '(:save 1 :revert 1 :todo 1 :agenda 1 :watcher 1)
                         (omarchy-org-agenda-test--hooks-installed)))
          (unload-feature 'omarchy-org-agenda t)
          (should-not (featurep 'omarchy-org-agenda))
          (dolist (hook '(after-save-hook after-revert-hook
                          org-after-todo-state-change-hook org-agenda-finalize-hook))
            (should-not (seq-filter
                         (lambda (fn)
                           (and (symbolp fn)
                                (string-prefix-p "omarchy-org-agenda-"
                                                 (symbol-name fn))))
                         (symbol-value hook))))
          (should-not (get-variable-watchers 'org-agenda-files)))
      (load omarchy-org-agenda-test--source nil t)
      (setq omarchy-org-agenda-output nil
            omarchy-org-agenda-files-override nil))))

;;; agenda-test.el ends here
