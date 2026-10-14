# Deploy scripts

Foundry scripts for the Launchpad and Moments contracts on Monad (chain 143). A dry run needs no key:

```bash
cd contracts
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc3.monad.xyz --sender <owner address>
```

Deploying signs as the contract owner, so it follows the owner procedure in DyorHQ/internal (private):
`ios-app/contracts/script/README.md`. Sign with a hardware wallet or a Foundry keystore (`--ledger`, `--account`),
never with a private key on the command line or in an env file.

The v2 contracts deploy through `script/deploy-v2.sh`. Its header lists every input (`EXTERNAL_BASE_URI` included,
which must be exactly `https://dyorhq.fun/moments/c4/`) and everything the pre-flight refuses: a `contracts/.env`, any
other knob the Deploy scripts read, an `OWNER`/`GOVERNANCE` that is empty, or left out or GOV on a live run (unless
`NO_HANDOVER=1`), or is not a Safe with a threshold of at least 2, and a full run from a deployer whose nonce is not 0. A broadcast that stops midway is finished with forge's `--resume`, whose exact commands the script prints;
running the script again would deploy a second stack. `FORK=1` rehearses on a local anvil fork, after
`cast rpc anvil_setBalance $GOV 0x3635C9ADC5DEA00000 --rpc-url http://127.0.0.1:<port>`.
