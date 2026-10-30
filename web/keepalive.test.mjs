#!/usr/bin/env node
// Regression test: an idle keep-alive socket must not stop the server from
// accepting a new connection.
//
// moon's `Server.serve_concurrent` drains its whole batch of connection
// fibers before accepting again, and a fiber lives for the keep-alive socket,
// so enough idle browser sockets park the accept loop. The SPA then fails to
// mount with "TypeError: NetworkError when attempting to fetch resource" when
// its `app.wasm` fetch lands on a new connection (see
// todo-backend/src/serve.mo and PLAN.md, `moon-serve-concurrent-parks-accept-loop`).
//
// The old loop served 16 sockets of `max_in_flight` and then never accepted a
// 17th. This holds more idle sockets than that, then requires a fresh request
// (a new TCP connection, outside the held set) to be answered.
//
// Usage: node web/keepalive.test.mjs [base-url] [idle-sockets] [asset-path]

import net from "node:net";

const baseUrl = new URL(process.argv[2] ?? "http://127.0.0.1:8095");
const idleCount = Number(process.argv[3] ?? 24);
const assetPath = process.argv[4] ?? "/web/app.wasm";
const host = baseUrl.hostname;
const port = Number(baseUrl.port || (baseUrl.protocol === "https:" ? 443 : 80));

function fail(message) {
  console.error(`keepalive: FAIL ${message}`);
  process.exit(1);
}

/** Open one socket, send one request, consume the whole response, keep it open. */
function holdIdleSocket(index) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port });
    let buffered = Buffer.alloc(0);
    let head = null;
    socket.setTimeout(10_000, () => {
      socket.destroy();
      reject(new Error(`socket ${index}: no response within 10s`));
    });
    const onError = (error) => reject(new Error(`socket ${index}: ${error.message}`));
    socket.once("error", onError);
    socket.once("connect", () => {
      socket.write(`GET /web/boot.version HTTP/1.1\r\nHost: ${baseUrl.host}\r\n\r\n`);
    });
    socket.on("data", (chunk) => {
      buffered = Buffer.concat([buffered, chunk]);
      if (head === null) {
        const end = buffered.indexOf("\r\n\r\n");
        if (end < 0) return;
        const text = buffered.subarray(0, end).toString("latin1");
        const status = text.split("\r\n")[0];
        if (!status.includes(" 200 ")) {
          socket.destroy();
          reject(new Error(`socket ${index}: ${status}`));
          return;
        }
        const match = /^content-length:\s*(\d+)$/im.exec(text);
        if (match === null) {
          socket.destroy();
          reject(new Error(`socket ${index}: no content-length`));
          return;
        }
        head = { bodyStart: end + 4, length: Number(match[1]) };
      }
      if (buffered.length - head.bodyStart < head.length) return;
      socket.removeListener("error", onError);
      // A held socket the server later resets must not become an unhandled
      // 'error' event and take the process down.
      socket.on("error", () => {});
      socket.setTimeout(0);
      // Stop reading: the connection stays open and idle, which is the point.
      socket.removeAllListeners("data");
      resolve(socket);
    });
  });
}

const held = [];
try {
  for (let i = 0; i < idleCount; i += 1) {
    held.push(await holdIdleSocket(i));
  }

  const response = await fetch(new URL(assetPath, baseUrl), {
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) fail(`new connection got HTTP ${response.status} for ${assetPath}`);
  const bytes = await response.arrayBuffer();
  if (bytes.byteLength < 1024) fail(`new connection got only ${bytes.byteLength} bytes`);

  console.log(
    `keepalive: ok ${held.length} idle keep-alive sockets held, new connection served ${assetPath} (${bytes.byteLength} bytes)`,
  );
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
} finally {
  for (const socket of held) socket.destroy();
}
