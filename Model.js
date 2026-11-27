// Pure helpers for the Paperclip widget: parse the probe, describe a state,
// and decide which desktop notifications a new report deserves.
//
// Nothing here touches QML, Quickshell or the network, so `test/test_model.mjs`
// can run all of it under plain node.

// The paperclip is the identity glyph. Nothing stands in for it.
var GLYPH_PAPERCLIP = ""
var GLYPH_WARN = ""
var GLYPH_OK = ""
var GLYPH_OPEN = ""
var GLYPH_REFRESH = ""
var GLYPH_WRENCH = ""
var GLYPH_CHEVRON = ""
// nf-md-sleep: the zzz that stands in for the bubble while the plugin is quiet.
var GLYPH_SLEEP = "\uDB81\uDCB2"

// Notification levels. These are the values stored in shell.json, so they stay
// single words: the bar's setter strips anything that would need quoting.
var NOTIFY_OFF = "Off"
var NOTIFY_NEEDED = "Needs-me"
var NOTIFY_ALL = "Everything"

// Panel filter. Two positions, deliberately the same two the notification
// filter has, so one mental model covers both surfaces.
var INBOX_NEEDS_ME = "needs-me"
var INBOX_ALL = "all"

// "Error" means error. `Everything` names a failure as a failure, never as one
// more thing in a "5 things need you" summary.
var ERROR_KINDS = { failed_run: true, agent_error_alert: true, recovery_action: true }

// The inbox rows that are a decision waiting on a person: an approval, a board
// decision, a question or confirmation an agent asked in a thread, a join
// request. These are the only rows `Needs-me` raises a toast for. Reviews,
// blockers, budget alerts and failures stay in the panel and the bubble, and
// reach the desktop under `Everything`.
var DECISION_KINDS = { approval: true, decision: true, issue_thread_interaction: true, join_request: true }

// Past this many fresh error rows in one poll, summarize. A watchdog looping
// every fifteen minutes must not be able to paper the screen in toasts.
var MAX_ERROR_TOASTS = 3

// The most row keys the shell remembers as seen. A cut list cannot say a row
// is gone, so on a busy instance new keys keep coming and none is forgotten;
// past this many, the keys listed longest ago go first. Four times the largest
// report the probe writes (100 inbox rows and 25 runs), so a row has to stay
// out of several full lists before it can speak again.
var MAX_SEEN_KEYS = 500

// How often the widget reads the instance. Each read asks the server for the
// attention feed of every company, a heavy query, so the closed bar reads it
// once a minute; the open panel reads it at least every 20 seconds.
var REFRESH_DEFAULT_SEC = 60
var REFRESH_PANEL_SEC = 20

function refreshIntervalMs(seconds, panelOpen) {
  return (panelOpen ? Math.min(seconds, REFRESH_PANEL_SEC) : seconds) * 1000
}

// The inbox filter the probe is asked for. `All` costs the server a second
// attention query per company, and only adds rows you cleared, which never
// toast and are only drawn in the open panel. So the closed bar reads the open
// inbox under either filter: the count is the open inbox anyway.
function probeInboxFilter(filter, panelOpen) {
  return panelOpen ? normalizeInboxFilter(filter) : INBOX_NEEDS_ME
}

// A report shaped like the probe's output, for before the first poll lands.
function emptyReport() {
  return {
    schemaVersion: 1,
    state: "unknown",
    summary: "Checking…",
    apiBase: "",
    reachable: false,
    authRequired: false,
    cli: { installed: false, path: "", npx: false },
    service: { supported: false, installed: false, active: false },
    webapp: { installed: false },
    health: {},
    attention: 0,
    working: 0,
    failedRuns: 0,
    inboxFilter: INBOX_NEEDS_ME,
    inboxTotal: 0,
    inboxShown: 0,
    inboxCounts: {},
    retryableCount: 0,
    // True when a company's inbox could not be read, so the count is short of
    // the truth and the panel owes an explanation rather than a number.
    inboxStale: false,
    // True when a company's run list could not be read: `working` and `moving`
    // are short of the truth.
    runsStale: false,
    companies: [],
    needs: [],
    moving: [],
    problems: []
  }
}

// The stored value, mapped onto what this file works in. The names the setting
// used to have are still accepted, so a shell.json written before the rename
// still means what the person who wrote it meant.
function normalizeNotifyLevel(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var lower = text.toLowerCase()
  if (lower === "off") return NOTIFY_OFF
  if (lower === "everything" || lower === "all") return NOTIFY_ALL
  return NOTIFY_NEEDED
}

function normalizeInboxFilter(value) {
  var text = String(value === undefined || value === null ? "" : value).toLowerCase()
  return text === INBOX_ALL ? INBOX_ALL : INBOX_NEEDS_ME
}

// What goes back into shell.json. The settings dropdown lists these, so the
// stored value has to be one of them or the panel's choice looks unset.
function inboxFilterSetting(filter) {
  return normalizeInboxFilter(filter) === INBOX_ALL ? "All" : "Needs-me"
}

function notificationLabel(level) {
  var mode = normalizeNotifyLevel(level)
  if (mode === NOTIFY_OFF) return "notifications off"
  if (mode === NOTIFY_ALL) return "notify: everything"
  return "notify: decisions"
}

function inboxFilterLabel(filter) {
  return normalizeInboxFilter(filter) === INBOX_ALL ? "all" : "needs me"
}

function isErrorKind(kind) {
  return ERROR_KINDS[String(kind || "")] === true
}

function isDecisionKind(kind) {
  return DECISION_KINDS[String(kind || "")] === true
}

// How many pending decisions the whole feed holds, from the server's counts by
// kind, so rows past the listed page are counted too.
function decisionCount(report) {
  var counts = report && report.inboxCounts
  if (!counts || typeof counts !== "object") return 0
  var total = 0
  for (var kind in DECISION_KINDS) total += toCount(counts[kind])
  return total
}

