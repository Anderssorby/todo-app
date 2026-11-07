// End-to-end ATproto OAuth sign-in smoke.
//
// Spins a stub resolver/PDS/authorization-server on 127.0.0.1 (plain http
// is the ATproto loopback-development shape and the backend allows it for
// localhost origins), starts a real todo-backend against it, and drives
// the whole flow: handle form -> PAR -> 302 -> callback -> token exchange
// -> PDS session confirmation -> app session cookie -> /api/me.
//
// The stub VERIFIES the DPoP proof header on every protected request with
// Node's crypto (the public key comes from the proof's own `jwk`), so the
// ES256 signatures the app produces through the FFI seam are checked the
// way a real server would check them.
//
// Usage: node web/auth-smoke.mjs <backend-binary> [port]

import { createServer } from "node:http";
import { createPublicKey, verify } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const backend = process.argv[2];
if (!backend) {
  console.error("usage: node web/auth-smoke.mjs <backend-binary> [port]");
  process.exit(1);
}
const port = Number(process.argv[3] || 8096);

const DID = "did:plc:smoke1";
const HANDLE = "localhost";

const failures = [];
function check(ok, label) {
  if (ok) console.log(`ok: ${label}`);
  else {
    console.error(`FAIL: ${label}`);
    failures.push(label);
  }
}

