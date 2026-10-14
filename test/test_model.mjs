// Everything in Model.js runs under plain node, so the parts of the widget
// that are decisions rather than drawing can be pinned here.
//
//   node test/test_model.mjs
//
// Prints one line per group and exits non-zero on the first failure.

import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"
import path from "node:path"

const require = createRequire(import.meta.url)
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const Model = require(path.join(root, "Model.js"))

const PAPERCLIP = ""
const BELL = ""

// Every state the probe can put in a report. derive_state() in
// bin/omarchy-paperclip-status is the other half of this list.
const STATES = [
  "unknown", "not-installed", "stopped", "needs-auth", "untrusted-listener",
  "probe-failed", "needs-you", "working", "idle"
]

function group(name, body) {
  body()
  console.log("ok - " + name)
}

group("the mark is a paperclip in every state", () => {
  assert.equal(Model.GLYPH_PAPERCLIP, PAPERCLIP)
  assert.equal(Model.GLYPH_BELL, undefined, "the bell is gone for good")
  for (const state of STATES) {
    assert.equal(Model.stateGlyph(state), PAPERCLIP, state + " must still be a paperclip")
  }
})

group("state tones and labels", () => {
  assert.equal(Model.stateTone("stopped"), "alarm")
  assert.equal(Model.stateTone("untrusted-listener"), "alarm")
  assert.equal(Model.stateTone("probe-failed"), "alarm")
  assert.equal(Model.stateTone("needs-you"), "attention")
  assert.equal(Model.stateTone("working"), "working")
  assert.equal(Model.stateTone("idle"), "quiet")
  assert.equal(Model.stateTone("unknown"), "quiet")
  for (const state of STATES) {
    assert.ok(Model.stateLabel(state).length > 0, state + " needs a label")
  }
})

group("the tiles report the three counts", () => {
  const tiles = Model.statTiles({ attention: 1, working: 3, failedRuns: 2 })
  assert.deepEqual(tiles.map((t) => t.key), ["attention", "working", "failed"])
  assert.deepEqual(tiles.map((t) => t.value), [1, 3, 2])
  assert.deepEqual(tiles.map((t) => t.tone), ["attention", "working", "alarm"])
  // Singulars, because "1 agents working" is how a panel looks unfinished.
  assert.equal(tiles[0].label, "needs you")
  assert.equal(Model.statTiles({ working: 1 })[1].label, "agent working")
  assert.equal(Model.statTiles({ failedRuns: 1 })[2].label, "failed run")

  const empty = Model.statTiles(null)
  assert.deepEqual(empty.map((t) => t.value), [0, 0, 0])
  assert.deepEqual(empty.map((t) => t.tone), ["quiet", "quiet", "quiet"])
})

group("the cards filter the lists and never the counts", () => {
  const report = {
    attention: 3, working: 2, failedRuns: 1, inboxTotal: 3, retryableCount: 1,
    needs: [{ kind: "failed_run", title: "a" }, { kind: "approval", title: "b" }, { kind: "approval", title: "c" }],
    moving: [{ title: "w1" }, { title: "w2" }]
  }
  const need = (f) => Model.filterNeedRows(report.needs, f).map((r) => r.title)
  const move = (f) => Model.filterMovingRows(report.moving, f).map((r) => r.title)

  assert.deepEqual(need(""), ["a", "b", "c"])
  assert.deepEqual(move(""), ["w1", "w2"])
  assert.deepEqual(need(Model.TILE_ATTENTION), ["a", "b", "c"])
  assert.deepEqual(move(Model.TILE_ATTENTION), [])
  assert.deepEqual(need(Model.TILE_WORKING), [])
  assert.deepEqual(move(Model.TILE_WORKING), ["w1", "w2"])
  assert.deepEqual(need(Model.TILE_FAILED), ["a"])
  assert.deepEqual(move(Model.TILE_FAILED), [])

  // The card shows its own count whatever the filter hides.
  assert.deepEqual(Model.statTiles(report).map((t) => t.value), [3, 2, 1])

  // A card at zero cannot hold the filter; one with rows can.
  assert.equal(Model.activeTileFilter(report, "failed"), "failed")
  assert.equal(Model.activeTileFilter({ working: 0 }, "working"), "")
  assert.equal(Model.activeTileFilter(report, "nonsense"), "")
  assert.equal(Model.activeTileFilter(null, "attention"), "")

  // Clicking the selected card clears it; another card replaces it.
  assert.equal(Model.toggleTileFilter("", "failed"), "failed")
  assert.equal(Model.toggleTileFilter("failed", "failed"), "")
  assert.equal(Model.toggleTileFilter("failed", "working"), "working")

  // Under the failed filter, "more waiting" counts failed runs, not the inbox.
  assert.equal(Model.moreWaiting({ inboxTotal: 9, retryableCount: 4 }, 1, "failed"), 3)
  assert.equal(Model.moreWaiting({ inboxTotal: 9, retryableCount: 4 }, 1, ""), 8)
})