function parseReport(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    return null
  }
  if (!parsed || typeof parsed !== "object") return null

  var base = emptyReport()
  for (var key in base) {
    if (parsed[key] === undefined || parsed[key] === null) parsed[key] = base[key]
  }
  parsed.needs = asRows(parsed.needs)
  parsed.moving = asRows(parsed.moving)
  parsed.attention = toCount(parsed.attention)
  parsed.working = toCount(parsed.working)
  parsed.inboxFilter = normalizeInboxFilter(parsed.inboxFilter)
  // The bubble is the length of this list, so the total it counts and the rows
  // it lists come from one query. `attention` is that total.
  parsed.inboxTotal = toCount(parsed.inboxTotal) || parsed.attention
  parsed.inboxShown = toCount(parsed.inboxShown) || parsed.needs.length
  parsed.retryableCount = toCount(parsed.retryableCount)
  if (!parsed.inboxCounts || typeof parsed.inboxCounts !== "object") parsed.inboxCounts = {}
  return parsed
}

function asRows(value) {
  if (!value || !value.length) return []
  var out = []
  for (var i = 0; i < value.length; i++) {
    var row = value[i]
    if (!row || typeof row !== "object") continue
    out.push({
      key: String(row.key || row.url || row.title || ("row" + i)),
      kind: String(row.kind || ""),
      identifier: String(row.identifier || ""),
      title: String(row.title || ""),
      detail: String(row.detail || ""),
      severity: String(row.severity || "normal"),
      company: String(row.company || ""),
      companyId: String(row.companyId || ""),
      agent: String(row.agent || ""),
      ago: String(row.ago || ""),
      url: String(row.url || ""),
      // What the write path needs. A row without these ids draws no button.
      itemKey: String(row.itemKey || ""),
      retryKind: String(row.retryKind || ""),
      retryable: row.retryable === true,
      isError: row.isError === true,
      agentId: String(row.agentId || ""),
      runId: String(row.runId || ""),
      issueId: String(row.issueId || ""),
      actionId: String(row.actionId || ""),
      snoozedUntil: String(row.snoozedUntil || ""),
      hidden: row.hidden === true,
      activityMs: asMillis(row.activityMs),
      // A single row is a group of one, so the panel has one row shape only.
      count: 1,
      members: null
    })
  }
  return out
}

// Collapse rows that say the same thing. One watchdog looping every fifteen
// minutes produces a hundred identical rows; "Kai run failed ×115" is a fact
// you can act on, a hundred copies of it is a wall.
//
// The count is the number of grouped rows that are *listed*, never an estimate
// of the whole feed: `moreWaiting()` carries what the list does not reach.
function groupRows(rows) {
  var out = []
  var index = {}
  for (var i = 0; i < (rows || []).length; i++) {
    var row = rows[i]
    var key = String(row.kind) + "\u0000" + rowLabel(row)
    var at = index[key]
    if (at === undefined) {
      var group = {}
      for (var field in row) group[field] = row[field]
      group.count = 1
      group.members = [row]
      group.retryableCount = row.retryable ? 1 : 0
      index[key] = out.length
      out.push(group)
      continue
    }
    var existing = out[at]
    existing.count += 1
    existing.members.push(row)
    if (row.retryable) existing.retryableCount += 1
    // The group keeps the freshest age, because that is the one that answers
    // "is this still happening".
    if (!existing.ago && row.ago) existing.ago = row.ago
  }
  return out
}

// How many open rows a grouped list holds. A row you cleared, listed under
// the `All` filter, is not open and is not in the count it is set against.
function openListed(groups) {
  var total = 0
  for (var i = 0; i < (groups || []).length; i++) {
    var members = groups[i].members || [groups[i]]
    for (var j = 0; j < members.length; j++) {
      if (members[j].hidden !== true) total++
    }
  }
  return total
}

// How many open rows the panel's list does not reach. Named rather than
// hidden, so a cut-off list never pretends to be the whole inbox.
function moreWaiting(report, listed, filter) {
  var total = report ? toCount(report.inboxTotal || report.attention) : 0
  if (filter === TILE_FAILED) total = retryableCount(report)
  var shown = toCount(listed)
  return total > shown ? total - shown : 0
}

// The summary cards are a view filter over the panel's lists. The filter lives
// in the panel only: it never touches the inbox setting or the bar's count.
var TILE_ATTENTION = "attention"
var TILE_WORKING = "working"
var TILE_FAILED = "failed"

// The filter that is really in force: a card whose count fell to zero cannot
// stay selected, so the list never filters down to nothing.
function activeTileFilter(report, filter) {
  var tiles = statTiles(report)
  for (var i = 0; i < tiles.length; i++) {
    if (tiles[i].key === filter && tiles[i].value > 0) return filter
  }
  return ""
}

// Clicking the selected card clears the filter; any other card selects.
function toggleTileFilter(current, key) {
  return current === key ? "" : key
}

// Which rows each section lists under a filter. Needs-you takes the inbox
// rows (all of them, or only the failed runs); working-now takes the moving
// rows. No filter lists both.
function filterNeedRows(rows, filter) {
  if (filter === TILE_WORKING) return []
  if (filter !== TILE_FAILED) return rows || []
  var out = []
  for (var i = 0; i < (rows || []).length; i++) {
    if (String(rows[i].kind) === "failed_run") out.push(rows[i])
  }
  return out
}

function filterMovingRows(rows, filter) {
  return filter === TILE_ATTENTION || filter === TILE_FAILED ? [] : (rows || [])
}

// The number on the `Retry all` button: the failed-run rows in this feed.
// Counted by the server over the whole feed, not over the visible page.
function retryableCount(report) {
  return report ? toCount(report.retryableCount) : 0
}

