import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import path from "node:path";
import zlib from "node:zlib";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { StringDecoder } from "node:string_decoder";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const listenHost = "127.0.0.1";
const listenPort = integerEnv(
  "CODEX_COMPAT_PORT",
  integerEnv("CLIPROXY_LISTEN_PORT", 8318, 1, 65535),
  1,
  65535,
);
const proxyHost = "127.0.0.1";
const proxyPort = integerEnv(
  "CLIPROXY_PORT",
  integerEnv("CLIPROXY_UPSTREAM_PORT", 8317, 1, 65535),
  1,
  65535,
);
const requestLimit = 64 * 1024 * 1024;
const errorBodyLimit = 2 * 1024 * 1024;
const officialOrigin = new URL(process.env.CODEX_OFFICIAL_ORIGIN || "https://chatgpt.com");
const officialPath = process.env.CODEX_OFFICIAL_PATH || "/backend-api/codex/responses";
const clientKeyPath = process.env.CLIPROXY_CLIENT_KEY_FILE || path.join(scriptDir, "client-key.txt");
const upstreamClientKey = process.env.CLIPROXY_CLIENT_KEY || fs.readFileSync(clientKeyPath, "utf8").trim();
const routingModePath =
  process.env.CODEX_ROUTING_MODE_FILE ||
  process.env.CLIPROXY_GPT_ROUTING_MODE_FILE ||
  path.join(scriptDir, "routing-mode.txt");

if (!upstreamClientKey) throw new Error("The local CLIProxyAPI client key is empty.");

const agentOptions = {
  keepAlive: true,
  keepAliveMsecs: 1000,
  maxSockets: 32,
  maxFreeSockets: 8,
  scheduling: "lifo",
};
const officialHttpsAgent = new https.Agent(agentOptions);
const localHttpAgent = new http.Agent(agentOptions);
const officialConnectRetryDelaysMs = [250, 750];
const activeUpstreamRequests = new Set();
const modelAliases = new Map([
  ["gpt-5.6-sol-1m", "gpt-5.6-sol"],
]);

