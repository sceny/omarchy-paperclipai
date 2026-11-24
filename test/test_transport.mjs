// The two API clients, run as the plugin runs them, against listeners that
// misbehave.
//
//   node test/test_transport.mjs
//
// What is pinned here:
//
//   * a 3xx answer is an error, and the second port never sees a request, let
//     alone the Authorization header, from the probe or from the writer;
//   * the token still reaches a loopback listener this user owns (the real
//     /proc/net/tcp check runs here, the stub is ours);
//   * a token is never sent to a plain-http base on another host;
//   * an answer without an end is cut off at the cap and is an error.
//
// The foreign-listener case needs a second user, so it lives in
// test/test_transport.py with an injectable uid lookup.

import assert from "node:assert/strict"
import http from "node:http"
import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"
import path from "node:path"

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const status = path.join(root, "bin", "omarchy-paperclip-status")
const inbox = path.join(root, "bin", "omarchy-paperclip-inbox")
const TOKEN = "board-token-for-tests"

function listen(handler) {
  const seen = []
  const server = http.createServer((request, response) => {
    seen.push({ method: request.method, url: request.url, authorization: request.headers.authorization || "" })
    handler(request, response)
  })
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => {
    resolve({ server, seen, base: "http://127.0.0.1:" + server.address().port })
  }))
}

function run(script, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn("python3", [script, ...args],
      { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, PAPERCLIP_OMARCHY_TOKEN: TOKEN, ...env } })
    let out = ""
    child.stdout.on("data", (chunk) => { out += chunk })
    child.on("error", reject)
    child.on("close", (code) => {
      const lines = out.split("\n").filter((line) => line.trim() !== "").map((line) => JSON.parse(line))
      resolve({ code, last: lines[lines.length - 1] })
    })
  })
}

const probe = (base, env) => run(status, ["--api-base", base, "--compact", "--timeout", "5"], env)
const write = (base, env) => run(inbox, ["dismiss", "--company", "co-1", "--item-key", "attention:run:x",
                                         "--api-base", base, "--timeout", "5"], env)

async function group(name, body) {
  await body()
  console.log("ok - " + name)
}

await group("a redirect is refused by the probe and by the writer", async () => {
  for (const code of [301, 302, 303, 307, 308]) {
    const target = await listen((_q, r) => { r.writeHead(200, { "content-type": "application/json" }); r.end("{}") })
    const squatter = await listen((_q, r) => {
      r.writeHead(code, { location: target.base + "/api/health" })
      r.end()
    })
    const report = (await probe(squatter.base)).last
    assert.equal(report.reachable, false, String(code))
    assert.ok(report.problems.some((p) => p.includes("redirect refused")), JSON.stringify(report.problems))
    const written = (await write(squatter.base)).last
    assert.equal(written.ok, false, String(code))
    assert.ok(written.message.includes("redirect refused"), written.message)
    assert.equal(target.seen.length, 0, "the redirect target saw a request after a " + code)
    assert.ok(squatter.seen.length >= 2)
    target.server.close()
    squatter.server.close()
  }
})

await group("the token reaches a listener this user owns", async () => {
  const own = await listen((_q, r) => { r.writeHead(200, { "content-type": "application/json" }); r.end('{"status":"ok"}') })
  const report = (await probe(own.base)).last
  assert.equal(report.reachable, true)
  assert.equal(own.seen[0].authorization, "Bearer " + TOKEN)
  own.server.close()
})

await group("a token is never sent to plain http on another host", async () => {
  // 192.0.2.1 is TEST-NET-1: nothing there. No connection is attempted at all.
  const report = (await probe("http://192.0.2.1:3100")).last
  assert.equal(report.state, "untrusted-listener")
  assert.equal(report.reachable, false)
  const written = (await write("http://192.0.2.1:3100")).last
  assert.equal(written.ok, false)
  assert.equal(written.code, "token_withheld")
})

await group("an answer without an end is cut off and is an error", async () => {
  let stop = false
  const flood = await listen((_q, r) => {
    r.writeHead(200, { "content-type": "application/json" })
    const pump = () => {
      if (stop || r.destroyed) return
      if (r.write("x".repeat(65536))) setImmediate(pump)
      else r.once("drain", pump)
    }
    pump()
  })
  const report = (await probe(flood.base, { PAPERCLIP_OMARCHY_TOKEN: "" })).last
  assert.equal(report.reachable, false)
  assert.ok(report.problems.some((p) => p.includes("answer too large")), JSON.stringify(report.problems))
  const written = (await write(flood.base, { PAPERCLIP_OMARCHY_TOKEN: "" })).last
  assert.equal(written.ok, false)
  assert.ok(written.message.includes("answer too large"), written.message)
  stop = true
  flood.server.closeAllConnections()
  flood.server.close()
})
console.log("all groups passed")
