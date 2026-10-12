import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Everything that is not drawing: poll the status probe, raise desktop
// notifications when something changes, and run the plugin's scripts.
//
// Two scripts own the Paperclip API and this file owns neither. The probe
// (bin/omarchy-paperclip-status) reads; the inbox script
// (bin/omarchy-paperclip-inbox) writes. One reader, one writer, and no HTTP
// in QML.
Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""
  property bool panelOpen: false
  // Omarchy's own Do Not Disturb. A third-party bar widget is not handed the
  // shell's notification service, so it is polled through the shell's CLI.
  property bool omarchyDnd: false

  property var report: Model.emptyReport()
  property bool refreshing: false
  property string lastError: ""
  property string actionStatus: ""

  // What the writer is doing, and what it said about a row that refused.
  property bool writing: false
  property string batchProgress: ""
  property var rowNotes: ({})

  readonly property string statusScript: pluginDir + "/bin/omarchy-paperclip-status"
  readonly property string inboxScript: pluginDir + "/bin/omarchy-paperclip-inbox"
  readonly property string setupScript: pluginDir + "/bin/omarchy-paperclip-setup"
  readonly property string doctorScript: pluginDir + "/bin/omarchy-paperclip-doctor"
  readonly property string serviceScript: pluginDir + "/bin/omarchy-paperclip-service"
  readonly property string webappScript: pluginDir + "/bin/omarchy-paperclip-webapp"
  readonly property string openScript: pluginDir + "/bin/omarchy-paperclip-open"
  readonly property string snoozeScript: pluginDir + "/bin/omarchy-paperclip-snooze"

  readonly property string notifyLevel: Model.normalizeNotifyLevel(setting("notifications", Model.NOTIFY_NEEDED))
  readonly property string inboxFilter: Model.normalizeInboxFilter(setting("inboxFilter", Model.INBOX_NEEDS_ME))
  readonly property int retryAllLimit: intSetting("retryAllLimit", 20, 1, 100)
  readonly property bool autoStart: String(setting("autoStart", "On")) === "On"
  readonly property bool showCount: String(setting("showCount", "On")) === "On"
  // One switch for every transition in the panel and every loop in the bar.
  // Off leaves the layout and the colors alone and only removes the motion,
  // for people who find animated chrome distracting.
  readonly property bool animations: String(setting("animations", "On")) !== "Off"
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 20, 5, 600)
  readonly property string instanceState: String(report ? report.state : "unknown")
  readonly property int attention: report ? report.attention : 0
  readonly property int working: report ? report.working : 0
  readonly property int failedRuns: report ? Number(report.failedRuns || 0) : 0
  // The whole open inbox under the current filter, and the part of it that has
  // an attempt to repeat. Both come from the one query the panel lists.
  readonly property int inboxTotal: report ? Number(report.inboxTotal || 0) : 0
  readonly property int retryableCount: Model.retryableCount(report)
  readonly property var problems: report && report.problems ? report.problems : []
  readonly property bool trouble: Model.isTrouble(instanceState)
  readonly property string tone: Model.stateTone(instanceState)

  // Snooze: what was asked for, and the clock it is judged against. `quiet` is
  // the one answer every surface reads (see Model.quietState).
  property var snooze: Model.emptySnooze()
  property double clock: Date.now()
  readonly property var quiet: Model.quietState(snooze, omarchyDnd, clock)
  readonly property string quietMode: quiet.mode
  property string _lastMode: "awake"
  property bool _snoozeLoaded: false

  property var _seenKeys: ({})
  property var _previousReport: null
  property double _lastStartAttempt: 0

  // Writes run one at a time through this queue. Clearing a group of thirteen
  // is thirteen calls, and thirteen agent runs starting at once is not a thing
  // a keypress should be able to do.
  property var _queue: []
  property var _job: null
  property var _result: null
  // `Retry all` walks the companies in the report, spending one shared budget,
  // so the cap is a cap on the press and not a cap per company.
  property var _retryCompanies: []
  property int _retryBudget: 0
  property int _retryDone: 0
  property int _retryRefused: 0

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // Which instance every script call is about. Appended to both the reader and
  // the writer, so the two can never end up talking to different Paperclips.
  function instanceArgv() {
    var argv = []
    var instance = String(setting("instance", ""))
    if (instance !== "") argv = argv.concat(["--instance", instance])
    var apiBase = String(setting("apiBase", ""))
    if (apiBase !== "") argv = argv.concat(["--api-base", apiBase])
    return argv
  }

  function refresh() {
    if (statusProcess.running || pluginDir === "") return
    refreshing = true
    // The closed bar only needs the counts and enough rows to colour the
    // bubble and raise notifications; the open panel needs rows to list. The
    // count is the whole feed either way, so this changes what is drawn and
    // never what is counted.
    statusProcess.command = ["python3", statusScript, "--compact",
                             "--items", "6",
                             "--inbox-items", panelOpen ? "60" : "20",
                             "--inbox-filter", inboxFilter].concat(instanceArgv())
    statusProcess.running = true
  }

  function applyOutput(text, exitCode) {
    var parsed = Model.parseReport(text)
    if (!parsed) {
      lastError = exitCode === 0 ? "The status probe returned nothing readable."
                                 : "The status probe failed (exit " + exitCode + ")."
      return
    }
    lastError = ""
    clock = Date.now()
    var diff = Model.diffNotifications(_previousReport, parsed, notifyLevel, _seenKeys)
    _seenKeys = diff.seen
    // A snoozed plugin still marks what it saw as seen, so waking it up is
    // never a replay of everything that happened in the meantime.
    if (quiet.toasts) {
      for (var i = 0; i < diff.notifications.length; i++) notify(diff.notifications[i])
    }
    _previousReport = parsed
    report = parsed
    maybeAutoStart()
  }

  // One attempt per ten minutes: an instance that refuses to start must not
  // turn into a restart loop nobody asked for.
  function maybeAutoStart() {
    if (!autoStart || instanceState !== "stopped") return
    var service = report.service || {}
    if (!service.installed) return
    var now = Date.now()
    if (now - _lastStartAttempt < 600000) return
    _lastStartAttempt = now
    actionStatus = "Starting Paperclip…"
    Util.execArgv([serviceScript, "start", "--quiet"])
    settleTimer.restart()
  }

  function notify(item) {
    if (!item) return
    // `omarchy-action` is the one app name Omarchy's Do Not Disturb lets
    // through, which is exactly what a focus session asks for.
    var argv = ["omarchy-notification-send", "--app-name", quiet.bypass ? "omarchy-action" : "Paperclip",
                "-u", String(item.urgency || "normal"),
                // Every notification wears the mark: the words say what
                // happened, the glyph says who is speaking.
                "-g", String(item.glyph || Model.stateGlyph(root.instanceState)),
                Model.notificationSummary(item.summary || "Paperclip"),
                Model.notificationBody(item.body || "")]
    var action = actionArgv(String(item.action || "open"), String(item.url || ""))
    if (action.length > 0) argv = argv.concat(["--exec"]).concat(action)
    Util.execArgv(argv)
  }

  // The argv a notification click (or a panel button) runs. Built as a vector
  // so a title or url from the API is always one argument, never a command.
  function actionArgv(action, url) {
    if (action === "url" && url !== "") return openArgv(url, false)
    if (action === "setup") return ["omarchy-launch-tui", "--app-id=org.omarchy.paperclip-setup", setupScript]
    if (action === "doctor") return ["omarchy-launch-tui", "--app-id=org.omarchy.paperclip-doctor", doctorScript]
    if (action === "start") return [serviceScript, "start"]
    if (action === "webapp") return [webappScript, "ensure"]
    return openArgv("", false)
  }

  // One Paperclip window is the rule, so every open raises the window that is
  // already there. A second window is only ever asked for by hand, by holding
  // Shift in the panel.
  function openArgv(url, newWindow) {
    var argv = [openScript]
    if (newWindow) argv.push("--new-window")
    if (url) argv.push(String(url))
    return argv
  }

  function run(action, url) {
    var argv = actionArgv(action, url || "")
    if (argv.length === 0) return
    Util.execArgv(argv)
    if (action === "start" || action === "webapp") settleTimer.restart()
  }

  function openUrl(url, newWindow) {
    if (!url) return
    Util.execArgv(openArgv(url, newWindow === true))
  }

  function openBoard(newWindow) { Util.execArgv(openArgv("", newWindow === true)) }
  function runSetup() { run("setup") }
  function runDoctor() { run("doctor") }
  function ensureWebapp() { run("webapp") }
  function startInstance() { run("start") }

  function restartInstance() {
    actionStatus = "Restarting Paperclip…"
    Util.execArgv([serviceScript, "restart"])
    settleTimer.restart()
  }

  // Persist one of our own settings through the bar, which owns shell.json.
  // Values are single words on purpose, so this never needs shell quoting.
  function setSetting(key, value) {
    var clean = String(value).replace(/[^A-Za-z0-9._-]/g, "")
    if (clean === "") return
    Util.execArgv(["omarchy", "bar", "set", "sceny.paperclipai", String(key), clean])
  }

  function cycleNotifications() {
    var order = [Model.NOTIFY_OFF, Model.NOTIFY_NEEDED, Model.NOTIFY_ALL]
    var index = order.indexOf(notifyLevel)
    var next = order[(index + 1 + order.length) % order.length]
    setSetting("notifications", next)
    actionStatus = Model.notificationLabel(next)
    actionStatusTimer.restart()
  }

  // ------------------------------------------------------------- snooze

  function loadSnooze() {
    if (_snoozeLoaded || pluginDir === "" || snoozeLoad.running) return
    _snoozeLoaded = true
    snoozeLoad.command = [snoozeScript, "get"]
    snoozeLoad.running = true
  }

  onPluginDirChanged: loadSnooze()
  Component.onCompleted: loadSnooze()

  function writeSnooze(next) {
    clock = Date.now()
    snooze = next
    if (pluginDir === "") return
    Util.execArgv([snoozeScript, "set", next.step === "" ? "none" : next.step,
                   String(next.until), String(next.focusUntil)])
  }

  function say(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  // `z` snoozes for an hour and `Z` until morning; the key of the step that is
  // already running wakes the plugin.
  function toggleSnooze(untilMorning) {
    var now = Date.now()
    writeSnooze(Model.toggleSnooze(snooze, untilMorning === true ? Model.SNOOZE_MORNING : Model.SNOOZE_HOUR, now))
    say(quiet.mode === "plugin" ? quiet.headline : "Snooze ended")
  }

  function toggleFocus() {
    var now = Date.now()
    if (!Model.focusActive(snooze, now) && !omarchyDnd) {
      say("Omarchy is not snoozed, so there is nothing to come through")
      return
    }
    var was = Model.focusActive(snooze, now)
    writeSnooze(Model.toggleFocus(snooze, omarchyDnd, now))
    if (quiet.mode === "plugin") say("Paperclip is snoozed — wake it first")
    else say(was ? "Focus ended" : "Focus on — Paperclip comes through")
  }

  // Focus lifts a snooze that is running; once Omarchy wakes, it has nothing
  // left to lift, and it must not come back by surprise at the next snooze.
  onOmarchyDndChanged: {
    if (!omarchyDnd && Model.focusActive(snooze, Date.now())) {
      writeSnooze({ step: snooze.step, until: snooze.until, focusUntil: 0 })
    }
  }

  onQuietModeChanged: {
    var was = _lastMode
    _lastMode = quietMode
    // A timed snooze that ran out by itself. One line, never the backlog.
    if (was === "plugin" && quietMode !== "plugin" && snooze.until > 0 && snooze.until <= clock) {
      var wake = Model.wakeNotification(report, notifyLevel)
      if (wake) notify(wake)
      writeSnooze({ step: "", until: 0, focusUntil: snooze.focusUntil })
    }
  }

  function notificationLabel(level) { return Model.notificationLabel(level) }
  function inboxFilterLabel(filter) { return Model.inboxFilterLabel(filter) }

  // `Needs me` is the open inbox. `All` also shows what you snoozed or
  // cleared, so a row cleared by mistake is findable — the one thing a plugin
  // without a history still owes you.
  function cycleInboxFilter() {
    var next = inboxFilter === Model.INBOX_ALL ? Model.INBOX_NEEDS_ME : Model.INBOX_ALL
    setSetting("inboxFilter", Model.inboxFilterSetting(next))
    actionStatus = "Showing: " + Model.inboxFilterLabel(next)
    actionStatusTimer.restart()
    // The setting round-trips through the bar, so ask for the new list once it
    // has had a moment to land.
    settleTimer.restart()
  }

  // ------------------------------------------------------------- the writer
  //
  // Every write is one call to bin/omarchy-paperclip-inbox, queued so only one
  // runs at a time. The script always answers with JSON, and a refusal carries
  // the server's own sentence, which is what lands on the row.

  function inboxArgv(args) {
    return ["python3", inboxScript].concat(args).concat(instanceArgv())
  }

  function enqueue(key, note, argv) {
    _queue = _queue.concat([{ key: String(key || ""), note: String(note || ""), argv: argv }])
    // Never dispatch from inside a signal handler of the process we are
    // waiting on: at `onExited` the old process can still read as running, and
    // a queue that silently refuses to start the next job is a button that
    // works once.
    drainTimer.restart()
  }

  function drain() {
    if (writing || inboxProcess.running || _queue.length === 0 || pluginDir === "") return
    _job = _queue[0]
    _queue = _queue.slice(1)
    _result = null
    writing = true
    if (_job.note !== "") actionStatus = _job.note
    inboxProcess.command = _job.argv
    inboxProcess.running = true
  }

  function noteRow(key, text) {
    if (!key) return
    var next = {}
    for (var existing in rowNotes) next[existing] = rowNotes[existing]
    if (text === "") delete next[key]
    else next[key] = String(text)
    rowNotes = next
  }

  function rowNote(key) {
    return key && rowNotes[key] !== undefined ? String(rowNotes[key]) : ""
  }

  function clearNotes() { rowNotes = ({}) }

  // One row, or every row in a group. `limit` caps how many members a single
  // keypress may act on, so `t` on a group of a hundred is still one press
  // worth of work.
  function membersOf(row, onlyRetryable, limit) {
    var all = row && row.members && row.members.length ? row.members : (row ? [row] : [])
    var out = []
    for (var i = 0; i < all.length; i++) {
      if (onlyRetryable && all[i].retryable !== true) continue
      out.push(all[i])
      if (limit > 0 && out.length >= limit) break
    }
    return out
  }

  function dismissRow(row) {
    var members = membersOf(row, false, 0)
    var acted = 0
    for (var i = 0; i < members.length; i++) {
      var member = members[i]
      if (!member.itemKey || !member.companyId) continue
      var verb = member.hidden ? "restore" : "dismiss"
      enqueue(row.key, member.hidden ? "Restoring…" : "Clearing…",
              inboxArgv([verb, "--company", member.companyId, "--item-key", member.itemKey]))
      acted += 1
    }
    if (acted === 0) reportNoAction(row, "This row cannot be cleared from the bar.")
  }

  function snoozeRow(row, tomorrow) {
    var members = membersOf(row, false, 0)
    var acted = 0
    for (var i = 0; i < members.length; i++) {
      var member = members[i]
      if (!member.itemKey || !member.companyId) continue
      var argv = ["snooze", "--company", member.companyId, "--item-key", member.itemKey]
      argv = argv.concat(tomorrow === true ? ["--tomorrow"] : ["--hours", "1"])
      enqueue(row.key, tomorrow === true ? "Snoozing until tomorrow…" : "Snoozing for an hour…",
              inboxArgv(argv))
      acted += 1
    }
    if (acted === 0) reportNoAction(row, "This row cannot be snoozed from the bar.")
  }

  // Repeat the attempt. Only a row that represents a failed attempt has one:
  // a review or a question is waiting on you, and a retry there would either
  // do nothing or approve something you did not read.
  function retryRow(row) {
    var members = membersOf(row, true, retryAllLimit)
    if (members.length === 0) {
      reportNoAction(row, "Nothing failed here — this one is waiting on you.")
      return
    }
    var total = row && row.retryableCount ? Number(row.retryableCount) : members.length
    var note = members.length < total
      ? "Trying " + members.length + " of " + total + "…"
      : (members.length > 1 ? "Trying " + members.length + " again…" : "Trying again…")
    for (var i = 0; i < members.length; i++) {
      var member = members[i]
      var argv = String(member.retryKind) === "recovery"
        ? ["retry", "--company", member.companyId, "--kind", "recovery",
           "--issue", member.issueId, "--action", member.actionId]
        : ["retry", "--company", member.companyId, "--kind", "run",
           "--agent", member.agentId, "--run", member.runId]
      enqueue(row.key, note, inboxArgv(argv))
    }
  }

  function reportNoAction(row, text) {
    noteRow(row ? row.key : "", text)
    actionStatus = text
    actionStatusTimer.restart()
  }

  // Which companies have failed-run rows in the list right now. `Retry all` is
  // scoped to the rows you can see, and the rows you can see can come from
  // more than one company.
  function retryAllCompanies() {
    var rows = report && report.needs ? report.needs : []
    var seen = {}
    var out = []
    for (var i = 0; i < rows.length; i++) {
      if (String(rows[i].retryKind) !== "run") continue
      var cid = String(rows[i].companyId || "")
      if (cid === "" || seen[cid]) continue
      seen[cid] = true
      out.push(cid)
    }
    return out
  }

  // Failed runs only, capped, sequential, and it says what happened. A recovery
  // hand-back changes a task's status, so it stays a per-row press.
  function retryAll() {
    if (writing) return
    var companies = retryAllCompanies()
    if (companies.length === 0) {
      actionStatus = "Nothing to try again"
      actionStatusTimer.restart()
      return
    }
    clearNotes()
    _retryCompanies = companies
    _retryBudget = retryAllLimit
    _retryDone = 0
    _retryRefused = 0
    nextRetryAll()
  }

  function nextRetryAll() {
    if (_retryBudget <= 0 || _retryCompanies.length === 0) {
      finishRetryAll()
      return
    }
    var company = _retryCompanies[0]
    _retryCompanies = _retryCompanies.slice(1)
    enqueue("", "Trying again…",
            inboxArgv(["retry-all", "--company", company,
                       "--limit", String(_retryBudget), "--filter", inboxFilter]))
  }

  function finishRetryAll() {
    var parts = ["retried " + _retryDone]
    if (_retryRefused > 0) parts.push("refused " + _retryRefused)
    batchProgress = ""
    actionStatus = parts.join(" · ")
    actionStatusTimer.restart()
    settleTimer.restart()
  }

  function applyWriteLine(line) {
    var text = String(line || "").trim()
    if (text === "") return
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      return
    }
    if (!parsed || typeof parsed !== "object") return
    if (parsed.progress) {
      var done = Number(parsed.progress.done || 0)
      var total = Number(parsed.progress.total || 0)
      batchProgress = "retrying " + (done + 1) + " of " + total + "…"
      actionStatus = batchProgress
      return
    }
    _result = parsed
  }

  function finishWrite(exitCode) {
    writing = false
    var job = _job
    var result = _result
    _job = null
    _result = null

    if (!result) {
      var complaint = String(inboxErr.text || "").split("\n")[0]
      actionStatus = complaint !== ""
        ? complaint
        : "The inbox script said nothing readable (exit " + exitCode + ")."
      if (job) noteRow(job.key, actionStatus)
      actionStatusTimer.restart()
    } else if (String(result.action || "") === "retry-all") {
      _retryDone += Number(result.retried || 0)
      _retryRefused += Number(result.refused || 0)
      _retryBudget -= Number(result.attempted || 0)
      if (!result.ok && result.message) actionStatus = String(result.message)
      // Walk to the next company on the same budget, or report the total.
      if (_retryCompanies.length > 0 && _retryBudget > 0 && result.ok) {
        nextRetryAll()
        return
      }
      finishRetryAll()
    } else if (result.ok === true) {
      actionStatus = String(result.message || "Done")
      if (job) noteRow(job.key, "")
      actionStatusTimer.restart()
    } else {
      // The server's own sentence, on the row it is about. A refusal that
      // disappears into a log is a button that failed quietly.
      var message = String(result.message || "That was refused.")
      if (job) noteRow(job.key, message)
      actionStatus = message
      actionStatusTimer.restart()
    }

    if (_queue.length > 0) {
      drainTimer.restart()
      return
    }
    batchProgress = ""
    // The list has changed, so stop trusting the one on screen.
    settleTimer.restart()
  }

  Timer {
    id: refreshTimer
    interval: (root.panelOpen ? Math.min(root.refreshIntervalSec, 10) : root.refreshIntervalSec) * 1000
    repeat: true
    running: root.pluginDir !== ""
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // The clock a snooze is judged against. Ten seconds is as late as the zzz
    // can linger after a snooze ends, and as early as nobody can tell.
    interval: 10000
    repeat: true
    running: root.snooze.until > 0 || root.snooze.focusUntil > 0
    onTriggered: root.clock = Date.now()
  }

  Timer {
    interval: 3000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (dndProbe.running) return
      dndProbe.command = ["omarchy-shell", "notifications", "dndState"]
      dndProbe.running = true
    }
  }

  Process {
    id: dndProbe
    running: false
    command: []
    stdout: StdioCollector { id: dndOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.omarchyDnd = exitCode === 0 && String(dndOut.text).trim() === "on"
    }
  }

  Process {
    id: snoozeLoad
    running: false
    command: []
    stdout: StdioCollector { id: snoozeOut; waitForEnd: true }
    onExited: function(exitCode) {
      // A write that landed while this was running is newer than the file.
      if (root.snooze.until === 0 && root.snooze.focusUntil === 0) {
        root.clock = Date.now()
        root.snooze = Model.parseSnooze(snoozeOut.text)
      }
    }
  }

  Timer {
    // After a start/restart, poll a few times so the panel reflects reality
    // instead of waiting out the whole interval.
    id: settleTimer
    property int ticks: 0
    interval: 3000
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 8) {
        ticks = 0
        running = false
        root.actionStatus = ""
      }
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // Starts the next queued write, one event loop turn after the last one
    // finished.
    id: drainTimer
    interval: 30
    repeat: false
    onTriggered: root.drain()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      var text = String(statusOut.text || "")
      if (text === "" && exitCode !== 0) {
        root.lastError = String(statusErr.text || "The status probe failed.").split("\n")[0]
        return
      }
      root.applyOutput(text, exitCode)
    }
  }

  Process {
    // The writer. Read line by line rather than collected at the end, because
    // `Retry all` reports its progress as it goes and a batch of twenty is
    // long enough that silence would look like a hang.
    id: inboxProcess
    running: false
    command: []
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.applyWriteLine(line) }
    }
    stderr: StdioCollector { id: inboxErr; waitForEnd: true }
    onExited: function(exitCode) { root.finishWrite(exitCode) }
  }
}