group("the footer only advertises keys that do something", () => {
  // Nothing in the inbox: no row verbs, because there is no row to use them on.
  const quiet = Model.hintKeys({ state: "idle" }).map((h) => h.key)
  assert.deepEqual(quiet, ["o", "z", "r", "d", "n"])
  // No Paperclip yet: `s` is set up, and there is no inbox to snooze.
  const fresh = Model.hintKeys({ state: "not-installed" }).map((h) => h.key)
  assert.deepEqual(fresh, ["o", "s", "z", "r", "d", "n"])

  // Rows, but nothing with a failed attempt: no `t`, no `T`.
  const waiting = Model.hintKeys({
    state: "needs-you",
    needs: [{ key: "a", kind: "review", title: "Read this" }],
    retryableCount: 0
  }).map((h) => h.key)
  assert.deepEqual(waiting, ["o", "a", "f", "s", "x", "z", "r", "d", "n"])

  // Something failed: the retry keys appear.
  const failing = Model.hintKeys({
    state: "needs-you",
    needs: [{ key: "b", kind: "failed_run", title: "Kai run failed", retryable: true }],
    retryableCount: 4
  }).map((h) => h.key)
  assert.deepEqual(failing, ["o", "a", "f", "t", "T", "s", "x", "z", "r", "d", "n"])

  for (const hint of Model.hintKeys(null)) {
    assert.equal(hint.key.length, 1)
    assert.ok(hint.label.length > 0)
  }
})

group("the filter and the notification level accept what was stored before", () => {
  // The names these settings used to have still mean what they meant.
  assert.equal(Model.normalizeNotifyLevel("Needed"), Model.NOTIFY_NEEDED)
  assert.equal(Model.normalizeNotifyLevel("All"), Model.NOTIFY_ALL)
  assert.equal(Model.normalizeNotifyLevel("Off"), Model.NOTIFY_OFF)
  assert.equal(Model.normalizeNotifyLevel("Everything"), Model.NOTIFY_ALL)
  assert.equal(Model.normalizeNotifyLevel("Needs-me"), Model.NOTIFY_NEEDED)
  // An unreadable value is "needs me", never "off": a filter that fails must
  // not fail silent.
  assert.equal(Model.normalizeNotifyLevel(""), Model.NOTIFY_NEEDED)
  assert.equal(Model.normalizeNotifyLevel(null), Model.NOTIFY_NEEDED)

  assert.equal(Model.normalizeInboxFilter("All"), Model.INBOX_ALL)
  assert.equal(Model.normalizeInboxFilter("all"), Model.INBOX_ALL)
  assert.equal(Model.normalizeInboxFilter("Needs-me"), Model.INBOX_NEEDS_ME)
  assert.equal(Model.normalizeInboxFilter(undefined), Model.INBOX_NEEDS_ME)

  // What goes back into shell.json has to be one of the options the settings
  // dropdown lists, or the panel's own choice reads as unset.
  for (const stored of ["Needs-me", "All"]) {
    assert.equal(Model.inboxFilterSetting(Model.normalizeInboxFilter(stored)), stored)
  }
})

