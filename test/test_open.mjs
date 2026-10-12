// The open script's branch choice, with a stub browser and a stub compositor.
//
//   node test/test_open.mjs
//
// What is pinned: a row's url always reaches the browser (a raised window
// would stay on the page it was on), the board itself only raises, Shift
// forces a window, and a url outside the instance's own origin never gets that
// far.

import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const script = path.join(root, "bin", "omarchy-paperclip-open")
const BASE = "http://127.0.0.1:3199"

function run(args, { windowOpen, clients }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pc-open-"))
  const log = path.join(dir, "calls.log")
  const stub = (name, body) => {
    const file = path.join(dir, name)
    fs.writeFileSync(file, "#!/bin/bash\n" + body + "\n", { mode: 0o755 })
  }
  stub("omarchy-launch-webapp", `echo "launch $*" >> "${log}"`)
  stub("hyprctl", [
    `if [[ $1 == clients ]]; then`,
    clients
      ? `  echo '${JSON.stringify(clients)}'`
      : windowOpen
      ? `  echo '[{"address":"0xabc","class":"brave-127.0.0.1__-Default","title":"Inbox - Paperclip","mapped":true}]'`
      : `  echo '[]'`,
    `else echo "focus $*" >> "${log}"; echo ok; fi`,
  ].join("\n"))
  const result = spawnSync("bash", [script, ...args], {
    env: {
      PATH: dir + ":" + process.env.PATH,
      HOME: dir,
      PAPERCLIP_OMARCHY_API_BASE: BASE,
    },
    encoding: "utf8",
  })
  const calls = fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n") : []
  fs.rmSync(dir, { recursive: true, force: true })
  return { status: result.status, calls }
}

const issue = BASE + "/SCE/issues/SCE-444"

let r = run([issue], { windowOpen: true })
assert.equal(r.status, 0)
assert.deepEqual(r.calls, ["launch " + issue], "a row opens its url even when a window is open, and never dispatches a focus")

r = run([issue], { windowOpen: false })
assert.deepEqual(r.calls, ["launch " + issue], "a row opens its url when no window is open")

r = run([], { windowOpen: true })
assert.equal(r.calls.length, 1)
assert.match(r.calls[0], /^focus /, "the board raises the open window")

r = run([BASE + "/"], { windowOpen: true })
assert.match(r.calls[0], /^focus /, "the board with a trailing slash raises too")

r = run([], { windowOpen: false })
assert.deepEqual(r.calls, ["launch " + BASE], "the board starts a window when none is open")

r = run(["--new-window", BASE], { windowOpen: true })
assert.deepEqual(r.calls, ["launch " + BASE], "Shift asks for a window of its own")

r = run(["file:///etc/passwd"], { windowOpen: true })
assert.notEqual(r.status, 0)
assert.deepEqual(r.calls, [], "a non-http url reaches nothing")

// A url on another origin never reaches the browser, however it is spelled.
for (const bad of [
  "https://evil.example/login",
  "http://evil.example",
  "https://127.0.0.1:3199/SCE/issues/SCE-1",
  "http://127.0.0.1:3198/",
  "http://127.0.0.1:31990/",
  "http://127.0.0.1/",
  "http://127.0.0.1:3199.evil.example/",
  "http://127.0.0.1:3199@evil.example/",
  "http://127.0.0.1:3199\\@evil.example/",
  "http://evil.example/?next=" + BASE,
  "//evil.example/",
  "ftp://127.0.0.1:3199/",
]) {
  r = run([bad], { windowOpen: true })
  assert.notEqual(r.status, 0, "refused: " + bad)
  assert.deepEqual(r.calls, [], "nothing is launched or raised for " + bad)
}

r = run(["--new-window", "https://evil.example/"], { windowOpen: false })
assert.notEqual(r.status, 0)
assert.deepEqual(r.calls, [], "--new-window does not widen the origin")

r = run(["HTTP://127.0.0.1:3199/SCE/issues/SCE-2?a=1#b"], { windowOpen: false })
assert.equal(r.status, 0, "scheme and host compare without case")
assert.equal(r.calls.length, 1)

// A title is text any page can set. A window that only says "Paperclip" in its
// title or class, with no instance host in its class, is never raised.
const stranger = { address: "0xbad", class: "firefox", title: "Inbox - Paperclip", mapped: true }
r = run([], { clients: [stranger] })
assert.deepEqual(r.calls, ["launch " + BASE], "a title alone does not take the click")

r = run([], { clients: [{ ...stranger, class: "Paperclip" }] })
assert.deepEqual(r.calls, ["launch " + BASE], "an app name in the class alone does not take it either")

// Several windows of the host: the one that also carries the app name wins.
const hostOnly = { address: "0x111", class: "brave-127.0.0.1__-Default", title: "Docs", mapped: true }
const hostAndName = { address: "0x222", class: "brave-127.0.0.1__-Default", title: "Inbox - Paperclip", mapped: true }
r = run([], { clients: [stranger, hostOnly, hostAndName] })
assert.equal(r.calls.length, 1)
assert.match(r.calls[0], /^focus .*0x222/, "the host and name window is chosen among several")

r = run([], { clients: [stranger, hostOnly] })
assert.match(r.calls[0], /^focus .*0x111/, "a host window without the name is still the board's window")

console.log("open: ok")