// What `t` does on this row, or nothing when the row has no attempt to repeat.
function retryLabel(row) {
  if (!row || row.retryable !== true) return ""
  return String(row.retryKind) === "recovery" ? "Hand back" : "Try again"
}

function toCount(value) {
  var n = parseInt(value, 10)
  return isFinite(n) && n > 0 ? n : 0
}

// What the row shows on its left edge.
function rowLabel(row) {
  if (!row) return ""
  var identifier = String(row.identifier || "")
  var title = String(row.title || "")
  if (identifier && title) return identifier + " " + title
  return identifier || title
}

// An error toast has to say that something broke. An agent-error row is
// titled with the agent's name alone, which on its own reads like good news.
function errorSummary(row) {
  var label = rowLabel(row)
  if (!label) return "Something failed in Paperclip"
  if (String(row.kind) === "agent_error_alert") return label + " hit an error"
  if (String(row.kind) === "recovery_action") return label + " needs a hand back"
  return label
}

function isTrouble(state) {
  return state === "stopped" || state === "not-installed" ||
    state === "needs-auth" || state === "probe-failed" ||
    state === "untrusted-listener"
}

// The one-line answer the bar tooltip gives without opening anything.
function tooltipText(report, quiet) {
  if (!report) return "Paperclip"
  var parts = ["Paperclip — " + String(report.summary || "")]
  if (quiet && quiet.headline) parts.unshift("zzz " + quiet.headline)
  if (report.working > 0 && report.attention > 0) {
    parts.push(report.working + (report.working === 1 ? " agent working" : " agents working"))
  }
  var problems = report.problems || []
  if (problems.length > 0) parts.push(problems[0])
  return parts.join("\n")
}

// Small text in the bar bubble: the number of open inbox rows under the
// panel's current filter.
//
// This used to be the server's `deskBadgeCount`, which counts rows that are
// new today or due today. That number falls to zero at midnight whether or not
// anybody did the work, and rises again without anything new happening — which
// is exactly the red count that could never be cleared. The bubble is now the
// length of the list the panel shows, and nothing else.
function badgeText(report) {
  if (!report) return ""
  if (isTrouble(report.state)) return "!"
  var total = toCount(report.inboxTotal) || toCount(report.attention)
  if (total > 0) return total > 99 ? "99+" : String(total)
  return ""
}

// Red when a listed row is urgent or an error, neutral when the inbox is just
// long. A hundred stale rows should not look like a fire.
function badgeTone(report) {
  if (!report) return "quiet"
  if (isTrouble(report.state)) return "alarm"
  var rows = report.needs || []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].isError === true) return "alarm"
    if (severityUrgency(rows[i].severity) === "critical") return "attention"
  }
  var total = toCount(report.inboxTotal) || toCount(report.attention)
  if (total > 0) return "waiting"
  return report.working > 0 ? "working" : "quiet"
}

// The widget's face is always the paperclip. State is carried by color,
// by the bubble and by motion, never by swapping the mark for a bell or a
// warning sign: a bar icon that changes shape stops being an identity.
function stateGlyph(state) {
  return GLYPH_PAPERCLIP
}

// Which of the four visual tones a state paints in. The panel maps these to
// urgent / foreground / dim so one table decides every surface.
//
//   alarm     — the instance is broken and a person has to repair it
//   attention — the instance is fine and is waiting for a person
//   working   — agents are moving; nothing is waiting
//   quiet     — nothing to say
function stateTone(state) {
  if (isTrouble(state)) return "alarm"
  if (state === "needs-you") return "attention"
  if (state === "working") return "working"
  return "quiet"
}

// Two or three words for the hero, where the summary already gives the long
// version. Kept out of the probe so the panel can label an empty report.
function stateLabel(state) {
  if (state === "not-installed") return "Not set up"
  if (state === "stopped") return "Not running"
  if (state === "needs-auth") return "Needs a token"
  if (state === "untrusted-listener") return "Not your Paperclip"
  if (state === "probe-failed") return "Probe failed"
  if (state === "needs-you") return "Needs you"
  if (state === "working") return "Working"
  if (state === "idle") return "All quiet"
  return "Checking"
}

// The three counts the panel shows as tiles under the hero. Returning them
// from here keeps the labels, the plurals and the tone in one place, and lets
// the test pin them.
function statTiles(report) {
  var r = report || emptyReport()
  // The failed-run tile counts the inbox rows you can press `Try again` on, so
  // the tile and the `Retry all` counter are the same number.
  // A zero is an answer, not a missing field: falling back to the recent-run
  // count on 0 left the tile at 1 after the last failed row was cleared.
  var failed = r.retryableCount !== undefined ? toCount(r.retryableCount) : toCount(r.failedRuns)
  var waiting = r.inboxTotal !== undefined ? toCount(r.inboxTotal) : toCount(r.attention)
  return [
    {
      key: "attention",
      label: waiting === 1 ? "needs you" : "need you",
      value: waiting,
      tone: waiting > 0 ? "attention" : "quiet"
    },
    {
      key: "working",
      label: r.working === 1 ? "agent working" : "agents working",
      value: toCount(r.working),
      tone: r.working > 0 ? "working" : "quiet"
    },
    {
      key: "failed",
      label: failed === 1 ? "failed run" : "failed runs",
      value: failed,
      tone: failed > 0 ? "alarm" : "quiet"
    }
  ]
}

