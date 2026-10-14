;;; agenda-test.el --- ERT tests for omarchy-org-agenda  -*- lexical-binding: t; -*-

;; Run with tests/run.sh, which isolates HOME and the XDG directories.
;; Fixtures are generated in a temp dir with dates relative to today.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'org-clock)
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
           ;; A week starting today: 6 later days, whatever today is.
           (org-agenda-start-on-weekday nil)
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

(defconst omarchy-org-agenda-test--clock-hooks
  '(org-clock-in-hook org-clock-out-hook org-clock-cancel-hook)
  "org-clock's hooks the package must use.")

(defconst omarchy-org-agenda-test--pomodoro-hooks
  '(org-pomodoro-started-hook org-pomodoro-finished-hook
    org-pomodoro-overtime-hook org-pomodoro-killed-hook
    org-pomodoro-break-finished-hook)
  "org-pomodoro's hooks the package must use.")

(defun omarchy-org-agenda-test--count-in-hooks (fn hooks)
  "How many times FN is on the global value of HOOKS, unbound ones included."
  (apply #'+ (mapcar (lambda (hook)
                       (if (default-boundp hook)
                           (cl-count fn (default-value hook))
                         0))
                     hooks)))

(defun omarchy-org-agenda-test--hooks-installed ()
  "How many of the package's hooks and watchers are installed, as a plist.
:clock and :pomodoro add up over all of their hooks."
  (list :save (cl-count #'omarchy-org-agenda--on-save after-save-hook)
        :revert (cl-count #'omarchy-org-agenda--on-revert after-revert-hook)
        :todo (cl-count #'omarchy-org-agenda--on-todo
                        org-after-todo-state-change-hook)
        :agenda (cl-count #'omarchy-org-agenda--on-agenda
                          org-agenda-finalize-hook)
        :watcher (cl-count #'omarchy-org-agenda--on-files
                           (get-variable-watchers 'org-agenda-files))
        :clock (omarchy-org-agenda-test--count-in-hooks
                #'omarchy-org-agenda--on-clock
                omarchy-org-agenda-test--clock-hooks)
        :pomodoro (omarchy-org-agenda-test--count-in-hooks
                   #'omarchy-org-agenda--on-pomodoro
                   omarchy-org-agenda-test--pomodoro-hooks)))

(defconst omarchy-org-agenda-test--no-hooks
  '(:save 0 :revert 0 :todo 0 :agenda 0 :watcher 0 :clock 0 :pomodoro 0)
  "`omarchy-org-agenda-test--hooks-installed' without push.")

(defconst omarchy-org-agenda-test--all-hooks
  '(:save 1 :revert 1 :todo 1 :agenda 1 :watcher 1 :clock 3 :pomodoro 5)
  "`omarchy-org-agenda-test--hooks-installed' with push: each hook once.")

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
                     (plist-get (plist-get payload :keywords) :done)))
      ;; The timers come last; nothing runs, org-pomodoro isn't around.
      (should (equal '(version date generatedAt reason emacs org keywords items
                               daysAhead missing error clock pomodoro)
                     (mapcar #'car (json-parse-string
                                    (omarchy-org-agenda-test--slurp
                                     (expand-file-name "agenda.json" dir))
                                    :object-type 'alist))))
      (should (eq :null (plist-get payload :clock)))
      (should (equal '(:available :false :state "none" :endsAt :null
                                  :phaseMin :null :count 0 :askKill t)
                     (plist-get payload :pomodoro))))))

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
        (should (equal "Timed meeting today" (plist-get timed :title)))
        (should (equal 0 (plist-get timed :inDays))))
      (let ((overdue (funcall item "Overdue task")))
        (should (equal "Overdue task with a link" (plist-get overdue :title)))
        (should (equal ["work"] (plist-get overdue :tags)))
        (should (equal 12 (plist-get overdue :overdueDays)))
        (should (equal 0 (plist-get overdue :inDays)))
        (should (equal "fixture-overdue" (plist-get overdue :id))))
      (let ((deadline (funcall item "Deadline today")))
        (should (equal "WAIT" (plist-get deadline :todo)))
        (should (eq :null (plist-get deadline :id)))
        (should (eq :null (plist-get deadline :time)))
        (should (eq :null (plist-get deadline :priority))))
      (let ((upcoming (funcall item "Upcoming deadline")))
        (should (equal "upcoming-deadline" (plist-get upcoming :type)))
        (should (equal 0 (plist-get upcoming :overdueDays)))
        (should (equal 3 (plist-get upcoming :inDays))))
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

;;;; Private output

