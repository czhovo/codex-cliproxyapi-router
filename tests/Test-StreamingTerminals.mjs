import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const routerPath = path.join(repositoryRoot, "src", "codex-catalog-compat.mjs");
const testDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "cliproxy-stream-test-"));
const routingModePath = path.join(testDirectory, "routing-mode.txt");
fs.writeFileSync(routingModePath, "direct\n", "utf8");

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server.address().port);
    });
  });
}

function reservePort() {
  const server = http.createServer();
  return listen(server).then((port) => new Promise((resolve) => server.close(() => resolve(port))));
}

function request({ port, path: requestPath, method = "GET", headers = {}, body = "" }) {
  return new Promise((resolve, reject) => {
    const outgoing = http.request(
      { host: "127.0.0.1", port, path: requestPath, method, headers },
      (incoming) => {
        const chunks = [];
        incoming.on("data", (chunk) => chunks.push(chunk));
        incoming.once("aborted", () => reject(Object.assign(new Error("response aborted"), { code: "RESPONSE_ABORTED" })));
        incoming.once("error", reject);
        incoming.once("end", () => resolve({
          status: incoming.statusCode,
          body: Buffer.concat(chunks).toString("utf8"),
        }));
      },
    );
    outgoing.once("error", reject);
    outgoing.end(body);
  });
}