// The keyboard hints the footer advertises. Nothing is listed that would do
// nothing: the row verbs only appear once there are rows, and `t`/`T` only once
// there is something with an attempt to repeat.
//
// `s` is snooze while there is an inbox, and set-up while there is no Paperclip
// yet. Those two states never overlap: an instance that is not installed has no
// inbox to snooze.
function hintKeys(report, quiet, pending) {
  var r = report || emptyReport()
  var state = String(r.state || "")
  var rows = r.needs || []
  var hints = [{ key: "o", label: "open" }]

  if (state === "not-installed") {
    hints.push({ key: "s", label: "set up" })
  } else if (rows.length > 0) {
    hints.push({ key: "a", label: "all" })
    hints.push({ key: "f", label: "filter" })
    if (retryableCount(r) > 0) {
      hints.push({ key: "t", label: "try again" })
      hints.push({ key: "T", label: "retry all" })
    }
    hints.push({ key: "s", label: "snooze" })
    hints.push({ key: "x", label: "clear" })
  }

  // Focus is only offered while it has something to lift, and `z` says what it
  // will do: start a snooze, or end the one that is running.
  var mode = quiet ? String(quiet.mode) : "awake"
  hints.push({ key: "z", label: mode === "plugin" ? "wake" : "zzz" })
  if (mode === "focus") hints.push({ key: "p", label: "end focus" })
  else if (mode === "omarchy") hints.push({ key: "p", label: "focus" })

  var control = serviceControl(r, pending)
  if (control.action !== "") hints.push({ key: "v", label: control.action })

  hints.push({ key: "r", label: "refresh" })
  hints.push({ key: "d", label: "fix" })
  hints.push({ key: "n", label: "notify" })
  return hints
}

// What the big button in the panel should do about a broken instance.
function primaryAction(report, pending) {
  if (!report) return null
  var state = String(report.state || "")
  if (state === "not-installed") {
    return { id: "setup", label: "Set up Paperclip", detail: "Install the CLI and start the instance" }
  }
  if (state === "stopped") {
    // A start or stop already under way is not offered a second time.
    if (String(pending || "") !== "") return null
    var service = report.service || {}
    if (service.installed) {
      return { id: "start", label: "Start Paperclip", detail: "Start the background service" }
    }
    if (report.cli && report.cli.installed) {
      return { id: "start", label: "Start Paperclip", detail: "Run the instance in a terminal" }
    }
    return { id: "setup", label: "Set up Paperclip", detail: "Finish the install first" }
  }
  if (state === "needs-auth") {
    return { id: "doctor", label: "Fix it with your agent", detail: "This instance needs a board token" }
  }
  if (state === "probe-failed") {
    return { id: "doctor", label: "Fix it with your agent", detail: "The status probe itself failed" }
  }
  // The address is not Paperclip's: nothing that opens or creates something
  // there is offered. The problem line is the only thing to read.
  if (state === "untrusted-listener") return null
  if (!report.webapp || !report.webapp.installed) {
    return { id: "webapp", label: "Create the web app", detail: "Add Paperclip to the app launcher" }
  }
  return null
}

// ------------------------------------------------------------- the service
//
// What the panel says about the Paperclip process, and the one thing it offers
// to do about it. The report is the truth: the probe reads the API and the
// systemd unit. `pending` is only what this panel just asked for ("start" or
// "stop"), so the row can say "starting" before the unit has moved; it is
// dropped as soon as the report agrees (settlePending) or runs out of time.
//
//   running     the API answers
//   stopped     it does not, and nothing is starting it
//   starting    asked to start, or the unit is up and the API is not yet
//   stopping    asked to stop, or the unit is shutting down
//   unavailable not set up, or not ours: nothing to offer
//
// Stop is offered only for the background service. An instance started in a
// terminal is that terminal's process, and the plugin does not fake a way to
// end it. Stopping with agents at work asks once (`confirm`).
var SERVICE_PENDING_MS = 90000

function serviceControl(report, pending) {
  var none = { state: "unavailable", label: "", detail: "", action: "", confirm: false, working: 0 }
  if (!report) return none
  var state = String(report.state || "")
  if (state === "not-installed" || state === "untrusted-listener" || state === "unknown" || state === "") return none

  var service = report.service || {}
  var managed = service.installed === true
  var unit = String(service.activeState || "")
  var wanted = String(pending || "")
  var working = toCount(report.working)
  var reachable = report.reachable === true

  if (reachable) {
    if (wanted === "stop" || unit === "deactivating") {
      return { state: "stopping", label: "Stopping", detail: "Waiting for Paperclip to shut down", action: "", confirm: false, working: working }
    }
    return {
      state: "running",
      label: "Running",
      detail: managed ? "Background service" : "Started in a terminal — close that terminal to stop it",
      action: managed ? "stop" : "",
      confirm: managed && working > 0,
      working: working
    }
  }

  if (wanted === "stop" || unit === "deactivating") {
    if (service.active === true || unit === "deactivating") {
      return { state: "stopping", label: "Stopping", detail: "Waiting for Paperclip to shut down", action: "", confirm: false, working: 0 }
    }
  }
  if (wanted === "start" || unit === "activating") {
    return { state: "starting", label: "Starting", detail: "Waiting for Paperclip to answer", action: "", confirm: false, working: 0 }
  }
  if (service.active === true) {
    return { state: "starting", label: "Starting", detail: "The service is up; Paperclip is not answering yet", action: "stop", confirm: false, working: 0 }
  }
  if (managed) {
    return { state: "stopped", label: "Stopped", detail: "Background service", action: "start", confirm: false, working: 0 }
  }
  if (report.cli && report.cli.installed === true) {
    return { state: "stopped", label: "Stopped", detail: "Starts in a terminal", action: "start", confirm: false, working: 0 }
  }
  return { state: "stopped", label: "Stopped", detail: "Finish the install first", action: "", confirm: false, working: 0 }
}

// Drop the pending ask once the report shows it came true.
function settlePending(pending, report) {
  var wanted = String(pending || "")
  if (wanted === "" || !report) return wanted
  var service = report.service || {}
  var up = report.reachable === true
  var unitUp = service.active === true || String(service.activeState || "") === "activating"
  if (wanted === "start" && up) return ""
  if (wanted === "stop" && !up && !unitUp) return ""
  return wanted
}

