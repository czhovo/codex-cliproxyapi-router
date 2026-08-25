#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

let [mode, catalogSource, outputPath, officialCatalogSource] = process.argv.slice(2);
if (!new Set(["direct", "forward"]).has(mode)) {
  officialCatalogSource = undefined;
  outputPath = catalogSource;
  catalogSource = mode;
  mode = "forward";
}
if (!catalogSource || !outputPath || (mode === "direct" && !officialCatalogSource)) {
  fail("Usage: build-model-catalog.mjs direct|forward PROXY_CATALOG OUTPUT [OFFICIAL_CATALOG]");
}

async function readCatalog(source, label) {
  try {
    const value = source.startsWith("http://") || source.startsWith("https://")
      ? await fetch(source, { headers: { authorization: "Bearer local-catalog-request" } }).then(async (response) => {
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          return response.json();
        })
      : JSON.parse(fs.readFileSync(source, "utf8"));
    if (!Array.isArray(value.models)) throw new Error("missing models array");
    return value;
  } catch (error) {
    fail(`Unable to read ${label} catalog: ${error.message}`);
  }
}

const proxyCatalog = await readCatalog(catalogSource, "proxy");
let catalog = proxyCatalog;
if (mode === "direct") {
  const officialCatalog = await readCatalog(officialCatalogSource, "official Codex");
  const existingSlugs = new Set(
    officialCatalog.models.map((model) => model?.slug).filter((slug) => typeof slug === "string"),
  );
  const proxyOnlyModels = proxyCatalog.models.filter(
    (model) =>
      model &&
      typeof model.slug === "string" &&
      !model.slug.startsWith("gpt-") &&
      !existingSlugs.has(model.slug),
  );
  catalog = { ...officialCatalog, models: [...officialCatalog.models, ...proxyOnlyModels] };
}

catalog.models = catalog.models.filter(
  (model) => model && typeof model === "object" && typeof model.slug === "string" && model.slug.trim() !== "",
);
if (catalog.models.length === 0) fail("Proxy catalog must contain at least one model.");

const solSlug = "gpt-5.6-sol";
const solLargeSlug = "gpt-5.6-sol-1m";
const solIndex = catalog.models.findIndex((model) => model.slug === solSlug);
if (solIndex !== -1) {
  const source = catalog.models[solIndex];
  const compact = {
    ...source,
    slug: solSlug,
    display_name: "GPT 5.6 Sol · 272k",
    context_window: 272000,
    max_context_window: 272000,
    default_service_tier: "priority",
  };
  const large = {
    ...source,
    slug: solLargeSlug,
    display_name: "GPT 5.6 Sol · 1.05M",
    context_window: 921000,
    max_context_window: 921000,
    effective_context_window_percent: 95,
    auto_compact_token_limit: null,
    default_service_tier: "priority",
  };
  catalog.models = catalog.models.filter((model) => model.slug !== solLargeSlug);
  const currentSolIndex = catalog.models.findIndex((model) => model.slug === solSlug);
  catalog.models.splice(currentSolIndex, 1, compact, large);
}

const deepSeekModels = ["deepseek-v4-flash", "deepseek-v4-pro"].map((slug) =>
  catalog.models.find((model) => model.slug === slug),
);

const visibleModelOrder = [
  "gpt-5.6-sol",
  "gpt-5.6-sol-1m",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "gpt-5.3-codex-spark",
  "deepseek-v4-flash",
  "deepseek-v4-pro",
];
const displayNames = new Map([
  ["gpt-5.6-sol", "GPT 5.6 Sol · 272k"],
  ["gpt-5.6-sol-1m", "GPT 5.6 Sol · 1.05M"],
  ["gpt-5.6-terra", "GPT 5.6 Terra"],
  ["gpt-5.6-luna", "GPT 5.6 Luna"],
  ["gpt-5.3-codex-spark", "GPT 5.3 Codex Spark"],
  ["deepseek-v4-flash", "DeepSeek V4 Flash"],
  ["deepseek-v4-pro", "DeepSeek V4 Pro"],
]);
const modelsBySlug = new Map(catalog.models.map((model) => [model.slug, model]));
catalog.models = visibleModelOrder
  .map((slug) => modelsBySlug.get(slug))
  .filter(Boolean);
if (catalog.models.length === 0) fail("No supported visible model is present in the upstream catalog.");
for (const model of catalog.models) model.display_name = displayNames.get(model.slug);

for (const model of catalog.models) {
  model.prefer_websockets = false;
  if (typeof model.supports_reasoning_summaries !== "boolean") {
    model.supports_reasoning_summaries = true;
  }
  if (
    model.slug.startsWith("gpt-") &&
    (model.service_tiers ?? []).some((tier) => tier?.id === "priority")
  ) {
    model.default_service_tier = "priority";
  }
}

for (const deepSeek of deepSeekModels) {
  if (!deepSeek) continue;
  Object.assign(deepSeek, {
    context_window: 1000000,
    max_context_window: 1000000,
    effective_context_window_percent: 95,
    auto_compact_token_limit: null,
    default_reasoning_level: "high",
    supported_reasoning_levels: [
      { effort: "low", description: "Lower reasoning depth for faster responses" },
      { effort: "high", description: "Standard reasoning depth (default)" },
      { effort: "max", description: "Maximum reasoning depth for the hardest tasks" },
    ],
    default_service_tier: null,
    service_tiers: [],
    additional_speed_tiers: [],
    web_search_tool_type: "text",
  });
}

const temporaryPath = `${outputPath}.tmp-${process.pid}`;
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(temporaryPath, `${JSON.stringify(catalog, null, 2)}\n`, { mode: 0o600 });
fs.chmodSync(temporaryPath, 0o600);
fs.renameSync(temporaryPath, outputPath);
