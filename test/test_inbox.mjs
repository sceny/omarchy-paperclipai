// The write path, against a Paperclip that only exists for this test.
//
//   node test/test_inbox.mjs
//
// A stub HTTP server stands in for the instance, so every call the plugin can
// make — and every refusal the real server can answer with — is exercised
// without touching anybody's inbox. What is pinned here:
//
//   * the exact body a retry sends, because the server refuses a retry that
//     tries to change its own execution context;
//   * that a refusal comes back as the server's own sentence, not as silence;
//   * that `retry-all` is capped, sequential, and reports both halves.
//
// Prints one line per group and exits non-zero on the first failure.

import assert from "node:assert/strict"
import http from "node:http"
import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"
import path from "node:path"
import fs from "node:fs"
import os from "node:os"

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const script = path.join(root, "bin", "omarchy-paperclip-inbox")
const COMPANY = "co-1"

// Every request the stub saw, in order, so a test can assert on the body.
let seen = []
// path -> { status, body } or a function(request) -> { status, body }
let routes = {}

function key(method, url) {
  return method + " " + url.split("?")[0]
}

const server = http.createServer((request, response) => {
  let raw = ""
  request.on("data", (chunk) => { raw += chunk })
  request.on("end", () => {
    let body = null
    if (raw) {
      try {
        body = JSON.parse(raw)
      } catch {
        body = raw
      }
    }
    const record = { method: request.method, url: request.url, body: body }
    seen.push(record)
    let route = routes[key(request.method, request.url)]
    if (typeof route === "function") route = route(record)
    if (!route) {
      response.writeHead(404, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "No stub for " + key(request.method, request.url) }))
      return
    }
    response.writeHead(route.status, { "content-type": "application/json" })
    response.end(route.body === undefined ? "" : JSON.stringify(route.body))
  })
})

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
const base = "http://127.0.0.1:" + server.address().port

// Run the script and return every JSON object it printed, in order. The last
// one is the result; anything before it is progress.
function run(...args) {
  return new Promise((resolve, reject) => {
    const child = spawn("python3", [script, ...args, "--api-base", base, "--timeout", "5"],
                        { stdio: ["ignore", "pipe", "pipe"] })
    let out = ""
    let err = ""
    child.stdout.on("data", (chunk) => { out += chunk })
    child.stderr.on("data", (chunk) => { err += chunk })
    child.on("error", reject)
    child.on("close", (code) => {
      const lines = out.split("\n").filter((line) => line.trim() !== "")
      let parsed
      try {
        parsed = lines.map((line) => JSON.parse(line))
      } catch (error) {
        reject(new Error("unparseable output: " + out + err))
        return
      }
      resolve({ code: code, lines: parsed, last: parsed[parsed.length - 1], stderr: err })
    })
  })
}

async function group(name, body) {
  seen = []
  routes = {}
  await body()
  console.log("ok - " + name)
}

function attentionFeed(items) {
  return {
    status: 200,
    body: {
      companyId: COMPANY,
      totalCount: items.length,
      countsBySourceKind: { failed_run: items.filter((i) => i.sourceKind === "failed_run").length },
      items: items
    }
  }
}

function failedRunItem(n) {
  return {
    sourceKind: "failed_run",
    subject: {
      kind: "run", id: "run-" + n, title: "Kai run failed",
      metadata: { agentId: "agent-" + n, issueId: "issue-" + n }
    },
    dismissalKey: "attention:run:run-" + n,
    activityAt: new Date().toISOString()
  }
}

// ----------------------------------------------------------------- the verbs

await group("dismiss and restore are one call each, and reversible", async () => {
  routes["POST /api/companies/" + COMPANY + "/inbox-dismissals"] = { status: 201, body: { ok: true } }
  routes["DELETE /api/companies/" + COMPANY + "/inbox-dismissals/attention%3Arun%3Ax"] =
    { status: 204 }

  const cleared = await run("dismiss", "--company", COMPANY, "--item-key", "attention:run:x")
  assert.equal(cleared.code, 0)
  assert.equal(cleared.last.ok, true)
  assert.deepEqual(seen[0].body, { itemKey: "attention:run:x", kind: "dismiss" })

  const back = await run("restore", "--company", COMPANY, "--item-key", "attention:run:x")
  assert.equal(back.last.ok, true)
  // The key goes in the path, so a colon in it must be escaped, not sent raw.
  assert.ok(seen[1].url.indexOf("attention%3Arun%3Ax") > 0,
            "the item key must be percent-encoded in the path")
})

