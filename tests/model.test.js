// Model.js under node: parsing, sections, next up, bar text, elisp forms.
//   node tests/model.test.js
// TZ is pinned (before any Date use) so local-time helpers (dateKey, nextUp,
// isOld with a +0300 stamp) are deterministic: Bucharest is UTC+3 in October.
process.env.TZ = "Europe/Bucharest"

const fs = require("fs")
const path = require("path")
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const M = new Function(src + "; return { PROTOCOL, MAX_ITEMS, MAX_TITLE, ID_RE, NOW_GRACE_MIN," +
  " STALE_AFTER_MS, parse, bounded, classify, sections, openToday, overdueCount, minutesOf," +
  " nextUp, normalizeSettings, barLabel, relTime, tooltip, plain, elispString, clientArgs," +
  " socketKey, outputDir, agendaFilesList, filesForm, loadPreamble, pullForm, gotoForm, agendaForm," +
  " fallbackOpenArgs, isNoServer, backoffMs, dateKey, isNewDay, isOld, keywordColor, view," +
  " basename, isDeadline, rowLead, rowTrail, rowLocation, sectionHint, nextMeta, footerLine," +
  " panelMode, errorMessage, panelModel, refocus, stateChoices, canChangeState, stateForm," +
  " takeNoteForm, parseStateResult, stateMessage, entryKey, pickerHint, ITEM_TYPES, payloadDay }")()

let failed = 0
let count = 0
function eq(got, want, name) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  count++
  if (!ok) failed++
  console.log((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "\n     got  " + JSON.stringify(got) + "\n     want " + JSON.stringify(want)))
}
function throws(fn) { try { fn(); return false } catch (e) { return true } }

// ---------------------------------------------------------------- fixtures

const ELISP = "/home/u/plugin/elisp/omarchy-org-agenda.el"
const OUT = "/home/u/.cache/org-agenda/server.json"
const at = (h, m) => new Date(2026, 9, 13, h, m)

function item(over) {
  return Object.assign({ id: null, path: "/home/u/org/cal.org", line: 1, type: "scheduled",
    todo: null, done: false, title: "x", priority: null, category: "cal", tags: [],
    time: null, durationMin: null, overdueDays: 0, inDays: 0, habit: false }, over)
}
function payloadOf(items, over) {
  return Object.assign({ version: 1, date: "2026-10-13", generatedAt: "2026-10-13T11:13:04+0300",
    reason: "save", emacs: "31.1", org: "9.8.7",
    keywords: { todo: ["NEXT", "TODO"], done: ["DONE"], colors: { NEXT: "#fb4934" } },
    items: items, error: null, missing: [] }, over)
}
const parsed = raw => M.parse(JSON.stringify(raw))
const parsedItems = items => parsed(payloadOf(items)).value.items

const sync = item({ line: 63, type: "timestamp", title: "Engineering Sync Up", time: "13:00", durationMin: 30 })
const standup = item({ line: 10, title: "Standup", time: "09:00" })
const task = item({ line: 20, todo: "TODO", title: "Write report" })
const habit = item({ line: 30, title: "Log weight ⚖️", habit: true, overdueDays: 2 })
const late = item({ line: 40, todo: "NEXT", title: "Pay bill", overdueDays: 3 })
const soon = item({ line: 50, type: "upcoming-deadline", title: "Taxes" })
const doneTask = item({ line: 60, todo: "DONE", title: "Done thing", done: true })
const all = [sync, standup, task, habit, late, soon, doneTask]

// ---------------------------------------------------------------- parse

eq(M.parse("not json {").ok, false, "parse: garbage")
eq([M.parse(undefined).ok, M.parse(null).ok, M.parse(42).ok], [false, false, false], "parse: non-string input")
eq([M.parse("[]").ok, M.parse("3").ok, M.parse("null").ok, M.parse("\"x\"").ok], [false, false, false, false], "parse: non-object")
eq(parsed(payloadOf([], { version: 2 })).ok, false, "parse: wrong version")
eq(parsed(payloadOf([], { version: "1" })).ok, false, "parse: string version")
eq([parsed(payloadOf([], { date: "2026-10-1" })).ok, parsed(payloadOf([], { date: 5 })).ok], [false, false], "parse: bad date")
eq(parsed(payloadOf([sync])).ok, true, "parse: valid")
eq(parsedItems([sync])[0], sync, "parse: item round-trips")
eq(parsedItems([item({ path: undefined }), item({ line: undefined }), item({ line: 0 }), item({ line: 1.5 }), item({ line: "3" })]).length,
   0, "parse: missing/bad path or line dropped")
eq(parsedItems([item({ path: "org/cal.org" }), item({ path: "/a\nb" }), item({ path: "/" + "a".repeat(5000) })]).length,
   0, "parse: relative / control / huge path dropped")
eq(parsedItems([null, 3, "x", [], sync]).length, 1, "parse: non-object items dropped")
eq(parsedItems(Array.from({ length: 250 }, (_, i) => item({ line: i + 1 }))).length, 200, "parse: 250 items -> 200")
{
  const t = parsedItems([item({ title: "a".repeat(500) })])[0].title
  eq([Array.from(t).length, t.slice(-1)], [200, "…"], "parse: long title bounded with …")
}
eq(parsedItems([habit])[0].title, "Log weight ⚖️", "parse: emoji title intact")
eq(parsedItems([item({ title: "a\tb\nc\u0000d\u007f" })])[0].title, "a b c d ", "parse: control chars in title -> spaces")
eq(parsedItems([item({ title: 5 })])[0].title, "", "parse: non-string title -> empty")
eq(parsedItems([item({ id: "bad id!" }), item({ id: "x\") (shell-command \"rm\")" }), item({ id: "abc-123:4.5_6" })]).map(i => i.id),
   [null, null, "abc-123:4.5_6"], "parse: id validated")
{
  const i = parsedItems([item({ todo: "X".repeat(33), done: "yes", habit: 1, time: "9:00", durationMin: -5,
    overdueDays: 1.5, priority: "AB", category: "c".repeat(61), tags: ["ok", 3, "t".repeat(41)].concat(Array(30).fill("z")),
    type: "weird" })])[0]
  eq([i.todo, i.done, i.habit, i.time, i.durationMin, i.overdueDays, i.priority, i.category, i.tags.length, i.tags[0], i.type],
     [null, false, false, null, null, 0, null, null, 20, "ok", "other"], "parse: field normalisation")
}
eq(parsedItems([item({ priority: "A", tags: ["a", "b"] })]).map(i => [i.priority, i.tags]), [["A", ["a", "b"]]], "parse: priority and tags kept")
{
  const old = item({ type: "upcoming-deadline" }); delete old.inDays
  eq(parsedItems([old])[0].inDays, 0, "parse: payload without inDays (pre-0.3) -> 0")
  eq(parsedItems([4, -1, 1.5, "3", null, 0].map(d => item({ inDays: d }))).map(i => i.inDays),
     [4, 0, 0, 0, 0, 0], "parse: inDays validated")
}
{
  const v = parsed(payloadOf([], { keywords: { todo: ["A", 1, "B"], done: "x",
    colors: { A: "#00ff00", B: "red", C: "#12345", D: "#abcdefg", E: "#AbCdEf" } } })).value
  eq(v.keywords, { todo: ["A", "B"], done: [], colors: { A: "#00ff00", E: "#AbCdEf" }, keys: {} },
     "parse: keywords, bad colors dropped, no keys (pre-0.2 payload)")
}
eq(parsed(payloadOf([], { keywords: { todo: ["A"], done: [], keys: { A: "a", B: "Z", C: "9", D: "ab", E: "", F: 3,
    G: "-", H: "\n", I: "é", "bad\tkey": "x" } } })).value.keywords.keys,
   { A: "a", B: "Z", C: "9" }, "parse: keys, invalid entries dropped")
