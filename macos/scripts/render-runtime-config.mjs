#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function readSecret(secretPath, label) {
  let value;
  try {
    value = fs.readFileSync(secretPath, "utf8").trim();
  } catch {
    fail(`${label} is missing: ${secretPath}`);
  }
  if (!value || /[\r\n]/.test(value)) {
    fail(`${label} must contain exactly one non-empty line.`);
  }
  return value;
}

function yamlQuoted(value) {
  return JSON.stringify(value);
}

const [templatePath, outputPath, authDirectory, clientKeyPath, deepSeekKeyPath] = process.argv.slice(2);
if (!templatePath || !outputPath || !authDirectory || !clientKeyPath || !deepSeekKeyPath) {
  fail("Usage: render-runtime-config.mjs TEMPLATE OUTPUT AUTH_DIR CLIENT_KEY DEEPSEEK_KEY");
}

const clientKey = readSecret(clientKeyPath, "CLIProxyAPI client key");
const deepSeekKey = readSecret(deepSeekKeyPath, "DeepSeek API key");
if (!deepSeekKey.startsWith("sk-")) {
  fail("DeepSeek API key must start with sk-.");
}

let template = fs.readFileSync(templatePath, "utf8");
const replacements = new Map([
  ["\"__AUTH_DIR__\"", yamlQuoted(path.resolve(authDirectory))],
  ["\"__LOCAL_PROXY_KEY__\"", yamlQuoted(clientKey)],
  ["\"__DEEPSEEK_API_KEY__\"", yamlQuoted(deepSeekKey)],
]);
for (const [needle, replacement] of replacements) {
  if (!template.includes(needle)) fail(`Runtime template is missing ${needle}.`);
  template = template.replaceAll(needle, replacement);
}
if (!/^\s*disable-codex-cloaking:\s*true\s*$/m.test(template)) {
  fail("Runtime configuration must disable Codex header cloaking.");
}

fs.mkdirSync(path.dirname(outputPath), { recursive: true, mode: 0o700 });
const temporaryPath = `${outputPath}.tmp-${process.pid}`;
fs.writeFileSync(temporaryPath, template, { encoding: "utf8", mode: 0o600 });
fs.chmodSync(temporaryPath, 0o600);
fs.renameSync(temporaryPath, outputPath);