await group("snooze carries a timestamp in the future", async () => {
  routes["POST /api/companies/" + COMPANY + "/inbox-dismissals"] = { status: 201, body: { ok: true } }

  const hour = await run("snooze", "--company", COMPANY, "--item-key", "attention:a", "--hours", "1")
  assert.equal(hour.last.ok, true)
  assert.equal(seen[0].body.kind, "snooze")
  const soon = new Date(seen[0].body.snoozedUntil).getTime()
  assert.ok(soon > Date.now() + 30 * 60 * 1000, "an hour from now is at least half an hour away")
  assert.ok(soon < Date.now() + 90 * 60 * 1000)

  const tomorrow = await run("snooze", "--company", COMPANY, "--item-key", "attention:a", "--tomorrow")
  assert.equal(tomorrow.last.ok, true)
  const later = new Date(seen[1].body.snoozedUntil)
  assert.ok(later.getTime() > Date.now(), "tomorrow is not in the past")
  assert.equal(later.getMinutes(), 0, "tomorrow morning is on the hour")
})

await group("a retry replays the failed run and changes nothing about it", async () => {
  routes["POST /api/agents/agent-1/wakeup"] = { status: 202, body: { status: "queued" } }

  const result = await run("retry", "--company", COMPANY, "--kind", "run",
                           "--agent", "agent-1", "--run", "run-1")
  assert.equal(result.last.ok, true)
  // The server refuses a retry that tries to override its own context: a fresh
  // session, a different trigger, a debug flag or caller-supplied task markers.
  // So the body is exactly this and nothing else.
  assert.deepEqual(seen[0].body, {
    source: "on_demand",
    triggerDetail: "manual",
    reason: "retry_failed_run",
    failedRunId: "run-1",
    forceFreshSession: false
  })
})

await group("a hand-back resolves the recovery action", async () => {
  routes["POST /api/issues/issue-1/recovery-actions/resolve"] = { status: 200, body: { ok: true } }

  const result = await run("retry", "--company", COMPANY, "--kind", "recovery",
                           "--issue", "issue-1", "--action", "action-1")
  assert.equal(result.last.ok, true)
  assert.deepEqual(seen[0].body, {
    actionId: "action-1", outcome: "restored", sourceIssueStatus: "todo"
  })
})

// ------------------------------------------------------------- the refusals

await group("every refusal comes back in the server's own words", async () => {
  const cases = [
    { status: 409, body: { error: "Only a failed run can be retried." } },
    { status: 409, body: { error: "Resolve the task's blockers before retrying." } },
    { status: 409, body: { error: "Respond to the pending question or confirmation before retrying." } },
    { status: 409, body: { error: "Conversation session changed; this older turn cannot be retried." } },
    {
      status: 409,
      body: {
        error: "The stopped native session requires cleanup and reconciliation before a new attempt.",
        code: "native_session_cleanup_quarantined"
      }
    },
    { status: 403, body: { error: "Board access required" } }
  ]
  for (const answer of cases) {
    routes["POST /api/agents/agent-1/wakeup"] = answer
    const result = await run("retry", "--company", COMPANY, "--kind", "run",
                             "--agent", "agent-1", "--run", "run-1")
    // Exit 0 with a readable answer: the widget must never be left guessing.
    assert.equal(result.code, 0)
    assert.equal(result.last.ok, false)
    assert.equal(result.last.status, answer.status)
    assert.equal(result.last.message, answer.body.error)
    assert.equal(result.last.code, answer.body.code || "")
  }

  // A recovery cause that needs a written evidence note cannot be satisfied
  // from a bar button, and says so in the server's words.
  routes["POST /api/issues/issue-1/recovery-actions/resolve"] = {
    status: 400,
    body: { error: "executionReconciliation.outcomeEvidence must be at least 20 characters" }
  }
  const blocked = await run("retry", "--company", COMPANY, "--kind", "recovery",
                            "--issue", "issue-1", "--action", "action-1")
  assert.equal(blocked.last.ok, false)
  assert.ok(blocked.last.message.indexOf("outcomeEvidence") >= 0)
})