eq(M.parse(JSON.stringify(payloadOf([])).replace("\"colors\"", "\"keys\":{\"__proto__\":\"p\"},\"colors\""))
     .value.keywords.keys.__proto__ === Object.prototype, true, "parse: __proto__ key ignored")
eq([parsed(payloadOf([], { keywords: { keys: "n" } })).value.keywords.keys,
    parsed(payloadOf([], { keywords: { keys: ["n"] } })).value.keywords.keys,
    parsed(payloadOf([], { keywords: { keys: null } })).value.keywords.keys], [{}, {}, {}], "parse: non-object keys -> {}")
eq(parsed(payloadOf([], { keywords: { colors: JSON.parse("{\"__proto__\":\"#000000\"}") } })).value.keywords.colors.__proto__ === Object.prototype,
   true, "parse: __proto__ colour key ignored")
{
  const raw = payloadOf([sync]); delete raw.missing
  eq(parsed(raw).value.missing, [], "parse: missing defaults to []")
}
eq(parsed(payloadOf([], { missing: ["/a.org", 3, "/b.org"] })).value.missing, ["/a.org", "/b.org"], "parse: missing strings")
eq([parsed(payloadOf([], { error: "e".repeat(400) })).value.error.length, parsed(payloadOf([], { error: 3 })).value.error],
   [300, null], "parse: error bounded / non-string -> null")
eq(parsed(payloadOf([], { generatedAt: 5, reason: null, emacs: undefined, org: {} })).value,
   Object.assign(parsed(payloadOf([])).value, { generatedAt: "", reason: "", emacs: "", org: "" }), "parse: meta strings default to empty")
eq(parsed(payloadOf("nope")).value.items, [], "parse: non-array items -> []")

// ---------------------------------------------------------------- bounded

eq([M.bounded("abc", 5), M.bounded("abcdef", 4), M.bounded("Log weight ⚖️", 28), M.bounded("😀😀😀", 2)],
   ["abc", "abc…", "Log weight ⚖️", "😀…"], "bounded")

// ---------------------------------------------------------------- classify / sections

eq([habit, late, soon, sync, task].map(M.classify), ["habit", "overdue", "upcoming", "schedule", "today"], "classify: every branch")
eq(M.classify(item({ habit: true, time: "08:00" })), "habit", "classify: habit beats time")
eq(M.classify(item({ type: "upcoming-deadline", time: "08:00" })), "upcoming", "classify: upcoming beats time")
eq(M.sections(all, {}).map(s => [s.key, s.title, s.items.map(i => i.line)]),
   [["schedule", "Schedule", [63, 10]], ["today", "Today", [20, 60]], ["habits", "Habits", [30]],
    ["upcoming", "Coming up", [50]], ["overdue", "Overdue", [40]]], "sections: order, Org order kept")
eq(M.sections([task, soon], {}).map(s => s.key), ["today", "upcoming"], "sections: empty omitted")
eq(M.sections(all, { showDone: false })[1].items.map(i => i.line), [20], "sections: showDone false")
eq(M.sections([doneTask], { showDone: false }), [], "sections: all done hidden")
eq(M.sections([], {}), [], "sections: empty")

// A task scheduled on a later day. Org can date a repeat by its past base
// date, so a bad overdueDays mustn't make it overdue either.
const tomorrow = item({ line: 90, todo: "TODO", title: "Call the bank", time: "09:30", inDays: 1 })
const repeat = item({ line: 91, type: "past-scheduled", title: "Weekly review", inDays: 4, overdueDays: 3 })
eq([tomorrow, repeat, item({ inDays: 2, habit: true }), item({ type: "upcoming-deadline", inDays: 0 }),
    item({ type: "upcoming-deadline", inDays: 3, overdueDays: 2 })].map(M.classify),
   ["upcoming", "upcoming", "habit", "upcoming", "upcoming"], "classify: habit, then inDays/upcoming-deadline, then overdue")
eq(M.sections(all.concat([tomorrow, repeat]), {}).map(s => [s.key, s.items.map(i => i.line)]),
   [["schedule", [63, 10]], ["today", [20, 60]], ["habits", [30]], ["upcoming", [50, 90, 91]], ["overdue", [40]]],
   "sections: later-day tasks only under Coming up")
eq([M.nextUp([tomorrow], at(8, 0)), M.openToday([tomorrow, repeat]), M.overdueCount([repeat], { habitsInBadge: true })],
   [null, 0, 0], "later-day task: not next up, not open today, not overdue")
eq(M.view(payloadOf([tomorrow, repeat]), "ok", "", at(8, 0), {}).label,
   { mode: "clear", text: "", badge: 0, alert: false }, "later-day task: bar stays clear")

// Calendar-style entries on a later day: a timed timestamp, a date range.
const event = item({ line: 92, type: "timestamp", title: "Design review", time: "10:00", durationMin: 30, inDays: 1 })
const trip = item({ line: 93, type: "block", title: "Conference", inDays: 14, overdueDays: 1 })
eq([event, trip].map(M.classify), ["upcoming", "upcoming"], "classify: later-day timestamp and block -> upcoming")
eq(M.sections(all.concat([event, trip]), {}).map(s => [s.key, s.items.map(i => i.line)]),
   [["schedule", [63, 10]], ["today", [20, 60]], ["habits", [30]], ["upcoming", [50, 92, 93]], ["overdue", [40]]],
   "sections: later-day events only under Coming up")
eq([M.nextUp([event], at(8, 0)), M.openToday([event, trip]), M.overdueCount([event, trip], { habitsInBadge: true })],
   [null, 0, 0], "later-day event: not next up, not open today, not overdue")
eq(M.view(payloadOf([event, trip]), "ok", "", at(8, 0), {}).label,
   { mode: "clear", text: "", badge: 0, alert: false }, "later-day event: bar stays clear")
eq([event, trip].map(i => M.rowLead(i, M.payloadDay(payloadOf([])))),
   [{ text: "Wed", urgent: false }, { text: "27 Oct", urgent: false }], "rowLead: later-day events")
