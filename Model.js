// Pure logic for the Org agenda bar widget: parsing server.json, sections,
// "next up", bar label/tooltip text and the emacsclient argv / elisp forms.
// Loaded by QML (`import "Model.js" as Model`) and by node in tests, so: no
// modules, no DOM/Intl, no clock reads — callers pass `now` in.
// Kept to syntax the Qt 6 V4 engine is sure to handle (no object spread,
// no padStart / Object.entries / Object.fromEntries).

const PROTOCOL = 1
const MAX_ITEMS = 200
const MAX_TITLE = 200
const ID_RE = /^[A-Za-z0-9._:-]{1,128}$/
const NOW_GRACE_MIN = 30
const STALE_AFTER_MS = 60000
const MAX_IN_DAYS = 3660
// Weeks `omarchy-org-agenda-week' reaches either way; a week's first day
// is within MAX_START_DAYS of today.
const MAX_WEEK_OFFSET = 52
const MAX_START_DAYS = 400

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/
const TIME_RE = /^\d{2}:\d{2}$/
const COLOR_RE = /^#[0-9A-Fa-f]{6}$/
const CONTROL_RE = /[\u0000-\u001f\u007f]/
const CONTROL_RE_G = /[\u0000-\u001f\u007f]/g
const REASON_RE = /^[a-z-]{1,20}$/
const KEY_RE = /^[A-Za-z0-9]{1,4}$/
const FAST_KEY_RE = /^[A-Za-z0-9]$/
// A TODO keyword safe to put in an elisp form and a label: no whitespace,
// quotes, parens, backslashes or control chars.
const KEYWORD_RE = /^[^\s"'`()\[\]\\\u0000-\u001f\u007f]{1,32}$/
const STATE_RESULTS = ["done", "note", "note-frame", "blocked", "changed", "conflict",
                       "busy", "invalid", "error"]
// What the clock and pomodoro actions answer.
const ACTION_RESULTS = ["done", "note", "note-frame", "changed", "conflict", "busy", "invalid",
                        "error", "not-clocking", "needs-emacs", "unavailable", "confirm"]
// Epoch seconds before year 5000: a value in ms is refused, not shown as
// a clock running for millennia.
const MAX_EPOCH = 1e11
// org-pomodoro's running phases, as the strip and the bar show them.
const PHASES = {
  pomodoro: { caption: "POMODORO", glyph: "●", tone: "urgent" },
  overtime: { caption: "OVERTIME", glyph: "●", tone: "urgent" },
  "short-break": { caption: "SHORT BREAK", glyph: "◌", tone: "accent" },
  "long-break": { caption: "LONG BREAK", glyph: "◌", tone: "accent" }
}
const POMODORO_STATES = ["none", "pomodoro", "overtime", "short-break", "long-break"]
const CLOCK_GLYPH = "◷"
// Footer hints whose buttons' tooltips name the key, dropped in this
// order when the timer hints need the room.
const HINT_DROPS = ["r refresh", "v layout", "f b week"]
const MAX_HINT = 80
const MAX_DETAIL = 200
const ITEM_TYPES = ["scheduled", "past-scheduled", "deadline", "upcoming-deadline",
                    "timestamp", "sexp", "block"]
const LABELS = ["Next item", "Count", "Icon"]
const STATUSES = ["loading", "ok", "offline", "error", "stale"]
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const WEEKDAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August",
                     "September", "October", "November", "December"]
// The popout's layouts, in `v' order, and the Tabs layout's tabs.
const LAYOUTS = ["Org", "Tabs", "Columns"]
const TABS = ["today", "week", "overdue"]
// Width of Org's %-12:c category and %?-12t time/leader columns.
const ORG_CELL = 12
const NOW_LINE = "now - - - - - - - - - - - - - - - - - - - - - - - - -"
const SECTION_ORDER = [
  { key: "schedule", cls: "schedule", title: "Schedule" },
  { key: "today", cls: "today", title: "Today" },
  { key: "habits", cls: "habit", title: "Habits" },
  { key: "upcoming", cls: "upcoming", title: "Coming up" },
  { key: "overdue", cls: "overdue", title: "Overdue" }
]

// ---------------------------------------------------------------- helpers

function isObj(v) { return v !== null && typeof v === "object" && !Array.isArray(v) }
function isStr(v) { return typeof v === "string" }
function hasOwn(o, k) { return Object.prototype.hasOwnProperty.call(o, k) }
function pad2(n) { return (n < 10 ? "0" : "") + n }
function clamp(n, lo, hi) { return Math.min(hi, Math.max(lo, n)) }
function hhmm(min) { return pad2(Math.floor(min / 60)) + ":" + pad2(min % 60) }

// String with no control chars and at most `max` UTF-16 units, else null.
function cleanStr(v, max) {
  return isStr(v) && v.length <= max && !CONTROL_RE.test(v) ? v : null
}

// Array of clean strings, at most `count` of them.
function strList(v, count, max) {
  return Array.isArray(v)
    ? v.slice(0, count * 4).filter(s => cleanStr(s, max) !== null).slice(0, count)
    : []
}

function bounded(s, n) {
  const chars = Array.from(String(s == null ? "" : s))
  return chars.length <= n ? chars.join("") : chars.slice(0, Math.max(0, n - 1)).join("") + "…"
}

// Bounded free text, "" when absent or not a string.
function text(v, n) { return isStr(v) ? bounded(v.replace(CONTROL_RE_G, " "), n) : "" }

function nonNegInt(v) { return Number.isSafeInteger(v) && v >= 0 }
function intIn(v, lo, hi) { return Number.isSafeInteger(v) && v >= lo && v <= hi }

// ---------------------------------------------------------------- parsing

function isAbsPath(v) { return cleanStr(v, 4096) !== null && v.charAt(0) === "/" }

function normalizeItem(raw) {
  if (!isObj(raw) || !isAbsPath(raw.path) || !Number.isSafeInteger(raw.line) || raw.line < 1)
    return null
  return {
    id: isStr(raw.id) && ID_RE.test(raw.id) ? raw.id : null,
    path: raw.path,
    line: raw.line,
    type: ITEM_TYPES.indexOf(raw.type) >= 0 ? raw.type : "other",
    todo: cleanStr(raw.todo, 32),
    done: raw.done === true,
    title: text(raw.title, MAX_TITLE),
    priority: isStr(raw.priority) && Array.from(raw.priority).length === 1
      && !CONTROL_RE.test(raw.priority) ? raw.priority : null,
    category: cleanStr(raw.category, 60),
    tags: strList(raw.tags, 20, 40),
    time: isStr(raw.time) && TIME_RE.test(raw.time) ? raw.time : null,
    durationMin: nonNegInt(raw.durationMin) ? raw.durationMin : null,
    overdueDays: nonNegInt(raw.overdueDays) ? raw.overdueDays : 0,
    // Days until a later day's scheduled task or an upcoming deadline;
    // older payloads have none. Negative only in a past week's payload.
    inDays: intIn(raw.inDays, -MAX_IN_DAYS, MAX_IN_DAYS) ? raw.inDays : 0,
    habit: raw.habit === true
  }
}

function normalizeColors(raw) {
  const out = {}
  if (!isObj(raw)) return out
  Object.keys(raw).slice(0, 100)
    .filter(k => k !== "__proto__" && cleanStr(k, 32) !== null
                 && isStr(raw[k]) && COLOR_RE.test(raw[k]))
    .slice(0, 50)
    .forEach(k => { out[k] = raw[k] })
  return out
}

// keyword → its one-char fast-selection key; payloads before v0.2 have none.
function normalizeKeys(raw) {
  const out = {}
  if (!isObj(raw)) return out
  Object.keys(raw).slice(0, 100)
    .filter(k => k !== "__proto__" && cleanStr(k, 32) !== null
                 && isStr(raw[k]) && FAST_KEY_RE.test(raw[k]))
    .slice(0, 50)
    .forEach(k => { out[k] = raw[k] })
  return out
}

function normalizeKeywords(raw) {
  const kw = isObj(raw) ? raw : {}
  return { todo: strList(kw.todo, 50, 32), done: strList(kw.done, 50, 32),
           colors: normalizeColors(kw.colors), keys: normalizeKeys(kw.keys) }
}

function isEpoch(v) { return Number.isSafeInteger(v) && v > 0 && v < MAX_EPOCH }

// The running Org clock, or null. Its path and line are its row's.
function normalizeClock(raw) {
  if (!isObj(raw) || !isEpoch(raw.startedAt)) return null
  const path = isAbsPath(raw.path) ? raw.path : null
  return {
    title: text(raw.title, MAX_TITLE),
    category: cleanStr(raw.category, 60),
    path: path,
    line: path !== null && Number.isSafeInteger(raw.line) && raw.line >= 1 ? raw.line : null,
    startedAt: raw.startedAt,
    baseMin: nonNegInt(raw.baseMin) ? raw.baseMin : 0,
    effortMin: Number.isSafeInteger(raw.effortMin) && raw.effortMin > 0 ? raw.effortMin : null
  }
}

