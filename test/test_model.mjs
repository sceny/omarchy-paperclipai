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
import { readFileSync } from "node:fs"
import vm from "node:vm"

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
      { key: "a", kind: "approval", identifier: "SCE-1", title: "Approve the plan", severity: "high" },
      { key: "b", kind: "issue_thread_interaction", identifier: "SCE-2", title: "Answer a question" }
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
      needs: [1, 2, 3, 4, 5].map((n) => ({ key: "k" + n, kind: "approval", title: "Item " + n }))
    })), Model.NOTIFY_NEEDED, {}),
    // The instance going away, and coming back.
    Model.diffNotifications(busy, Model.parseReport(JSON.stringify({
      state: "stopped", summary: "Paperclip is not running", reachable: false
    })), Model.NOTIFY_ALL, {}),
    Model.diffNotifications(Model.parseReport(JSON.stringify({ state: "stopped", reachable: false })),
      seed, Model.NOTIFY_ALL, {}),
    // Nothing installed yet.
    Model.diffNotifications(seed, Model.parseReport(JSON.stringify({
      state: "not-installed", reachable: true
    })), Model.NOTIFY_ALL, {})
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

  // Off still marks what it saw: turning notifications back on replays nothing
  // that arrived while they were off (#126).
  const empty = Model.parseReport(JSON.stringify({ state: "idle", reachable: true, attention: 0 }))
  const two = Model.parseReport(JSON.stringify({
    state: "needs-you", reachable: true, attention: 2,
    needs: [{ key: "x", kind: "approval", title: "One" }, { key: "y", kind: "approval", title: "Two" }],
    moving: [{ key: "r9", title: "Running" }]
  }))
  for (const level of [Model.NOTIFY_NEEDED, Model.NOTIFY_ALL]) {
    let seen = Model.diffNotifications(null, empty, Model.NOTIFY_ALL, {}).seen
    const off = Model.diffNotifications(empty, two, Model.NOTIFY_OFF, seen)
    assert.equal(off.notifications.length, 0)
    const on = Model.diffNotifications(two, two, level, off.seen)
    assert.deepEqual(on.notifications.map((n) => n.key), [], level + " replayed what arrived at Off")
  }
})

group("a moment's outage replays nothing", () => {
  const report = (fields) => Model.parseReport(JSON.stringify(fields))
  const up = report({
    state: "needs-you",
    reachable: true,
    attention: 6,
    working: 1,
    needs: [
      { key: "f1", kind: "failed_run", title: "Kai run failed", isError: true },
      { key: "d1", kind: "approval", title: "Approve the plan" },
      { key: "d2", kind: "issue_thread_interaction", title: "Answer a question" },
      { key: "d3", title: "Read this" },
      { key: "d4", title: "And this" },
      { key: "d5", title: "Last one" }
    ],
    moving: [{ key: "run:1", title: "Writing", agent: "Kai" }]
  })
  const stopped = report({ state: "stopped", reachable: false })
  const crashed = report({ state: "probe-failed", summary: "Status probe failed" })

  for (const level of [Model.NOTIFY_ALL, Model.NOTIFY_NEEDED]) {
    for (const down of [stopped, crashed]) {
      let seen = Model.diffNotifications(null, up, level, {}).seen
      const gone = Model.diffNotifications(up, down, level, seen)
      seen = gone.seen
      if (down === stopped) {
        assert.deepEqual(gone.notifications.map((n) => n.key),
                         level === Model.NOTIFY_ALL ? ["instance:stopped"] : [], level)
      }
      const back = Model.diffNotifications(down, up, level, seen)
      const keys = back.notifications.map((n) => n.key)
      // Only the instance coming back, and only where that is asked for.
      assert.deepEqual(keys, level === Model.NOTIFY_ALL ? ["instance:started"] : [],
                       level + " after " + down.state + ": " + keys.join(", "))
    }
  }

  // A row really gone from a report that lists everything is still forgotten,
  // so it speaks again when it comes back.
  let seen = Model.diffNotifications(null, up, Model.NOTIFY_ALL, {}).seen
  const fewer = report({
    state: "needs-you", reachable: true, attention: 5, working: 0,
    needs: up.needs.filter((r) => r.key !== "d1"), moving: []
  })
  seen = Model.diffNotifications(up, fewer, Model.NOTIFY_ALL, seen).seen
  assert.ok(!seen.d1 && !seen["run:1"], "a finished row is forgotten")
  const again = Model.diffNotifications(fewer, up, Model.NOTIFY_ALL, seen)
  assert.deepEqual(again.notifications.map((n) => n.key).sort(), ["moving:run:1", "needs:d1"])

  // A report that lists less than there is forgets nothing: a token missing,
  // an inbox that could not be read, the bar's short list while the count says
  // more (the panel closing), a run list cut short.
  const partial = [
    report({ state: "needs-auth", reachable: true, authRequired: true }),
    report({ state: "idle", reachable: true, inboxStale: true, working: 1, moving: up.moving }),
    report({ state: "needs-you", reachable: true, attention: 6, working: 1,
             needs: up.needs.slice(0, 2), moving: up.moving })
  ]
  for (const short of partial) {
    let kept = Model.diffNotifications(null, up, Model.NOTIFY_ALL, {}).seen
    kept = Model.diffNotifications(up, short, Model.NOTIFY_ALL, kept).seen
    const after = Model.diffNotifications(short, up, Model.NOTIFY_ALL, kept)
    assert.deepEqual(after.notifications.map((n) => n.key).filter((k) => k !== "instance:started"), [],
                     short.state + " replayed rows")
  }
  // A list whose request failed reads as empty with a count of 0; its flag is
  // what says it is not. Neither list forgets on it.
  for (const failed of [
    report({ state: "idle", reachable: true, inboxStale: true, runsStale: true }),
    report({ state: "needs-you", reachable: true, attention: 6, working: 0, runsStale: true,
             needs: up.needs, moving: [] })
  ]) {
    let kept = Model.diffNotifications(null, up, Model.NOTIFY_ALL, {}).seen
    kept = Model.diffNotifications(up, failed, Model.NOTIFY_ALL, kept).seen
    assert.ok(kept["run:1"], "a run is kept when the run list failed")
    if (failed.inboxStale) assert.ok(kept.d1 && kept.f1, "rows are kept when the inbox failed")
    const after = Model.diffNotifications(failed, up, Model.NOTIFY_ALL, kept)
    assert.deepEqual(after.notifications.map((n) => n.key), [], "a failed list replayed rows")
  }
  // A run list cut short keeps runs, and still forgets an inbox row that is gone.
  let mixed = Model.diffNotifications(null, up, Model.NOTIFY_ALL, {}).seen
  mixed = Model.diffNotifications(up, report({
    state: "needs-you", reachable: true, attention: 5, working: 3,
    needs: up.needs.filter((r) => r.key !== "d1"), moving: []
  }), Model.NOTIFY_ALL, mixed).seen
  assert.ok(mixed["run:1"] && !mixed.d1)

  // Under `All` the list adds cleared rows the open count leaves out, so they
  // cannot fill a list that is cut: two open listed out of three open forgets
  // nothing, whatever the cleared rows bring the length to.
  const cutAll = report({
    state: "needs-you", reachable: true, inboxFilter: "all", attention: 3, inboxTotal: 3,
    working: 1, moving: up.moving,
    needs: [up.needs[1], up.needs[2],
            { key: "c1", title: "Cleared", hidden: true },
            { key: "c2", title: "Cleared too", hidden: true }]
  })
  let fromAll = Model.diffNotifications(null, up, Model.NOTIFY_ALL, {}).seen
  fromAll = Model.diffNotifications(up, cutAll, Model.NOTIFY_ALL, fromAll).seen
  assert.ok(fromAll.d3 && fromAll.f1, "an open row past a cut `All` list is kept")
})

