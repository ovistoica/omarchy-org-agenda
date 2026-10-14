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
  " panelMode, errorMessage, refocus, stateChoices, canChangeState, stateForm," +
  " takeNoteForm, parseStateResult, stateMessage, entryKey, pickerHint, ITEM_TYPES, payloadDay," +
  " weekForm, parseWeekResult, elispStringValue, LAYOUTS, MAX_WEEK_OFFSET, pullKey, nextLayout," +
  " orgCategory, orgLeader, orgWhen, orgDayTitle, isoWeek, compactDayTitle, browseOffset, weekNav," +
  " weekWanted, layoutModel, paneSel, tabStep, tabAt, overdueFocus, overdueUi, layoutHints, keyAction," +
  " payloadFor, timerState, pomodoroStep, clockInForm, clockOutForm, clockCancelForm, clockGotoForm," +
  " pomodoroForm, parseActionResult, actionMessage, clockFallbackArgs }")()

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
  // Signed since 0.3: a past week's rows lie before today.
  eq(parsedItems([4, -1, 1.5, "3", null, 0, -3660, 3660, -3661, 3661, NaN].map(d => item({ inDays: d })))
       .map(i => i.inDays),
     [4, -1, 0, 0, 0, 0, -3660, 3660, 0, 0, 0], "parse: inDays validated, signed, bounded")
}
{
  // A negative inDays reads like the 0 it was clamped to before 0.3:
  // never "upcoming", and the bar's counts and next-up don't move.
  const past = [item({ line: 70, title: "Past task", inDays: -5 }),
                item({ line: 71, title: "Past meeting", time: "11:30", durationMin: 30, inDays: -3 }),
                item({ line: 72, type: "deadline", title: "Past deadline", inDays: -2 }),
                item({ line: 73, type: "past-scheduled", title: "Past repeat", inDays: -1 })]
  const zeroed = past.map(i => Object.assign({}, i, { inDays: 0 }))
  const neg = parsedItems(past), zero = parsedItems(zeroed)
  eq(neg.map(i => i.inDays), [-5, -3, -2, -1], "parse: negative inDays kept")
  eq(neg.map(M.classify), zero.map(M.classify), "classify: negative inDays like 0")
  eq(neg.map(M.classify).indexOf("upcoming"), -1, "classify: negative inDays never upcoming")
  const nextOf = items => { const n = M.nextUp(items, at(11, 0)); return n && [n.item.line, n.state, n.startMin, n.endMin] }
  const counts = items => [M.openToday(items), M.overdueCount(items, {}), M.overdueCount(items, { habitsInBadge: true }),
                           nextOf(items)]
  const main = parsedItems(all)
  eq(counts(main.concat(neg)), counts(main.concat(zero)), "counts/nextUp: negative inDays like 0")
  eq(counts(main).slice(0, 3), [3, 1, 2], "counts: main payload unchanged")
  eq([M.nextUp(main.concat(neg), at(11, 0)).item.title, M.nextUp(main.concat(neg), at(11, 0)).state],
     ["Past meeting", "next"], "nextUp: a negative-inDays timed row counts as today's, as when clamped to 0")
}
{
  const week = { weekOffset: 1, weekStart: "2026-10-19", startInDays: 5 }
  const fields = v => [v.weekOffset, v.weekStart, v.startInDays]
  eq(fields(parsed(payloadOf([])).value), [null, null, null], "parse: no week fields in the bar's file -> null")
  eq(fields(parsed(payloadOf([], week)).value), [1, "2026-10-19", 5], "parse: week fields")
  eq(fields(parsed(payloadOf([], { weekOffset: -52, weekStart: "2025-10-13", startInDays: -400 })).value),
     [-52, "2025-10-13", -400], "parse: week fields at their bounds")
  eq([{ weekOffset: 53, weekStart: "2026-10-19 Mon", startInDays: 401 },
      { weekOffset: -53, weekStart: 20261019, startInDays: -401 },
      { weekOffset: 1.5, weekStart: "", startInDays: "5" },
      { weekOffset: "1", weekStart: null, startInDays: 2.5 }].map(w => fields(parsed(payloadOf([], w)).value)),
     [[null, null, null], [null, null, null], [null, null, null], [null, null, null]], "parse: bad week fields -> null")
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
eq(parsed(payloadOf([])).value.daysAhead, 0, "parse: payload without daysAhead (pre-0.3) -> 0")
eq([0, 4, 6, 31].map(d => parsed(payloadOf([], { daysAhead: d })).value.daysAhead), [0, 4, 6, 31],
   "parse: daysAhead kept")
eq([-1, 2.5, 32, 1e9, Number.MAX_SAFE_INTEGER + 2, "4", null, true].map(d =>
     parsed(payloadOf([], { daysAhead: d })).value.daysAhead),
   [0, 0, 31, 31, 0, 0, 0, 0], "parse: daysAhead negative/float/string -> 0, huge clamped to 31")

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
   { mode: "clear", text: "", badge: 0, alert: false, timer: null }, "later-day task: bar stays clear")

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
   { mode: "clear", text: "", badge: 0, alert: false, timer: null }, "later-day event: bar stays clear")
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

eq(M.normalizeSettings(null), { label: "Next item", layout: "Org", maxTitleChars: 28, overdueBadge: true, habitsInBadge: false,
  showDone: true, pushUpdates: true, socketName: "", serverFile: "", emacsclient: "", agendaFiles: "",
  agendaKey: "a", emacsApp: "emacs", timeoutSeconds: 5 }, "normalizeSettings: defaults")
eq(M.normalizeSettings({ upcomingDays: 3 }), M.normalizeSettings({}),
   "normalizeSettings: an old upcomingDays setting is ignored")
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
const L = (mode, text, badge, alert, timer) => ({ mode, text, badge, alert, timer: timer || null })

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
   "(progn " + PRE + " (omarchy-org-agenda-ensure \"" + OUT + "\" (list \"/home/u/org/a.org\" \"/home/u/org/b.org\") t)" +
   " (omarchy-org-agenda-export \"save\"))", "pullForm: exact")
eq(M.pullForm(ELISP, OUT, { pushUpdates: false }, "pull").split(PRE)[1],
   " (omarchy-org-agenda-ensure \"" + OUT + "\" nil nil) (omarchy-org-agenda-export \"pull\"))", "pullForm: nil files, push nil")
eq([7, "3) (shell-command \"rm\""].map(d => M.pullForm(ELISP, OUT, { upcomingDays: d }, "pull").split(PRE)[1]),
   [" (omarchy-org-agenda-ensure \"" + OUT + "\" nil t) (omarchy-org-agenda-export \"pull\"))",
    " (omarchy-org-agenda-ensure \"" + OUT + "\" nil t) (omarchy-org-agenda-export \"pull\"))"],
   "pullForm: ensure takes 3 args, an old upcomingDays setting is ignored")
eq(["Save", "a\"b", "x".repeat(21), undefined, "new-day"].map(r => /export "([^"]*)"/.exec(M.pullForm(ELISP, OUT, {}, r))[1]),
   ["pull", "pull", "pull", "pull", "new-day"], "pullForm: reason sanitised")
eq([throws(() => M.pullForm("x.el", OUT, {}, "pull")), throws(() => M.pullForm(ELISP, "out.json", {}, "pull")),
    throws(() => M.pullForm(ELISP, null, {}, "pull"))], [true, true, true], "pullForm: relative paths throw")

{
  const ENSURE = " (omarchy-org-agenda-ensure \"" + OUT + "\" nil t)"
  eq(M.weekForm(ELISP, OUT, {}, 1), "(progn " + PRE + ENSURE + " (omarchy-org-agenda-week 1))", "weekForm: exact, next week")
  eq(M.weekForm(ELISP, OUT, {}, -1), "(progn " + PRE + ENSURE + " (omarchy-org-agenda-week -1))", "weekForm: exact, last week")
  eq([99, -99, 52, 0].map(k => M.weekForm(ELISP, OUT, {}, k).split(ENSURE)[1]),
     [" (omarchy-org-agenda-week 52))", " (omarchy-org-agenda-week -52))", " (omarchy-org-agenda-week 52))",
      " (omarchy-org-agenda-week 0))"], "weekForm: offset clamped to ±52")
  eq(M.weekForm(ELISP, OUT, { agendaFiles: "/home/u/org/a.org:/home/u/org/b.org", pushUpdates: false }, 2),
     "(progn " + PRE + " (omarchy-org-agenda-ensure \"" + OUT + "\" (list \"/home/u/org/a.org\" \"/home/u/org/b.org\") nil)" +
     " (omarchy-org-agenda-week 2))", "weekForm: files and push as in pullForm")
  const s = { agendaFiles: "/home/u/org/a.org", pushUpdates: false }
  eq(M.weekForm(ELISP, OUT, s, 3).split(" (omarchy-org-agenda-week")[0],
     M.pullForm(ELISP, OUT, s, "pull").split(" (omarchy-org-agenda-export")[0], "weekForm: same preamble and ensure as pullForm")
  eq([1.5, "1", NaN, Infinity, null, undefined, 2 ** 53].map(k => throws(() => M.weekForm(ELISP, OUT, {}, k))),
     [true, true, true, true, true, true, true], "weekForm: non-integer offsets throw")
  eq([throws(() => M.weekForm("x.el", OUT, {}, 1)), throws(() => M.weekForm(ELISP, "out.json", {}, 1)),
      throws(() => M.weekForm(ELISP, null, {}, 1))], [true, true, true], "weekForm: relative paths throw")
}

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

// ---------------------------------------------------------------- week

