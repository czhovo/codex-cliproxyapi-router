#!/bin/zsh
set -u

export PATH="${HOME:?HOME is required}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

error_log="$(mktemp "${TMPDIR:-/tmp}/reset-codex.XXXXXX")"
trap 'rm -f "$error_log"' EXIT
"$HOME/.codex/tools/cliproxyapi/reset-codex" "$@" 2> >(tee "$error_log" >&2)
exit_code=$?

if (( exit_code != 0 )); then
  error_text="$(tail -n 8 "$error_log")"
  /usr/bin/osascript -e 'on run argv' \
    -e 'display alert "reset-codex 执行失败" message (item 1 of argv) as critical' \
    -e 'end run' -- "$error_text" >/dev/null 2>&1 || true
  exit "$exit_code"
fi

restart_text="；Codex App 将自动重启"
for argument in "$@"; do
  [[ "$argument" == "--no-restart" ]] && restart_text="；未重启 Codex App"
done
/usr/bin/osascript -e 'on run argv' \
  -e 'display notification ((item 1 of argv) & (item 2 of argv)) with title "reset-codex"' \
  -e 'end run' -- "已恢复 Codex 官方模式并保留可用的当前模型选择" "$restart_text" >/dev/null 2>&1 || true