// org-pomodoro's state; payloads before v0.4 have none: unavailable.
function normalizePomodoro(raw) {
  const r = isObj(raw) ? raw : {}
  const state = POMODORO_STATES.indexOf(r.state) >= 0 ? r.state : "none"
  return {
    available: r.available === true,
    state: state,
    endsAt: state !== "none" && isEpoch(r.endsAt) ? r.endsAt : null,
    phaseMin: typeof r.phaseMin === "number" && isFinite(r.phaseMin) && r.phaseMin > 0 ? r.phaseMin : null,
    count: nonNegInt(r.count) ? r.count : 0,
    askKill: r.askKill !== false
  }
}

function normalizePayload(raw) {
  if (!isObj(raw)) return { ok: false, reason: "not an object" }
  if (raw.version !== PROTOCOL) return { ok: false, reason: "unsupported version" }
  if (!isStr(raw.date) || !DATE_RE.test(raw.date)) return { ok: false, reason: "bad date" }
  const items = Array.isArray(raw.items)
    ? raw.items.slice(0, MAX_ITEMS).map(normalizeItem).filter(i => i !== null)
    : []
  return {
    ok: true,
    value: {
      version: PROTOCOL,
      date: raw.date,
      generatedAt: text(raw.generatedAt, 40),
      reason: text(raw.reason, 40),
      emacs: text(raw.emacs, 40),
      org: text(raw.org, 40),
      keywords: normalizeKeywords(raw.keywords),
      items: items,
      // Later days of the Org week the export covers; older payloads have none.
      daysAhead: nonNegInt(raw.daysAhead) ? Math.min(raw.daysAhead, 31) : 0,
      error: isStr(raw.error) ? text(raw.error, 300) : null,
      missing: Array.isArray(raw.missing)
        ? raw.missing.slice(0, 50).filter(isStr).map(s => text(s, 1024))
        : [],
      // Which week an `omarchy-org-agenda-week' payload is; null in the
      // bar's file.
      weekOffset: intIn(raw.weekOffset, -MAX_WEEK_OFFSET, MAX_WEEK_OFFSET) ? raw.weekOffset : null,
      weekStart: isStr(raw.weekStart) && DATE_RE.test(raw.weekStart) ? raw.weekStart : null,
      startInDays: intIn(raw.startInDays, -MAX_START_DAYS, MAX_START_DAYS) ? raw.startInDays : null,
      // The timers: only the bar's file has them (parseWeekResult drops them).
      clock: normalizeClock(raw.clock),
      pomodoro: normalizePomodoro(raw.pomodoro)
    }
  }
}

function parse(textIn) {
  try {
    if (!isStr(textIn)) return { ok: false, reason: "not text" }
    return normalizePayload(JSON.parse(textIn))
  } catch (e) {
    return { ok: false, reason: "invalid JSON" }
  }
}

// ---------------------------------------------------------------- classification

// A later day's task comes before overdue: Org may date a repeat by its
// past base date.
function classify(item) {
  if (item.habit) return "habit"
  if (item.inDays > 0 || item.type === "upcoming-deadline") return "upcoming"
  if (item.overdueDays > 0) return "overdue"
  if (item.time) return "schedule"
  return "today"
}

// Soonest first, ties in Org's order: V4's sort may not be stable.
function byInDays(items) {
  return items
    .map((item, i) => ({ item: item, i: i }))
    .sort((a, b) => (a.item.inDays - b.item.inDays) || (a.i - b.i))
    .map(e => e.item)
}

function sections(items, settings) {
  const s = normalizeSettings(settings)
  const shown = (items || []).filter(i => s.showDone || !i.done)
  return SECTION_ORDER
    .map(sec => {
      const its = shown.filter(i => classify(i) === sec.cls)
      return { key: sec.key, title: sec.title, items: sec.key === "upcoming" ? byInDays(its) : its }
    })
    .filter(sec => sec.items.length > 0)
}

function countOpen(items, classes) {
  return (items || []).filter(i => !i.done && classes.indexOf(classify(i)) >= 0).length
}

function openToday(items) { return countOpen(items, ["schedule", "today"]) }

function habitCount(items) { return countOpen(items, ["habit"]) }

function overdueCount(items, settings) {
  const withHabits = !!settings && settings.habitsInBadge === true
  return (items || []).filter(i => !i.done && i.overdueDays > 0 && !(i.inDays > 0)
                                   && (withHabits || !i.habit)).length
}

function minutesOf(hm) {
  const m = isStr(hm) && /^(\d{2}):(\d{2})$/.exec(hm)
  if (!m) return -1
  const h = Number(m[1]), mi = Number(m[2])
  return h < 24 && mi < 60 ? h * 60 + mi : -1
}

function nowMinutes(now) {
  return now instanceof Date && !isNaN(now.getTime()) ? now.getHours() * 60 + now.getMinutes() : NaN
}

function nextUp(items, now) {
  const nowMin = nowMinutes(now)
  const best = (items || [])
    .filter(i => !i.done && classify(i) === "schedule" && minutesOf(i.time) >= 0)
    .map(i => {
      const startMin = minutesOf(i.time)
      return { item: i, startMin: startMin,
               endMin: startMin + (i.durationMin > 0 ? i.durationMin : NOW_GRACE_MIN) }
    })
    .filter(c => c.endMin > nowMin)
    .reduce((acc, c) => (acc === null || c.startMin < acc.startMin ? c : acc), null)
  return best === null ? null
    : { item: best.item, state: best.startMin <= nowMin ? "now" : "next",
        startMin: best.startMin, endMin: best.endMin }
}

// ---------------------------------------------------------------- settings

function settingStr(v, dflt) {
  const s = isStr(v) ? v.trim() : ""
  return s === "" ? dflt : s
}

function settingInt(v, dflt, lo, hi) {
  const n = (typeof v === "number" || (isStr(v) && v.trim() !== "")) ? Number(v) : NaN
  return isFinite(n) ? clamp(Math.round(n), lo, hi) : dflt
}

function normalizeSettings(raw) {
  const r = isObj(raw) ? raw : {}
  const label = settingStr(r.label, "Next item")
  const layout = settingStr(r.layout, "Org")
  return {
    label: LABELS.indexOf(label) >= 0 ? label : "Next item",
    layout: LAYOUTS.indexOf(layout) >= 0 ? layout : "Org",
    maxTitleChars: settingInt(r.maxTitleChars, 28, 10, 80),
    overdueBadge: r.overdueBadge !== false,
    habitsInBadge: r.habitsInBadge === true,
    showDone: r.showDone !== false,
    pushUpdates: r.pushUpdates !== false,
    socketName: settingStr(r.socketName, ""),
    serverFile: settingStr(r.serverFile, ""),
    emacsclient: settingStr(r.emacsclient, ""),
    agendaFiles: settingStr(r.agendaFiles, ""),
    agendaKey: settingStr(r.agendaKey, "a"),
    emacsApp: settingStr(r.emacsApp, "emacs"),
    timeoutSeconds: settingInt(r.timeoutSeconds, 5, 1, 30)
  }
}

// ---------------------------------------------------------------- timers

// 83 → "1:23", as Org's mode line shows a clock.
function hMm(min) { return Math.floor(min / 60) + ":" + pad2(min % 60) }

// 761 → "12:41"; the minutes may pass 59.
function mSs(sec) { return Math.floor(sec / 60) + ":" + pad2(sec % 60) }

function nowMsOf(now) {
  return now instanceof Date ? now.getTime() : typeof now === "number" ? now : NaN
}

// One timerState value, its fields in a fixed order.
function timerOf(kind, caption, title, time, extra, progress, look, clockKey, barTime) {
  return { kind: kind, caption: caption, title: title, time: time, extra: extra, progress: progress,
           tone: look.tone, glyph: look.glyph, clockKey: clockKey, barTime: barTime }
}

function clockKeyOf(clock) {
  return clock && clock.path !== null && clock.line !== null ? clock.path + ":" + clock.line : ""
}

// Org's clocked time: the earlier minutes plus whole minutes since start.
// Past the effort the time turns urgent, as Org's overrun face does.
function clockTimer(clock, nowMs) {
  const minutes = clock.baseMin + Math.max(0, Math.floor((nowMs - clock.startedAt * 1000) / 60000))
  const effort = clock.effortMin
  const time = hMm(minutes)
  return timerOf("clock", "CLOCKED IN", clock.title,
                 { text: time, tone: effort !== null && minutes > effort ? "urgent" : "normal" },
                 effort !== null ? " / " + hMm(effort) + " effort" : "",
                 effort !== null ? Math.min(1, minutes / effort) : null,
                 { tone: "accent", glyph: CLOCK_GLYPH }, clockKeyOf(clock), time)
}

// A pomodoro or a break counts down to endsAt; overtime counts up from it.
function phaseTimer(pom, clock, nowMs, seconds) {
  const ph = PHASES[pom.state]
  const nowSec = nowMs / 1000
  const title = clock ? clock.title : ""
  const caption = pom.state === "pomodoro"
    ? ph.caption + " " + ((nonNegInt(pom.count) ? pom.count : 0) + 1) : ph.caption
  if (pom.state === "overtime") {
    const over = Math.max(0, nowSec - pom.endsAt)
    const short = "+" + Math.ceil(over / 60) + "m"
    return timerOf(pom.state, caption, title,
                   { text: seconds ? "+" + mSs(Math.floor(over)) : short, tone: "urgent" },
                   " over", 1, ph, clockKeyOf(clock), short)
  }
  const left = Math.max(0, pom.endsAt - nowSec)
  const short = Math.ceil(left / 60) + "m"
  const phaseSec = pom.phaseMin === null ? 0 : pom.phaseMin * 60
  return timerOf(pom.state, caption, title, { text: seconds ? mSs(Math.ceil(left)) : short, tone: "normal" },
                 " left", phaseSec > 0 ? clamp((phaseSec - left) / phaseSec, 0, 1) : null,
                 ph, clockKeyOf(clock), short)
}