function b64urlToBuffer(s) {
  return Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

// Paths whose requests REQUIRE a proof; the identity/DID-document/metadata
// lookups are plain fetches on purpose, so a missing header there is not
// a failure and is not logged as one.
const PROTECTED_PATHS = ["/par", "/token", "/xrpc/com.atproto.server.getSession"];

// Verify one DPoP proof (JWS compact, raw r||s signature) and return its
// payload object. `null` means the proof did not check out; the reason is
// printed so a broken proof is diagnosable from the smoke output alone.
function verifyDpop(header, label) {
  if (!header) {
    if (PROTECTED_PATHS.includes(label)) {
      console.error(`dpop-fail(${label}): no DPoP header`);
    }
    return null;
  }
  const parts = header.split(".");
  if (parts.length !== 3) {
    console.error(`dpop-fail(${label}): ${parts.length} parts, want 3`);
    return null;
  }
  try {
    const head = JSON.parse(b64urlToBuffer(parts[0]).toString("utf8"));
    const payload = JSON.parse(b64urlToBuffer(parts[1]).toString("utf8"));
    if (head.typ !== "dpop+jwt" || head.alg !== "ES256" || !head.jwk) {
      console.error(`dpop-fail(${label}): bad JOSE header ${JSON.stringify(head)}`);
      return null;
    }
    // Like the Bluesky AS: optional claims must be absent or strings
    // (a `"nonce":null` is rejected as "Invalid DPoP \"nonce\" type").
    for (const claim of ["nonce", "ath"]) {
      if (claim in payload && typeof payload[claim] !== "string") {
        console.error(`dpop-fail(${label}): ${claim} is ${JSON.stringify(payload[claim])}, want string or absent`);
        return null;
      }
    }
    if (head.jwk.kty !== "EC" || head.jwk.crv !== "P-256") {
      console.error(`dpop-fail(${label}): bad jwk ${JSON.stringify(head.jwk)}`);
      return null;
    }
    const key = {
      kty: "EC", crv: "P-256", x: head.jwk.x, y: head.jwk.y,
    };
    const sig = b64urlToBuffer(parts[2]);
    if (sig.length !== 64) {
      console.error(`dpop-fail(${label}): signature is ${sig.length} bytes, want 64`);
      return null;
    }
    // Node does not take a bare JWK object as the verify key; it has to be
    // imported as one first.
    const pub = createPublicKey({ key, format: "jwk" });
    const ok = verify("sha256", Buffer.from(`${parts[0]}.${parts[1]}`), {
      key: pub,
      dsaEncoding: "ieee-p1363",
    }, sig);
    if (!ok) console.error(`dpop-fail(${label}): signature does not verify`);
    return ok ? payload : null;
  } catch (e) {
    console.error(`dpop-fail(${label}): ${e.message}`);
    return null;
  }
}

let lastParState = null;
let dpopProofsSeen = 0;

const stub = createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${stubPort}`);
  const reply = (status, body, headers = {}) => {
    res.writeHead(status, { "content-type": "application/json", ...headers });
    res.end(typeof body === "string" ? body : JSON.stringify(body));
  };
  const stubBase = `http://127.0.0.1:${stubPort}`;

  const dpopPayload = verifyDpop(req.headers["dpop"], url.pathname);
  if (dpopPayload) dpopProofsSeen += 1;

  if (req.method === "GET" && url.pathname === "/xrpc/com.atproto.identity.resolveHandle") {
    return reply(200, { did: DID });
  }
  if (req.method === "GET" && url.pathname === `/${DID}`) {
    return reply(200, {
      "@context": ["https://www.w3.org/ns/did/v1"],
      id: DID,
      alsoKnownAs: ["at://smoke.test"],
      service: [{
        id: "#atproto_pds",
        type: "AtprotoPersonalDataServer",
        serviceEndpoint: `${stubBase}/`,
      }],
    });
  }
  if (req.method === "GET" && url.pathname === "/.well-known/oauth-protected-resource") {
    return reply(200, { authorization_servers: [stubBase] });
  }
  if (req.method === "GET" && url.pathname === "/.well-known/oauth-authorization-server") {
    return reply(200, {
      issuer: stubBase,
      authorization_endpoint: `${stubBase}/authorize`,
      token_endpoint: `${stubBase}/token`,
      pushed_authorization_request_endpoint: `${stubBase}/par`,
      dpop_signing_alg_values_supported: ["ES256"],
      response_types_supported: ["code"],
      code_challenge_methods_supported: ["S256"],
    });
  }
  if (req.method === "POST" && url.pathname === "/par") {
    if (!dpopPayload) return reply(400, { error: "no DPoP proof" });
    let body = "";
    req.on("data", (c) => { body += c; });
    return req.on("end", () => {
      const params = new URLSearchParams(body);
      for (const needed of ["client_id", "redirect_uri", "state", "code_challenge",
        "code_challenge_method", "login_hint", "dpop_jkt"]) {
        if (!params.get(needed)) return reply(400, { error: `missing ${needed}` });
      }
      if (params.get("code_challenge_method") !== "S256") {
        return reply(400, { error: "PKCE must be S256" });
      }
      lastParState = params.get("state");
      reply(200, { request_uri: "urn:ietf:params:oauth:request_uri:smoke" });
    });
  }
  if (req.method === "POST" && url.pathname === "/token") {
    if (!dpopPayload) return reply(400, { error: "no DPoP proof" });
    let body = "";
    req.on("data", (c) => { body += c; });
    return req.on("end", () => {
      const params = new URLSearchParams(body);
      if (params.get("grant_type") !== "authorization_code") {
        return reply(400, { error: "unsupported_grant_type" });
      }
      if (!params.get("code_verifier")) return reply(400, { error: "missing code_verifier" });
      reply(200, {
        access_token: "at_smoke",
        token_type: "DPoP",
        sub: DID,
        scope: "atproto",
        expires_in: 3600,
        refresh_token: "rt_smoke",
        iss: stubBase,
      });
    });
  }
  if (req.method === "GET" && url.pathname === "/xrpc/com.atproto.server.getSession") {
    if (!dpopPayload) return reply(401, { error: "invalid_token" });
    if (req.headers.authorization !== "DPoP at_smoke") {
      return reply(401, { error: "invalid_token" });
    }
    if (!dpopPayload.ath) return reply(401, { error: "missing ath" });
    return reply(200, { did: DID, handle: "smoke.test", email: "smoke@example.test" });
  }
  return reply(404, { error: "not_found" });
});

let stubPort = 0;
const dbDir = mkdtempSync(join(tmpdir(), "todo-auth-smoke-"));
const db = join(dbDir, "todos.db");

function die(msg) {
  console.error(`FAIL: ${msg}`);
  if (globalThis.server) globalThis.server.kill("SIGTERM");
  process.exit(1);
}

