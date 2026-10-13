# Org Agenda for Omarchy

Today's Org agenda from your running Emacs, in the Omarchy bar. Click an
entry and Emacs opens it at its heading.

![The bar: the clock, then the next entry and the overdue count](docs/screenshot-bar.png)

![The popout: the next-up card on top, then the agenda grouped into sections](docs/screenshot-popout.png)

## Requirements

- Omarchy 4.0.4 or newer.
- GNU Emacs 29.1 or newer, running as a server. Any one of these works:
  `M-x server-start`, `(server-start)` in your init file, `emacs --daemon`,
  or `systemctl --user enable --now emacs`.
- Org 9.6 or newer (bundled with Emacs 29 and later).
- `emacsclient` on your `PATH`, or its full path in the `emacsclient`
  setting.

## Install

```sh
omarchy plugin add https://github.com/ovistoica/omarchy-org-agenda
```

It asks whether to enable the plugin and which bar section to put it in,
with the centre preselected. Add `--enable` to skip the enable question.

To install by hand instead:

```sh
git clone https://github.com/ovistoica/omarchy-org-agenda \
  ~/.config/omarchy/plugins/ovistoica.org-agenda
omarchy plugin enable ovistoica.org-agenda
```

## Uninstall

```sh
omarchy plugin remove ovistoica.org-agenda
```

This disables the plugin and deletes its folder. Your running Emacs keeps
the helper loaded until it restarts; `M-x unload-feature RET
omarchy-org-agenda` removes its functions and hooks right away. The plugin
never writes to your Emacs config, and its agenda file in
`$XDG_RUNTIME_DIR/omarchy-org-agenda/` is cleared when you log out.

## How it works

- The plugin loads a small elisp helper
  ([`elisp/omarchy-org-agenda.el`](elisp/omarchy-org-agenda.el)) into your
  running Emacs through `emacsclient`.
- Emacs writes today's agenda, plus the scheduled tasks and timestamped
  entries of the next few days, as JSON to `$XDG_RUNTIME_DIR/omarchy-org-agenda/`, and the bar
  watches that file.
- The bar never polls. Emacs pushes a fresh export whenever an Org
  buffer is saved or reverted, a TODO state changes, or an agenda
  buffer is rebuilt.
- The agenda is Org's own: Org collects the entries, so your sorting
  strategy, skip functions, habits and diary sexps all apply.

## Using it

**Bar widget**

| Click  | Action                                                       |
| ------ | ------------------------------------------------------------ |
| Left   | Open the popout                                              |
| Middle | Open your `org-agenda` in Emacs (dispatcher key `agendaKey`) |
| Right  | Ask Emacs for a fresh export                                 |

**Popout keys:** `↑`/`↓` or `j`/`k` move, `↵` opens, `t` changes the
state, `r` refreshes, `Esc` closes.

Opening an entry (click or `↵`) shows its file at the heading in the
current Emacs frame, the way `emacsclient +LINE FILE` would, and focuses
the Emacs window.

**Coming up**

After today's entries, Coming up looks ahead. It lists Org's warnings for
upcoming deadlines, and the scheduled tasks and timestamped entries (like
calendar events, including multi-day ones) of the next `upcomingDays`
days (a week by default), soonest first. Each row starts with the day:
`Thu` within the week, `27 Oct` further out. Each heading shows once, at
its next date: a repeating entry at its next occurrence, a multi-day
event on its first day, and an entry that is already on today's agenda
(such as an event under way) isn't listed again. Diary entries on later
days aren't included. Set `upcomingDays` to `0` to list deadline
warnings only.

**Changing a state**

Press `t` on an entry, or click its keyword, and your TODO keywords
appear under it in their Emacs colours, each with its Org fast key
(`d DONE`):

- press a fast key, or click a keyword, to set it;
- `←`/`→` move between keywords and `↵` sets the highlighted one;
- `Esc` closes the picker, and so does `t` unless one of your keywords
  uses `t` as its fast key (then `t` sets that keyword);
- `↑`/`↓` close it and move to the next entry.

Fast keys are case-sensitive, as in Org, and take precedence over the
picker's own letters (`h`, `j`, `k`, `l`, `t`). The footer lists the keys
while the picker is open.

What happens next:

- If the new state logs a note, Emacs shows the heading with Org's
  `*Org Note*` buffer and is focused, and the popout closes. `C-c C-c`
  stores the note as usual.
- Any other change finishes in the bar: the entry updates in place and
  a one-line result appears above the footer.
- Org's blockers are respected (`org-enforce-todo-dependencies`, open
  checkboxes): nothing changes, and the popout says what is blocking.
- The file is saved when it had no other unsaved edits in Emacs;
  otherwise the change is left for you to save, and the popout says so.
- If you cancel the note with `C-c C-k`, the change stays in the
  buffer unsaved, as it does from Org's own agenda.
- If Emacs doesn't answer (say one of your hooks asks a question), the
  bar focuses Emacs so you can answer it there.

**IPC**

```sh
omarchy-shell ovistoica.org-agenda refresh   # re-export now
omarchy-shell ovistoica.org-agenda status    # status, item count, settings as JSON
omarchy-shell shell toggle ovistoica.org-agenda '{}'   # open/close the popout
```

To toggle the popout from the keyboard, bind it in
`~/.config/hypr/bindings.lua` (pick a key that is free on your system;
`omarchy menu keybindings --print` lists the taken ones):

```lua
o.bind("SUPER + ALT + O", "Org agenda", "omarchy-shell shell toggle ovistoica.org-agenda '{}'")
```