// What runs, display-ready, or null: nothing runs, or Emacs isn't
// reachable (`status' not ok) so the clock may be stale. A pomodoro
// phase wins over the clock and takes its title. `now' is a Date or ms;
// `seconds' gives a running phase M:SS instead of whole minutes.
//   {kind, caption, title, time: {text, tone}, extra, progress, tone,
//    glyph, clockKey, barTime}
function timerState(view, now, seconds) {
  const v = isObj(view) ? view : {}
  const nowMs = nowMsOf(now)
  if (v.status !== "ok" || !isObj(v.payload) || !isFinite(nowMs)) return null
  const clock = isObj(v.payload.clock) && isEpoch(v.payload.clock.startedAt) ? v.payload.clock : null
  const pom = v.payload.pomodoro
  // A phase without its end time can't be shown; the clock still can.
  const running = isObj(pom) && hasOwn(PHASES, pom.state) && isEpoch(pom.endsAt)
  return running ? phaseTimer(pom, clock, nowMs, seconds === true)
    : clock ? clockTimer(clock, nowMs)
    : null
}

function isBreak(timer) { return timer.kind === "short-break" || timer.kind === "long-break" }

// "Clocked in: Title · 0:23 / 1:00", "Pomodoro 3: Title · 13m left",
// "Overtime · +4m". `withTitle': the label mode lets titles show.
function timerLine(view, withTitle) {
  const t = view.timer
  const name = t.caption.charAt(0) + t.caption.slice(1).toLowerCase()
  const clock = view.payload && view.payload.clock
  const effort = t.kind === "clock" && isObj(clock) && clock.effortMin ? " / " + hMm(clock.effortMin) : ""
  const tail = t.kind === "clock" ? effort : t.kind === "overtime" ? "" : t.extra
  return name + (withTitle && t.title ? ": " + t.title : "") + " · " + t.time.text + tail
}

// ---------------------------------------------------------------- bar text

function hasError(view) { return view.status === "error" || (!!view.payload && view.payload.error !== null && view.payload.error !== undefined) }

// {mode, text, badge, alert, timer}. While a timer runs, `timer' is
// {glyph, time, tone}: Next item shows it before the clock's title
// (mode "timer"); Count shows it instead of the count, and Count and Icon
// keep titles off the bar.
function barLabel(view) {
  const blank = mode => ({ mode: mode, text: "", badge: 0, alert: false, timer: null })
  if (view.status === "offline") return blank("offline")
  if (hasError(view)) return blank("error")
  if (!view.payload) return blank("loading")
  const s = view.settings
  const alert = view.overdue > 0
  const badge = s.overdueBadge ? view.overdue : 0
  const t = isObj(view.timer) ? view.timer : null
  // An overrun clock is urgent on the bar too.
  const timer = t ? { glyph: t.glyph, time: t.barTime, tone: t.time.tone === "urgent" ? "urgent" : t.tone } : null
  const label = (mode, txt) => ({ mode: mode, text: txt, badge: badge, alert: alert, timer: timer })
  if (s.label === "Icon") return { mode: "icon", text: "", badge: 0, alert: alert, timer: timer }
  if (s.label === "Count") return label("count", t ? "" : String(view.openToday))
  if (t) return label("timer", t.title ? bounded(t.title, s.maxTitleChars) : isBreak(t) ? "break" : "")
  const next = view.next
  if (next && next.state === "now") return label("now", "now " + bounded(next.item.title, s.maxTitleChars))
  if (next) return label("next", next.item.time + " " + bounded(next.item.title, s.maxTitleChars))
  if (view.openToday > 0) return label("today", view.openToday + " today")
  if (view.overdue > 0) return label("icon", "")
  return label("clear", "")
}

function relTime(deltaMin) {
  const d = Math.round(deltaMin)
  if (!(d > 0)) return "now"
  if (d < 60) return "in " + d + " min"
  const h = Math.floor(d / 60), m = d % 60
  return "in " + h + " h" + (m ? " " + m + " min" : "")
}

function plain(s) {
  return String(s == null ? "" : s)
    .replace(/</g, "‹").replace(/>/g, "›")
    .replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, " ")
}

function nextLine(next, nowMin, withTitle) {
  const title = withTitle ? " " + next.item.title : ""
  return next.state === "now"
    ? "Now" + title + " · until " + hhmm(next.endMin % 1440)
    : "Next " + next.item.time + title + " · " + relTime(next.startMin - nowMin)
}

function missingLine(payload) {
  const n = payload && payload.missing ? payload.missing.length : 0
  return n > 0 ? ["Missing: " + n + " agenda file(s)"] : []
}

function tooltipLines(view) {
  if (view.status === "offline")
    return ["Emacs not reachable"].concat(view.detail ? [view.detail] : [])
  if (hasError(view)) {
    const msg = (view.payload && view.payload.error) || view.detail || "unknown error"
    return ["Agenda export failed: " + bounded(msg, 300)].concat(missingLine(view.payload))
  }
  if (!view.payload) return ["Loading agenda…"]
  const updated = view.updated
    ? ["Updated " + view.updated + " from Emacs" + (view.stale ? " · stale" : "")]
    : (view.stale ? ["Stale"] : [])
  const withTitles = view.settings.label !== "Icon"
  return (isObj(view.timer) ? [timerLine(view, withTitles)] : [])
    .concat(view.next ? [nextLine(view.next, view.nowMin, withTitles)] : [])
    .concat(["Today " + view.openToday + " · Habits " + habitCount(view.items)
             + " · Overdue " + view.overdue])
    .concat(updated)
    .concat(missingLine(view.payload))
}

function tooltip(view) { return tooltipLines(view).map(plain).join("\n") }

// ---------------------------------------------------------------- emacsclient

function elispString(s) {
  if (!isStr(s)) throw new Error("elispString: not a string")
  if (CONTROL_RE.test(s)) throw new Error("elispString: control character")
  return "\"" + s.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""
}

function clientArgs(settings) {
  const s = normalizeSettings(settings)
  const socket = s.serverFile ? ["-f", s.serverFile] : s.socketName ? ["-s", s.socketName] : []
  return [s.emacsclient || "emacsclient"].concat(socket, ["-w", String(s.timeoutSeconds)])
}

// The agenda file's directory, private to the user: the runtime dir, else
// the cache dir, never a shared /tmp. "" when there is none. As the XDG
// spec says, a relative value is ignored like an unset one.
function outputDir(runtimeDir, cacheHome, home) {
  const strip = p => p.replace(/\/+$/, "")
  const base = isAbsPath(runtimeDir) ? strip(runtimeDir)
    : isAbsPath(cacheHome) ? strip(cacheHome)
    : isAbsPath(home) ? strip(home) + "/.cache"
    : null
  return base === null ? "" : base + "/omarchy-org-agenda"
}

function sanitizeKey(s) { return s.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80) }

function socketKey(settings) {
  const s = normalizeSettings(settings)
  return s.serverFile ? "f-" + sanitizeKey(s.serverFile)
    : s.socketName ? "s-" + sanitizeKey(s.socketName)
    : "server"
}

function agendaFilesList(settings) {
  return normalizeSettings(settings).agendaFiles.split(":")
    .map(f => f.trim())
    .filter(f => cleanStr(f, 1024) !== null && f !== "")
    .slice(0, 50)
}

// Changes only with what a pull sends to Emacs, so a UI-only setting such
// as the layout never costs one.
function pullKey(settings) {
  const s = normalizeSettings(settings)
  return JSON.stringify([clientArgs(s), agendaFilesList(s), s.pushUpdates, socketKey(s)])
}

function filesForm(list) {
  return list && list.length ? "(list " + list.map(elispString).join(" ") + ")" : "nil"
}

function requireAbs(p, what) {
  if (!isAbsPath(p)) throw new Error(what + " must be an absolute path")
  return p
}

function loadPreamble(elispFile) {
  const file = elispString(requireAbs(elispFile, "elisp file"))
  return "(unless (and (boundp 'omarchy-org-agenda--source-mtime)" +
    " (equal omarchy-org-agenda--source-mtime" +
    " (file-attribute-modification-time (file-attributes " + file + "))))" +
    " (load " + file + " nil t))"
}

function pullForm(elispFile, outputFile, settings, reason) {
  const s = normalizeSettings(settings)
  const out = elispString(requireAbs(outputFile, "output file"))
  const why = isStr(reason) && REASON_RE.test(reason) ? reason : "pull"
  return "(progn " + loadPreamble(elispFile) +
    " (omarchy-org-agenda-ensure " + out + " " + filesForm(agendaFilesList(s)) + " " +
    (s.pushUpdates ? "t" : "nil") + ")" +
    " (omarchy-org-agenda-export " + elispString(why) + "))"
}

