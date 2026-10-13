import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless agenda service: one per shell, shared by the bar widget on every
// monitor (bar.shell.serviceFor("ovistoica.org-agenda")). It is the only
// place that talks to Emacs. Emacs writes the agenda as JSON into the
// runtime dir — on our pull, or by itself from its save/TODO hooks — and
// the file is watched, so there is no polling: timers only run for a retry
// after a failed pull and as a watchdog while a pull is in flight.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property string omarchyPath: ""

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string elispFile: pluginDir + "/elisp/omarchy-org-agenda.el"
  readonly property string outputDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-org-agenda"
  // One file per Emacs server, so a socket change never shows another
  // server's agenda.
  readonly property string outputFile: outputDir + "/" + Model.socketKey(settings) + ".json"

  property var settings: Model.normalizeSettings({})
  property var payload: null
  property string status: "loading"
  property string detail: ""
  property int pullCount: 0
  readonly property var view: Model.view(payload, status, detail, clock.date, settings)

  // Pull bookkeeping. A trigger that lands mid-pull is coalesced into one
  // follow-up pull, so a burst of triggers costs at most two emacsclients.
  property string pendingReason: ""
  property bool pullStarted: false
  property bool pullTimedOut: false
  property int retryAttempt: 0
  property string midnightPulledFor: ""

  function errorText(e) { return String(e && e.message ? e.message : e) }

  // Widgets on every monitor call this with the same settings; only a real
  // change may cost a pull.
  function configure(raw) {
    var next = Model.normalizeSettings(raw)
    if (JSON.stringify(next) === JSON.stringify(settings)) return
    if (Model.socketKey(next) !== Model.socketKey(settings)) {
      // Another server is another agenda; don't show the old one as its.
      payload = null
      status = "loading"
      detail = ""
    }
    settings = next
    pull("settings")
  }

  function pull(reason) {
    if (puller.running) {
      pendingReason = reason
      return
    }
    var argv
    try {
      argv = Model.clientArgs(settings).concat(["--eval", Model.pullForm(elispFile, outputFile, settings, reason)])
    } catch (e) {
      status = "error"
      detail = errorText(e)
      console.warn("org-agenda: cannot build pull:", detail)
      return
    }
    console.log("org-agenda: pull " + reason)
    retry.stop()
    pullCount++
    pullStarted = false
    pullTimedOut = false
    puller.command = argv
    // Armed before starting: a failed start may be reported synchronously.
    watchdog.restart()
    puller.running = true
  }

  function failed(nextStatus, why) {
    status = nextStatus
    detail = why
    console.warn("org-agenda: pull failed (" + nextStatus + "):", why)
    scheduleRetry()
  }

  function scheduleRetry() {
    retry.interval = Model.backoffMs(retryAttempt)
    retryAttempt++
    retry.restart()
  }

  function runPending() {
    if (pendingReason === "") return
    var reason = pendingReason
    pendingReason = ""
    // Deferred: the finished Process still reports running inside its handlers.
    Qt.callLater(function() { root.pull(reason) })
  }

  function pullExited(code) {
    watchdog.stop()
    if (pullTimedOut) {
      failed(payload ? "stale" : "error", "Emacs didn't answer within " + Math.round(watchdog.interval / 1000) + "s")
    } else if (code === 0) {
      retryAttempt = 0
      agendaFile.reload()
    } else {
      var err = String(pullErr.text || "")
      failed(Model.isNoServer(err) ? "offline" : (payload ? "stale" : "error"),
             Model.bounded(err.trim() || ("emacsclient exited with code " + code), 300))
    }
    runPending()
  }

  // Quickshell's Process has no error signal: a binary that can't be
  // exec'd just drops `running` back to false without `started` or `exited`.
  function pullFailedToStart() {
    watchdog.stop()
    failed("offline", "Couldn't run " + (puller.command[0] || "emacsclient")
           + " — check the emacsclient setting")
    runPending()
  }

  function load(text) {
    var parsed = Model.parse(text)
    if (!parsed.ok) {
      status = payload ? "stale" : "error"
      detail = parsed.reason
      return
    }
    // A leftover from yesterday is not today's agenda; the pull replaces it.
    if (Model.isNewDay(parsed.value, new Date())) return
    payload = parsed.value
    // Also covers a push arriving while we thought Emacs was offline.
    status = parsed.value.error ? "error" : "ok"
    detail = parsed.value.error || ""
  }

  // The popout calls this on open, so a stale agenda is refreshed on demand.
  function ensureFresh() {
    if (Model.isOld(payload, new Date())) pull("open")
  }

  function focusEmacs() {
    Quickshell.execDetached(["omarchy-hyprland-focus-app", settings.emacsApp])
  }

  function launch(form, fallback) {
    if (opener.running || fallbackOpener.running) {
      console.warn("org-agenda: an open is already in progress")
      return
    }
    opener.fallback = fallback
    opener.command = Model.clientArgs(settings).concat(["-r", "-n", "--eval", form])
    opener.running = true
  }

  function open(item) {
    try {
      launch(Model.gotoForm(item, payload, elispFile), Model.fallbackOpenArgs(settings, item, payload))
    } catch (e) {
      console.warn("org-agenda: cannot open item:", errorText(e))
    }
  }

  function openAgenda() {
    try {
      launch(Model.agendaForm(settings.agendaKey, elispFile), null)
    } catch (e) {
      console.warn("org-agenda: cannot open agenda:", errorText(e))
    }
  }

  Process {
    id: puller
    stderr: StdioCollector { id: pullErr }
    onStarted: root.pullStarted = true
    onExited: function(exitCode, exitStatus) { root.pullExited(exitCode) }
    onRunningChanged: if (!running && !root.pullStarted) root.pullFailedToStart()
  }

  // emacsclient -w only bounds the connect; an eval that hangs in Emacs
  // would block the pull forever.
  Timer {
    id: watchdog
    interval: (root.settings.timeoutSeconds + 2) * 1000
    repeat: false
    onTriggered: {
      if (!puller.running) return
      root.pullTimedOut = true
      puller.signal(15)
    }
  }

  Timer {
    id: retry
    repeat: false
    onTriggered: root.pull("retry")
  }

  // Emacs writes <file>.tmp and renames it over <file>; FileView keeps
  // watching the path across the rename (verified live).
  FileView {
    id: agendaFile
    path: root.outputFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.load(text())
  }

  // A clock, not a poll: the view's "next"/"now" follows the minute, and
  // Emacs is only asked again when the date rolls over.
  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      var day = Qt.formatDate(date, "yyyy-MM-dd")
      if (Model.isNewDay(root.payload, date) && root.midnightPulledFor !== day) {
        root.midnightPulledFor = day
        root.pull("midnight")
      }
    }
  }

  Process {
    id: opener
    property var fallback: null
    stderr: StdioCollector { id: openErr }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) {
        root.focusEmacs()
      } else if (fallback) {
        console.warn("org-agenda: goto failed, opening the file instead:", Model.bounded(String(openErr.text || "").trim(), 200))
        fallbackOpener.command = fallback
        fallbackOpener.running = true
      } else {
        console.warn("org-agenda: open failed:", Model.bounded(String(openErr.text || "").trim(), 200))
      }
    }
  }

  Process {
    id: fallbackOpener
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) root.focusEmacs()
      else console.warn("org-agenda: fallback open exited with code", exitCode)
    }
  }

  IpcHandler {
    target: "ovistoica.org-agenda"

    function refresh(): void { root.pull("ipc") }
    function status(): string {
      return JSON.stringify({
        status: root.status,
        detail: root.detail,
        pullCount: root.pullCount,
        items: root.view.items.length,
        generatedAt: root.payload ? root.payload.generatedAt : "",
        reason: root.payload ? root.payload.reason : "",
        outputFile: root.outputFile,
        settings: root.settings
      })
    }
  }

  Component.onCompleted: pull("start")
}
