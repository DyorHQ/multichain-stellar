# Rules for every session in this repository

- **Never commit a secret.** No env files, private keys, seed phrases, API keys or tokens, keyed RPC URLs or signing
  material. Values live in git-ignored files, a password manager or the platform's secret store.
- **Never print a secret value.** Do not cat, grep, echo or diff env files, `Secrets.xcconfig` or key files, and do not
  search a whole checkout for key names (`grep -r`, `rg -uu`): the lines it prints can hold the values. For variable
  names only: `scripts/dev/env-names.sh <file>`. Tools that need a value read it themselves.
- **Internal documents never go in this repository.** Audit reports and checklists, security reviews, runbooks and owner
  procedures, handoffs, incident and relaunch notes, plans and decision logs go to the private repository
  **DyorHQ/internal**, under `ios-app/`. `docs/` holds developer docs only.
- **The leak guard must pass.** `scripts/dev/install-hooks.sh` turns on the git hooks (the SessionStart hook runs it);
  the `leak-guard` workflow re-checks every push with the default branch's copy of the guard. Never use `--no-verify`,
  `git commit -n` or another `core.hooksPath`. A reviewed false positive gets a line in `.leakguard` with a reason
  (`@allow <path glob> <finding name>` for secret-scan, `!<path>` for a path) and the matching entry in
  `.gitleaks.toml`, committed on its own before the change that needs it: a commit cannot exempt itself.
- **The guards are the owner's.** Do not edit `.claude/settings*.json`, `.claude/hooks/` or `~/.claude`; the secret
  guard refuses it. Production Supabase writes ask the user in the Claude UI.
- **Public repositories** (website, docs, accounts-domain): push only when their leak guard passes, and never describe
  open vulnerabilities, incidents, key history or internal audit finding IDs in them, commit messages included.