group("the seen keys stay bounded on a busy instance whose lists are never whole", () => {
  // 200 open rows with 20 listed, 10 live runs with 6 listed, and every poll
  // brings new ids in both lists: nothing can be forgotten as gone, so only the
  // bound holds the map. Shell time must not grow with the session.
  const report = (fields) => Model.parseReport(JSON.stringify(Object.assign({
    state: "needs-you", reachable: true, attention: 200, working: 10
  }, fields)))
  const poll = (n) => report({
    needs: [{ key: "steady", kind: "approval", title: "Stays" }]
      .concat(Array.from({ length: 19 }, (_, i) => ({ key: "n" + n + "-" + i, kind: "approval", title: "Row" }))),
    moving: [{ key: "run:steady", title: "Stays" }]
      .concat(Array.from({ length: 5 }, (_, i) => ({ key: "run:" + n + "-" + i, title: "Run" })))
  })
  for (const level of [Model.NOTIFY_ALL, Model.NOTIFY_OFF]) {
    let previous = poll(0)
    let out = Model.diffNotifications(null, previous, level, {}, 0)
    let largest = 0
    for (let n = 1; n <= 5000; n++) {
      const next = poll(n)
      out = Model.diffNotifications(previous, next, level, out.seen, out.since)
      const size = Object.keys(out.seen).length
      if (size > largest) largest = size
      assert.ok(!out.notifications.some((t) => t.key.endsWith("steady")), level + ": a listed row spoke again")
      previous = next
    }
    assert.ok(largest <= Model.MAX_SEEN_KEYS, level + ": " + largest + " seen keys")
    assert.equal(largest, Model.MAX_SEEN_KEYS, level + ": the bound is what holds the map")
    for (const row of previous.needs.concat(previous.moving)) {
      assert.ok(out.seen[row.key], level + ": the last list is remembered: " + row.key)
    }
    assert.ok(!out.seen["n1-0"] && !out.seen["run:1-0"], level + ": the oldest keys went first")
  }

  // The order is the poll a key was last listed on, not the object's own: a key
  // that reads as a number sorts first in an object, and still goes when old.
  let seen = Model.diffNotifications(null, report({ needs: [{ key: "7", title: "Old" }] }),
                                     Model.NOTIFY_ALL, {}, 0).seen
  for (let n = 1; n <= Model.MAX_SEEN_KEYS; n++) {
    seen = Model.diffNotifications(report({}), report({ needs: [{ key: "k" + n, title: "Row" }] }),
                                   Model.NOTIFY_ALL, seen, 0).seen
  }
  assert.ok(!seen["7"] && seen["k1"], "an old key that reads as a number stayed")

  // A report bigger than the bound still leaves the map at the bound.
  const flood = report({ attention: 2000,
                         needs: Array.from({ length: 2000 }, (_, i) => ({ key: "f" + i, title: "Row" })) })
  assert.equal(Object.keys(Model.diffNotifications(null, flood, Model.NOTIFY_ALL, {}, 0).seen).length,
               Model.MAX_SEEN_KEYS)
})

