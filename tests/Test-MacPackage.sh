#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
node_path="$(command -v node || true)"
[[ -n "$node_path" ]] || { print -u2 -- "Node.js was not found on PATH."; exit 1; }

required_files=(
  src/codex-catalog-compat.mjs
  config/config.template.yaml
  macos/Install-CLIProxyAPIRouter.sh
  macos/scripts/build-model-catalog.mjs
  macos/scripts/update-codex-config.mjs
  macos/scripts/render-runtime-config.mjs
  macos/scripts/cliproxy-common.sh
  macos/scripts/enable-cliproxy
  macos/scripts/reset-codex
  macos/scripts/restart-codex-app.sh
  macos/scripts/login-codex-oauth
  macos/launchers/enable-cliproxy.command
  macos/launchers/reset-codex.command
)
for relative_path in $required_files; do
  [[ -f "$repository_root/$relative_path" ]] || { print -u2 -- "Missing package file: $relative_path"; exit 1; }
done

for script in \
  "$repository_root/src/codex-catalog-compat.mjs" \
  "$repository_root/macos/scripts/build-model-catalog.mjs" \
  "$repository_root/macos/scripts/update-codex-config.mjs" \
  "$repository_root/macos/scripts/render-runtime-config.mjs"; do
  "$node_path" --check "$script"
done
zsh -n \
  "$repository_root/macos/Install-CLIProxyAPIRouter.sh" \
  "$repository_root/macos/scripts/cliproxy-common.sh" \
  "$repository_root/macos/scripts/enable-cliproxy" \
  "$repository_root/macos/scripts/reset-codex" \
  "$repository_root/macos/scripts/restart-codex-app.sh" \
  "$repository_root/macos/scripts/login-codex-oauth" \
  "$repository_root/macos/launchers/enable-cliproxy.command" \
  "$repository_root/macos/launchers/reset-codex.command"

template="$repository_root/config/config.template.yaml"
for placeholder in __AUTH_DIR__ __LOCAL_PROXY_KEY__ __DEEPSEEK_API_KEY__; do
  /usr/bin/grep -Fq "$placeholder" "$template" || { print -u2 -- "Missing placeholder: $placeholder"; exit 1; }
done
/usr/bin/grep -Eq '^host: "127\.0\.0\.1"$' "$template"
/usr/bin/grep -Eq '^  disable-codex-cloaking: true$' "$template"
/usr/bin/grep -Eq '^cliproxy_ready_timeout_seconds=120$' \
  "$repository_root/macos/scripts/cliproxy-common.sh"
/usr/bin/grep -Fq '/usr/bin/codesign --force --sign - --timestamp=none "$installed_binary"' \
  "$repository_root/macos/Install-CLIProxyAPIRouter.sh"
/usr/bin/grep -Fq '/usr/bin/codesign --verify --strict "$installed_binary"' \
  "$repository_root/macos/Install-CLIProxyAPIRouter.sh"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-cliproxyapi-test.XXXXXX")"
cleanup() {
  if [[ -n "$test_dir" && -d "$test_dir" && "${test_dir:t}" == codex-cliproxyapi-test.* ]]; then
    rm -rf -- "$test_dir"
  fi
}
trap cleanup EXIT

"$node_path" - "$test_dir/source.json" <<'NODE'
const fs = require("node:fs");
const path = process.argv[2];
const reasoning = ["low", "medium", "high", "xhigh", "max", "ultra"].map((effort) => ({ effort }));
const priority = [{ id: "priority", name: "Fast" }];
const models = [
  { slug: "gpt-5.6-sol", display_name: "Sol", context_window: 272000, supported_reasoning_levels: reasoning, service_tiers: priority },
  { slug: "gpt-5.6-terra", display_name: "Terra", supported_reasoning_levels: reasoning, service_tiers: priority },
  { slug: "gpt-5.6-luna", display_name: "Luna", supported_reasoning_levels: reasoning, service_tiers: priority },
  { slug: "gpt-5.3-codex-spark", display_name: "Spark", supported_reasoning_levels: reasoning, service_tiers: priority },
  { slug: "gpt-5.5", display_name: "Hidden" },
  { slug: "codex-auto-review", display_name: "Hidden" },
  { slug: "deepseek-v4-flash", display_name: "Flash" },
  { slug: "deepseek-v4-pro", display_name: "Pro" },
];
fs.writeFileSync(path, JSON.stringify({ models }), "utf8");
NODE

"$node_path" "$repository_root/macos/scripts/build-model-catalog.mjs" \
  forward "$test_dir/source.json" "$test_dir/catalog.json"
