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
  const supplementalProxyModels = proxyCatalog.models.filter(
    (model) =>
      model &&
      typeof model.slug === "string" &&
      !existingSlugs.has(model.slug),
  );
  catalog = { ...officialCatalog, models: [...officialCatalog.models, ...supplementalProxyModels] };
}

catalog.models = catalog.models.filter(
  (model) => model && typeof model === "object" && typeof model.slug === "string" && model.slug.trim() !== "",
);
if (catalog.models.length === 0) fail("Proxy catalog must contain at least one model.");

// Keep Astra visible in mode 1 when the saved official Codex catalog predates it.
// The upstream uses the real gpt-6-astra model ID.
const astraSlug = "gpt-6-astra";
const astraLargeSlug = "gpt-6-astra-1m";
if (!catalog.models.some((model) => model.slug === astraSlug)) {
  const template = catalog.models.find((model) => model.slug === "gpt-5.6-sol")
    ?? catalog.models.find((model) => model.slug.startsWith("gpt-"));
  if (template) {
    const levels = ["low", "medium", "high", "xhigh", "max", "ultra"];
    catalog.models.push({
      ...structuredClone(template),
      slug: astraSlug,
      display_name: "GPT 6 Astra",
      description: "GPT-6 Astra. Our most capable model for the hardest end-to-end work.",
      default_reasoning_level: "medium",
      supported_reasoning_levels: levels.map((effort) => ({
        effort,
        description: template.supported_reasoning_levels?.find((level) => level.effort === effort)?.description
          ?? (effort === "ultra" ? "Maximum reasoning with automatic task delegation" : effort),
      })),
      // Reserve 128k output tokens plus a 1k margin within the 1.05M total window.
      context_window: 921000,
      max_context_window: 921000,
      effective_context_window_percent: 95,
      auto_compact_token_limit: null,
      visibility: "list",
      upgrade: null,
      availability_nux: null,
      default_service_tier: "default",
      service_tiers: (template.service_tiers ?? []).filter((tier) => tier.id === "priority"),
      additional_speed_tiers: (template.additional_speed_tiers ?? []).filter((tier) => tier === "fast"),
    });
  }
}

const astraIndex = catalog.models.findIndex((model) => model.slug === astraSlug);
if (astraIndex !== -1) {
  const source = catalog.models[astraIndex];
  const supportedReasoningLevels = Array.isArray(source.supported_reasoning_levels)
    ? structuredClone(source.supported_reasoning_levels)
    : [];
  if (!supportedReasoningLevels.some((level) => level?.effort === "ultra")) {
    supportedReasoningLevels.push({
      effort: "ultra",
      description: "Maximum reasoning with automatic task delegation",
    });
  }
  const compact = {
    ...source,
    slug: astraSlug,
    display_name: "GPT 6 Astra · 272k",
    context_window: 272000,
    max_context_window: 272000,
    effective_context_window_percent: 95,
    auto_compact_token_limit: null,
    supported_reasoning_levels: supportedReasoningLevels,
  };
  const large = {
    ...source,
    slug: astraLargeSlug,
    display_name: "GPT 6 Astra · 1.05M",
    // Match the long-context model: reserve 128k output plus a 1k margin.
    context_window: 921000,
    max_context_window: 921000,
    effective_context_window_percent: 95,
    auto_compact_token_limit: null,
    supported_reasoning_levels: structuredClone(supportedReasoningLevels),
  };
  catalog.models = catalog.models.filter((model) => model.slug !== astraLargeSlug);
  const currentAstraIndex = catalog.models.findIndex((model) => model.slug === astraSlug);
  catalog.models.splice(currentAstraIndex, 1, compact, large);
}

const solSlug = "gpt-5.6-sol";
const solLargeSlug = "gpt-5.6-sol-1m";
const solIndex = catalog.models.findIndex((model) => model.slug === solSlug);
if (solIndex !== -1) {
  const source = catalog.models[solIndex];
  catalog.models[solIndex] = {
    ...source,
    slug: solSlug,
    display_name: "GPT 5.6 Sol",
    context_window: 272000,
    max_context_window: 272000,
    default_service_tier: "priority",
  };
}
catalog.models = catalog.models.filter((model) => model.slug !== solLargeSlug);

const deepSeekModels = ["deepseek-v4-flash", "deepseek-v4-pro"].map((slug) =>
  catalog.models.find((model) => model.slug === slug),
);

const visibleModelOrder = [
  "gpt-6-astra",
  "gpt-6-astra-1m",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "deepseek-v4-flash",
  "deepseek-v4-pro",
];
const displayNames = new Map([
  ["gpt-6-astra", "GPT 6 Astra · 272k"],
  ["gpt-6-astra-1m", "GPT 6 Astra · 1.05M"],
  ["gpt-5.6-sol", "GPT 5.6 Sol"],
  ["gpt-5.6-terra", "GPT 5.6 Terra"],
  ["gpt-5.6-luna", "GPT 5.6 Luna"],
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
    model.slug !== astraSlug &&
    model.slug !== astraLargeSlug &&
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