await group("a 202 the server skipped is a refusal, not a queued retry", async () => {
  // Seen on the rig: a run behind a reconciliation blocker answers 202 and
  // starts nothing.
  routes["POST /api/agents/agent-1/wakeup"] = {
    status: 202,
    body: {
      status: "skipped",
      reason: "execution_reconciliation_required",
      message: "Automatic recovery stopped. Recorded work is preserved; actions with unverified outcomes will not be repeated."
    }
  }
  const skipped = await run("retry", "--company", COMPANY, "--kind", "run",
                            "--agent", "agent-1", "--run", "run-1")
  assert.equal(skipped.last.ok, false)
  assert.equal(skipped.last.code, "execution_reconciliation_required")
  assert.ok(skipped.last.message.indexOf("Automatic recovery stopped") === 0)

  // Already running is not stuck: the work is under way.
  routes["POST /api/agents/agent-1/wakeup"] = {
    status: 202,
    body: {
      status: "skipped",
      reason: "issue_execution_deferred",
      message: "Wakeup was deferred because this issue is already being executed by Flaky."
    }
  }
  const deferred = await run("retry", "--company", COMPANY, "--kind", "run",
                             "--agent", "agent-1", "--run", "run-1")
  assert.equal(deferred.last.ok, true)
  assert.equal(deferred.last.code, "issue_execution_deferred")
})

await group("a row missing its ids makes no call at all", async () => {
  const noIds = await run("retry", "--company", COMPANY, "--kind", "run")
  assert.equal(noIds.last.ok, false)
  const noCompany = await run("dismiss", "--item-key", "attention:a")
  assert.equal(noCompany.last.ok, false)
  const noKey = await run("dismiss", "--company", COMPANY)
  assert.equal(noKey.last.ok, false)
  assert.equal(seen.length, 0, "nothing should have reached the instance")
})

await group("an instance that is not answering is a sentence, not a crash", async () => {
  const child = spawn("python3", [script, "dismiss", "--company", COMPANY,
                                  "--item-key", "attention:a",
                                  // Nothing listens here.
                                  "--api-base", "http://127.0.0.1:1", "--timeout", "2"],
                      { stdio: ["ignore", "pipe", "pipe"] })
  let out = ""
  child.stdout.on("data", (chunk) => { out += chunk })
  const code = await new Promise((resolve) => child.on("close", resolve))
  const result = JSON.parse(out.trim().split("\n").pop())
  assert.equal(code, 0)
  assert.equal(result.ok, false)
  assert.ok(result.message.length > 0)
})

// --------------------------------------------------------------- the batch

await group("retry all is capped, sequential, and counts both halves", async () => {
  const items = [1, 2, 3, 4, 5, 6, 7].map(failedRunItem)
  items.splice(2, 0, { sourceKind: "review", subject: { kind: "issue", id: "i" } })
  routes["GET /api/companies/" + COMPANY + "/attention"] = attentionFeed(items)
  // Two of the five refuse.
  for (const n of [1, 2, 4]) {
    routes["POST /api/agents/agent-" + n + "/wakeup"] = { status: 202, body: { status: "queued" } }
  }
  for (const n of [3, 5]) {
    routes["POST /api/agents/agent-" + n + "/wakeup"] =
      { status: 409, body: { error: "Only a failed run can be retried." } }
  }

  const result = await run("retry-all", "--company", COMPANY, "--limit", "5")
  assert.equal(result.last.action, "retry-all")
  assert.equal(result.last.attempted, 5, "the cap is the cap")
  assert.equal(result.last.retried, 3)
  assert.equal(result.last.refused, 2)
  assert.equal(result.last.message, "retried 3 · refused 2")
  // The review row in the middle of the feed is never touched: it is waiting
  // on a person, and there a retry would approve something nobody read.
  assert.equal(seen.filter((r) => r.method === "POST").length, 5)
  // One at a time. 124 concurrent agent runs is a self-inflicted outage.
  const progress = result.lines.filter((line) => line.progress)
  assert.equal(progress.length, 5, "one progress line per row")
  assert.deepEqual(progress.map((line) => line.progress.done), [0, 1, 2, 3, 4])
  assert.equal(progress[0].progress.total, 5)
  // A refusal keeps the server's words, per row.
  const refusals = result.last.results.filter((r) => !r.ok)
  assert.equal(refusals.length, 2)
  assert.equal(refusals[0].message, "Only a failed run can be retried.")
})

await group("retry all over an empty list says so and calls nothing", async () => {
  routes["GET /api/companies/" + COMPANY + "/attention"] = attentionFeed([
    { sourceKind: "review", subject: { kind: "issue", id: "i" } }
  ])
  const result = await run("retry-all", "--company", COMPANY)
  assert.equal(result.last.ok, true)
  assert.equal(result.last.attempted, 0)
  assert.equal(result.last.message, "Nothing to try again")
  assert.equal(seen.filter((r) => r.method === "POST").length, 0)
})