group("the bubble counts the rows the panel lists", () => {
  // The whole point of SCE-242: the number is the length of a list, not a
  // clock. `deskBadgeCount` is never read, so it cannot appear here.
  const report = Model.parseReport(JSON.stringify({
    state: "needs-you", reachable: true, attention: 147, inboxTotal: 147,
    inboxShown: 60, retryableCount: 124, deskBadgeCount: 9,
    needs: [{ key: "a", kind: "failed_run", title: "Kai run failed", retryable: true }]
  }))
  assert.equal(report.inboxTotal, 147)
  assert.equal(Model.badgeText(report), "99+")
  assert.equal(Model.retryableCount(report), 124)
  // 147 open, 1 listed: the rest is named, not hidden.
  assert.equal(Model.moreWaiting(report, 1), 146)
  assert.equal(Model.moreWaiting(report, 147), 0)
  // Clearing the inbox takes it to zero, and it stays there.
  const clean = Model.parseReport(JSON.stringify({
    state: "idle", reachable: true, attention: 0, inboxTotal: 0, deskBadgeCount: 4
  }))
  assert.equal(Model.badgeText(clean), "")
  assert.equal(Model.moreWaiting(clean, 0), 0)

  // The tile and the Retry all counter are the same number.
  assert.equal(Model.statTiles(report)[0].value, 147)
  assert.equal(Model.statTiles(report)[2].value, 124)
  // Seen on the rig: the last failed row cleared, two runs still failed
  // recently. The tile follows the inbox and reads 0.
  const cleared = Model.parseReport(JSON.stringify({
    state: "idle", reachable: true, attention: 3, inboxTotal: 3, retryableCount: 0, failedRuns: 2
  }))
  assert.equal(Model.statTiles(cleared)[2].value, 0)
})

group("the bubble is red for errors and urgency, not for length", () => {
  const long = {
    state: "needs-you", inboxTotal: 90, working: 0,
    needs: [{ key: "a", kind: "blocker_attention", severity: "normal" }]
  }
  assert.equal(Model.badgeTone(long), "waiting")
  const urgent = {
    state: "needs-you", inboxTotal: 2,
    needs: [{ key: "a", kind: "review", severity: "critical" }]
  }
  assert.equal(Model.badgeTone(urgent), "attention")
  const broken = {
    state: "needs-you", inboxTotal: 2,
    needs: [{ key: "a", kind: "failed_run", severity: "high", isError: true }]
  }
  assert.equal(Model.badgeTone(broken), "alarm")
  assert.equal(Model.badgeTone({ state: "stopped" }), "alarm")
  assert.equal(Model.badgeTone({ state: "idle", inboxTotal: 0, working: 3 }), "working")
  assert.equal(Model.badgeTone({ state: "idle", inboxTotal: 0, working: 0 }), "quiet")
})

group("identical rows collapse, and a group keeps every member", () => {
  const rows = Model.parseReport(JSON.stringify({
    needs: [
      { key: "r1", kind: "failed_run", identifier: "SCE-250", title: "Kai run failed",
        retryable: true, retryKind: "run", agentId: "a", runId: "1" },
      { key: "r2", kind: "failed_run", identifier: "SCE-250", title: "Kai run failed",
        retryable: true, retryKind: "run", agentId: "a", runId: "2" },
      { key: "r3", kind: "failed_run", identifier: "SCE-250", title: "Kai run failed",
        retryable: true, retryKind: "run", agentId: "a", runId: "3" },
      { key: "b1", kind: "blocker_attention", identifier: "SCE-18", title: "Decodability" },
      // Same title, different task: a different row, not the same group.
      { key: "r4", kind: "failed_run", identifier: "SCE-39", title: "Kai run failed",
        retryable: true, retryKind: "run", agentId: "a", runId: "4" }
    ]
  })).needs

  const groups = Model.groupRows(rows)
  assert.deepEqual(groups.map((g) => g.count), [3, 1, 1])
  assert.deepEqual(groups.map((g) => g.retryableCount), [3, 0, 1])
  // Acting on a group has to be able to act on every row in it.
  assert.deepEqual(groups[0].members.map((m) => m.runId), ["1", "2", "3"])
  assert.equal(groups[1].kind, "blocker_attention")
  // A group of one is still a row, so the panel has one row shape only.
  assert.equal(groups[1].members.length, 1)
  assert.equal(Model.groupRows([]).length, 0)
  assert.equal(Model.groupRows(null).length, 0)
})