// Another Org week, `offset` weeks from this one, fetched on demand. The
// ensure keeps Emacs's file list the bar's, even after a shell restart.
function weekForm(elispFile, outputFile, settings, offset) {
  if (!Number.isSafeInteger(offset)) throw new Error("week offset must be an integer")
  const s = normalizeSettings(settings)
  const out = elispString(requireAbs(outputFile, "output file"))
  return "(progn " + loadPreamble(elispFile) +
    " (omarchy-org-agenda-ensure " + out + " " + filesForm(agendaFilesList(s)) + " " +
    (s.pushUpdates ? "t" : "nil") + ")" +
    " (omarchy-org-agenda-week " + clamp(offset, -MAX_WEEK_OFFSET, MAX_WEEK_OFFSET) + "))"
}

function hasItem(payload, item) {
  return isObj(item) && Number.isSafeInteger(item.line) && item.line > 0 && isAbsPath(item.path)
    && isObj(payload) && Array.isArray(payload.items)
    && payload.items.some(i => isObj(i) && i.path === item.path && i.line === item.line)
}

// The UI may only jump to a location Emacs itself reported.
function knownItem(item, payload) {
  if (!hasItem(payload, item)) throw new Error("item is not in the agenda payload")
  return item
}

// The first of `payloads` (the bar's, then a fetched week's) that reported
// `item`, or null: what gotoForm and stateForm check it against.
function payloadFor(item, payloads) {
  return (Array.isArray(payloads) ? payloads : []).filter(p => hasItem(p, item))[0] || null
}

function gotoForm(item, payload, elispFile) {
  const it = knownItem(item, payload)
  const id = isStr(it.id) && ID_RE.test(it.id) ? elispString(it.id) : "nil"
  return "(progn " + loadPreamble(elispFile) +
    " (omarchy-org-agenda-goto " + elispString(it.path) + " " + it.line + " " + id + "))"
}

function agendaForm(key, elispFile) {
  const k = isStr(key) && KEY_RE.test(key) ? key : "a"
  return "(progn " + loadPreamble(elispFile) +
    " (omarchy-org-agenda-open-agenda " + elispString(k) + "))"
}

function fallbackOpenArgs(settings, item, payload) {
  const it = knownItem(item, payload)
  return clientArgs(settings).concat(["-r", "-n", "+" + it.line, it.path])
}

// J's fallback: the clocked entry's file at its line, as fallbackOpenArgs
// opens a row; null when the clock reported no place (or none runs).
function clockFallbackArgs(settings, payload) {
  const c = isObj(payload) && isObj(payload.clock) ? payload.clock : null
  return c && isAbsPath(c.path) && Number.isSafeInteger(c.line) && c.line > 0
    ? clientArgs(settings).concat(["-r", "-n", "+" + c.line, c.path]) : null
}

// ---------------------------------------------------------------- state change

function isKeyword(k) { return isStr(k) && KEYWORD_RE.test(k) }

// The keywords the picker offers: todo then done, in declaration order.
function stateChoices(payload) {
  const kw = isObj(payload) && isObj(payload.keywords) ? payload.keywords : {}
  const keys = isObj(kw.keys) ? kw.keys : {}
  const keyOf = k => hasOwn(keys, k) && isStr(keys[k]) && FAST_KEY_RE.test(keys[k]) ? keys[k] : ""
  const list = (arr, done) => (Array.isArray(arr) ? arr : [])
    .filter(isKeyword)
    .map(k => ({ keyword: k, key: keyOf(k), color: keywordColor(payload, k), done: done }))
  const all = list(kw.todo, false).concat(list(kw.done, true))
  return all.filter((c, i) => all.findIndex(d => d.keyword === c.keyword) === i)
}

// A diary sexp has no TODO heading of its own to change.
function canChangeState(item) {
  return isObj(item) && item.type !== "sexp" && isAbsPath(item.path)
    && Number.isSafeInteger(item.line) && item.line > 0
}

function keywordForm(k, choices) {
  if (!isKeyword(k) || choices.indexOf(k) < 0) throw new Error("not one of the agenda's keywords")
  return elispString(k)
}

function stateForm(item, payload, toKeyword, elispFile) {
  const it = knownItem(item, payload)
  if (!canChangeState(it)) throw new Error("this entry has no TODO state to change")
  const choices = stateChoices(payload).map(c => c.keyword)
  const to = keywordForm(toKeyword, choices)
  const from = it.todo === null || it.todo === undefined ? "nil" : keywordForm(it.todo, choices)
  const id = isStr(it.id) && ID_RE.test(it.id) ? elispString(it.id) : "nil"
  return "(progn " + loadPreamble(elispFile) +
    " (omarchy-org-agenda-set-state " + elispString(it.path) + " " + it.line + " " +
    id + " " + from + " " + to + "))"
}

function takeNoteForm(elispFile) {
  return "(progn " + loadPreamble(elispFile) + " (omarchy-org-agenda-take-note))"
}

// PATH LINE ID FROM for an entry's clock-in, checked as stateForm checks
// it: Emacs reported it, it has a heading, and its keyword is known.
function entryArgs(item, payload) {
  const it = knownItem(item, payload)
  if (!canChangeState(it)) throw new Error("this entry has no heading to clock")
  const from = it.todo === null || it.todo === undefined ? "nil"
    : keywordForm(it.todo, stateChoices(payload).map(c => c.keyword))
  const id = isStr(it.id) && ID_RE.test(it.id) ? elispString(it.id) : "nil"
  return elispString(it.path) + " " + it.line + " " + id + " " + from
}

function actionForm(name, args, elispFile) {
  return "(progn " + loadPreamble(elispFile) + " (omarchy-org-agenda-" + name + (args ? " " + args : "") + "))"
}

function clockInForm(item, payload, elispFile) { return actionForm("clock-in", entryArgs(item, payload), elispFile) }
function clockOutForm(elispFile) { return actionForm("clock-out", "", elispFile) }
function clockCancelForm(elispFile) { return actionForm("clock-cancel", "", elispFile) }
function clockGotoForm(elispFile) { return actionForm("clock-goto", "", elispFile) }

// P: start on `item', or (item null) finish overtime / stop; `confirm'
// answers org-pomodoro's "stop it?" question.
function pomodoroForm(item, payload, confirm, elispFile) {
  const entry = item === null || item === undefined ? "nil nil nil nil" : entryArgs(item, payload)
  return actionForm("pomodoro", entry + " " + (confirm === true ? "t" : "nil"), elispFile)
}

// The contents of a string as `emacsclient --eval' prints it (prin1:
// quoted, with \" and \\ escaped), or null.  The helper's JSON is ASCII,
// but raw non-ASCII passes through too.
function elispStringValue(s) {
  const t = String(s == null ? "" : s).trim()
  if (t.length < 2 || t.charAt(0) !== "\"" || t.charAt(t.length - 1) !== "\"") return null
  let out = ""
  for (let i = 1; i < t.length - 1; i++) {
    const c = t.charAt(i)
    if (c === "\"") return null
    if (c !== "\\") { out += c; continue }
    if (++i >= t.length - 1) return null
    const n = t.charAt(i)
    if (n === "\\" || n === "\"") out += n
    else if (n === "n") out += "\n"
    else if (n === "t") out += "\t"
    else if (n !== "\n") return null
  }
  return out
}

// {result, state, saved, detail} as an action printed it, `result' one of
// `results'.
function parseResult(stdout, results) {
  const s = String(stdout == null ? "" : stdout).trim()
  const json = s.charAt(0) === "{" ? s : elispStringValue(s)
  if (json === null) return { ok: false, reason: "not an elisp string" }
  let raw
  try { raw = JSON.parse(json) } catch (e) { return { ok: false, reason: "invalid JSON" } }
  if (!isObj(raw) || results.indexOf(raw.result) < 0)
    return { ok: false, reason: "unknown result" }
  const detail = isStr(raw.detail) ? text(raw.detail, MAX_DETAIL) : ""
  return { ok: true, value: {
    result: raw.result,
    state: isKeyword(raw.state) ? raw.state : null,
    saved: raw.saved === true,
    detail: detail === "" ? null : detail
  } }
}

function parseStateResult(stdout) { return parseResult(stdout, STATE_RESULTS) }

// What a clock or pomodoro action printed.
function parseActionResult(stdout) { return parseResult(stdout, ACTION_RESULTS) }

// What `omarchy-org-agenda-week' printed: a payload that says its week.
// Timers are the bar's alone, so a week's are dropped.
function parseWeekResult(stdout) {
  const s = String(stdout == null ? "" : stdout).trim()
  const json = s.charAt(0) === "{" ? s : elispStringValue(s)
  if (json === null) return { ok: false, reason: "not an elisp string" }
  const res = parse(json)
  if (!res.ok) return res
  const v = res.value
  return v.weekOffset === null || v.weekStart === null || v.startInDays === null
    ? { ok: false, reason: "not a week" }
    : { ok: true, value: Object.assign({}, v, { clock: null, pomodoro: normalizePomodoro(null) }) }
}

// Shared by stateMessage and actionMessage.
const RETRY_TEXT = {
  changed: ["This entry changed in Emacs. The agenda is refreshing; try again.", "warn"],
  conflict: ["The file changed on disk and has unsaved edits in Emacs. Resolve it there first.", "error"],
  busy: ["Emacs is waiting for another note. Finish it first.", "warn"]
}
const NOT_SAVED = "the file had unsaved edits in Emacs"
const NOTE_TEXT = { note: " · add your note in Emacs", "note-frame": " · opening Emacs for your note" }
// The needs-emacs detail when Emacs didn't know the question.
const ANY_QUESTION = "Org wants to ask something; do it in Emacs"