eq([event, trip].map(M.rowTrail), ["10:00 · cal", "cal"], "rowTrail: later-day events")
{
  const ups = [[1, 3], [2, 1], [3, 3], [4, 1], [5, 1], [6, 0], [7, 2]]
    .map(c => item({ line: c[0], type: c[1] ? "scheduled" : "upcoming-deadline", inDays: c[1] }))
  eq(M.sections(ups, {})[0].items.map(i => i.line), [6, 2, 4, 5, 7, 1, 3], "sections: Coming up by inDays, ties in Org order")
  const many = Array.from({ length: 40 }, (_, i) => item({ line: i + 1, inDays: 1 + (i % 3) }))
  const lines = M.sections(many, {})[0].items.map(i => i.line)
  eq([lines.slice(0, 4), lines.length, lines.every((l, k) => k === 0 || many[l - 1].inDays > many[lines[k - 1] - 1].inDays
                                                     || l > lines[k - 1])],
     [[1, 4, 7, 10], 40, true], "sections: stable on many ties")
  const timed = [item({ line: 1, time: "09:00" }), item({ line: 2, time: "08:00" })]
  eq(M.sections(timed, {})[0].items.map(i => i.line), [1, 2], "sections: other sections keep Org order")
}

// ---------------------------------------------------------------- counts

eq(M.openToday(all), 3, "openToday")
eq(M.openToday([doneTask, habit, late]), 0, "openToday: none")
eq(M.overdueCount(all, {}), 1, "overdueCount: habits excluded")
eq(M.overdueCount(all, { habitsInBadge: true }), 2, "overdueCount: habitsInBadge")
eq(M.overdueCount([item({ overdueDays: 2, done: true }), late], { habitsInBadge: true }), 1, "overdueCount: done excluded")

// ---------------------------------------------------------------- nextUp

eq(["13:00", "00:00", "23:59", "24:00", "9:00", "x", null].map(M.minutesOf), [780, 0, 1439, -1, -1, -1, -1], "minutesOf")
{
  const n = M.nextUp([sync], at(11, 13))
  eq([n.state, n.item.line, n.startMin, n.endMin], ["next", 63, 780, 810], "nextUp: before -> next")
}
eq(M.nextUp([sync], at(13, 0)).state, "now", "nextUp: at start -> now")
eq(M.nextUp([sync], at(13, 29)).state, "now", "nextUp: during -> now")
eq(M.nextUp([sync], at(13, 30)), null, "nextUp: at end -> null")
eq(M.nextUp([standup], at(9, 29)).state, "now", "nextUp: no duration stays now for 30 min")
eq(M.nextUp([standup], at(9, 30)), null, "nextUp: no duration ends after 30 min")
eq(M.nextUp(all, at(23, 0)), null, "nextUp: after all -> null")
eq(M.nextUp(all, at(8, 0)).item.line, 10, "nextUp: earliest start wins")
eq(M.nextUp([item({ time: "10:00", done: true }), item({ line: 2, time: "11:00" })], at(8, 0)).item.line, 2, "nextUp: done skipped")
eq(M.nextUp([item({ line: 1, time: "10:00" }), item({ line: 2, time: "10:00" })], at(8, 0)).item.line, 1, "nextUp: tie keeps Org order")
eq(M.nextUp([habit, late, task], at(8, 0)), null, "nextUp: only schedule class")
eq(M.nextUp([sync], new Date(NaN)), null, "nextUp: invalid now -> null")

// ---------------------------------------------------------------- settings

eq(M.normalizeSettings(null), { label: "Next item", maxTitleChars: 28, overdueBadge: true, habitsInBadge: false,
  showDone: true, pushUpdates: true, socketName: "", serverFile: "", emacsclient: "", agendaFiles: "",
  agendaKey: "a", emacsApp: "emacs", timeoutSeconds: 5, upcomingDays: 7 }, "normalizeSettings: defaults")
eq([-5, 0, 3, "12", 2.6, 99, "x", null, true].map(v => M.normalizeSettings({ upcomingDays: v }).upcomingDays),
   [0, 0, 3, 12, 3, 31, 7, 7, 7], "normalizeSettings: upcomingDays clamped to 0..31")
{
  const s = M.normalizeSettings({ label: "Bogus", maxTitleChars: 500, timeoutSeconds: 0, overdueBadge: "no",
    habitsInBadge: "yes", showDone: false, pushUpdates: false, socketName: "  work ", agendaKey: "  ", emacsApp: " " })
  eq([s.label, s.maxTitleChars, s.timeoutSeconds, s.overdueBadge, s.habitsInBadge, s.showDone, s.pushUpdates,
      s.socketName, s.agendaKey, s.emacsApp],
     ["Next item", 80, 1, true, false, false, false, "work", "a", "emacs"], "normalizeSettings: clamp, trim, bools")
}
eq([M.normalizeSettings({ maxTitleChars: 3 }).maxTitleChars, M.normalizeSettings({ maxTitleChars: "40" }).maxTitleChars,
    M.normalizeSettings({ timeoutSeconds: 99 }).timeoutSeconds, M.normalizeSettings({ timeoutSeconds: "x" }).timeoutSeconds,
    M.normalizeSettings({ label: "Count" }).label, M.normalizeSettings({ label: "Icon" }).label],
   [10, 40, 30, 5, "Count", "Icon"], "normalizeSettings: numbers and labels")

// ---------------------------------------------------------------- barLabel

const P = items => payloadOf(items)
const label = (items, status, settings, now) => M.view(P(items), status, "", now || at(11, 13), settings).label
const L = (mode, text, badge, alert) => ({ mode, text, badge, alert })

eq(M.view(P(all), "offline", "x", at(11, 13), {}).label, L("offline", "", 0, false), "barLabel: offline")
eq(M.view(P(all), "error", "x", at(11, 13), {}).label, L("error", "", 0, false), "barLabel: error status")
eq(M.view(payloadOf([], { error: "boom" }), "ok", "", at(11, 13), {}).label, L("error", "", 0, false), "barLabel: payload error")
eq(M.view(null, "loading", "", at(11, 13), {}).label, L("loading", "", 0, false), "barLabel: loading")
eq(label(all, "ok", { label: "Icon" }), L("icon", "", 0, true), "barLabel: icon with alert")
eq(label([sync], "ok", { label: "Icon" }), L("icon", "", 0, false), "barLabel: icon without alert")
eq(label(all, "ok", { label: "Count" }), L("count", "3", 1, true), "barLabel: count")
eq(label(all, "ok", { label: "Count", overdueBadge: false }), L("count", "3", 0, true), "barLabel: count, overdueBadge false")
eq(label(all, "ok", {}, at(13, 5)), L("now", "now Engineering Sync Up", 1, true), "barLabel: now")
eq(label(all, "ok", {}), L("next", "13:00 Engineering Sync Up", 1, true), "barLabel: next")
eq(label([sync], "ok", { maxTitleChars: 10 }), L("next", "13:00 Engineeri…", 0, false), "barLabel: title bounded")
// Past schedule entries still count as open today; only nextUp drops them.
eq(label(all, "ok", {}, at(20, 0)), L("today", "3 today", 1, true), "barLabel: today")
eq(label([task, late], "ok", {}), L("today", "1 today", 1, true), "barLabel: today, no schedule")
eq(label([late, doneTask], "ok", {}), L("icon", "", 1, true), "barLabel: overdue only -> icon")
eq(label([doneTask, soon], "ok", {}), L("clear", "", 0, false), "barLabel: clear")
eq(label(all, "ok", { overdueBadge: false }), L("next", "13:00 Engineering Sync Up", 0, true), "barLabel: overdueBadge false")
eq(label(all, "stale", {}), L("next", "13:00 Engineering Sync Up", 1, true), "barLabel: stale keeps label")