await group("retry all follows the filter it was given", async () => {
  routes["GET /api/companies/" + COMPANY + "/attention"] = attentionFeed([failedRunItem(1)])
  routes["POST /api/agents/agent-1/wakeup"] = { status: 202, body: { status: "queued" } }
  await run("retry-all", "--company", COMPANY, "--filter", "all")
  assert.ok(seen[0].url.indexOf("includeDismissed=true") > 0,
            "the All filter has to read the same list the panel shows")
  assert.ok(seen[0].url.indexOf("sort=decide") > 0, "and in the same order")
})

// ------------------------------------------------------------ the backlog

await group("clear-failed counts before it clears, and only clears failures", async () => {
  const old = new Date(Date.now() - 30 * 86400000).toISOString()
  const fresh = new Date().toISOString()
  routes["GET /api/companies/" + COMPANY + "/attention"] = attentionFeed([
    { sourceKind: "failed_run", subject: { kind: "run", id: "r1" },
      dismissalKey: "attention:run:r1", activityAt: old },
    { sourceKind: "failed_run", subject: { kind: "run", id: "r2" },
      dismissalKey: "attention:run:r2", activityAt: old },
    { sourceKind: "failed_run", subject: { kind: "run", id: "r3" },
      dismissalKey: "attention:run:r3", activityAt: fresh },
    { sourceKind: "blocker_attention", subject: { kind: "issue", id: "i1" },
      dismissalKey: "attention:blocker:i1", activityAt: old }
  ])
  routes["POST /api/companies/" + COMPANY + "/inbox-dismissals"] = { status: 201, body: { ok: true } }

  const counted = await run("clear-failed", "--company", COMPANY, "--older-than-days", "7")
  assert.equal(counted.last.matched, 2, "two old failures, and nothing else")
  assert.equal(counted.last.cleared, 0, "counting must not clear anything")
  assert.equal(seen.filter((r) => r.method === "POST").length, 0)

  seen = []
  const applied = await run("clear-failed", "--company", COMPANY,
                            "--older-than-days", "7", "--apply")
  assert.equal(applied.last.cleared, 2)
  const posted = seen.filter((r) => r.method === "POST").map((r) => r.body.itemKey)
  assert.deepEqual(posted, ["attention:run:r1", "attention:run:r2"])
})

// ------------------------------------------------------- the reading half
//
// The probe is what hands the write path its ids, and what the bubble counts.
// Both halves are pinned against the same stub so they cannot drift apart.

const probe = path.join(root, "bin", "omarchy-paperclip-status")

// A machine with no Paperclip (CI) reads "not set up" before it reads the
// inbox, so the probe gets a data dir that holds an instance.
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "paperclip-data-"))
fs.mkdirSync(path.join(dataDir, "instances", "default"), { recursive: true })

function runProbe(...args) {
  return new Promise((resolve, reject) => {
    const child = spawn("python3", [probe, "--compact", ...args, "--api-base", base],
                        { stdio: ["ignore", "pipe", "pipe"],
                          env: { ...process.env, PAPERCLIP_DATA_DIR: dataDir } })
    let out = ""
    child.stdout.on("data", (chunk) => { out += chunk })
    child.on("error", reject)
    child.on("close", () => {
      try {
        resolve(JSON.parse(out))
      } catch (error) {
        reject(new Error("unparseable probe output: " + out))
      }
    })
  })
}

