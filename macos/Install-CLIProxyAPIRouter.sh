#!/bin/zsh
set -euo pipefail

umask 077

skip_desktop_launchers=false
archive_path=""
while (( $# > 0 )); do
  case "$1" in
    --skip-desktop-launchers)
      skip_desktop_launchers=true
      shift
      ;;
    --archive)
      (( $# >= 2 )) || { print -u2 -- "--archive requires a path"; exit 2; }
      archive_path="$2"
      shift 2
      ;;
    *)
      print -u2 -- "Usage: Install-CLIProxyAPIRouter.sh [--skip-desktop-launchers] [--archive PATH]"
      exit 2
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || { print -u2 -- "This installer supports macOS only."; exit 1; }

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
install_user_dir="${HOME:?HOME is required}"
codex_dir="$install_user_dir/.codex"
tools_dir="$codex_dir/tools/cliproxyapi"
state_dir="$codex_dir/cliproxy-state"
auth_root="$install_user_dir/.cli-proxy-api"
auth_dir="$auth_root/auth"
binary_dir="$tools_dir/bin"
launch_dir="$install_user_dir/Library/LaunchAgents"
local_bin_dir="$install_user_dir/.local/bin"
desktop_dir="$install_user_dir/Desktop"
client_key_file="$state_dir/client-api-key"
deepseek_key_file="$codex_dir/deepseek_api_key.txt"
reload_marker="$state_dir/compat-reload-required"
node_path="$(command -v node || true)"
codex_binary="/Applications/ChatGPT.app/Contents/Resources/codex"

[[ -n "$node_path" ]] || { print -u2 -- "Node.js was not found on PATH."; exit 1; }
[[ -x "$codex_binary" ]] || { print -u2 -- "Codex App binary was not found at $codex_binary"; exit 1; }

cliproxy_version="7.2.119"
case "$(uname -m)" in
  arm64)
    archive_name="CLIProxyAPI_${cliproxy_version}_darwin_aarch64.tar.gz"
    expected_sha256="7e9bc444a7defd9ae06dc37f16a6ce73be754656b07324aa3d264a3d01c71175"
    ;;
  x86_64)
    archive_name="CLIProxyAPI_${cliproxy_version}_darwin_amd64.tar.gz"
    expected_sha256="0ab1f1a0751532cf0f36fd396f6a9d74707358bcbfde16f809ffce4bf069f26b"
    ;;
  *)
    print -u2 -- "Unsupported macOS architecture: $(uname -m)"
    exit 1
    ;;
esac
download_url="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${cliproxy_version}/${archive_name}"

install_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-cliproxyapi-install.XXXXXX")"
cleanup() {
  if [[ -n "$install_temp_dir" && -d "$install_temp_dir" && "${install_temp_dir:t}" == codex-cliproxyapi-install.* ]]; then
    rm -rf -- "$install_temp_dir"
  fi
}
trap cleanup EXIT

temporary_archive="$install_temp_dir/$archive_name"
expanded_dir="$install_temp_dir/expanded"
mkdir -p "$expanded_dir"
if [[ -n "$archive_path" ]]; then
  [[ -f "$archive_path" ]] || { print -u2 -- "Archive was not found: $archive_path"; exit 1; }
  cp -p -- "$archive_path" "$temporary_archive"
else
  /usr/bin/curl --fail --location --silent --show-error --max-time 300 \
    --output "$temporary_archive" "$download_url"
fi

actual_sha256="$(/usr/bin/shasum -a 256 "$temporary_archive" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$expected_sha256" ]] || {
  print -u2 -- "CLIProxyAPI archive checksum mismatch."
  print -u2 -- "Expected: $expected_sha256"
  print -u2 -- "Received: $actual_sha256"
  exit 1
}

/usr/bin/tar -xzf "$temporary_archive" -C "$expanded_dir"
downloaded_binary="$(find "$expanded_dir" -type f -name 'cli-proxy-api' -perm -u+x -print -quit)"
[[ -n "$downloaded_binary" ]] || { print -u2 -- "Verified archive does not contain cli-proxy-api."; exit 1; }

mkdir -p "$codex_dir" "$tools_dir" "$state_dir" "$auth_root" "$auth_dir" \
  "$binary_dir" "$launch_dir" "$local_bin_dir"
chmod 700 "$codex_dir" "$tools_dir" "$state_dir" "$auth_root" "$auth_dir" "$binary_dir"

installed_binary="$binary_dir/cli-proxy-api"
/usr/bin/install -m 700 "$downloaded_binary" "$installed_binary"
# Upstream Go releases carry a linker-generated ad-hoc signature that macOS may
# reject when a LaunchAgent starts the binary after reboot. Replace it with a
# local ad-hoc signature after the verified archive has been installed.
/usr/bin/codesign --force --sign - --timestamp=none "$installed_binary"
/usr/bin/codesign --verify --strict "$installed_binary"
/usr/bin/install -m 700 "$repository_root/src/codex-catalog-compat.mjs" "$tools_dir/codex-compat-proxy.mjs"
/usr/bin/install -m 600 "$repository_root/config/config.template.yaml" "$tools_dir/config.template.yaml"
for source_name in \
  build-model-catalog.mjs update-codex-config.mjs render-runtime-config.mjs \
  cliproxy-common.sh enable-cliproxy reset-codex restart-codex-app.sh login-codex-oauth; do
  /usr/bin/install -m 700 "$script_dir/scripts/$source_name" "$tools_dir/$source_name"