group("opening the panel toasts nothing that was waiting at the start", () => {
  // The bar's probe lists 20 rows, the open panel's up to 60; the count is the
  // whole inbox either way. Rows past the first 20 were waiting all along.
  const start = Date.parse("2026-10-09T17:00:00Z")
  const report = (fields) => Model.parseReport(JSON.stringify(Object.assign({
    state: "needs-you", reachable: true, generatedAt: "2026-10-09T17:00:00Z", moving: []
  }, fields)))
  const row = (n, at) => ({ key: "r" + n, kind: "approval", title: "Item " + n, activityMs: at })
  const old = (n) => row(n, start - 3600 * 1000 - n)
  const rows = (count, make) => Array.from({ length: count }, (_, i) => (make || old)(i + 1))
  const closed = report({ attention: 30, needs: rows(20) })
  const opened = report({ attention: 30, needs: rows(30), generatedAt: "2026-10-09T17:01:00Z" })

  for (const level of [Model.NOTIFY_ALL, Model.NOTIFY_NEEDED]) {
    const first = Model.diffNotifications(null, closed, level, {}, 0)
    assert.equal(first.since, start, "a short first list keeps the session's start")
    const open = Model.diffNotifications(closed, opened, level, first.seen, first.since)
    assert.deepEqual(open.notifications.map((n) => n.key), [], level + ": rows past the short list toasted")
    assert.ok(open.seen.r30, "the rows it held back are seen")
    assert.equal(open.since, 0, "a list of every row ends the start's cover")

    // A row really new since the start still speaks, even when it first shows
    // past the bar's short list.
    const later = report({ attention: 31, generatedAt: "2026-10-09T17:02:00Z",
                           needs: rows(30).concat([row(99, start + 90 * 1000)]) })
    const late = Model.diffNotifications(closed, later, level, first.seen, first.since)
    assert.deepEqual(late.notifications.map((n) => n.key), ["needs:r99"], level)

    // A row with no time cannot show it is new, so it waits with the rest.
    const bare = (count) => report({ attention: 30, needs: rows(count, (n) => row(n, 0)) })
    const seeded = Model.diffNotifications(null, bare(20), level, {}, 0)
    assert.deepEqual(Model.diffNotifications(bare(20), bare(30), level, seeded.seen, seeded.since)
      .notifications.map((n) => n.key), [], level + ": a row with no time toasted")

    // Off keeps the same cover: a session that started at Off and is turned on
    // before the panel first opens toasts none of the rows that waited.
    const quiet = Model.diffNotifications(null, closed, Model.NOTIFY_OFF, {}, 0)
    assert.equal(quiet.since, start, "Off's first short list keeps the session's start")
    const turnedOn = Model.diffNotifications(closed, opened, level, quiet.seen, quiet.since)
    assert.deepEqual(turnedOn.notifications.map((n) => n.key), [], level + ": Off then on toasted the backlog")

    // A whole list seen at Off ends the cover, so after notifications are
    // turned on a row that leaves and comes back speaks again.
    const offOpen = Model.diffNotifications(closed, opened, Model.NOTIFY_OFF, quiet.seen, quiet.since)
    assert.equal(offOpen.since, 0, "a list of every row at Off ends the start's cover")
    const shorter = report({ attention: 29, needs: rows(30).slice(1), generatedAt: "2026-10-09T17:02:00Z" })
    const left = Model.diffNotifications(opened, shorter, level, offOpen.seen, offOpen.since)
    const returned = Model.diffNotifications(shorter, opened, level, left.seen, left.since)
    assert.deepEqual(returned.notifications.map((n) => n.key), ["needs:r1"], level + ": a returning row stayed quiet")
  }

  // An instance down at the start does not replay its inbox when it comes up.
  const down = report({ state: "stopped", reachable: false })
  const first = Model.diffNotifications(null, down, Model.NOTIFY_ALL, {}, 0)
  const up = Model.diffNotifications(down, closed, Model.NOTIFY_ALL, first.seen, first.since)
  assert.deepEqual(up.notifications.map((n) => n.key), ["instance:started"])

  // A first list that holds every row needs no cover: what comes back after it
  // was gone speaks again, however old its time.
  const whole = report({ attention: 3, needs: rows(3) })
  const seed = Model.diffNotifications(null, whole, Model.NOTIFY_ALL, {}, 0)
  assert.equal(seed.since, 0)
  const fewer = report({ attention: 2, needs: rows(3).slice(1) })
  const gone = Model.diffNotifications(whole, fewer, Model.NOTIFY_ALL, seed.seen, seed.since)
  const back = Model.diffNotifications(fewer, whole, Model.NOTIFY_ALL, gone.seen, gone.since)
  assert.deepEqual(back.notifications.map((n) => n.key), ["needs:r1"])

  // The probe's time survives the parse; anything else is no time.
  assert.equal(report({ needs: [row(1, 1234)] }).needs[0].activityMs, 1234)
  assert.equal(report({ needs: [row(1, "soon")] }).needs[0].activityMs, 0)
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

  const out = Model.diffNotifications(quiet, broken, Model.NOTIFY_ALL, {})
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
  const stormOut = Model.diffNotifications(quiet, storm, Model.NOTIFY_ALL, {})
  assert.equal(stormOut.notifications.filter((n) => n.key.indexOf("error:s") === 0).length, 3)
  assert.ok(stormOut.notifications.some((n) => n.key === "error:batch:7"))

  // The old stored values still mean the same thing.
  assert.equal(Model.diffNotifications(quiet, broken, "all", {}).notifications.length,
               out.notifications.length)
  assert.equal(Model.diffNotifications(quiet, broken, "Off", {}).notifications.length, 0)
})

