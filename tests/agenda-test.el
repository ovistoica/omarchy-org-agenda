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
          (should (equal '(:save 1 :revert 1 :todo 1 :agenda 1 :watcher 1)
                         (omarchy-org-agenda-test--hooks-installed)))
          (unload-feature 'omarchy-org-agenda t)
          (should-not (featurep 'omarchy-org-agenda))
          (dolist (hook '(after-save-hook after-revert-hook post-command-hook
                          org-after-todo-state-change-hook org-agenda-finalize-hook))
            (should-not (seq-filter
                         (lambda (fn)
                           (and (symbolp fn)
                                (string-prefix-p "omarchy-org-agenda-"
                                                 (symbol-name fn))))
                         (default-value hook))))
          (should-not (get-variable-watchers 'org-agenda-files))
          (omarchy-org-agenda-test--note-gone timer)
          (should-not (boundp 'omarchy-org-agenda--index))
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
          (load omarchy-org-agenda-test--source nil t)
          ;; The reload dropped the note it couldn't take any more.
          (omarchy-org-agenda-test--note-gone timer)
          (should-not omarchy-org-agenda--note)
          (load omarchy-org-agenda-test--source nil t)
          (should-not (get 'omarchy-org-agenda-export 'function-history))
          (should-not (get 'omarchy-org-agenda-set-state 'function-history))
          ;; The reload tore the hooks down; the plugin's ensure brings them back.
          (should (equal '(:save 0 :revert 0 :todo 0 :agenda 0 :watcher 0)
                         (omarchy-org-agenda-test--hooks-installed)))
          (omarchy-org-agenda-ensure out nil t)
          (should (equal '(:save 1 :revert 1 :todo 1 :agenda 1 :watcher 1)
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
