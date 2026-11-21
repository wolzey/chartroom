// A fake push service for test/app-push.bats: a browser's subscription on 127.0.0.1 (never a real
// push service). It writes the subscription to <sub.json>, then decrypts each push it receives as
// the browser would (RFC 8291, aes128gcm) and appends the payload, one JSON line each, to <got>.
// usage: node push-sink.js <sub.json> <got>
"use strict";
const crypto = require("crypto");
const http = require("http");
const fs = require("fs");

const [subFile, gotFile] = process.argv.slice(2);
const ua = crypto.createECDH("prime256v1");
ua.generateKeys();
const auth = crypto.randomBytes(16);
const hk = (salt, ikm, info, len) => Buffer.from(crypto.hkdfSync("sha256", ikm, salt, info, len));

function decrypt(body) {
  const salt = body.subarray(0, 16), idlen = body[20];
  const asPublic = body.subarray(21, 21 + idlen), ct = body.subarray(21 + idlen);
  const ikm = hk(auth, ua.computeSecret(asPublic), Buffer.concat([Buffer.from("WebPush: info\0"), ua.getPublicKey(), asPublic]), 32);
  const d = crypto.createDecipheriv("aes-128-gcm", hk(salt, ikm, Buffer.from("Content-Encoding: aes128gcm\0"), 16), hk(salt, ikm, Buffer.from("Content-Encoding: nonce\0"), 12));
  d.setAuthTag(ct.subarray(ct.length - 16));
  const pt = Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
  return pt.subarray(0, pt.length - 1).toString();
}

const srv = http.createServer((req, res) => {
  const parts = [];
  req.on("data", (c) => parts.push(c));
  req.on("end", () => {
    let line;
    try {
      if (!/^vapid t=[^.]+\.[^.]+\.[^,]+, k=/.test(req.headers.authorization || "")) throw new Error("no VAPID header");
      line = decrypt(Buffer.concat(parts));
    } catch (e) { line = JSON.stringify({ error: e.message }); }
    fs.appendFileSync(gotFile, line + "\n");
    res.writeHead(201); res.end();
  });
});
srv.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(subFile, JSON.stringify({ endpoint: "http://127.0.0.1:" + srv.address().port + "/push/dev1",
    keys: { p256dh: ua.getPublicKey().toString("base64url"), auth: auth.toString("base64url") } }));
});