// What "Keep Paperclip running" does with one new report. `wasUp` is true when
// the instance answered since the last decision; `busy` is true while the
// panel's own start or stop is in flight.
//   "mark-stopped": it answered and its unit is now cleanly inactive, so
//                   someone stopped it (systemctl, `paperclipai service stop`):
//                   record that, do not start it.
//   "start":        ask the service script to start it; the script is the one
//                   that checks the marker, the lock and the ten-minute rule.
//   "mark-running": it answers and did not before (a start from a terminal,
//                   or the first look), so any recorded stop is over; a later
//                   crash is then started again.
// A unit that is starting, stopping or running without answering is in
// transition and gets neither. A failed unit is a crash, not a stop.
function autoStartStep(wasUp, report, autoStart, busy) {
  var up = !!report && report.reachable === true
  var keep = wasUp === true || up
  if (up && wasUp !== true && busy !== true && (report.service || {}).installed === true) {
    return { action: "mark-running", wasUp: true }
  }
  if (!report || busy === true || String(report.state) !== "stopped") return { action: "", wasUp: keep }
  var service = report.service || {}
  if (service.installed !== true) return { action: "", wasUp: keep }
  var unit = String(service.activeState || "")
  if (service.active === true || unit === "activating" || unit === "deactivating") {
    return { action: "", wasUp: keep }
  }
  if (wasUp === true && unit === "inactive") return { action: "mark-stopped", wasUp: false }
  return { action: autoStart === true ? "start" : "", wasUp: false }
}

// The words on the Stop button while it waits for the second press.
function stopConfirmText(working) {
  var n = toCount(working)
  return n + " agent" + (n === 1 ? "" : "s") + " at work — press again"
}

// ---------------------------------------------------------------- snooze
//
// Two things can make the plugin quiet, and a third can lift one of them.
//
//   plugin  — you snoozed Paperclip (`z` for an hour, `Z` until morning). No
//             desktop notifications, no bubble, a zzz on the icon.
//   omarchy — Omarchy's own Do Not Disturb is on. Same icon. Omarchy already
//             silences our toasts and keeps them in its history, so we keep
//             sending them and let it.
//   focus   — you asked Paperclip to come through Omarchy's snooze. Toasts are
//             sent as `omarchy-action`, the one app name Omarchy lets through.
//
// A plugin snooze always wins: focus only lifts Omarchy's snooze, never your
// own "not now". Starting a snooze ends a focus session, and focus cannot
// start while the plugin is snoozed.
var SNOOZE_HOUR = "1h"
var SNOOZE_MORNING = "morning"
var MORNING_HOUR = 9
var FOCUS_LIMIT_MS = 4 * 3600 * 1000

function emptySnooze() {
  return { step: "", until: 0, focusUntil: 0 }
}

function asMillis(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? Math.floor(n) : 0
}

// What bin/omarchy-paperclip-snooze prints. Anything unreadable is "not
// snoozed": a broken state file must never be able to silence the plugin.
function parseSnooze(raw) {
  var out = emptySnooze()
  var parsed = null
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (error) {
    return out
  }
  if (!parsed || typeof parsed !== "object") return out
  var step = String(parsed.step || "")
  if (step === SNOOZE_HOUR || step === SNOOZE_MORNING) out.step = step
  out.until = out.step === "" ? 0 : asMillis(parsed.until)
  out.focusUntil = asMillis(parsed.focusUntil)
  return out
}

function snoozeActive(snooze, now) {
  return !!snooze && asMillis(snooze.until) > now
}

function focusActive(snooze, now) {
  return !!snooze && asMillis(snooze.focusUntil) > now
}

// When a step ends. "Morning" is the next 09:00 on the local clock, the same
// hour the row snooze (`S`) uses.
function snoozeEnds(step, now) {
  if (step === SNOOZE_MORNING) {
    var d = new Date(now)
    d.setHours(MORNING_HOUR, 0, 0, 0)
    if (d.getTime() <= now) d.setDate(d.getDate() + 1)
    return d.getTime()
  }
  return now + 3600 * 1000
}

// The key for a step wakes the plugin when that step is already running, and
// otherwise sets it: `z` twice is on then off, `Z` while on for an hour
// stretches it to morning. Starting a snooze ends a focus session.
function toggleSnooze(snooze, step, now) {
  var current = snooze || emptySnooze()
  if (snoozeActive(current, now) && current.step === step) {
    return { step: "", until: 0, focusUntil: asMillis(current.focusUntil) }
  }
  return { step: step, until: snoozeEnds(step, now), focusUntil: 0 }
}

function toggleFocus(snooze, omarchyDnd, now) {
  var current = snooze || emptySnooze()
  if (snoozeActive(current, now)) return current
  if (focusActive(current, now)) {
    return { step: "", until: 0, focusUntil: 0 }
  }
  if (!omarchyDnd) return current
  return { step: "", until: 0, focusUntil: now + FOCUS_LIMIT_MS }
}

// "14:30" today, "tomorrow 09:00" the next day.
function clockText(ms, now) {
  var d = new Date(ms)
  var h = String(d.getHours())
  var m = String(d.getMinutes())
  var text = (h.length < 2 ? "0" + h : h) + ":" + (m.length < 2 ? "0" + m : m)
  var today = new Date(now)
  if (d.getFullYear() === today.getFullYear() && d.getMonth() === today.getMonth() &&
      d.getDate() === today.getDate()) return text
  return "tomorrow " + text
}

