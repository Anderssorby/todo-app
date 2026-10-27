#!/usr/bin/env node
// Check that the generated loader graph is hash-pinned to the files it
// imports. `todo-webgen` writes boot.js/web.gen.js/web_runtime.gen.js and
// boot.version; this test recomputes every SHA-256 and compares.
//
// Usage (after building web/app.wasm and running todo-webgen):
//   node web/boot_url.test.mjs
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");

const web = await readFile(new URL("./web.gen.js", import.meta.url));
const runtime = await readFile(new URL("./web_runtime.gen.js", import.meta.url));
const float = await readFile(new URL("./float_format.js", import.meta.url));
const wasm = await readFile(new URL("./app.wasm", import.meta.url));
const boot = await readFile(new URL("./boot.js", import.meta.url), "utf8");
const bootVersion = (await readFile(new URL("./boot.version", import.meta.url), "utf8")).trim();
const index = await readFile(new URL("./index.html", import.meta.url), "utf8");

const webHash = sha(web);
const runtimeHash = sha(runtime);
const floatHash = sha(float);
const wasmHash = sha(wasm);

assert.ok(boot.includes(`./web.gen.js?v=${webHash}`), "boot.js must pin web.gen.js");
assert.ok(boot.includes(`./web_runtime.gen.js?v=${runtimeHash}`), "boot.js must pin web_runtime.gen.js");
assert.ok(boot.includes(`/web/app.wasm?v=${wasmHash}`), "boot.js must pin app.wasm");
assert.ok(web.toString().includes(`./web_runtime.gen.js?v=${runtimeHash}`), "web.gen.js must pin its runtime import");
assert.ok(runtime.toString().includes(`./float_format.js?v=${floatHash}`), "web_runtime.gen.js must pin its float import");
assert.equal(bootVersion, sha(boot), "boot.version must be the SHA-256 of boot.js");
assert.ok(index.includes("./boot.version") && index.includes("./boot.js?v="), "index.html must load the versioned boot");

console.log("ok: the loader graph imports are pinned to each file's SHA-256");
