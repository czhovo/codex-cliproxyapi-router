#!/bin/zsh

set -euo pipefail

cliproxy_user_dir="${HOME:?HOME is required}"
cliproxy_codex_dir="$cliproxy_user_dir/.codex"
cliproxy_tools_dir="$cliproxy_codex_dir/tools/cliproxyapi"
cliproxy_state_dir="$cliproxy_codex_dir/cliproxy-state"
cliproxy_auth_root="$cliproxy_user_dir/.cli-proxy-api"
cliproxy_auth_dir="$cliproxy_auth_root/auth"
cliproxy_runtime_config="$cliproxy_auth_root/config.yaml"
cliproxy_key_file="$cliproxy_codex_dir/deepseek_api_key.txt"
cliproxy_client_key_file="$cliproxy_state_dir/client-api-key"
cliproxy_routing_mode_file="$cliproxy_state_dir/gpt-routing-mode"
cliproxy_catalog="$cliproxy_codex_dir/cliproxy-model-catalog.json"
cliproxy_official_catalog="$cliproxy_state_dir/openai-models.json"
cliproxy_codex_config="$cliproxy_codex_dir/config.toml"
cliproxy_binary="$cliproxy_tools_dir/bin/cli-proxy-api"
cliproxy_node="${CLIPROXY_NODE_PATH:-$(command -v node || true)}"
cliproxy_codex_binary="${CODEX_BINARY_PATH:-/Applications/ChatGPT.app/Contents/Resources/codex}"
cliproxy_launch_dir="$cliproxy_user_dir/Library/LaunchAgents"
cliproxy_api_label="com.codex.cliproxyapi-router.proxy"
cliproxy_compat_label="com.codex.cliproxyapi-router.compat"
cliproxy_api_plist="$cliproxy_launch_dir/$cliproxy_api_label.plist"
cliproxy_compat_plist="$cliproxy_launch_dir/$cliproxy_compat_label.plist"
cliproxy_domain="gui/$(id -u)"
cliproxy_compat_reload_marker="$cliproxy_state_dir/compat-reload-required"
cliproxy_ready_timeout_seconds=120

cliproxy_die() {
  print -u2 -- "ERROR: $*"
  exit 1
}

cliproxy_wait_http() {
  local url="$1"
  local timeout_seconds="${2:-$cliproxy_ready_timeout_seconds}"
  local label="${3:-}"
  local deadline=$(( SECONDS + timeout_seconds ))
  while (( SECONDS < deadline )); do
    if /usr/bin/curl --silent --show-error --fail --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$label" ]] && ! cliproxy_agent_is_running "$label"; then
      return 2
    fi
    sleep 0.25
  done
  return 1
}

cliproxy_agent_is_running() {
  local label="$1"
  launchctl print "$cliproxy_domain/$label" 2>/dev/null | \
    /usr/bin/grep -Fq "state = running"
}

cliproxy_wait_models() {
  local client_key="$1"
  local timeout_seconds="${2:-$cliproxy_ready_timeout_seconds}"
  local label="${3:-}"
  local deadline=$(( SECONDS + timeout_seconds ))
  while (( SECONDS < deadline )); do
    if /usr/bin/curl --silent --fail --max-time 2 \
      -H "Authorization: Bearer $client_key" \
      "http://127.0.0.1:8317/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$label" ]] && ! cliproxy_agent_is_running "$label"; then
      return 2
    fi
    sleep 0.25
  done
  return 1
}

cliproxy_render_runtime() {
  "$cliproxy_node" "$cliproxy_tools_dir/render-runtime-config.mjs" \
    "$cliproxy_tools_dir/config.template.yaml" \
    "$cliproxy_runtime_config" \
    "$cliproxy_auth_dir" \
    "$cliproxy_client_key_file" \
    "$cliproxy_key_file"
}

cliproxy_set_routing_mode() {
  local mode="$1"
  [[ "$mode" == "direct" || "$mode" == "forward" ]] || \
    cliproxy_die "GPT routing mode must be direct or forward."
  local temporary="$cliproxy_routing_mode_file.tmp-$$"
  print -r -- "$mode" >"$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$cliproxy_routing_mode_file"
}

