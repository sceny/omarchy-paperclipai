// The open script's branch choice, with a stub browser and a stub compositor.
//
//   node test/test_open.mjs
//
// What is pinned: a row's url always reaches the browser (a raised window
// would stay on the page it was on), the board itself only raises, Shift
// forces a window, and a non-http url never gets that far.

import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const script = path.join(root, "bin", "omarchy-paperclip-open")
const BASE = "http://127.0.0.1:3199"

function run(args, { windowOpen }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pc-open-"))
  const log = path.join(dir, "calls.log")
  const stub = (name, body) => {
    const file = path.join(dir, name)
    fs.writeFileSync(file, "#!/bin/bash\n" + body + "\n", { mode: 0o755 })
  }
  stub("omarchy-launch-webapp", `echo "launch $*" >> "${log}"`)
  stub("hyprctl", [
    `if [[ $1 == clients ]]; then`,
    windowOpen
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

console.log("open: ok")