(defun omarchy-org-agenda-test--slurp (file)
  "The contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun omarchy-org-agenda-test--mode (file)
  "The permission bits of FILE itself, a symlink not followed."
  (file-modes file 'nofollow))

(defmacro omarchy-org-agenda-test--with-out (spec &rest body)
  "Run BODY in a temp dir with an agenda file ready to export.
SPEC is (DIR OUT-DIR OUT VICTIMS): OUT is agenda.json in OUT-DIR, a
subdir of DIR that doesn't exist yet; `omarchy-org-agenda-ensure'
points at OUT.  VICTIMS is another temp dir, for the targets of
planted links."
  (declare (indent 1) (debug ((symbolp symbolp symbolp symbolp) body)))
  (pcase-let ((`(,dir ,out-dir ,out ,victims) spec))
    `(omarchy-org-agenda-test--with-dir (,dir)
       (let* ((,out-dir (expand-file-name "out/" ,dir))
              (,out (expand-file-name "agenda.json" ,out-dir))
              (,victims (make-temp-file
                         (expand-file-name "victims-" omarchy-org-agenda-test--root) t)))
         (unwind-protect
             (progn
               (omarchy-org-agenda-ensure
                ,out (list (omarchy-org-agenda-test--small ,dir "A")) nil)
               ,@body)
           (delete-directory ,victims t))))))

(defun omarchy-org-agenda-test--victim (dir)
  "A file in DIR that an export must never touch; return its name."
  (omarchy-org-agenda-test--write (expand-file-name "victim" dir) "precious\n"))

(ert-deftest omarchy-org-agenda-test-private-modes ()
  (omarchy-org-agenda-test--with-out (dir out-dir out victims)
    (let ((parent (expand-file-name "parent/" out-dir)))
      ;; Umask 022: what a plain `make-directory' and `write-region' get.
      (with-file-modes #o755
        (omarchy-org-agenda-ensure (expand-file-name "agenda.json" parent)
                                   omarchy-org-agenda-files-override nil)
        (should (omarchy-org-agenda-export)))
      (should (= #o700 (omarchy-org-agenda-test--mode out-dir)))
      (should (= #o700 (omarchy-org-agenda-test--mode parent)))
      (should (= #o600 (omarchy-org-agenda-test--mode
                        (expand-file-name "agenda.json" parent))))
      (should-not (file-exists-p (expand-file-name "agenda.json.tmp" parent))))))

(ert-deftest omarchy-org-agenda-test-private-tightens-own-dir ()
  (omarchy-org-agenda-test--with-out (dir out-dir out victims)
    (with-file-modes #o755 (make-directory out-dir))
    (should (= #o755 (omarchy-org-agenda-test--mode out-dir)))
    (should (omarchy-org-agenda-export))
    (should (= #o700 (omarchy-org-agenda-test--mode out-dir)))
    (should (= #o600 (omarchy-org-agenda-test--mode out)))
    (should (equal '("Item in A")
                   (omarchy-org-agenda-test--titles
                    (omarchy-org-agenda-test--read out))))))

(ert-deftest omarchy-org-agenda-test-private-tmp-symlink ()
  (omarchy-org-agenda-test--with-out (dir out-dir out victims)
    (let ((victim (omarchy-org-agenda-test--victim victims)))
      (make-directory out-dir)
      (make-symbolic-link victim (concat out ".tmp"))
      (should (omarchy-org-agenda-export))
      (should (equal "precious\n" (omarchy-org-agenda-test--slurp victim)))
      (should-not (file-symlink-p out))
      (should (file-regular-p out))
      (should (= #o600 (omarchy-org-agenda-test--mode out)))
      (should-not (file-exists-p (concat out ".tmp"))))))

(ert-deftest omarchy-org-agenda-test-private-out-symlink ()
  (omarchy-org-agenda-test--with-out (dir out-dir out victims)
    (let ((victim (omarchy-org-agenda-test--victim victims)))
      (make-directory out-dir)
      (make-symbolic-link victim out)
      (should (omarchy-org-agenda-export))
      (should (equal "precious\n" (omarchy-org-agenda-test--slurp victim)))
      (should-not (file-symlink-p out))
      (should (file-regular-p out))
      (should (= #o600 (omarchy-org-agenda-test--mode out)))
      (should (equal '("Item in A")
                     (omarchy-org-agenda-test--titles
                      (omarchy-org-agenda-test--read out)))))))

(ert-deftest omarchy-org-agenda-test-private-refuses-symlinked-dir ()
  (omarchy-org-agenda-test--with-out (dir out-dir out victims)
    (make-symbolic-link victims (directory-file-name out-dir))
    (should (string-match-p
             "\\`Unsafe agenda directory .*: not a private directory owned by you\\'"
             (cadr (should-error (omarchy-org-agenda-export)))))
    (should-not (directory-files victims nil directory-files-no-dot-files-regexp))
    ;; Nor a dangling one, which `make-directory' can't create over.
    (delete-file (directory-file-name out-dir))
    (make-symbolic-link (expand-file-name "nowhere" victims)
                        (directory-file-name out-dir))
    (should-error (omarchy-org-agenda-export))
    (should-not (directory-files victims nil directory-files-no-dot-files-regexp))))

(ert-deftest omarchy-org-agenda-test-private-refuses-foreign-owner ()
  (omarchy-org-agenda-test--with-out (dir out-dir out victims)
    (make-directory out-dir)
    ;; Someone else's directory, as seen from the uid we pretend to have;
    ;; root too owns test dirs, so this holds under any uid.
    (let ((uid (1+ (user-uid))))
      (cl-letf (((symbol-function 'user-uid) (lambda () uid)))
        (should-error (omarchy-org-agenda-export))))
    (should-not (directory-files out-dir nil directory-files-no-dot-files-regexp))))

(ert-deftest omarchy-org-agenda-test-private-push-never-signals ()
  (omarchy-org-agenda-test--with-out (dir out-dir out victims)
    (make-symbolic-link victims (directory-file-name out-dir))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        ;; What the hooks' idle timer runs.
        (omarchy-org-agenda--schedule "save")
        (let ((timer omarchy-org-agenda--timer))
          (should (eq #'omarchy-org-agenda--push-export (timer--function timer)))
          (should-not (apply (timer--function timer) (timer--args timer)))))
      (should (= 1 (length messages)))
      (should (string-match-p "Unsafe agenda directory" (car messages))))
    (should-not (directory-files victims nil directory-files-no-dot-files-regexp))))

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
          (none omarchy-org-agenda-test--no-hooks)
          (once omarchy-org-agenda-test--all-hooks))
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

;;;; State changes

(defun omarchy-org-agenda-test--state-text ()
  "The state-change fixture: fast keys, logging, blockers, an ID."
  (let ((today (concat "SCHEDULED: " (omarchy-org-agenda-test--ts 0) "\n")))
    (concat
     "#+TODO: NEXT(n@/!) TODO(t@/!) REPEAT(r) PROJ(p) | DONE(d@) CANCELED(c@)\n\n"
     "* REPEAT Alpha task\n" today
     "* PROJ Beta task\n" today
     ":PROPERTIES:\n:ID: state-beta\n:END:\n"
     "* PROJ Parent task\n" today
     "** NEXT Ședință copil\n"
     "* PROJ Checklist task\n" today
     "- [ ] First box\n"
     "* NEXT Gamma \"quoted\" task\n" today
     "* Plain heading\n" today)))

(defun omarchy-org-agenda-test--clear-notes ()
  "Forget any note Org has queued or open."
  (remove-hook 'post-command-hook #'org-add-log-note)
  (setq org-log-setup nil)
  (when (get-buffer "*Org Note*")
    (kill-buffer "*Org Note*")))

(defmacro omarchy-org-agenda-test--with-state (spec &rest body)
  "Run BODY with (FILE PAYLOAD) of SPEC bound to the exported state fixture.
Dependencies are enforced like a typical configuration."
  (declare (indent 1) (debug ((symbolp symbolp) body)))
  `(omarchy-org-agenda-test--with-dir (dir)
     (let* ((org-blocker-hook '(org-block-todo-from-checkboxes
                                org-block-todo-from-children-or-siblings-or-parent))
            (org-enforce-todo-dependencies t)
            (org-enforce-todo-checkbox-dependencies t)
            (org-log-into-drawer nil)
            (,(car spec) (omarchy-org-agenda-test--write
                          (expand-file-name "state.org" dir)
                          (omarchy-org-agenda-test--state-text)))
            (,(cadr spec) (omarchy-org-agenda-test--export dir (list ,(car spec)))))
       (ignore ,(cadr spec))
       (unwind-protect (progn ,@body)
         (omarchy-org-agenda-test--clear-notes)))))

(defun omarchy-org-agenda-test--line (payload title)
  "The line of the PAYLOAD item whose title contains TITLE."
  (plist-get (omarchy-org-agenda-test--item payload title) :line))

(defun omarchy-org-agenda-test--set-state (&rest args)
  "`omarchy-org-agenda-set-state' on ARGS, its JSON parsed to a plist."
  (let ((json (apply #'omarchy-org-agenda-set-state args)))
    (should (stringp json))
    (json-parse-string json :object-type 'plist
                       :null-object nil :false-object nil)))

(defun omarchy-org-agenda-test--disk (file)
  "FILE's contents on disk."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun omarchy-org-agenda-test--todo (file title)
  "The TODO keyword of the heading in FILE's buffer containing TITLE."
  (with-current-buffer (find-buffer-visiting file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (re-search-forward (concat "^\\*+ .*" (regexp-quote title)))
     (org-get-todo-state))))

(defun omarchy-org-agenda-test--edit (file fn)
  "Call FN in FILE's widened buffer, at the start."
  (with-current-buffer (find-buffer-visiting file)
    (org-with-wide-buffer (goto-char (point-min)) (funcall fn))))

(defun omarchy-org-agenda-test--rewrite (file from to)
  "Replace FROM with TO in FILE on disk, behind Emacs's back."
  (let ((text (omarchy-org-agenda-test--disk file)))
    (omarchy-org-agenda-test--write file (string-replace from to text))
    (set-file-times file (time-add nil 10))))

(defun omarchy-org-agenda-test--advised-p ()
  "Non-nil while the one-shot note-save advice is installed."
  (advice-member-p 'omarchy-org-agenda--around-store-note 'org-store-log-note))

(defun omarchy-org-agenda-test--store-note (text &optional abort)
  "Type TEXT into *Org Note* and finish it, or cancel when ABORT."
  (with-current-buffer "*Org Note*"
    (goto-char (point-max))
    (insert text)
    (let ((org-note-abort abort))
      (org-store-log-note))))

(ert-deftest omarchy-org-agenda-test-fast-keys ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((keys (plist-get (plist-get payload :keywords) :keys)))
      (should (equal '("n" "t" "r" "p" "d" "c")
                     (mapcar (lambda (k) (plist-get keys k))
                             '(:NEXT :TODO :REPEAT :PROJ :DONE :CANCELED))))
      (should (= 12 (length keys))))))

(ert-deftest omarchy-org-agenda-test-index ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((payload (cdr (omarchy-org-agenda-test--fixture-payload dir)))
           (items (seq-remove (lambda (i) (equal "sexp" (plist-get i :type)))
                              (omarchy-org-agenda-test--items payload)))
           (key (lambda (i) (cons (plist-get i :path) (plist-get i :line)))))
      (should (= (length (seq-uniq (mapcar key items)))
                 (hash-table-count omarchy-org-agenda--index)))
      (should (= (length items) (hash-table-count omarchy-org-agenda--index)))
      (dolist (i items)
        (should (equal (list :title (plist-get i :title)
                             :todo (plist-get i :todo)
                             :id (plist-get i :id))
                       (gethash (funcall key i) omarchy-org-agenda--index))))
      (cl-letf (((symbol-function 'omarchy-org-agenda--entries)
                 (lambda (&rest _) (error "Boom"))))
        (omarchy-org-agenda-export))
      (should (= 0 (hash-table-count omarchy-org-agenda--index)))
      (omarchy-org-agenda-teardown)
      (should-not omarchy-org-agenda--index))))

(ert-deftest omarchy-org-agenda-test-state-result-shape ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let* ((line (omarchy-org-agenda-test--line payload "Parent task"))
           (json (omarchy-org-agenda-set-state file line nil "PROJ" "DONE"))
           (result (json-parse-string json :object-type 'alist)))
      (should (equal '(result state saved detail) (mapcar #'car result)))
      ;; Plain ASCII on the wire; the child's name survives the round trip.
      (should-not (string-match-p "[^[:ascii:]]" json))
      (should (string-search "\\u0218" json))
      (should (equal "blocked" (alist-get 'result result)))
      (should (string-search "Ședință copil" (alist-get 'detail result))))
    (cl-letf (((symbol-function 'omarchy-org-agenda--change)
               (lambda (&rest _) (error "Boom\nwith a\ttab %s" (make-string 500 ?x)))))
      (let ((r (omarchy-org-agenda-test--set-state
                file (omarchy-org-agenda-test--line payload "Alpha") nil "REPEAT" "PROJ")))
        (should (equal "error" (plist-get r :result)))
        (should (string-prefix-p "Boom with a tab xx" (plist-get r :detail)))
        (should (= 200 (length (plist-get r :detail))))))))

(ert-deftest omarchy-org-agenda-test-state-done-saved ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((r (omarchy-org-agenda-test--set-state
              file (omarchy-org-agenda-test--line payload "Alpha") nil "REPEAT" "PROJ")))
      (should (equal '(:result "done" :state "PROJ" :saved t :detail nil)
                     (list :result (plist-get r :result) :state (plist-get r :state)
                           :saved (plist-get r :saved) :detail (plist-get r :detail))))
      (should (string-search "* PROJ Alpha task" (omarchy-org-agenda-test--disk file)))
      (should-not (buffer-modified-p (find-buffer-visiting file))))
    ;; No keyword before: FROM is nil.
    (let ((r (omarchy-org-agenda-test--set-state
              file (omarchy-org-agenda-test--line payload "Plain heading") nil nil "REPEAT")))
      (should (equal "done" (plist-get r :result)))
      (should (equal "REPEAT" (omarchy-org-agenda-test--todo file "Plain heading"))))))

(ert-deftest omarchy-org-agenda-test-state-unsaved-edits ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((line (omarchy-org-agenda-test--line payload "Alpha")))
      (omarchy-org-agenda-test--edit file (lambda () (goto-char (point-max))
                                            (insert "\nUnsaved text\n")))
      (let ((r (omarchy-org-agenda-test--set-state file line nil "REPEAT" "PROJ")))
        (should (equal "done" (plist-get r :result)))
        (should (eq nil (plist-get r :saved)))
        (should-not (plist-get r :detail)))
      (should (buffer-modified-p (find-buffer-visiting file)))
      (should (string-search "* REPEAT Alpha task" (omarchy-org-agenda-test--disk file)))
      (should (equal "PROJ" (omarchy-org-agenda-test--todo file "Alpha"))))))

(ert-deftest omarchy-org-agenda-test-state-verification ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((alpha (omarchy-org-agenda-test--line payload "Alpha"))
          (changed (lambda (&rest args)
                     (setq omarchy-org-agenda--timer nil)
                     (let ((r (apply #'omarchy-org-agenda-test--set-state args)))
                       (should (equal "changed" (plist-get r :result)))
                       ;; A refresh is on its way.
                       (should (timerp omarchy-org-agenda--timer))))))
      ;; Unknown location.
      (funcall changed file 9999 nil "REPEAT" "PROJ")
      (funcall changed (concat file "x") alpha nil "REPEAT" "PROJ")
      ;; FROM isn't what the bar showed.
      (funcall changed file alpha nil "PROJ" "DONE")
      ;; Keyword changed in Emacs.
      (omarchy-org-agenda-test--edit
       file (lambda () (re-search-forward "^\\* REPEAT Alpha") (replace-match "* PROJ Alpha")))
      (funcall changed file alpha nil "REPEAT" "PROJ")
      ;; Title edited.
      (omarchy-org-agenda-test--edit
       file (lambda () (re-search-forward "^\\* PROJ Alpha task") (replace-match "* REPEAT Alpha renamed")))
      (funcall changed file alpha nil "REPEAT" "PROJ")
      ;; A line shifted: the line now holds another heading, which stays as is.
      (omarchy-org-agenda-test--edit
       file (lambda () (re-search-forward "^\\* REPEAT Alpha renamed\n")
              (replace-match "* REPEAT Inserted above\n* REPEAT Alpha task\n")))
      (funcall changed file alpha nil "REPEAT" "PROJ")
      (should (equal "REPEAT" (omarchy-org-agenda-test--todo file "Inserted above")))
      (should (equal "REPEAT" (omarchy-org-agenda-test--todo file "Alpha task"))))))

(ert-deftest omarchy-org-agenda-test-state-follows-id ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((beta (omarchy-org-agenda-test--line payload "Beta")))
      (omarchy-org-agenda-test--edit file (lambda () (forward-line 2)
                                            (insert "* One\n* Two\n")))
      (should (equal "done" (plist-get (omarchy-org-agenda-test--set-state
                                        file beta "state-beta" "PROJ" "REPEAT")
                                       :result)))
      (should (equal "REPEAT" (omarchy-org-agenda-test--todo file "Beta")))
      (should-not (omarchy-org-agenda-test--todo file "One"))
      ;; An ID the index doesn't have for that location.
      (should (equal "changed" (plist-get (omarchy-org-agenda-test--set-state
                                           file beta "other-id" "PROJ" "REPEAT")
                                          :result))))))

(ert-deftest omarchy-org-agenda-test-state-narrowed-elsewhere ()
  (omarchy-org-agenda-test--with-state (file payload)
    (with-current-buffer (find-buffer-visiting file)
      (goto-char (point-min))
      (re-search-forward "^\\* NEXT Gamma")
      (org-narrow-to-subtree)
      (let ((visible (buffer-string)))
        (should (equal "done" (plist-get (omarchy-org-agenda-test--set-state
                                          file (omarchy-org-agenda-test--line payload "Alpha")
                                          nil "REPEAT" "PROJ")
                                         :result)))
        (should (buffer-narrowed-p))
        (should (equal visible (buffer-string)))
        (should (equal "PROJ" (omarchy-org-agenda-test--todo file "Alpha")))
        (should (equal "NEXT" (omarchy-org-agenda-test--todo file "Gamma")))))))

(ert-deftest omarchy-org-agenda-test-state-blocked ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((r (omarchy-org-agenda-test--set-state
              file (omarchy-org-agenda-test--line payload "Parent") nil "PROJ" "DONE")))
      (should (equal "blocked" (plist-get r :result)))
      (should (equal "NEXT Ședință copil" (plist-get r :detail)))
      (should-not (plist-get r :state)))
    (let ((r (omarchy-org-agenda-test--set-state
              file (omarchy-org-agenda-test--line payload "Checklist") nil "PROJ" "DONE")))
      (should (equal "blocked" (plist-get r :result)))
      (should-not (plist-get r :detail)))
    (should-not (buffer-modified-p (find-buffer-visiting file)))
    (should-not (omarchy-org-agenda--note-queued-p))
    (should (equal "PROJ" (omarchy-org-agenda-test--todo file "Parent")))))

(ert-deftest omarchy-org-agenda-test-state-time-log ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((config (current-window-configuration))
          (shown (window-buffer))
          (r (omarchy-org-agenda-test--set-state
              file (omarchy-org-agenda-test--line payload "Gamma") nil "NEXT" "REPEAT")))
      (should (equal "done" (plist-get r :result)))
      (should (equal "REPEAT" (plist-get r :state)))
      (should (eq t (plist-get r :saved)))
      (should-not (get-buffer "*Org Note*"))
      (should-not (omarchy-org-agenda--note-queued-p))
      (should-not omarchy-org-agenda--note)
      (should (compare-window-configurations config (current-window-configuration)))
      (should (eq shown (window-buffer)))
      (should (string-match-p "State \"REPEAT\" +from \"NEXT\""
                              (omarchy-org-agenda-test--disk file))))))

(ert-deftest omarchy-org-agenda-test-state-repeater ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((org-log-repeat 'time)
           (org-log-done nil)
           (file (omarchy-org-agenda-test--write
                  (expand-file-name "repeat.org" dir)
                  (concat "#+TODO: TODO NEXT | DONE\n\n* TODO Water the plants\n"
                          "SCHEDULED: " (omarchy-org-agenda-test--ts 0 nil ".+1d") "\n")))
           (payload (omarchy-org-agenda-test--export dir (list file)))
           (r (omarchy-org-agenda-test--set-state
               file (omarchy-org-agenda-test--line payload "Water") nil "TODO" "DONE")))
      ;; Back to the state it came from, but the entry did change.
      (should (equal "done" (plist-get r :result)))
      (should (equal "TODO" (plist-get r :state)))
      (should (eq t (plist-get r :saved)))
      (should (string-search
               (concat "SCHEDULED: <" (format-time-string
                                       "%F" (encode-time (omarchy-org-agenda-test--day 1))))
               (omarchy-org-agenda-test--disk file))))))

(ert-deftest omarchy-org-agenda-test-state-note-frame ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let* ((beta (omarchy-org-agenda-test--line payload "Beta"))
           (r (omarchy-org-agenda-test--set-state file beta nil "PROJ" "DONE"))
           (timer (plist-get omarchy-org-agenda--note :timer)))
      (should (equal '("note-frame" "DONE" nil)
                     (list (plist-get r :result) (plist-get r :state) (plist-get r :saved))))
      (should (omarchy-org-agenda--note-queued-p))
      (should (timerp timer))
      (should (omarchy-org-agenda-test--advised-p))
      ;; Org's queued note never fires for an unrelated command.
      (let ((this-command 'next-line)) (run-hooks 'post-command-hook))
      (should-not (get-buffer "*Org Note*"))
      (should (equal "busy" (plist-get (omarchy-org-agenda-test--set-state
                                        file (omarchy-org-agenda-test--line payload "Alpha")
                                        nil "REPEAT" "PROJ")
                                       :result)))
      (should (eq t (omarchy-org-agenda-take-note)))
      (should (get-buffer "*Org Note*"))
      (should-not (omarchy-org-agenda--note-queued-p))
      (should-not (memq timer timer-list))
      (should-not (omarchy-org-agenda-take-note))
      ;; Still busy while the note is being written.
      (should (equal "busy" (plist-get (omarchy-org-agenda-test--set-state
                                        file (omarchy-org-agenda-test--line payload "Alpha")
                                        nil "REPEAT" "PROJ")
                                       :result)))
      (should (string-search "* PROJ Beta" (omarchy-org-agenda-test--disk file)))
      (omarchy-org-agenda-test--store-note "Wrapped up")
      (let ((disk (omarchy-org-agenda-test--disk file)))
        (should (string-search "* DONE Beta task" disk))
        (should (string-search "Wrapped up" disk)))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (should-not (omarchy-org-agenda-test--advised-p))
      (should-not omarchy-org-agenda--note))))

(ert-deftest omarchy-org-agenda-test-state-note-graphic ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((opened 0))
      (cl-letf* ((add-log (symbol-function 'org-add-log-note))
                 ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                 ((symbol-function 'frame-visible-p) (lambda (&rest _) t))
                 ((symbol-function 'org-add-log-note)
                  (lambda (&rest args) (cl-incf opened) (apply add-log args))))
        (let ((r (omarchy-org-agenda-test--set-state
                  file (omarchy-org-agenda-test--line payload "Beta") nil "PROJ" "DONE")))
          (should (equal "note" (plist-get r :result)))
          (should (equal "DONE" (plist-get r :state)))
          (should (= 1 opened))
          (should (get-buffer "*Org Note*"))
          (should-not (omarchy-org-agenda--note-queued-p))
          (should-not (plist-get omarchy-org-agenda--note :timer)))))
    (omarchy-org-agenda-test--store-note "From the frame")
    (should (string-search "From the frame" (omarchy-org-agenda-test--disk file)))
    (should-not (omarchy-org-agenda-test--advised-p))))

(ert-deftest omarchy-org-agenda-test-state-note-cancel ()
  (omarchy-org-agenda-test--with-state (file payload)
    (should (equal "note-frame"
                   (plist-get (omarchy-org-agenda-test--set-state
                               file (omarchy-org-agenda-test--line payload "Beta")
                               nil "PROJ" "DONE")
                              :result)))
    (should (omarchy-org-agenda-take-note))
    (omarchy-org-agenda-test--store-note "Never mind" t)
    (should-not (omarchy-org-agenda-test--advised-p))
    (should-not omarchy-org-agenda--note)
    ;; The change stays, unsaved, as with Org's own agenda.
    (should (buffer-modified-p (find-buffer-visiting file)))
    (should (string-search "* PROJ Beta" (omarchy-org-agenda-test--disk file)))))

(ert-deftest omarchy-org-agenda-test-state-note-other ()
  (omarchy-org-agenda-test--with-state (file payload)
    (should (equal "note-frame"
                   (plist-get (omarchy-org-agenda-test--set-state
                               file (omarchy-org-agenda-test--line payload "Beta")
                               nil "PROJ" "DONE")
                              :result)))
    ;; The user starts another note: Org's single pending note is replaced.
    (omarchy-org-agenda-test--edit
     file (lambda ()
            (re-search-forward "^\\* REPEAT Alpha")
            (let ((this-command 'org-add-note))
              (org-add-log-setup 'note nil nil 'note)
              (org-add-log-note))))
    (should-not (omarchy-org-agenda-take-note))
    (omarchy-org-agenda-test--store-note "Another note")
    (should-not (omarchy-org-agenda-test--advised-p))
    (should-not omarchy-org-agenda--note)
    (should (buffer-modified-p (find-buffer-visiting file)))
    (should-not (string-search "Another note" (omarchy-org-agenda-test--disk file)))))

(ert-deftest omarchy-org-agenda-test-state-note-expires ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((omarchy-org-agenda-note-timeout 0.05))
      (should (equal "note-frame"
                     (plist-get (omarchy-org-agenda-test--set-state
                                 file (omarchy-org-agenda-test--line payload "Beta")
                                 nil "PROJ" "DONE")
                                :result)))
      (sleep-for 0.3)
      (should-not (omarchy-org-agenda--note-queued-p))
      (should-not org-log-setup)
      (should-not omarchy-org-agenda--note)
      (should-not (omarchy-org-agenda-test--advised-p))
      (should-not (omarchy-org-agenda-take-note))
      (should (equal "DONE" (omarchy-org-agenda-test--todo file "Beta"))))))

(ert-deftest omarchy-org-agenda-test-state-disk-changes ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((alpha (omarchy-org-agenda-test--line payload "Alpha")))
      ;; Clean buffer: reverted silently, then changed.
      (omarchy-org-agenda-test--rewrite file "Gamma \"quoted\" task" "Gamma edited elsewhere")
      (let ((r (omarchy-org-agenda-test--set-state file alpha nil "REPEAT" "PROJ")))
        (should (equal '("done" t) (list (plist-get r :result) (plist-get r :saved)))))
      (let ((disk (omarchy-org-agenda-test--disk file)))
        (should (string-search "Gamma edited elsewhere" disk))
        (should (string-search "* PROJ Alpha task" disk)))
      ;; Clean buffer, but the revert moved the line: refused.
      (omarchy-org-agenda-test--rewrite file "* PROJ Alpha task" "* PROJ New\n* PROJ Alpha task")
      (should (equal "changed" (plist-get (omarchy-org-agenda-test--set-state
                                           file alpha nil "PROJ" "REPEAT")
                                          :result)))
      (should (equal "PROJ" (omarchy-org-agenda-test--todo file "New")))
      ;; Unsaved edits and a newer file: refused, nothing touched.
      (omarchy-org-agenda-test--edit file (lambda () (goto-char (point-max))
                                            (insert "Unsaved\n")))
      (omarchy-org-agenda-test--rewrite file "* PROJ New\n" "")
      (let ((before (with-current-buffer (find-buffer-visiting file) (buffer-string))))
        (should (equal "conflict" (plist-get (omarchy-org-agenda-test--set-state
                                              file alpha nil "PROJ" "REPEAT")
                                             :result)))
        (should (equal before (with-current-buffer (find-buffer-visiting file)
                                (buffer-string))))))))

(ert-deftest omarchy-org-agenda-test-state-refusals ()
  (omarchy-org-agenda-test--with-state (file payload)
    (let ((alpha (omarchy-org-agenda-test--line payload "Alpha")))
      (should (equal "invalid" (plist-get (omarchy-org-agenda-test--set-state
                                           file alpha nil "REPEAT" "NOPE")
                                          :result)))
      (should (equal "invalid" (plist-get (omarchy-org-agenda-test--set-state
                                           file "3" nil "REPEAT" "PROJ")
                                          :result)))
      (let ((r (omarchy-org-agenda-test--set-state file alpha nil "REPEAT" "REPEAT")))
        (should (equal '("done" "REPEAT") (list (plist-get r :result) (plist-get r :state)))))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (should (equal "REPEAT" (omarchy-org-agenda-test--todo file "Alpha")))
      ;; A note Org queued elsewhere is never clobbered.
      (add-hook 'post-command-hook #'org-add-log-note 'append)
      (should (equal "busy" (plist-get (omarchy-org-agenda-test--set-state
                                        file alpha nil "REPEAT" "PROJ")
                                       :result)))
      (should (equal "REPEAT" (omarchy-org-agenda-test--todo file "Alpha"))))))

;;;; Coming up: scheduled tasks and timestamped entries on later days

(defun omarchy-org-agenda-test--upcoming-text ()
  "The look-ahead fixture: today's entries and later scheduled tasks."
  (let ((ts #'omarchy-org-agenda-test--ts))
    (concat
     "#+TODO: NEXT TODO WAIT | DONE CANCELED\n\n"
     "* NEXT Task for today\n"
     "SCHEDULED: " (funcall ts 0) "\n"
     "* TODO Weekly since three days ago\n"
     "SCHEDULED: " (funcall ts -3 nil "+1w") "\n"
     "* TODO Habit since two days ago\n"
     "SCHEDULED: " (funcall ts -2 nil ".+1d") "\n"
     ":PROPERTIES:\n:STYLE: habit\n:END:\n"
     "* TODO Deadline in five days\n"
     "DEADLINE: " (funcall ts 5) "\n"
     "* TODO Timed task tomorrow\n"
     "SCHEDULED: " (funcall ts 1 "09:30-10:00") "\n"
     "* NEXT Daily from tomorrow\n"
     "SCHEDULED: " (funcall ts 1 nil "+1d") "\n"
     "* TODO Habit from tomorrow\n"
     "SCHEDULED: " (funcall ts 1 nil ".+1d") "\n"
     ":PROPERTIES:\n:STYLE: habit\n:END:\n"
     "* TODO Task in three days\n"
     "SCHEDULED: " (funcall ts 3) "\n"
     "* Event in two days\n"
     (funcall ts 2 "10:00-11:00") "\n"
     "* TODO Task beyond the horizon\n"
     "SCHEDULED: " (funcall ts 9) "\n")))

(defmacro omarchy-org-agenda-test--with-upcoming (spec &rest body)
  "Run BODY with (FILE PAYLOAD) of SPEC bound to the exported look-ahead fixture.
Habits show on today only, as Org's default has it."
  (declare (indent 1) (debug ((symbolp symbolp) body)))
  `(omarchy-org-agenda-test--with-dir (dir)
     (let* ((org-habit-show-habits-only-for-today t)
            (org-agenda-show-future-repeats t)
            (,(car spec) (omarchy-org-agenda-test--write
                          (expand-file-name "upcoming.org" dir)
                          (omarchy-org-agenda-test--upcoming-text)))
            (,(cadr spec) (omarchy-org-agenda-test--export dir (list ,(car spec)))))
       (ignore ,(car spec) ,(cadr spec))
       ,@body)))

(defun omarchy-org-agenda-test--later-p (item)
  "Non-nil when ITEM was collected for a later day.
Deadline warnings count days ahead too, but come from today's agenda."
  (and (member (plist-get item :type) '("scheduled" "timestamp" "block"))
       (> (plist-get item :inDays) 0)))

(defun omarchy-org-agenda-test--matching (payload title)
  "The items of PAYLOAD whose title contains TITLE."
  (seq-filter (lambda (item) (string-search title (plist-get item :title)))
              (omarchy-org-agenda-test--items payload)))

(ert-deftest omarchy-org-agenda-test-upcoming-scheduled ()
  (omarchy-org-agenda-test--with-upcoming (file payload)
    (let ((timed (omarchy-org-agenda-test--item payload "Timed task tomorrow"))
          (later (omarchy-org-agenda-test--item payload "Task in three days")))
      (should (equal "scheduled" (plist-get timed :type)))
      (should (equal 1 (plist-get timed :inDays)))
      (should (equal 0 (plist-get timed :overdueDays)))
      (should (equal "09:30" (plist-get timed :time)))
      (should (eql 30 (plist-get timed :durationMin)))
      (should (equal 3 (plist-get later :inDays)))
      (should (eq :null (plist-get later :time))))
    (let ((deadline (omarchy-org-agenda-test--item payload "Deadline in five days")))
      (should (equal "upcoming-deadline" (plist-get deadline :type)))
      (should (equal 5 (plist-get deadline :inDays))))
    ;; Plain timestamps are looked ahead for as well.
    (let ((event (omarchy-org-agenda-test--item payload "Event in two days")))
      (should (equal "timestamp" (plist-get event :type)))
      (should (equal 2 (plist-get event :inDays)))
      (should (equal "10:00" (plist-get event :time))))
    (should-not (omarchy-org-agenda-test--matching payload "beyond the horizon"))
    (dolist (item (omarchy-org-agenda-test--items payload))
      (should (natnump (plist-get item :inDays))))))

(ert-deftest omarchy-org-agenda-test-upcoming-one-row-per-heading ()
  (omarchy-org-agenda-test--with-upcoming (file payload)
    ;; A daily repeater shows on every later day; only the first is kept.
    (let ((daily (omarchy-org-agenda-test--item payload "Daily from tomorrow")))
      (should (equal 1 (plist-get daily :inDays)))
      (should (equal 0 (plist-get daily :overdueDays))))
    ;; Already on today's agenda: its next occurrence adds no row.
    (let ((weekly (omarchy-org-agenda-test--item payload "Weekly since three days ago")))
      (should (equal 0 (plist-get weekly :inDays)))
      (should (equal 3 (plist-get weekly :overdueDays))))
    (let ((keys (mapcar #'omarchy-org-agenda--key
                        (seq-filter #'omarchy-org-agenda-test--later-p
                                    (omarchy-org-agenda-test--items payload)))))
      (should (equal keys (seq-uniq keys))))))

(ert-deftest omarchy-org-agenda-test-upcoming-habits ()
  (omarchy-org-agenda-test--with-upcoming (file payload)
    (let ((habit (omarchy-org-agenda-test--item payload "Habit since two days ago")))
      (should (eq t (plist-get habit :habit)))
      (should (equal 0 (plist-get habit :inDays))))
    ;; `org-habit-show-habits-only-for-today': never on a later day.
    (should-not (omarchy-org-agenda-test--matching payload "Habit from tomorrow"))))

(ert-deftest omarchy-org-agenda-test-upcoming-repeat-not-overdue ()
  (omarchy-org-agenda-test--with-upcoming (file payload)
    ;; The weekly task's next occurrence, before deduplication: Org may
    ;; date it by its past base date, which must not count as overdue.
    (let* ((today (calendar-absolute-from-gregorian (calendar-current-date)))
           (days (omarchy-org-agenda--entries (list file) 7))
           (entry (seq-find (lambda (e) (string-search "Weekly" e))
                            (alist-get 4 days)))
           (item (omarchy-org-agenda--item entry today (+ today 4))))
      (should entry)
      (should (equal 4 (plist-get item :inDays)))
      (should (equal 0 (plist-get item :overdueDays))))))

(ert-deftest omarchy-org-agenda-test-upcoming-order ()
  (omarchy-org-agenda-test--with-upcoming (file payload)
    (let* ((items (omarchy-org-agenda-test--items payload))
           (later (seq-drop-while (lambda (i) (not (omarchy-org-agenda-test--later-p i)))
                                  items))
           (days (mapcar (lambda (i) (plist-get i :inDays)) later)))
      ;; Today's agenda first, then the later days, in order.
      (should (= 4 (length later)))
      (should (seq-every-p #'omarchy-org-agenda-test--later-p later))
      (should (equal days (sort (copy-sequence days) #'<)))
      (should (equal '(1 1 2 3) days))
      ;; Within a day, Org's sorting: the timed task first.
      (should (string-search "Timed task tomorrow" (plist-get (car later) :title)))
      (should (= 4 (- (length items) (length later)))))))

(defun omarchy-org-agenda-test--week-start (ahead)
  "The `org-agenda-start-on-weekday' whose week ends AHEAD days after today."
  (mod (+ (calendar-day-of-week (calendar-current-date)) 1 ahead) 7))

(ert-deftest omarchy-org-agenda-test-days-ahead ()
  ;; START → days ahead on Sunday (0) through Saturday (6).
  (pcase-dolist (`(,start . ,want)
                 '((0 6 5 4 3 2 1 0)
                   (1 0 6 5 4 3 2 1)
                   (6 5 4 3 2 1 0 6)
                   (nil 6 6 6 6 6 6 6)
                   (7 6 6 6 6 6 6 6)
                   (-1 6 6 6 6 6 6 6)
                   (monday 6 6 6 6 6 6 6)))
    (should (equal (cons start want)
                   (cons start (mapcar (lambda (dow)
                                         (omarchy-org-agenda--days-ahead dow start))
                                       (number-sequence 0 6)))))))

(ert-deftest omarchy-org-agenda-test-upcoming-week-ends-today ()
  ;; Org's Sunday with a Monday week: nothing ahead but deadline warnings.
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((org-habit-show-habits-only-for-today t)
           (org-agenda-start-on-weekday (omarchy-org-agenda-test--week-start 0))
           (file (omarchy-org-agenda-test--write
                  (expand-file-name "upcoming.org" dir)
                  (omarchy-org-agenda-test--upcoming-text)))
           (payload (omarchy-org-agenda-test--export dir (list file))))
      (should (equal 0 (plist-get payload :daysAhead)))
      (should-not (seq-filter (lambda (item) (> (plist-get item :inDays) 0))
                              (seq-remove (lambda (item)
                                            (equal (plist-get item :type)
                                                   "upcoming-deadline"))
                                          (omarchy-org-agenda-test--items payload))))
      ;; Org's own deadline warning still counts its days.
      (should (equal 5 (plist-get (omarchy-org-agenda-test--item
                                   payload "Deadline in five days")
                                  :inDays))))))

(ert-deftest omarchy-org-agenda-test-upcoming-week-ends-in-two-days ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((org-habit-show-habits-only-for-today t)
           (org-agenda-start-on-weekday (omarchy-org-agenda-test--week-start 2))
           (file (omarchy-org-agenda-test--write
                  (expand-file-name "upcoming.org" dir)
                  (omarchy-org-agenda-test--upcoming-text)))
           (payload (omarchy-org-agenda-test--export dir (list file))))
      (should (equal 2 (plist-get payload :daysAhead)))
      (should (equal 1 (plist-get (omarchy-org-agenda-test--item
                                   payload "Timed task tomorrow")
                                  :inDays)))
      (should (equal 2 (plist-get (omarchy-org-agenda-test--item
                                   payload "Event in two days")
                                  :inDays)))
      (should-not (omarchy-org-agenda-test--matching payload "Task in three days"))
      (should (equal '(1 1 2)
                     (mapcar (lambda (item) (plist-get item :inDays))
                             (seq-filter #'omarchy-org-agenda-test--later-p
                                         (omarchy-org-agenda-test--items payload)))))
      ;; Past the week's end, within `org-deadline-warning-days': today's
      ;; agenda warns about it.
      (let ((deadline (omarchy-org-agenda-test--item payload "Deadline in five days")))
        (should (< 5 org-deadline-warning-days))
        (should (equal "upcoming-deadline" (plist-get deadline :type)))
        (should (equal 5 (plist-get deadline :inDays)))))))

(ert-deftest omarchy-org-agenda-test-upcoming-cap ()
  (omarchy-org-agenda-test--with-upcoming (file payload)
    (let* ((today-count (seq-count (lambda (i) (not (omarchy-org-agenda-test--later-p i)))
                                   (omarchy-org-agenda-test--items payload)))
           (export (lambda (max)
                     (let ((omarchy-org-agenda-max-items max))
                       (omarchy-org-agenda-test--items
                        (omarchy-org-agenda-test--export
                         (file-name-directory file) (list file)))))))
      (should (= 4 today-count))
      (let ((items (funcall export (1+ today-count))))
        (should (= (1+ today-count) (length items)))
        (should (equal '(nil nil nil nil t)
                       (mapcar (lambda (i) (and (omarchy-org-agenda-test--later-p i) t))
                               items))))
      (let ((items (funcall export 2)))
        (should (= 2 (length items)))
        (should-not (seq-some #'omarchy-org-agenda-test--later-p items))))))

(ert-deftest omarchy-org-agenda-test-upcoming-ensure-ignores-4th-arg ()
  ;; A shell from before 0.3 still sends the old days-ahead setting.
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((org-habit-show-habits-only-for-today t)
           (file (omarchy-org-agenda-test--write
                  (expand-file-name "upcoming.org" dir)
                  (omarchy-org-agenda-test--upcoming-text)))
           (out (expand-file-name "agenda.json" dir))
           (export (lambda (&rest upcoming)
                     (should (eq t (apply #'omarchy-org-agenda-ensure
                                          out (list file) nil upcoming)))
                     (omarchy-org-agenda-export)
                     (let ((payload (omarchy-org-agenda-test--read out)))
                       (list (plist-get payload :daysAhead)
                             (plist-get payload :items)))))
           (want (funcall export)))
      (should (equal 6 (car want)))
      (dolist (upcoming '(0 2 31 nil))
        (should (equal want (funcall export upcoming))))
      (should-not (boundp 'omarchy-org-agenda-upcoming-days)))))

(ert-deftest omarchy-org-agenda-test-upcoming-set-state ()
  (omarchy-org-agenda-test--with-upcoming (file payload)
    (let* ((item (omarchy-org-agenda-test--item payload "Task in three days"))
           (line (plist-get item :line)))
      (should (gethash (omarchy-org-agenda--key item) omarchy-org-agenda--index))
      (let ((r (omarchy-org-agenda-test--set-state file line nil "TODO" "DONE")))
        (should (equal "done" (plist-get r :result)))
        (should (equal "DONE" (plist-get r :state))))
      (should (string-search "* DONE Task in three days"
                             (omarchy-org-agenda-test--disk file))))))

;;;; Coming up: calendar-style events

(defun omarchy-org-agenda-test--calendar-text ()
  "The events fixture: plain timestamps and ranges, as a calendar sync writes."
  (let* ((ts #'omarchy-org-agenda-test--ts)
         (range (lambda (from to) (concat (funcall ts from) "--" (funcall ts to))))
         (sexp-day (omarchy-org-agenda-test--day 2)))
    (concat
     "* Timed event tomorrow\n"
     (funcall ts 1 "10:00-10:30") "\n"
     "* All-day event in three days\n"
     (funcall ts 3) "\n"
     "* Range from two days for three days\n"
     (funcall range 2 4) "\n"
     "* Range from yesterday to tomorrow\n"
     (funcall range -1 1) "\n"
     "* Weekly event since three days ago\n"
     (funcall ts -3 nil "+1w") "\n"
     "* Event beyond the horizon\n"
     (funcall ts 9) "\n"
     "* TODO Scheduled in two days, event in three\n"
     "SCHEDULED: " (funcall ts 2) "\n"
     (funcall ts 3 "15:00-16:00") "\n"
     "* Sexps\n"
     (format "%%%%(diary-date %d %d %d) Sexp event in two days\n"
             (decoded-time-month sexp-day) (decoded-time-day sexp-day)
             (decoded-time-year sexp-day)))))

(defmacro omarchy-org-agenda-test--with-calendar (spec &rest body)
  "Run BODY with (FILE PAYLOAD) of SPEC bound to the exported events fixture."
  (declare (indent 1) (debug ((symbolp symbolp) body)))
  `(omarchy-org-agenda-test--with-dir (dir)
     (let* ((org-agenda-show-future-repeats t)
            (calendar-date-style 'american)
            (,(car spec) (omarchy-org-agenda-test--write
                          (expand-file-name "calendar.org" dir)
                          (omarchy-org-agenda-test--calendar-text)))
            (,(cadr spec) (omarchy-org-agenda-test--export dir (list ,(car spec)))))
       (ignore ,(car spec) ,(cadr spec))
       ,@body)))

(ert-deftest omarchy-org-agenda-test-calendar-timestamps ()
  (omarchy-org-agenda-test--with-calendar (file payload)
    (let ((timed (omarchy-org-agenda-test--item payload "Timed event tomorrow")))
      (should (equal "timestamp" (plist-get timed :type)))
      (should (equal 1 (plist-get timed :inDays)))
      (should (equal 0 (plist-get timed :overdueDays)))
      (should (equal "10:00" (plist-get timed :time)))
      (should (eql 30 (plist-get timed :durationMin)))
      (should (eq :null (plist-get timed :todo))))
    (let ((all-day (omarchy-org-agenda-test--item payload "All-day event in three days")))
      (should (equal "timestamp" (plist-get all-day :type)))
      (should (equal 3 (plist-get all-day :inDays)))
      (should (equal 0 (plist-get all-day :overdueDays)))
      (should (eq :null (plist-get all-day :time))))
    (should-not (omarchy-org-agenda-test--matching payload "beyond the horizon"))
    (should-not (omarchy-org-agenda-test--matching payload "Sexp event"))))

(ert-deftest omarchy-org-agenda-test-calendar-ranges ()
  (omarchy-org-agenda-test--with-calendar (file payload)
    ;; Org lists a range on each of its days; it shows once, on the first.
    (let ((later (omarchy-org-agenda-test--item payload "Range from two days")))
      (should (equal "block" (plist-get later :type)))
      (should (equal 2 (plist-get later :inDays)))
      (should (equal 0 (plist-get later :overdueDays))))
    ;; Already under way: today's row only.
    (let ((current (omarchy-org-agenda-test--item payload "Range from yesterday")))
      (should (equal "block" (plist-get current :type)))
      (should (equal 0 (plist-get current :inDays))))))

(ert-deftest omarchy-org-agenda-test-calendar-one-row-per-heading ()
  (omarchy-org-agenda-test--with-calendar (file payload)
    (let ((weekly (omarchy-org-agenda-test--item payload "Weekly event")))
      (should (equal "timestamp" (plist-get weekly :type)))
      (should (equal 4 (plist-get weekly :inDays)))
      (should (equal 0 (plist-get weekly :overdueDays))))
    ;; The earlier of its SCHEDULED and body timestamp wins.
    (let ((both (omarchy-org-agenda-test--item payload "Scheduled in two days")))
      (should (equal "scheduled" (plist-get both :type)))
      (should (equal 2 (plist-get both :inDays))))
    (let ((keys (mapcar #'omarchy-org-agenda--key
                        (omarchy-org-agenda-test--items payload))))
      (should (equal keys (seq-uniq keys))))
    (dolist (item (omarchy-org-agenda-test--items payload))
      (should (gethash (omarchy-org-agenda--key item) omarchy-org-agenda--index)))))

(ert-deftest omarchy-org-agenda-test-calendar-week-ends-today ()
  (omarchy-org-agenda-test--with-calendar (file payload)
    (let ((out (expand-file-name "agenda.json" (file-name-directory file)))
          (org-agenda-start-on-weekday (omarchy-org-agenda-test--week-start 0)))
      (omarchy-org-agenda-ensure out (list file) nil)
      (omarchy-org-agenda-export)
      (let ((items (omarchy-org-agenda-test--items (omarchy-org-agenda-test--read out))))
        (should-not (seq-filter #'omarchy-org-agenda-test--later-p items))
        (should (equal '("Range from yesterday to tomorrow")
                       (mapcar (lambda (i) (plist-get i :title)) items)))))))

;;;; Browsing other weeks: `omarchy-org-agenda-week'

(ert-deftest omarchy-org-agenda-test-days-back ()
  (dolist (start '(0 1 2 3 4 5 6 nil 7 -1 monday))
    (dolist (dow (number-sequence 0 6))
      (let ((back (omarchy-org-agenda--days-back dow start)))
        (should (<= 0 back 6))
        (should (= 6 (+ back (omarchy-org-agenda--days-ahead dow start))))
        (if (and (integerp start) (<= 0 start 6))
            ;; The week's first day is START's weekday.
            (should (= start (mod (- dow back) 7)))
          (should (= 0 back)))))))

(defconst omarchy-org-agenda-test--week-back 2
  "Days the Org week of the week tests started before today.
Next week then covers days 5..11 from today, last week -9..-3.")

(defun omarchy-org-agenda-test--week-text ()
  "The week fixture: entries next week, last week and beyond."
  (let* ((ts #'omarchy-org-agenda-test--ts)
         (range (lambda (from to) (concat (funcall ts from) "--" (funcall ts to))))
         (sexp-day (omarchy-org-agenda-test--day 6)))
    (concat
     "#+TODO: NEXT TODO WAIT | DONE CANCELED\n\n"
     "* TODO Task today\n"
     "SCHEDULED: " (funcall ts 0) "\n"
     "* TODO Task next week\n"
     "SCHEDULED: " (funcall ts 6) "\n"
     "* Meeting next week\n"
     (funcall ts 7 "14:00-15:00") "\n"
     "* TODO Deadline next week\n"
     "DEADLINE: " (funcall ts 8) "\n"
     "* Trip from next week on\n"
     (funcall range 9 13) "\n"
     "* NEXT Daily repeater\n"
     "SCHEDULED: " (funcall ts -1 nil "+1d") "\n"
     "* TODO Ședință next week\n"
     "SCHEDULED: " (funcall ts 10) "\n"
     "* TODO Task in two weeks\n"
     "SCHEDULED: " (funcall ts 13) "\n"
     "* TODO Task last week\n"
     "SCHEDULED: " (funcall ts -5) "\n"
     "* Event last week\n"
     (funcall ts -4 "10:00-11:00") "\n"
     "* Sexps\n"
     (format "%%%%(diary-date %d %d %d) Sexp event next week\n"
             (decoded-time-month sexp-day) (decoded-time-day sexp-day)
             (decoded-time-year sexp-day)))))

(defun omarchy-org-agenda-test--week (dir files offset)
  "`omarchy-org-agenda-week' OFFSET for FILES, after the plugin's ensure.
Returns (JSON . PAYLOAD), the string and its parsed plist."
  (omarchy-org-agenda-ensure (expand-file-name "agenda.json" dir) files nil)
  (let ((json (omarchy-org-agenda-week offset)))
    (should (stringp json))
    (cons json (json-parse-string json :object-type 'plist
                                  :null-object :null :false-object :false))))

(defmacro omarchy-org-agenda-test--with-week (spec &rest body)
  "Run BODY with (FILE) of SPEC bound to the week fixture in DIR.
The Org week started `omarchy-org-agenda-test--week-back' days ago."
  (declare (indent 1) (debug ((symbolp) body)))
  `(omarchy-org-agenda-test--with-dir (dir)
     (let* ((org-agenda-show-future-repeats t)
            (calendar-date-style 'american)
            (org-agenda-start-on-weekday
             (omarchy-org-agenda-test--week-start
              (- 6 omarchy-org-agenda-test--week-back)))
            (,(car spec) (omarchy-org-agenda-test--write
                          (expand-file-name "week.org" dir)
                          (omarchy-org-agenda-test--week-text))))
       ,@body)))

(defun omarchy-org-agenda-test--date (offset)
  "The date OFFSET days from today, as YYYY-MM-DD."
  (format-time-string "%F" (encode-time (omarchy-org-agenda-test--day offset))))

(ert-deftest omarchy-org-agenda-test-week-shape ()
  (omarchy-org-agenda-test--with-week (file)
    (pcase-let ((`(,json . ,payload) (omarchy-org-agenda-test--week dir (list file) 1)))
      (should (equal '(version date generatedAt reason emacs org keywords items
                               missing error weekOffset weekStart startInDays)
                     (mapcar #'car (json-parse-string json :object-type 'alist))))
      (should (equal 1 (plist-get payload :version)))
      (should (equal (format-time-string "%F") (plist-get payload :date)))
      (should (stringp (plist-get payload :generatedAt)))
      (should (equal "week" (plist-get payload :reason)))
      (should (equal emacs-version (plist-get payload :emacs)))
      (should (equal (org-version) (plist-get payload :org)))
      (should (equal ["NEXT" "TODO" "WAIT"]
                     (plist-get (plist-get payload :keywords) :todo)))
      (should (equal ["DONE" "CANCELED"]
                     (plist-get (plist-get payload :keywords) :done)))
      (should (equal [] (plist-get payload :missing)))
      (should (eq :null (plist-get payload :error)))
      (should (equal 1 (plist-get payload :weekOffset)))
      (should (equal (omarchy-org-agenda-test--date 5) (plist-get payload :weekStart)))
      (should (equal 5 (plist-get payload :startInDays)))
      (should-not (plist-member payload :daysAhead)))
    (let ((payload (cdr (omarchy-org-agenda-test--week dir (list file) -1))))
      (should (equal -1 (plist-get payload :weekOffset)))
      (should (equal (omarchy-org-agenda-test--date -9) (plist-get payload :weekStart)))
      (should (equal -9 (plist-get payload :startInDays))))
    ;; Org's week starting today: week k starts 7k days on.
    (let* ((org-agenda-start-on-weekday nil)
           (payload (cdr (omarchy-org-agenda-test--week dir (list file) -1))))
      (should (equal (omarchy-org-agenda-test--date -7) (plist-get payload :weekStart)))
      (should (equal -7 (plist-get payload :startInDays))))))

(ert-deftest omarchy-org-agenda-test-week-next ()
  (omarchy-org-agenda-test--with-week (file)
    (let* ((payload (cdr (omarchy-org-agenda-test--week dir (list file) 1)))
           (item (apply-partially #'omarchy-org-agenda-test--item payload)))
      (let ((task (funcall item "Task next week")))
        (should (equal "scheduled" (plist-get task :type)))
        (should (equal 6 (plist-get task :inDays)))
        (should (equal 0 (plist-get task :overdueDays))))
      (let ((meeting (funcall item "Meeting next week")))
        (should (equal "timestamp" (plist-get meeting :type)))
        (should (equal 7 (plist-get meeting :inDays)))
        (should (equal "14:00" (plist-get meeting :time)))
        (should (eql 60 (plist-get meeting :durationMin))))
      ;; On its due day, not today, Org lists a deadline as plain "deadline".
      (let ((deadline (funcall item "Deadline next week")))
        (should (equal "deadline" (plist-get deadline :type)))
        (should (equal 8 (plist-get deadline :inDays)))
        (should (equal 0 (plist-get deadline :overdueDays))))
      ;; A range shows once, on its first day; it runs past the week's end.
      (let ((trip (funcall item "Trip from next week")))
        (should (equal "block" (plist-get trip :type)))
        (should (equal 9 (plist-get trip :inDays))))
      ;; A daily repeater: one row, on the week's first day.
      (let ((daily (funcall item "Daily repeater")))
        (should (equal 5 (plist-get daily :inDays)))
        (should (equal 0 (plist-get daily :overdueDays))))
      (should-not (omarchy-org-agenda-test--matching payload "Sexp event"))
      (should-not (omarchy-org-agenda-test--matching payload "Task today"))
      (should-not (omarchy-org-agenda-test--matching payload "in two weeks"))
      (should-not (omarchy-org-agenda-test--matching payload "last week"))
      (let ((days (mapcar (lambda (i) (plist-get i :inDays))
                          (omarchy-org-agenda-test--items payload))))
        (should (equal days (sort (copy-sequence days) #'<)))
        (should (seq-every-p (lambda (d) (<= 5 d 11)) days)))
      (let ((keys (mapcar #'omarchy-org-agenda--key
                          (omarchy-org-agenda-test--items payload))))
        (should (equal keys (seq-uniq keys)))
        (dolist (key keys)
          (should (gethash key omarchy-org-agenda--week-index)))))))

(ert-deftest omarchy-org-agenda-test-week-last ()
  (omarchy-org-agenda-test--with-week (file)
    (let ((payload (cdr (omarchy-org-agenda-test--week dir (list file) -1))))
      (let ((task (omarchy-org-agenda-test--item payload "Task last week")))
        (should (equal -5 (plist-get task :inDays)))
        (should (equal 0 (plist-get task :overdueDays))))
      (let ((event (omarchy-org-agenda-test--item payload "Event last week")))
        (should (equal "timestamp" (plist-get event :type)))
        (should (equal -4 (plist-get event :inDays)))
        (should (equal 0 (plist-get event :overdueDays))))
      (should-not (omarchy-org-agenda-test--matching payload "next week"))
      (dolist (item (omarchy-org-agenda-test--items payload))
        (should (<= -9 (plist-get item :inDays) -3))
        (should (equal 0 (plist-get item :overdueDays)))))))

(ert-deftest omarchy-org-agenda-test-week-cap ()
  (omarchy-org-agenda-test--with-week (file)
    (let* ((omarchy-org-agenda-max-items 2)
           (payload (cdr (omarchy-org-agenda-test--week dir (list file) 1))))
      ;; The earliest days are kept.
      (should (equal '(5 6) (mapcar (lambda (i) (plist-get i :inDays))
                                    (omarchy-org-agenda-test--items payload)))))))

(ert-deftest omarchy-org-agenda-test-week-ascii ()
  (omarchy-org-agenda-test--with-week (file)
    (pcase-let ((`(,json . ,payload) (omarchy-org-agenda-test--week dir (list file) 1)))
      (should-not (string-match-p "[^[:ascii:]]" json))
      (should (string-search "\\u0218" json))
      (should (omarchy-org-agenda-test--item payload "Ședință next week")))))

(ert-deftest omarchy-org-agenda-test-week-clamp ()
  (omarchy-org-agenda-test--with-week (file)
    (dolist (case '((100 . 52) (-100 . -52) (52 . 52) (0 . 0)))
      (let ((payload (cdr (omarchy-org-agenda-test--week dir (list file) (car case)))))
        (should (equal (cdr case) (plist-get payload :weekOffset)))
        (should (equal (- (* 7 (cdr case)) omarchy-org-agenda-test--week-back)
                       (plist-get payload :startInDays)))))))

(ert-deftest omarchy-org-agenda-test-week-missing-file ()
  (omarchy-org-agenda-test--with-week (file)
    (let ((gone (expand-file-name "gone.org" dir)))
      (cl-letf (((symbol-function 'read-char-exclusive)
                 (lambda (&rest _) (error "Prompted")))
                ((symbol-function 'read-from-minibuffer)
                 (lambda (&rest _) (error "Prompted"))))
        (let ((payload (cdr (omarchy-org-agenda-test--week dir (list file gone) 1))))
          (should (eq :null (plist-get payload :error)))
          (should (equal (vector gone) (plist-get payload :missing)))
          (should (omarchy-org-agenda-test--item payload "Task next week")))))))

(ert-deftest omarchy-org-agenda-test-week-errors ()
  (omarchy-org-agenda-test--with-week (file)
    (omarchy-org-agenda-test--week dir (list file) 1)
    (should (< 0 (hash-table-count omarchy-org-agenda--week-index)))
    (cl-letf (((symbol-function 'org-agenda-get-day-entries)
               (lambda (&rest _) (error "boom"))))
      (let ((payload (cdr (omarchy-org-agenda-test--week dir (list file) 1))))
        (should (equal "boom" (plist-get payload :error)))
        (should (equal [] (plist-get payload :items)))
        (should (equal [] (plist-get payload :missing)))
        (should (equal "week" (plist-get payload :reason)))
        (should (equal 1 (plist-get payload :weekOffset)))
        (should (equal 5 (plist-get payload :startInDays)))
        (should (= 0 (hash-table-count omarchy-org-agenda--week-index)))))
    ;; Not an integer: an error payload, which can't say its week.
    (dolist (offset '(1.5 "1" nil))
      (let ((payload (cdr (omarchy-org-agenda-test--week dir (list file) offset))))
        (should (string-match-p "integerp" (plist-get payload :error)))
        (should (equal [] (plist-get payload :items)))
        (should-not (plist-member payload :weekOffset))))))

(ert-deftest omarchy-org-agenda-test-week-set-state ()
  (omarchy-org-agenda-test--with-week (file)
    (let* ((export (omarchy-org-agenda-test--export dir (list file)))
           (line (with-temp-buffer
                   (insert-file-contents file)
                   (re-search-forward "^\\* TODO Task next week")
                   (line-number-at-pos))))
      ;; Past this week's end: the export doesn't have it.
      (should-not (omarchy-org-agenda-test--matching export "Task next week"))
      (should (equal "changed" (plist-get (omarchy-org-agenda-test--set-state
                                           file line nil "TODO" "DONE")
                                          :result)))
      (let ((payload (cdr (omarchy-org-agenda-test--week dir (list file) 1))))
        (should (equal line (plist-get (omarchy-org-agenda-test--item
                                        payload "Task next week")
                                       :line))))
      (let ((r (omarchy-org-agenda-test--set-state file line nil "TODO" "DONE")))
        (should (equal "done" (plist-get r :result)))
        (should (eq t (plist-get r :saved))))
      (should (string-search "* DONE Task next week"
                             (omarchy-org-agenda-test--disk file)))
      (should (equal "changed" (plist-get (omarchy-org-agenda-test--set-state
                                           file 9999 nil "TODO" "DONE")
                                          :result)))
      (omarchy-org-agenda-teardown)
      (should-not omarchy-org-agenda--week-index))))

;;;; Timers: Org's clock

(defun omarchy-org-agenda-test--inactive (offset hh:mm)
  "Inactive Org timestamp at HH:MM, OFFSET days from today."
  (let ((system-time-locale "C"))
    (format-time-string (concat "[%F %a " hh:mm "]")
                        (encode-time (omarchy-org-agenda-test--day offset)))))

(defun omarchy-org-agenda-test--clock-text ()
  "The clock fixture: an entry with an Effort and 45 minutes clocked earlier."
  (let ((today (concat "SCHEDULED: " (omarchy-org-agenda-test--ts 0) "\n")))
    (concat
     "* TODO Other task\n" today
     "* TODO Clock target \1 weird\n" today
     ":PROPERTIES:\n:Effort:   1:30\n:END:\n"
     ":LOGBOOK:\n"
     "CLOCK: " (omarchy-org-agenda-test--inactive -1 "10:00")
     "--" (omarchy-org-agenda-test--inactive -1 "10:45") " =>  0:45\n"
     ":END:\n")))

(defun omarchy-org-agenda-test--sloppy (dir)
  "Write an entry with an Effort that doesn't parse into DIR; return its file.
Org's own agenda signals on such an Effort, so it is kept out of the
exported files: a clock can run in any file."
  (omarchy-org-agenda-test--write
   (expand-file-name "sloppy.org" dir)
   "* TODO Sloppy effort\n:PROPERTIES:\n:Effort:   soonish\n:END:\n"))

(defun omarchy-org-agenda-test--goto-heading (title)
  "Move to the heading whose title contains TITLE, in a widened buffer."
  (widen)
  (goto-char (point-min))
  (re-search-forward (concat "^\\*.*" (regexp-quote title)))
  (org-back-to-heading t))

(defun omarchy-org-agenda-test--file-line (file title)
  "The line of the heading of FILE whose title contains TITLE, on disk."
  (with-temp-buffer
    (insert-file-contents file)
    (re-search-forward (concat "^\\*.*" (regexp-quote title)))
    (line-number-at-pos)))

(defmacro omarchy-org-agenda-test--with-clock (spec &rest body)
  "Run BODY with (FILE) of SPEC bound to the clock fixture in DIR.
Org's clock is cancelled afterwards, whatever happens, so no clock or
clock timer leaks into other tests."
  (declare (indent 1) (debug ((symbolp) body)))
  `(omarchy-org-agenda-test--with-dir (dir)
     (let ((org-clock-auto-clock-resolution nil)
           ;; Counts every earlier CLOCK line: baseMin is 45.
           (org-clock-mode-line-total 'all)
           (org-clock-in-switch-to-state nil)
           (,(car spec) (omarchy-org-agenda-test--write
                         (expand-file-name "clock.org" dir)
                         (omarchy-org-agenda-test--clock-text))))
       (unwind-protect (progn ,@body)
         (when (org-clocking-p) (org-clock-cancel))))))

(defun omarchy-org-agenda-test--clock-in (file title)
  "Clock into the heading of FILE whose title contains TITLE."
  (with-current-buffer (find-file-noselect file)
    (save-restriction
      (omarchy-org-agenda-test--goto-heading title)
      (org-clock-in))))

(ert-deftest omarchy-org-agenda-test-clock-fields ()
  (omarchy-org-agenda-test--with-clock (file)
    (omarchy-org-agenda-test--clock-in file "Clock target")
    (should (org-clocking-p))
    (let* ((payload (omarchy-org-agenda-test--export dir (list file) "test"))
           (clock (plist-get payload :clock))
           (item (omarchy-org-agenda-test--item payload "Clock target")))
      (should (equal (plist-get item :title) (plist-get clock :title)))
      (should (string-prefix-p "Clock target" (plist-get clock :title)))
      (should (equal (plist-get item :category) (plist-get clock :category)))
      (should (equal "clock" (plist-get clock :category)))
      (should (equal (plist-get item :path) (plist-get clock :path)))
      (should (file-equal-p file (plist-get clock :path)))
      (should (equal (plist-get item :line) (plist-get clock :line)))
      (should (equal (omarchy-org-agenda-test--file-line file "Clock target")
                     (plist-get clock :line)))
      (should (integerp (plist-get clock :startedAt)))
      (should (equal (truncate (float-time org-clock-start-time))
                     (plist-get clock :startedAt)))
      (should (equal 45 (plist-get clock :baseMin)))
      (should (equal 90 (plist-get clock :effortMin)))
      (should (equal '(:title :category :path :line :startedAt :baseMin :effortMin)
                     (seq-filter #'keywordp clock)))
      ;; The browsed week never carries the timers.
      (let ((week (cdr (omarchy-org-agenda-test--week dir (list file) 0))))
        (should (omarchy-org-agenda-test--item week "Clock target"))
        (should-not (plist-member week :clock))
        (should-not (plist-member week :pomodoro))))))

(ert-deftest omarchy-org-agenda-test-clock-none ()
  (omarchy-org-agenda-test--with-clock (file)
    (should (featurep 'org-clock))
    (should-not (org-clocking-p))
    (should (eq :null (plist-get (omarchy-org-agenda-test--export dir (list file))
                                 :clock)))
    ;; Clocked out: none again.
    (omarchy-org-agenda-test--clock-in file "Clock target")
    (org-clock-out)
    (should (eq :null (plist-get (omarchy-org-agenda-test--export dir (list file))
                                 :clock)))))

(ert-deftest omarchy-org-agenda-test-clock-effort ()
  (omarchy-org-agenda-test--with-clock (file)
    (let ((sloppy (omarchy-org-agenda-test--sloppy dir)))
      ;; Org 9.6 and 9.7 parse the Effort on clock-in; it is the export
      ;; that must survive it, so set it as Org would have.
      (ignore-errors (omarchy-org-agenda-test--clock-in sloppy "Sloppy effort"))
      (should (org-clocking-p))
      (setq org-clock-effort "soonish")
      (let* ((payload (omarchy-org-agenda-test--export dir (list file)))
             (clock (plist-get payload :clock)))
        (should (eq :null (plist-get payload :error)))
        (should (equal "Sloppy effort" (plist-get clock :title)))
        (should (equal (omarchy-org-agenda-test--file-line sloppy "Sloppy")
                       (plist-get clock :line)))
        (should (eq :null (plist-get clock :effortMin)))
        (should (equal 0 (plist-get clock :baseMin)))))
    (org-clock-cancel)
    (omarchy-org-agenda-test--clock-in file "Other task")
    (let ((clock (plist-get (omarchy-org-agenda-test--export dir (list file)) :clock)))
      (should (equal "Other task" (plist-get clock :title)))
      (should (eq :null (plist-get clock :effortMin))))
    ;; Whatever ends up in someone else's variables.
    (dolist (effort '(nil "" "  " 90 "1:30x"))
      (let ((org-clock-effort effort)
            (org-clock-total-time "45"))
        (let ((clock (plist-get (omarchy-org-agenda--timers) :clock)))
          (should (eq :null (plist-get clock :effortMin)))
          (should (equal 0 (plist-get clock :baseMin))))))
    (let ((org-clock-start-time ""))
      (should (eq :null (plist-get (plist-get (omarchy-org-agenda--timers) :clock)
                                   :startedAt))))))

(ert-deftest omarchy-org-agenda-test-clock-narrowed ()
  (omarchy-org-agenda-test--with-clock (file)
    (omarchy-org-agenda-test--clock-in file "Clock target")
    (let ((line (omarchy-org-agenda-test--file-line file "Clock target")))
      (with-current-buffer (find-file-noselect file)
        ;; Narrowed away from the clock, then down to its own subtree.
        (omarchy-org-agenda-test--goto-heading "Other task")
        (org-narrow-to-subtree)
        (let ((clock (plist-get (omarchy-org-agenda--timers) :clock)))
          (should (equal line (plist-get clock :line)))
          (should (string-prefix-p "Clock target" (plist-get clock :title))))
        (omarchy-org-agenda-test--goto-heading "Clock target")
        (org-narrow-to-subtree)
        (should (equal line (plist-get (plist-get (omarchy-org-agenda--timers) :clock)
                                       :line)))
        (should (buffer-narrowed-p))))))

(ert-deftest omarchy-org-agenda-test-clock-dead-buffer ()
  ;; A clock whose buffer is gone, as `org-clocking-p' can't see it.
  (let ((org-clock-marker (with-temp-buffer (insert "* Gone\n") (point-marker))))
    (cl-letf (((symbol-function 'org-clocking-p) #'always))
      (should (eq :null (plist-get (omarchy-org-agenda--timers) :clock))))))

(ert-deftest omarchy-org-agenda-test-clock-non-file ()
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Scratch entry\n")
    (let ((org-clock-marker (copy-marker (point-min)))
          (org-clock-start-time (time-convert 1700000000 'list))
          (org-clock-total-time 5)
          (org-clock-effort "0:20"))
      (cl-letf (((symbol-function 'org-clocking-p) #'always))
        ;; Org's category for a buffer without a file is "???".
        (should (equal '(:title "Scratch entry" :category "???" :path :null
                                :line :null :startedAt 1700000000
                                :baseMin 5 :effortMin 20)
                       (plist-get (omarchy-org-agenda--timers) :clock)))))))

;;;; Timers: org-pomodoro, through a stub

(defconst omarchy-org-agenda-test--pomodoro-stub
  (concat
   ";;; org-pomodoro.el --- Test stub  -*- lexical-binding: t; -*-\n"
   "(defvar org-pomodoro-state :none)\n"
   "(defvar org-pomodoro-end-time nil)\n"
   "(defvar org-pomodoro-length 25)\n"
   "(defvar org-pomodoro-short-break-length 5)\n"
   "(defvar org-pomodoro-long-break-length 20)\n"
   "(defvar org-pomodoro-count 0)\n"
   "(defvar org-pomodoro-ask-upon-killing t)\n"
   (mapconcat (lambda (hook) (format "(defvar %s nil)\n" hook))
              omarchy-org-agenda-test--pomodoro-hooks
              "")
   "(provide 'org-pomodoro)\n")
  "A stand-in for org-pomodoro: its variables and hooks, nothing else.
The CI images don't have the real one.")

(defun omarchy-org-agenda-test--write-stub (dir &optional text)
  "Write an org-pomodoro stub into DIR/stub/; return that directory.
TEXT is the stub's source, by default `--pomodoro-stub'."
  (let ((stub (expand-file-name "stub/" dir)))
    (make-directory stub t)
    (omarchy-org-agenda-test--write (expand-file-name "org-pomodoro.el" stub)
                                    (or text omarchy-org-agenda-test--pomodoro-stub))
    stub))

(defmacro omarchy-org-agenda-test--with-stub (spec &rest body)
  "Run BODY with (STUB TEXT) of SPEC: STUB, the stub's directory, on `load-path'.
TEXT, when given, is the stub's source.  The stub isn't loaded;
whatever BODY loads is unloaded afterwards, so neither the feature nor
its variables leak into other tests."
  (declare (indent 1) (debug ((symbolp &optional form) body)))
  `(omarchy-org-agenda-test--with-dir (dir)
     (let* ((,(car spec) (omarchy-org-agenda-test--write-stub dir ,(cadr spec)))
            (load-path (cons ,(car spec) load-path))
            (omarchy-org-agenda--pomodoro-located nil))
       (unwind-protect (progn ,@body)
         (when (featurep 'org-pomodoro)
           (unload-feature 'org-pomodoro t))))))

(ert-deftest omarchy-org-agenda-test-pomodoro-available ()
  (omarchy-org-agenda-test--with-dir (dir)
    (let ((a (omarchy-org-agenda-test--small dir "A")))
      (should-not (locate-library "org-pomodoro"))
      (should (eq :false (plist-get (plist-get (omarchy-org-agenda-test--export
                                                dir (list a))
                                               :pomodoro)
                                    :available)))))
  (omarchy-org-agenda-test--with-stub (stub)
    (let ((a (omarchy-org-agenda-test--small dir "A")))
      ;; Found on the load path, never loaded to check.
      (should (equal '(:available t :state "none" :endsAt :null
                                  :phaseMin :null :count 0 :askKill t)
                     (plist-get (omarchy-org-agenda-test--export dir (list a))
                                :pomodoro)))
      (should-not (featurep 'org-pomodoro))
      (should-not (boundp 'org-pomodoro-state))
      ;; Uninstalled: gone from the next pull on.
      (let ((load-path (remove stub load-path)))
        (should (eq :false (plist-get (plist-get (omarchy-org-agenda-test--export
                                                  dir (list a))
                                                 :pomodoro)
                                      :available)))))))

(ert-deftest omarchy-org-agenda-test-pomodoro-states ()
  (omarchy-org-agenda-test--with-stub (_stub)
    (require 'org-pomodoro)
    (let ((end (time-add nil 600))
          (pomodoro (lambda () (plist-get (omarchy-org-agenda--timers) :pomodoro))))
      (setq org-pomodoro-end-time end
            org-pomodoro-count 2)
      (pcase-dolist (`(,state ,name ,phase)
                     '((:pomodoro "pomodoro" 25)
                       (:overtime "overtime" :null)
                       (:short-break "short-break" 5)
                       (:long-break "long-break" 20)))
        (setq org-pomodoro-state state)
        (should (equal (list :available t :state name
                             :endsAt (truncate (float-time end))
                             :phaseMin phase :count 2 :askKill t)
                       (funcall pomodoro))))
      ;; No phase: no end, no length, whatever the variables still say.
      (dolist (state '(:none :weird pomodoro "pomodoro" nil 3))
        (setq org-pomodoro-state state)
        (should (equal (list :available t :state "none" :endsAt :null
                             :phaseMin :null :count 2 :askKill t)
                       (funcall pomodoro))))
      ;; Garbage in someone else's variables.
      (setq org-pomodoro-state :pomodoro
            org-pomodoro-end-time "soon"
            org-pomodoro-length "25"
            org-pomodoro-count -1
            org-pomodoro-ask-upon-killing nil)
      (should (equal '(:available t :state "pomodoro" :endsAt :null
                                  :phaseMin :null :count 0 :askKill :false)
                     (funcall pomodoro)))
      (setq org-pomodoro-end-time 1700000000.7
            org-pomodoro-length 0.5
            org-pomodoro-count 'many)
      (should (equal '(:available t :state "pomodoro" :endsAt 1700000000
                                  :phaseMin 0.5 :count 0 :askKill :false)
                     (funcall pomodoro)))
      ;; And through the JSON, into the file.
      (setq org-pomodoro-state :short-break
            org-pomodoro-end-time end
            org-pomodoro-count 4
            org-pomodoro-ask-upon-killing t)
      (should (equal (list :available t :state "short-break"
                           :endsAt (truncate (float-time end))
                           :phaseMin 5 :count 4 :askKill t)
                     (plist-get (omarchy-org-agenda-test--export
                                 dir (list (omarchy-org-agenda-test--small dir "A")))
                                :pomodoro))))))

;; Named to run after every test that loads the stub: none leaves it behind.
(ert-deftest omarchy-org-agenda-test-zz-pomodoro-stub-gone ()
  (should-not (featurep 'org-pomodoro))
  (should-not (boundp 'org-pomodoro-state))
  (should-not (boundp 'org-pomodoro-count))
  (should-not (boundp 'org-pomodoro-last-clock-in))
  (should-not (fboundp 'org-pomodoro-start))
  (should-not (fboundp 'org-pomodoro-kill))
  (should-not (locate-library "org-pomodoro")))

;;;; Timers: acting

(defun omarchy-org-agenda-test--actions-text (&optional extra)
  "The clock actions fixture: two tasks today, one next week, then EXTRA."
  (let ((today (concat "SCHEDULED: " (omarchy-org-agenda-test--ts 0) "\n")))
    (concat
     "#+TODO: TODO NEXT | DONE\n\n"
     "* TODO Alpha clock\n" today
     "* TODO Beta clock\n" today
     ":PROPERTIES:\n:ID: clock-beta\n:END:\n"
     "* TODO Delta later\n"
     "SCHEDULED: " (omarchy-org-agenda-test--ts 8) "\n"
     extra)))

(defconst omarchy-org-agenda-test--dangling
  (concat "* Old work\n:LOGBOOK:\nCLOCK: "
          (omarchy-org-agenda-test--inactive -1 "09:00") "\n:END:\n")
  "An entry whose clock was left running by an Emacs that is gone.")

(defun omarchy-org-agenda-test--stop-clock ()
  "Cancel any running clock and its timers, leaving no clock state behind."
  (when (org-clocking-p) (ignore-errors (org-clock-cancel)))
  (dolist (timer '(org-clock-mode-line-timer org-clock-idle-timer))
    (when (timerp (symbol-value timer)) (cancel-timer (symbol-value timer)))
    (set timer nil))
  (setq org-clock-current-task nil))

(defun omarchy-org-agenda-test--in-actions (dir fn &optional extra)
  "Call FN with the actions fixture in DIR: (FILE OTHER PAYLOAD).
FILE has the fixture with EXTRA, OTHER one task of its own; PAYLOAD is
their export.  Org's clock settings are the defaults that never ask,
and no clock, note or clock timer is left behind."
  (let ((org-clock-auto-clock-resolution nil)
        (org-clock-in-switch-to-state nil)
        (org-clock-out-switch-to-state nil)
        (org-clock-out-remove-zero-time-clocks nil)
        (org-clock-in-resume nil)
        (org-clock-continuously nil)
        (org-clock-leftover-time nil)
        (org-clock-persist nil)
        (org-log-note-clock-out nil)
        (org-log-into-drawer nil))
    (let* ((file (omarchy-org-agenda-test--write
                  (expand-file-name "actions.org" dir)
                  (omarchy-org-agenda-test--actions-text extra)))
           (other (omarchy-org-agenda-test--write
                   (expand-file-name "other.org" dir)
                   (concat "* TODO Gamma elsewhere\nSCHEDULED: "
                           (omarchy-org-agenda-test--ts 0) "\n")))
           (payload (omarchy-org-agenda-test--export dir (list file other))))
      (unwind-protect (funcall fn file other payload)
        (omarchy-org-agenda-test--stop-clock)
        (omarchy-org-agenda-test--clear-notes)))))

(defmacro omarchy-org-agenda-test--with-actions (spec &rest body)
  "Run BODY with (FILE OTHER PAYLOAD) of SPEC bound to the actions fixture.
See `omarchy-org-agenda-test--in-actions'."
  (declare (indent 1) (debug ((symbolp symbolp symbolp) body)))
  `(omarchy-org-agenda-test--with-dir (dir)
     (omarchy-org-agenda-test--in-actions
      dir (lambda ,spec (ignore ,@spec) ,@body))))

(defun omarchy-org-agenda-test--act (fn &rest args)
  "The JSON result of the action FN on ARGS, as a plist; nulls are nil."
  (let ((json (apply fn args)))
    (should (stringp json))
    (json-parse-string json :object-type 'plist
                       :null-object nil :false-object nil)))

(defun omarchy-org-agenda-test--clock-into (file payload title &optional from)
  "`omarchy-org-agenda-clock-in' on the item of PAYLOAD with TITLE in FILE.
FROM is the keyword the bar showed, TODO by default."
  (omarchy-org-agenda-test--act
   #'omarchy-org-agenda-clock-in
   file (omarchy-org-agenda-test--line payload title) nil (or from "TODO")))

(defun omarchy-org-agenda-test--clocked ()
  "The title of the running clock's heading, or nil."
  (when (org-clocking-p)
    (org-with-point-at org-clock-hd-marker (org-get-heading t t t t))))

(defun omarchy-org-agenda-test--text (file)
  "The text of FILE's buffer, all of it."
  (with-current-buffer (find-buffer-visiting file)
    (org-with-wide-buffer (buffer-substring-no-properties (point-min) (point-max)))))

(defconst omarchy-org-agenda-test--open-clock "^CLOCK: \\[[^]\n]+\\]$"
  "A running clock line.")

(defconst omarchy-org-agenda-test--closed-clock
  "^CLOCK: \\[[^]\n]+\\]--\\[[^]\n]+\\] => "
  "A closed clock line.")

(defun omarchy-org-agenda-test--count (regexp text)
  "How many lines of TEXT match REGEXP."
  (with-temp-buffer
    (insert text)
    (count-matches regexp (point-min) (point-max))))

(ert-deftest omarchy-org-agenda-test-act-clock-in ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (let ((r (omarchy-org-agenda-test--clock-into file payload "Alpha")))
      (should (equal '("done" nil t nil)
                     (mapcar (lambda (k) (plist-get r k))
                             '(:result :state :saved :detail))))
      (should (equal "Alpha clock" (omarchy-org-agenda-test--clocked)))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (let ((disk (omarchy-org-agenda-test--disk file)))
        (should (= 1 (omarchy-org-agenda-test--count
                      omarchy-org-agenda-test--open-clock disk)))
        (should (string-match-p "Alpha clock\nSCHEDULED: [^\n]+\n:LOGBOOK:\nCLOCK: "
                                disk))))
    ;; Again: Org's "Clock continues", nothing changes.
    (let ((before (omarchy-org-agenda-test--text file))
          (r (omarchy-org-agenda-test--clock-into file payload "Alpha")))
      (should (equal '("done" nil t) (list (plist-get r :result) (plist-get r :state)
                                           (plist-get r :saved))))
      (should (equal before (omarchy-org-agenda-test--text file)))
      (should (equal "Alpha clock" (omarchy-org-agenda-test--clocked))))))

(ert-deftest omarchy-org-agenda-test-act-clock-in-unsaved ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (omarchy-org-agenda-test--edit file (lambda () (goto-char (point-max))
                                          (insert "Unsaved text\n")))
    (let ((r (omarchy-org-agenda-test--clock-into file payload "Alpha")))
      (should (equal "done" (plist-get r :result)))
      (should-not (plist-get r :saved)))
    (should (equal "Alpha clock" (omarchy-org-agenda-test--clocked)))
    (should (buffer-modified-p (find-buffer-visiting file)))
    (should-not (string-search "CLOCK:" (omarchy-org-agenda-test--disk file)))))

(ert-deftest omarchy-org-agenda-test-act-clock-in-switch ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (omarchy-org-agenda-test--clock-into file payload "Alpha")
    ;; Another file: both are saved.
    (let ((r (omarchy-org-agenda-test--clock-into other payload "Gamma")))
      (should (equal '("done" t) (list (plist-get r :result) (plist-get r :saved)))))
    (should (equal "Gamma elsewhere" (omarchy-org-agenda-test--clocked)))
    (let ((disk (omarchy-org-agenda-test--disk file)))
      (should (= 1 (omarchy-org-agenda-test--count
                    omarchy-org-agenda-test--closed-clock disk)))
      (should (= 0 (omarchy-org-agenda-test--count
                    omarchy-org-agenda-test--open-clock disk))))
    (should (= 1 (omarchy-org-agenda-test--count
                  omarchy-org-agenda-test--open-clock
                  (omarchy-org-agenda-test--disk other))))
    (should-not (buffer-modified-p (find-buffer-visiting file)))
    (should-not (buffer-modified-p (find-buffer-visiting other)))
    ;; Back, in the same file, by ID after a line shift; OTHER had unsaved
    ;; edits, so it keeps them, its clock closed in the buffer only.
    (omarchy-org-agenda-test--edit other (lambda () (goto-char (point-max))
                                           (insert "Unsaved\n")))
    (let ((r (omarchy-org-agenda-test--act
              #'omarchy-org-agenda-clock-in
              file (omarchy-org-agenda-test--line payload "Beta") "clock-beta" "TODO")))
      (should (equal '("done" t) (list (plist-get r :result) (plist-get r :saved)))))
    (should (equal "Beta clock" (omarchy-org-agenda-test--clocked)))
    (should (buffer-modified-p (find-buffer-visiting other)))
    (should (string-match-p omarchy-org-agenda-test--open-clock
                            (omarchy-org-agenda-test--disk other)))
    (should (string-match-p omarchy-org-agenda-test--closed-clock
                            (omarchy-org-agenda-test--text other)))))

(ert-deftest omarchy-org-agenda-test-act-clock-in-switch-note ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (omarchy-org-agenda-test--clock-into file payload "Alpha")
    (let* ((org-log-note-clock-out t)
           (r (omarchy-org-agenda-test--clock-into other payload "Gamma")))
      ;; The clocked-in file is saved now, the clocked-out one with its note.
      (should (equal '("note-frame" t) (list (plist-get r :result) (plist-get r :saved))))
      (should (equal "Gamma elsewhere" (omarchy-org-agenda-test--clocked)))
      (should-not (buffer-modified-p (find-buffer-visiting other)))
      (should (buffer-modified-p (find-buffer-visiting file)))
      (should (string-match-p omarchy-org-agenda-test--open-clock
                              (omarchy-org-agenda-test--disk file)))
      (should (omarchy-org-agenda-take-note))
      (omarchy-org-agenda-test--store-note "Switching to Gamma")
      (let ((disk (omarchy-org-agenda-test--disk file)))
        (should (string-search "Switching to Gamma" disk))
        (should (string-match-p omarchy-org-agenda-test--closed-clock disk)))
      (should-not (buffer-modified-p (find-buffer-visiting file))))))

(ert-deftest omarchy-org-agenda-test-act-clock-in-switch-state ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (let* ((org-clock-in-switch-to-state "NEXT")
           (r (omarchy-org-agenda-test--clock-into file payload "Alpha")))
      (should (equal '("done" "NEXT" t)
                     (list (plist-get r :result) (plist-get r :state)
                           (plist-get r :saved))))
      (should (string-search "* NEXT Alpha clock" (omarchy-org-agenda-test--disk file)))
      (should (equal "Alpha clock" (omarchy-org-agenda-test--clocked))))))

(ert-deftest omarchy-org-agenda-test-act-clock-in-refusals ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (let ((alpha (omarchy-org-agenda-test--line payload "Alpha"))
          (result (lambda (&rest args)
                    (plist-get (apply #'omarchy-org-agenda-test--act
                                      #'omarchy-org-agenda-clock-in args)
                               :result))))
      (should (equal "invalid" (funcall result file "3" nil "TODO")))
      (should (equal "invalid" (funcall result "actions.org" alpha nil "TODO")))
      (should (equal "invalid" (funcall result file alpha nil 'todo)))
      (should (equal "changed" (funcall result file 9999 nil "TODO")))
      (should (equal "changed" (funcall result file alpha nil "NEXT")))
      (should (equal "changed" (funcall result file alpha "other-id" "TODO")))
      (omarchy-org-agenda-test--edit
       file (lambda () (re-search-forward "^\\* TODO Alpha clock")
              (replace-match "* TODO Alpha renamed")))
      (should (equal "changed" (funcall result file alpha nil "TODO")))
      (omarchy-org-agenda-test--edit
       file (lambda () (re-search-forward "^\\* TODO Alpha renamed")
              (replace-match "* NEXT Alpha clock")))
      (should (equal "changed" (funcall result file alpha nil "TODO")))
      (should-not (org-clocking-p))
      ;; Unsaved edits and a newer file.
      (omarchy-org-agenda-test--rewrite file "Delta later" "Delta moved")
      (should (equal "conflict" (funcall result file alpha nil "NEXT")))
      ;; A note queued elsewhere.
      (add-hook 'post-command-hook #'org-add-log-note 'append)
      (should (equal "busy" (funcall result other
                                     (omarchy-org-agenda-test--line payload "Gamma")
                                     nil "TODO")))
      (should-not (org-clocking-p))
      (should-not (string-search "CLOCK:" (omarchy-org-agenda-test--text other))))))

(ert-deftest omarchy-org-agenda-test-act-clock-in-revert ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (find-file-noselect file)
    (omarchy-org-agenda-test--rewrite file "Delta later" "Delta moved")
    (should (equal "done" (plist-get (omarchy-org-agenda-test--clock-into
                                      file payload "Alpha")
                                     :result)))
    (let ((disk (omarchy-org-agenda-test--disk file)))
      (should (string-search "Delta moved" disk))
      (should (string-match-p omarchy-org-agenda-test--open-clock disk)))))

(ert-deftest omarchy-org-agenda-test-act-clock-in-week ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (let ((line (omarchy-org-agenda-test--file-line file "Delta later")))
      (should (equal "changed" (plist-get (omarchy-org-agenda-test--act
                                           #'omarchy-org-agenda-clock-in
                                           file line nil "TODO")
                                          :result)))
      (omarchy-org-agenda-week 1)
      (should (equal "done" (plist-get (omarchy-org-agenda-test--act
                                        #'omarchy-org-agenda-clock-in
                                        file line nil "TODO")
                                       :result)))
      (should (equal "Delta later" (omarchy-org-agenda-test--clocked))))))

(ert-deftest omarchy-org-agenda-test-act-dangling ()
  (omarchy-org-agenda-test--with-dir (dir)
    (omarchy-org-agenda-test--in-actions
     dir
     (lambda (file _other payload)
       (let* ((org-clock-auto-clock-resolution t)
              (before (omarchy-org-agenda-test--text file))
              (r (omarchy-org-agenda-test--clock-into file payload "Alpha")))
         (should (equal "needs-emacs" (plist-get r :result)))
         (should (string-match-p "\\`Dangling clock started [0-9]+ mins ago\\'"
                                 (plist-get r :detail)))
         (should-not (plist-get r :saved))
         (should (equal before (omarchy-org-agenda-test--text file)))
         (should-not (buffer-modified-p (find-buffer-visiting file)))
         (should-not (org-clocking-p))
         (should-not org-clock-current-task)
         (should-not (get-buffer "*Org Clock*"))))
     omarchy-org-agenda-test--dangling)))

(ert-deftest omarchy-org-agenda-test-act-leftover ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (let* ((org-clock-leftover-time (time-subtract nil 600))
           (before (omarchy-org-agenda-test--text file))
           (r (omarchy-org-agenda-test--clock-into file payload "Alpha")))
      (should (equal '("needs-emacs" "You stopped another clock 10 mins ago; start this one from then?")
                     (list (plist-get r :result) (plist-get r :detail))))
      (should (equal before (omarchy-org-agenda-test--text file)))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (should-not (org-clocking-p)))))

(ert-deftest omarchy-org-agenda-test-act-rollback ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (let* ((buf (find-file-noselect file))
           (marker (omarchy-org-agenda--locate
                    file (omarchy-org-agenda-test--line payload "Alpha")))
           (before (omarchy-org-agenda-test--text file))
           ;; Past the pre-check: Org asks after inserting "CLOCK: ".
           (r (let ((org-clock-leftover-time (time-subtract nil 600)))
                (omarchy-org-agenda--clock-in-at buf marker))))
      (should (equal "needs-emacs" (plist-get r :result)))
      (should (string-match-p "\\`You stopped another clock 10 mins ago"
                              (plist-get r :detail)))
      (should (equal before (omarchy-org-agenda-test--text file)))
      (should-not (buffer-modified-p buf))
      (should-not (org-clocking-p))
      (should-not org-clock-current-task)
      (should-not (omarchy-org-agenda--note-queued-p))
      ;; Switching within the file: the old clock stays closed, the new
      ;; one is rolled back.
      (omarchy-org-agenda-test--clock-into file payload "Beta")
      (let ((r (let ((org-clock-leftover-time (time-subtract nil 600)))
                 (omarchy-org-agenda--clock-in-at buf marker)))
            (text (omarchy-org-agenda-test--text file)))
        (should (equal "needs-emacs" (plist-get r :result)))
        (should-not (org-clocking-p))
        (should (= 1 (omarchy-org-agenda-test--count
                      omarchy-org-agenda-test--closed-clock text)))
        (should (= 0 (omarchy-org-agenda-test--count
                      omarchy-org-agenda-test--open-clock text)))
        (should (= 1 (omarchy-org-agenda-test--count "^CLOCK:" text)))))))

(ert-deftest omarchy-org-agenda-test-act-clock-out ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (should (equal '(:result "not-clocking" :state nil :saved nil :detail nil)
                   (omarchy-org-agenda-test--act #'omarchy-org-agenda-clock-out)))
    (omarchy-org-agenda-test--clock-into file payload "Alpha")
    (let ((r (omarchy-org-agenda-test--act #'omarchy-org-agenda-clock-out)))
      (should (equal '("done" nil t) (list (plist-get r :result) (plist-get r :state)
                                           (plist-get r :saved)))))
    (should-not (org-clocking-p))
    (should-not (buffer-modified-p (find-buffer-visiting file)))
    (should (string-match-p omarchy-org-agenda-test--closed-clock
                            (omarchy-org-agenda-test--disk file)))
    ;; With a state to switch to.
    (omarchy-org-agenda-test--clock-into file payload "Alpha")
    (let* ((org-clock-out-switch-to-state "NEXT")
           (r (omarchy-org-agenda-test--act #'omarchy-org-agenda-clock-out)))
      (should (equal '("done" "NEXT" t) (list (plist-get r :result) (plist-get r :state)
                                              (plist-get r :saved)))))
    (should (string-search "* NEXT Alpha clock" (omarchy-org-agenda-test--disk file)))))

(ert-deftest omarchy-org-agenda-test-act-clock-out-note ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (omarchy-org-agenda-test--clock-into file payload "Alpha")
    (let* ((org-log-note-clock-out t)
           (r (omarchy-org-agenda-test--act #'omarchy-org-agenda-clock-out)))
      (should (equal '("note-frame" nil) (list (plist-get r :result) (plist-get r :saved))))
      (should-not (org-clocking-p))
      (should (omarchy-org-agenda--note-queued-p))
      (should (equal "busy" (plist-get (omarchy-org-agenda-test--clock-into
                                        file payload "Beta")
                                       :result)))
      (should (string-match-p omarchy-org-agenda-test--open-clock
                              (omarchy-org-agenda-test--disk file)))
      (should (eq t (omarchy-org-agenda-take-note)))
      (omarchy-org-agenda-test--store-note "Clocked out for lunch")
      (let ((disk (omarchy-org-agenda-test--disk file)))
        (should (string-search "Clocked out for lunch" disk))
        (should (string-match-p omarchy-org-agenda-test--closed-clock disk)))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (should-not (omarchy-org-agenda-test--advised-p)))))

(ert-deftest omarchy-org-agenda-test-act-clock-cancel ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (should (equal "not-clocking" (plist-get (omarchy-org-agenda-test--act
                                              #'omarchy-org-agenda-clock-cancel)
                                             :result)))
    (let ((before (omarchy-org-agenda-test--disk file)))
      (omarchy-org-agenda-test--clock-into file payload "Alpha")
      (should (string-search "CLOCK:" (omarchy-org-agenda-test--disk file)))
      (let ((r (omarchy-org-agenda-test--act #'omarchy-org-agenda-clock-cancel)))
        (should (equal '("done" t) (list (plist-get r :result) (plist-get r :saved)))))
      (should-not (org-clocking-p))
      ;; The clock line and its drawer are gone.
      (should (equal before (omarchy-org-agenda-test--disk file)))
      (should-not (buffer-modified-p (find-buffer-visiting file))))))

(ert-deftest omarchy-org-agenda-test-act-clock-goto ()
  (omarchy-org-agenda-test--with-actions (file other payload)
    (should-error (omarchy-org-agenda-clock-goto) :type 'user-error)
    (omarchy-org-agenda-test--clock-into file payload "Beta")
    (save-window-excursion
      (should (eq t (omarchy-org-agenda-clock-goto)))
      (should (eq (find-buffer-visiting file) (window-buffer)))
      (should (eq (current-buffer) (window-buffer)))
      (should (looking-at "^\\* TODO Beta clock")))))

(ert-deftest omarchy-org-agenda-test-act-never-load ()
  ;; A fresh Emacs, as the user's: nothing clocking, org-clock not loaded.
  ;; Clocking in loads it, under the guard: its load talks to D-Bus.
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((a (omarchy-org-agenda-test--small dir "A"))
           (out (expand-file-name "agenda.json" dir))
           (form (format "(progn
  (omarchy-org-agenda-ensure %S (list %S) nil)
  (omarchy-org-agenda-export)
  (prin1 (list (omarchy-org-agenda-clock-out)
               (omarchy-org-agenda-clock-cancel)
               (condition-case err (omarchy-org-agenda-clock-goto)
                 (user-error (car err)))
               (featurep 'org-clock)
               (omarchy-org-agenda-clock-in %S 1 nil \"TODO\")
               (featurep 'org-clock)
               (org-clocking-p)
               (featurep 'org-pomodoro))))"
                         out a a))
           (result
            (with-temp-buffer
              (should (eql 0 (call-process
                              (expand-file-name invocation-name invocation-directory)
                              nil '(t nil) nil
                              "--batch" "-Q"
                              "-l" omarchy-org-agenda-test--source
                              "--eval" form)))
              (car (read-from-string (buffer-string)))))
           (none "{\"result\":\"not-clocking\",\"state\":null,\"saved\":false,\"detail\":null}")
           (done "{\"result\":\"done\",\"state\":null,\"saved\":true,\"detail\":null}"))
      (should (equal (list none none 'user-error nil done t t nil) result))
      (should (string-match-p omarchy-org-agenda-test--open-clock
                              (omarchy-org-agenda-test--disk a))))))

;;;; Timers: acting on org-pomodoro, through a richer stub

(defconst omarchy-org-agenda-test--pomodoro-steps
  '("(defun org-pomodoro-active-p () (not (eq org-pomodoro-state :none)))"
    "(defun org-pomodoro-expires-p ()
  (> (/ (float-time (time-subtract nil org-pomodoro-last-clock-in)) 60)
     org-pomodoro-expiry-time))"
    "(defun org-pomodoro-set (state)
  (setq org-pomodoro-state state
        org-pomodoro-end-time
        (pcase state
          (:pomodoro (time-add nil (* 60 org-pomodoro-length)))
          (:overtime (current-time))
          (:short-break (time-add nil (* 60 org-pomodoro-short-break-length)))
          (:long-break (time-add nil (* 60 org-pomodoro-long-break-length))))))"
    "(defun org-pomodoro-start (&optional state)
  (org-pomodoro-set (or state :pomodoro))
  (when (eq org-pomodoro-state :pomodoro)
    (run-hooks 'org-pomodoro-started-hook)))"
    "(defun org-pomodoro-reset ()
  (setq org-pomodoro-state :none org-pomodoro-end-time nil))"
    "(defun org-pomodoro-overtime ()
  (org-pomodoro-start :overtime)
  (run-hooks 'org-pomodoro-overtime-hook))"
    "(defun org-pomodoro-finished ()
  (unless org-pomodoro-clock-break (org-clock-out nil t))
  (setq org-pomodoro-count (1+ org-pomodoro-count))
  (org-pomodoro-start (if (zerop (mod org-pomodoro-count
                                      org-pomodoro-long-break-frequency))
                          :long-break
                        :short-break))
  (run-hooks 'org-pomodoro-finished-hook))"
    "(defun org-pomodoro-killed ()
  (org-pomodoro-reset)
  (when (org-clocking-p)
    (if org-pomodoro-keep-killed-pomodoro-time
        (org-clock-out nil t)
      (org-clock-cancel)))
  (run-hooks 'org-pomodoro-killed-hook))"
    "(defun org-pomodoro-kill () (org-pomodoro-killed))"
    "(defun org-pomodoro (&optional _arg) (error \"Never call the command\"))")
  "The stub's functions, with the effects of org-pomodoro's that matter:
states, end time, count, clocking out or cancelling, and the hooks.
No timer runs: tests move between states themselves.")

(defun omarchy-org-agenda-test--pomodoro-full-stub (&optional without)
  "A stub with org-pomodoro's variables and steps, but WITHOUT that function."
  (concat
   ";;; org-pomodoro.el --- Richer test stub  -*- lexical-binding: t; -*-\n"
   "(require 'org-clock)\n"
   (mapconcat
    (pcase-lambda (`(,var ,value)) (format "(defvar %s %S)\n" var value))
    '((org-pomodoro-state :none) (org-pomodoro-end-time nil)
      (org-pomodoro-length 25) (org-pomodoro-short-break-length 5)
      (org-pomodoro-long-break-length 20) (org-pomodoro-long-break-frequency 4)
      (org-pomodoro-count 0) (org-pomodoro-last-clock-in nil)
      (org-pomodoro-expiry-time 120) (org-pomodoro-ask-upon-killing t)
      (org-pomodoro-keep-killed-pomodoro-time nil) (org-pomodoro-clock-break nil))
    "")
   (mapconcat (lambda (hook) (format "(defvar %s nil)\n" hook))
              omarchy-org-agenda-test--pomodoro-hooks
              "")
   (mapconcat (lambda (step) (concat step "\n"))
              (seq-remove (lambda (step)
                            (and without
                                 (string-prefix-p (format "(defun %s " without) step)))
                          omarchy-org-agenda-test--pomodoro-steps)
              "")
   "(provide 'org-pomodoro)\n"))

(defmacro omarchy-org-agenda-test--with-pomodoro (spec &rest body)
  "Run BODY with (FILE OTHER PAYLOAD) of SPEC, the actions fixture.
The richer org-pomodoro stub is on `load-path', not loaded yet; the
actions load it, and it is unloaded afterwards."
  (declare (indent 1) (debug ((symbolp symbolp symbolp) body)))
  `(omarchy-org-agenda-test--with-stub
       (_stub (omarchy-org-agenda-test--pomodoro-full-stub))
     (omarchy-org-agenda-test--in-actions
      dir (lambda ,spec (ignore ,@spec) ,@body))))

(defun omarchy-org-agenda-test--pomodoro (&rest args)
  "`omarchy-org-agenda-pomodoro' on ARGS, its JSON parsed to a plist."
  (apply #'omarchy-org-agenda-test--act #'omarchy-org-agenda-pomodoro args))

(defun omarchy-org-agenda-test--start-pomodoro (file payload title)
  "Start a pomodoro on the item of PAYLOAD with TITLE in FILE; return the result."
  (omarchy-org-agenda-test--pomodoro
   file (omarchy-org-agenda-test--line payload title) nil "TODO" nil))

(defun omarchy-org-agenda-test--stopping (&optional confirm)
  "`omarchy-org-agenda-pomodoro' for a running pomodoro, with CONFIRM."
  (omarchy-org-agenda-test--pomodoro nil nil nil nil confirm))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-start ()
  (omarchy-org-agenda-test--with-pomodoro (file other payload)
    (should-not (featurep 'org-pomodoro))
    (let ((r (omarchy-org-agenda-test--start-pomodoro file payload "Alpha")))
      (should (equal '("done" nil t) (list (plist-get r :result) (plist-get r :state)
                                           (plist-get r :saved)))))
    (should (featurep 'org-pomodoro))
    (should (eq :pomodoro org-pomodoro-state))
    (should (equal "Alpha clock" (omarchy-org-agenda-test--clocked)))
    (should (< (float-time (time-since org-pomodoro-last-clock-in)) 60))
    (should (= 0 org-pomodoro-count))
    (should (string-match-p omarchy-org-agenda-test--open-clock
                            (omarchy-org-agenda-test--disk file)))
    (should (equal "pomodoro" (plist-get (plist-get (omarchy-org-agenda--timers)
                                                    :pomodoro)
                                         :state)))))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-count ()
  (omarchy-org-agenda-test--with-pomodoro (file other payload)
    (require 'org-pomodoro)
    ;; Expired: reset silently.
    (setq org-pomodoro-count 3
          org-pomodoro-last-clock-in (time-subtract nil (* 3 3600)))
    (should (equal "done" (plist-get (omarchy-org-agenda-test--start-pomodoro
                                      file payload "Alpha")
                                     :result)))
    (should (= 0 org-pomodoro-count))
    (should (equal "done" (plist-get (omarchy-org-agenda-test--stopping t) :result)))
    ;; Recent: kept.
    (setq org-pomodoro-count 3
          org-pomodoro-last-clock-in (time-subtract nil 600))
    (should (equal "done" (plist-get (omarchy-org-agenda-test--start-pomodoro
                                      file payload "Beta")
                                     :result)))
    (should (= 3 org-pomodoro-count))
    (should (eq :pomodoro org-pomodoro-state))))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-not-started ()
  (omarchy-org-agenda-test--with-pomodoro (file other payload)
    (require 'org-pomodoro)
    (let ((last (time-subtract nil (* 3 3600))))
      (setq org-pomodoro-count 3
            org-pomodoro-last-clock-in last)
      (omarchy-org-agenda-test--edit
       file (lambda () (re-search-forward "^\\* TODO Alpha clock")
              (replace-match "* TODO Alpha renamed")))
      (should (equal "changed" (plist-get (omarchy-org-agenda-test--start-pomodoro
                                           file payload "Alpha")
                                          :result)))
      (should (equal "invalid" (plist-get (omarchy-org-agenda-test--pomodoro
                                           nil nil nil nil nil)
                                          :result)))
      ;; Org wanted to ask: no clock, so no pomodoro.
      (let ((org-clock-leftover-time (time-subtract nil 600)))
        (should (equal "needs-emacs" (plist-get (omarchy-org-agenda-test--start-pomodoro
                                                 file payload "Beta")
                                                :result))))
      (should-not (org-clocking-p))
      (should (eq :none org-pomodoro-state))
      (should (eq last org-pomodoro-last-clock-in))
      (should (= 3 org-pomodoro-count)))))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-already-clocked ()
  ;; As `org-pomodoro': Org says "Clock continues", the pomodoro starts.
  (omarchy-org-agenda-test--with-pomodoro (file other payload)
    (omarchy-org-agenda-test--clock-into file payload "Alpha")
    (let ((before (omarchy-org-agenda-test--text file))
          (r (omarchy-org-agenda-test--start-pomodoro file payload "Alpha")))
      (should (equal '("done" nil t nil)
                     (mapcar (lambda (k) (plist-get r k))
                             '(:result :state :saved :detail))))
      (should (equal before (omarchy-org-agenda-test--text file))))
    (should (eq :pomodoro org-pomodoro-state))
    (should (< (float-time (time-since org-pomodoro-last-clock-in)) 60))
    (should (equal "Alpha clock" (omarchy-org-agenda-test--clocked)))
    (let ((text (omarchy-org-agenda-test--text file)))
      (should (= 1 (omarchy-org-agenda-test--count "^CLOCK:" text)))
      (should (= 1 (omarchy-org-agenda-test--count
                    omarchy-org-agenda-test--open-clock text))))))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-start-note ()
  ;; Switching from a clocked entry queues its clock-out note: the new
  ;; clock runs, so does the pomodoro, and the note is still to take.
  (omarchy-org-agenda-test--with-pomodoro (file other payload)
    (omarchy-org-agenda-test--clock-into file payload "Alpha")
    (let* ((org-log-note-clock-out t)
           (r (omarchy-org-agenda-test--start-pomodoro other payload "Gamma")))
      (should (equal '("note-frame" t nil)
                     (mapcar (lambda (k) (plist-get r k)) '(:result :saved :detail))))
      (should (eq :pomodoro org-pomodoro-state))
      (should (equal "Gamma elsewhere" (omarchy-org-agenda-test--clocked)))
      (should (omarchy-org-agenda--note-queued-p))
      (should (eq t (omarchy-org-agenda-take-note)))
      (omarchy-org-agenda-test--store-note "Pomodoro on Gamma")
      (let ((disk (omarchy-org-agenda-test--disk file)))
        (should (string-search "Pomodoro on Gamma" disk))
        (should (string-match-p omarchy-org-agenda-test--closed-clock disk)))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (should (eq :pomodoro org-pomodoro-state))
      (should (equal "Gamma elsewhere" (omarchy-org-agenda-test--clocked))))))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-start-fails ()
  ;; The clock-in is done, the pomodoro step isn't: its result wins.
  (omarchy-org-agenda-test--with-pomodoro (file other payload)
    (require 'org-pomodoro)
    (cl-letf (((symbol-function 'org-pomodoro-start)
               (lambda (&optional _state) (y-or-n-p "Start the pomodoro? "))))
      (let ((r (omarchy-org-agenda-test--start-pomodoro file payload "Alpha")))
        (should (equal '("needs-emacs" t)
                       (list (plist-get r :result) (plist-get r :saved))))
        (should (string-match-p
                 "\\`Start the pomodoro\\?.*no pomodoro started; the clock is still running\\'"
                 (plist-get r :detail)))))
    (should (eq :none org-pomodoro-state))
    (should (equal "Alpha clock" (omarchy-org-agenda-test--clocked)))
    (cl-letf (((symbol-function 'org-pomodoro-start)
               (lambda (&optional _state) (error "Boom"))))
      (let ((r (omarchy-org-agenda-test--start-pomodoro other payload "Gamma")))
        (should (equal '("error" "Boom; no pomodoro started; the clock is still running")
                       (list (plist-get r :result) (plist-get r :detail))))))
    (should (eq :none org-pomodoro-state))
    (should (equal "Gamma elsewhere" (omarchy-org-agenda-test--clocked)))))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-stop ()
  (omarchy-org-agenda-test--with-pomodoro (file other payload)
    (let ((before (omarchy-org-agenda-test--disk file)))
      (omarchy-org-agenda-test--start-pomodoro file payload "Alpha")
      ;; Asking first is org-pomodoro's default.
      (should (equal '(:result "confirm" :state nil :saved nil :detail nil)
                     (omarchy-org-agenda-test--stopping)))
      (should (eq :pomodoro org-pomodoro-state))
      (should (org-clocking-p))
      (let ((r (omarchy-org-agenda-test--stopping t)))
        (should (equal '("done" t) (list (plist-get r :result) (plist-get r :saved)))))
      (should (eq :none org-pomodoro-state))
      (should-not (org-clocking-p))
      ;; Killed: the clock was cancelled, its line removed.
      (should (equal before (omarchy-org-agenda-test--disk file))))
    ;; Not asking: stops without the flag; keeping the time clocks out.
    (setq org-pomodoro-ask-upon-killing nil
          org-pomodoro-keep-killed-pomodoro-time t)
    (omarchy-org-agenda-test--start-pomodoro file payload "Alpha")
    (should (equal "done" (plist-get (omarchy-org-agenda-test--stopping) :result)))
    (should (eq :none org-pomodoro-state))
    (should-not (org-clocking-p))
    (should (string-match-p omarchy-org-agenda-test--closed-clock
                            (omarchy-org-agenda-test--disk file)))
    ;; A break stops the same way, with no clock to stop.
    (setq org-pomodoro-ask-upon-killing t)
    (org-pomodoro-start :short-break)
    (should (equal "confirm" (plist-get (omarchy-org-agenda-test--stopping) :result)))
    (should (equal '("done" nil) (let ((r (omarchy-org-agenda-test--stopping t)))
                                   (list (plist-get r :result) (plist-get r :saved)))))
    (should (eq :none org-pomodoro-state))))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-overtime ()
  (omarchy-org-agenda-test--with-pomodoro (file other payload)
    (omarchy-org-agenda-test--start-pomodoro file payload "Alpha")
    (org-pomodoro-overtime)
    (should (eq :overtime org-pomodoro-state))
    ;; Busy while a note is queued.
    (add-hook 'post-command-hook #'org-add-log-note 'append)
    (should (equal "busy" (plist-get (omarchy-org-agenda-test--stopping) :result)))
    (omarchy-org-agenda-test--clear-notes)
    (let ((r (omarchy-org-agenda-test--stopping)))
      (should (equal '("done" t) (list (plist-get r :result) (plist-get r :saved)))))
    (should (eq :short-break org-pomodoro-state))
    (should (= 1 org-pomodoro-count))
    (should-not (org-clocking-p))
    (should (string-match-p omarchy-org-agenda-test--closed-clock
                            (omarchy-org-agenda-test--disk file)))))

(ert-deftest omarchy-org-agenda-test-act-pomodoro-unavailable ()
  (omarchy-org-agenda-test--with-dir (dir)
    (omarchy-org-agenda-test--in-actions
     dir
     (lambda (file _other payload)
       (should-not (locate-library "org-pomodoro"))
       (should (equal '("unavailable" "org-pomodoro can't be loaded")
                      (let ((r (omarchy-org-agenda-test--start-pomodoro
                                file payload "Alpha")))
                        (list (plist-get r :result) (plist-get r :detail)))))
       (should-not (org-clocking-p)))))
  (omarchy-org-agenda-test--with-stub
      (_stub (omarchy-org-agenda-test--pomodoro-full-stub 'org-pomodoro-start))
    (omarchy-org-agenda-test--in-actions
     dir
     (lambda (file _other payload)
       (should (equal '("unavailable" "org-pomodoro has no org-pomodoro-start")
                      (let ((r (omarchy-org-agenda-test--start-pomodoro
                                file payload "Alpha")))
                        (list (plist-get r :result) (plist-get r :detail)))))
       (should-not (org-clocking-p))))))

;;;; Timers: hooks and loading

(defun omarchy-org-agenda-test--scheduled-reason ()
  "The reason of the pending push export, or nil."
  (and (timerp omarchy-org-agenda--timer)
       (car (timer--args omarchy-org-agenda--timer))))

(ert-deftest omarchy-org-agenda-test-timers-hooks ()
  (omarchy-org-agenda-test--with-stub (_stub)
    (let ((out (expand-file-name "agenda.json" dir)))
      (omarchy-org-agenda-ensure out nil nil)
      (should (equal omarchy-org-agenda-test--no-hooks
                     (omarchy-org-agenda-test--hooks-installed)))
      ;; Before org-pomodoro loads: its `defvar's keep our functions.
      (omarchy-org-agenda-ensure out nil t)
      (should (equal omarchy-org-agenda-test--all-hooks
                     (omarchy-org-agenda-test--hooks-installed)))
      (should-not (featurep 'org-pomodoro))
      (require 'org-pomodoro)
      (should (equal omarchy-org-agenda-test--all-hooks
                     (omarchy-org-agenda-test--hooks-installed)))
      (dolist (case (append
                     (mapcar (lambda (hook) (cons hook "clock"))
                             omarchy-org-agenda-test--clock-hooks)
                     (mapcar (lambda (hook) (cons hook "pomodoro"))
                             omarchy-org-agenda-test--pomodoro-hooks)))
        (omarchy-org-agenda--schedule "other")
        (run-hooks (car case))
        (should (equal (cdr case) (omarchy-org-agenda-test--scheduled-reason))))
      (omarchy-org-agenda--remove-push-hooks)
      (should (equal omarchy-org-agenda-test--no-hooks
                     (omarchy-org-agenda-test--hooks-installed)))
      (should-not omarchy-org-agenda--timer)
      (omarchy-org-agenda-ensure out nil t)
      (omarchy-org-agenda-teardown)
      (should (equal omarchy-org-agenda-test--no-hooks
                     (omarchy-org-agenda-test--hooks-installed))))))

(ert-deftest omarchy-org-agenda-test-timers-clock-in-pushes ()
  (omarchy-org-agenda-test--with-clock (file)
    (omarchy-org-agenda-ensure (expand-file-name "agenda.json" dir) (list file) t)
    (omarchy-org-agenda-test--clock-in file "Clock target")
    (should (equal "clock" (omarchy-org-agenda-test--scheduled-reason)))
    (omarchy-org-agenda--schedule "other")
    (org-clock-cancel)
    (should (equal "clock" (omarchy-org-agenda-test--scheduled-reason)))
    ;; The scheduled export itself: the clock is gone.
    (omarchy-org-agenda--push-export "clock")
    (let ((payload (omarchy-org-agenda-test--read omarchy-org-agenda-output)))
      (should (equal "clock" (plist-get payload :reason)))
      (should (eq :null (plist-get payload :clock))))))

(ert-deftest omarchy-org-agenda-test-timers-never-load ()
  ;; A fresh Emacs, as the user's: org-clock and org-pomodoro not loaded.
  (omarchy-org-agenda-test--with-dir (dir)
    (let* ((stub (omarchy-org-agenda-test--write-stub dir))
           (a (omarchy-org-agenda-test--small dir "A"))
           (out (expand-file-name "agenda.json" dir))
           (form (format "(progn
  (omarchy-org-agenda-ensure %S (list %S) t)
  (omarchy-org-agenda-export \"pull\")
  (prin1 (list (featurep 'org-clock) (featurep 'org-pomodoro))))"
                         out a))
           (result
            (with-temp-buffer
              (should (eql 0 (call-process
                              (expand-file-name invocation-name invocation-directory)
                              nil '(t nil) nil
                              "--batch" "-Q" "-L" stub
                              "-l" omarchy-org-agenda-test--source
                              "--eval" form)))
              (car (read-from-string (buffer-string)))))
           (payload (omarchy-org-agenda-test--read out)))
      (should (equal '(nil nil) result))
      (should (equal '("Item in A") (omarchy-org-agenda-test--titles payload)))
      (should (eq :null (plist-get payload :clock)))
      (should (eq t (plist-get (plist-get payload :pomodoro) :available)))
      (should (equal "none" (plist-get (plist-get payload :pomodoro) :state))))))

(defun omarchy-org-agenda-test--queue-note (dir)
  "Leave a state-change note queued for a fixture in DIR; return its timer."
  (let* ((file (omarchy-org-agenda-test--write
                (expand-file-name "state.org" dir)
                (omarchy-org-agenda-test--state-text)))
         (payload (progn (make-directory dir t)
                         (omarchy-org-agenda-test--export dir (list file)))))
    (should (equal "note-frame"
                   (plist-get (omarchy-org-agenda-test--set-state
                               file (omarchy-org-agenda-test--line payload "Beta")
                               nil "PROJ" "DONE")
                              :result)))
    (should (omarchy-org-agenda-test--advised-p))
    (plist-get omarchy-org-agenda--note :timer)))

(defun omarchy-org-agenda-test--note-gone (timer)
  "Assert the queued note, its TIMER and the store advice are all gone."
  (should-not (memq #'org-add-log-note (default-value 'post-command-hook)))
  (should-not (memq timer timer-list))
  (should-not (advice-member-p 'omarchy-org-agenda--around-store-note
                               'org-store-log-note)))

;; Named to run last; it reloads the helper anyway, so order doesn't matter.
(ert-deftest omarchy-org-agenda-test-zz-unload ()
  (let* ((dir (expand-file-name "unload/" omarchy-org-agenda-test--root))
         (out (expand-file-name "agenda.json" dir)))
    (make-directory dir t)
    (unwind-protect
        (let ((timer (omarchy-org-agenda-test--queue-note dir)))
          (omarchy-org-agenda-ensure out nil t)
          (should (equal omarchy-org-agenda-test--all-hooks
                         (omarchy-org-agenda-test--hooks-installed)))
          (unload-feature 'omarchy-org-agenda t)
          (should-not (featurep 'omarchy-org-agenda))
          (dolist (hook (append '(after-save-hook after-revert-hook post-command-hook
                                  org-after-todo-state-change-hook
                                  org-agenda-finalize-hook)
                                omarchy-org-agenda-test--clock-hooks
                                omarchy-org-agenda-test--pomodoro-hooks))
            (should-not (seq-filter
                         (lambda (fn)
                           (and (symbolp fn)
                                (string-prefix-p "omarchy-org-agenda-"
                                                 (symbol-name fn))))
                         (and (default-boundp hook) (default-value hook)))))
          (should-not (get-variable-watchers 'org-agenda-files))
          (omarchy-org-agenda-test--note-gone timer)
          (should-not (boundp 'omarchy-org-agenda--index))
          (should-not (boundp 'omarchy-org-agenda--week-index))
          (should-not (boundp 'omarchy-org-agenda--note))
          (should-not (boundp 'omarchy-org-agenda-upcoming-days)))
      (load omarchy-org-agenda-test--source nil t)
      (omarchy-org-agenda-test--clear-notes)
      (omarchy-org-agenda-test--kill-buffers dir)
      (setq omarchy-org-agenda-output nil
            omarchy-org-agenda-files-override nil))))

;; The plugin reloads the helper whenever it changes on disk.  Emacs keeps
;; replaced definitions in `function-history', and `unload-feature' revives
;; them, so a reloaded helper must not leave any behind.
(ert-deftest omarchy-org-agenda-test-zz-reload-unload ()
  (let* ((dir (expand-file-name "reload/" omarchy-org-agenda-test--root))
         (out (expand-file-name "agenda.json" dir)))
    (make-directory dir t)
    (unwind-protect
        (let ((timer (omarchy-org-agenda-test--queue-note dir)))
          (setq omarchy-org-agenda--week-index (make-hash-table :test #'equal))
          (load omarchy-org-agenda-test--source nil t)
          ;; The reload dropped the note it couldn't take any more.
          (omarchy-org-agenda-test--note-gone timer)
          (should-not omarchy-org-agenda--note)
          (should-not omarchy-org-agenda--week-index)
          (load omarchy-org-agenda-test--source nil t)
          (should-not (get 'omarchy-org-agenda-export 'function-history))
          (should-not (get 'omarchy-org-agenda-set-state 'function-history))
          ;; The reload tore the hooks down; the plugin's ensure brings them back.
          (should (equal omarchy-org-agenda-test--no-hooks
                         (omarchy-org-agenda-test--hooks-installed)))
          (omarchy-org-agenda-ensure out nil t)
          (should (equal omarchy-org-agenda-test--all-hooks
                         (omarchy-org-agenda-test--hooks-installed)))
          (unload-feature 'omarchy-org-agenda t)
          (should-not (fboundp 'omarchy-org-agenda-export))
          (should-not (fboundp 'omarchy-org-agenda--on-save))
          (should-not (fboundp 'omarchy-org-agenda-set-state))
          (should-not (fboundp 'omarchy-org-agenda-take-note))
          (should-not (fboundp 'omarchy-org-agenda--around-store-note))
          (should-not (get 'omarchy-org-agenda-set-state 'function-history))
          (should-not (get-variable-watchers 'org-agenda-files)))
      (load omarchy-org-agenda-test--source nil t)
      (omarchy-org-agenda-test--clear-notes)
      (omarchy-org-agenda-test--kill-buffers dir)
      (setq omarchy-org-agenda-output nil
            omarchy-org-agenda-files-override nil))))

;;; agenda-test.el ends here