cliproxy_refresh_official_catalog() {
  local config_is_official
  config_is_official="$($cliproxy_node -e '
    const fs = require("fs");
    const text = fs.existsSync(process.argv[1]) ? fs.readFileSync(process.argv[1], "utf8") : "";
    const proxied = /^\s*(?:openai_base_url|model_catalog_json)\s*=/m.test(text);
    process.stdout.write(proxied ? "false" : "true");
  ' "$cliproxy_codex_config")"

  if [[ "$config_is_official" == "true" ]]; then
    local temporary="$cliproxy_official_catalog.tmp-$$"
    if "$cliproxy_codex_binary" debug models >"$temporary" && \
      "$cliproxy_node" -e '
        const fs = require("fs");
        const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (!Array.isArray(value.models) || value.models.length === 0) process.exit(1);
      ' "$temporary"; then
      chmod 600 "$temporary"
      mv -f "$temporary" "$cliproxy_official_catalog"
    else
      rm -f "$temporary"
      [[ -s "$cliproxy_official_catalog" ]] || \
        cliproxy_die "Unable to refresh the official Codex model catalog."
    fi
  fi

  [[ -s "$cliproxy_official_catalog" ]] || \
    cliproxy_die "Official Codex model catalog snapshot is missing; run reset-codex once before mode 1."
}

cliproxy_has_codex_oauth() {
  "$cliproxy_node" -e '
    const fs = require("fs"), path = require("path");
    const directory = process.argv[1];
    let found = false;
    for (const name of fs.existsSync(directory) ? fs.readdirSync(directory) : []) {
      if (!name.endsWith(".json")) continue;
      try {
        const value = JSON.parse(fs.readFileSync(path.join(directory, name), "utf8"));
        if (value.type === "codex" && value.disabled !== true) found = true;
      } catch {}
    }
    process.exit(found ? 0 : 1);
  ' "$cliproxy_auth_dir"
}

cliproxy_bootstrap_agent() {
  local label="$1"
  local plist="$2"
  local index

  launchctl enable "$cliproxy_domain/$label" >/dev/null 2>&1 || true
  launchctl bootout "$cliproxy_domain/$label" >/dev/null 2>&1 || true
  for (( index = 1; index <= 20; index++ )); do
    if launchctl bootstrap "$cliproxy_domain" "$plist" >/dev/null 2>&1; then
      launchctl kickstart -k "$cliproxy_domain/$label" >/dev/null
      return 0
    fi
    sleep 0.25
  done
  cliproxy_die "Unable to bootstrap LaunchAgent $label."
}

cliproxy_assert_compat_idle() {
  local health_json
  health_json="$(/usr/bin/curl --silent --fail --max-time 2 "http://127.0.0.1:8318/health" 2>/dev/null || true)"
  [[ -n "$health_json" ]] || return 0
  local active_requests
  active_requests="$($cliproxy_node -e '
    const value = JSON.parse(process.argv[1]);
    process.stdout.write(Number.isInteger(value.active_requests) ? String(value.active_requests) : "unknown");
  ' "$health_json")"
  [[ "$active_requests" != "unknown" ]] || \
    cliproxy_die "The running compatibility proxy predates safe reload support; run reset-codex --no-restart before upgrading it."
  (( active_requests == 0 )) || \
    cliproxy_die "Compatibility proxy has $active_requests active request(s); reload was not attempted."
}

