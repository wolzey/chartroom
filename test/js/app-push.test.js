// lib/app/push.mjs, the app's Web Push sender: the RFC 8291 vector, VAPID keys kept 0600, and a send
// to a local fake push endpoint that decrypts the body as a browser would (RFC 8291 and 8188) and
// checks the VAPID JWT. No real push service is ever reached.
"use strict";
const assert = require("assert");
const crypto = require("crypto");
const http = require("http");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { execFileSync, spawn } = require("child_process");

const PUSH = path.join(__dirname, "../../lib/app/push.mjs");
let n = 0, failed = 0;
async function t(name, fn) {
  n++;
  try { await fn(); console.log("ok   " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + String(e.stack || e).split("\n").slice(0, 5).join("\n     ")); }
}
const hk = (salt, ikm, info, len) => Buffer.from(crypto.hkdfSync("sha256", ikm, salt, info, len));

// what the browser does with a push body
function decrypt(body, ua, auth) {
  const salt = body.subarray(0, 16), idlen = body[20];
  assert.strictEqual(body.readUInt32BE(16), 4096);
  const asPublic = body.subarray(21, 21 + idlen), ct = body.subarray(21 + idlen);
  const ikm = hk(auth, ua.computeSecret(asPublic), Buffer.concat([Buffer.from("WebPush: info\0"), ua.getPublicKey(), asPublic]), 32);
  const d = crypto.createDecipheriv("aes-128-gcm", hk(salt, ikm, Buffer.from("Content-Encoding: aes128gcm\0"), 16), hk(salt, ikm, Buffer.from("Content-Encoding: nonce\0"), 12));
  d.setAuthTag(ct.subarray(ct.length - 16));
  const pt = Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
  assert.strictEqual(pt[pt.length - 1], 2, "the last record ends with the 0x02 delimiter");
  return pt.subarray(0, pt.length - 1).toString();
}

function send(keys, subject, input) {
  return new Promise((resolve, reject) => {
    const p = spawn(process.execPath, [PUSH, "send", keys, subject]);
    let out = "", err = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("close", (code) => (code === 0 ? resolve(JSON.parse(out)) : reject(new Error(err))));
    p.stdin.end(JSON.stringify(input));
  });
}

(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "push-"));
  const keys = path.join(dir, "keys.json");

  await t("selftest: the RFC 8291 appendix A vector, and a VAPID signature that verifies", () => {
    assert.strictEqual(execFileSync(process.execPath, [PUSH, "selftest"]).toString().trim(), "ok");
  });

  await t("keys: made once, 0600, the same public key every time after", () => {
    const a = execFileSync(process.execPath, [PUSH, "keys", keys]).toString().trim();
    const b = execFileSync(process.execPath, [PUSH, "keys", keys]).toString().trim();
    assert.strictEqual(a, b);
    assert.strictEqual(Buffer.from(a, "base64url").length, 65);
    assert.strictEqual(fs.statSync(keys).mode & 0o777, 0o600);
  });

  await t("send: an encrypted body a browser can open, with VAPID for the endpoint's origin", async () => {
    const ua = crypto.createECDH("prime256v1"); ua.generateKeys();
    const auth = crypto.randomBytes(16);
    let got = null;
    const srv = http.createServer((req, res) => {
      const parts = [];
      req.on("data", (c) => parts.push(c));
      req.on("end", () => { got = { url: req.url, headers: req.headers, body: Buffer.concat(parts) }; res.writeHead(201); res.end(); });
    });
    await new Promise((r) => srv.listen(0, "127.0.0.1", r));
    const origin = "http://127.0.0.1:" + srv.address().port;
    const payload = { title: "Approve the plan", body: "acme · Approve", url: "/#/n/acme%3Aq-1", tag: "acme:q-1" };
    const r = await send(keys, "mailto:crew@example.com", { subscription: { endpoint: origin + "/push/abc",
      keys: { p256dh: ua.getPublicKey().toString("base64url"), auth: auth.toString("base64url") } }, payload, ttl: 600 });
    srv.close();
    assert.strictEqual(r.status, 201);
    assert.strictEqual(got.url, "/push/abc");
    assert.strictEqual(got.headers["content-encoding"], "aes128gcm");
    assert.strictEqual(got.headers.ttl, "600");
    assert.deepStrictEqual(JSON.parse(decrypt(got.body, ua, auth)), payload);
    const m = /^vapid t=([^.]+)\.([^.]+)\.([^,]+), k=(.+)$/.exec(got.headers.authorization);
    assert.ok(m, "a vapid Authorization header");
    const pub = Buffer.from(m[4], "base64url");
    assert.strictEqual(m[4], execFileSync(process.execPath, [PUSH, "keys", keys]).toString().trim());
    const key = crypto.createPublicKey({ key: { kty: "EC", crv: "P-256", x: pub.subarray(1, 33).toString("base64url"), y: pub.subarray(33).toString("base64url") }, format: "jwk" });
    assert.ok(crypto.verify("sha256", Buffer.from(m[1] + "." + m[2]), { key, dsaEncoding: "ieee-p1363" }, Buffer.from(m[3], "base64url")));
    const claims = JSON.parse(Buffer.from(m[2], "base64url"));
    assert.strictEqual(claims.aud, origin);
    assert.strictEqual(claims.sub, "mailto:crew@example.com");
    assert.ok(claims.exp > Date.now() / 1000 && claims.exp <= Date.now() / 1000 + 24 * 3600);
  });

  await t("send: a gone subscription comes back as its status (the server drops it)", async () => {
    const ua = crypto.createECDH("prime256v1"); ua.generateKeys();
    const srv = http.createServer((req, res) => { req.resume(); req.on("end", () => { res.writeHead(410); res.end("gone"); }); });
    await new Promise((r) => srv.listen(0, "127.0.0.1", r));
    const r = await send(keys, "mailto:crew@example.com", { subscription: { endpoint: "http://127.0.0.1:" + srv.address().port + "/x",
      keys: { p256dh: ua.getPublicKey().toString("base64url"), auth: crypto.randomBytes(16).toString("base64url") } }, payload: { title: "x" } });
    srv.close();
    assert.strictEqual(r.status, 410);
  });

  fs.rmSync(dir, { recursive: true, force: true });
  console.log(n - failed + "/" + n + " passed");
  process.exit(failed ? 1 : 0);
})();
