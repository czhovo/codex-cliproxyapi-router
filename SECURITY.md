# Security

## Credential handling

- Do not commit `deepseek_api_key.txt`, `client-key.txt`, `config.runtime.yaml`, the `auth/`
  directory, logs, PID files, or generated model catalogs.
- The installer never asks for or copies an API key from the repository.
- Runtime credentials remain under the current user's Codex data directory. The included ACL
  script restricts them to the current user, `SYSTEM`, and local Administrators.
- Ports 8317 and 8318 are bound to `127.0.0.1` only.
- The compatibility layer emits bounded, structured logs and redacts common Bearer, API-key,
  JWT, cookie, and account-identifier forms.

## Reporting a vulnerability

Open a private GitHub security advisory for the repository. Do not include live credentials,
OAuth files, cookies, raw prompts, or unredacted logs in an issue.