function integerEnv(name, fallback, minimum, maximum) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} is outside the supported range.`);
  }
  return value;
}

function readRoutingMode() {
  try {
    const value = fs.readFileSync(routingModePath, "utf8").trim();
    if (value === "1" || value === "direct") return 1;
    if (value === "2" || value === "forward") return 2;
  } catch (error) {
    if (error?.code !== "ENOENT") safeLog({ event: "mode_read_error", error: safeError(error) });
  }
  return 1;
}

function redactText(value, maximum = 512) {
  let text = String(value ?? "");
  text = text
    .replace(/Bearer\s+[^\s"',;]+/gi, "Bearer <redacted>")
    .replace(/\b(?:sk|sess)-[A-Za-z0-9_-]{6,}\b/gi, "<redacted>")
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "<redacted>")
    .replace(/\baccount[-_:][A-Za-z0-9_-]{8,}\b/gi, "<redacted>")
    .replace(/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/gi, "<redacted>")
    .replace(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, "<redacted>")
    .replace(/\b[A-Za-z0-9_-]{32,}\b/g, "<redacted>")
    .replace(/\b(authorization|cookie|x-api-key|chatgpt-account-id)\s*[:=]\s*[^\s,;]+/gi, "$1=<redacted>");
  return text.slice(0, maximum);
}

function safeLog(fields) {
  const record = { timestamp: new Date().toISOString(), ...fields };
  try {
    process.stdout.write(`${JSON.stringify(record)}\n`, () => {});
  } catch {
    // Logging must never terminate the proxy.
  }
}

function safeError(error) {
  return {
    type: redactText(error?.name || "Error", 96),
    code: redactText(error?.code || "", 96),
    message: redactText(error?.message || "upstream request failed", 512),
    param: redactText(error?.param || "", 128),
  };
}

for (const stream of [process.stdout, process.stderr]) stream.on("error", () => {});
process.on("unhandledRejection", (error) => safeLog({ event: "unhandled_rejection", error: safeError(error) }));
process.on("uncaughtException", (error) => safeLog({ event: "uncaught_exception", error: safeError(error) }));

function normalizeReasoningCatalog(payload) {
  if (!payload || !Array.isArray(payload.models)) return payload;
  for (const model of payload.models) {
    if (typeof model.supports_reasoning_summaries !== "boolean") model.supports_reasoning_summaries = true;
  }
  return payload;
}

function deleteHopByHopHeaders(headers) {
  for (const name of [
    "host",
    "connection",
    "proxy-connection",
    "keep-alive",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "expect",
  ]) {
    delete headers[name];
  }
}

function officialHeaders(incoming) {
  const headers = { ...incoming };
  deleteHopByHopHeaders(headers);
  for (const name of ["cookie", "x-api-key", "openai-organization", "openai-project"]) delete headers[name];
  headers["accept-encoding"] = "identity";
  return headers;
}

function proxyHeaders(incoming) {
  const headers = { ...incoming };
  deleteHopByHopHeaders(headers);
  for (const name of [
    "cookie",
    "x-api-key",
    "chatgpt-account-id",
    "openai-organization",
    "openai-project",
  ]) {
    delete headers[name];
  }
  headers.authorization = `Bearer ${upstreamClientKey}`;
  headers["accept-encoding"] = "identity";
  return headers;
}

function responseHeaders(incoming) {
  const headers = { ...incoming };
  deleteHopByHopHeaders(headers);
  return headers;
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let settled = false;
    const cleanup = () => {
      request.off("data", onData);
      request.off("end", onEnd);
      request.off("aborted", onAborted);
      request.off("error", onError);
      request.off("close", onClose);
    };
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      cleanup();
      callback(value);
    };
    const onData = (chunk) => {
      total += chunk.length;
      if (total > requestLimit) {
        const error = Object.assign(new Error("request body exceeds 64 MiB"), { code: "REQUEST_TOO_LARGE" });
        finish(reject, error);
        request.resume();
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => finish(resolve, Buffer.concat(chunks, total));
    const onAborted = () => finish(reject, Object.assign(new Error("client request aborted"), { code: "CLIENT_ABORTED" }));
    const onError = (error) => finish(reject, error);
    const onClose = () => {
      if (!request.complete) onAborted();
    };
    request.on("data", onData);
    request.once("end", onEnd);
    request.once("aborted", onAborted);
    request.once("error", onError);
    request.once("close", onClose);
  });
}

function decodeBody(rawBody, contentEncoding) {
  const encodings = String(contentEncoding || "")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter((value) => value && value !== "identity");
  let decoded = rawBody;
  for (const encoding of encodings.reverse()) {
    const options = { maxOutputLength: requestLimit };
    if (encoding === "gzip" || encoding === "x-gzip") decoded = zlib.gunzipSync(decoded, options);
    else if (encoding === "deflate") decoded = zlib.inflateSync(decoded, options);
    else if (encoding === "br") decoded = zlib.brotliDecompressSync(decoded, options);
    else if (encoding === "zstd") decoded = zlib.zstdDecompressSync(decoded, options);
    else throw Object.assign(new Error("unsupported content encoding"), { code: "UNSUPPORTED_CONTENT_ENCODING" });
  }
  if (decoded.length > requestLimit) {
    throw Object.assign(new Error("decoded request body exceeds 64 MiB"), { code: "REQUEST_TOO_LARGE" });
  }
  return decoded;
}

function encodeBody(decodedBody, contentEncoding) {
  const encodings = String(contentEncoding || "")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter((value) => value && value !== "identity");
  let encoded = decodedBody;
  for (const encoding of encodings) {
    if (encoding === "gzip" || encoding === "x-gzip") encoded = zlib.gzipSync(encoded);
    else if (encoding === "deflate") encoded = zlib.deflateSync(encoded);
    else if (encoding === "br") encoded = zlib.brotliCompressSync(encoded);
    else if (encoding === "zstd") encoded = zlib.zstdCompressSync(encoded);
    else throw Object.assign(new Error("unsupported content encoding"), { code: "UNSUPPORTED_CONTENT_ENCODING" });
    if (encoded.length > requestLimit) {
      throw Object.assign(new Error("encoded request body exceeds 64 MiB"), { code: "REQUEST_TOO_LARGE" });
    }
  }
  return encoded;
}

function rewriteRequestModel(rawBody, contentEncoding, expectedModel, upstreamModel) {
  const decoded = decodeBody(rawBody, contentEncoding);
  const payload = JSON.parse(decoded.toString("utf8"));
  if (payload?.model !== expectedModel) {
    throw Object.assign(new Error("request model changed during alias rewrite"), { code: "MODEL_ALIAS_MISMATCH" });
  }
  payload.model = upstreamModel;
  const rewritten = Buffer.from(JSON.stringify(payload), "utf8");
  if (rewritten.length > requestLimit) {
    throw Object.assign(new Error("rewritten request body exceeds 64 MiB"), { code: "REQUEST_TOO_LARGE" });
  }
  return encodeBody(rewritten, contentEncoding);
}

function extractModel(rawBody, contentEncoding) {
  try {
    const decoded = decodeBody(rawBody, contentEncoding);
    const payload = JSON.parse(decoded.toString("utf8"));
    return typeof payload?.model === "string" ? payload.model.slice(0, 160) : "";
  } catch (error) {
    return { decodeError: safeError(error) };
  }
}

function extractStructuredError(buffer) {
  if (!buffer?.length) return { type: "", code: "", message: "", param: "" };
  const raw = buffer.toString("utf8");
  const candidates = [raw];
  for (const line of raw.split(/\r?\n/)) if (line.startsWith("data:")) candidates.push(line.slice(5).trim());
  for (const candidate of candidates.reverse()) {
    try {
      const parsed = JSON.parse(candidate);
      const source = parsed?.error && typeof parsed.error === "object" ? parsed.error : parsed;
      return {
        type: redactText(source?.type || "", 96),
        code: redactText(source?.code || "", 96),
        message: redactText(source?.message || "", 512),
        param: redactText(source?.param || "", 128),
      };
    } catch {
      // Raw bodies are intentionally never logged.
    }
  }
  return { type: "upstream_error", code: "", message: "non-JSON upstream error", param: "" };
}

function sendJsonError(response, statusCode, code, message) {
  if (response.destroyed || response.writableEnded) return;
  const body = Buffer.from(JSON.stringify({ error: { type: "proxy_error", code, message } }), "utf8");
  try {
    if (!response.headersSent) {
      response.writeHead(statusCode, {
        "content-type": "application/json; charset=utf-8",
        "content-length": String(body.length),
        connection: "close",
      });
    }
    response.end(body);
  } catch {
    response.destroy();
  }
}

class ResponsesCompletionTracker {
  constructor() {
    this.decoder = new StringDecoder("utf8");
    this.lineBuffer = "";
    this.scanBuffer = "";
    this.seen = false;
  }

  push(chunk) {
    if (this.seen) return;
    this.#consume(this.decoder.write(chunk));
  }

  end() {
    if (this.seen) return;
    this.#consume(this.decoder.end());
    if (this.lineBuffer) this.#processLine(this.lineBuffer);
  }

  #consume(text) {
    if (!text || this.seen) return;
    this.scanBuffer = `${this.scanBuffer}${text}`.slice(-256 * 1024);
    if (/(?:^|\n)event:\s*response\.completed\s*(?:\r?\n|$)/m.test(this.scanBuffer) ||
        /"type"\s*:\s*"response\.completed"/.test(this.scanBuffer)) {
      this.seen = true;
      return;
    }
    this.lineBuffer += text;
    let newline;
    while ((newline = this.lineBuffer.indexOf("\n")) >= 0) {
      const line = this.lineBuffer.slice(0, newline).replace(/\r$/, "");
      this.lineBuffer = this.lineBuffer.slice(newline + 1);
      this.#processLine(line);
      if (this.seen) return;
    }
    if (this.lineBuffer.length > 256 * 1024) this.lineBuffer = this.lineBuffer.slice(-256 * 1024);
  }

  #processLine(line) {
    const trimmed = line.trim();
    if (/^event:\s*response\.completed$/i.test(trimmed)) {
      this.seen = true;
      return;
    }
    let json = trimmed;
    if (json.startsWith("data:")) json = json.slice(5).trim();
    if (!json.startsWith("{")) return;
    try {
      if (JSON.parse(json)?.type === "response.completed") this.seen = true;
    } catch {
      // A complete JSON line may arrive in a later chunk.
    }
  }
}

function connectionKind(request) {
  return request?.reusedSocket ? "reused" : "fresh";
}

function forwardStreaming({ request, response, rawBody, route, mode, model, upstreamModel, requestUrl, requestId }) {
  const started = Date.now();
  const isOfficial = route === "official";
  const transport = isOfficial && officialOrigin.protocol === "https:" ? https : http;
  const agent = isOfficial && officialOrigin.protocol === "https:" ? officialHttpsAgent : localHttpAgent;
  const targetPath = isOfficial ? `${officialPath}${requestUrl.search}` : `${requestUrl.pathname}${requestUrl.search}`;
  const outgoingHeaders = isOfficial ? officialHeaders(request.headers) : proxyHeaders(request.headers);
  if (rawBody.length > 0 || request.headers["content-length"] !== undefined) {
    outgoingHeaders["content-length"] = String(rawBody.length);
  }
  const options = isOfficial
    ? {
        protocol: officialOrigin.protocol,
        hostname: officialOrigin.hostname,
        port: officialOrigin.port || undefined,
        method: request.method,
        path: targetPath,
        headers: outgoingHeaders,
        agent,
      }
    : {
        host: proxyHost,
        port: proxyPort,
        method: request.method,
        path: targetPath,
        headers: outgoingHeaders,
        agent: localHttpAgent,
      };

  safeLog({
    event: "route",
    request_id: requestId,
    route,
    mode,
    model,
    ...(upstreamModel && upstreamModel !== model ? { upstream_model: upstreamModel } : {}),
    method: request.method,
    path: requestUrl.pathname,
  });

  let finished = false;
  let clientAttached = true;
  let currentRequest;
  let currentResponse;
  let completionTracker;
  let retryCount = 0;
  let finalConnection = "fresh";

  const finish = (fields) => {
    if (finished) return;
    finished = true;
    safeLog({
      event: "complete",
      request_id: requestId,
      route,
      mode,
      model,
      ...(upstreamModel && upstreamModel !== model ? { upstream_model: upstreamModel } : {}),
      duration_ms: Date.now() - started,
      conn: finalConnection,
      retries: retryCount,
      ...fields,
    });
  };

  const detachCompletedClient = () => {
    if (!clientAttached) return;
    clientAttached = false;
    response.removeAllListeners("drain");
    finish({ status: 200, client_closed_after_completed: true, completed: true });
    if (currentResponse && !currentResponse.destroyed && !currentResponse.readableEnded) currentResponse.resume();
  };

  const handleClientDisconnect = (error) => {
    if (!clientAttached || response.writableEnded) return;
    if (completionTracker?.seen) {
      detachCompletedClient();
      return;
    }
    clientAttached = false;
    currentResponse?.destroy();
    currentRequest?.destroy();
    finish({ status: 499, error: safeError(error || Object.assign(new Error("client closed before completion"), { code: "CLIENT_CLOSED" })) });
  };

  response.once("error", handleClientDisconnect);
  response.once("close", () => {
    if (!response.writableEnded) handleClientDisconnect();
  });

  const handleUpstreamResponse = (upstreamRequest, incomingResponse) => {
    currentResponse = incomingResponse;
    finalConnection = connectionKind(upstreamRequest);
    const statusCode = incomingResponse.statusCode || 502;
    const expectsCompletion =
      request.method === "POST" && requestUrl.pathname === "/v1/responses" && statusCode >= 200 && statusCode < 300;
    completionTracker = expectsCompletion ? new ResponsesCompletionTracker() : undefined;
    const capturedErrorChunks = [];
    let capturedErrorBytes = 0;
    let upstreamSettled = false;
    let waitingForDrain = false;

    const endClient = () => {
      if (!clientAttached || response.destroyed || response.writableEnded) return;
      try {
        response.end();
      } catch (error) {
        handleClientDisconnect(error);
      }
    };

    const failUpstreamStream = (error) => {
      if (upstreamSettled) return;
      upstreamSettled = true;
      if (completionTracker?.seen) {
        endClient();
        finish({ status: statusCode, completed: true, upstream_closed_after_completed: true });
        return;
      }
      finish({ status: 502, error: safeError(error) });
      if (clientAttached && !response.destroyed) response.destroy();
    };

    if (!clientAttached) {
      if (completionTracker?.seen) incomingResponse.resume();
      else incomingResponse.destroy();
      return;
    }
    try {
      if (!response.headersSent) response.writeHead(statusCode, responseHeaders(incomingResponse.headers));
    } catch (error) {
      handleClientDisconnect(error);
      return;
    }

    incomingResponse.on("data", (chunk) => {
      if (statusCode < 200 || statusCode >= 300) {
        const remaining = errorBodyLimit - capturedErrorBytes;
        if (remaining > 0) {
          const captured = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
          capturedErrorChunks.push(captured);
          capturedErrorBytes += captured.length;
        }
      }
      completionTracker?.push(chunk);
      if (!clientAttached) return;
      try {
        if (!response.write(chunk) && !waitingForDrain) {
          waitingForDrain = true;
          incomingResponse.pause();
          response.once("drain", () => {
            waitingForDrain = false;
            if (clientAttached && !incomingResponse.destroyed && !incomingResponse.readableEnded) incomingResponse.resume();
          });
        }
      } catch (error) {
        handleClientDisconnect(error);
      }
    });

    incomingResponse.once("end", () => {
      if (upstreamSettled) return;
      upstreamSettled = true;
      completionTracker?.end();
      if (statusCode < 200 || statusCode >= 300) {
        endClient();
        finish({
          status: clientAttached ? statusCode : 499,
          error: extractStructuredError(Buffer.concat(capturedErrorChunks, capturedErrorBytes)),
        });
        return;
      }
      if (expectsCompletion && !completionTracker.seen) {
        finish({
          status: 502,
          error: safeError(Object.assign(new Error("upstream ended before response.completed"), { code: "UPSTREAM_EARLY_EOF" })),
        });
        if (clientAttached && !response.destroyed) response.destroy();
        return;
      }
      endClient();
      finish({ status: statusCode, completed: expectsCompletion ? true : undefined });
    });

    incomingResponse.once("aborted", () => {
      failUpstreamStream(Object.assign(new Error("upstream response aborted"), { code: "UPSTREAM_ABORTED" }));
    });
    incomingResponse.once("error", (error) => failUpstreamStream(error));
    incomingResponse.once("close", () => {
      if (!upstreamSettled && !incomingResponse.complete) {
        failUpstreamStream(Object.assign(new Error("upstream response closed early"), { code: "UPSTREAM_EARLY_CLOSE" }));
      }
    });
  };

  const startAttempt = (attempt) => {
    if (!clientAttached) return;
    let receivedHeaders = false;
    const upstreamRequest = transport.request(options);
    currentRequest = upstreamRequest;
    activeUpstreamRequests.add(upstreamRequest);
    upstreamRequest.once("close", () => activeUpstreamRequests.delete(upstreamRequest));
    upstreamRequest.setTimeout(10 * 60 * 1000, () => {
      upstreamRequest.destroy(Object.assign(new Error("upstream timeout"), { code: "UPSTREAM_TIMEOUT" }));
    });
    upstreamRequest.once("response", (incomingResponse) => {
      receivedHeaders = true;
      handleUpstreamResponse(upstreamRequest, incomingResponse);
    });
    upstreamRequest.once("error", (error) => {
      const conn = connectionKind(upstreamRequest);
      finalConnection = conn;
      const staleKeepAliveReset =
        isOfficial &&
        attempt === 0 &&
        !receivedHeaders &&
        upstreamRequest.reusedSocket === true &&
        error?.code === "ECONNRESET";
      const tlsPreHandshakeReset =
        isOfficial &&
        !receivedHeaders &&
        error?.code === "ECONNRESET" &&
        /before secure TLS connection was established/i.test(String(error?.message || ""));
      const retryReason = staleKeepAliveReset
        ? "stale_keepalive_reset"
        : tlsPreHandshakeReset
          ? "tls_prehandshake_reset"
          : "";
      if (clientAttached && retryReason && attempt < officialConnectRetryDelaysMs.length) {
        const delayMs = officialConnectRetryDelaysMs[attempt];
        retryCount += 1;
        safeLog({
          event: "retry",
          request_id: requestId,
          route,
          model,
          conn,
          reason: retryReason,
          attempt: retryCount,
          delay_ms: delayMs,
        });
        setTimeout(() => {
          if (clientAttached) startAttempt(attempt + 1);
        }, delayMs);
        return;
      }
      if (clientAttached && !response.headersSent) {
        sendJsonError(response, 502, "upstream_unavailable", "Upstream service unavailable");
      } else if (clientAttached && !response.destroyed) {
        finish({ status: 502, error: safeError(error) });
        response.destroy();
        return;
      }
      finish({ status: clientAttached ? 502 : 499, error: safeError(error) });
    });
    upstreamRequest.end(rawBody);
  };

  startAttempt(0);
}

function forwardCatalog(request, response, requestUrl, requestId) {
  const started = Date.now();
  const upstreamRequest = http.request({
    host: proxyHost,
    port: proxyPort,
    method: "GET",
    path: `${requestUrl.pathname}${requestUrl.search}`,
    headers: proxyHeaders(request.headers),
    agent: localHttpAgent,
  });
  activeUpstreamRequests.add(upstreamRequest);
  upstreamRequest.once("close", () => activeUpstreamRequests.delete(upstreamRequest));
  let completed = false;
  let clientClosed = false;
  const finish = (fields) => {
    if (completed) return;
    completed = true;
    safeLog({
      event: "complete",
      request_id: requestId,
      route: "catalog",
      duration_ms: Date.now() - started,
      conn: connectionKind(upstreamRequest),
      ...fields,
    });
  };
  safeLog({ event: "route", request_id: requestId, route: "catalog", method: "GET", path: requestUrl.pathname });
  upstreamRequest.once("error", (error) => {
    if (!clientClosed) sendJsonError(response, 502, "catalog_unavailable", "Model catalog unavailable");
    finish({ status: clientClosed ? 499 : 502, error: safeError(error) });
  });
  response.once("error", (error) => {
    clientClosed = true;
    upstreamRequest.destroy();
    finish({ status: 499, error: safeError(error) });
  });
  response.once("close", () => {
    if (!response.writableEnded) {
      clientClosed = true;
      upstreamRequest.destroy();
      finish({ status: 499, error: safeError(Object.assign(new Error("catalog client closed"), { code: "CLIENT_CLOSED" })) });
    }
  });
  upstreamRequest.once("response", (incomingResponse) => {
    const chunks = [];
    let total = 0;
    let settled = false;
    const fail = (error) => {
      if (settled) return;
      settled = true;
      if (!clientClosed) sendJsonError(response, 502, "catalog_aborted", "Model catalog unavailable");
      finish({ status: clientClosed ? 499 : 502, error: safeError(error) });
    };
    incomingResponse.on("data", (chunk) => {
      total += chunk.length;
      if (total > requestLimit) {
        incomingResponse.destroy(Object.assign(new Error("catalog exceeds limit"), { code: "CATALOG_TOO_LARGE" }));
      } else {
        chunks.push(chunk);
      }
    });
    incomingResponse.once("aborted", () => fail(Object.assign(new Error("catalog response aborted"), { code: "CATALOG_ABORTED" })));
    incomingResponse.once("error", fail);
    incomingResponse.once("end", () => {
      if (settled) return;
      settled = true;
      const statusCode = incomingResponse.statusCode || 502;
      const raw = Buffer.concat(chunks, total);
      if (statusCode < 200 || statusCode >= 300) {
        if (!clientClosed) {
          if (!response.headersSent) response.writeHead(statusCode, responseHeaders(incomingResponse.headers));
          response.end(raw);
        }
        finish({ status: clientClosed ? 499 : statusCode, error: extractStructuredError(raw.subarray(0, errorBodyLimit)) });
        return;
      }
      try {
        const decoded = decodeBody(raw, incomingResponse.headers["content-encoding"]);
        const normalized = normalizeReasoningCatalog(JSON.parse(decoded.toString("utf8")));
        const body = Buffer.from(JSON.stringify(normalized), "utf8");
        if (!clientClosed) {
          response.writeHead(statusCode, {
            "content-type": "application/json; charset=utf-8",
            "content-length": String(body.length),
          });
          response.end(body);
        }
        finish({ status: clientClosed ? 499 : statusCode });
      } catch (error) {
        if (!clientClosed) sendJsonError(response, 502, "catalog_invalid", "Model catalog was invalid");
        finish({ status: clientClosed ? 499 : 502, error: safeError(error) });
      }
    });
  });
  upstreamRequest.end();
}

function authorizedShutdown(request) {
  const remote = request.socket.remoteAddress;
  if (remote !== "127.0.0.1" && remote !== "::1" && remote !== "::ffff:127.0.0.1") return false;
  const supplied = String(request.headers.authorization || "").replace(/^Bearer\s+/i, "");
  const expected = Buffer.from(upstreamClientKey);
  const candidate = Buffer.from(supplied);
  return expected.length === candidate.length && timingSafeEqual(expected, candidate);
}

let shuttingDown = false;
let shutdownTimer;
function destroyAgents() {
  officialHttpsAgent.destroy();
  localHttpAgent.destroy();
}

function beginShutdown(reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  safeLog({ event: "shutdown_started", reason });
  server.close(() => {
    if (shutdownTimer) clearTimeout(shutdownTimer);
    destroyAgents();
    safeLog({ event: "shutdown_complete", reason });
  });
  shutdownTimer = setTimeout(() => {
    for (const upstreamRequest of activeUpstreamRequests) upstreamRequest.destroy();
    server.closeAllConnections?.();
    destroyAgents();
    safeLog({ event: "shutdown_forced", reason, active_requests: activeUpstreamRequests.size });
  }, 10_000);
  shutdownTimer.unref();
}

const server = http.createServer(async (request, response) => {
  const requestId = randomUUID();
  request.on("error", () => {});
  const requestUrl = new URL(request.url || "/", `http://${listenHost}:${listenPort}`);

  if (request.method === "POST" && requestUrl.pathname === "/__cliproxy_internal/shutdown") {
    if (!authorizedShutdown(request)) {
      sendJsonError(response, 403, "forbidden", "Forbidden");
      return;
    }
    response.writeHead(202, { "content-type": "application/json", connection: "close" });
    response.end('{"status":"shutting_down"}');
    setImmediate(() => beginShutdown("internal"));
    return;
  }

  if (request.method === "GET" && requestUrl.pathname === "/health") {
    const mode = readRoutingMode();
    const body = Buffer.from(
      JSON.stringify({
        status: shuttingDown ? "shutting_down" : "ok",
        mode,
        gpt_routing_mode: mode === 1 ? "direct" : "forward",
        routing: mode === 1 ? "gpt-official-deepseek-cliproxy" : "all-cliproxy",
        active_requests: activeUpstreamRequests.size,
      }),
      "utf8",
    );
    response.writeHead(shuttingDown ? 503 : 200, {
      "content-type": "application/json; charset=utf-8",
      "content-length": String(body.length),
      "cache-control": "no-store",
    });
    response.end(body);
    return;
  }

  const isCodexCatalog =
    request.method === "GET" && requestUrl.pathname === "/v1/models" && requestUrl.searchParams.has("client_version");
  if (isCodexCatalog) {
    forwardCatalog(request, response, requestUrl, requestId);
    return;
  }

  let rawBody;
  try {
    rawBody = await readRequestBody(request);
  } catch (error) {
    const status = error?.code === "REQUEST_TOO_LARGE" ? 413 : 499;
    if (status === 413) sendJsonError(response, 413, "request_too_large", "Request body exceeds 64 MiB");
    safeLog({ event: "request_error", request_id: requestId, route: "none", status, error: safeError(error) });
    return;
  }

  let model = "";
  let decodeError;
  if (request.method === "POST" && requestUrl.pathname === "/v1/responses") {
    const extracted = extractModel(rawBody, request.headers["content-encoding"]);
    if (typeof extracted === "string") model = extracted;
    else decodeError = extracted.decodeError;
  }

  const hasNativeAuthorization = typeof request.headers.authorization === "string" && request.headers.authorization.trim().length > 0;
  const hasNativeAccount =
    typeof request.headers["chatgpt-account-id"] === "string" && request.headers["chatgpt-account-id"].trim().length > 0;
  const mode = readRoutingMode();
  const isResponses = request.method === "POST" && requestUrl.pathname === "/v1/responses";
  const isGpt = isResponses && model.startsWith("gpt-");
  if (mode === 1 && isGpt && (!hasNativeAuthorization || !hasNativeAccount)) {
    sendJsonError(
      response,
      401,
      "native_codex_auth_required",
      "Mode 1 requires Codex App Authorization and chatgpt-account-id headers for GPT requests",
    );
    safeLog({ event: "route_rejected", request_id: requestId, route: "official", mode, model, status: 401 });
    return;
  }
  const official =
    mode === 1 &&
    isGpt &&
    hasNativeAuthorization &&
    hasNativeAccount;
  const route = official ? "official" : "cliproxy";
  if (decodeError) safeLog({ event: "decode_fallback", request_id: requestId, route, error: decodeError });
  let upstreamModel = model;
  if (modelAliases.has(model)) {
    upstreamModel = modelAliases.get(model);
    try {
      rawBody = rewriteRequestModel(rawBody, request.headers["content-encoding"], model, upstreamModel);
    } catch (error) {
      const status = error?.code === "REQUEST_TOO_LARGE" ? 413 : 400;
      sendJsonError(response, status, "model_alias_rewrite_failed", "The selected model request could not be prepared");
      safeLog({ event: "alias_rewrite_error", request_id: requestId, route, model, status, error: safeError(error) });
      return;
    }
  }
  forwardStreaming({ request, response, rawBody, route, mode, model, upstreamModel, requestUrl, requestId });
});