async function waitUntil(predicate, description, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for ${description}`);
}

const payloads = {
  "response.completed": {
    type: "response.completed",
    response: { status: "completed", error: null, incomplete_details: null },
  },
  "response.failed": {
    type: "response.failed",
    response: { status: "failed", error: { code: "synthetic_server_error", message: "synthetic failure" } },
  },
  "response.incomplete": {
    type: "response.incomplete",
    response: { status: "incomplete", incomplete_details: { reason: "max_output_tokens" } },
  },
  error: {
    type: "error",
    code: "synthetic_stream_error",
    message: "synthetic stream failure",
  },
  cyber_policy: {
    type: "error",
    error: {
      type: "invalid_request",
      code: "cyber_policy",
      message: "synthetic policy rejection",
    },
  },
};

let mockRequestCount = 0;
const mockServer = http.createServer((incoming, response) => {
  mockRequestCount += 1;
  incoming.resume();
  const terminal = String(incoming.headers["x-synthetic-terminal"] || "response.completed");
  response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
  if (terminal === "none") {
    response.end('event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"partial"}\n\n');
    return;
  }
  const eventType = terminal === "cyber_policy" ? "error" : terminal;
  response.end(`event: ${eventType}\ndata: ${JSON.stringify(payloads[terminal])}\n\n`);
});

let router;
let routerStderr = "";
const routerLogs = [];

try {
  const mockPort = await listen(mockServer);
  const routerPort = await reservePort();
  const unusedProxyPort = await reservePort();
  router = spawn(process.execPath, [routerPath], {
    cwd: repositoryRoot,
    env: {
      ...process.env,
      CODEX_COMPAT_PORT: String(routerPort),
      CLIPROXY_PORT: String(unusedProxyPort),
      CODEX_OFFICIAL_ORIGIN: `http://127.0.0.1:${mockPort}`,
      CODEX_OFFICIAL_PATH: "/backend-api/codex/responses",
      CODEX_ROUTING_MODE_FILE: routingModePath,
      CLIPROXY_CLIENT_KEY: "test",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdoutBuffer = "";
  router.stdout.setEncoding("utf8");
  router.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
    let newline;
    while ((newline = stdoutBuffer.indexOf("\n")) >= 0) {
      const line = stdoutBuffer.slice(0, newline);
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      try {
        routerLogs.push(JSON.parse(line));
      } catch {
        // Non-JSON child output is ignored by this structured-log test.
      }
    }
  });
  router.stderr.setEncoding("utf8");
  router.stderr.on("data", (chunk) => { routerStderr += chunk; });

  await waitUntil(() => routerLogs.some((entry) => entry.event === "ready"), "router readiness");

  const terminalCases = [
    { synthetic: "response.completed", expected: "response.completed" },
    { synthetic: "response.failed", expected: "response.failed" },
    { synthetic: "response.incomplete", expected: "response.incomplete" },
    { synthetic: "error", expected: "error" },
    { synthetic: "cyber_policy", expected: "error" },
  ];
  for (const terminalCase of terminalCases) {
    const body = JSON.stringify({ model: "gpt-6-astra", stream: true });
    const result = await request({
      port: routerPort,
      path: "/v1/responses",
      method: "POST",
      headers: {
        authorization: "test",
        "chatgpt-account-id": "test",
        "content-type": "application/json",
        "content-length": String(Buffer.byteLength(body)),
        "x-synthetic-terminal": terminalCase.synthetic,
      },
      body,
    });
    assert.equal(result.status, 200);
    assert.match(result.body, new RegExp(`event: ${terminalCase.expected.replace(".", "\\.")}`));
  }
  assert.equal(mockRequestCount, terminalCases.length, "terminal errors must not be retried by the router");

  await waitUntil(
    () => routerLogs.filter((entry) => entry.event === "complete" && entry.route === "official").length >= terminalCases.length,
    "terminal completion logs",
  );
  const completionLogs = routerLogs
    .filter((entry) => entry.event === "complete" && entry.route === "official")
    .slice(0, terminalCases.length);
  assert.deepEqual(completionLogs.map((entry) => entry.terminal_event), terminalCases.map((entry) => entry.expected));
  assert.deepEqual(
    completionLogs.map((entry) => entry.logical_outcome),
    ["completed", "failed", "incomplete", "failed", "failed"],
  );
  assert.equal(completionLogs[0].completed, true);
  assert.equal(completionLogs[1].completed, false);
  assert.equal(completionLogs[1].terminal_error.code, "synthetic_server_error");
  assert.equal(completionLogs[1].failure_class, "upstream_terminal");
  assert.equal(completionLogs[2].incomplete_reason, "max_output_tokens");
  assert.equal(completionLogs[2].failure_class, "incomplete");
  assert.equal(completionLogs[2].retryable, false);
  assert.equal(completionLogs[3].terminal_error.code, "synthetic_stream_error");
  assert.equal(completionLogs[4].terminal_error.code, "cyber_policy");
  assert.equal(completionLogs[4].failure_class, "policy");
  assert.equal(completionLogs[4].retryable, false);

  const healthBeforeTransportFailure = await request({ port: routerPort, path: "/health" });
  assert.equal(healthBeforeTransportFailure.status, 200);
  assert.deepEqual(JSON.parse(healthBeforeTransportFailure.body).response_outcomes, {
    completed: 1,
    failed: 3,
    incomplete: 1,
    transport_error: 0,
    http_error: 0,
    client_closed: 0,
  });

  const unterminatedBody = JSON.stringify({ model: "gpt-6-astra", stream: true });
  await assert.rejects(
    request({
      port: routerPort,
      path: "/v1/responses",
      method: "POST",
      headers: {
        authorization: "test",
        "chatgpt-account-id": "test",
        "content-type": "application/json",
        "content-length": String(Buffer.byteLength(unterminatedBody)),
        "x-synthetic-terminal": "none",
      },
      body: unterminatedBody,
    }),
  );
  await waitUntil(
    () => routerLogs.some((entry) => entry.error?.code === "UPSTREAM_EARLY_EOF"),
    "unterminated-stream rejection log",
  );
  const healthAfterTransportFailure = await request({ port: routerPort, path: "/health" });
  assert.equal(JSON.parse(healthAfterTransportFailure.body).response_outcomes.transport_error, 1);

  assert.equal(routerStderr, "");
  process.stdout.write("Streaming terminal handling passed.\n");
} finally {
  if (router && router.exitCode === null) {
    router.kill("SIGTERM");
    await new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (router.exitCode === null) router.kill("SIGKILL");
        resolve();
      }, 2000);
      router.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
  await new Promise((resolve) => mockServer.close(resolve));
  fs.rmSync(testDirectory, { recursive: true, force: true });
}