"$node_path" - "$test_dir/catalog.json" <<'NODE'
const fs = require("node:fs");
const catalog = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = [
  ["gpt-5.6-sol", "GPT 5.6 Sol · 272k"],
  ["gpt-5.6-sol-1m", "GPT 5.6 Sol · 1.05M"],
  ["gpt-5.6-terra", "GPT 5.6 Terra"],
  ["gpt-5.6-luna", "GPT 5.6 Luna"],
  ["gpt-5.3-codex-spark", "GPT 5.3 Codex Spark"],
  ["deepseek-v4-flash", "DeepSeek V4 Flash"],
  ["deepseek-v4-pro", "DeepSeek V4 Pro"],
];
const actual = catalog.models.map(({ slug, display_name }) => [slug, display_name]);
if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error("macOS model picker list mismatch");
const shortSol = catalog.models.find((model) => model.slug === "gpt-5.6-sol");
const longSol = catalog.models.find((model) => model.slug === "gpt-5.6-sol-1m");
if (shortSol.context_window !== 272000 || shortSol.max_context_window !== 272000) throw new Error("272k Sol mismatch");
if (longSol.context_window !== 921000 || longSol.max_context_window !== 921000) throw new Error("1.05M Sol mismatch");
for (const slug of ["deepseek-v4-flash", "deepseek-v4-pro"]) {
  const model = catalog.models.find((entry) => entry.slug === slug);
  if (model.default_reasoning_level !== "high") throw new Error(`${slug} default reasoning mismatch`);
  if (model.supported_reasoning_levels.map((level) => level.effort).join(",") !== "low,high,max") {
    throw new Error(`${slug} reasoning levels mismatch`);
  }
  if (model.service_tiers.length !== 0 || model.additional_speed_tiers.length !== 0) {
    throw new Error(`${slug} must not expose speed tiers`);
  }
}
NODE

"$node_path" - "$test_dir/no-sol.json" <<'NODE'
require("node:fs").writeFileSync(
  process.argv[2],
  JSON.stringify({ models: [{ slug: "gpt-5.6-luna", display_name: "Luna", service_tiers: [{ id: "priority" }] }] }),
  "utf8",
);
NODE
"$node_path" "$repository_root/macos/scripts/build-model-catalog.mjs" \
  forward "$test_dir/no-sol.json" "$test_dir/no-sol-catalog.json"
"$node_path" - "$test_dir/no-sol-catalog.json" <<'NODE'
const models = JSON.parse(require("node:fs").readFileSync(process.argv[2], "utf8")).models;
if (models.length !== 1 || models[0].slug !== "gpt-5.6-luna") throw new Error("catalog must remain dynamic without Sol");
NODE

"$node_path" - "$repository_root" <<'NODE'
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const files = execFileSync("git", ["-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
  .toString("utf8")
  .split("\0")
  .filter(Boolean);
const patterns = [
  ["concrete macOS profile", new RegExp("/" + "Users/[^/<$\\s\\\"']+")],
  ["concrete Windows profile", new RegExp("C:\\\\" + "Users\\\\[^<%$\\s\\\"']+", "i")],
  ["email address", /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i],
  ["private key", /-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/],
  ["GitHub token", new RegExp("\\bgh" + "[pousr]_[A-Za-z0-9]{20,}\\b")],
  ["API key", new RegExp("\\b" + "sk-[A-Za-z0-9_-]{16,}\\b")],
  ["JWT", /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/],
  ["local proxy key", new RegExp("\\bcodex-" + "local-[A-Za-z0-9_-]{12,}\\b")],
];
const assignedSecrets = [
  ["OAuth token assignment", new RegExp("(?:access|refresh|id|oauth)[_-]?" + "token\\s*[:=]\\s*[\\\"']([^\\\"'\\r\\n]{12,})[\\\"']", "ig")],
  ["client secret assignment", new RegExp("client[_-]?" + "secret\\s*[:=]\\s*[\\\"']([^\\\"'\\r\\n]{12,})[\\\"']", "ig")],
  ["API key assignment", new RegExp("(?:api[_-]?" + "key|apikey)\\s*[:=]\\s*[\\\"']([^\\\"'\\r\\n]{12,})[\\\"']", "ig")],
  ["Bearer credential", new RegExp("\\bBearer\\s+" + "([A-Za-z0-9._~+/=-]{12,})", "ig")],
];
function isPlaceholder(value) {
  const normalized = value.trim().toLowerCase();
  return (
    normalized === "local-catalog-request" ||
    normalized.includes("redacted") ||
    normalized.includes("placeholder") ||
    normalized.includes("example") ||
    normalized.includes("dummy") ||
    normalized.includes("change-me") ||
    normalized.startsWith("__") ||
    value.includes("\\\\") ||
    /[$%<>[\]{}()]/.test(value)
  );
}
const findings = [];
for (const relative of files) {
  const buffer = fs.readFileSync(path.join(root, relative));
  if (buffer.includes(0)) continue;
  const text = buffer.toString("utf8");
  for (const [label, pattern] of patterns) if (pattern.test(text)) findings.push(`${label}: ${relative}`);
  for (const [label, pattern] of assignedSecrets) {
    pattern.lastIndex = 0;
    for (const match of text.matchAll(pattern)) {
      if (!isPlaceholder(match[1])) findings.push(`${label}: ${relative}`);
    }
  }
}
if (findings.length) throw new Error(`Potential secret or machine-specific value:\n${findings.join("\n")}`);
NODE

print -- "macOS package validation passed: syntax, placeholders, exact picker list, dynamic absence handling, and OAuth/API-key scan."