// ---------------------------------------------------------------- relTime / plain

eq([-3, 0, 5, 59, 60, 107, 120].map(M.relTime), ["now", "now", "in 5 min", "in 59 min", "in 1 h", "in 1 h 47 min", "in 2 h"], "relTime")
eq(M.plain("a<b>c\td\ne\u0000"), "a‹b›c d\ne ", "plain")
eq([M.plain(null), M.plain(3)], ["", "3"], "plain: non-strings")

// ---------------------------------------------------------------- tooltip

eq(M.view(P(all), "ok", "", at(11, 13), {}).tooltip,
   "Next 13:00 Engineering Sync Up · in 1 h 47 min\nToday 3 · Habits 1 · Overdue 1\nUpdated 11:13 from Emacs", "tooltip: next")
eq(M.view(P(all), "ok", "", at(13, 5), {}).tooltip.split("\n")[0], "Now Engineering Sync Up · until 13:30", "tooltip: now")
eq(M.view(P(all), "ok", "", at(11, 13), { label: "Icon" }).tooltip.split("\n")[0], "Next 13:00 · in 1 h 47 min", "tooltip: icon omits titles")
eq(M.view(P(all), "ok", "", at(13, 5), { label: "Icon" }).tooltip.split("\n")[0], "Now · until 13:30", "tooltip: icon now")
eq(M.view(P(all), "ok", "", at(20, 0), { habitsInBadge: true }).tooltip,
   "Today 3 · Habits 1 · Overdue 2\nUpdated 11:13 from Emacs", "tooltip: no next line, habitsInBadge")
eq(M.view(P(all), "stale", "", at(20, 0), {}).tooltip.split("\n").pop(), "Updated 11:13 from Emacs · stale", "tooltip: stale")
eq(M.view(payloadOf([], { missing: ["/a.org", "/b.org"] }), "ok", "", at(20, 0), {}).tooltip.split("\n").pop(),
   "Missing: 2 agenda file(s)", "tooltip: missing")
eq(M.view(null, "offline", "can't find <socket>", at(20, 0), {}).tooltip, "Emacs not reachable\ncan't find ‹socket›", "tooltip: offline")
eq(M.view(payloadOf([], { error: "void-function foo" }), "ok", "", at(20, 0), {}).tooltip,
   "Agenda export failed: void-function foo", "tooltip: export error")
{
  const t = M.view(P([item({ title: "<img src=x onerror=alert(1)>", time: "13:00" })]), "ok", "", at(11, 13), {}).tooltip
  eq([t.split("\n")[0], /[<>]/.test(t)], ["Next 13:00 ‹img src=x onerror=alert(1)› · in 1 h 47 min", false], "tooltip: markup neutralised")
}

// ---------------------------------------------------------------- elispString

eq(M.elispString("a\"b\\c"), "\"a\\\"b\\\\c\"", "elispString: escapes")
eq(M.elispString("Ünïcødé ⚖️ 😀"), "\"Ünïcødé ⚖️ 😀\"", "elispString: unicode")
eq(["a\nb", "a\u0000", "a\u007f", "\t", 3, null].map(s => throws(() => M.elispString(s))),
   [true, true, true, true, true, true], "elispString: control chars / non-strings throw")

// ---------------------------------------------------------------- forms

const PRE = "(unless (and (boundp 'omarchy-org-agenda--source-mtime) (equal omarchy-org-agenda--source-mtime" +
  " (file-attribute-modification-time (file-attributes \"" + ELISP + "\")))) (load \"" + ELISP + "\" nil t))"
eq(M.loadPreamble(ELISP), PRE, "loadPreamble")
eq(throws(() => M.loadPreamble("omarchy-org-agenda")), true, "loadPreamble: relative throws")
eq(M.pullForm(ELISP, OUT, { agendaFiles: "/home/u/org/a.org:/home/u/org/b.org" }, "save"),
   "(progn " + PRE + " (omarchy-org-agenda-ensure \"" + OUT + "\" (list \"/home/u/org/a.org\" \"/home/u/org/b.org\") t 7)" +
   " (omarchy-org-agenda-export \"save\"))", "pullForm: exact")
eq(M.pullForm(ELISP, OUT, { pushUpdates: false }, "pull").split(PRE)[1],
   " (omarchy-org-agenda-ensure \"" + OUT + "\" nil nil 7) (omarchy-org-agenda-export \"pull\"))", "pullForm: nil files, push nil")
eq([0, 12, "12", 99, -1, "x", "3) (shell-command \"rm\""].map(d =>
     / t (\S+)\) \(omarchy-org-agenda-export/.exec(M.pullForm(ELISP, OUT, { upcomingDays: d }, "pull"))[1]),
   ["0", "12", "12", "31", "0", "7", "7"], "pullForm: upcomingDays as a bare clamped integer")
eq(["Save", "a\"b", "x".repeat(21), undefined, "new-day"].map(r => /export "([^"]*)"/.exec(M.pullForm(ELISP, OUT, {}, r))[1]),
   ["pull", "pull", "pull", "pull", "new-day"], "pullForm: reason sanitised")
eq([throws(() => M.pullForm("x.el", OUT, {}, "pull")), throws(() => M.pullForm(ELISP, "out.json", {}, "pull")),
    throws(() => M.pullForm(ELISP, null, {}, "pull"))], [true, true, true], "pullForm: relative paths throw")

const gp = payloadOf([sync, item({ id: "abc-1", path: "/home/u/org/it's \"q\".org", line: 7 })])
eq(M.gotoForm(sync, gp, ELISP), "(progn " + PRE + " (omarchy-org-agenda-goto \"/home/u/org/cal.org\" 63 nil))", "gotoForm: exact")
eq(M.gotoForm(gp.items[1], gp, ELISP).split(PRE)[1],
   " (omarchy-org-agenda-goto \"/home/u/org/it's \\\"q\\\".org\" 7 \"abc-1\"))", "gotoForm: quote escaped, id kept")