// The one answer to "is the plugin quiet, and why". Every surface reads this,
// so the icon, the strip in the panel, the tooltip and the notifier cannot
// disagree.
//
//   quiet   — the icon wears the zzz and the bubble is gone
//   toasts  — whether the plugin itself holds back desktop notifications
//   bypass  — send toasts as `omarchy-action` so Omarchy's snooze lets them by
function quietState(snooze, omarchyDnd, now) {
  var base = {
    mode: "awake", quiet: false, toasts: true, bypass: false,
    canFocus: false, until: 0, headline: "", detail: ""
  }
  if (snoozeActive(snooze, now)) {
    base.mode = "plugin"
    base.quiet = true
    base.toasts = false
    base.until = asMillis(snooze.until)
    base.headline = "Snoozed until " + clockText(base.until, now)
    base.detail = "No notifications. Your inbox is still here."
    return base
  }
  if (omarchyDnd) {
    if (focusActive(snooze, now)) {
      base.mode = "focus"
      base.bypass = true
      base.canFocus = true
      base.until = asMillis(snooze.focusUntil)
      base.headline = "Focus: Paperclip comes through"
      base.detail = "Omarchy is snoozed. Your toasts get through until it ends."
      return base
    }
    base.mode = "omarchy"
    base.quiet = true
    base.canFocus = true
    base.headline = "Omarchy is snoozed"
    base.detail = "Paperclip follows it. Notifications wait in Omarchy's history."
    return base
  }
  return base
}

// Said once when a timed snooze runs out by itself and rows are waiting. The
// backlog is never replayed: one line, one click, then the panel is the list.
// `Needs-me` counts only the decisions, the same rows it would have toasted.
function wakeNotification(report, level) {
  var mode = normalizeNotifyLevel(level)
  if (mode === NOTIFY_OFF || !report) return null
  if (mode === NOTIFY_NEEDED) {
    var decisions = decisionCount(report)
    if (decisions === 0) return null
    return {
      key: "snooze:over",
      urgency: "normal",
      glyph: GLYPH_PAPERCLIP,
      summary: "Snooze is over",
      body: decisions === 1 ? "1 decision waits for you." : decisions + " decisions wait for you.",
      action: "open"
    }
  }
  var total = toCount(report.inboxTotal) || toCount(report.attention)
  if (total === 0) return null
  return {
    key: "snooze:over",
    urgency: "normal",
    glyph: GLYPH_PAPERCLIP,
    summary: "Snooze is over",
    body: total === 1 ? "1 thing needs you." : total + " things need you.",
    action: "open"
  }
}

// Each key maps to the list it came from, so pruning can ask whether that
// list was whole.
function keysOf(rows, list) {
  var out = {}
  for (var i = 0; i < (rows || []).length; i++) out[rows[i].key] = list || true
  return out
}

function severityUrgency(severity) {
  var value = String(severity || "").toLowerCase()
  return (value === "critical" || value === "high") ? "critical" : "normal"
}

// Which notifications a transition from `previous` to `next` deserves.
//
// `seen` is the set of row keys already announced, so a restart of the shell
// does not replay a backlog: the caller seeds it from the first report and
// passes it back on every call.
//
// `since` covers the rows the first report did not list: the bar's short list
// holds twenty, and the rest of a longer inbox first shows when the panel
// opens. Until a report lists the whole inbox, a row nobody saw that last moved
// before the session began was waiting all along, and is marked seen without a
// toast. The caller passes back what the last call returned.
// Returns { notifications: [...], seen: {...}, since: ms }.
function diffNotifications(previous, next, level, seen, since) {
  var out = { notifications: [], seen: seen || {}, since: asMillis(since) }
  if (!next) return out
  var mode = normalizeNotifyLevel(level)
  // Off says nothing and still marks what it saw as seen, as a snoozed plugin
  // does, so turning notifications back on is never a replay of the meantime.
  if (mode === NOTIFY_OFF) return markSeen(out, next, !!previous)

  // First report of the session: remember what is already waiting, say nothing.
  if (!previous) return markSeen(out, next, false)

  // `Needs-me` is pending decisions and nothing else. The instance's own state
  // shows on the bar icon; a toast for it is `Everything`'s.
  var all = mode === NOTIFY_ALL

  if (previous.reachable && !next.reachable && all) {
    out.notifications.push({
      key: "instance:stopped",
      urgency: "critical",
      glyph: GLYPH_PAPERCLIP,
      summary: "Paperclip stopped",
      body: "Nothing is answering on " + String(next.apiBase || "the instance") + ".",
      action: "doctor"
    })
  } else if (!previous.reachable && next.reachable && all) {
    out.notifications.push({
      key: "instance:started",
      urgency: "low",
      glyph: GLYPH_OK,
      summary: "Paperclip is running",
      body: String(next.summary || ""),
      action: "open"
    })
  }

  if (all && next.state === "not-installed" && previous.state !== "not-installed") {
    out.notifications.push({
      key: "instance:not-installed",
      urgency: "normal",
      glyph: GLYPH_PAPERCLIP,
      summary: "Finish setting up Paperclip",
      body: "The plugin is installed; Paperclip itself is not set up yet.",
      action: "setup"
    })
  }

  // Errors and the rest are separated under `Everything`, not because they
  // deserve different urgency, but because an error folded into a "5 things
  // need you" summary is an error you did not hear about. Under `Needs-me` only
  // the decisions are fresh; every other row is still marked seen below, so
  // moving to `Everything` later does not replay it.
  var freshErrors = []
  var freshDecisions = []
  // A row you cleared is not shown, whatever the level. The `All` inbox filter
  // lists it so it can be found, never so it can toast; it stays unseen, so a
  // row that comes back is one toast. A snoozed row is never in the report.
  for (var i = 0; i < next.needs.length; i++) {
    var row = next.needs[i]
    if (row.hidden === true || out.seen[row.key] || waitedSince(row, out.since)) continue
    if (!all) {
      if (isDecisionKind(row.kind)) freshDecisions.push(row)
    } else if (isErrorKind(row.kind) || row.isError === true) freshErrors.push(row)
    else freshDecisions.push(row)
  }

  var shownErrors = freshErrors.length > MAX_ERROR_TOASTS
    ? freshErrors.slice(0, MAX_ERROR_TOASTS)
    : freshErrors
  for (var e = 0; e < shownErrors.length; e++) {
    out.notifications.push({
      key: "error:" + shownErrors[e].key,
      urgency: severityUrgency(shownErrors[e].severity),
      glyph: GLYPH_PAPERCLIP,
      summary: errorSummary(shownErrors[e]),
      body: shownErrors[e].detail || "A run failed.",
      action: "url",
      url: shownErrors[e].url
    })
  }
  if (freshErrors.length > shownErrors.length) {
    var rest = freshErrors.length - shownErrors.length
    out.notifications.push({
      key: "error:batch:" + freshErrors.length,
      urgency: "normal",
      glyph: GLYPH_PAPERCLIP,
      summary: rest + (rest === 1 ? " more failure" : " more failures"),
      body: "Open the Paperclip panel to try them again.",
      action: "open"
    })
  }

  // Three cards is a nudge; ten is a wall of toasts. Past that, summarize.
  if (freshDecisions.length > 3) {
    out.notifications.push({
      key: "needs:batch:" + freshDecisions.length,
      urgency: "normal",
      glyph: GLYPH_PAPERCLIP,
      summary: freshDecisions.length + (all ? " things need you" : " decisions wait for you"),
      body: "Open Paperclip to work through them.",
      action: "open"
    })
  } else {
    for (var j = 0; j < freshDecisions.length; j++) {
      out.notifications.push({
        key: "needs:" + freshDecisions[j].key,
        urgency: severityUrgency(freshDecisions[j].severity),
        glyph: GLYPH_PAPERCLIP,
        summary: rowLabel(freshDecisions[j]) || "Paperclip needs you",
        body: freshDecisions[j].detail || "Waiting for your decision.",
        action: "url",
        url: freshDecisions[j].url
      })
    }
  }

  if (all) {
    for (var k = 0; k < next.moving.length; k++) {
      var run = next.moving[k]
      if (out.seen[run.key]) continue
      out.notifications.push({
        key: "moving:" + run.key,
        urgency: "low",
        glyph: GLYPH_PAPERCLIP,
        summary: (run.agent || "An agent") + " started working",
        body: rowLabel(run),
        action: "url",
        url: run.url
      })
    }
  }

  return markSeen(out, next, true)
}