## Settings

Edit them in the widget's settings in the bar, or from a terminal:

```sh
omarchy bar set ovistoica.org-agenda label Count
```

| Key              | Type    | Default       | Meaning                                                                                                   |
| ---------------- | ------- | ------------- | --------------------------------------------------------------------------------------------------------- |
| `label`          | enum    | `"Next item"` | Bar label: `Next item` (next entry's time and title), `Count` (open entries today) or `Icon` (icon only) |
| `maxTitleChars`  | integer | `28`          | Longest title shown in the bar (10–80)                                                                    |
| `overdueBadge`   | boolean | `true`        | Show the overdue count badge                                                                              |
| `habitsInBadge`  | boolean | `false`       | Count missed habits as overdue                                                                            |
| `showDone`       | boolean | `true`        | Keep done entries in the popout, struck through                                                           |
| `upcomingDays`   | integer | `7`           | Days after today whose scheduled tasks and timestamped entries (like calendar events, including multi-day ones) Coming up lists, one row per heading at its next date (0–31); `0` lists deadline warnings only |
| `pushUpdates`    | boolean | `true`        | Let Emacs push changes (installs the hooks listed below)                                                  |
| `socketName`     | string  | `""`          | Emacs server socket name or path; blank is the default socket                                            |
| `serverFile`     | path    | `""`          | Server file of a TCP Emacs server; blank uses the socket                                                  |
| `emacsclient`    | path    | `""`          | `emacsclient` binary; blank looks it up on `PATH`                                                         |
| `agendaFiles`    | string  | `""`          | Agenda files and directories, colon-separated; blank falls back to Emacs (see below)                     |
| `agendaKey`      | string  | `"a"`         | `org-agenda` dispatcher key opened by middle click and the Agenda button                                  |
| `emacsApp`       | string  | `"emacs"`     | Window class of Emacs, focused after opening an entry                                                     |
| `timeoutSeconds` | integer | `5`           | How long to wait for Emacs to answer (1–30)                                                               |

## Pinning the agenda files

The bar reads the first of these that is set:

1. the `agendaFiles` setting,
2. the Emacs option `omarchy-org-agenda-files`,
3. `org-agenda-files`.

Set `omarchy-org-agenda-files` if you have commands that narrow
`org-agenda-files` at runtime (a "work only" agenda, say) but want the bar
to always show everything:

```elisp
(setq omarchy-org-agenda-files '("~/org/agenda.org" "~/org/projects/"))
```

It takes the same forms as `org-agenda-files`: a list of files and
directories, or the name of a file that lists them.

## Privacy

The `Count` and `Icon` label modes keep task titles off the bar, which
helps while screen sharing. In `Icon` mode the tooltip leaves out titles
too.

## What it changes in Emacs

- It defines only functions and variables prefixed `omarchy-org-agenda-`.
- With `pushUpdates` on, it adds functions to `after-save-hook`,
  `after-revert-hook`, `org-after-todo-state-change-hook` and
  `org-agenda-finalize-hook`, and a variable watcher on
  `org-agenda-files`. Set `pushUpdates` to `false` and they are removed;
  the bar then refreshes when you open the popout (if the agenda is over
  a minute old), on right click, at midnight and after a state change.
- A state change from the popout calls `org-todo` on the heading, after
  checking it is still the entry the bar showed.
- While a note started from the bar is pending, a temporary advice on
  `org-store-log-note` saves the file once the note is stored; it
  removes itself when the note is stored or cancelled.
- `M-x unload-feature RET omarchy-org-agenda` removes everything,
  hooks and advice included.
- It never prompts. Agenda files that don't exist are skipped and
  counted in the popout's footer.

## Troubleshooting

- **"Can't reach your Emacs server"** in the popout means `emacsclient`
  found no server. Start one (see Requirements) and press Retry.
- **Custom server:** if you named your socket (`server-name`, or
  `emacs --daemon=NAME`), set `socketName`. For a TCP server
  (`server-use-tcp`), set `serverFile` to its server file.
- **Emacs busy:** if Emacs doesn't answer in time, the bar dims to show
  the agenda is stale and retries with backoff.
- **Status:** `omarchy-shell ovistoica.org-agenda status` prints the
  status, last error, item count and effective settings.
- **Logs:** `journalctl --user -b -t omarchy-shell` (lines are prefixed
  `org-agenda:`).

## Development

```sh
tests/run.sh             # ERT in emacs --batch -Q with an isolated HOME, then the Model.js node tests
tests/check-manifest.sh  # manifest, settings schema and plugin-folder checks
```

Dev loop:

1. Symlink the repo into the plugins directory:
   `ln -s "$PWD" ~/.config/omarchy/plugins/ovistoica.org-agenda`.
2. After editing QML, run `omarchy restart shell`. Hot reload doesn't
   follow symlinks. The elisp helper is reloaded into Emacs automatically
   when it changes on disk.
3. Validate against the real path, not the symlink:
   `omarchy plugin validate ~/path/to/omarchy-org-agenda`.

Security notes:

- All Org text is rendered as plain text (`PlainText.qml`). Rich and
  styled text are never used, so markup in a heading stays literal.
- The `--eval` forms sent to Emacs are built only in `Model.js`, from
  validated paths, line numbers and IDs, and keywords from the export.
- Only the popout's picker changes a state; there is no IPC command for
  it.
- `emacsclient` is always run with an argument vector, never through a
  shell.

## License

MIT; see [LICENSE](LICENSE).