eq([throws(() => M.gotoForm(item({ path: "/etc/passwd", line: 63 }), gp, ELISP)),
    throws(() => M.gotoForm(item({ path: "/home/u/org/cal.org", line: 64 }), gp, ELISP)),
    throws(() => M.gotoForm(item({ path: "/home/u/org/cal.org", line: "63" }), gp, ELISP)),
    throws(() => M.gotoForm(sync, null, ELISP)),
    throws(() => M.gotoForm(null, gp, ELISP))], [true, true, true, true, true], "gotoForm: unknown path/line throws")
eq(/ 63 (\S+)\)\)$/.exec(M.gotoForm(Object.assign({}, sync, { id: "bad id" }), gp, ELISP))[1], "nil", "gotoForm: bad id -> nil")
{
  const f = M.gotoForm(Object.assign({}, sync, { id: "x\") (shell-command \"rm\")" }), gp, ELISP)
  eq([/ 63 nil\)\)$/.test(f), f.indexOf("shell-command")], [true, -1], "gotoForm: id injection -> nil")
}
eq(M.agendaForm("t", ELISP), "(progn " + PRE + " (omarchy-org-agenda-open-agenda \"t\"))", "agendaForm: exact")
eq(["ab12", "", "abcde", "a\"", null].map(k => /agenda "([^"]*)"/.exec(M.agendaForm(k, ELISP))[1]),
   ["ab12", "a", "a", "a", "a"], "agendaForm: key sanitised")
eq(M.fallbackOpenArgs({ socketName: "work" }, sync, gp),
   ["emacsclient", "-s", "work", "-w", "5", "-r", "-n", "+63", "/home/u/org/cal.org"], "fallbackOpenArgs")
eq(throws(() => M.fallbackOpenArgs({}, item({ path: "/etc/passwd", line: 1 }), gp)), true, "fallbackOpenArgs: unknown item throws")

// ---------------------------------------------------------------- state change

const KW = { todo: ["NEXT", "TODO", "REPEAT"], done: ["DONE", "CANCELED"],
             colors: { NEXT: "#fb4934", DONE: "#98971a" }, keys: { NEXT: "n", TODO: "t", DONE: "d", CANCELED: "c" } }
const sp = payloadOf([task, late, sync, item({ line: 70, type: "sexp", title: "Ana is 36" }),
                      item({ line: 80, id: "e-1", todo: "TODO", title: "With id" })], { keywords: KW })
eq(M.stateChoices(sp), [
  { keyword: "NEXT", key: "n", color: "#fb4934", done: false }, { keyword: "TODO", key: "t", color: "", done: false },
  { keyword: "REPEAT", key: "", color: "", done: false }, { keyword: "DONE", key: "d", color: "#98971a", done: true },
  { keyword: "CANCELED", key: "c", color: "", done: true }], "stateChoices: todo then done, keys and colours")
eq(M.stateChoices(payloadOf([], { keywords: { todo: ["NEXT"], done: ["DONE"], colors: {} } })).map(c => c.key),
   ["", ""], "stateChoices: payload without keys")
eq([M.stateChoices(null), M.stateChoices({}), M.stateChoices(payloadOf([], { keywords: null }))], [[], [], []],
   "stateChoices: no keywords")
eq(M.stateChoices(payloadOf([], { keywords: { todo: ["A B", "C\"", "(x)", "D", "D", "x".repeat(33), 5, "Ș"],
                                               done: ["D", "E\\", "F"], keys: { D: "dd", F: "f" } } }))
     .map(c => [c.keyword, c.key, c.done]),
   [["D", "", false], ["Ș", "", false], ["F", "f", true]], "stateChoices: unsafe keywords and duplicates dropped")
eq(M.ITEM_TYPES.indexOf("sexp") >= 0, true, "ITEM_TYPES has sexp")
eq([task, sync, item({ type: "sexp" }), item({ type: "block" }), item({ type: "other" }),
    item({ path: "rel.org" }), item({ line: 0 }), item({ line: 1.5 }), null, {}].map(M.canChangeState),
   [true, true, false, true, true, false, false, false, false, false], "canChangeState")

eq(M.stateForm(task, sp, "DONE", ELISP),
   "(progn " + PRE + " (omarchy-org-agenda-set-state \"/home/u/org/cal.org\" 20 nil \"TODO\" \"DONE\"))", "stateForm: exact")
eq(M.stateForm(sync, sp, "NEXT", ELISP).split(PRE)[1],
   " (omarchy-org-agenda-set-state \"/home/u/org/cal.org\" 63 nil nil \"NEXT\"))", "stateForm: no keyword -> FROM nil")
eq(M.stateForm(sp.items[4], sp, "REPEAT", ELISP).split(PRE)[1],
   " (omarchy-org-agenda-set-state \"/home/u/org/cal.org\" 80 \"e-1\" \"TODO\" \"REPEAT\"))", "stateForm: id kept")
eq(M.stateForm(Object.assign({}, task, { id: "x\") (shell-command \"rm\")" }), sp, "DONE", ELISP).indexOf("shell-command"),
   -1, "stateForm: id injection -> nil")
{
  const qp = payloadOf([item({ path: "/home/u/org/it's \"q\".org", line: 7, todo: "NEXT" })], { keywords: KW })
  eq(M.stateForm(qp.items[0], qp, "DONE", ELISP).split(PRE)[1],
     " (omarchy-org-agenda-set-state \"/home/u/org/it's \\\"q\\\".org\" 7 nil \"NEXT\" \"DONE\"))", "stateForm: path escaped")
}
eq([throws(() => M.stateForm(task, sp, "WAIT", ELISP)),
    throws(() => M.stateForm(task, sp, "DONE\" (shell-command \"x\") \"", ELISP)),
    throws(() => M.stateForm(task, sp, null, ELISP)),
    throws(() => M.stateForm(Object.assign({}, task, { todo: "BOGUS" }), sp, "DONE", ELISP)),
    throws(() => M.stateForm(Object.assign({}, task, { todo: "TO DO" }), sp, "DONE", ELISP)),
    throws(() => M.stateForm(sp.items[3], sp, "DONE", ELISP)),
    throws(() => M.stateForm(item({ line: 21 }), sp, "DONE", ELISP)),
    throws(() => M.stateForm(item({ path: "/etc/passwd", line: 20 }), sp, "DONE", ELISP)),
    throws(() => M.stateForm(task, null, "DONE", ELISP)),
    throws(() => M.stateForm(task, sp, "DONE", "rel.el"))],
   [true, true, true, true, true, true, true, true, true, true], "stateForm: throws on anything invalid")
eq(M.takeNoteForm(ELISP), "(progn " + PRE + " (omarchy-org-agenda-take-note))", "takeNoteForm")
eq(throws(() => M.takeNoteForm("x.el")), true, "takeNoteForm: relative throws")

