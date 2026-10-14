#!/usr/bin/env bash
# Drive the installed org-pomodoro through the plugin's actions, in a
# sandboxed batch Emacs.  Local only: CI doesn't have org-pomodoro.
#
# The user's packages are only read (-L on their elpa dirs); nothing is
# compiled or written there, and HOME is a temp dir as in run.sh.  Sounds
# and notifications are off.  Skips, with exit 0, when a package is missing.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
elpa="${ELPA_DIR:-$HOME/.config/emacs/elpa}"

newest() {
  local dir
  for dir in $(compgen -G "$elpa/$1-[0-9]*" | sort -V); do
    [[ -d "$dir" ]] && printf '%s\n' "$dir"
  done | tail -n 1
}

dirs=()
for pkg in org-pomodoro alert gntp log4e; do
  dir="$(newest "$pkg" || true)"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "SKIP: $pkg not found under $elpa"
    exit 0
  fi
  dirs+=("$dir")
done
# Org from elpa when there is one (the user's Emacs runs it), else built in.
org="$(newest org || true)"
[[ -n "$org" && -f "$org/org.el" ]] && dirs=("$org" "${dirs[@]}")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
marker="$tmp/started"
touch "$marker"

export HOME="$tmp/home"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_CACHE_HOME="$tmp/cache"
export XDG_DATA_HOME="$tmp/data"
export XDG_STATE_HOME="$tmp/state"
export TMPDIR="$tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

loads=()
for dir in "${dirs[@]}"; do loads+=(-L "$dir"); done

cat >"$tmp/check.el" <<'ELISP'
;;; check.el --- The real org-pomodoro, through the plugin  -*- lexical-binding: t; -*-
(setq native-comp-jit-compilation nil          ; Emacs 30+
      native-comp-deferred-compilation nil     ; Emacs 29
      inhibit-automatic-native-compilation t
      org-pomodoro-play-sounds nil
      alert-default-style 'ignore
      org-clock-persist nil
      org-clock-auto-clock-resolution nil
      org-id-locations-file (expand-file-name "org-id-locations" temporary-file-directory)
      org-persist-directory (expand-file-name "org-persist/" temporary-file-directory))

(defvar check-failures 0)

(defun check (label ok)
  "Report LABEL as passed when OK, else count a failure."
  (princ (format "%s %s\n" (if ok "ok  " "FAIL") label))
  (unless ok (setq check-failures (1+ check-failures))))

(defun result (json)
  "The JSON result of an action as a plist."
  (json-parse-string json :object-type 'plist :null-object nil :false-object nil))

(let* ((dir (make-temp-file "pomodoro-real-" t))
       (file (expand-file-name "real.org" dir))
       (out (expand-file-name "agenda.json" dir)))
  (with-temp-file file
    (insert "* TODO Real pomodoro task\nSCHEDULED: "
            (format-time-string "<%F %a>") "\n"))
  (omarchy-org-agenda-ensure out (list file) nil)
  (omarchy-org-agenda-export)
  (check "org-pomodoro not loaded by the export" (not (featurep 'org-pomodoro)))
  (let ((start (lambda ()
                 (result (omarchy-org-agenda-pomodoro file 1 nil "TODO" nil))))
        (stop (lambda (confirm)
                (result (omarchy-org-agenda-pomodoro nil nil nil nil confirm)))))
    (princ (format "Org %s, org-pomodoro from %s\n"
                   (org-version) (locate-library "org-pomodoro")))
    (let ((r (funcall start)))
      (check (format "start: %S" r) (equal "done" (plist-get r :result))))
    (check "loaded by P" (featurep 'org-pomodoro))
    (check "state :pomodoro" (eq org-pomodoro-state :pomodoro))
    (check "clock running" (org-clocking-p))
    (check "count 0" (eql 0 org-pomodoro-count))
    (let ((r (funcall stop nil)))
      (check (format "stop without confirm: %S" r)
             (equal "confirm" (plist-get r :result))))
    (check "still running" (and (eq org-pomodoro-state :pomodoro) (org-clocking-p)))
    (let ((r (funcall stop t)))
      (check (format "stop with confirm: %S" r) (equal "done" (plist-get r :result))))
    (check "killed: state :none, clock cancelled"
           (and (eq org-pomodoro-state :none) (not (org-clocking-p))))
    (check "the cancelled clock left no line"
           (not (string-search "CLOCK:" (with-temp-buffer
                                          (insert-file-contents file)
                                          (buffer-string)))))
    ;; Overtime: a manual break, with the pomodoro's time up.
    (setq org-pomodoro-manual-break t)
    (funcall start)
    (org-pomodoro-overtime)
    (check "overtime" (eq org-pomodoro-state :overtime))
    (let ((r (funcall stop nil)))
      (check (format "finish from overtime: %S" r) (equal "done" (plist-get r :result))))
    (check "short break" (eq org-pomodoro-state :short-break))
    (check "count 1" (eql 1 org-pomodoro-count))
    (check "clocked out" (not (org-clocking-p)))
    (check "closed clock line saved"
           (string-match-p "^CLOCK: \\[[^]]+\\]--\\[[^]]+\\] =>"
                           (with-temp-buffer (insert-file-contents file) (buffer-string))))
    (let ((r (funcall stop t)))
      (check (format "stop the break: %S" r) (equal "done" (plist-get r :result))))
    (check "no timer left" (and (eq org-pomodoro-state :none)
                                (not (memq org-pomodoro-timer timer-list))))
    ;; Already clocked in: as `org-pomodoro', the running clock gets one.
    (let ((clock-lines (lambda ()
                         (with-current-buffer (find-buffer-visiting file)
                           (org-with-wide-buffer
                            (count-matches "^[ \t]*CLOCK:" (point-min) (point-max)))))))
      (let ((r (result (omarchy-org-agenda-clock-in file 1 nil "TODO"))))
        (check (format "clock in: %S" r) (equal "done" (plist-get r :result))))
      (let ((before (funcall clock-lines))
            (r (funcall start)))
        (check (format "start on the clocked entry: %S" r)
               (equal "done" (plist-get r :result)))
        (check "state :pomodoro on the running clock"
               (and (eq org-pomodoro-state :pomodoro) (org-clocking-p)))
        (check "no extra clock line" (= before (funcall clock-lines))))
      (funcall stop t)
      (check "stopped" (and (eq org-pomodoro-state :none) (not (org-clocking-p)))))))

(kill-emacs (if (zerop check-failures) 0 1))
ELISP

rc=0
emacs --batch -Q "${loads[@]}" \
  -l "$root/elisp/omarchy-org-agenda.el" \
  -l "$tmp/check.el" </dev/null || rc=$?

written="$(find "${dirs[@]}" -newer "$marker" -print)"
if [[ -n "$written" ]]; then
  echo "FAIL: written into the package dirs:"
  echo "$written"
  rc=1
else
  echo "ok   nothing written into the package dirs"
fi
exit "$rc"