// Remembers every row of `next` in `out.seen`; `prune` forgets the rows that
// are gone, which only a report after a first one can tell. The map never holds
// more than MAX_SEEN_KEYS keys, however long the shell runs.
function markSeen(out, next, prune) {
  out.seen = rememberKeys(out.seen, mergeKeys(keysOf(next.needs, "needs"), keysOf(next.moving, "moving")))
  out.seen = forgetHidden(prune ? pruneKeys(out.seen, next) : out.seen, next)
  out.seen = boundKeys(out.seen, MAX_SEEN_KEYS)
  // The first report starts the cover for the rows it did not list. Once one
  // report has listed every row, every row waiting at the start has been seen,
  // and anything after that is news however old its time.
  if (listsEveryRow(next, next.needs, next.inboxTotal, next.inboxStale)) out.since = 0
  else if (!prune) out.since = asMillis(Date.parse(String(next.generatedAt || "")))
  return out
}

// A row is news only when its time says it moved after the session began; one
// with no time cannot show that, so it is counted as waiting. A row whose
// Paperclip snooze began before the start and ends while the cover holds keeps
// its old time, so it stays quiet too, as a cut list already left it.
function waitedSince(row, since) {
  return since > 0 && !(row.activityMs > since)
}

// Whether a report's list holds every row there is, so a key missing from it
// means the row is gone. A stopped instance, a missing token or an inbox that
// could not be read lists nothing, or less than there is; so does a list cut
// to the bar's few rows while the count says more, and a list whose request
// failed (`stale`: the probe read it as empty). Forgetting on such a report
// toasts every row again on the next one that lists them. The count is the
// open inbox, so the cleared rows the `All` filter lists are not set against it.
function listsEveryRow(report, rows, count, stale) {
  if (!report || report.reachable !== true) return false
  if (report.authRequired === true || stale === true) return false
  var open = 0
  for (var i = 0; i < (rows || []).length; i++) {
    if (rows[i].hidden !== true) open++
  }
  return open >= toCount(count)
}

// Text from the instance reaches `omarchy-notification-send` as a positional.
// A value that starts with a dash is read as one of its options
// (--app-name=omarchy-action gets through Do Not Disturb, --image= sets a
// picture), so a word joiner goes first: it prints as nothing and is not a dash.
var WORD_JOINER = "\u2060"

function neutralizeOption(text) {
  var s = String(text === undefined || text === null ? "" : text)
  return /^\s*-/.test(s) ? WORD_JOINER + s : s
}