// Real `emacsclient --eval' stdout of omarchy-org-agenda-set-state (Emacs 31.1;
// 29.4 and 30.1 print the same bytes): prin1 of an ASCII-only JSON string.
const OUT_DONE = "\"{\\\"result\\\":\\\"done\\\",\\\"state\\\":\\\"DONE\\\",\\\"saved\\\":true,\\\"detail\\\":null}\"\n"
const OUT_BLOCKED = "\"{\\\"result\\\":\\\"blocked\\\",\\\"state\\\":null,\\\"saved\\\":false,\\\"detail\\\":" +
  "\\\"TODO \\\\u0218edin\\\\u021b\\\\u0103 \\\\\\\"copil\\\\\\\" (x)\\\"}\"\n"
const OUT_NOTE = "\"{\\\"result\\\":\\\"note-frame\\\",\\\"state\\\":\\\"WAIT\\\",\\\"saved\\\":false,\\\"detail\\\":null}\"\n"
const OUT_CHANGED = "\"{\\\"result\\\":\\\"changed\\\",\\\"state\\\":null,\\\"saved\\\":false,\\\"detail\\\":null}\"\n"
eq(M.parseStateResult(OUT_DONE), { ok: true, value: { result: "done", state: "DONE", saved: true, detail: null } },
   "parseStateResult: real done")
eq(M.parseStateResult(OUT_BLOCKED).value, { result: "blocked", state: null, saved: false, detail: "TODO Ședință \"copil\" (x)" },
   "parseStateResult: real blocked, unicode and quotes")
eq(M.parseStateResult(OUT_NOTE).value, { result: "note-frame", state: "WAIT", saved: false, detail: null },
   "parseStateResult: real note-frame")
eq(M.parseStateResult(OUT_CHANGED).value.result, "changed", "parseStateResult: real changed")
eq(M.parseStateResult("\"{\\\"result\\\":\\\"blocked\\\",\\\"detail\\\":\\\"Ședință\\\"}\"").value.detail, "Ședință",
   "parseStateResult: raw non-ASCII passes through")
eq(M.parseStateResult("{\"result\":\"busy\"}").value, { result: "busy", state: null, saved: false, detail: null },
   "parseStateResult: bare JSON accepted")
{
  const big = M.parseStateResult(JSON.stringify(JSON.stringify({ result: "error", detail: "a\tb\n" + "x".repeat(500) }))).value
  eq([big.detail.slice(0, 5), Array.from(big.detail).length], ["a b x", 200], "parseStateResult: detail cleaned and bounded")
}
eq([M.parseStateResult(JSON.stringify(JSON.stringify({ result: "done", state: "BAD STATE", saved: "yes", detail: 3 }))).value],
   [{ result: "done", state: null, saved: false, detail: null }], "parseStateResult: bad fields -> defaults")
eq(["", null, undefined, "t\n", "nil\n", "\"{\\\"result\\\":\\\"maybe\\\"}\"", "\"not json\"", "\"[1]\"", "\"\\\"x\\\"\"",
    "\"{\\\"result\\\":\\\"done\\\"}", "\"a\"b\"", "\"\\q\"", "*ERROR*: boom"].map(s => M.parseStateResult(s).ok),
   [false, false, false, false, false, false, false, false, false, false, false, false, false],
   "parseStateResult: malformed or unknown -> not ok")
eq(M.parseStateResult("\"{\\\"result\\\":\\\"done\\\"}\"").ok, true, "parseStateResult: minimal")

{
  const msg = (v, kw) => M.stateMessage(Object.assign({ state: null, saved: false, detail: null }, v), kw)
  eq([msg({ result: "done", state: "DONE", saved: true }, "DONE"),
      msg({ result: "done", state: "DONE" }, "DONE"),
      msg({ result: "done", state: "DONE", detail: "Permission denied" }, "DONE"),
      msg({ result: "done", state: "NEXT", saved: true }, "DONE"),
      msg({ result: "note", state: "DONE" }, "DONE"),
      msg({ result: "note-frame", state: "DONE" }, "DONE"),
      msg({ result: "blocked", detail: "TODO Child" }, "DONE"),
      msg({ result: "blocked" }, "DONE"),
      msg({ result: "changed" }, "DONE"),
      msg({ result: "conflict" }, "DONE"),
      msg({ result: "busy" }, "DONE"),
      msg({ result: "invalid", detail: "NOPE isn't a keyword of this file" }, "NOPE"),
      msg({ result: "error", detail: "boom" }, "DONE"),
      msg({ result: "weird" }, "DONE")],
     [{ text: "Marked DONE · saved", tone: "ok" },
      { text: "Marked DONE · not saved: the file had unsaved edits in Emacs", tone: "warn" },
      { text: "Marked DONE · not saved: Permission denied", tone: "warn" },
      { text: "Marked DONE · repeats as NEXT · saved", tone: "ok" },
      { text: "Marked DONE · add your note in Emacs", tone: "ok" },
      { text: "Marked DONE · opening Emacs for your note", tone: "ok" },
      { text: "Org blocked this: “TODO Child” isn't done yet", tone: "warn" },
      { text: "Org blocked this: its checkboxes or dependencies aren't done yet", tone: "warn" },
      { text: "This entry changed in Emacs. The agenda is refreshing; try again.", tone: "warn" },
      { text: "The file changed on disk and has unsaved edits in Emacs. Resolve it there first.", tone: "error" },
      { text: "Emacs is waiting for another note. Finish it first.", tone: "warn" },
      { text: "Emacs refused NOPE: NOPE isn't a keyword of this file", tone: "error" },
      { text: "Couldn't change the state: boom", tone: "error" },
      { text: "Couldn't change the state: unexpected answer from Emacs", tone: "error" }], "stateMessage: every result")
  eq(msg({ result: "blocked", detail: "<b>x</b>\n" + "y".repeat(300) }, "DONE").text.indexOf("<"), -1,
     "stateMessage: markup neutralised")
  eq(Array.from(msg({ result: "error", detail: "y".repeat(400) }, "DONE").text).length <= 300, true, "stateMessage: bounded")
  eq([M.stateMessage(null, null).tone, msg({ result: "done", saved: true }, "A B\"").text],
     ["error", "Marked the new state · saved"], "stateMessage: bad input")
}

eq([M.entryKey(task), M.entryKey(item({ line: 80, type: "deadline" })), M.entryKey(null),
    M.entryKey({ path: "/a.org" }), M.entryKey({ path: 3, line: 1 })],
   ["/home/u/org/cal.org:20", "/home/u/org/cal.org:80", "", "", ""], "entryKey: path:line or empty")

eq(M.pickerHint(M.stateChoices(sp), "R"), "n t d c set · ←→ R set · ↑↓ leave · esc cancel",
   "pickerHint: t is a fast key, so only esc cancels")
eq(M.pickerHint([{ key: "n" }, { key: "" }, { key: "d" }], "R"), "n d set · ←→ R set · ↑↓ leave · esc/t cancel",
   "pickerHint: t cancels when no keyword uses it")