group("only a failed attempt gets a Try again", () => {
  const rows = Model.parseReport(JSON.stringify({
    needs: [
      { key: "a", kind: "failed_run", retryable: true, retryKind: "run" },
      { key: "b", kind: "recovery_action", retryable: true, retryKind: "recovery" },
      { key: "c", kind: "review", retryable: false },
      { key: "d", kind: "issue_thread_interaction" },
      { key: "e", kind: "blocker_attention" }
    ]
  })).needs
  assert.equal(Model.retryLabel(rows[0]), "Try again")
  assert.equal(Model.retryLabel(rows[1]), "Hand back")
  // A greyed-out button that lies about being available is worse than none.
  assert.equal(Model.retryLabel(rows[2]), "")
  assert.equal(Model.retryLabel(rows[3]), "")
  assert.equal(Model.retryLabel(rows[4]), "")
  assert.equal(Model.retryLabel(null), "")
})

group("a row carries what the write path needs", () => {
  const row = Model.parseReport(JSON.stringify({
    needs: [{
      key: "failed_run:run:xyz", kind: "failed_run", identifier: "SCE-250",
      title: "Kai run failed", itemKey: "attention:run:xyz", companyId: "co",
      retryable: true, retryKind: "run", agentId: "ag", runId: "xyz",
      issueId: "iss", isError: true
    }]
  })).needs[0]
  for (const field of ["itemKey", "companyId", "agentId", "runId", "retryKind"]) {
    assert.ok(String(row[field]).length > 0, field + " must survive the parse")
  }
  assert.equal(row.retryable, true)
  assert.equal(row.isError, true)
  assert.equal(row.count, 1)
  // An unknown row claims nothing, so no button is drawn for it.
  const bare = Model.parseReport(JSON.stringify({ needs: [{ key: "z" }] })).needs[0]
  assert.equal(bare.retryable, false)
  assert.equal(bare.itemKey, "")
  assert.equal(bare.hidden, false)
})

