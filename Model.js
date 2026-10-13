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
const MAX_DETAIL = 200
const ITEM_TYPES = ["scheduled", "past-scheduled", "deadline", "upcoming-deadline",
                    "timestamp", "sexp", "block"]
const LABELS = ["Next item", "Count", "Icon"]
const STATUSES = ["loading", "ok", "offline", "error", "stale"]
const SECTION_ORDER = [
  { key: "schedule", cls: "schedule", title: "Schedule" },
  { key: "today", cls: "today", title: "Today" },
  { key: "habits", cls: "habit", title: "Habits" },
  { key: "overdue", cls: "overdue", title: "Overdue" },
  { key: "upcoming", cls: "upcoming", title: "Coming up" }
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
      error: isStr(raw.error) ? text(raw.error, 300) : null,
      missing: Array.isArray(raw.missing)
        ? raw.missing.slice(0, 50).filter(isStr).map(s => text(s, 1024))
        : []
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

function classify(item) {
  if (item.habit) return "habit"
  if (item.overdueDays > 0) return "overdue"
  if (item.type === "upcoming-deadline") return "upcoming"
  if (item.time) return "schedule"
  return "today"
}

function sections(items, settings) {
  const s = normalizeSettings(settings)
  const shown = (items || []).filter(i => s.showDone || !i.done)
  return SECTION_ORDER
    .map(sec => ({ key: sec.key, title: sec.title,
                   items: shown.filter(i => classify(i) === sec.cls) }))
    .filter(sec => sec.items.length > 0)
}

function countOpen(items, classes) {
  return (items || []).filter(i => !i.done && classes.indexOf(classify(i)) >= 0).length
}

function openToday(items) { return countOpen(items, ["schedule", "today"]) }

function habitCount(items) { return countOpen(items, ["habit"]) }

function overdueCount(items, settings) {
  const withHabits = !!settings && settings.habitsInBadge === true
  return (items || []).filter(i => !i.done && i.overdueDays > 0 && (withHabits || !i.habit)).length
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
  return {
    label: LABELS.indexOf(label) >= 0 ? label : "Next item",
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

// ---------------------------------------------------------------- bar text

function hasError(view) { return view.status === "error" || (!!view.payload && view.payload.error !== null && view.payload.error !== undefined) }

function barLabel(view) {
  const blank = mode => ({ mode: mode, text: "", badge: 0, alert: false })
  if (view.status === "offline") return blank("offline")
  if (hasError(view)) return blank("error")
  if (!view.payload) return blank("loading")
  const s = view.settings
  const alert = view.overdue > 0
  const badge = s.overdueBadge ? view.overdue : 0
  const label = (mode, txt) => ({ mode: mode, text: txt, badge: badge, alert: alert })
  if (s.label === "Icon") return { mode: "icon", text: "", badge: 0, alert: alert }
  if (s.label === "Count") return label("count", String(view.openToday))
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
  return (view.next ? [nextLine(view.next, view.nowMin, view.settings.label !== "Icon")] : [])
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

// The UI may only jump to a location Emacs itself reported.
function knownItem(item, payload) {
  const ok = isObj(item) && Number.isSafeInteger(item.line) && item.line > 0 && isAbsPath(item.path)
    && isObj(payload) && Array.isArray(payload.items)
    && payload.items.some(i => isObj(i) && i.path === item.path && i.line === item.line)
  if (!ok) throw new Error("item is not in the agenda payload")
  return item
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

function parseStateResult(stdout) {
  const s = String(stdout == null ? "" : stdout).trim()
  const json = s.charAt(0) === "{" ? s : elispStringValue(s)
  if (json === null) return { ok: false, reason: "not an elisp string" }
  let raw
  try { raw = JSON.parse(json) } catch (e) { return { ok: false, reason: "invalid JSON" } }
  if (!isObj(raw) || STATE_RESULTS.indexOf(raw.result) < 0)
    return { ok: false, reason: "unknown result" }
  const detail = isStr(raw.detail) ? text(raw.detail, MAX_DETAIL) : ""
  return { ok: true, value: {
    result: raw.result,
    state: isKeyword(raw.state) ? raw.state : null,
    saved: raw.saved === true,
    detail: detail === "" ? null : detail
  } }
}

// One line for the popout after a state change: {text, tone}.
function stateMessage(value, toKeyword) {
  const v = isObj(value) ? value : {}
  const kw = isKeyword(toKeyword) ? toKeyword : "the new state"
  const detail = isStr(v.detail) ? text(v.detail, 120) : ""
  const marked = "Marked " + kw
    + (v.result === "done" && isKeyword(v.state) && v.state !== kw ? " · repeats as " + v.state : "")
  const msg = (t, tone) => ({ text: plain(bounded(t, 300)), tone: tone })
  switch (v.result) {
  case "done":
    return v.saved ? msg(marked + " · saved", "ok")
      : msg(marked + " · not saved: " + (detail || "the file had unsaved edits in Emacs"), "warn")
  case "note": return msg(marked + " · add your note in Emacs", "ok")
  case "note-frame": return msg(marked + " · opening Emacs for your note", "ok")
  case "blocked":
    return msg(detail ? "Org blocked this: “" + detail + "” isn't done yet"
                      : "Org blocked this: its checkboxes or dependencies aren't done yet", "warn")
  case "changed": return msg("This entry changed in Emacs. The agenda is refreshing; try again.", "warn")
  case "conflict":
    return msg("The file changed on disk and has unsaved edits in Emacs. Resolve it there first.", "error")
  case "busy": return msg("Emacs is waiting for another note. Finish it first.", "warn")
  case "invalid": return msg("Emacs refused " + kw + (detail ? ": " + detail : ""), "error")
  case "error": return msg("Couldn't change the state" + (detail ? ": " + detail : ""), "error")
  default: return msg("Couldn't change the state: unexpected answer from Emacs", "error")
  }
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

// Left column of a popout row: the clock time, or days overdue (urgent).
function rowLead(item) {
  const cls = classify(item)
  if (cls === "overdue") return { text: item.overdueDays + "d", urgent: true }
  if (cls === "upcoming") return { text: "", urgent: false }
  return { text: item.time || "", urgent: false }
}

// Right column at rest: the category, or a habit's missed days.
function rowTrail(item) {
  return item.habit && item.overdueDays > 0 ? item.overdueDays + "d" : (item.category || "")
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

// The popout in display order. `sel` numbers what the keyboard can reach:
// the next-up card, then every row of every section. `rows` lists those in
// `sel` order, keyed so a selection survives a refresh.
function panelModel(view) {
  let sel = 0
  const next = view.next ? { key: "next", sel: sel++, item: view.next.item } : null
  const secs = view.sections.map(sec => ({
    key: sec.key, title: sec.title, count: sec.items.length,
    hint: sectionHint(sec.key),
    rows: sec.items.map(item => ({
      key: sec.key + ":" + item.path + ":" + item.line + ":" + item.type,
      sel: sel++, item: item
    }))
  }))
  return { next: next, sections: secs,
           rows: secs.reduce((acc, s) => acc.concat(s.rows), next ? [next] : []) }
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
  return Object.assign(v, { label: barLabel(v), tooltip: tooltip(v) })
}
