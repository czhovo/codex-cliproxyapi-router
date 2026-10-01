#!/bin/zsh

# Resolve the bundled CLI without launching or restarting the desktop app.
cliproxy_resolve_codex_binary() {
  if [[ -n "${CODEX_BINARY_PATH:-}" ]]; then
    [[ -x "$CODEX_BINARY_PATH" ]] || {
      print -u2 -- "ERROR: CODEX_BINARY_PATH is not executable: $CODEX_BINARY_PATH"
      return 1
    }
    print -r -- "$CODEX_BINARY_PATH"
    return 0
  fi
  local app candidate
  local -a apps
  if (( $# > 0 )); then
    apps=("$@")
  else
    apps=(/Applications/ChatGPT.app /Applications/Codex.app
      "${HOME:?HOME is required}/Applications/ChatGPT.app"
      "$HOME/Applications/Codex.app")
  fi
  for app in "${apps[@]}"; do
    for candidate in "$app/Contents/Resources/codex-cli/bin/codex" \
      "$app/Contents/Resources/codex"; do
      if [[ -x "$candidate" ]]; then
        print -r -- "$candidate"
        return 0
      fi
    done
  done
  print -u2 -- "ERROR: Codex bundled CLI was not found. Set CODEX_BINARY_PATH to its executable path."
  return 1
}