// The shell draws a notification body as StyledText, so markup in it is markup.
function escapeMarkup(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// The summary is drawn as plain text; the body is not.
function notificationSummary(text) {
  return neutralizeOption(text)
}

function notificationBody(text) {
  return neutralizeOption(escapeMarkup(text))
}

// What `bin/omarchy-paperclip-notify` reads from stdin. The words never go on a
// command line, so there is nothing to neutralise against option parsing, but
// the same functions run so the text stays exactly what it was.
function notificationRequest(item, appName, fallbackGlyph, exec) {
  var out = {
    appName: String(appName || "Paperclip"),
    urgency: String(item.urgency || "normal"),
    glyph: String(item.glyph || fallbackGlyph || ""),
    summary: notificationSummary(item.summary || "Paperclip"),
    body: notificationBody(item.body || "")
  }
  if (exec && exec.length > 0) out.exec = exec.map(String)
  return out
}

function mergeKeys(seen, keys) {
  var out = {}
  for (var a in seen) out[a] = seen[a]
  for (var b in keys) out[b] = keys[b]
  return out
}

// Each seen key holds the list it came from and the poll that last listed it
// (`at`, one more than the newest before), so `boundKeys` can tell which keys
// went unlisted longest. Object order is no guide: a key that looks like a
// number sorts first.
function rememberKeys(seen, listed) {
  var out = {}
  var tick = 0
  for (var a in seen) {
    out[a] = seen[a]
    if (seenAt(seen[a]) > tick) tick = seenAt(seen[a])
  }
  tick++
  for (var b in listed) out[b] = { list: listed[b], at: tick }
  return out
}

function seenAt(entry) {
  return entry && typeof entry.at === "number" ? entry.at : 0
}

// Keeps the `max` keys listed most recently and drops the rest.
function boundKeys(seen, max) {
  var keys = Object.keys(seen)
  if (keys.length <= max) return seen
  keys.sort(function (a, b) { return seenAt(seen[b]) - seenAt(seen[a]) })
  var out = {}
  for (var i = 0; i < max; i++) out[keys[i]] = seen[keys[i]]
  return out
}

// A cleared row is never counted as seen: when it comes back it is news
// again, under either inbox filter.
function forgetHidden(seen, report) {
  for (var i = 0; i < report.needs.length; i++) {
    if (report.needs[i].hidden === true) delete seen[report.needs[i].key]
  }
  return seen
}

// Forget rows that are gone, so the same task notifies again if it comes back.
// Only a list that holds every row can say a row is gone (`listsEveryRow`);
// otherwise each key it does not list is kept.
function pruneKeys(seen, report) {
  var needs = keysOf(report.needs)
  var moving = keysOf(report.moving)
  var needsWhole = listsEveryRow(report, report.needs, report.inboxTotal, report.inboxStale)
  var movingWhole = listsEveryRow(report, report.moving, report.working, report.runsStale)
  var out = {}
  for (var key in seen) {
    var list = seen[key] && seen[key].list
    var whole = list === "needs" ? needsWhole
              : list === "moving" ? movingWhole
              : needsWhole && movingWhole
    if (needs[key] || moving[key] || !whole) out[key] = seen[key]
  }
  return out
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    GLYPH_PAPERCLIP: GLYPH_PAPERCLIP,
    GLYPH_WARN: GLYPH_WARN,
    GLYPH_OK: GLYPH_OK,
    GLYPH_OPEN: GLYPH_OPEN,
    GLYPH_REFRESH: GLYPH_REFRESH,
    GLYPH_WRENCH: GLYPH_WRENCH,
    GLYPH_CHEVRON: GLYPH_CHEVRON,
    GLYPH_SLEEP: GLYPH_SLEEP,
    NOTIFY_OFF: NOTIFY_OFF,
    NOTIFY_NEEDED: NOTIFY_NEEDED,
    NOTIFY_ALL: NOTIFY_ALL,
    MAX_SEEN_KEYS: MAX_SEEN_KEYS,
    INBOX_NEEDS_ME: INBOX_NEEDS_ME,
    INBOX_ALL: INBOX_ALL,
    emptyReport: emptyReport,
    parseReport: parseReport,
    normalizeNotifyLevel: normalizeNotifyLevel,
    normalizeInboxFilter: normalizeInboxFilter,
    inboxFilterSetting: inboxFilterSetting,
    notificationLabel: notificationLabel,
    inboxFilterLabel: inboxFilterLabel,
    isErrorKind: isErrorKind,
    isDecisionKind: isDecisionKind,
    decisionCount: decisionCount,
    rowLabel: rowLabel,
    errorSummary: errorSummary,
    groupRows: groupRows,
    openListed: openListed,
    moreWaiting: moreWaiting,
    TILE_ATTENTION: TILE_ATTENTION,
    TILE_WORKING: TILE_WORKING,
    TILE_FAILED: TILE_FAILED,
    activeTileFilter: activeTileFilter,
    toggleTileFilter: toggleTileFilter,
    filterNeedRows: filterNeedRows,
    filterMovingRows: filterMovingRows,
    retryableCount: retryableCount,
    retryLabel: retryLabel,
    isTrouble: isTrouble,
    tooltipText: tooltipText,
    badgeText: badgeText,
    badgeTone: badgeTone,
    stateGlyph: stateGlyph,
    stateTone: stateTone,
    stateLabel: stateLabel,
    statTiles: statTiles,
    hintKeys: hintKeys,
    primaryAction: primaryAction,
    SERVICE_PENDING_MS: SERVICE_PENDING_MS,
    REFRESH_DEFAULT_SEC: REFRESH_DEFAULT_SEC,
    REFRESH_PANEL_SEC: REFRESH_PANEL_SEC,
    refreshIntervalMs: refreshIntervalMs,
    probeInboxFilter: probeInboxFilter,
    serviceControl: serviceControl,
    settlePending: settlePending,
    autoStartStep: autoStartStep,
    stopConfirmText: stopConfirmText,
    diffNotifications: diffNotifications,
    neutralizeOption: neutralizeOption,
    escapeMarkup: escapeMarkup,
    notificationSummary: notificationSummary,
    notificationBody: notificationBody,
    notificationRequest: notificationRequest,
    SNOOZE_HOUR: SNOOZE_HOUR,
    SNOOZE_MORNING: SNOOZE_MORNING,
    FOCUS_LIMIT_MS: FOCUS_LIMIT_MS,
    emptySnooze: emptySnooze,
    parseSnooze: parseSnooze,
    snoozeActive: snoozeActive,
    focusActive: focusActive,
    snoozeEnds: snoozeEnds,
    toggleSnooze: toggleSnooze,
    toggleFocus: toggleFocus,
    clockText: clockText,
    quietState: quietState,
    wakeNotification: wakeNotification
  }
}