function message(t, tn) { return { text: plain(bounded(t, 300)), tone: tn } }

// What each timer action did, and what it failed to do.
const ACTIONS = {
  in: ["Clocked in", "clock in"],
  out: ["Clocked out", "clock out"],
  cancel: ["Clock cancelled", "cancel the clock"],
  start: ["Pomodoro started", "start the pomodoro"],
  "break": ["Break started", "start the break"],
  stop: ["Pomodoro stopped", "stop the pomodoro"]
}

// One line for the popout after a timer action: {text, tone}. `action'
// is in, out, cancel, start, break or stop; `value' parseActionResult's.
function actionMessage(action, value) {
  const v = isObj(value) ? value : {}
  const a = isStr(action) && hasOwn(ACTIONS, action) ? ACTIONS[action] : ["Done", "do that"]
  const detail = isStr(v.detail) ? text(v.detail, 160).trim() : ""
  const did = a[0] + (isKeyword(v.state) ? " · now " + v.state : "")
  const failed = "Couldn't " + a[1]
  if (hasOwn(RETRY_TEXT, v.result)) return message(RETRY_TEXT[v.result][0], RETRY_TEXT[v.result][1])
  if (hasOwn(NOTE_TEXT, v.result)) return message(did + NOTE_TEXT[v.result], "ok")
  switch (v.result) {
  case "done":
    return v.saved ? message(did + " · saved", "ok")
      : message(did + " · not saved: " + (detail || NOT_SAVED), "warn")
  case "needs-emacs":
    return message(detail && detail !== ANY_QUESTION ? "Org wants to ask: " + detail + " — do it in Emacs"
                                                     : "Org wants to ask something — do it in Emacs", "warn")
  case "not-clocking": return message("No clock running", "warn")
  case "unavailable": return message("org-pomodoro isn't available" + (detail ? ": " + detail : ""), "error")
  case "confirm": return message("Stop the pomodoro? P again", "warn")
  case "invalid": return message("Emacs refused this entry" + (detail ? ": " + detail : ""), "error")
  case "error": return message(failed + (detail ? ": " + detail : ""), "error")
  default: return message(failed + ": unexpected answer from Emacs", "error")
  }
}

// One line for the popout after a state change: {text, tone}.
function stateMessage(value, toKeyword) {
  const v = isObj(value) ? value : {}
  const kw = isKeyword(toKeyword) ? toKeyword : "the new state"
  const detail = isStr(v.detail) ? text(v.detail, 120) : ""
  const marked = "Marked " + kw
    + (v.result === "done" && isKeyword(v.state) && v.state !== kw ? " · repeats as " + v.state : "")
  const msg = message
  if (hasOwn(RETRY_TEXT, v.result)) return msg(RETRY_TEXT[v.result][0], RETRY_TEXT[v.result][1])
  if (hasOwn(NOTE_TEXT, v.result)) return msg(marked + NOTE_TEXT[v.result], "ok")
  switch (v.result) {
  case "done":
    return v.saved ? msg(marked + " · saved", "ok")
      : msg(marked + " · not saved: " + (detail || NOT_SAVED), "warn")
  case "blocked":
    return msg(detail ? "Org blocked this: “" + detail + "” isn't done yet"
                      : "Org blocked this: its checkboxes or dependencies aren't done yet", "warn")
  case "invalid": return msg("Emacs refused " + kw + (detail ? ": " + detail : ""), "error")
  case "error": return msg("Couldn't change the state" + (detail ? ": " + detail : ""), "error")
  default: return msg("Couldn't change the state: unexpected answer from Emacs", "error")
  }
}

// Which entry a state change is for: one heading, whatever section shows it.
function entryKey(item) {
  return isObj(item) && isStr(item.path) && Number.isSafeInteger(item.line)
    ? item.path + ":" + item.line : ""
}

// The footer while the picker is open. A fast key wins over the picker's
// own letters, so `t` closes it only when no keyword uses `t`.
function pickerHint(choices, enter) {
  const keys = (Array.isArray(choices) ? choices : [])
    .map(c => isObj(c) && isStr(c.key) && FAST_KEY_RE.test(c.key) ? c.key : "")
    .filter(k => k !== "")
  return [keys.length ? keys.join(" ") + " set" : "",
          "←→ " + (isStr(enter) ? enter : "↵") + " set",
          "↑↓ leave",
          (keys.indexOf("t") >= 0 ? "esc" : "esc/t") + " cancel"]
    .filter(s => s !== "")
    .join(" · ")
}

// ---------------------------------------------------------------- status

const NO_SERVER_HINTS = ["can't find socket", "have you started the server",
  "error accessing socket", "error accessing server file", "connection refused",
  "no such file or directory"]

function isNoServer(stderr) {
  const s = String(stderr == null ? "" : stderr).toLowerCase()
  return NO_SERVER_HINTS.some(h => s.indexOf(h) >= 0)
}

function backoffMs(attempt) {
  const n = Number.isFinite(attempt) && attempt > 0 ? Math.floor(attempt) : 0
  return Math.min(15000 * Math.pow(2, n), 300000)
}

function dateKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function isNewDay(payload, now) { return !!payload && payload.date !== dateKey(now) }

// "2026-10-13T11:13:04+0300" → ms; the zone needs a colon for Date.parse.
function stampMs(s) {
  const m = isStr(s) && /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(Z|[+-]\d{2}:?\d{2})$/.exec(s)
  if (!m) return NaN
  const zone = m[2] === "Z" ? "Z" : m[2].slice(0, 3) + ":" + m[2].slice(-2)
  return Date.parse(m[1] + zone)
}

function isOld(payload, now) {
  const t = payload ? stampMs(payload.generatedAt) : NaN
  return isNaN(t) || !(now.getTime() - t <= STALE_AFTER_MS)
}

function keywordColor(payload, kw) {
  const colors = payload && payload.keywords && payload.keywords.colors
  return isObj(colors) && isStr(kw) && hasOwn(colors, kw) && COLOR_RE.test(colors[kw])
    ? colors[kw] : ""
}

function updatedOf(payload) {
  const m = payload && isStr(payload.generatedAt) && /T(\d{2}):(\d{2})/.exec(payload.generatedAt)
  return m ? m[1] + ":" + m[2] : ""
}

// ---------------------------------------------------------------- popout

function basename(p) {
  const s = String(p == null ? "" : p)
  return s.slice(s.lastIndexOf("/") + 1)
}

function isDeadline(item) { return item.type === "deadline" || item.type === "upcoming-deadline" }

// The payload's day as a local Date at midnight, or null.
function payloadDay(payload) {
  const m = isObj(payload) && isStr(payload.date) && /^(\d{4})-(\d{2})-(\d{2})$/.exec(payload.date)
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null
}

// The day `inDays` after `today`: "Wed" within the week, "27 Oct" further
// out. Fixed English names, so node and QML agree whatever the locale.
function dayLabel(inDays, today) {
  if (!(today instanceof Date) || isNaN(today.getTime())) return "+" + inDays + "d"
  const d = new Date(today.getFullYear(), today.getMonth(), today.getDate() + inDays)
  return inDays < 7 ? WEEKDAYS[d.getDay()] : d.getDate() + " " + MONTHS[d.getMonth()]
}

// Left column of a popout row: the clock time, days overdue (urgent), or
// the day a coming-up entry falls on. `today` is the agenda's day.
function rowLead(item, today) {
  const cls = classify(item)
  if (cls === "overdue") return { text: item.overdueDays + "d", urgent: true }
  if (cls === "upcoming") return { text: item.inDays > 0 ? dayLabel(item.inDays, today) : "", urgent: false }
  return { text: item.time || "", urgent: false }
}

// Right column at rest: the category, or a habit's missed days. A coming-up
// entry's lead is its day, so its time goes here.
function rowTrail(item) {
  if (item.habit && item.overdueDays > 0) return item.overdueDays + "d"
  if (item.time && classify(item) === "upcoming")
    return item.time + (item.category ? " · " + item.category : "")
  return item.category || ""
}

function rowLocation(item) { return basename(item.path) + ":" + item.line }

// What the muted tail of a section header explains.
function sectionHint(key) {
  return key === "habits" ? "missed days" : ""
}

function nextMeta(next, nowMin) {
  const it = next.item
  const end = hhmm(next.endMin % 1440)
  return (next.state === "now"
    ? [it.time + "–" + end, "until " + end]
    : [it.time, relTime(next.startMin - nowMin)])
    .concat(it.category ? [it.category] : [])
    .join(" · ")
}

function footerLine(view) {
  const p = view.payload
  if (!p) return ""
  return [view.updated ? "Updated " + view.updated : "", p.reason,
          p.emacs ? "Emacs " + p.emacs : "", p.org ? "Org " + p.org : "",
          view.stale ? "stale" : ""]
    .filter(s => s !== "")
    .join(" · ")
}

// Which body the popout shows.
function panelMode(view) {
  if (view.status === "offline") return "offline"
  if (hasError(view)) return "error"
  if (!view.payload) return "loading"
  return view.next || view.sections.length ? "agenda" : "empty"
}

function errorMessage(view) {
  return (view.payload && view.payload.error) || view.detail || "unknown error"
}