group("needs-me announces pending decisions and nothing else", () => {
  const quiet = Model.parseReport(JSON.stringify({
    state: "idle", reachable: true, needs: [], moving: []
  }))
  const mixed = Model.parseReport(JSON.stringify({
    state: "needs-you",
    reachable: true,
    needs: [
      { key: "f1", kind: "failed_run", title: "Kai run failed", isError: true },
      { key: "e1", kind: "agent_error_alert", title: "Panel Engineer", isError: true },
      { key: "x1", kind: "recovery_action", title: "Hand back", isError: true },
      { key: "r1", kind: "review", title: "Read this" },
      { key: "b1", kind: "blocker_attention", title: "Unblock this" },
      { key: "m1", kind: "budget_alert", title: "Budget at 90%" },
      { key: "u1", title: "No kind at all" },
      { key: "a1", kind: "approval", title: "Approve the hire" },
      { key: "d1", kind: "decision", title: "Pick one" },
      { key: "q1", kind: "issue_thread_interaction", title: "Answer a question" },
      { key: "j1", kind: "join_request", title: "Let them in" }
    ],
    moving: [{ key: "w1", title: "Writing", agent: "Kai" }]
  }))
  const out = Model.diffNotifications(quiet, mixed, Model.NOTIFY_NEEDED, {})
  assert.deepEqual(out.notifications.map((n) => n.key).sort(),
    ["needs:batch:4"], "four fresh decisions summarize, and nothing else speaks")
  // Every row is remembered, so moving to Everything later replays nothing.
  for (const key of ["f1", "e1", "x1", "r1", "b1", "m1", "u1", "a1", "d1", "q1", "j1", "w1"]) {
    assert.ok(out.seen[key], key + " is remembered")
  }
  assert.equal(Model.diffNotifications(mixed, mixed, Model.NOTIFY_ALL, out.seen).notifications.length, 0)

  const one = Model.diffNotifications(quiet, Model.parseReport(JSON.stringify({
    state: "needs-you", reachable: true,
    needs: [
      { key: "f1", kind: "failed_run", title: "Kai run failed", isError: true },
      { key: "q1", kind: "issue_thread_interaction", identifier: "SCE-9", title: "Answer a question" }
    ]
  })), Model.NOTIFY_NEEDED, {})
  assert.deepEqual(one.notifications.map((n) => n.key), ["needs:q1"])
  assert.equal(one.notifications[0].summary, "SCE-9 Answer a question")

  // The instance's own state is on the bar icon; only Everything toasts it.
  const stopped = Model.parseReport(JSON.stringify({ state: "stopped", reachable: false }))
  assert.equal(Model.diffNotifications(quiet, stopped, Model.NOTIFY_NEEDED, {}).notifications.length, 0)
  assert.equal(Model.diffNotifications(quiet, stopped, Model.NOTIFY_ALL, {}).notifications[0].key,
    "instance:stopped")
  const bare = Model.parseReport(JSON.stringify({ state: "not-installed", reachable: true }))
  assert.equal(Model.diffNotifications(quiet, bare, Model.NOTIFY_NEEDED, {}).notifications.length, 0)

  // Wall of decisions at needs-me says what they are.
  assert.equal(out.notifications[0].summary, "4 decisions wait for you")
  // The legacy stored value is needs-me.
  assert.equal(Model.diffNotifications(quiet, mixed, "Needed", {}).notifications.length, 1)

  assert.equal(Model.isDecisionKind("approval"), true)
  assert.equal(Model.isDecisionKind("review"), false)
  assert.equal(Model.isDecisionKind(""), false)
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
  const waiting = { inboxTotal: 5, attention: 5,
    inboxCounts: { approval: 2, issue_thread_interaction: 1, failed_run: 2 } }
  const wake = Model.wakeNotification(waiting, Model.NOTIFY_NEEDED)
  assert.equal(wake.summary, "Snooze is over")
  // Needs-me counts only the decisions, over the server's counts by kind.
  assert.equal(wake.body, "3 decisions wait for you.")
  assert.equal(Model.wakeNotification({ inboxTotal: 2, inboxCounts: { join_request: 1, review: 1 } },
    Model.NOTIFY_NEEDED).body, "1 decision waits for you.")
  assert.equal(Model.wakeNotification({ inboxTotal: 4, inboxCounts: { failed_run: 4 } },
    Model.NOTIFY_NEEDED), null, "no decision waiting, nothing to say")
  assert.equal(Model.wakeNotification(waiting, Model.NOTIFY_ALL).body, "5 things need you.")
  assert.equal(Model.wakeNotification({ inboxTotal: 1 }, Model.NOTIFY_ALL).body, "1 thing needs you.")
  assert.equal(Model.wakeNotification({ inboxTotal: 0 }, Model.NOTIFY_NEEDED), null)
  // Notifications off means off, snooze or no snooze.
  assert.equal(Model.wakeNotification(waiting, Model.NOTIFY_OFF), null)
  assert.equal(Model.wakeNotification(null, Model.NOTIFY_NEEDED), null)
})