eq([M.pickerHint([], "R"), M.pickerHint(null), M.pickerHint([{ key: "xy" }, null, { key: "<" }], "R")],
   ["←→ R set · ↑↓ leave · esc/t cancel", "←→ ↵ set · ↑↓ leave · esc/t cancel",
    "←→ R set · ↑↓ leave · esc/t cancel"], "pickerHint: no fast keys, bad input")

// ---------------------------------------------------------------- clientArgs / socket / files

eq(M.clientArgs({}), ["emacsclient", "-w", "5"], "clientArgs: default")
eq(M.clientArgs({ socketName: "work" }), ["emacsclient", "-s", "work", "-w", "5"], "clientArgs: socketName")
eq(M.clientArgs({ socketName: "work", serverFile: "/tmp/srv" }), ["emacsclient", "-f", "/tmp/srv", "-w", "5"], "clientArgs: serverFile wins")
eq(M.clientArgs({ emacsclient: " /opt/bin/emacsclient ", timeoutSeconds: 100 }), ["/opt/bin/emacsclient", "-w", "30"], "clientArgs: binary, timeout clamped")
eq(M.clientArgs(null), ["emacsclient", "-w", "5"], "clientArgs: null settings")
eq([M.socketKey({}), M.socketKey({ socketName: "work" }), M.socketKey({ serverFile: "/tmp/a b/srv", socketName: "w" }),
    M.socketKey({ socketName: "x".repeat(200) }).length],
   ["server", "s-work", "f-_tmp_a_b_srv", 82], "socketKey")
eq(M.outputDir("/run/user/1000", "/home/u/.c", "/home/u"), "/run/user/1000/omarchy-org-agenda", "outputDir: runtime dir wins")
eq(M.outputDir("run/user/1000", "/home/u/.c", "/home/u"), "/home/u/.c/omarchy-org-agenda", "outputDir: relative runtime dir ignored")
eq(M.outputDir("", "/home/u/.c", "/home/u"), "/home/u/.c/omarchy-org-agenda", "outputDir: cache home fallback")
eq([M.outputDir(undefined, undefined, "/home/u"), M.outputDir(null, ".cache", "/home/u")],
   ["/home/u/.cache/omarchy-org-agenda", "/home/u/.cache/omarchy-org-agenda"], "outputDir: home fallback")
eq([M.outputDir("/run/user/1000/", null, null), M.outputDir(null, "/c//", null), M.outputDir(null, null, "/home/u/")],
   ["/run/user/1000/omarchy-org-agenda", "/c/omarchy-org-agenda", "/home/u/.cache/omarchy-org-agenda"], "outputDir: trailing slash")
eq([M.outputDir(), M.outputDir(null, null, null), M.outputDir("", "", ""), M.outputDir("tmp", "c", "home"),
    M.outputDir(1, {}, ["/x"]), M.outputDir("/run/\u0001", null, null)],
   ["", "", "", "", "", ""], "outputDir: none, never /tmp")
eq(M.agendaFilesList({ agendaFiles: " /a.org : :/b.org::/c\u0001.org:" + "/" + "x".repeat(1100) }), ["/a.org", "/b.org"], "agendaFilesList")
eq(M.agendaFilesList({ agendaFiles: Array.from({ length: 60 }, (_, i) => "/f" + i).join(":") }).length, 50, "agendaFilesList: capped at 50")
eq(M.agendaFilesList({}), [], "agendaFilesList: empty")
eq([M.filesForm([]), M.filesForm(["/a.org", "/b \"c\".org"])], ["nil", "(list \"/a.org\" \"/b \\\"c\\\".org\")"], "filesForm")

// ---------------------------------------------------------------- status helpers

eq(["emacsclient: can't find socket; have you started the server?",
    "emacsclient: error accessing socket \"/run/user/1000/emacs/server\"",
    "emacsclient: error accessing server file \"/x\"",
    "emacsclient: connect: Connection refused",
    "emacsclient: No such file or directory",
    "*ERROR*: Symbol's function definition is void: foo", "", null].map(M.isNoServer),
   [true, true, true, true, true, false, false, false], "isNoServer")
eq([0, 1, 2, 3, 4, 5, 6].map(M.backoffMs), [15000, 30000, 60000, 120000, 240000, 300000, 300000], "backoffMs")
eq([M.backoffMs(-1), M.backoffMs(1000)], [15000, 300000], "backoffMs: bounds")
eq([M.dateKey(at(0, 0)), M.dateKey(new Date(2026, 0, 5, 23, 59))], ["2026-10-13", "2026-01-05"], "dateKey")
eq([M.isNewDay(P([]), at(23, 59)), M.isNewDay(P([]), new Date(2026, 9, 14, 0, 0)), M.isNewDay(null, at(1, 0))],
   [false, true, false], "isNewDay")
// 11:13:04+0300 is 11:13:04 local in Bucharest.
eq([M.isOld(P([]), new Date(2026, 9, 13, 11, 13, 30)), M.isOld(P([]), new Date(2026, 9, 13, 11, 14, 4)),
    M.isOld(P([]), new Date(2026, 9, 13, 11, 14, 5)), M.isOld(null, at(11, 13)),
    M.isOld(payloadOf([], { generatedAt: "garbage" }), at(11, 13)),
    M.isOld(payloadOf([], { generatedAt: "2026-10-13T08:13:04Z" }), new Date(2026, 9, 13, 11, 13, 30)),
    M.isOld(payloadOf([], { generatedAt: "2026-10-13T11:13:04+03:00" }), new Date(2026, 9, 13, 11, 13, 30))],
   [false, false, true, true, true, false, false], "isOld")
eq([M.keywordColor(P([]), "NEXT"), M.keywordColor(P([]), "TODO"), M.keywordColor(null, "NEXT"),
    M.keywordColor(P([]), "toString"), M.keywordColor(payloadOf([], { keywords: {} }), "NEXT")],
   ["#fb4934", "", "", "", ""], "keywordColor")

// ---------------------------------------------------------------- view

{
  const results = ["loading", "ok", "offline", "error", "stale", "bogus", undefined].map(st => {
    try {
      const v = M.view(null, st, null, at(11, 13), undefined)
      return [v.status, v.stale, v.items.length, v.sections.length, v.next, v.openToday, v.overdue, v.updated, v.label.mode]
    } catch (e) { return "threw: " + e.message }
  })
  eq(results, [["loading", false, 0, 0, null, 0, 0, "", "loading"], ["ok", false, 0, 0, null, 0, 0, "", "loading"],
               ["offline", false, 0, 0, null, 0, 0, "", "offline"], ["error", false, 0, 0, null, 0, 0, "", "error"],
               ["stale", true, 0, 0, null, 0, 0, "", "loading"], ["loading", false, 0, 0, null, 0, 0, "", "loading"],
               ["loading", false, 0, 0, null, 0, 0, "", "loading"]], "view: null payload, every status")
}
{
  const v = M.view(P(all), "ok", "", at(11, 13), { label: "Count" })
  eq([v.status, v.stale, v.items.length, v.sections.length, v.next.item.line, v.openToday, v.overdue, v.updated, v.label.text, v.settings.label],
     ["ok", false, 7, 5, 63, 3, 1, "11:13", "3", "Count"], "view: populated")
}
eq(typeof M.view(null, "ok", null, new Date(NaN), null).tooltip, "string", "view: invalid now does not throw")
// ---------------------------------------------------------------- popout

