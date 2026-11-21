// push.mjs - the app's Web Push sender (slice 6): VAPID (RFC 8292) and aes128gcm payload
// encryption (RFC 8291, RFC 8188), with node's built-in node:crypto only. Optional on the brain:
// without node, the app reports push as unavailable. The server (lib/app/server.py) runs it:
//   node push.mjs keys <keys.json>               create the VAPID keys once (0600); print the public key
//   node push.mjs send <keys.json> <subject>     stdin {subscription, payload, ttl}; POST it; print {status}
//   node push.mjs selftest                       RFC 8291 appendix A, and a VAPID signature round trip
// Payloads are encrypted end to end: the push service (the browser maker's) sees only ciphertext,
// the endpoint and the timing.
import crypto from "node:crypto";
import fs from "node:fs";

const b64u = (buf) => Buffer.from(buf).toString("base64url");
const unb64u = (s) => Buffer.from(s, "base64url");
const hkdf = (salt, ikm, info, len) => Buffer.from(crypto.hkdfSync("sha256", ikm, salt, info, len));

// RFC 8291 section 3.4 and RFC 8188: one record, rs 4096, the 0x02 delimiter, no padding.
export function encrypt(plaintext, uaPublic, authSecret, fixed = {}) {
  const ecdh = crypto.createECDH("prime256v1");
  if (fixed.asPrivate) ecdh.setPrivateKey(fixed.asPrivate); else ecdh.generateKeys();
  const asPublic = ecdh.getPublicKey();
  const shared = ecdh.computeSecret(uaPublic);
  const ikm = hkdf(authSecret, shared, Buffer.concat([Buffer.from("WebPush: info\0"), uaPublic, asPublic]), 32);
  const salt = fixed.salt || crypto.randomBytes(16);
  const cek = hkdf(salt, ikm, Buffer.from("Content-Encoding: aes128gcm\0"), 16);
  const nonce = hkdf(salt, ikm, Buffer.from("Content-Encoding: nonce\0"), 12);
  const body = Buffer.concat([Buffer.from(plaintext), Buffer.from([2])]);
  if (body.length + 16 > 4096 - 86) throw new Error("the payload is too long for one record");
  const c = crypto.createCipheriv("aes-128-gcm", cek, nonce);
  const ct = Buffer.concat([c.update(body), c.final(), c.getAuthTag()]);
  const head = Buffer.alloc(21);
  salt.copy(head, 0);
  head.writeUInt32BE(4096, 16);
  head[20] = asPublic.length;
  return Buffer.concat([head, asPublic, ct]);
}

function newKeys() {
  const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const jwk = privateKey.export({ format: "jwk" });
  return { jwk, public: b64u(Buffer.concat([Buffer.from([4]), unb64u(jwk.x), unb64u(jwk.y)])) };
}

// The VAPID header: an ES256 JWT (raw r||s, never DER) for the endpoint's origin, 12 hours.
export function vapid(endpoint, keys, subject, now = Date.now()) {
  const head = b64u(JSON.stringify({ typ: "JWT", alg: "ES256" }));
  const claims = b64u(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(now / 1000) + 12 * 3600, sub: subject }));
  const key = crypto.createPrivateKey({ key: keys.jwk, format: "jwk" });
  const sig = crypto.sign("sha256", Buffer.from(head + "." + claims), { key, dsaEncoding: "ieee-p1363" });
  return "vapid t=" + head + "." + claims + "." + b64u(sig) + ", k=" + keys.public;
}

async function readStdin() {
  let s = "";
  for await (const chunk of process.stdin) s += chunk;
  return s;
}

function selftest() {
  // RFC 8291 appendix A
  const v = {
    plaintext: "When I grow up, I want to be a watermelon",
    asPrivate: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
    uaPublic: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    auth: "BTBZMqHH6r4Tts7J_aSIgg",
    salt: "DGv6ra1nlYgDCS1FRnbzlw",
    // 144 bytes: salt, rs 4096, idlen 65, as_public, then the 58 bytes of ciphertext and tag
    result: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
  };
  const got = b64u(encrypt(v.plaintext, unb64u(v.uaPublic), unb64u(v.auth), { asPrivate: unb64u(v.asPrivate), salt: unb64u(v.salt) }));
  if (got !== v.result) throw new Error("RFC 8291 vector: got " + got);
  // a VAPID signature verifies with the public key, as raw r||s of 64 bytes
  const keys = newKeys();
  const t = vapid("https://push.example.net/x", keys, "mailto:a@example.com").split(" ")[1].slice(2, -1);
  const [h, c, s] = t.split(".");
  if (unb64u(s).length !== 64) throw new Error("the signature is not raw r||s");
  const pub = crypto.createPublicKey({ key: { kty: "EC", crv: "P-256", x: keys.jwk.x, y: keys.jwk.y }, format: "jwk" });
  if (!crypto.verify("sha256", Buffer.from(h + "." + c), { key: pub, dsaEncoding: "ieee-p1363" }, unb64u(s))) throw new Error("VAPID signature does not verify");
  if (JSON.parse(unb64u(c)).aud !== "https://push.example.net") throw new Error("aud is not the origin");
  return "ok";
}

async function main() {
  const [cmd, file, subject] = process.argv.slice(2);
  if (cmd === "selftest") { console.log(selftest()); return; }
  if (cmd === "keys") {
    if (!fs.existsSync(file)) fs.writeFileSync(file, JSON.stringify(newKeys()), { mode: 0o600, flag: "wx" });
    console.log(JSON.parse(fs.readFileSync(file, "utf8")).public);
    return;
  }
  if (cmd === "send") {
    const keys = JSON.parse(fs.readFileSync(file, "utf8"));
    const req = JSON.parse(await readStdin());
    const sub = req.subscription;
    const body = encrypt(JSON.stringify(req.payload), unb64u(sub.keys.p256dh), unb64u(sub.keys.auth));
    const r = await fetch(sub.endpoint, {
      method: "POST", body, signal: AbortSignal.timeout(20000),
      headers: { TTL: String(req.ttl || 86400), Urgency: "high", "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
        Authorization: vapid(sub.endpoint, keys, subject) },
    });
    console.log(JSON.stringify({ status: r.status, text: (await r.text()).slice(0, 200) }));
    return;
  }
  console.error("usage: push.mjs keys|send|selftest");
  process.exit(2);
}

main().catch((e) => { console.error("push: " + e.message); process.exit(1); });
