#!/usr/bin/env node
// `web_runtime.js` reads wasm32 pointer/length words as unsigned 32-bit
// values. `platform_web.c`'s `web_str_ptr` sign-extends (`int64_t` through
// `intptr_t`), so an address at or above 2 GiB arrives as a negative BigInt;
// without this conversion `new Uint8Array(memory.buffer, ptr, len)` throws
// `RangeError: invalid or out-of-range index` (Firefox) inside a patch.
//
// Usage (after running todo-webgen):
//   node web/runtime_args.test.mjs
import assert from "node:assert/strict";

// The generated copy carries the same exports as the vendored source.
const { word32 } = await import("./web_runtime.gen.js");

assert.equal(word32(-2147483648n), 0x80000000, "int32 min is address 2 GiB");
assert.equal(word32(-1n), 0xffffffff, "highest sign-extended word");
assert.equal(word32(1234n), 1234, "ordinary low address is unchanged");
assert.equal(word32(4294967295n), 4294967295, "already unsigned word");
assert.equal(word32(1234), 1234, "number-valued arguments (i32 imports)");
assert.equal(word32(undefined), 0, "a missing word is the null handle");

console.log("ok: wasm32 address words are treated as unsigned");
