#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

const [mode, configPath, catalogPath, stateDirectory] = process.argv.slice(2);
if (!new Set(["enable", "reset"]).has(mode) || !configPath || !catalogPath || !stateDirectory) {
  fail("Usage: update-codex-config.mjs enable|reset CONFIG CATALOG STATE_DIR");
}

const existing = fs.existsSync(configPath) ? fs.readFileSync(configPath, "utf8") : "";
const existingSetting = (name) => {
  const match = existing.match(new RegExp(`^\\s*${name}\\s*=\\s*"([^"]*)"\\s*(?:#.*)?$`, "m"));
  return match?.[1] ?? "";
};
fs.mkdirSync(path.join(stateDirectory, "backups"), { recursive: true, mode: 0o700 });
const stamp = new Date().toISOString().replaceAll(":", "").replaceAll("-", "").replace(".", "");
const backupPath = path.join(stateDirectory, "backups", `config-before-${mode}-${stamp}.toml`);
fs.writeFileSync(backupPath, existing, { mode: 0o600 });
fs.chmodSync(backupPath, 0o600);

const controlledKeys = new Set([
  "model",
  "model_provider",
  "model_reasoning_effort",
  "service_tier",
  "openai_base_url",
  "model_catalog_json",
]);

const lines = existing.replace(/^\uFEFF/, "").split(/\r?\n/);
const firstTableIndex = lines.findIndex((line) => /^\s*\[\[?[^\]]+\]\]?\s*(?:#.*)?$/.test(line));
const splitIndex = firstTableIndex === -1 ? lines.length : firstTableIndex;
const preamble = lines.slice(0, splitIndex).filter((line) => {
  const match = line.match(/^\s*([A-Za-z0-9_-]+)\s*=/);
  return !match || !controlledKeys.has(match[1]);
});
const tables = lines.slice(splitIndex);

while (preamble.length > 0 && preamble[0].trim() === "") preamble.shift();
while (preamble.length > 0 && preamble.at(-1).trim() === "") preamble.pop();

const topLevel = [];
if (mode === "enable") {
  let catalog;
  try {
    catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  } catch (error) {
    fail(`Unable to read proxy model catalog: ${error.message}`);
  }
  const models = Array.isArray(catalog.models)
    ? catalog.models.filter((model) => model && typeof model.slug === "string" && model.slug.trim() !== "")
    : [];
  if (models.length === 0) fail("Proxy catalog must contain at least one valid model.");

  const selectedModel = models.find((model) => model.slug === existingSetting("model")) ?? models[0];
  const efforts = new Set(
    (selectedModel.supported_reasoning_levels ?? [])
      .map((level) => level?.effort)
      .filter((effort) => typeof effort === "string" && effort !== ""),
  );
  const configuredEffort = existingSetting("model_reasoning_effort");
  const selectedEffort = efforts.has(configuredEffort)
    ? configuredEffort
    : efforts.has(selectedModel.default_reasoning_level)
      ? selectedModel.default_reasoning_level
      : [...efforts][0];
  const supportedServiceTiers = new Set(
    (selectedModel.service_tiers ?? [])
      .flatMap((tier) => [tier?.id, tier?.name])
      .filter((tier) => typeof tier === "string" && tier !== ""),
  );
  const configuredServiceTier = existingSetting("service_tier");
  const selectedServiceTier = supportedServiceTiers.has(configuredServiceTier)
    ? configuredServiceTier
    : supportedServiceTiers.has(selectedModel.default_service_tier)
      ? selectedModel.default_service_tier
      : supportedServiceTiers.has("priority")
        ? "priority"
        : "";

  topLevel.push(`model = ${JSON.stringify(selectedModel.slug)}`);
  if (selectedEffort) topLevel.push(`model_reasoning_effort = ${JSON.stringify(selectedEffort)}`);
  topLevel.push('model_provider = "openai"');
  if (selectedServiceTier) topLevel.push(`service_tier = ${JSON.stringify(selectedServiceTier)}`);
  topLevel.push('openai_base_url = "http://127.0.0.1:8318/v1"');
  topLevel.push(`model_catalog_json = ${JSON.stringify(path.resolve(catalogPath))}`);
} else {
  let officialCatalog;
  try {
    officialCatalog = JSON.parse(fs.readFileSync(path.join(stateDirectory, "openai-models.json"), "utf8"));
  } catch (error) {
    fail(`Unable to read official Codex model catalog: ${error.message}`);
  }
  const officialModels = Array.isArray(officialCatalog.models)
    ? officialCatalog.models.filter((model) => model && typeof model.slug === "string" && model.slug.trim() !== "")
    : [];
  if (officialModels.length === 0) fail("Official Codex model catalog must contain at least one valid model.");

  const configuredModel = existingSetting("model") === "gpt-5.6-sol-1m"
    ? "gpt-5.6-sol"
    : existingSetting("model");
  const selectedModel = officialModels.find((model) => model.slug === configuredModel) ?? officialModels[0];
  const supportedEfforts = new Set(
    (selectedModel.supported_reasoning_levels ?? [])
      .map((level) => level?.effort)
      .filter((effort) => typeof effort === "string" && effort !== ""),
  );
  const configuredEffort = existingSetting("model_reasoning_effort");
  const selectedEffort = supportedEfforts.has(configuredEffort)
    ? configuredEffort
    : supportedEfforts.has(selectedModel.default_reasoning_level)
      ? selectedModel.default_reasoning_level
      : [...supportedEfforts][0];
  const supportedServiceTiers = new Set(
    (selectedModel.service_tiers ?? [])
      .flatMap((tier) => [tier?.id, tier?.name])
      .filter((tier) => typeof tier === "string" && tier !== ""),
  );
  const configuredServiceTier = existingSetting("service_tier");
  const selectedServiceTier = supportedServiceTiers.has(configuredServiceTier)
    ? configuredServiceTier
    : supportedServiceTiers.has(selectedModel.default_service_tier)
      ? selectedModel.default_service_tier
      : supportedServiceTiers.has("priority")
        ? "priority"
        : "";

  topLevel.push(`model = ${JSON.stringify(selectedModel.slug)}`);
  if (selectedEffort) topLevel.push(`model_reasoning_effort = ${JSON.stringify(selectedEffort)}`);
  topLevel.push('model_provider = "openai"');
  if (selectedServiceTier) topLevel.push(`service_tier = ${JSON.stringify(selectedServiceTier)}`);
}

const resultLines = [...topLevel];
if (preamble.length > 0) resultLines.push("", ...preamble);
if (tables.length > 0 && tables.some((line) => line !== "")) resultLines.push("", ...tables);
while (resultLines.length > 0 && resultLines.at(-1) === "") resultLines.pop();
const result = `${resultLines.join("\n")}\n`;

const temporaryPath = `${configPath}.tmp-${process.pid}`;
fs.writeFileSync(temporaryPath, result, { mode: 0o600 });
fs.chmodSync(temporaryPath, 0o600);
fs.renameSync(temporaryPath, configPath);
process.stdout.write(`${backupPath}\n`);