group("no notification carries a bell", () => {
  const seed = Model.parseReport(JSON.stringify({
    state: "idle", summary: "All quiet", reachable: true, needs: [], moving: []
  }))
  const busy = Model.parseReport(JSON.stringify({
    state: "needs-you",
    summary: "2 need you",
    reachable: true,
    attention: 2,
    needs: [
      { key: "a", identifier: "SCE-1", title: "Approve the plan", severity: "high" },
      { key: "b", identifier: "SCE-2", title: "Answer a question" }
    ],
    moving: [{ key: "r1", identifier: "SCE-3", title: "Writing", agent: "Kai" }]
  }))

  // First report is only ever remembered, never announced.
  const first = Model.diffNotifications(null, seed, Model.NOTIFY_NEEDED, {})
  assert.equal(first.notifications.length, 0)

  const cases = [
    Model.diffNotifications(seed, busy, Model.NOTIFY_NEEDED, {}),
    Model.diffNotifications(seed, busy, Model.NOTIFY_ALL, {}),
    // A wall of fresh rows summarizes instead of shouting ten times.
    Model.diffNotifications(seed, Model.parseReport(JSON.stringify({
      state: "needs-you",
      reachable: true,
      attention: 5,
      needs: [1, 2, 3, 4, 5].map((n) => ({ key: "k" + n, title: "Item " + n }))
    })), Model.NOTIFY_NEEDED, {}),
    // The instance going away, and coming back.
    Model.diffNotifications(busy, Model.parseReport(JSON.stringify({
      state: "stopped", summary: "Paperclip is not running", reachable: false
    })), Model.NOTIFY_NEEDED, {}),
    Model.diffNotifications(Model.parseReport(JSON.stringify({ state: "stopped", reachable: false })),
      seed, Model.NOTIFY_ALL, {}),
    // Nothing installed yet.
    Model.diffNotifications(seed, Model.parseReport(JSON.stringify({
      state: "not-installed", reachable: true
    })), Model.NOTIFY_NEEDED, {})
  ]

  let total = 0
  for (const result of cases) {
    for (const note of result.notifications) {
      total += 1
      assert.notEqual(note.glyph, BELL, note.key + " still carries a bell")
      assert.ok(
        note.glyph === PAPERCLIP || note.glyph === Model.GLYPH_OK,
        note.key + " carries an off-brand glyph"
      )
    }
  }
  assert.ok(total >= 6, "expected these cases to raise notifications, got " + total)

  // Off stays off.
  assert.equal(Model.diffNotifications(seed, busy, Model.NOTIFY_OFF, {}).notifications.length, 0)
})

group("the bar bubble counts what is waiting", () => {
  assert.equal(Model.badgeText(null), "")
  assert.equal(Model.badgeText({ state: "idle", attention: 0 }), "")
  assert.equal(Model.badgeText({ state: "needs-you", attention: 4 }), "4")
  assert.equal(Model.badgeText({ state: "needs-you", attention: 140 }), "99+")
  assert.equal(Model.badgeText({ state: "stopped" }), "!")
})

group("an error is announced as an error", () => {
  const quiet = Model.parseReport(JSON.stringify({
    state: "idle", reachable: true, needs: [], moving: []
  }))
  // Five fresh decisions and two fresh failures in one poll. The decisions may
  // be summarized; the failures may not disappear into that summary.
  const broken = Model.parseReport(JSON.stringify({
    state: "needs-you",
    reachable: true,
    attention: 7,
    needs: [
      { key: "f1", kind: "failed_run", identifier: "SCE-250", title: "Kai run failed",
        severity: "high", isError: true },
      { key: "f2", kind: "agent_error_alert", title: "Panel Engineer",
        severity: "high", isError: true },
      { key: "d1", kind: "review", title: "Read this" },
      { key: "d2", kind: "review", title: "And this" },
      { key: "d3", kind: "review", title: "And this too" },
      { key: "d4", kind: "review", title: "Still more" },
      { key: "d5", kind: "review", title: "Last one" }
    ]
  }))

  const out = Model.diffNotifications(quiet, broken, Model.NOTIFY_NEEDED, {})
  const keys = out.notifications.map((n) => n.key)
  assert.ok(keys.indexOf("error:f1") >= 0, "the failed run must speak for itself")
  assert.ok(keys.indexOf("error:f2") >= 0, "the agent error must speak for itself")
  assert.ok(keys.indexOf("needs:batch:5") >= 0, "five decisions summarize")
  // An agent-error row is titled with the agent's name alone, which on its own
  // reads like good news.
  const agentError = out.notifications.filter((n) => n.key === "error:f2")[0]
  assert.equal(agentError.summary, "Panel Engineer hit an error")

  // A storm of failures summarizes rather than papering the screen.
  const storm = Model.parseReport(JSON.stringify({
    state: "needs-you",
    reachable: true,
    needs: [1, 2, 3, 4, 5, 6, 7].map((n) => ({
      key: "s" + n, kind: "failed_run", title: "Kai run failed", isError: true
    }))
  }))
  const stormOut = Model.diffNotifications(quiet, storm, Model.NOTIFY_NEEDED, {})
  assert.equal(stormOut.notifications.filter((n) => n.key.indexOf("error:s") === 0).length, 3)
  assert.ok(stormOut.notifications.some((n) => n.key === "error:batch:7"))

  // The old stored value still means the same thing.
  assert.equal(Model.diffNotifications(quiet, broken, "Needed", {}).notifications.length,
               out.notifications.length)
  assert.equal(Model.diffNotifications(quiet, broken, "Off", {}).notifications.length, 0)
})