done

if [[ ! -s "$client_key_file" ]]; then
  print -n -- "codex-local-$(/usr/bin/openssl rand -hex 32)" >"$client_key_file"
fi
[[ -f "$deepseek_key_file" ]] || : >"$deepseek_key_file"
chmod 600 "$client_key_file" "$deepseek_key_file"

ln -sfn "$tools_dir/enable-cliproxy" "$local_bin_dir/enable-cliproxy"
ln -sfn "$tools_dir/reset-codex" "$local_bin_dir/reset-codex"
ln -sfn "$tools_dir/login-codex-oauth" "$local_bin_dir/login-codex-oauth"

if ! $skip_desktop_launchers; then
  mkdir -p "$desktop_dir"
  /usr/bin/install -m 755 "$script_dir/launchers/enable-cliproxy.command" "$desktop_dir/enable-cliproxy.command"
  /usr/bin/install -m 755 "$script_dir/launchers/reset-codex.command" "$desktop_dir/reset-codex.command"
fi

proxy_label="com.codex.cliproxyapi-router.proxy"
compat_label="com.codex.cliproxyapi-router.compat"
proxy_plist="$launch_dir/$proxy_label.plist"
compat_plist="$launch_dir/$compat_label.plist"
runtime_config="$auth_root/config.yaml"
path_value="$local_bin_dir:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

write_common_plist_values() {
  local plist="$1"
  local label="$2"
  /usr/bin/plutil -create xml1 "$plist"
  /usr/bin/plutil -insert Label -string "$label" "$plist"
  /usr/bin/plutil -insert RunAtLoad -bool true "$plist"
  /usr/bin/plutil -insert KeepAlive -dictionary "$plist"
  /usr/bin/plutil -insert KeepAlive.SuccessfulExit -bool false "$plist"
  /usr/bin/plutil -insert ProcessType -string Background "$plist"
  /usr/bin/plutil -insert ThrottleInterval -integer 5 "$plist"
  /usr/bin/plutil -insert EnvironmentVariables -dictionary "$plist"
  /usr/bin/plutil -insert EnvironmentVariables.HOME -string "$install_user_dir" "$plist"
  /usr/bin/plutil -insert EnvironmentVariables.PATH -string "$path_value" "$plist"
}

write_common_plist_values "$proxy_plist" "$proxy_label"
/usr/bin/plutil -insert ProgramArguments -array "$proxy_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$binary_dir/cli-proxy-api" "$proxy_plist"
/usr/bin/plutil -insert ProgramArguments.1 -string -config "$proxy_plist"
/usr/bin/plutil -insert ProgramArguments.2 -string "$runtime_config" "$proxy_plist"
/usr/bin/plutil -insert ProgramArguments.3 -string -local-model "$proxy_plist"
/usr/bin/plutil -insert StandardOutPath -string "$auth_root/cliproxyapi.stdout.log" "$proxy_plist"
/usr/bin/plutil -insert StandardErrorPath -string "$auth_root/cliproxyapi.stderr.log" "$proxy_plist"

write_common_plist_values "$compat_plist" "$compat_label"
/usr/bin/plutil -insert ProgramArguments -array "$compat_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$node_path" "$compat_plist"
/usr/bin/plutil -insert ProgramArguments.1 -string "$tools_dir/codex-compat-proxy.mjs" "$compat_plist"
/usr/bin/plutil -insert EnvironmentVariables.CLIPROXY_CLIENT_KEY_FILE -string "$client_key_file" "$compat_plist"
/usr/bin/plutil -insert EnvironmentVariables.CLIPROXY_GPT_ROUTING_MODE_FILE -string "$state_dir/gpt-routing-mode" "$compat_plist"
/usr/bin/plutil -insert StandardOutPath -string "$auth_root/codex-compat.stdout.log" "$compat_plist"
/usr/bin/plutil -insert StandardErrorPath -string "$auth_root/codex-compat.stderr.log" "$compat_plist"
chmod 600 "$proxy_plist" "$compat_plist"

: >"$reload_marker"
chmod 600 "$reload_marker"

"$node_path" --check "$tools_dir/codex-compat-proxy.mjs"
"$node_path" --check "$tools_dir/build-model-catalog.mjs"
"$node_path" --check "$tools_dir/update-codex-config.mjs"
"$node_path" --check "$tools_dir/render-runtime-config.mjs"
zsh -n "$tools_dir/cliproxy-common.sh" "$tools_dir/enable-cliproxy" "$tools_dir/reset-codex" \
  "$tools_dir/restart-codex-app.sh" "$tools_dir/login-codex-oauth"

print -- "Codex CLIProxyAPI Router for macOS was installed without starting services or changing config.toml."
print -- "CLIProxyAPI version: $cliproxy_version (official archive checksum verified)"
print -- "Place the DeepSeek API key in: $deepseek_key_file"
print -- "Then run: $local_bin_dir/enable-cliproxy"
