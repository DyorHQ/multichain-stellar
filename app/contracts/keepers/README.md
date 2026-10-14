# Keepers

Keepers for the deployed Launchpad and Moments contracts. Dry run by default; `--send` signs through Foundry `cast`
with a keystore, a named account or a Ledger, never a raw key.

```sh
node contracts/keepers/keeper.mjs --help
npm run keepers:test
```

`ops/` is the Fly.io kit (one always-on Machine running supercronic): each file's header says what it does. Every
scheduled unit is a dry run until its send flag is set.

What each job does, how to run and schedule them, and the operating procedures are in DyorHQ/internal (private):
`ios-app/contracts/keepers/README.md`.