group("a cleared row never toasts, and toasts once when it comes back", () => {
  const quiet = Model.parseReport(JSON.stringify({
    state: "idle", reachable: true, needs: [], moving: []
  }))
  // The All inbox filter lists what you cleared, so it can be found. A row
  // snoozed in Paperclip never reaches the report (the probe drops it).
  const listed = Model.parseReport(JSON.stringify({
    state: "needs-you", reachable: true, inboxFilter: "all",
    needs: [
      { key: "a1", kind: "approval", title: "Approve the hire", hidden: true },
      { key: "d1", kind: "decision", title: "Pick one", hidden: true },
      { key: "f1", kind: "failed_run", title: "Kai run failed", isError: true, hidden: true }
    ]
  }))
  for (const level of [Model.NOTIFY_NEEDED, Model.NOTIFY_ALL]) {
    const out = Model.diffNotifications(quiet, listed, level, {})
    assert.equal(out.notifications.length, 0, level + ": nothing cleared speaks")
    assert.ok(!out.seen.a1 && !out.seen.d1 && !out.seen.f1, level + ": hidden rows stay unseen")
  }
  // Not on the first report of the session either.
  const first = Model.diffNotifications(null, listed, Model.NOTIFY_NEEDED, {})
  assert.ok(!first.seen.a1, "a hidden row is not remembered as seen at start")
  // Even a row seen before it was cleared is forgotten while hidden.
  const before = Model.diffNotifications(listed, listed, Model.NOTIFY_NEEDED, { a1: true })
  assert.ok(!before.seen.a1)
  // New activity on it: the row is open again, and that is one toast.
  const back = Model.parseReport(JSON.stringify({
    state: "needs-you", reachable: true, inboxFilter: "all",
    needs: [{ key: "a1", kind: "approval", title: "Approve the hire" }]
  }))
  assert.deepEqual(Model.diffNotifications(listed, back, Model.NOTIFY_NEEDED, before.seen)
    .notifications.map((n) => n.key), ["needs:a1"])

  // The wake toast reads the server's counts, which are the open inbox under
  // either filter: what you snoozed or cleared is not in them.
  const waking = { inboxFilter: "all", inboxTotal: 1, inboxCounts: { approval: 1 },
    needs: [{ key: "a1", kind: "approval" }, { key: "d1", kind: "decision", hidden: true }] }
  assert.equal(Model.wakeNotification(waking, Model.NOTIFY_NEEDED).body, "1 decision waits for you.")
  assert.equal(Model.wakeNotification({ ...waking, inboxTotal: 0, inboxCounts: {} },
    Model.NOTIFY_NEEDED), null, "nothing open: nothing to say")
})

group("a cleared row the All filter lists is not counted as open", () => {
  const groups = Model.groupRows([
    { key: "a", kind: "review", title: "One" },
    { key: "b", kind: "review", title: "One", hidden: true },
    { key: "c", kind: "approval", title: "Two", hidden: true },
    { key: "d", kind: "approval", title: "Three" }
  ])
  assert.equal(Model.openListed(groups), 2)
  assert.equal(Model.openListed([]), 0)
  assert.equal(Model.openListed(null), 0)
  // Against the open count: two open listed out of five open is three more.
  assert.equal(Model.moreWaiting({ inboxTotal: 5 }, Model.openListed(groups), ""), 3)
})

group("the snooze-over count at Everything leaves out what you snoozed or cleared", () => {
  // Under `All` the probe takes its total from the open inbox, so the cleared
  // rows it lists are not in it, and a cut list does not change it.
  const listed = {
    inboxFilter: Model.INBOX_ALL, inboxTotal: 1, inboxShown: 3, attention: 1,
    needs: [
      { key: "a", kind: "approval", hidden: false },
      { key: "b", kind: "failed_run", hidden: true },
      { key: "c", kind: "issue_thread_interaction", hidden: true }
    ]
  }
  assert.equal(Model.wakeNotification(listed, Model.NOTIFY_ALL).body, "1 thing needs you.")
  // Nothing open: nothing to say, whatever the list holds.
  assert.equal(Model.wakeNotification({ ...listed, inboxTotal: 0, attention: 0 }, Model.NOTIFY_ALL), null)
  const cut = { ...listed, inboxTotal: 9, attention: 9 }
  assert.equal(Model.wakeNotification(cut, Model.NOTIFY_ALL).body, "9 things need you.")
  // The same count under `Needs-me`.
  assert.equal(Model.wakeNotification({ ...cut, inboxFilter: Model.INBOX_NEEDS_ME }, Model.NOTIFY_ALL).body,
    "9 things need you.")
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
  assert.equal(Model.notificationBody("<b>x</b>"), "\u2039b\u203ax\u2039/b\u203a")
  assert.equal(Model.notificationBody("a & b"), "a &" + WJ + " b")
  assert.equal(Model.notificationBody("&lt;"), "&" + WJ + "lt;", "no entity is left to decode")
  assert.equal(Model.notificationBody("-<b>"), WJ + "-\u2039b\u203a")
  assert.equal(Model.notificationBody("see https://x.example/a"), "see https:" + WJ + "//x.example/a")
  // The summary is drawn as plain text, so it keeps its characters; only a url is broken.
  assert.equal(Model.notificationSummary("a <b> & c"), "a <b> & c")
  assert.equal(Model.notificationSummary("Fix the build"), "Fix the build")
  assert.equal(Model.notificationSummary("see http://x.example"), "see http:" + WJ + "//x.example")
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
  assert.equal(Model.notificationBody(n.body), "\u2039img src=x\u203a")
})

// Omarchy's notification daemon renders a body itself (Markup.render: entity
// decode up to three passes, the allowed tags and <a href> put back, bare urls
// linked) and draws the result as StyledText. Our text is checked against that
// renderer, not against our own escape. CI has no Omarchy, so the two files are
// vendored and pinned in test/vendor/omarchy-notifications/README.md.
function loadOmarchyMarkup() {
  const dir = path.join(root, "test", "vendor", "omarchy-notifications")
  const qmlJs = (name) => readFileSync(path.join(dir, name), "utf8").replace(/^\.(pragma|import)\b.*$/gm, "")
  const Security = vm.createContext({})
  vm.runInContext(qmlJs("Security.js"), Security)
  const Markup = vm.createContext({ Security })
  vm.runInContext(qmlJs("Markup.js"), Markup)
  return Markup
}