// Captured from `emacsclient --eval (omarchy-org-agenda-week 1)' on an
// isolated -Q daemon (Emacs 31.1, Org 9.8.7) with a one-entry agenda.
const OUT_WEEK = "\"{\\\"version\\\":1,\\\"date\\\":\\\"2026-10-14\\\",\\\"generatedAt\\\":\\\"2026-10-14T07:50:43+0300\\\"," +
  "\\\"reason\\\":\\\"week\\\",\\\"emacs\\\":\\\"31.1\\\",\\\"org\\\":\\\"9.8.7\\\",\\\"keywords\\\":{\\\"todo\\\":[\\\"TODO\\\"]," +
  "\\\"done\\\":[\\\"DONE\\\"],\\\"colors\\\":{},\\\"keys\\\":{\\\"TODO\\\":\\\"t\\\",\\\"DONE\\\":\\\"d\\\"}},\\\"items\\\":[{\\\"id\\\":null," +
  "\\\"path\\\":\\\"/tmp/oa-week/tiny.org\\\",\\\"line\\\":2,\\\"type\\\":\\\"scheduled\\\",\\\"todo\\\":\\\"TODO\\\",\\\"done\\\":false," +
  "\\\"title\\\":\\\"Caf\\\\u00e9 review\\\",\\\"priority\\\":null,\\\"category\\\":\\\"tiny\\\",\\\"tags\\\":[],\\\"time\\\":null," +
  "\\\"durationMin\\\":null,\\\"overdueDays\\\":0,\\\"inDays\\\":6,\\\"habit\\\":false}],\\\"missing\\\":[],\\\"error\\\":null," +
  "\\\"weekOffset\\\":1,\\\"weekStart\\\":\\\"2026-10-19\\\",\\\"startInDays\\\":5}\"\n"
{
  const r = M.parseWeekResult(OUT_WEEK)
  eq([r.ok, r.value.reason, r.value.weekOffset, r.value.weekStart, r.value.startInDays, r.value.error, r.value.daysAhead],
     [true, "week", 1, "2026-10-19", 5, null, 0], "parseWeekResult: real stdout")
  eq(r.value.items.map(i => [i.title, i.type, i.inDays, i.overdueDays, i.todo, i.line]),
     [["Café review", "scheduled", 6, 0, "TODO", 2]], "parseWeekResult: real stdout, items with \\u escapes decoded")
  eq(r.value.keywords.keys, { TODO: "t", DONE: "d" }, "parseWeekResult: keywords")
  const bare = M.elispStringValue(OUT_WEEK)
  eq(M.parseWeekResult("  " + bare + "\n"), r, "parseWeekResult: bare JSON accepted")
  const raw = JSON.parse(bare)
  const without = k => { const o = Object.assign({}, raw); delete o[k]; return JSON.stringify(o) }
  eq(["weekOffset", "weekStart", "startInDays"].map(k => M.parseWeekResult(without(k))),
     [{ ok: false, reason: "not a week" }, { ok: false, reason: "not a week" }, { ok: false, reason: "not a week" }],
     "parseWeekResult: a week field missing -> not ok")
  eq(M.parseWeekResult(JSON.stringify(Object.assign({}, raw, { weekOffset: 60 }))).ok, false,
     "parseWeekResult: out-of-range week field -> not ok")
  eq(M.parseWeekResult(JSON.stringify(Object.assign({}, raw, { version: 2 }))), { ok: false, reason: "unsupported version" },
     "parseWeekResult: payload checks still apply")
  // An error inside Emacs still says its week, so the popout can show it.
  const err = M.parseWeekResult(JSON.stringify(JSON.stringify(Object.assign({}, raw, { items: [], error: "boom" }))))
  eq([err.ok, err.value.error, err.value.items.length, err.value.weekOffset], [true, "boom", 0, 1],
     "parseWeekResult: error payload with its week")
  eq([42, null, undefined, {}, [], true].map(v => M.parseWeekResult(v).ok), [false, false, false, false, false, false],
     "parseWeekResult: non-strings -> not ok")
  eq(["", "t\n", "nil\n", "*ERROR*: boom", "\"\\q\"", "\"{\\\"a\\\":1\"", "\"not json\"", "{not json"]
       .map(s => M.parseWeekResult(s).reason),
     ["not an elisp string", "not an elisp string", "not an elisp string", "not an elisp string", "not an elisp string",
      "invalid JSON", "invalid JSON", "invalid JSON"], "parseWeekResult: malformed -> not ok")
  // prin1 escapes the JSON's own backslashes: \\\" is an escaped quote
  // inside a title, \\\\ a literal backslash.
  const tricky = Object.assign({}, raw, { items: [Object.assign({}, raw.items[0], { title: "a \"q\" \\ b \\u00e9" })] })
  eq(M.parseWeekResult(JSON.stringify(JSON.stringify(tricky))).value.items[0].title, "a \"q\" \\ b \\u00e9",
     "parseWeekResult: escaped quotes and backslashes")
}
{
  // ~120 KB of prin1 output: what 200 long rows can reach.
  const rows = Array.from({ length: 200 }, (_, i) => Object.assign({}, item({ line: i + 1, inDays: 6 }),
    { title: "Row \"" + i + "\" \\ " + "x".repeat(300) }))
  const stdout = JSON.stringify(JSON.stringify(payloadOf(rows, { reason: "week", weekOffset: 1, weekStart: "2026-10-19",
                                                                 startInDays: 5 }))) + "\n"
  const t0 = Date.now()
  const runs = 20
  let r
  for (let i = 0; i < runs; i++) r = M.parseWeekResult(stdout)
  const ms = (Date.now() - t0) / runs
  console.log("     parseWeekResult on " + Math.round(stdout.length / 1024) + " KB: " + ms.toFixed(2) + " ms per call")
  eq([r.ok, r.value.items.length, ms < 100], [true, 200, true], "parseWeekResult: ~120 KB in well under 100 ms")
}

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
  // A refresh after the habit was done: its row is gone, the rows below it move up.
  const before = ["next", "a", "b", "c", "habit", "d", "e", "f"]
  const after = before.filter(k => k !== "habit")
  eq([M.refocus(before, after, 5), M.refocus(before, after, 6), M.refocus(before, after, 7),
      M.refocus(after, before, 6), M.refocus(after, before, 3),
      M.refocus([], before, 0), M.refocus(before, [], 3), M.refocus(["gone"], ["a", "b"], 5),
      M.refocus(before, after, 4)],
     [4, 5, 6, 7, 3, 0, 0, 1, 3], "refocus: keeps the entry or the one above")
}

// ---------------------------------------------------------------- layouts: settings

{
  const base = { socketName: "work", agendaFiles: "/a.org", label: "Count" }
  const key = over => M.pullKey(Object.assign({}, base, over))
  eq([{ layout: "Tabs" }, { layout: "Columns" }, { label: "Icon" }, { showDone: false }, { maxTitleChars: 40 },
      { overdueBadge: false }, { habitsInBadge: true }, { agendaKey: "t" }, { emacsApp: "x" }]
       .map(o => key(o) === key({})), [true, true, true, true, true, true, true, true, true],
     "pullKey: UI-only settings keep it")
  eq([{ socketName: "home" }, { serverFile: "/tmp/srv" }, { emacsclient: "/opt/ec" }, { agendaFiles: "/b.org" },
      { pushUpdates: false }, { timeoutSeconds: 9 }].map(o => key(o) === key({})),
     [false, false, false, false, false, false], "pullKey: pull settings change it")
  eq([M.pullKey(null) === M.pullKey({}), typeof M.pullKey({})], [true, "string"], "pullKey: defaults")
}
eq([M.LAYOUTS, ["Org", "Tabs", "Columns", "bogus", null].map(M.nextLayout)],
   [["Org", "Tabs", "Columns"], ["Tabs", "Columns", "Org", "Tabs", "Tabs"]], "nextLayout: cycles, invalid as Org")
eq(["Org", "Tabs", "Columns", " Tabs ", "tabs", "", 3, undefined].map(l => M.normalizeSettings({ layout: l }).layout),
   ["Org", "Tabs", "Columns", "Tabs", "Org", "Org", "Org", "Org"], "normalizeSettings: layout")

// ---------------------------------------------------------------- layouts: Org formatting

eq([M.orgCategory("work"), M.orgCategory("work-cal"), M.orgCategory("abcdefghijk"), M.orgCategory("abcdefghijkl"),
    M.orgCategory(""), M.orgCategory(null), M.orgCategory("ăîșțâ")],
   ["work:       ", "work-cal:   ", "abcdefghijk:", "abcdefghijk:", "            ", "            ", "ăîșțâ:      "],
   "orgCategory: padded to 12, cut to 11")
{
  const L = over => M.orgLeader(item(over))
  eq([L({ overdueDays: 5 }), L({ type: "past-scheduled", overdueDays: 13 }), L({ overdueDays: 120 }), L({}),
      L({ type: "past-scheduled" }), L({ type: "deadline", overdueDays: 3 }), L({ type: "deadline", overdueDays: 100 }),
      L({ type: "deadline" }), L({ type: "upcoming-deadline", inDays: 5 }), L({ type: "upcoming-deadline", inDays: 120 }),
      L({ type: "timestamp" }), L({ type: "sexp" }), L({ type: "block" }), L({ habit: true, overdueDays: 2 }),
      L({ habit: true })],
     ["Sched. 5x: ", "Sched.13x: ", "Sched.120x: ", "Scheduled: ", "Scheduled: ", " 3 d. ago: ", "100 d. ago: ",
      "Deadline:  ", "In   5 d.: ", "In 120 d.: ", "", "", "", "Sched. 2x: ", "Scheduled: "], "orgLeader: Org's formats")
}
{
  const W = (over, nowMin, today) => M.orgWhen(item(over), nowMin, today === undefined ? true : today)
  eq([W({ time: "09:30", durationMin: 30, type: "timestamp" }, 600),
      W({ time: "09:30", durationMin: 30, type: "timestamp" }, 599),
      W({ time: "09:30", durationMin: 30, type: "timestamp" }, 600, false),
      W({ time: "13:00", type: "timestamp" }, 640),
      W({ time: "13:00", type: "timestamp" }, 810),
      W({ time: "23:30", durationMin: 60, type: "timestamp" }, 640),
      W({ time: "22:00", durationMin: 180 }, NaN),
      W({}, 640), W({ type: "timestamp" }, 640),
      W({ overdueDays: 13, time: "09:00" }, 640),
      W({ type: "deadline", overdueDays: 3 }, 640),
      W({ type: "deadline", time: "17:00" }, 640),
      W({ type: "deadline" }, 640, false),
      W({ type: "upcoming-deadline", inDays: 5 }, 640),
      W({ habit: true, time: "07:30" }, 640),
      W({ habit: true, time: "07:30", overdueDays: 2 }, 640)],
     [{ text: "09:30-10:00 ", tone: "muted" }, { text: "09:30-10:00 ", tone: "normal" },
      { text: "09:30-10:00 ", tone: "normal" },
      { text: "13:00...... ", tone: "normal" }, { text: "13:00...... ", tone: "muted" },
      { text: "23:30-00:30 ", tone: "normal" }, { text: "22:00-01:00 ", tone: "normal" },
      { text: "Scheduled:  ", tone: "muted" }, { text: "            ", tone: "normal" },
      { text: "Sched.13x:  ", tone: "late" }, { text: " 3 d. ago:  ", tone: "urgent" },
      { text: "Deadline:   ", tone: "urgent" }, { text: "Deadline:   ", tone: "soon" },
      { text: "In   5 d.:  ", tone: "soon" },
      { text: "07:30...... ", tone: "normal" }, { text: "Sched. 2x:  ", tone: "late" }],
     "orgWhen: times, leaders, padding, tones, past, past midnight")
}
{
  const d = (y, m, day) => new Date(y, m - 1, day)
  eq([M.orgDayTitle(d(2026, 10, 14), true), M.orgDayTitle(d(2026, 10, 15), false), M.orgDayTitle(d(2026, 10, 19), false),
      M.orgDayTitle(d(2026, 5, 3), false), M.orgDayTitle(new Date(NaN), true)],
     [{ title: "Wednesday  14 October 2026", week: "W42" }, { title: "Thursday   15 October 2026", week: "" },
      { title: "Monday     19 October 2026", week: "W43" }, { title: "Sunday      3 May 2026", week: "" },
      { title: "", week: "" }], "orgDayTitle: aligned, week on Monday or first shown")
  eq([d(2026, 1, 1), d(2027, 1, 1), d(2024, 12, 30), d(2021, 1, 3), d(2020, 12, 31), d(2026, 12, 28), d(2026, 10, 14),
      d(2026, 3, 29)].map(M.isoWeek), [1, 53, 1, 53, 53, 53, 42, 13], "isoWeek: edges")
  eq([M.compactDayTitle(d(2026, 10, 15)), M.compactDayTitle(d(2026, 11, 1)), M.compactDayTitle(null)],
     ["THU 15", "SUN 1", ""], "compactDayTitle")
}

// ---------------------------------------------------------------- layouts: fixture