// ---------------------------------------------------------------- snooze
//
// Local-time cases build their `now` from parts, so they hold in any timezone.
const at = (h, m = 0, day = 15) => new Date(2026, 9, day, h, m, 0, 0).getTime()
const HOUR = 3600 * 1000

group("a snooze file that cannot be read means not snoozed", () => {
  for (const raw of ["", "nope", "[]", "null", "{}", '{"step":"forever","until":99}']) {
    assert.deepEqual(Model.parseSnooze(raw), Model.emptySnooze(), JSON.stringify(raw))
  }
  const good = Model.parseSnooze('{"step":"1h","until":5000,"focusUntil":7000}')
  assert.deepEqual(good, { step: "1h", until: 5000, focusUntil: 7000 })
  // An end time with no step is not a snooze.
  assert.equal(Model.parseSnooze('{"until":5000}').until, 0)
})

group("a snooze ends by itself, and `morning` is the next 09:00", () => {
  assert.equal(Model.snoozeEnds("1h", at(10)), at(11))
  assert.equal(Model.snoozeEnds("morning", at(22)), at(9, 0, 16))
  // Before 09:00 it is this morning, not a day and a half away.
  assert.equal(Model.snoozeEnds("morning", at(6)), at(9))
  // At 09:00 sharp the morning has come, so it means tomorrow's.
  assert.equal(Model.snoozeEnds("morning", at(9)), at(9, 0, 16))
  const s = { step: "1h", until: at(11), focusUntil: 0 }
  assert.equal(Model.snoozeActive(s, at(10, 59)), true)
  assert.equal(Model.snoozeActive(s, at(11)), false)
})

group("the snooze keys toggle and stretch", () => {
  const now = at(10)
  const awake = Model.emptySnooze()
  const hour = Model.toggleSnooze(awake, "1h", now)
  assert.deepEqual(hour, { step: "1h", until: at(11), focusUntil: 0 })
  // The same key again wakes the plugin.
  assert.equal(Model.snoozeActive(Model.toggleSnooze(hour, "1h", now), now), false)
  // The other key stretches the snooze instead of waking it.
  const morning = Model.toggleSnooze(hour, "morning", now)
  assert.equal(morning.step, "morning")
  assert.equal(morning.until, at(9, 0, 16))
  assert.equal(Model.snoozeActive(Model.toggleSnooze(morning, "morning", now), now), false)
  // An expired snooze is not on, so the key starts one.
  const stale = { step: "1h", until: at(9), focusUntil: 0 }
  assert.equal(Model.toggleSnooze(stale, "1h", now).until, at(11))
})

group("a plugin snooze always wins over a focus session", () => {
  const now = at(10)
  const focus = Model.toggleFocus(Model.emptySnooze(), true, now)
  assert.equal(focus.focusUntil, now + Model.FOCUS_LIMIT_MS)
  // Starting a snooze ends the focus session.
  assert.equal(Model.toggleSnooze(focus, "1h", now).focusUntil, 0)
  // And focus cannot start over a snooze.
  const snoozed = Model.toggleSnooze(Model.emptySnooze(), "1h", now)
  assert.deepEqual(Model.toggleFocus(snoozed, true, now), snoozed)
  // Focus has nothing to lift when Omarchy is awake.
  assert.deepEqual(Model.toggleFocus(Model.emptySnooze(), false, now), Model.emptySnooze())
  // Pressing it again ends it.
  assert.equal(Model.focusActive(Model.toggleFocus(focus, true, now), now), false)
  // Waking the plugin does not touch a running focus session.
  const both = { step: "1h", until: at(11), focusUntil: at(14) }
  assert.equal(Model.toggleSnooze(both, "1h", now).focusUntil, at(14))
})