group("text from the instance is drawn inert by Omarchy's own renderer", () => {
  const Markup = loadOmarchyMarkup()
  // The renderer is live: unprotected, these do become tags and links.
  assert.match(Markup.render('&lt;a href="https://pay.example/x"&gt;Open&lt;/a&gt;'), /<a href=/)
  assert.match(Markup.render("&amp;lt;b&amp;gt;x"), /<b>/)
  assert.match(Markup.render("see https://evil.example/x"), /<a href=/)

  const hostile = [
    '<a href="https://pay.example/approve">Open the approval in Paperclip</a>',
    '&lt;a href="https://pay.example/approve"&gt;Open&lt;/a&gt;',
    '&amp;lt;a href=&amp;quot;https://pay.example/&amp;quot;&amp;gt;Open&amp;lt;/a&amp;gt;',
    '&amp;amp;lt;b&amp;amp;gt;triple&amp;amp;lt;/b&amp;amp;gt;',
    "&amp;lt;b&amp;gt;URGENT&amp;lt;/b&amp;gt;",
    "<b>URGENT</b> see https://evil.example/x",
    "<i>i</i> <u>u</u> <s>s</s> <em>em</em> <strong>st</strong> <br/>",
    "&#60;b&#62;dec&#60;/b&#62; &#x3c;i&#x3e;hex&#x3c;/i&#x3e;",
    "<a href='mailto:x@evil.example'>mail</a>",
    "http://evil.example HTTPS://EVIL.EXAMPLE https: //evil.example",
    "https:\\\\evil.example",
    "-<b>dash</b>"
  ]
  // No tag at all but the line breaks the renderer adds, so no <a, <b, <i,
  // <u, <s and no href inside a tag.
  const banned = /<(?!br\/>)|<[^>]*href/i
  for (const text of hostile) {
    const row = { key: "r:1", kind: "issue_thread_interaction", title: text, detail: text, severity: "normal" }
    const diff = Model.diffNotifications(
      { reachable: true, needs: [], moving: [] },
      { reachable: true, needs: [row], moving: [] },
      Model.NOTIFY_NEEDED, {})
    assert.equal(diff.notifications.length, 1)
    const req = Model.notificationRequest(diff.notifications[0], "Paperclip", "F", ["/p/open"])
    const drawn = Markup.render(req.body)
    assert.ok(!banned.test(drawn), JSON.stringify(text) + " was drawn as " + JSON.stringify(drawn))
    assert.ok(!banned.test(Markup.oneLine(req.body)), "the one-line body of " + JSON.stringify(text))
    // The summary is drawn as plain text; no url in it is a card's link either.
    assert.ok(!/https?:\/\//i.test(req.summary + "\n" + req.body), JSON.stringify(req))
  }
  // The words still read as written.
  assert.equal(Markup.render(Model.notificationBody("Ship 1.2 & tag <v1>")), "Ship 1.2 &amp;\u2060 tag \u2039v1\u203a")
  assert.equal(Markup.oneLine(Model.notificationBody("a &amp; b")), "a &\u2060amp; b")
})

group("a notification request carries the words as data for the helper", () => {
  const WJ = "\u2060"
  const item = { summary: "--app-name=x", body: "<b>why</b>", urgency: "critical", glyph: "G" }
  const exec = ["/p/open", "https://127.0.0.1:3100/PAP-1"]
  const req = Model.notificationRequest(item, "Paperclip", "F", exec)
  assert.deepEqual(req, { appName: "Paperclip", urgency: "critical", glyph: "G",
    summary: WJ + "--app-name=x", body: "\u2039b\u203awhy\u2039/b\u203a", exec })
  const bare = Model.notificationRequest({}, "", "F", [])
  assert.deepEqual(bare, { appName: "Paperclip", urgency: "normal", glyph: "F",
    summary: "Paperclip", body: "" })
  assert.equal(Model.notificationRequest({ glyph: "" }, "omarchy-action", "", null).glyph, "")
  assert.equal(JSON.parse(JSON.stringify(req)).exec[1], exec[1])
})

group("the service row says what the report says and offers one thing", () => {
  const managed = { installed: true, active: true, activeState: "active" }
  const running = (extra) => Object.assign({ state: "idle", reachable: true, working: 0, service: managed, cli: { installed: true } }, extra)
  const stopped = (extra) => Object.assign({ state: "stopped", reachable: false, working: 0,
    service: { installed: true, active: false, activeState: "inactive" }, cli: { installed: true } }, extra)

  // Nothing to say before the first report, or when the plugin has no
  // instance to speak of.
  for (const report of [null, undefined, { state: "unknown" }, { state: "not-installed" },
                        { state: "untrusted-listener", reachable: false }]) {
    const control = Model.serviceControl(report, "")
    assert.equal(control.state, "unavailable")
    assert.equal(control.action, "")
  }

  // Running as the background service: Stop, and no question when idle.
  let c = Model.serviceControl(running(), "")
  assert.deepEqual([c.state, c.action, c.confirm], ["running", "stop", false])
  // Every reachable state is running, including one that needs a token.
  for (const state of ["idle", "working", "needs-you", "needs-auth"]) {
    assert.equal(Model.serviceControl(running({ state }), "").state, "running", state)
  }

  // Agents at work: Stop asks once, and says how many.
  c = Model.serviceControl(running({ state: "working", working: 3 }), "")
  assert.deepEqual([c.action, c.confirm, c.working], ["stop", true, 3])
  assert.equal(Model.stopConfirmText(3), "3 agents at work — press again")
  assert.equal(Model.stopConfirmText(1), "1 agent at work — press again")

  // Started in a terminal: no Stop is offered, because none exists.
  c = Model.serviceControl(running({ state: "working", working: 2, service: { installed: false } }), "")
  assert.deepEqual([c.state, c.action, c.confirm], ["running", "", false])
  assert.ok(c.detail.includes("terminal"))

  // Stopped: Start for the service, Start for a CLI that runs in a terminal,
  // nothing when there is neither.
  c = Model.serviceControl(stopped(), "")
  assert.deepEqual([c.state, c.action], ["stopped", "start"])
  c = Model.serviceControl(stopped({ service: { installed: false } }), "")
  assert.deepEqual([c.state, c.action, c.detail], ["stopped", "start", "Starts in a terminal"])
  c = Model.serviceControl(stopped({ service: { installed: false }, cli: { installed: false } }), "")
  assert.deepEqual([c.state, c.action], ["stopped", ""])

  // The panel's own ask shows at once, with nothing to press meanwhile.
  c = Model.serviceControl(stopped(), "start")
  assert.deepEqual([c.state, c.action], ["starting", ""])
  c = Model.serviceControl(running(), "stop")
  assert.deepEqual([c.state, c.action], ["stopping", ""])
  c = Model.serviceControl(stopped({ service: { installed: true, active: true, activeState: "active" } }), "stop")
  assert.equal(c.state, "stopping")

  // A change made outside the panel is followed from the report alone.
  assert.equal(Model.serviceControl(stopped({ service: { installed: true, active: false, activeState: "activating" } }), "").state, "starting")
  assert.equal(Model.serviceControl(running({ service: { installed: true, active: true, activeState: "deactivating" } }), "").state, "stopping")
  // Up but not answering: Stop is still there, so a stuck one can be ended.
  c = Model.serviceControl(stopped({ service: { installed: true, active: true, activeState: "active" } }), "")
  assert.deepEqual([c.state, c.action], ["starting", "stop"])
})

group("a pending ask ends when the report agrees, and not before", () => {
  const up = { reachable: true, service: { active: true, activeState: "active" } }
  const down = { reachable: false, service: { active: false, activeState: "inactive" } }
  const shuttingDown = { reachable: false, service: { active: true, activeState: "deactivating" } }
  assert.equal(Model.settlePending("start", down), "start")
  assert.equal(Model.settlePending("start", up), "")
  assert.equal(Model.settlePending("stop", up), "stop")
  assert.equal(Model.settlePending("stop", shuttingDown), "stop")
  assert.equal(Model.settlePending("stop", down), "")
  assert.equal(Model.settlePending("", up), "")
  assert.equal(Model.settlePending("stop", null), "stop")
  assert.ok(Model.SERVICE_PENDING_MS >= 60000, "a start waits up to a minute for health")
})

group("the footer offers the service key only when it does something", () => {
  const keys = (report) => Model.hintKeys(report).map((h) => h.key)
  const label = (report) => Model.hintKeys(report).find((h) => h.key === "v").label
  const managed = { installed: true, active: true, activeState: "active" }
  assert.ok(!keys({ state: "not-installed" }).includes("v"))
  assert.ok(!keys({ state: "idle", reachable: true, service: { installed: false } }).includes("v"))
  assert.equal(label({ state: "idle", reachable: true, service: managed }), "stop")
  assert.equal(label({ state: "stopped", reachable: false, service: { installed: true, active: false }, cli: { installed: true } }), "start")

  // While a start or stop is under way, neither the key nor the card offers it again.
  const down = { state: "stopped", reachable: false, service: { installed: true, active: false } }
  const up = { state: "idle", reachable: true, service: { installed: true, active: true, activeState: "active" } }
  const hasV = (r, pending) => Model.hintKeys(r, null, pending).some((h) => h.key === "v")
  assert.ok(hasV(up, "") && hasV(down, ""))
  assert.ok(!hasV(down, "start"), "start pending")
  assert.ok(!hasV(up, "stop"), "stop pending")
  assert.equal(Model.primaryAction(down, "start"), null)
  assert.equal(Model.primaryAction(down, "").id, "start")
})

group("no action is offered at an address that is not Paperclip's", () => {
  const noWebapp = { webapp: { installed: false } }
  assert.equal(Model.primaryAction(Object.assign({ state: "idle", reachable: true }, noWebapp)).id, "webapp")
  for (const extra of [noWebapp, {}, { webapp: { installed: true } }]) {
    const report = Object.assign({ state: "untrusted-listener", reachable: false }, extra)
    assert.equal(Model.primaryAction(report, ""), null, JSON.stringify(extra))
  }
})

// "Keep Paperclip running": a stop seen from outside the panel is not undone.
group("auto-start step", () => {
  const down = (unit, extra) => Object.assign({ state: "stopped", reachable: false,
    service: { installed: true, active: false, activeState: unit } }, extra)
  const up = { state: "idle", reachable: true, service: { installed: true, active: true, activeState: "active" } }

  // Down at the first look: start it.
  assert.deepEqual(Model.autoStartStep(false, down("inactive"), true, false), { action: "start", wasUp: false })
  // Answering, then cleanly inactive (systemctl stop, paperclipai service stop): record it, do not start.
  assert.deepEqual(Model.autoStartStep(true, down("inactive"), true, false), { action: "mark-stopped", wasUp: false })
  // Recorded even with the setting Off: turning it On later must not undo the stop.
  assert.equal(Model.autoStartStep(true, down("inactive"), false, false).action, "mark-stopped")
  // A crash is not a stop.
  assert.equal(Model.autoStartStep(true, down("failed"), true, false).action, "start")
  // The setting Off starts nothing.
  assert.equal(Model.autoStartStep(false, down("inactive"), false, false).action, "")
  // Answering again, however it was started (a terminal's systemctl start):
  // any recorded stop is over, once; answering after that is nothing to do.
  assert.deepEqual(Model.autoStartStep(false, up, true, false), { action: "mark-running", wasUp: true })
  assert.deepEqual(Model.autoStartStep(false, up, false, false), { action: "mark-running", wasUp: true })
  assert.deepEqual(Model.autoStartStep(true, up, true, false), { action: "", wasUp: true })
  // The panel's own start or stop in flight is not read as a start from outside.
  assert.deepEqual(Model.autoStartStep(false, up, true, true), { action: "", wasUp: true })
  // The whole story: stopped by hand, started from a terminal, then a crash is started again.
  let story = Model.autoStartStep(false, up, true, false)
  story = Model.autoStartStep(story.wasUp, down("inactive"), true, false)
  assert.equal(story.action, "mark-stopped")
  story = Model.autoStartStep(story.wasUp, up, true, false)
  assert.equal(story.action, "mark-running")
  story = Model.autoStartStep(story.wasUp, down("failed"), true, false)
  assert.equal(story.action, "start")
  // In transition the unit gets neither, and the memory of "was up" survives to the next look.
  for (const unit of ["deactivating", "activating"]) {
    assert.deepEqual(Model.autoStartStep(true, down(unit), true, false), { action: "", wasUp: true }, unit)
  }
  // The unit is up and not answering yet: starting, not stopped.
  const starting = down("active", { service: { installed: true, active: true, activeState: "active" } })
  assert.deepEqual(Model.autoStartStep(true, starting, true, false), { action: "", wasUp: true })
  // The sequence of a terminal stop: up, deactivating, inactive.
  let step = Model.autoStartStep(false, up, true, false)
  step = Model.autoStartStep(step.wasUp, down("deactivating"), true, false)
  step = Model.autoStartStep(step.wasUp, down("inactive"), true, false)
  assert.equal(step.action, "mark-stopped")
  // The panel's own start or stop in flight: nothing, and nothing forgotten.
  assert.deepEqual(Model.autoStartStep(true, down("inactive"), true, true), { action: "", wasUp: true })
  // No background service, or no report: nothing to start.
  assert.equal(Model.autoStartStep(false, down("", { service: { installed: false } }), true, false).action, "")
  assert.equal(Model.autoStartStep(false, null, true, false).action, "")
  assert.equal(Model.autoStartStep(false, { state: "needs-you", reachable: true }, true, false).action, "")
})

group("the closed bar reads the open inbox under either filter, the open panel the filter it shows", () => {
  // `All` is a second attention query per company, for rows that only the
  // open panel draws; the closed bar pays one query per company per read.
  assert.equal(Model.probeInboxFilter(Model.INBOX_ALL, false), Model.INBOX_NEEDS_ME)
  assert.equal(Model.probeInboxFilter(Model.INBOX_NEEDS_ME, false), Model.INBOX_NEEDS_ME)
  assert.equal(Model.probeInboxFilter(Model.INBOX_ALL, true), Model.INBOX_ALL)
  assert.equal(Model.probeInboxFilter(Model.INBOX_NEEDS_ME, true), Model.INBOX_NEEDS_ME)
  assert.equal(Model.probeInboxFilter("All", true), Model.INBOX_ALL)
  assert.equal(Model.probeInboxFilter("nonsense", true), Model.INBOX_NEEDS_ME)
  // The widget asks the probe for exactly this, not for the setting itself.
  const service = readFileSync(path.join(root, "Service.qml"), "utf8")
  assert.ok(service.includes('"--inbox-filter", Model.probeInboxFilter(inboxFilter, panelOpen)'))
})

group("the bar reads once a minute, the open panel at least every 20 seconds", () => {
  assert.equal(Model.REFRESH_DEFAULT_SEC, 60)
  assert.equal(Model.refreshIntervalMs(Model.REFRESH_DEFAULT_SEC, false), 60000)
  assert.equal(Model.refreshIntervalMs(Model.REFRESH_DEFAULT_SEC, true), 20000)
  // A shorter interval the user chose is kept, open or closed.
  assert.equal(Model.refreshIntervalMs(5, true), 5000)
  assert.equal(Model.refreshIntervalMs(15, false), 15000)
  assert.equal(Model.refreshIntervalMs(300, false), 300000)
  assert.equal(Model.refreshIntervalMs(300, true), 20000)
  // The manifest's default and the widget's fallback are the same number.
  const widget = JSON.parse(readFileSync(path.join(root, "manifest.json"), "utf8")).barWidget
  assert.equal(widget.defaults.refreshIntervalSec, Model.REFRESH_DEFAULT_SEC)
  const field = widget.schema.find(f => f.key === "refreshIntervalSec")
  assert.equal(field.defaultValue, Model.REFRESH_DEFAULT_SEC)
  assert.match(field.description, new RegExp("every " + Model.REFRESH_PANEL_SEC + " seconds"))
})

console.log("all groups passed")