// Wednesday 14 Oct 2026, 10:40. The Org week runs Mon–Sun: 4 later days.
// Today's list is in Org's order (habit-down time-up urgency-down).
const on14 = (h, m) => new Date(2026, 9, 14, h, m)
const runH = item({ line: 100, todo: "TODO", title: "Morning run", category: "habits", habit: true, time: "07:30", overdueDays: 2 })
const readH = item({ line: 101, todo: "TODO", title: "Read", category: "habits", habit: true, time: "08:00" })
const standup14 = item({ line: 110, type: "timestamp", title: "Standup", category: "work-cal", time: "09:30", durationMin: 30 })
const sync14 = item({ line: 111, type: "timestamp", title: "Engineering sync", category: "work-cal", time: "13:00" })
const late14 = item({ line: 112, type: "timestamp", title: "Release", category: "work-cal", time: "23:30", durationMin: 60 })
const expenses = item({ line: 120, type: "deadline", todo: "TODO", title: "Expenses", category: "work", overdueDays: 3 })
const taxes = item({ line: 121, type: "deadline", todo: "TODO", title: "Taxes", category: "home" })
const talk = item({ line: 122, type: "upcoming-deadline", todo: "TODO", title: "Talk proposal", category: "work", inDays: 2 })
const visa = item({ line: 123, type: "upcoming-deadline", todo: "TODO", title: "Visa", category: "home", inDays: 12 })
const hiring = item({ line: 130, todo: "NEXT", priority: "A", title: "Hiring plan", category: "work" })
const insurance = item({ line: 140, type: "past-scheduled", todo: "TODO", title: "Insurance", category: "home", overdueDays: 13 })
const done14 = item({ line: 150, todo: "DONE", done: true, title: "Done thing", category: "home" })
const thuStandup = item({ line: 160, type: "timestamp", title: "Standup", category: "work-cal", time: "09:30", durationMin: 30, inDays: 1 })
const slides = item({ line: 161, todo: "TODO", title: "Board slides", category: "work", inDays: 1 })
const groceries = item({ line: 170, todo: "TODO", title: "Groceries", category: "home", inDays: 3 })
const weekItems = [runH, readH, standup14, sync14, late14, expenses, taxes, talk, visa, hiring, insurance, done14,
                   thuStandup, slides, groceries]
const weekPayload = items => payloadOf(items, { date: "2026-10-14", generatedAt: "2026-10-14T10:38:00+0300", daysAhead: 4 })
const V = (now, settings, items) => M.view(parsed(weekPayload(items || weekItems)).value, "ok", "", now || on14(10, 40), settings || {})
const v14 = V()
// Next week (Mon 19 – Sun 25) and last week (Mon 5 – Sun 11), as parseWeekResult gives them.
const nextWeek = parsed(payloadOf([
  item({ line: 200, type: "deadline", todo: "TODO", title: "Visa", category: "home", inDays: 5 }),
  item({ line: 201, todo: "TODO", title: "Dentist", category: "home", time: "10:00", inDays: 7 }),
  item({ line: 202, todo: "DONE", done: true, title: "Done next week", category: "home", inDays: 7 })],
  { date: "2026-10-14", reason: "week", weekOffset: 1, weekStart: "2026-10-19", startInDays: 5 })).value
const lastWeek = parsed(payloadOf([
  item({ line: 210, type: "past-scheduled", todo: "TODO", title: "Old repeat", category: "home", inDays: -8 }),
  item({ line: 211, type: "deadline", todo: "TODO", title: "Old deadline", category: "work", inDays: -5 })],
  { date: "2026-10-14", reason: "week", weekOffset: -1, weekStart: "2026-10-05", startInDays: -9 })).value