// Index in `after` (keys) for what was selected at `index` in `before`:
// the same entry if it is still there, else the nearest one above it.
function refocus(before, after, index) {
  if (!after.length) return 0
  for (let i = Math.min(index, before.length - 1); i >= 0; i--) {
    const j = after.indexOf(before[i])
    if (j >= 0) return j
  }
  return clamp(index, 0, after.length - 1)
}

// ---------------------------------------------------------------- org formatting

function spaces(n) { return n > 0 ? new Array(n + 1).join(" ") : "" }
function padRight(s, n) { return s + spaces(n - Array.from(s).length) }
function padLeft(s, n) { return spaces(n - s.length) + s }
function isDate(d) { return d instanceof Date && !isNaN(d.getTime()) }
function addDays(date, n) { return new Date(date.getFullYear(), date.getMonth(), date.getDate() + n) }
function range(from, to) {
  const out = []
  for (let i = from; i <= to; i++) out.push(i)
  return out
}

// Org's %-12:c: "work:" padded to 12 columns, the category cut to 11.
function orgCategory(cat) {
  const chars = Array.from(isStr(cat) ? cat : "")
  return chars.length ? padRight(chars.slice(0, ORG_CELL - 1).join("") + ":", ORG_CELL) : spaces(ORG_CELL)
}

function isScheduledType(item) { return item.type === "scheduled" || item.type === "past-scheduled" }

// Org's default `org-agenda-scheduled-leaders' / `org-agenda-deadline-leaders'.
function orgLeader(item) {
  const n = item.overdueDays
  if (isScheduledType(item)) return n > 0 ? "Sched." + padLeft(String(n), 2) + "x: " : "Scheduled: "
  if (item.type === "deadline") return n > 0 ? padLeft(String(n), 2) + " d. ago: " : "Deadline:  "
  if (item.type === "upcoming-deadline") return "In " + padLeft(String(item.inDays), 3) + " d.: "
  return ""
}

// A leader that says more than the clock: overdue, a deadline, a warning.
function leaderFirst(item) { return isDeadline(item) || (isScheduledType(item) && item.overdueDays > 0) }

// The leader's Org face: org-scheduled-previously, org-scheduled,
// org-warning, org-upcoming-deadline.
function leaderTone(item, today) {
  if (isScheduledType(item)) return item.overdueDays > 0 ? "late" : "muted"
  if (item.type === "deadline") return item.overdueDays > 0 || today ? "urgent" : "soon"
  if (item.type === "upcoming-deadline") return "soon"
  return "normal"
}

// A clock row of today that is over; without a duration it lasts as long
// as nextUp keeps it "now". Habits and leader rows never are.
function isOver(item, nowMin) {
  const start = minutesOf(item.time)
  return !item.habit && !leaderFirst(item) && start >= 0
    && start + (item.durationMin > 0 ? item.durationMin : NOW_GRACE_MIN) <= nowMin
}

// Org's 12-column time/leader cell: {text, tone}. `today`: the row is on
// today's date.
function orgWhen(item, nowMin, today) {
  const start = minutesOf(item.time)
  const cell = (t, tone) => ({ text: padRight(t, ORG_CELL), tone: tone })
  if (leaderFirst(item) || start < 0) return cell(orgLeader(item), leaderTone(item, !!today))
  const t = item.durationMin > 0 ? hhmm(start) + "-" + hhmm((start + item.durationMin) % 1440)
    : hhmm(start) + "......"
  return cell(t, today && isOver(item, nowMin) ? "muted" : "normal")
}

// ISO-8601 week number of a local date.
function isoWeek(date) {
  const dow = date.getDay() || 7
  const thursday = Date.UTC(date.getFullYear(), date.getMonth(), date.getDate() + 4 - dow)
  const yearStart = Date.UTC(new Date(thursday).getUTCFullYear(), 0, 1)
  return Math.floor((thursday - yearStart) / 86400000 / 7) + 1
}

// `org-agenda-format-date-aligned': "Wednesday  14 October 2026", and
// "W42" on a Monday or the first day shown.
function orgDayTitle(date, firstShown) {
  if (!isDate(date)) return { title: "", week: "" }
  return {
    title: padRight(WEEKDAY_NAMES[date.getDay()], 10) + " " + padLeft(String(date.getDate()), 2) + " "
      + MONTH_NAMES[date.getMonth()] + " " + padLeft(String(date.getFullYear()), 4),
    week: date.getDay() === 1 || firstShown ? "W" + pad2(isoWeek(date)) : ""
  }
}

// "THU 15", for the Tabs and Columns day headers.
function compactDayTitle(date) {
  return isDate(date) ? WEEKDAYS[date.getDay()].toUpperCase() + " " + date.getDate() : ""
}

// ---------------------------------------------------------------- layouts

function nextLayout(layout) {
  return LAYOUTS[(LAYOUTS.indexOf(normalizeSettings({ layout: layout }).layout) + 1) % LAYOUTS.length]
}

function weekOffsetOf(v) { return intIn(v, -MAX_WEEK_OFFSET, MAX_WEEK_OFFSET) ? v : 0 }

// f (+1), b (-1) and . (0, back to this week).
function browseOffset(offset, step) {
  if (step === 0) return 0
  const dir = step > 0 ? 1 : step < 0 ? -1 : 0
  return clamp(weekOffsetOf(offset) + dir, -MAX_WEEK_OFFSET, MAX_WEEK_OFFSET)
}

// The week payload when it is the one for `offset`, else null.
function weekFor(offset, week) {
  return isObj(week) && week.weekOffset === offset && payloadDay({ date: week.weekStart }) !== null
    && Array.isArray(week.items) ? week : null
}

// The week to fetch for `offset`, or null when none is needed.
function weekWanted(offset, week) {
  const o = weekOffsetOf(offset)
  return o === 0 || (isObj(week) && week.weekOffset === o) ? null : o
}

// First day of the Org week `offset` weeks away. The bar's week ends
// `daysAhead` days after its day and lasts 7 days, whatever
// `org-agenda-start-on-weekday' is, so no Emacs setting is needed.
function weekStartDay(view, offset, week) {
  const w = weekFor(offset, week)
  if (w) return payloadDay({ date: w.weekStart })
  const today = payloadDay(view.payload)
  return today ? addDays(today, 7 * offset + view.payload.daysAhead - 6) : null
}

// "14–18 Oct", "29 Sep – 5 Oct", "14 Oct".
function dayRange(a, b) {
  if (a.getTime() === b.getTime()) return a.getDate() + " " + MONTHS[a.getMonth()]
  return a.getMonth() === b.getMonth() && a.getFullYear() === b.getFullYear()
    ? a.getDate() + "–" + b.getDate() + " " + MONTHS[b.getMonth()]
    : a.getDate() + " " + MONTHS[a.getMonth()] + " – " + b.getDate() + " " + MONTHS[b.getMonth()]
}

// The header's week navigator: {offset, label, range}.
function weekNav(view, offset, week) {
  const o = weekOffsetOf(offset)
  const today = payloadDay(view.payload)
  const first = weekStartDay(view, o, week)
  const label = o === 0 ? "This week" : o === 1 ? "Next week" : o === -1 ? "Last week"
    : first ? "W" + pad2(isoWeek(first))
    : (o > 0 ? "+" : "") + o + " weeks"
  const span = o === 0 ? (today ? dayRange(today, addDays(today, view.payload.daysAhead)) : "")
    : first ? dayRange(first, addDays(first, 6)) : ""
  return { offset: o, label: label, range: span }
}

// Keys for a payload's items, the same in every layout and refresh:
// type, path, line and day, with "#2"… for repeats. Computed before
// showDone filters, so hiding done rows doesn't move them either.
function keyedEntries(items) {
  const seen = {}
  return (items || []).map(item => {
    const base = item.type + ":" + item.path + ":" + item.line + ":" + item.inDays
    const n = hasOwn(seen, base) ? seen[base] + 1 : 1
    seen[base] = n
    return { key: n > 1 ? base + "#" + n : base, item: item }
  })
}

// Soonest first, ties in Org's order (V4's sort may not be stable).
function entriesByInDays(entries) {
  return entries
    .map((e, i) => ({ e: e, i: i }))
    .sort((a, b) => (a.e.item.inDays - b.e.item.inDays) || (a.i - b.i))
    .map(x => x.e)
}

function isLaterDay(item) { return item.inDays > 0 && item.type !== "upcoming-deadline" }

// Where Org draws its now line in today's rows: before the first timed
// non-habit row starting after now, else after the last one; -1 for none.
function nowLineAt(items, nowMin) {
  if (!isFinite(nowMin)) return -1
  const timed = items
    .map((item, i) => ({ i: i, start: item.habit ? -1 : minutesOf(item.time) }))
    .filter(c => c.start >= 0)
  if (!timed.length) return -1
  const after = timed.filter(c => c.start > nowMin)
  return after.length ? after[0].i : timed[timed.length - 1].i + 1
}

const tone = (t, tn) => ({ text: t, tone: tn })

function orgRow(e, nowMin, today) {
  return { kind: "row", key: e.key, sel: -1, item: e.item, style: "org", lead: null, trail: null,
           cat: orgCategory(e.item.category), when: orgWhen(e.item, nowMin, today),
           past: !!today && isOver(e.item, nowMin), flag: isDeadline(e.item), dense: false }
}