cliproxy_start_services() {
  local routing_mode="$1"
  [[ -f "$cliproxy_api_plist" ]] || cliproxy_die "Missing LaunchAgent: $cliproxy_api_plist"
  [[ -f "$cliproxy_compat_plist" ]] || cliproxy_die "Missing LaunchAgent: $cliproxy_compat_plist"

  local client_key
  client_key="$(<"$cliproxy_client_key_file")"
  launchctl enable "$cliproxy_domain/$cliproxy_api_label" >/dev/null 2>&1 || true
  if ! /usr/bin/curl --silent --fail --max-time 2 \
    -H "Authorization: Bearer $client_key" \
    "http://127.0.0.1:8317/v1/models" >/dev/null 2>&1; then
    cliproxy_bootstrap_agent "$cliproxy_api_label" "$cliproxy_api_plist"
  fi

  if ! cliproxy_wait_models \
    "$client_key" "$cliproxy_ready_timeout_seconds" "$cliproxy_api_label"; then
    cliproxy_agent_is_running "$cliproxy_api_label" || \
      cliproxy_die "CLIProxyAPI exited before becoming ready on 127.0.0.1:8317."
    cliproxy_die "CLIProxyAPI did not become ready on 127.0.0.1:8317 within ${cliproxy_ready_timeout_seconds} seconds."
  fi

  launchctl enable "$cliproxy_domain/$cliproxy_compat_label" >/dev/null 2>&1 || true
  if [[ -f "$cliproxy_compat_reload_marker" ]]; then
    cliproxy_assert_compat_idle
    cliproxy_bootstrap_agent "$cliproxy_compat_label" "$cliproxy_compat_plist"
  elif ! /usr/bin/curl --silent --fail --max-time 2 "http://127.0.0.1:8318/health" | \
    /usr/bin/grep -Fq "\"gpt_routing_mode\":\"$routing_mode\""; then
    cliproxy_bootstrap_agent "$cliproxy_compat_label" "$cliproxy_compat_plist"
  fi
  if ! cliproxy_wait_http \
    "http://127.0.0.1:8318/health" "$cliproxy_ready_timeout_seconds" "$cliproxy_compat_label"; then
    cliproxy_agent_is_running "$cliproxy_compat_label" || \
      cliproxy_die "Codex compatibility proxy exited before becoming ready on 127.0.0.1:8318."
    cliproxy_die "Codex compatibility proxy did not become ready on 127.0.0.1:8318 within ${cliproxy_ready_timeout_seconds} seconds."
  fi
  /usr/bin/curl --silent --fail --max-time 2 "http://127.0.0.1:8318/health" | \
    /usr/bin/grep -Fq "\"gpt_routing_mode\":\"$routing_mode\"" || \
    cliproxy_die "Codex compatibility proxy did not apply GPT routing mode $routing_mode."
  rm -f "$cliproxy_compat_reload_marker"
}

cliproxy_stop_services() {
  launchctl disable "$cliproxy_domain/$cliproxy_compat_label" >/dev/null 2>&1 || true
  launchctl disable "$cliproxy_domain/$cliproxy_api_label" >/dev/null 2>&1 || true
  launchctl bootout "$cliproxy_domain/$cliproxy_compat_label" >/dev/null 2>&1 || true
  launchctl bootout "$cliproxy_domain/$cliproxy_api_label" >/dev/null 2>&1 || true
}

cliproxy_build_catalog() {
  local routing_mode="$1"
  local client_version
  client_version="$("$cliproxy_codex_binary" --version | awk '{ print $2 }')"
  local proxy_catalog_url="http://127.0.0.1:8318/v1/models?client_version=$client_version"
  if [[ "$routing_mode" == "direct" ]]; then
    "$cliproxy_node" "$cliproxy_tools_dir/build-model-catalog.mjs" \
      direct "$proxy_catalog_url" "$cliproxy_catalog" "$cliproxy_official_catalog"
  else
    "$cliproxy_node" "$cliproxy_tools_dir/build-model-catalog.mjs" \
      forward "$proxy_catalog_url" "$cliproxy_catalog"
  fi
}

cliproxy_switch_config() {
  local mode="$1"
  "$cliproxy_node" "$cliproxy_tools_dir/update-codex-config.mjs" \
    "$mode" "$cliproxy_codex_config" "$cliproxy_catalog" "$cliproxy_state_dir"
}

cliproxy_validate_codex_config() {
  "$cliproxy_codex_binary" features list >/dev/null
}

cliproxy_validate_catalog() {
  local rendered="$cliproxy_state_dir/validated-models.json"
  "$cliproxy_codex_binary" debug models >"$rendered"
  "$cliproxy_node" -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (!Array.isArray(value.models) || !value.models.some((model) => typeof model?.slug === "string" && model.slug.trim() !== "")) {
      throw new Error("Proxy catalog must contain at least one valid model");
    }
  ' "$rendered"
}

cliproxy_schedule_codex_restart() {
  /usr/bin/nohup "$cliproxy_tools_dir/restart-codex-app.sh" \
    >"$cliproxy_auth_root/restart-codex.log" 2>&1 &
}