const lineOf = k => Number(/:(\d+):-?\d+(#\d+)?$/.exec(k)[1])
// One short string per block, to compare kinds and order at a glance.
const shape = b => b.kind === "row" ? "row " + b.item.line
  : b.kind === "next" ? "next " + b.item.line
  : b.kind === "day" ? "day " + b.title.trim() + (b.empty ? " (empty)" : "")
  : b.kind === "section" ? "sec " + b.title + " " + b.count
  : b.kind === "chips" ? "chips " + b.chips.map(c => c.item.line).join(",")
  : b.kind === "message" ? "msg " + b.text
  : b.kind
const shapes = (m, pane) => m.panes[pane || 0].blocks.map(shape)
const LM = (v, ui) => M.layoutModel(v, ui)

// The keyboard's order is the display order, pane by pane.
function selsInOrder(m) {
  const seen = []
  m.panes.forEach((p, pi) => p.blocks.forEach(b => {
    if (b.kind === "row" || b.kind === "next") seen.push([b.sel, b.key, pi])
    if (b.kind === "chips") b.chips.forEach(c => seen.push([c.sel, c.key, pi]))
  }))
  return seen.every((s, i) => s[0] === i) && JSON.stringify(seen) === JSON.stringify(m.rows.map(r => [r.sel, r.key, r.pane]))
}

// ---------------------------------------------------------------- layouts: week navigation

eq([[0, 1], [0, -1], [5, 0], [-3, 0], [52, 1], [-52, -1], [51, 7], [1.5, 1], [undefined, -1], [2, "x"]]
     .map(a => M.browseOffset(a[0], a[1])),
   [1, -1, 0, 0, 52, -52, 52, 1, -1, 2], "browseOffset: f b . clamped to ±52")
eq(M.MAX_WEEK_OFFSET, 52, "MAX_WEEK_OFFSET")
eq([M.weekNav(v14, 0, null), M.weekNav(v14, 1, null), M.weekNav(v14, 1, nextWeek), M.weekNav(v14, -1, lastWeek),
    M.weekNav(v14, -2, null), M.weekNav(v14, 3, null), M.weekNav(v14, 99, null)],
   [{ offset: 0, label: "This week", range: "14–18 Oct" }, { offset: 1, label: "Next week", range: "19–25 Oct" },
    { offset: 1, label: "Next week", range: "19–25 Oct" }, { offset: -1, label: "Last week", range: "5–11 Oct" },
    { offset: -2, label: "W40", range: "28 Sep – 4 Oct" }, { offset: 3, label: "W45", range: "2–8 Nov" },
    { offset: 0, label: "This week", range: "14–18 Oct" }],
   "weekNav: labels and ranges, across a month, without a week payload")
eq(M.weekNav(V(), 2, Object.assign({}, nextWeek, { weekOffset: 2, weekStart: "2026-10-26" })),
   { offset: 2, label: "W44", range: "26 Oct – 1 Nov" }, "weekNav: from the week payload")
{
  // On Sunday the week ends today; with Org's week starting today, 6 days on.
  const sun = M.view(parsed(payloadOf([], { date: "2026-10-18", daysAhead: 0 })).value, "ok", "", new Date(2026, 9, 18, 9, 0), {})
  const fromToday = M.view(parsed(payloadOf([], { date: "2026-10-14", daysAhead: 6 })).value, "ok", "", on14(9, 0), {})
  eq([M.weekNav(sun, 0, null).range, M.weekNav(sun, 1, null).range, M.weekNav(fromToday, 0, null).range,
      M.weekNav(fromToday, 1, null).range],
     ["18 Oct", "19–25 Oct", "14–20 Oct", "21–27 Oct"], "weekNav: Sunday, and a week starting today")
  eq(M.weekNav(M.view(null, "loading", "", on14(9, 0), {}), 3, null), { offset: 3, label: "+3 weeks", range: "" },
     "weekNav: no payload yet")
}
eq([M.weekWanted(0, null), M.weekWanted(1, null), M.weekWanted(1, nextWeek), M.weekWanted(-1, nextWeek),
    M.weekWanted(-1, lastWeek), M.weekWanted(0, nextWeek)],
   [null, 1, null, -1, null, null], "weekWanted")

// ---------------------------------------------------------------- layouts: Org

{
  const m = LM(v14, { layout: "Org" })
  eq([m.layout, m.tab, m.tabs, m.nav, m.panes.length, m.empty],
     ["Org", "today", [], { offset: 0, label: "This week", range: "14–18 Oct" }, 1, false], "layoutModel Org: frame")
  eq(shapes(m), ["day Wednesday  14 October 2026", "row 100", "row 101", "row 110", "now", "row 111", "row 112",
                 "row 120", "row 121", "row 122", "row 123", "row 130", "row 140", "row 150",
                 "day Thursday   15 October 2026", "row 160", "row 161", "day Friday     16 October 2026 (empty)",
                 "day Saturday   17 October 2026", "row 170", "day Sunday     18 October 2026 (empty)"],
     "layoutModel Org: today in Org's order with the now line, then each later day, empty days kept")
  const b = m.panes[0].blocks
  eq([b[0], b[4]],
     [{ kind: "day", key: "day:2026-10-14", style: "org", today: true, empty: false,
        title: "Wednesday  14 October 2026", week: "W42", hint: "" },
      { kind: "now", key: "now", text: "now - - - - - - - - - - - - - - - - - - - - - - - - -" }],
     "layoutModel Org: today's header and the now line")
  eq(b.filter(x => x.kind === "row").map(x => [x.item.line, x.cat, x.when.text, x.when.tone, x.past, x.flag]),
     [[100, "habits:     ", "Sched. 2x:  ", "late", false, false], [101, "habits:     ", "08:00...... ", "normal", false, false],
      [110, "work-cal:   ", "09:30-10:00 ", "muted", true, false], [111, "work-cal:   ", "13:00...... ", "normal", false, false],
      [112, "work-cal:   ", "23:30-00:30 ", "normal", false, false], [120, "work:       ", " 3 d. ago:  ", "urgent", false, true],
      [121, "home:       ", "Deadline:   ", "urgent", false, true], [122, "work:       ", "In   2 d.:  ", "soon", false, true],
      [123, "home:       ", "In  12 d.:  ", "soon", false, true], [130, "work:       ", "Scheduled:  ", "muted", false, false],
      [140, "home:       ", "Sched.13x:  ", "late", false, false], [150, "home:       ", "Scheduled:  ", "muted", false, false],
      [160, "work-cal:   ", "09:30-10:00 ", "normal", false, false], [161, "work:       ", "Scheduled:  ", "muted", false, false],
      [170, "home:       ", "Scheduled:  ", "muted", false, false]],
     "layoutModel Org: categories, leaders, tones; past only today")
  const r = b[1]
  eq([r.style, r.lead, r.trail, r.dense, r.sel], ["org", null, null, false, 0], "layoutModel Org: row shape")
  eq([b[14].week, b[17].week, selsInOrder(m), m.rows.length, m.rows.map(x => x.pane).indexOf(1)],
     ["", "", true, 15, -1], "layoutModel Org: no week mark mid-week; sel in display order")
  eq(m.rows.map(x => x.key).indexOf("next"), -1, "layoutModel Org: no next card")
}
{
  const nowAt = (h, mi) => shapes(LM(V(on14(h, mi)), { layout: "Org" })).slice(0, 8).join(" | ")
  eq([nowAt(8, 0), nowAt(13, 0), nowAt(23, 50)],
     ["day Wednesday  14 October 2026 | row 100 | row 101 | now | row 110 | row 111 | row 112 | row 120",
      "day Wednesday  14 October 2026 | row 100 | row 101 | row 110 | row 111 | now | row 112 | row 120",
      "day Wednesday  14 October 2026 | row 100 | row 101 | row 110 | row 111 | row 112 | now | row 120"],
     "layoutModel Org: now line before the first later start, else after the last timed row")
  eq(shapes(LM(V(on14(10, 40), {}, [runH, hiring, slides]), { layout: "Org" })).indexOf("now"), -1,
     "layoutModel Org: no now line without a timed non-habit row today")
  eq(shapes(LM(V(new Date(NaN)), { layout: "Org" })).indexOf("now"), -1, "layoutModel Org: no now line without a clock")
}
{
  const m = LM(V(on14(10, 40), { showDone: false }), { layout: "Org" })
  eq([shapes(m).indexOf("row 150"), m.rows.length, selsInOrder(m)], [-1, 14, true], "layoutModel Org: showDone false")
}
{
  const wk = LM(v14, { layout: "Org", offset: 1, week: nextWeek })
  eq(shapes(wk), ["day Monday     19 October 2026", "row 200", "day Tuesday    20 October 2026 (empty)",
                  "day Wednesday  21 October 2026", "row 201", "row 202", "day Thursday   22 October 2026 (empty)",
                  "day Friday     23 October 2026 (empty)", "day Saturday   24 October 2026 (empty)",
                  "day Sunday     25 October 2026 (empty)"], "layoutModel Org: next week's 7 days")
  const b = wk.panes[0].blocks
  eq([b[0].week, b[0].today, b[1].when, b[4].when, b[4].past, wk.empty, wk.nav.label],
     ["W43", false, { text: "Deadline:   ", tone: "soon" }, { text: "10:00...... ", tone: "normal" }, false, false, "Next week"],
     "layoutModel Org: next week, week mark on the first day, no today")
  eq(shapes(LM(V(on14(10, 40), { showDone: false }), { layout: "Org", offset: 1, week: nextWeek })).indexOf("row 202"), -1,
     "layoutModel Org: next week, showDone false")
  const lw = LM(v14, { layout: "Org", offset: -1, week: lastWeek })
  eq([shapes(lw).filter(s => s.indexOf("row") === 0), lw.panes[0].blocks[2].when, lw.nav.label],
     [["row 210", "row 211"], { text: "Scheduled:  ", tone: "muted" }, "Last week"],
     "layoutModel Org: last week, its past-scheduled rows aren't overdue")
  eq([LM(v14, { layout: "Org", offset: 1 }).panes[0].blocks, LM(v14, { layout: "Org", offset: 2, week: nextWeek }).panes[0].blocks,
      LM(v14, { layout: "Org", offset: -1, weekError: "Emacs not reachable" }).panes[0].blocks,
      LM(v14, { layout: "Org", offset: 1, week: Object.assign({}, nextWeek, { error: "boom" }) }).panes[0].blocks],
     [[{ kind: "message", key: "msg:week", text: "Loading next week…", tone: "muted" }],
      [{ kind: "message", key: "msg:week", text: "Loading W44…", tone: "muted" }],
      [{ kind: "message", key: "msg:week", text: "Emacs not reachable", tone: "error" }],
      [{ kind: "message", key: "msg:week", text: "boom", tone: "error" }]],
     "layoutModel Org: loading, another offset's payload, error, an error payload")
  eq(LM(v14, { layout: "Org", offset: 1 }).rows, [], "layoutModel Org: loading has no rows")
}

// ---------------------------------------------------------------- layouts: Tabs

{
  const tab = t => LM(v14, { layout: "Tabs", tab: t })
  const today = tab("today")
  eq(today.tabs, [{ key: "today", title: "Today", count: 8, urgent: false },
                  { key: "week", title: "This week", count: 5, urgent: false },
                  { key: "overdue", title: "Overdue", count: 2, urgent: true }], "layoutModel Tabs: tabs and counts")
  eq([today.tab, today.panes.length, today.panes[0].key, shapes(today)],
     ["today", 1, "today", ["next 111", "sec Schedule 3", "row 110", "row 111", "row 112", "sec Today 3", "row 121", "row 130",
                           "row 150", "sec Habits 2", "row 100", "row 101"]], "layoutModel Tabs: Today tab")
  const b = today.panes[0].blocks
  eq(b[0], { kind: "next", key: "next", sel: 0, item: sync14, caption: "NEXT UP", meta: "13:00 · in 2 h 20 min · work-cal" },
     "layoutModel Tabs: next card")
  eq([b[1], b[9].hint], [{ kind: "section", key: "sec:schedule", title: "Schedule", count: 3, hint: "", urgent: false },
                         "missed days"], "layoutModel Tabs: section blocks")
  eq([b[2].style, b[2].lead, b[2].trail, b[2].past, b[3].past, b[2].cat, b[2].when, b[10].trail, b[6].flag],
     ["list", { text: "09:30", tone: "muted" }, { text: "work-cal", tone: "muted" }, true, false, "", null,
      { text: "2d", tone: "late" }, true], "layoutModel Tabs: list rows, past, habit trail, flag")
  eq([selsInOrder(today), today.rows.length], [true, 9], "layoutModel Tabs: Today sel")
  eq(LM(V(on14(13, 10)), { layout: "Tabs" }).panes[0].blocks[0].caption, "NOW", "layoutModel Tabs: NOW card")

  const week = tab("week")
  eq(shapes(week), ["day THU 15", "row 160", "row 161", "day FRI 16", "row 122", "day SAT 17", "row 170",
                    "day SUN 18 (empty)", "sec Deadlines ahead 1", "row 123"],
     "layoutModel Tabs: Week tab, warnings on their day, later ones after")
  const wb = week.panes[0].blocks
  eq([wb[0], wb[7].hint], [{ kind: "day", key: "day:2026-10-15", style: "compact", today: false, empty: false,
                             title: "THU 15", week: "", hint: "" }, "nothing scheduled"], "layoutModel Tabs: compact days")
  eq([wb[1].lead, wb[1].trail, wb[2].lead, wb[4].flag, wb[4].lead, wb[9].lead, wb[9].flag, wb[1].dense],
     [{ text: "09:30", tone: "muted" }, { text: "work-cal", tone: "muted" }, { text: "", tone: "muted" }, true,
      { text: "", tone: "muted" }, { text: "26 Oct", tone: "muted" }, true, false],
     "layoutModel Tabs: week rows: time, category, deadline flags and day")
  eq([selsInOrder(week), week.rows.length, week.tabs[1].count], [true, 5, 5], "layoutModel Tabs: Week sel")

  const od = tab("overdue")
  eq([shapes(od), od.panes[0].blocks.map(x => [x.lead, x.flag])],
     [["row 120", "row 140"], [[{ text: "3d", tone: "urgent" }, true], [{ text: "13d", tone: "urgent" }, false]]],
     "layoutModel Tabs: Overdue tab")
  eq(M.layoutModel(v14, { layout: "Tabs", tab: "bogus" }).tab, "today", "layoutModel Tabs: bad tab -> today")

  // Browsing weeks moves only the Week tab.
  const wk1 = LM(v14, { layout: "Tabs", tab: "week", offset: 1, week: nextWeek })
  eq([shapes(wk1), wk1.tabs.map(t => [t.title, t.count])],
     [["day MON 19", "row 200", "day TUE 20 (empty)", "day WED 21", "row 201", "row 202", "day THU 22 (empty)",
       "day FRI 23 (empty)", "day SAT 24 (empty)", "day SUN 25 (empty)"],
      [["Today", 8], ["Next week", 3], ["Overdue", 2]]], "layoutModel Tabs: next week")
  eq([shapes(LM(v14, { layout: "Tabs", tab: "today", offset: 1, week: nextWeek })), shapes(LM(v14, { layout: "Tabs", tab: "overdue", offset: -1 }))],
     [shapes(today), shapes(od)], "layoutModel Tabs: Today and Overdue ignore the week offset")
  eq([shapes(LM(v14, { layout: "Tabs", tab: "week", offset: 1 })), LM(v14, { layout: "Tabs", tab: "week", offset: 1 }).tabs[1].count],
     [["msg Loading next week…"], 0], "layoutModel Tabs: week loading")

  const hidden = LM(V(on14(10, 40), { showDone: false }), { layout: "Tabs" })
  eq([hidden.tabs.map(t => t.count), shapes(hidden).indexOf("row 150")], [[7, 5, 2], -1], "layoutModel Tabs: showDone false")
}

// ---------------------------------------------------------------- layouts: Columns

{
  const m = LM(v14, { layout: "Columns" })
  eq([m.panes.map(p => [p.key, p.title]), m.tabs], [[["today", "Today"], ["side", ""]], []], "layoutModel Columns: panes")
  eq(shapes(m, 0), ["next 111", "sec Schedule 3", "row 110", "row 111", "row 112", "sec Today 3", "row 121", "row 130",
                    "row 150", "sec Habits 2", "chips 100,101"], "layoutModel Columns: left, habits as chips")
  eq(shapes(m, 1), ["sec Overdue 2", "row 120", "row 140", "sec This week 5", "day THU 15", "row 160", "row 161",
                    "day FRI 16", "row 122", "day SAT 17", "row 170", "day SUN 18 (empty)", "sec Deadlines ahead 1",
                    "row 123"], "layoutModel Columns: right, overdue then the week")
  const chips = m.panes[0].blocks[10]
  eq([chips.key, chips.chips.map(c => [c.sel, c.text, c.missed, c.done])],
     ["chips:habits", [[7, "Morning run", "2d", false], [8, "Read", "", false]]], "layoutModel Columns: chips")
  const right = m.panes[1].blocks
  eq([right[0].urgent, right[1].dense, right[1].lead, right[5].dense, m.panes[0].blocks[2].dense],
     [true, true, { text: "3d", tone: "urgent" }, true, false], "layoutModel Columns: dense right pane")
  eq([selsInOrder(m), m.rows.map(r => r.pane).join(""), m.rows.length], [true, "0000000001111111", 16],
     "layoutModel Columns: sel across panes")
  const wk = LM(v14, { layout: "Columns", offset: -1, week: lastWeek })
  eq([shapes(wk, 0), shapes(wk, 1).slice(0, 5)],
     [shapes(m, 0), ["sec Overdue 2", "row 120", "row 140", "sec Last week 2", "day MON 5 (empty)"]],
     "layoutModel Columns: last week changes only the week part")
  eq(shapes(LM(v14, { layout: "Columns", offset: 1, weekError: "timeout" }), 1),
     ["sec Overdue 2", "row 120", "row 140", "sec Next week 0", "msg timeout"], "layoutModel Columns: week error")
  eq(shapes(LM(V(on14(10, 40), {}, [hiring, slides]), { layout: "Columns" }), 1),
     ["sec This week 1", "day THU 15", "row 161", "day FRI 16 (empty)", "day SAT 17 (empty)", "day SUN 18 (empty)"],
     "layoutModel Columns: no overdue section without overdue rows")
  eq(LM(V(on14(10, 40), { showDone: false }), { layout: "Columns" }).rows.map(r => r.item.line).indexOf(150), -1,
     "layoutModel Columns: showDone false")

  // ←/→ keeps the position within the pane, clamped.
  eq([M.paneSel(m, 2, 1), M.paneSel(m, 8, 1), M.paneSel(m, 9, -1), M.paneSel(m, 15, -1), M.paneSel(m, 0, -1),
      M.paneSel(m, 12, 1), M.paneSel(m, 99, 1)], [11, 15, 0, 6, 0, 12, 99], "paneSel")
  const noRight = LM(V(on14(10, 40), {}, [hiring]), { layout: "Columns" })
  eq([M.paneSel(noRight, 0, 1), M.paneSel(LM(v14, { layout: "Org" }), 3, 1), M.paneSel(null, 2, 1)], [0, 3, 2],
     "paneSel: empty target or one pane stays")
}

// ---------------------------------------------------------------- layouts: keys, empty, helpers

{
  const models = [LM(v14, { layout: "Org" }), LM(v14, { layout: "Tabs", tab: "today" }), LM(v14, { layout: "Tabs", tab: "week" }),
                  LM(v14, { layout: "Tabs", tab: "overdue" }), LM(v14, { layout: "Columns" })]
  const keyOf = (m, line) => m.rows.filter(r => r.key !== "next" && r.item.line === line).map(r => r.key)
  eq([111, 100, 120, 122, 160, 123].map(line => models.map(m => keyOf(m, line)).filter(k => k.length)
       .every((k, i, all) => k.length === 1 && k[0] === all[0][0])), [true, true, true, true, true, true],
     "keys: the same entry has the same key in every layout and tab")
  eq([keyOf(models[0], 111)[0], keyOf(models[0], 122)[0]],
     ["timestamp:/home/u/org/cal.org:111:0", "upcoming-deadline:/home/u/org/cal.org:122:2"], "keys: type, path, line, day")
  eq(models.map(m => new Set(m.rows.map(r => r.key)).size === m.rows.length), [true, true, true, true, true], "keys: unique")
  eq(keyOf(LM(V(), { layout: "Org" }), 111), keyOf(models[0], 111), "keys: stable across refreshes")
  eq(keyOf(LM(V(on14(10, 40), { showDone: false }), { layout: "Org" }), 160), keyOf(models[0], 160), "keys: showDone doesn't move them")
  // The same heading twice on a day: a deterministic suffix.
  const twice = LM(V(on14(10, 40), {}, [hiring, Object.assign({}, hiring, { title: "again" }), hiring]), { layout: "Org" })
  const k130 = "scheduled:/home/u/org/cal.org:130:0"
  eq(twice.rows.map(r => r.key), [k130, k130 + "#2", k130 + "#3"], "keys: repeats suffixed #2, #3")
  eq(lineOf(twice.rows[1].key), 130, "keys: suffix keeps the line readable")
  const wkKeys = LM(v14, { layout: "Org", offset: 1, week: nextWeek }).rows.map(r => r.key)
  eq([wkKeys, LM(v14, { layout: "Tabs", tab: "week", offset: 1, week: nextWeek }).rows.map(r => r.key)],
     [wkKeys, wkKeys], "keys: a week's rows keyed alike in Org and Tabs")
}
{
  const empty = M.view(parsed(weekPayload([])).value, "ok", "", on14(10, 40), {})
  eq(["Org", "Tabs", "Columns"].map(l => LM(empty, { layout: l }).empty), [true, true, true], "layoutModel: empty")
  eq([LM(empty, { layout: "Org", offset: 1 }).empty, LM(V(on14(10, 40), {}, [done14]), { layout: "Org" }).empty,
      LM(V(on14(10, 40), { showDone: false }, [done14]), { layout: "Org" }).empty], [false, false, true],
     "layoutModel: empty only this week, after showDone")
  eq(shapes(LM(empty, { layout: "Org" })), ["day Wednesday  14 October 2026 (empty)", "day Thursday   15 October 2026 (empty)",
     "day Friday     16 October 2026 (empty)", "day Saturday   17 October 2026 (empty)", "day Sunday     18 October 2026 (empty)"],
     "layoutModel Org: an empty week keeps its days")
  const loading = M.view(null, "loading", "", on14(10, 40), {})
  eq(["Org", "Tabs", "Columns"].map(l => { const m = LM(loading, { layout: l }); return [m.panes.length, m.rows.length, m.empty] }),
     [[1, 0, true], [1, 0, true], [2, 0, true]], "layoutModel: no payload yet")
  eq(LM(v14, null).layout, "Org", "layoutModel: no ui -> Org")
}
eq([M.tabStep("today", 1), M.tabStep("week", 1), M.tabStep("overdue", 1), M.tabStep("overdue", -1), M.tabStep("today", -1),
    M.tabStep("bogus", 1)], ["week", "overdue", "overdue", "week", "today", "week"], "tabStep: stops at the ends")
eq([1, 2, 3, 0, 4, "1", 1.5].map(M.tabAt), ["today", "week", "overdue", null, null, null, null], "tabAt")
{
  eq(["Org", "Tabs", "Columns"].map(l => M.overdueFocus(LM(v14, M.overdueUi({ layout: l, tab: "week", offset: 2 })))),
     ["deadline:/home/u/org/cal.org:120:0", "deadline:/home/u/org/cal.org:120:0", "deadline:/home/u/org/cal.org:120:0"],
     "overdueFocus: the first overdue row in every layout")
  eq([M.overdueUi({ layout: "Tabs", tab: "week", offset: 2, week: null }), M.overdueUi({ layout: "Org", tab: "week", offset: -3 }),
      M.overdueUi({ layout: "Columns", offset: 1 })],
     [{ layout: "Tabs", tab: "overdue", offset: 0, week: null }, { layout: "Org", tab: "week", offset: 0 },
      { layout: "Columns", offset: 0 }], "overdueUi: this week, Tabs on Overdue")
  eq([M.overdueFocus(LM(V(on14(10, 40), {}, [hiring, runH]), { layout: "Org" })),
      M.overdueFocus(LM(v14, { layout: "Org", offset: -1, week: lastWeek })), M.overdueFocus(null)],
     ["", "", ""], "overdueFocus: none")
}
{
  const hints = ["Org", "Tabs", "Columns"].map(l => M.layoutHints(l))
  eq(hints, ["↑↓ move · ↵ open · t state · f b week · v layout · r refresh · esc",
             "1 2 3 tabs · ↑↓ move · ↵ open · t state · f b week · v layout · r refresh · esc",
             "← → column · ↑↓ move · ↵ open · t state · f b week · v layout · r refresh · esc"], "layoutHints")
  eq(hints.map(h => h.length <= 80), [true, true, true], "layoutHints: under 80 chars")
}

{
  // [named key, text] → action, per layout.
  const act = (layout, tab, key, text) => M.keyAction({ layout: layout, tab: tab, pickerOpen: false }, key, text)
  const shared = [["Up", ""], ["Down", ""], ["", "k"], ["", "j"], ["", "p"], ["", "n"], ["Return", ""],
                  ["", "t"], ["", "r"], ["", "R"], ["Escape", ""], ["", "v"]]
  const sharedWant = [{ move: -1 }, { move: 1 }, { move: -1 }, { move: 1 }, { move: -1 }, { move: 1 }, { open: true },
                      { state: true }, { refresh: true }, { refresh: true }, { close: true }, { layout: "next" }]
  eq(["Org", "Tabs", "Columns"].map(l => shared.map(([k, t]) => act(l, "today", k, t))),
     [sharedWant, sharedWant, sharedWant], "keyAction: shared keys in every layout")
  eq(["Org", "Tabs", "Columns"].map(l => [["", "f"], ["", "b"], ["", "."]].map(([k, t]) => act(l, "today", k, t))),
     [[{ week: 1 }, { week: -1 }, { week: 0 }],
      [{ week: 1, tab: "week" }, { week: -1, tab: "week" }, { week: 0 }],
      [{ week: 1 }, { week: -1 }, { week: 0 }]], "keyAction: f b . browse weeks; Tabs shows the week tab")
  eq([["", "1"], ["", "2"], ["", "3"], ["", "4"], ["", "0"], ["Left", ""], ["Right", ""], ["", "h"], ["", "l"]]
       .map(([k, t]) => act("Tabs", "week", k, t)),
     [{ tab: "today" }, { tab: "week" }, { tab: "overdue" }, null, null,
      { tab: "today" }, { tab: "overdue" }, { tab: "today" }, { tab: "overdue" }], "keyAction: Tabs 1 2 3 and ←→ h l")
  eq([act("Tabs", "overdue", "Right", ""), act("Tabs", "today", "Left", "")],
     [{ tab: "overdue" }, { tab: "today" }], "keyAction: Tabs ←→ stop at the ends")
  eq([["Left", ""], ["Right", ""], ["", "h"], ["", "l"], ["", "1"]].map(([k, t]) => act("Columns", "today", k, t)),
     [{ pane: -1 }, { pane: 1 }, { pane: -1 }, { pane: 1 }, null], "keyAction: Columns ←→ h l switch panes")
  eq([["Left", ""], ["Right", ""], ["", "h"], ["", "l"], ["", "1"]].map(([k, t]) => act("Org", "today", k, t)),
     [null, null, null, null, null], "keyAction: Org ignores ←→ and digits")
  eq([["", "F"], ["", "B"], ["", "N"], ["", "P"], ["", "T"], ["", "V"], ["", "J"], ["", "x"], ["", ""], ["", "ff"],
      ["Tab", ""]].map(([k, t]) => act("Tabs", "today", k, t)),
     [null, null, null, null, null, null, null, null, null, null, null], "keyAction: case-sensitive, unknown keys")
  eq([M.keyAction({ layout: "Tabs", tab: "today", pickerOpen: true }, "Down", ""),
      M.keyAction({ layout: "Org", pickerOpen: true }, "", "f"),
      M.keyAction({ layout: "Columns", pickerOpen: true }, "Escape", "")],
     [null, null, null], "keyAction: the picker keeps its keys")
  eq([M.keyAction(null, "", "j"), M.keyAction({ layout: "bogus" }, "Left", ""), M.keyAction({ layout: "Tabs" }, "", "3"),
      M.keyAction({}, "Down", "x")],
     [{ move: 1 }, null, { tab: "overdue" }, { move: 1 }], "keyAction: defaults; the named key wins over text")
}
{
  const a = item({ path: "/home/u/org/a.org", line: 3 })
  const b = item({ path: "/home/u/org/b.org", line: 9 })
  const main = { items: [a] }
  const week = { items: [b, a] }
  eq([M.payloadFor(a, [main, week]) === main, M.payloadFor(b, [main, week]) === week,
      M.payloadFor(item({ path: "/x.org", line: 1 }), [main, week]), M.payloadFor(b, [main, null]),
      M.payloadFor(b, null), M.payloadFor(null, [main])],
     [true, true, null, null, null, null], "payloadFor: the bar's payload, then the week's")
}

// ---------------------------------------------------------------- timers: payload

// The clock started at 10:00 on 14 Oct on the "Hiring plan" row (line 130).
const S0 = on14(10, 0).getTime() / 1000
const sec = (h, m, s, ms) => new Date(2026, 9, 14, h, m, s || 0, ms || 0)
const clockAt = over => Object.assign({ title: "Hiring plan", category: "work", path: "/home/u/org/cal.org", line: 130,
                                        startedAt: S0, baseMin: 0, effortMin: null }, over)
const pomAt = over => Object.assign({ available: true, state: "none", endsAt: null, phaseMin: null, count: 0,
                                      askKill: true }, over)
const timerPayload = (clock, pom) => Object.assign(weekPayload(weekItems), { clock: clock, pomodoro: pom || pomAt({}) })
const TV = (clock, pom, now, settings, status) =>
  M.view(parsed(timerPayload(clock, pom)).value, status || "ok", "", now || on14(10, 40), settings || {})
const NO_POMODORO = { available: false, state: "none", endsAt: null, phaseMin: null, count: 0, askKill: true }
const clockOf = raw => parsed(timerPayload(raw)).value.clock
const pomOf = raw => parsed(Object.assign(weekPayload([]), { pomodoro: raw })).value.pomodoro
// A pomodoro started at 10:00: 25 min, the third since the long break.
const POM = pomAt({ state: "pomodoro", endsAt: S0 + 1500, phaseMin: 25, count: 2 })
const OVER = pomAt({ state: "overtime", endsAt: S0 + 1500, phaseMin: 25, count: 3 })
const SHORT = pomAt({ state: "short-break", endsAt: S0 + 1800, phaseMin: 5, count: 3 })
const LONG = pomAt({ state: "long-break", endsAt: S0 + 1800, phaseMin: 20, count: 0 })

eq(clockOf(clockAt({ effortMin: 60, baseMin: 12 })),
   { title: "Hiring plan", category: "work", path: "/home/u/org/cal.org", line: 130, startedAt: S0, baseMin: 12, effortMin: 60 },
   "normalize clock: valid")
eq([clockOf(clockAt({ startedAt: "x" })), clockOf(clockAt({ startedAt: -1 })), clockOf(clockAt({ startedAt: 0 })),
    clockOf(clockAt({ startedAt: S0 + 0.5 })), clockOf(clockAt({ startedAt: S0 * 1000 })), clockOf(clockAt({ startedAt: null })),
    clockOf("x"), clockOf([clockAt({})]), clockOf(undefined)],
   [null, null, null, null, null, null, null, null, null], "normalize clock: bad startedAt or not an object -> null")
eq([clockOf(clockAt({ path: "org/cal.org" })), clockOf(clockAt({ path: null, line: 5 })), clockOf(clockAt({ line: 0 })),
    clockOf(clockAt({ line: "130" })), clockOf(clockAt({ path: "/a\u0001.org" }))].map(c => [c.path, c.line]),
   [[null, null], [null, null], ["/home/u/org/cal.org", null], ["/home/u/org/cal.org", null], [null, null]],
   "normalize clock: relative path, line without path, bad line")
eq([-5, 2.5, "3", null, 7].map(b => clockOf(clockAt({ baseMin: b })).baseMin), [0, 0, 0, 0, 7],
   "normalize clock: baseMin a non-negative int, else 0")
eq([0, -3, "60", 1.5, null, 45].map(e => clockOf(clockAt({ effortMin: e })).effortMin), [null, null, null, null, null, 45],
   "normalize clock: effort a positive int, else null")
{
  const c = clockOf(clockAt({ title: "a\tb\n" + "x".repeat(300), category: "w\u0001" }))
  eq([c.title.slice(0, 4), Array.from(c.title).length, c.category, clockOf(clockAt({ title: 3 })).title],
     ["a b ", 200, null, ""], "normalize clock: title cleaned and bounded, bad category null")
}
eq([pomOf(undefined), pomOf("x"), pomOf({})], [NO_POMODORO, NO_POMODORO, NO_POMODORO], "normalize pomodoro: defaults")
eq(pomOf({ available: true, state: "pomodoro", endsAt: S0, phaseMin: 25.5, count: 4, askKill: false }),
   { available: true, state: "pomodoro", endsAt: S0, phaseMin: 25.5, count: 4, askKill: false }, "normalize pomodoro: valid, float phase")
eq([pomOf({ state: "paused", endsAt: S0 }), pomOf({ state: "none", endsAt: S0, phaseMin: 25 })].map(p => [p.state, p.endsAt]),
   [["none", null], ["none", null]], "normalize pomodoro: unknown state -> none; endsAt null for none")
eq([pomOf({ available: "yes", state: "overtime", endsAt: "S0", phaseMin: 0, count: -1, askKill: "no" }),
    pomOf({ state: "long-break", endsAt: S0 * 1000, phaseMin: "25", count: 1.5, askKill: null })],
   [{ available: false, state: "overtime", endsAt: null, phaseMin: null, count: 0, askKill: true },
    { available: false, state: "long-break", endsAt: null, phaseMin: null, count: 0, askKill: true }],
   "normalize pomodoro: bad fields -> defaults")
{
  // An elisp before 0.4 sends neither key.
  const old = parsed(weekPayload(weekItems)).value
  const v = M.view(old, "ok", "", on14(10, 40), {})
  eq([old.clock, old.pomodoro, v.timer, M.pomodoroStep(v, false)], [null, NO_POMODORO, null, null],
     "normalize: an old payload has no clock, pomodoro unavailable")
  const raw = JSON.parse(M.elispStringValue(OUT_WEEK))
  const w = M.parseWeekResult(JSON.stringify(Object.assign({}, raw, { clock: clockAt({}), pomodoro: POM })))
  eq([w.ok, w.value.clock, w.value.pomodoro], [true, null, NO_POMODORO], "parseWeekResult: a week's timers are ignored")
}

// ---------------------------------------------------------------- timers: timerState

eq([on14(10, 0), on14(10, 23), on14(11, 5), on14(22, 0), sec(10, 23, 59)].map(n => TV(clockAt({}), null, n).timer.time.text),
   ["0:00", "0:23", "1:05", "12:00", "0:23"], "timerState clock: H:MM, whole minutes")
eq([TV(clockAt({ baseMin: 75 }), null, sec(10, 0, 59)).timer.barTime, TV(clockAt({ baseMin: 600 }), null, on14(10, 5)).timer.barTime,
    TV(clockAt({}), null, on14(9, 0)).timer.barTime],
   ["1:15", "10:05", "0:00"], "timerState clock: earlier minutes added; a clock ahead of now shows 0:00")
eq(TV(clockAt({ effortMin: 60 }), null, on14(10, 23)).timer,
   { kind: "clock", caption: "CLOCKED IN", title: "Hiring plan", time: { text: "0:23", tone: "normal" },
     extra: " / 1:00 effort", progress: 23 / 60, tone: "accent", glyph: "◷", clockKey: "/home/u/org/cal.org:130",
     barTime: "0:23" }, "timerState clock: with effort")
eq([on14(11, 0), on14(11, 1), on14(13, 0)].map(n => { const t = TV(clockAt({ effortMin: 60 }), null, n).timer; return [t.time, t.progress] }),
   [[{ text: "1:00", tone: "normal" }, 1], [{ text: "1:01", tone: "urgent" }, 1], [{ text: "3:00", tone: "urgent" }, 1]],
   "timerState clock: at the effort normal, past it urgent; progress capped")
eq([TV(clockAt({}), null, on14(10, 23)).timer.extra, TV(clockAt({}), null, on14(10, 23)).timer.progress,
    TV(clockAt({ effortMin: 150 }), null, on14(10, 23)).timer.extra],
   ["", null, " / 2:30 effort"], "timerState clock: without effort; effort as H:MM")
{
  const v = TV(clockAt({}), POM, sec(10, 12, 19))
  eq(v.timer, { kind: "pomodoro", caption: "POMODORO 3", title: "Hiring plan", time: { text: "13m", tone: "normal" },
                extra: " left", progress: 739 / 1500, tone: "urgent", glyph: "●", clockKey: "/home/u/org/cal.org:130",
                barTime: "13m" }, "timerState pomodoro: wins over the clock, minutes")
  eq([M.timerState(v, sec(10, 12, 19), true).time.text, M.timerState(v, sec(10, 12, 19).getTime(), true).barTime],
     ["12:41", "13m"], "timerState pomodoro: M:SS with seconds (Date or ms); barTime stays minutes")
  eq([on14(10, 0), sec(10, 24, 30), on14(10, 25), on14(10, 30)].map(n => {
    const t = M.timerState(v, n, true); return [t.time.text, M.timerState(v, n, false).time.text, t.progress] }),
     [["25:00", "25m", 0], ["0:30", "1m", 1470 / 1500], ["0:00", "0m", 1], ["0:00", "0m", 1]],
     "timerState pomodoro: 25:00 at start, never negative")
  eq([M.timerState(v, sec(10, 12, 19, 500), true), M.timerState(v, sec(10, 12, 19, 500), false)].map(t => t.time.text),
     ["12:41", "13m"], "timerState pomodoro: seconds rounded up")
}
{
  const t = TV(null, POM, sec(10, 12, 19)).timer
  eq([t.kind, t.title, t.clockKey, t.caption], ["pomodoro", "", "", "POMODORO 3"], "timerState pomodoro: after a manual clock-out")
  eq([TV(null, pomAt({ state: "pomodoro", endsAt: S0 + 1500, count: 0 }), on14(10, 5)).timer.progress,
      TV(null, pomAt({ state: "pomodoro", endsAt: S0 + 1500, count: 0 }), on14(10, 5)).timer.caption],
     [null, "POMODORO 1"], "timerState pomodoro: no phase length -> no progress; count 0 -> POMODORO 1")
}
{
  const v = TV(clockAt({}), OVER, sec(10, 28, 10))
  eq(v.timer, { kind: "overtime", caption: "OVERTIME", title: "Hiring plan", time: { text: "+4m", tone: "urgent" },
                extra: " over", progress: 1, tone: "urgent", glyph: "●", clockKey: "/home/u/org/cal.org:130", barTime: "+4m" },
     "timerState overtime: counts up from endsAt")
  eq([M.timerState(v, sec(10, 28, 10), true).time.text, M.timerState(v, on14(10, 25), true).time.text,
      M.timerState(v, on14(10, 25), false).time.text], ["+3:10", "+0:00", "+0m"], "timerState overtime: +M:SS")
}
eq(TV(null, SHORT, on14(10, 26)).timer,
   { kind: "short-break", caption: "SHORT BREAK", title: "", time: { text: "4m", tone: "normal" }, extra: " left",
     progress: 0.2, tone: "accent", glyph: "◌", clockKey: "", barTime: "4m" }, "timerState: a short break")
{
  const t = TV(clockAt({}), LONG, on14(10, 26)).timer
  eq([t.kind, t.caption, t.title, t.glyph, t.tone, t.clockKey, M.timerState(TV(clockAt({}), LONG), on14(10, 26), true).time.text],
     ["long-break", "LONG BREAK", "Hiring plan", "◌", "accent", "/home/u/org/cal.org:130", "4:00"],
     "timerState: a long break with the clock running (org-pomodoro-clock-break)")
}
eq([TV(clockAt({}), null, on14(10, 40), {}, "stale").timer, TV(clockAt({}), POM, on14(10, 40), {}, "offline").timer,
    TV(clockAt({}), null, on14(10, 40), {}, "error").timer, TV(null, null).timer, TV(null, pomAt({ available: true })).timer,
    M.timerState(TV(clockAt({})), new Date(NaN), false), M.timerState(null, on14(10, 40), false)],
   [null, null, null, null, null, null, null], "timerState: null unless ok and something runs")
eq([TV(clockAt({ path: "rel.org" })).timer.clockKey, TV(clockAt({ line: null })).timer.clockKey],
   ["", ""], "timerState: no clockKey for a non-file buffer")
eq(M.timerState(Object.assign({}, TV(clockAt({})), { payload: Object.assign({}, TV(clockAt({})).payload,
     { pomodoro: pomAt({ state: "pomodoro", endsAt: null }) }) }), on14(10, 40), false).kind,
   "clock", "timerState: a phase without its end shows the clock")

// ---------------------------------------------------------------- timers: bar and tooltip

{
  const idle = V().label
  const lab = (clock, pom, settings, now) => TV(clock, pom, now || on14(10, 23), settings).label
  const CL = { glyph: "◷", time: "0:23", tone: "accent" }
  eq(lab(clockAt({})), L("timer", "Hiring plan", idle.badge, idle.alert, CL), "barLabel timer: next item shows the clock")
  eq(lab(clockAt({}), null, { maxTitleChars: 10 }).text, "Hiring pl…", "barLabel timer: title bounded")
  eq([lab(clockAt({}), null, { label: "Count" }), lab(clockAt({}), null, { label: "Icon" })],
     [L("count", "", idle.badge, idle.alert, CL), L("icon", "", 0, idle.alert, CL)],
     "barLabel timer: Count shows the time instead of the count, Icon the time; no titles")
  eq(lab(clockAt({}), null, { overdueBadge: false }).badge, 0, "barLabel timer: overdueBadge false")
  eq(lab(clockAt({ effortMin: 10 })).timer, { glyph: "◷", time: "0:23", tone: "urgent" }, "barLabel timer: overrun is urgent")
  eq([lab(clockAt({}), POM, {}, sec(10, 12, 19)), lab(null, POM, {}, sec(10, 12, 19)), lab(null, OVER, {}, sec(10, 28, 10))],
     [L("timer", "Hiring plan", idle.badge, idle.alert, { glyph: "●", time: "13m", tone: "urgent" }),
      L("timer", "", idle.badge, idle.alert, { glyph: "●", time: "13m", tone: "urgent" }),
      L("timer", "", idle.badge, idle.alert, { glyph: "●", time: "+4m", tone: "urgent" })],
     "barLabel timer: pomodoro and overtime")
  eq([lab(null, SHORT, {}, on14(10, 26)), lab(clockAt({}), LONG, {}, on14(10, 26)).text,
      lab(null, SHORT, { label: "Count" }, on14(10, 26)).text],
     [L("timer", "break", idle.badge, idle.alert, { glyph: "◌", time: "4m", tone: "accent" }), "Hiring plan", ""],
     "barLabel timer: a break, with and without the clock")
  eq([lab(null, null), lab(null, null, { label: "Count" }).text], [idle, V(undefined, { label: "Count" }).label.text],
     "barLabel timer: idle as before")
  eq([TV(clockAt({}), null, on14(10, 23), {}, "offline").label, TV(clockAt({}), null, on14(10, 23), {}, "stale").label.timer],
     [L("offline", "", 0, false), null], "barLabel timer: none while Emacs isn't reachable")
}
{
  const first = (clock, pom, now, settings) => TV(clock, pom, now, settings).tooltip.split("\n")[0]
  const idle = V().tooltip
  eq([first(clockAt({ effortMin: 60 }), null, on14(10, 23)), first(clockAt({}), null, on14(10, 23)),
      first(clockAt({}), POM, sec(10, 12, 19)), first(null, POM, sec(10, 12, 19)), first(clockAt({}), OVER, sec(10, 28, 10)),
      first(null, SHORT, on14(10, 26)), first(clockAt({}), LONG, on14(10, 26))],
     ["Clocked in: Hiring plan · 0:23 / 1:00", "Clocked in: Hiring plan · 0:23", "Pomodoro 3: Hiring plan · 13m left",
      "Pomodoro 3 · 13m left", "Overtime: Hiring plan · +4m", "Short break · 4m left", "Long break: Hiring plan · 4m left"],
     "tooltip timer: first line per kind")
  eq(TV(clockAt({}), null, on14(10, 40)).tooltip.split("\n").slice(1).join("\n"), idle, "tooltip timer: then the existing lines")
  eq([first(clockAt({ effortMin: 60 }), null, on14(10, 23), { label: "Icon" }),
      first(clockAt({}), POM, sec(10, 12, 19), { label: "Icon" }),
      first(clockAt({}), null, on14(10, 23), { label: "Count" })],
     ["Clocked in · 0:23 / 1:00", "Pomodoro 3 · 13m left", "Clocked in: Hiring plan · 0:23"],
     "tooltip timer: Icon hides the title as it hides the next item's; Count shows it")
  eq(/[<>]/.test(TV(clockAt({ title: "<img src=x>" }), null, on14(10, 23)).tooltip), false, "tooltip timer: markup neutralised")
}

// ---------------------------------------------------------------- timers: row tint

{
  const clocked = m => {
    const out = []
    m.panes.forEach(p => p.blocks.forEach(b => {
      if (b.kind === "row" && b.clocked) out.push("row " + b.item.line)
      if (b.kind === "chips") b.chips.forEach(c => { if (c.clocked) out.push("chip " + c.item.line) })
    }))
    return out
  }
  const rowAt = (m, line) => concatRows(m).filter(b => b.item.line === line)[0]
  const concatRows = m => m.panes.reduce((acc, p) => acc.concat(p.blocks.filter(b => b.kind === "row")), [])
  const onLine = line => TV(clockAt({ line: line }), null, on14(10, 23))
  const org = LM(onLine(130), { layout: "Org" })
  eq([clocked(org), rowAt(org, 130).clock, rowAt(org, 130).trail, rowAt(org, 110).clock, rowAt(org, 110).clocked],
     [["row 130"], "◷ 0:23", null, "", false], "row tint Org: the clocked row and its clock text")
  eq(concatRows(LM(v14, { layout: "Org" })).every(b => b.clocked === false && b.clock === ""), true,
     "row tint Org: nothing clocked without a timer")
  const tabs = [["today", 130], ["week", 161], ["overdue", 140]].map(([tab, line]) => {
    const m = LM(onLine(line), { layout: "Tabs", tab: tab })
    return [clocked(m), rowAt(m, line).trail, rowAt(m, line).clock]
  })
  eq(tabs, [[["row 130"], { text: "◷ 0:23", tone: "accent" }, undefined],
            [["row 161"], { text: "◷ 0:23", tone: "accent" }, undefined],
            [["row 140"], { text: "◷ 0:23", tone: "accent" }, undefined]], "row tint Tabs: each tab, the trail is the time")
  eq(rowAt(LM(v14, { layout: "Tabs", tab: "today" }), 130).trail, { text: "work", tone: "muted" }, "row tint Tabs: trail unchanged unclocked")
  const cols = LM(onLine(100), { layout: "Columns" })
  eq([clocked(cols), clocked(LM(onLine(120), { layout: "Columns" }))], [["chip 100"], ["row 120"]],
     "row tint Columns: a habit chip, a right-pane row")
  eq(LM(v14, { layout: "Columns" }).panes[0].blocks.filter(b => b.kind === "chips")[0].chips.map(c => c.clocked),
     [false, false], "row tint Columns: chips unclocked without a timer")
  // The clock on an entry of next week's payload.
  const rep = TV(clockAt({ line: 200 }), POM, sec(10, 12, 19))
  const wk = LM(rep, { layout: "Org", offset: 1, week: nextWeek })
  eq([clocked(wk), rowAt(wk, 200).clock], [["row 200"], "● 13m"], "row tint: a week payload's row, pomodoro text")
  eq(rowAt(LM(rep, { layout: "Tabs", tab: "week", offset: 1, week: nextWeek }), 200).trail, { text: "● 13m", tone: "urgent" },
     "row tint: a week payload's list row in the pomodoro's tone")
  const same = ui => [LM(v14, ui), LM(TV(clockAt({ line: 130 })), ui), LM(TV(clockAt({ line: 100 }), POM), ui)]
    .map(m => JSON.stringify(m.rows.map(r => [r.key, r.sel, r.pane])))
  eq([{ layout: "Org" }, { layout: "Tabs", tab: "today" }, { layout: "Tabs", tab: "week" }, { layout: "Tabs", tab: "overdue" },
      { layout: "Columns" }, { layout: "Org", offset: 1, week: nextWeek }].map(ui => same(ui).every((s, i, a) => s === a[0])),
     [true, true, true, true, true, true], "row tint: keys and sel unchanged")
  eq(clocked(LM(TV(clockAt({ path: null })), { layout: "Org" })), [], "row tint: a clock outside a file tints nothing")
}

// ---------------------------------------------------------------- timers: keys

{
  const act = (over, key, text) => M.keyAction(Object.assign({ layout: "Org", tab: "today", pickerOpen: false }, over), key, text)
  const caps = ["I", "O", "X", "J", "P"]
  eq([{}, { clocking: true }, { pomodoroAvailable: true }, { clocking: true, pomodoroAvailable: true, pomodoro: "pomodoro" }]
       .map(c => caps.map(k => act(c, "", k))),
     [[{ clock: "in" }, null, null, null, null],
      [{ clock: "in" }, { clock: "out" }, { clock: "cancel" }, { clock: "goto" }, null],
      [{ clock: "in" }, null, null, null, { pomodoro: true }],
      [{ clock: "in" }, { clock: "out" }, { clock: "cancel" }, { clock: "goto" }, { pomodoro: true }]],
     "keyAction: I O X J P gated on the clock and org-pomodoro")
  const all = { clocking: true, pomodoroAvailable: true }
  eq(["j", "k", "p", "n", "i", "o", "x"].map(k => act(all, "", k)),
     [{ move: 1 }, { move: -1 }, { move: -1 }, { move: 1 }, null, null, null], "keyAction: lowercase keep their meaning")
  const conf = Object.assign({ confirming: true }, all)
  eq([act(conf, "", "P"), act(conf, "", "p"), act(conf, "", "j"), act(conf, "Down", ""), act(conf, "Escape", ""),
      act(conf, "Return", ""), act(conf, "", "I"), act(conf, "", ""), act(conf, "", "ab")],
     [{ pomodoro: "stop" }, { cancelConfirm: true }, { cancelConfirm: true }, { cancelConfirm: true }, { cancelConfirm: true },
      { cancelConfirm: true }, { cancelConfirm: true }, null, null],
     "keyAction: the stop question takes the next key; a bare modifier leaves it")
  eq([act(Object.assign({ pickerOpen: true }, conf), "", "P"), act(Object.assign({ pickerOpen: true }, all), "", "I"),
      act(Object.assign({ pickerOpen: true }, all), "", "O")], [null, null, null], "keyAction: the picker still wins")
}
{
  const states = ["none", "pomodoro", "overtime", "short-break", "long-break"]
  const step = (state, askKill, confirming, available) =>
    M.pomodoroStep(TV(null, pomAt({ state: state, endsAt: state === "none" ? null : S0 + 1500, askKill: askKill,
                                    available: available !== false })), confirming)
  eq(states.map(s => [step(s, true, false), step(s, true, true), step(s, false, false), step(s, false, true)]),
     [["start", "start", "start", "start"], ["ask", "stop", "stop", "stop"], ["break", "break", "break", "break"],
      ["ask", "stop", "stop", "stop"], ["ask", "stop", "stop", "stop"]], "pomodoroStep: every state, askKill, confirming")
  eq([states.map(s => step(s, true, false, false)), M.pomodoroStep(null, false), M.pomodoroStep(V(), false)],
     [[null, null, null, null, null], null, null], "pomodoroStep: null without org-pomodoro")
}

// ---------------------------------------------------------------- timers: forms

{
  const qp = payloadOf([item({ path: "/home/u/org/it's \"q\".org", line: 7, todo: "NEXT", id: "x\") (shell-command \"rm\")" })],
                       { keywords: KW })
  eq([M.clockInForm(task, sp, ELISP), M.clockInForm(sp.items[4], sp, ELISP).split(PRE)[1],
      M.clockInForm(sync, sp, ELISP).split(PRE)[1], M.clockInForm(qp.items[0], qp, ELISP).split(PRE)[1]],
     ["(progn " + PRE + " (omarchy-org-agenda-clock-in \"/home/u/org/cal.org\" 20 nil \"TODO\"))",
      " (omarchy-org-agenda-clock-in \"/home/u/org/cal.org\" 80 \"e-1\" \"TODO\"))",
      " (omarchy-org-agenda-clock-in \"/home/u/org/cal.org\" 63 nil nil))",
      " (omarchy-org-agenda-clock-in \"/home/u/org/it's \\\"q\\\".org\" 7 nil \"NEXT\"))"],
     "clockInForm: exact, id, FROM nil, hostile path and id")
  eq([M.clockOutForm(ELISP), M.clockCancelForm(ELISP), M.clockGotoForm(ELISP)],
     ["(progn " + PRE + " (omarchy-org-agenda-clock-out))", "(progn " + PRE + " (omarchy-org-agenda-clock-cancel))",
      "(progn " + PRE + " (omarchy-org-agenda-clock-goto))"], "clock out/cancel/goto forms")
  const clocked = c => parsed(timerPayload(c)).value
  eq([M.clockFallbackArgs({ socketName: "work" }, clocked(clockAt({}))),
      M.clockFallbackArgs({}, clocked(clockAt({ path: "rel.org" }))),
      M.clockFallbackArgs({}, clocked(clockAt({ line: 0 }))),
      M.clockFallbackArgs({}, clocked(null)), M.clockFallbackArgs({}, null)],
     [["emacsclient", "-s", "work", "-w", "5", "-r", "-n", "+130", "/home/u/org/cal.org"], null, null, null, null],
     "clockFallbackArgs: the clock's file and line, else null")
  eq([M.pomodoroForm(task, sp, false, ELISP), M.pomodoroForm(sp.items[4], sp, true, ELISP).split(PRE)[1],
      M.pomodoroForm(null, sp, true, ELISP).split(PRE)[1], M.pomodoroForm(undefined, null, false, ELISP).split(PRE)[1],
      M.pomodoroForm(null, null, "yes", ELISP).split(PRE)[1]],
     ["(progn " + PRE + " (omarchy-org-agenda-pomodoro \"/home/u/org/cal.org\" 20 nil \"TODO\" nil))",
      " (omarchy-org-agenda-pomodoro \"/home/u/org/cal.org\" 80 \"e-1\" \"TODO\" t))",
      " (omarchy-org-agenda-pomodoro nil nil nil nil t))", " (omarchy-org-agenda-pomodoro nil nil nil nil nil))",
      " (omarchy-org-agenda-pomodoro nil nil nil nil nil))"], "pomodoroForm: start, confirm, break/stop")
  const bad = [item({ line: 21 }), item({ path: "/etc/passwd", line: 20 }), sp.items[3],
               Object.assign({}, task, { todo: "BOGUS" }), Object.assign({}, task, { todo: "TO DO" }), {}]
  eq([bad.map(it => throws(() => M.clockInForm(it, sp, ELISP))), bad.map(it => throws(() => M.pomodoroForm(it, sp, false, ELISP))),
      [throws(() => M.clockInForm(task, null, ELISP)), throws(() => M.clockInForm(task, sp, "rel.el")),
       throws(() => M.clockOutForm("rel.el")), throws(() => M.pomodoroForm(null, null, true, "rel.el"))]],
     [[true, true, true, true, true, true], [true, true, true, true, true, true], [true, true, true, true]],
     "clock forms: unknown entries, sexps, bad keywords and relative files throw")
  eq([M.clockInForm(nextWeek.items[1], nextWeek, ELISP).split(PRE)[1], throws(() => M.clockInForm(nextWeek.items[1], sp, ELISP))],
     [" (omarchy-org-agenda-clock-in \"/home/u/org/cal.org\" 201 nil \"TODO\"))", true],
     "clockInForm: checked against the payload the row came from")
}

// ---------------------------------------------------------------- timers: results

{
  const out = obj => JSON.stringify(JSON.stringify(Object.assign({ state: null, saved: false, detail: null }, obj))) + "\n"
  const values = ["done", "note", "note-frame", "changed", "conflict", "busy", "invalid", "error", "not-clocking",
                  "needs-emacs", "unavailable", "confirm"]
  eq(values.map(r => M.parseActionResult(out({ result: r })).value.result), values, "parseActionResult: every result value")
  eq(M.parseActionResult(out({ result: "done", state: "NEXT", saved: true, detail: null })),
     { ok: true, value: { result: "done", state: "NEXT", saved: true, detail: null } }, "parseActionResult: done")
  eq(M.parseActionResult(out({ result: "needs-emacs", detail: "Start the clock from then? " })).value.detail,
     "Start the clock from then? ", "parseActionResult: needs-emacs detail")
  eq([M.parseActionResult(out({ result: "blocked" })).ok, M.parseStateResult(out({ result: "blocked" })).ok,
      M.parseStateResult(out({ result: "not-clocking" })).ok, M.parseStateResult(OUT_DONE).ok],
     [false, true, false, true], "parseActionResult vs parseStateResult: each its own results")
  eq(["", null, "t\n", "nil\n", "\"not json\"", "\"[1]\"", "*ERROR*: No running clock", "\"{\\\"result\\\":\\\"maybe\\\"}\""]
       .map(s => M.parseActionResult(s).ok), [false, false, false, false, false, false, false, false],
     "parseActionResult: garbage -> not ok")
}
{
  const msg = (a, v) => M.actionMessage(a, Object.assign({ state: null, saved: false, detail: null }, v))
  eq(["in", "out", "cancel", "start", "break", "stop"].map(a => msg(a, { result: "done", saved: true })),
     ["Clocked in · saved", "Clocked out · saved", "Clock cancelled · saved", "Pomodoro started · saved",
      "Break started · saved", "Pomodoro stopped · saved"].map(t => ({ text: t, tone: "ok" })), "actionMessage: done")
  eq([msg("in", { result: "done", state: "NEXT", saved: true }), msg("out", { result: "done" }),
      msg("out", { result: "done", detail: "Permission denied" }), msg("out", { result: "note" }),
      msg("start", { result: "note-frame" }),
      msg("in", { result: "needs-emacs", detail: "You stopped another clock 5 mins ago; start this one from then? " }),
      msg("in", { result: "needs-emacs", detail: "Org wants to ask something; do it in Emacs" }),
      msg("in", { result: "needs-emacs" }), msg("out", { result: "not-clocking" }),
      msg("start", { result: "unavailable", detail: "org-pomodoro can't be loaded" }), msg("stop", { result: "confirm" }),
      msg("in", { result: "changed" }), msg("in", { result: "conflict" }), msg("out", { result: "busy" }),
      msg("in", { result: "invalid", detail: "no such entry" }),
      msg("start", { result: "error", detail: "boom; no pomodoro started; the clock is still running" }),
      msg("in", { result: "weird" }), M.actionMessage("bogus", { result: "done", saved: true })],
     [{ text: "Clocked in · now NEXT · saved", tone: "ok" },
      { text: "Clocked out · not saved: the file had unsaved edits in Emacs", tone: "warn" },
      { text: "Clocked out · not saved: Permission denied", tone: "warn" },
      { text: "Clocked out · add your note in Emacs", tone: "ok" },
      { text: "Pomodoro started · opening Emacs for your note", tone: "ok" },
      { text: "Org wants to ask: You stopped another clock 5 mins ago; start this one from then? — do it in Emacs", tone: "warn" },
      { text: "Org wants to ask something — do it in Emacs", tone: "warn" },
      { text: "Org wants to ask something — do it in Emacs", tone: "warn" },
      { text: "No clock running", tone: "warn" },
      { text: "org-pomodoro isn't available: org-pomodoro can't be loaded", tone: "error" },
      { text: "Stop the pomodoro? P again", tone: "warn" },
      { text: "This entry changed in Emacs. The agenda is refreshing; try again.", tone: "warn" },
      { text: "The file changed on disk and has unsaved edits in Emacs. Resolve it there first.", tone: "error" },
      { text: "Emacs is waiting for another note. Finish it first.", tone: "warn" },
      { text: "Emacs refused this entry: no such entry", tone: "error" },
      { text: "Couldn't start the pomodoro: boom; no pomodoro started; the clock is still running", tone: "error" },
      { text: "Couldn't clock in: unexpected answer from Emacs", tone: "error" },
      { text: "Done · saved", tone: "ok" }], "actionMessage: every result")
  eq([M.actionMessage("in", null).tone, msg("in", { result: "needs-emacs", detail: "<b>?</b>" }).text.indexOf("<"),
      Array.from(msg("in", { result: "error", detail: "y".repeat(400) }).text).length <= 300],
     ["error", -1, true], "actionMessage: bad input, markup neutralised, bounded")
}

// ---------------------------------------------------------------- timers: hints

{
  const ctxs = [undefined, { clocking: false, pomodoroAvailable: false }, { clocking: false, pomodoroAvailable: true },
                { clocking: true, pomodoroAvailable: false }, { clocking: true, pomodoroAvailable: true }]
  const hints = ["Org", "Tabs", "Columns"].map(l => ctxs.map(c => M.layoutHints(l, c)))
  eq(hints.map(h => h[0]), ["Org", "Tabs", "Columns"].map(l => M.layoutHints(l)), "layoutHints: no timer ctx as before")
  eq(hints[0].slice(1), ["↑↓ move · ↵ open · t state · I clock · f b week · v layout · esc",
                         "↑↓ move · ↵ open · t state · I clock · P pomodoro · f b week · v layout · esc",
                         "↑↓ move · ↵ open · t state · O out · J jump · f b week · v layout · esc",
                         "↑↓ move · ↵ open · t state · O out · J jump · P pomodoro · f b week · esc"],
     "layoutHints Org: timer hints, refresh then layout make room")
  eq(hints[2].slice(1), ["← → column · ↑↓ move · ↵ open · t state · I clock · f b week · v layout · esc",
                         "← → column · ↑↓ move · ↵ open · t state · I clock · P pomodoro · f b week · esc",
                         "← → column · ↑↓ move · ↵ open · t state · O out · J jump · f b week · esc",
                         "← → column · ↑↓ move · ↵ open · t state · O out · J jump · P pomodoro · esc"],
     "layoutHints Columns: timer hints fit the prefix")
  eq(hints[1][4], "1 2 3 tabs · ↑↓ move · ↵ open · t state · O out · J jump · P pomodoro · esc", "layoutHints Tabs: the longest")
  eq(hints.map(h => h.map(s => s.length <= 80)), [[true, true, true, true, true], [true, true, true, true, true],
     [true, true, true, true, true]], "layoutHints: every combination ≤ 80 chars")
  eq(hints.map(h => h.slice(1).every(s => s.indexOf("r refresh") < 0)), [true, true, true], "layoutHints: refresh leaves with a timer hint")
}

eq([M.PROTOCOL, M.MAX_ITEMS, M.MAX_TITLE, M.NOW_GRACE_MIN, M.STALE_AFTER_MS, M.ID_RE.test("a:b")],
   [1, 200, 200, 30, 60000, true], "constants")

console.log((failed ? "FAIL " : "ok   ") + (count - failed) + "/" + count + " passed")
process.exit(failed ? 1 : 0)