group("the quiet state names who made the plugin quiet", () => {
  const now = at(10)
  const none = Model.emptySnooze()
  const hour = { step: "1h", until: at(11), focusUntil: 0 }
  const focus = { step: "", until: 0, focusUntil: at(12) }

  const awake = Model.quietState(none, false, now)
  assert.equal(awake.mode, "awake")
  assert.equal(awake.quiet, false)
  assert.equal(awake.toasts, true)
  assert.equal(awake.bypass, false)

  const plugin = Model.quietState(hour, false, now)
  assert.equal(plugin.mode, "plugin")
  assert.equal(plugin.quiet, true)
  assert.equal(plugin.toasts, false)
  assert.equal(plugin.headline, "Snoozed until 11:00")
  assert.equal(Model.quietState(
    { step: "morning", until: at(9, 0, 16), focusUntil: 0 }, false, now).headline,
    "Snoozed until tomorrow 09:00")

  // Omarchy's snooze: the same icon, and Omarchy keeps the toasts.
  const omarchy = Model.quietState(none, true, now)
  assert.equal(omarchy.mode, "omarchy")
  assert.equal(omarchy.quiet, true)
  assert.equal(omarchy.toasts, true, "Omarchy silences and records them itself")
  assert.equal(omarchy.bypass, false)
  assert.equal(omarchy.canFocus, true)

  // Focus lifts Omarchy's snooze: awake icon, toasts sent past it.
  const focused = Model.quietState(focus, true, now)
  assert.equal(focused.mode, "focus")
  assert.equal(focused.quiet, false)
  assert.equal(focused.bypass, true)
  // A stale focus flag with Omarchy awake is nothing at all.
  assert.equal(Model.quietState(focus, false, now).mode, "awake")
  assert.equal(Model.quietState(focus, true, at(12)).mode, "omarchy", "focus ran out")

  // A plugin snooze beats both Omarchy and a leftover focus flag.
  const stacked = Model.quietState({ step: "1h", until: at(11), focusUntil: at(12) }, true, now)
  assert.equal(stacked.mode, "plugin")
  assert.equal(stacked.bypass, false)
  assert.equal(stacked.canFocus, false)
})

group("the footer offers focus only while it has something to lift", () => {
  const keys = (mode) => Model.hintKeys({ state: "idle" }, { mode }).map((h) => h.key)
  assert.deepEqual(keys("awake"), ["o", "z", "r", "d", "n"])
  assert.deepEqual(keys("plugin"), ["o", "z", "r", "d", "n"])
  assert.deepEqual(keys("omarchy"), ["o", "z", "p", "r", "d", "n"])
  assert.deepEqual(keys("focus"), ["o", "z", "p", "r", "d", "n"])
  const label = (mode, key) =>
    Model.hintKeys({ state: "idle" }, { mode }).find((h) => h.key === key).label
  assert.equal(label("awake", "z"), "zzz")
  assert.equal(label("plugin", "z"), "wake")
  assert.equal(label("omarchy", "p"), "focus")
  assert.equal(label("focus", "p"), "end focus")
})

group("the tooltip says why the plugin is quiet", () => {
  const report = { summary: "2 need you", attention: 2, working: 0 }
  const quiet = Model.quietState({ step: "1h", until: at(11), focusUntil: 0 }, false, at(10))
  assert.match(Model.tooltipText(report, quiet), /^zzz Snoozed until 11:00\nPaperclip — 2 need you/)
  assert.equal(Model.tooltipText(report), "Paperclip — 2 need you")
})