await group("the probe counts the whole inbox, never the desk badge", async () => {
  routes["GET /api/health"] = { status: 200, body: { status: "ok", version: "test" } }
  routes["GET /api/companies"] = {
    status: 200,
    body: { companies: [{ id: COMPANY, name: "Sceny", issuePrefix: "SCE" }] }
  }
  routes["GET /api/companies/" + COMPANY + "/heartbeat-runs"] = { status: 200, body: { runs: [] } }
  routes["GET /api/companies/" + COMPANY + "/attention"] = {
    status: 200,
    body: {
      totalCount: 147,
      // The number that could never be cleared. Nothing may read it.
      deskBadgeCount: 9,
      countsBySourceKind: { failed_run: 124, review: 3, blocker_attention: 20 },
      items: [failedRunItem(1), {
        sourceKind: "review",
        subject: { kind: "issue", id: "iss-1", identifier: "SCE-39", title: "Accept the gate" },
        dismissalKey: "attention:review:iss-1",
        whyNow: "Issue is in review without a maintained reviewer."
      }]
    }
  }

  const report = await runProbe("--inbox-items", "10")
  assert.equal(report.attention, 147, "the count is the whole feed")
  assert.equal(report.inboxTotal, 147)
  assert.equal(report.inboxShown, 2, "and it says how many of them it listed")
  assert.equal(report.retryableCount, 124, "the Retry all counter is the failed-run count")
  assert.equal(report.summary, "147 need you")
  // The server already ranked the feed in decide order. A second sort on the
  // client is how the list stopped matching the number.
  assert.ok(seen.some((r) => r.url.indexOf("sort=decide") > 0))
  assert.equal(report.needs[0].kind, "failed_run")

  // Every id the write path needs survives the projection.
  const failed = report.needs[0]
  assert.equal(failed.itemKey, "attention:run:run-1")
  assert.equal(failed.agentId, "agent-1")
  assert.equal(failed.runId, "run-1")
  assert.equal(failed.companyId, COMPANY)
  assert.equal(failed.retryable, true)
  assert.equal(failed.retryKind, "run")
  assert.equal(failed.isError, true)

  // A review is waiting on a person: no attempt to repeat, so no button.
  const review = report.needs[1]
  assert.equal(review.retryable, false)
  assert.equal(review.retryKind, "")
  assert.equal(review.isError, false)
  assert.equal(review.identifier, "SCE-39")
  assert.equal(review.itemKey, "attention:review:iss-1")
})

await group("the probe's All filter asks for what was snoozed or cleared", async () => {
  routes["GET /api/health"] = { status: 200, body: { status: "ok" } }
  routes["GET /api/companies"] = {
    status: 200, body: { companies: [{ id: COMPANY, name: "Sceny" }] }
  }
  routes["GET /api/companies/" + COMPANY + "/heartbeat-runs"] = { status: 200, body: { runs: [] } }
  routes["GET /api/companies/" + COMPANY + "/attention"] = {
    status: 200,
    body: {
      totalCount: 1,
      countsBySourceKind: {},
      items: [{
        sourceKind: "review",
        subject: { kind: "issue", id: "iss-2", identifier: "SCE-1", title: "Snoozed one" },
        dismissalKey: "attention:review:iss-2",
        // The shape the real server sends (seen on the rig): the snooze lives
        // inside the dismissal, and the top-level snoozedUntil is null.
        snoozedUntil: null,
        dismissal: {
          kind: "snooze",
          snoozedUntil: new Date(Date.now() + 3600000).toISOString(),
          isActive: true
        }
      }]
    }
  }

  const needsMe = await runProbe()
  assert.ok(seen[2].url.indexOf("includeDismissed") < 0, "the open inbox asks for the open inbox")
  assert.equal(needsMe.inboxFilter, "needs-me")

  seen = []
  const all = await runProbe("--inbox-filter", "all")
  assert.equal(all.inboxFilter, "all")
  assert.ok(seen.some((r) => r.url.indexOf("includeDismissed=true") > 0))
  // A hidden row says it is hidden, so clearing one by mistake is findable.
  assert.equal(all.needs[0].hidden, true)
  assert.ok(all.needs[0].snoozedUntil.length > 0)
})

await group("an inbox the probe could not read says so, instead of reading zero", async () => {
  routes["GET /api/health"] = { status: 200, body: { status: "ok" } }
  routes["GET /api/companies"] = {
    status: 200, body: { companies: [{ id: COMPANY, name: "Sceny" }] }
  }
  routes["GET /api/companies/" + COMPANY + "/heartbeat-runs"] = { status: 200, body: { runs: [] } }
  // The attention call fails while the instance is otherwise fine. Reading
  // that as "nothing is waiting" is how a number nobody can trust is born.
  routes["GET /api/companies/" + COMPANY + "/attention"] = { status: 500, body: { error: "boom" } }

  const report = await runProbe()
  assert.equal(report.inboxStale, true)
  assert.equal(report.attention, 0)
  assert.ok(report.problems.some((p) => p.indexOf("Sceny") >= 0 && p.indexOf("incomplete") >= 0),
            "the panel has to be able to say why the count is short")
})

await group("an instance that is down is still a readable report", async () => {
  routes = {}
  const report = await runProbe()
  assert.equal(report.state, "stopped")
  assert.equal(report.attention, 0)
  assert.equal(report.retryableCount, 0)
  assert.deepEqual(report.needs, [])
})

server.close()
fs.rmSync(dataDir, { recursive: true, force: true })
console.log("all groups passed")