function listRow(e, lead, trail, past, dense) {
  return { kind: "row", key: e.key, sel: -1, item: e.item, style: "list", lead: lead, trail: trail,
           cat: "", when: null, past: past, flag: isDeadline(e.item), dense: dense }
}

// Today's and Overdue's rows, with the v0.2 lead and trail.
function classicRow(e, today, nowMin, dense) {
  const lead = rowLead(e.item, today)
  return listRow(e, tone(lead.text, lead.urgent ? "urgent" : "muted"),
                 tone(rowTrail(e.item), e.item.habit && e.item.overdueDays > 0 ? "late" : "muted"),
                 isOver(e.item, nowMin), dense)
}

// A week row: the time, then the category.
function weekRow(e, dense) {
  return listRow(e, tone(e.item.time || "", "muted"), tone(e.item.category || "", "muted"), false, dense)
}

function sectionBlock(key, title, count, hint, urgent) {
  return { kind: "section", key: "sec:" + key, title: title, count: count, hint: hint, urgent: urgent }
}

function dayBlock(date, style, today, empty, firstShown) {
  const org = orgDayTitle(date, firstShown)
  return { kind: "day", key: "day:" + dateKey(date), style: style, today: today, empty: empty,
           title: style === "org" ? org.title : compactDayTitle(date),
           week: style === "org" ? org.week : "",
           hint: style === "compact" && empty ? "nothing scheduled" : "" }
}

function nextBlock(view) {
  return view.next
    ? [{ kind: "next", key: "next", sel: -1, item: view.next.item,
         caption: view.next.state === "now" ? "NOW" : "NEXT UP", meta: nextMeta(view.next, view.nowMin) }]
    : []
}

function chipsBlock(entries) {
  return { kind: "chips", key: "chips:habits", chips: entries.map(e => ({
    key: e.key, sel: -1, item: e.item, text: e.item.title,
    missed: e.item.overdueDays > 0 ? e.item.overdueDays + "d" : "", done: e.item.done })) }
}

function concatAll(lists) { return lists.reduce((acc, l) => acc.concat(l), []) }

function countRows(blocks) {
  return blocks.reduce((n, b) => n + (b.kind === "row" ? 1 : b.kind === "chips" ? b.chips.length : 0), 0)
}

// A week payload's 7 days: [{date, today, entries}].
function payloadWeekDays(week, showDone) {
  const start = payloadDay({ date: week.weekStart })
  const entries = keyedEntries(week.items).filter(e => showDone || !e.item.done)
  return range(0, 6).map(i => ({
    date: addDays(start, i), today: week.startInDays + i === 0,
    entries: entries.filter(e => e.item.inDays - week.startInDays === i)
  }))
}

// Another week's area: its days, or a loading / error message.
function otherWeek(ui, nav, showDone) {
  const w = weekFor(ui.offset, ui.week)
  if (w && !w.error) return { days: payloadWeekDays(w, showDone), message: null }
  const err = ui.weekError || (w && w.error) || ""
  const what = / week$/.test(nav.label) ? nav.label.toLowerCase() : nav.label
  return { days: null, message: err
    ? { kind: "message", key: "msg:week", text: text(err, 300), tone: "error" }
    : { kind: "message", key: "msg:week", text: "Loading " + what + "…", tone: "muted" } }
}

function compactDays(days, dense) {
  return concatAll(days.map(d => [dayBlock(d.date, "compact", d.today, d.entries.length === 0, false)]
    .concat(d.entries.map(e => weekRow(e, dense)))))
}

// Tabs' Week tab and Columns' week section. This week: its later days,
// with each deadline warning on its day, and further ones after.
function weekBlocks(ctx, dense) {
  if (ctx.ui.offset !== 0) {
    const other = otherWeek(ctx.ui, ctx.nav, ctx.settings.showDone)
    return other.days ? compactDays(other.days, dense) : [other.message]
  }
  const ahead = ctx.daysAhead
  const warns = ctx.entries.filter(e => e.item.type === "upcoming-deadline")
  const inWeek = e => e.item.inDays >= 1 && e.item.inDays <= ahead
  const days = range(1, ahead).map(d => ({
    date: addDays(ctx.today, d), today: false,
    entries: warns.filter(e => e.item.inDays === d)
      .concat(ctx.entries.filter(e => isLaterDay(e.item) && e.item.inDays === d))
  }))
  const later = entriesByInDays(warns.filter(e => !inWeek(e)))
  return compactDays(days, dense).concat(later.length
    ? [sectionBlock("ahead", "Deadlines ahead", later.length, "", false)].concat(later.map(e =>
        listRow(e, tone(dayLabel(e.item.inDays, ctx.today), "muted"), tone(e.item.category || "", "muted"),
                false, dense)))
    : [])
}

// The next card, then Schedule, Today and Habits as sections() has them;
// Habits as chips in Columns.
function todayBlocks(ctx, chips) {
  const secs = SECTION_ORDER
    .filter(sec => ["schedule", "today", "habit"].indexOf(sec.cls) >= 0)
    .map(sec => ({ sec: sec, entries: ctx.entries.filter(e => classify(e.item) === sec.cls) }))
    .filter(x => x.entries.length > 0)
  return nextBlock(ctx.view).concat(concatAll(secs.map(x =>
    [sectionBlock(x.sec.key, x.sec.title, x.entries.length, sectionHint(x.sec.key), false)]
      .concat(chips && x.sec.key === "habits" ? [chipsBlock(x.entries)]
              : x.entries.map(e => classicRow(e, ctx.today, ctx.nowMin, false))))))
}

function overdueEntries(ctx) { return ctx.entries.filter(e => classify(e.item) === "overdue") }

// Org: today in Org's order with the now line, then the week's later
// days; another week is its 7 days.
function orgBlocks(ctx) {
  if (ctx.ui.offset !== 0) {
    const other = otherWeek(ctx.ui, ctx.nav, ctx.settings.showDone)
    return other.days
      ? concatAll(other.days.map((d, i) => [dayBlock(d.date, "org", d.today, d.entries.length === 0, i === 0)]
          .concat(d.entries.map(e => orgRow(e, ctx.nowMin, d.today)))))
      : [other.message]
  }
  const todays = ctx.entries.filter(e => !isLaterDay(e.item))
  const rows = todays.map(e => orgRow(e, ctx.nowMin, true))
  const at = nowLineAt(todays.map(e => e.item), ctx.nowMin)
  const withNow = at < 0 ? rows
    : rows.slice(0, at).concat([{ kind: "now", key: "now", text: NOW_LINE }], rows.slice(at))
  return [dayBlock(ctx.today, "org", true, todays.length === 0, true)].concat(withNow,
    concatAll(range(1, ctx.daysAhead).map(d => {
      const day = ctx.entries.filter(e => isLaterDay(e.item) && e.item.inDays === d)
      return [dayBlock(addDays(ctx.today, d), "org", false, day.length === 0, false)]
        .concat(day.map(e => orgRow(e, ctx.nowMin, false)))
    })))
}

// Numbers what the keyboard reaches, pane by pane in display order.
function numbered(panes) {
  let sel = 0
  const rows = []
  const take = (key, item, pane) => {
    rows.push({ key: key, sel: sel, pane: pane, item: item })
    return sel++
  }
  const out = panes.map((p, pi) => ({ key: p.key, title: p.title, blocks: p.blocks.map(b =>
    b.kind === "row" || b.kind === "next" ? Object.assign({}, b, { sel: take(b.key, b.item, pi) })
    : b.kind === "chips" ? Object.assign({}, b, { chips: b.chips.map(c =>
        Object.assign({}, c, { sel: take(c.key, c.item, pi) })) })
    : b) }))
  return { panes: out, rows: rows }
}

function normalizeUi(ui) {
  const u = isObj(ui) ? ui : {}
  return {
    layout: normalizeSettings({ layout: u.layout }).layout,
    tab: TABS.indexOf(u.tab) >= 0 ? u.tab : "today",
    offset: weekOffsetOf(u.offset),
    week: isObj(u.week) ? u.week : null,
    weekError: isStr(u.weekError) ? u.weekError : ""
  }
}

// The clocked entry's rows and chips, as org-agenda-clocking tints them:
// `clocked' on every row and chip; a list row's trail becomes the time,
// an Org row gets `clock' ("◷ 0:23", else "").
function tinted(block, timer) {
  const hit = it => timer !== null && timer.clockKey !== "" && entryKey(it) === timer.clockKey
  if (block.kind === "chips")
    return Object.assign({}, block, { chips: block.chips.map(c => Object.assign({}, c, { clocked: hit(c.item) })) })
  if (block.kind !== "row") return block
  const on = hit(block.item)
  const mark = on ? timer.glyph + " " + timer.barTime : ""
  return Object.assign({}, block, { clocked: on },
                       block.style === "org" ? { clock: mark } : on ? { trail: tone(mark, timer.tone) } : {})
}