group("a snooze that ends says so once, and never replays the backlog", () => {
  const waiting = { inboxTotal: 3, attention: 3 }
  const wake = Model.wakeNotification(waiting, Model.NOTIFY_NEEDED)
  assert.equal(wake.summary, "Snooze is over")
  assert.equal(wake.body, "3 things need you.")
  assert.equal(Model.wakeNotification({ inboxTotal: 1 }, Model.NOTIFY_ALL).body, "1 thing needs you.")
  assert.equal(Model.wakeNotification({ inboxTotal: 0 }, Model.NOTIFY_NEEDED), null)
  // Notifications off means off, snooze or no snooze.
  assert.equal(Model.wakeNotification(waiting, Model.NOTIFY_OFF), null)
  assert.equal(Model.wakeNotification(null, Model.NOTIFY_NEEDED), null)
})

group("text from the instance is inert in a notification", () => {
  const WJ = "\u2060"
  for (const hostile of ["--app-name=x", "-u", "--image=/x", "--exec", "-r", "  --replace-id=4"]) {
    for (const make of [Model.notificationSummary, Model.notificationBody]) {
      const out = make(hostile)
      assert.ok(out.startsWith(WJ), JSON.stringify(hostile) + " must not start with a dash")
      assert.ok(!/^\s*-/.test(out), JSON.stringify(out))
      assert.ok(out.endsWith(hostile), "the words are kept")
    }
  }
  assert.equal(Model.notificationBody("<b>x</b>"), "&lt;b&gt;x&lt;/b&gt;")
  assert.equal(Model.notificationBody("a & b"), "a &amp; b")
  assert.equal(Model.notificationBody("&lt;"), "&amp;lt;", "an entity is not decoded twice")
  assert.equal(Model.notificationBody("-<b>"), WJ + "-&lt;b&gt;")
  // The summary is drawn as plain text, so it is not escaped.
  assert.equal(Model.notificationSummary("a <b> & c"), "a <b> & c")
  assert.equal(Model.notificationSummary("Fix the build"), "Fix the build")
  assert.equal(Model.notificationBody("-50% off"), WJ + "-50% off")
  assert.equal(Model.notificationBody(undefined), "")
  assert.equal(Model.notificationBody(null), "")

  // A decision whose title is an option comes out of the diff, then through
  // the same functions the service uses.
  const row = { key: "a:1", kind: "approval", title: "--app-name=omarchy-action", detail: "<img src=x>", severity: "normal" }
  const diff = Model.diffNotifications(
    { reachable: true, needs: [], moving: [] },
    { reachable: true, needs: [row], moving: [] },
    Model.NOTIFY_NEEDED, {})
  assert.equal(diff.notifications.length, 1)
  const n = diff.notifications[0]
  assert.ok(Model.notificationSummary(n.summary).startsWith(WJ))
  assert.equal(Model.notificationBody(n.body), "&lt;img src=x&gt;")
})

group("a notification request carries the words as data for the helper", () => {
  const WJ = "\u2060"
  const item = { summary: "--app-name=x", body: "<b>why</b>", urgency: "critical", glyph: "G" }
  const exec = ["/p/open", "https://127.0.0.1:3100/PAP-1"]
  const req = Model.notificationRequest(item, "Paperclip", "F", exec)
  assert.deepEqual(req, { appName: "Paperclip", urgency: "critical", glyph: "G",
    summary: WJ + "--app-name=x", body: "&lt;b&gt;why&lt;/b&gt;", exec })
  const bare = Model.notificationRequest({}, "", "F", [])
  assert.deepEqual(bare, { appName: "Paperclip", urgency: "normal", glyph: "F",
    summary: "Paperclip", body: "" })
  assert.equal(Model.notificationRequest({ glyph: "" }, "omarchy-action", "", null).glyph, "")
  assert.equal(JSON.parse(JSON.stringify(req)).exec[1], exec[1])
})

console.log("all groups passed")
