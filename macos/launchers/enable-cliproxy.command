#!/bin/zsh
set -u

export PATH="${HOME:?HOME is required}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

error_log="$(mktemp "${TMPDIR:-/tmp}/enable-cliproxy.XXXXXX")"
trap 'rm -f "$error_log"' EXIT
"$HOME/.codex/tools/cliproxyapi/enable-cliproxy" "$@" 2> >(tee "$error_log" >&2)
exit_code=$?

if (( exit_code != 0 )); then
  error_text="$(tail -n 8 "$error_log")"
  /usr/bin/osascript -e 'on run argv' \
    -e 'display alert "enable-cliproxy 执行失败" message (item 1 of argv) as critical' \
    -e 'end run' -- "$error_text" >/dev/null 2>&1 || true
  exit "$exit_code"
fi

mode="$(<"$HOME/.codex/cliproxy-state/gpt-routing-mode")"
restart_text="；Codex App 将自动重启"
for argument in "$@"; do
  [[ "$argument" == "--no-restart" ]] && restart_text="；未重启 Codex App"
done
if [[ "$mode" == "direct" ]]; then
  notification="模式 1 已启用：GPT 官方直连，DeepSeek/其他代理模型经 8317${restart_text}"
else
  notification="模式 2 已启用：GPT 与 DeepSeek/其他代理模型全部经 8317${restart_text}"
fi
/usr/bin/osascript -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "enable-cliproxy"' \
  -e 'end run' -- "$notification" >/dev/null 2>&1 || true