async function waitReady() {
  for (let i = 0; i < 100; i += 1) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/login`);
      if (r.ok) return;
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  die("backend never became ready");
}

async function main() {
  await new Promise((r) => { stub.listen(0, "127.0.0.1", r); });
  stubPort = stub.address().port;
  const server = spawn(backend, [
    "--port", String(port),
    "--db", db,
    "--auth-resolver", `http://127.0.0.1:${stubPort}`,
    "--auth-plc", `http://127.0.0.1:${stubPort}`,
    "--auth-redirect-uri", `http://127.0.0.1:${port}/auth/callback`,
  ], { stdio: ["ignore", "inherit", "inherit"] });
  globalThis.server = server;
  server.on("exit", (code) => {
    if (code !== null && code !== 0) die(`backend exited with ${code}`);
  });

  await waitReady();

  // Unauthenticated requests are rejected as before.
  const unauth = await fetch(`http://127.0.0.1:${port}/api/me`);
  check(unauth.status === 401, "no cookie gives 401 on /api/me");

  const loginHtml = await (await fetch(`http://127.0.0.1:${port}/login`)).text();
  check(loginHtml.includes('action="/auth/login"'), "the login page posts to /auth/login");

  const metadata = await (await fetch(`http://127.0.0.1:${port}/client-metadata.json`)).json();
  check(metadata.dpop_bound_access_tokens === true
    && metadata.token_endpoint_auth_method === "none"
    && metadata.redirect_uris.includes(`http://127.0.0.1:${port}/auth/callback`),
  "client-metadata.json declares the ATproto public-client shape");

  // The login form starts the flow: PAR, then a 302 to the AS.
  // `redirect: "manual"` on every fetch whose 302 is the point: followed
  // redirects would hide the status, the Location and the Set-Cookie.
  const login = await fetch(`http://127.0.0.1:${port}/auth/login`, {
    method: "POST",
    redirect: "manual",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "handle=smoke.test",
  });
  check(login.status === 302, "POST /auth/login redirects");
  const location = login.headers.get("location") || "";
  check(location.includes("request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3Asmoke"),
    "the redirect carries the PAR request_uri");
  check(location.includes("client_id="), "the redirect carries the client_id");
  check(Boolean(lastParState), "the stub saw a PAR request");

  // A bogus state is refused instead of silently creating a session.
  const badCallback = await fetch(`http://127.0.0.1:${port}/auth/callback?state=bogus&code=x`);
  check(badCallback.status === 400, "an unknown state is rejected");

  // The real callback finishes the exchange and sets the session cookie.
  const callback = await fetch(
    `http://127.0.0.1:${port}/auth/callback?state=${encodeURIComponent(lastParState)}&code=smoke-code`,
    { redirect: "manual" });
  check(callback.status === 302, "the callback redirects");
  check((callback.headers.get("location") || "") === "/", "the callback redirects to /");
  const setCookie = callback.headers.get("set-cookie") || "";
  check(setCookie.includes("todo_session=") && setCookie.includes("HttpOnly"),
    "the callback sets an HttpOnly todo_session cookie");
  const cookie = (setCookie.split(";")[0] || "").trim();

  // The session cookie authenticates /api/me with the resolved identity.
  const me = await (await fetch(`http://127.0.0.1:${port}/api/me`, {
    headers: { cookie },
  })).json();
  check(me.user && me.user.subject === DID && me.user.name === "smoke.test",
    "/api/me shows the signed-in ATproto user");
  check(typeof me.csrf === "string" && me.csrf.length > 0, "/api/me carries a CSRF token");

  const todos = await fetch(`http://127.0.0.1:${port}/api/todos`, { headers: { cookie } });
  check(todos.status === 200, "the session cookie authorizes /api/todos");

  // Logout destroys the server-side session; the cookie stops working.
  const logout = await fetch(`http://127.0.0.1:${port}/auth/logout`, {
    method: "POST",
    redirect: "manual",
    headers: { cookie },
  });
  check(logout.status === 302 && (logout.headers.get("location") || "") === "/login",
    "logout redirects to /login");
  const afterLogout = await fetch(`http://127.0.0.1:${port}/api/me`, { headers: { cookie } });
  check(afterLogout.status === 401, "the cookie no longer authenticates after logout");

  check(dpopProofsSeen >= 3,
    `every protected request carried a verifiable DPoP proof (${dpopProofsSeen} seen)`);

  if (failures.length) {
    console.error(`${failures.length} check(s) failed`);
    server.kill("SIGTERM");
    process.exit(1);
  }
  console.log("auth smoke: all checks passed");
  server.kill("SIGTERM");
  process.exit(0);
}

main().catch((e) => die(e && e.stack ? e.stack : String(e)));