server.on("connection", (socket) => socket.on("error", () => {}));
server.on("clientError", (_error, socket) => {
  if (!socket.destroyed) socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
});
server.on("upgrade", (_request, socket) => {
  socket.on("error", () => {});
  socket.end(
    "HTTP/1.1 426 Upgrade Required\r\n" +
      "Connection: close\r\n" +
      "Content-Type: text/plain; charset=utf-8\r\n" +
      "Content-Length: 41\r\n" +
      "\r\n" +
      "Responses WebSocket transport unsupported",
  );
});
server.on("error", (error) => safeLog({ event: "server_error", error: safeError(error) }));
server.listen(listenPort, listenHost, () => {
  safeLog({
    event: "ready",
    listen: `${listenHost}:${listenPort}`,
    proxy: `${proxyHost}:${proxyPort}`,
    mode: readRoutingMode(),
    keep_alive: { keepAliveMsecs: 1000, maxSockets: 32, maxFreeSockets: 8, scheduling: "lifo" },
    official_connect_retry: { max_retries: officialConnectRetryDelaysMs.length, delays_ms: officialConnectRetryDelaysMs },
  });
});

process.once("SIGTERM", () => beginShutdown("SIGTERM"));
process.once("SIGINT", () => beginShutdown("SIGINT"));