eq([M.basename("/home/u/org/work.org"), M.basename("work.org"), M.basename(null)],
   ["work.org", "work.org", ""], "basename")
eq([sync, soon, item({ type: "deadline" }), task].map(M.isDeadline), [false, true, true, false], "isDeadline")
eq([sync, late, habit, soon, task, item({ habit: true, time: "07:00" })].map(M.rowLead),
   [{ text: "13:00", urgent: false }, { text: "3d", urgent: true }, { text: "", urgent: false },
    { text: "", urgent: false }, { text: "", urgent: false }, { text: "07:00", urgent: false }], "rowLead")
{
  // 2026-10-28 is a Wednesday; the week runs into November.
  const wed = new Date(2026, 9, 28)
  const lead = (d, today) => M.rowLead(item({ inDays: d }), today).text
  eq([1, 4, 6, 7, 30].map(d => lead(d, wed)), ["Thu", "Sun", "Tue", "4 Nov", "27 Nov"], "rowLead: weekday, then d MMM, across a month")
  eq([lead(3, new Date(2026, 11, 30)), lead(7, new Date(2026, 11, 30))], ["Sat", "6 Jan"], "rowLead: across a year")
  eq(M.rowLead(item({ inDays: 14 }), M.payloadDay(P([]))), { text: "27 Oct", urgent: false }, "rowLead: from the payload's day")
  eq([lead(3, null), lead(3, new Date(NaN))], ["+3d", "+3d"], "rowLead: no day -> +Nd")
  eq([M.rowLead(item({ type: "upcoming-deadline", inDays: 2 }), wed).text, M.rowLead(soon, wed).text],
     ["Fri", ""], "rowLead: upcoming deadline; old payload without inDays -> blank")
  eq(M.rowLead(repeat, wed), { text: "Sun", urgent: false }, "rowLead: later-day repeat isn't urgent")
}
eq([M.payloadDay(P([])).getTime(), M.payloadDay(null), M.payloadDay({ date: "13 Oct" })],
   [new Date(2026, 9, 13).getTime(), null, null], "payloadDay")
eq([sync, habit, item({ habit: true }), item({ category: null })].map(M.rowTrail),
   ["cal", "2d", "cal", ""], "rowTrail: category, missed days")
eq([tomorrow, Object.assign({}, tomorrow, { category: null }), item({ inDays: 2 }), sync].map(M.rowTrail),
   ["09:30 · cal", "09:30", "cal", "cal"], "rowTrail: a coming-up time goes before the category")
eq(M.rowLocation(sync), "cal.org:63", "rowLocation")
eq(["habits", "overdue", "today"].map(M.sectionHint), ["missed days", "", ""], "sectionHint")
{
  const v = M.view(P(all), "ok", "", at(11, 13), {})
  eq(M.nextMeta(v.next, v.nowMin), "13:00 · in 1 h 47 min · cal", "nextMeta: next")
  const n = M.view(P(all), "ok", "", at(13, 10), {})
  eq(M.nextMeta(n.next, n.nowMin), "13:00–13:30 · until 13:30 · cal", "nextMeta: now")
  eq(M.footerLine(v), "Updated 11:13 · save · Emacs 31.1 · Org 9.8.7", "footerLine")
  eq(M.footerLine(M.view(P(all), "stale", "", at(11, 13), {})), "Updated 11:13 · save · Emacs 31.1 · Org 9.8.7 · stale",
     "footerLine: stale")
  eq(M.footerLine(M.view(null, "ok", "", at(11, 13), {})), "", "footerLine: no payload")
}
eq([M.view(null, "offline", "", at(11, 13), {}), M.view(P(all), "offline", "", at(11, 13), {}),
    M.view(null, "error", "boom", at(11, 13), {}), M.view(payloadOf([], { error: "bad" }), "ok", "", at(11, 13), {}),
    M.view(null, "loading", "", at(11, 13), {}), M.view(P([]), "ok", "", at(11, 13), {}),
    M.view(P(all), "stale", "", at(11, 13), {})].map(M.panelMode),
   ["offline", "offline", "error", "error", "loading", "empty", "agenda"], "panelMode")
eq([M.errorMessage(M.view(payloadOf([], { error: "bad" }), "ok", "x", at(11, 13), {})),
    M.errorMessage(M.view(null, "error", "boom", at(11, 13), {})),
    M.errorMessage(M.view(null, "error", "", at(11, 13), {}))], ["bad", "boom", "unknown error"], "errorMessage")
{
  const v = M.view(P(all), "ok", "", at(11, 13), {})
  const before = M.panelModel(v)
  // A refresh after the habit was done: its row is gone, the rows below it move up.
  const after = M.panelModel(M.view(P(all.filter(i => i !== habit)), "ok", "", at(11, 13), {}))
  eq(before.sections.map(s => [s.key, s.count, s.rows.length, s.hint]),
     [["schedule", 2, 2, ""], ["today", 2, 2, ""], ["habits", 1, 1, "missed days"],
      ["upcoming", 1, 1, ""], ["overdue", 1, 1, ""]], "panelModel: sections")
  eq(before.rows.map(r => [r.sel, r.item.line]),
     [[0, 63], [1, 63], [2, 10], [3, 20], [4, 60], [5, 30], [6, 50], [7, 40]],
     "panelModel: next card first, then every section's rows, overdue included")
  eq([before.next.key, before.rows[7].key], ["next", "overdue:/home/u/org/cal.org:40:scheduled"], "panelModel: keys")
  eq(M.panelModel(M.view(P([task]), "ok", "", at(11, 13), {})).rows.map(r => r.sel), [0], "panelModel: no next")
  const keys = m => m.rows.map(r => r.key)
  eq([M.refocus(keys(before), keys(after), 5), M.refocus(keys(before), keys(after), 6),
      M.refocus(keys(before), keys(after), 7),
      M.refocus(keys(after), keys(before), 6), M.refocus(keys(after), keys(before), 3),
      M.refocus([], keys(before), 0), M.refocus(keys(before), [], 3), M.refocus(["gone"], ["a", "b"], 5)],
     [4, 5, 6, 7, 3, 0, 0, 1], "refocus: keeps the entry or the one above")
}

eq([M.PROTOCOL, M.MAX_ITEMS, M.MAX_TITLE, M.NOW_GRACE_MIN, M.STALE_AFTER_MS, M.ID_RE.test("a:b")],
   [1, 200, 200, 30, 60000, true], "constants")

console.log((failed ? "FAIL " : "ok   ") + (count - failed) + "/" + count + " passed")
process.exit(failed ? 1 : 0)