// The popout's body for any layout, from view() and the popout's state
// ui = {layout, tab, offset, week, weekError}. Blocks are display-ready;
// `rows` lists what the keyboard reaches, in `sel` order.
function layoutModel(view, rawUi) {
  const ui = normalizeUi(rawUi)
  const settings = normalizeSettings(view.settings)
  const today = payloadDay(view.payload)
  const nav = weekNav(view, ui.offset, ui.week)
  const entries = keyedEntries(view.items).filter(e => settings.showDone || !e.item.done)
  const timer = isObj(view.timer) ? view.timer : null
  const model = (tabs, panes) => Object.assign(
    { layout: ui.layout, tab: ui.tab, tabs: tabs, nav: nav },
    numbered(panes.map(p => Object.assign({}, p, { blocks: p.blocks.map(b => tinted(b, timer)) }))),
    { empty: ui.offset === 0 && entries.length === 0 && !view.next })
  if (!today) {
    const panes = ui.layout === "Columns"
      ? [{ key: "today", title: "Today", blocks: [] }, { key: "side", title: "", blocks: [] }]
      : [{ key: ui.layout === "Tabs" ? ui.tab : "main", title: "", blocks: [] }]
    return model([], panes)
  }
  const ctx = { view: view, ui: ui, settings: settings, today: today, nav: nav, entries: entries,
                nowMin: view.nowMin, daysAhead: view.payload.daysAhead || 0 }
  const overdue = overdueEntries(ctx)
  if (ui.layout === "Org") return model([], [{ key: "main", title: "", blocks: orgBlocks(ctx) }])
  if (ui.layout === "Tabs") {
    const byTab = {
      today: todayBlocks(ctx, false),
      week: weekBlocks(ctx, false),
      overdue: overdue.map(e => classicRow(e, today, ctx.nowMin, false))
    }
    const todayCount = countRows(byTab.today.filter(b => b.kind !== "next"))
    const overdueCount = countRows(byTab.overdue)
    return model([{ key: "today", title: "Today", count: todayCount, urgent: false },
                  { key: "week", title: nav.label, count: countRows(byTab.week), urgent: false },
                  { key: "overdue", title: "Overdue", count: overdueCount, urgent: overdueCount > 0 }],
                 [{ key: ui.tab, title: "", blocks: byTab[ui.tab] }])
  }
  const week = weekBlocks(ctx, true)
  const side = (overdue.length
    ? [sectionBlock("overdue", "Overdue", overdue.length, "", true)]
        .concat(overdue.map(e => classicRow(e, today, ctx.nowMin, true)))
    : []).concat([sectionBlock("week", nav.label, countRows(week), "", false)], week)
  return model([], [{ key: "today", title: "Today", blocks: todayBlocks(ctx, true) },
                    { key: "side", title: "", blocks: side }])
}

// ←/→ in Columns: the other pane, same index within the pane, clamped.
function paneSel(model, sel, dir) {
  const rows = isObj(model) && Array.isArray(model.rows) ? model.rows : []
  const cur = rows.filter(r => r.sel === sel)[0]
  if (!cur || !Array.isArray(model.panes) || model.panes.length < 2) return sel
  const target = clamp(cur.pane + (dir > 0 ? 1 : dir < 0 ? -1 : 0), 0, model.panes.length - 1)
  const there = rows.filter(r => r.pane === target)
  if (target === cur.pane || !there.length) return sel
  const index = rows.filter(r => r.pane === cur.pane).indexOf(cur)
  return there[Math.min(index, there.length - 1)].sel
}

// ←/→ in Tabs, stopping at the ends.
function tabStep(tab, dir) {
  const i = Math.max(0, TABS.indexOf(tab))
  return TABS[clamp(i + (dir > 0 ? 1 : dir < 0 ? -1 : 0), 0, TABS.length - 1)]
}

// Keys 1 2 3; null for anything else.
function tabAt(n) { return intIn(n, 1, TABS.length) ? TABS[n - 1] : null }

// The first overdue row's key, for the badge click; "" when none shows.
function overdueFocus(model) {
  const rows = isObj(model) && Array.isArray(model.rows) ? model.rows : []
  const hit = rows.filter(r => r.key !== "next" && isObj(r.item) && classify(r.item) === "overdue")[0]
  return hit ? hit.key : ""
}

// The popout state that shows overdue: this week, and Tabs on Overdue.
function overdueUi(ui) {
  const u = normalizeUi(ui)
  return Object.assign({}, isObj(ui) ? ui : {}, { offset: 0 },
                       u.layout === "Tabs" ? { tab: "overdue" } : {})
}

// The popout's key map, as in Org's agenda: what a key press asks for, or
// null. `ctx` = {layout, tab, pickerOpen, clocking, pomodoro,
// pomodoroAvailable, confirming} (`pomodoro`: its state); `key` is a named
// key ("Up", "Down", "Left", "Right", "Return", "Escape") or ""; `text` is
// the event's text. Letters are case-sensitive, like Org's. The state
// picker, while it is open, keeps every key for itself; the pomodoro's
// stop question takes the next key: P stops, any other just dismisses it
// (a key with no name or text, such as Shift, leaves it).
//   {move: ±1} {open} {state} {refresh} {close} {layout: "next"}
//   {week: +1 | -1 | 0} (Tabs: also {tab: "week"}) {tab: …} {pane: ±1}
//   {clock: "in" | "out" | "cancel" | "goto"} {pomodoro: true | "stop"}
//   {cancelConfirm}
function keyAction(ctx, key, text) {
  const c = isObj(ctx) ? ctx : {}
  if (c.pickerOpen) return null
  const layout = normalizeSettings({ layout: c.layout }).layout
  const k = isStr(key) && key !== "" ? key : isStr(text) && text.length === 1 ? text : ""
  if (c.confirming) return k === "" ? null : k === "P" ? { pomodoro: "stop" } : { cancelConfirm: true }
  const side = k === "Left" || k === "h" ? -1 : k === "Right" || k === "l" ? 1 : 0
  const step = { f: 1, b: -1, ".": 0 }
  const onClock = { O: "out", X: "cancel", J: "goto" }
  if (k === "I") return { clock: "in" }
  if (hasOwn(onClock, k)) return c.clocking ? { clock: onClock[k] } : null
  if (k === "P") return c.pomodoroAvailable ? { pomodoro: true } : null
  if (k === "Up" || k === "k" || k === "p") return { move: -1 }
  if (k === "Down" || k === "j" || k === "n") return { move: 1 }
  if (k === "Return") return { open: true }
  if (k === "Escape") return { close: true }
  if (k === "t") return { state: true }
  if (k === "r" || k === "R") return { refresh: true }
  if (k === "v") return { layout: "next" }
  if (hasOwn(step, k))
    return layout === "Tabs" && k !== "." ? { week: step[k], tab: "week" } : { week: step[k] }
  if (layout === "Tabs") {
    if (side !== 0) return { tab: tabStep(c.tab, side) }
    const tab = /^[0-9]$/.test(k) ? tabAt(Number(k)) : null
    return tab ? { tab: tab } : null
  }
  if (layout === "Columns" && side !== 0) return { pane: side }
  return null
}

// What P does now: "start" (on the selected row), "break" (end the
// overtime), "ask" (org-pomodoro wants the stop confirmed), "stop", or
// null without org-pomodoro.
function pomodoroStep(view, confirming) {
  const p = isObj(view) && isObj(view.payload) && isObj(view.payload.pomodoro) ? view.payload.pomodoro : null
  if (p === null || p.available !== true) return null
  if (p.state === "overtime") return "break"
  if (hasOwn(PHASES, p.state)) return p.askKill !== false && !confirming ? "ask" : "stop"
  return "start"
}

// The footer's key hints. With `timerCtx` = {clocking, pomodoroAvailable}
// they add the clock's keys (and P); hints whose buttons name their key
// in a tooltip make room, refresh first, so the line stays ≤ MAX_HINT.
function layoutHints(layout, timerCtx) {
  const l = normalizeSettings({ layout: layout }).layout
  const prefix = l === "Tabs" ? "1 2 3 tabs · " : l === "Columns" ? "← → column · " : ""
  const t = isObj(timerCtx) ? timerCtx : null
  const timer = t === null ? []
    : (t.clocking ? ["O out", "J jump"] : ["I clock"]).concat(t.pomodoroAvailable ? ["P pomodoro"] : [])
  const hints = ["↑↓ move", "↵ open", "t state"].concat(timer, ["f b week", "v layout", "r refresh", "esc"])
  const line = drop => prefix + hints.filter(h => drop.indexOf(h) < 0).join(" · ")
  if (!timer.length) return line([])
  const fits = range(1, HINT_DROPS.length).map(n => line(HINT_DROPS.slice(0, n))).filter(s => s.length <= MAX_HINT)
  return fits.length ? fits[0] : line(HINT_DROPS)
}

// ---------------------------------------------------------------- view

function view(payload, status, detail, now, rawSettings) {
  const settings = normalizeSettings(rawSettings)
  const p = isObj(payload) ? payload : null
  const items = p && Array.isArray(p.items) ? p.items : []
  const st = STATUSES.indexOf(status) >= 0 ? status : "loading"
  const v = {
    status: st,
    stale: st === "stale",
    detail: text(detail, 300),
    settings: settings,
    payload: p,
    items: items,
    sections: sections(items, settings),
    next: nextUp(items, now),
    nowMin: nowMinutes(now),
    openToday: openToday(items),
    overdue: overdueCount(items, settings),
    updated: updatedOf(p)
  }
  // The bar and the rows count whole minutes; the popout's strip may ask
  // timerState for seconds.
  Object.assign(v, { timer: timerState(v, now, false) })
  return Object.assign(v, { label: barLabel(v), tooltip: tooltip(v) })
}
