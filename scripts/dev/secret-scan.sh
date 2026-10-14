#!/bin/bash
# Secret-leak scanner. Looks for the VALUES of the local secrets (the repo's .env and the iOS Secrets.xcconfig), for
# well-known key and token patterns and for key-shaped literals, and reports only file:line and the variable/pattern
# NAME — a value is never printed.
#
#   scripts/dev/secret-scan.sh                  # staged changes: added lines of `git diff --cached` (pre-commit hook)
#   scripts/dev/secret-scan.sh --all            # every tracked file in the working tree
#   scripts/dev/secret-scan.sh --path DIR       # any file or directory, e.g. dist/ or an .xcarchive
#   scripts/dev/secret-scan.sh --pre-push R URL # commits being pushed to remote R, refs on stdin (pre-push hook)
#   scripts/dev/secret-scan.sh --history [REV…] # added lines and messages of every commit `git log REV…` lists
#                                               # (default: --all), e.g. the whole history, or A..B in CI
#   scripts/dev/secret-scan.sh --commit-msg F   # a commit message file (commit-msg hook)
#   --config FILE                               # repository policy from FILE instead of .leakguard (repeatable)
#   --repo DIR                                  # any mode above in another repository, with this one's secret values
#   scripts/dev/secret-scan.sh --install-hook   # same as scripts/dev/install-hooks.sh (the tracked .githooks/)
#
# What counts as secret:
#   .env files (.env and every .env.* but the .example/.sample/.template ones, and .envrc): every value of 12+
#     characters whose variable is not NEXT_PUBLIC_* and is not a plain 0x-address — plus any NEXT_PUBLIC_* value
#     shaped like a private key (32-byte hex, e.g. NEXT_PUBLIC_DEV_WALLET_KEY), because vinext inlines NEXT_PUBLIC_
#     values into the bundle.
#   ios/DyorHQ/Config/Secrets.xcconfig: every value of 8+ characters whose variable is not a public identifier
#     (same PUBLIC_VARS and value handling as ios/scripts/testflight.sh).
#   Variables in PUBLIC_VARS (public identifiers such as the Privy app id) are skipped in both files.
#   32-byte hex values are matched case-insensitively and without the 0x; for a URL value the key part (its last path
#     segment, when 16+ characters) is matched on its own too.
#   Patterns (add_pattern below): keyed RPC-provider and bundler URLs (Alchemy, Infura, QuickNode, Pimlico, Chainstack,
#     dRPC, Ankr, Blast, GetBlock, NodeReal, Tenderly, and any RPC host with a key in its path or query), PEM and age
#     private keys, `…KEY=0x<64 hex>` and `private_key`/`privateKey`/`--private-key` assignments, provider tokens
#     (GitHub, AWS, Slack, Discord and Slack webhooks, Stripe live, Anthropic, OpenAI, Google, npm, Privy, Supabase,
#     Telegram), JSON Web Tokens, a known secret variable (AURORA_API_KEY, PRIVY_APP_SECRET, …) given a literal, and a
#     UUID given to a key-named variable.
#   Heuristics (HEURISTICS_AWK below): BIP-39 seed phrases (12+ consecutive words of bip39-english.txt, next to this
#     script, also across lines, numbered or hyphen-joined) and 32-byte hex literals in a key-named array, passed to a
#     key or wallet constructor, or up to 40 characters after a key-like name (deployerKey, RELAYER_PK, Treasury, …).
#   Public values are masked before the patterns and heuristics run: the anvil/hardhat default keys, the fork-only dev
#     keys, the AWS documentation example keys, the jwt.io example token, Supabase anon JWTs (the publishable
#     sb_publishable_ key matches no pattern) and well-known public test seed phrases. Placeholders are no finding:
#     YOUR_…/REPLACE…/EXAMPLE/CHANGEME/xxxx values and 32-byte hex values with fewer than 8 distinct digits (0x000…0).
#   Committed env/key files are reported by name (scripts/dev/forbidden-paths.sh covers the full list).
#   Binary files are recognized by content: zip (also ipa, jar, docx/xlsx and other office documents), gzip, bzip2,
#     xz, zstd and 7z archives are unpacked into a private temporary directory and their files checked (an archive
#     inside one level deep too); UTF-16 text is decoded. A file that cannot be unpacked is itself a finding.
# Repository policy (.leakguard "@" lines; the committed and the pending version, as scripts/dev/forbidden-paths.sh
# reads it, so no commit can relax its own check):
#   @public    — a public repository: internal audit finding IDs (a prefix from the list below, a hyphen and a
#                number) are findings in content and commit messages too.
#   @internal  — the DyorHQ/internal repository: the internal-document marker is allowed. Everywhere else it is a
#                finding (every DyorHQ/internal document carries it, so a copied document is caught).
#   @allow GLOB NAME — a reviewed false positive: findings called NAME (a pattern or heuristic name exactly as printed)
#                in paths matching GLOB (.leakguard glob rules) are dropped and counted. Values from .env or
#                Secrets.xcconfig can never be allowed.
# Sources are read from the main worktree (the parent of the git common dir), the current worktree, ~/Hackathon (the
# IOS-app checkout, so the public repositories are checked against its values too) and every directory in
# SECRET_SCAN_EXTRA_SOURCES (":"-separated). SECRET_SCAN_ENV / SECRET_SCAN_XCCONFIG replace all of them (tests use
# fake ones — never test with real values).
# A self-check runs first: if awk, grep or sed misbehave (missing, or incompatible on this platform) nothing is
# reported clean. Exit status: 0 clean, 1 findings, 2 usage, setup or scanner error. Runs on macOS /bin/bash 3.2.

# Never trace: the values below live in shell variables, and `bash -x`, SHELLOPTS=xtrace or a BASH_ENV that runs
# `set -x` would print every one of them to stderr.
set +x

# Byte-wise matching: binaries (an .xcarchive, a bundle) are not valid UTF-8, and grep skips bytes it cannot decode.
export LC_ALL=C

# Public identifiers that ship in the app by design. Mirrors PUBLIC_VARS in ios/scripts/testflight.sh; both gates run at
# upload time, so if the lists drift the stricter one wins — a drift can block an upload, never let a secret through.
PUBLIC_VARS=$(echo DEVELOPMENT_TEAM DYOR_SLASH PRIVY_APP_ID PRIVY_CLIENT_ID PASSKEY_RP_ID PERPL_BUILDER_ID \
  SOCIAL_LOGINS_ENABLED PASSKEYS_ENABLED LAUNCHPAD_FACTORY LAUNCH_ROUTER FEE_ESCROW HOLDER_FEE_SHARING MEME_HOOK \
  AURORA_FEE_RECIPIENT)

RE_ADDRESS='^0x[0-9a-fA-F]{40}$'
RE_HEX32='^(0x)?[0-9a-fA-F]{64}$'
RE_URL='^[A-Za-z][A-Za-z0-9+.-]*://'
RE_NAME='^[A-Za-z_][A-Za-z0-9_]*$'
# An xcconfig setting: NAME, optional conditions (NAME[sdk=iphoneos*][arch=*]), `=`, value; captures name and value.
RE_XCCONFIG_PARTS='^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])*[[:space:]]*=(.*)$'

# Generic patterns (POSIX ERE, for grep -E, git grep -E and bash =~) as parallel arrays of name, regex and an optional
# prefilter: a looser regex that starts with a literal, which grep and git grep search much faster. A line has to
# match the prefilter to be tested against the regex, so a prefilter must match everything its regex matches.
P_NAME=(); P_RE=(); P_FAST=()
add_pattern() { P_NAME[${#P_NAME[@]}]=$1; P_RE[${#P_RE[@]}]=$2; P_FAST[${#P_FAST[@]}]=${3:-$2}; }
Q="[^[:space:]\"'\`]" # a character of a URL in quotes or prose
UUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
add_pattern "Alchemy keyed RPC URL" 'alchemy(api)?\.(com|io)/v2/[A-Za-z0-9_-]{16,}'
add_pattern "Infura keyed RPC URL" 'infura\.io/v3/[0-9a-fA-F]{32}'
add_pattern "QuickNode keyed RPC URL" 'quiknode\.pro/[0-9a-fA-F]{16,}'
add_pattern "Chainstack keyed RPC URL" 'chainstack\.com/[0-9a-fA-F]{32}'
add_pattern "dRPC keyed RPC URL (dkey=)" "drpc\.org/$Q*[?&][Dd][Kk][Ee][Yy]=[A-Za-z0-9_-]{16,}"
add_pattern "Ankr keyed RPC URL" 'rpc\.ankr\.com/[A-Za-z0-9_]+/[0-9a-fA-F]{32,}'
add_pattern "Blast API keyed RPC URL" "blastapi\.io/$UUID"
add_pattern "GetBlock keyed RPC URL" 'getblock\.io/[0-9a-fA-F]{32}'
add_pattern "NodeReal keyed RPC URL" 'nodereal\.io/v1/[0-9a-fA-F]{32}'
add_pattern "Tenderly keyed RPC URL" 'gateway\.tenderly\.co/[A-Za-z0-9]{20,}'
# Any other RPC node URL (a host with "rpc" or "node" in its name) that carries a key in its path.
add_pattern "keyed RPC URL (key in the path)" \
  "[Hh][Tt][Tt][Pp][Ss]?://[^/[:space:]\"'\`]*([Rr][Pp][Cc]|[Nn][Oo][Dd][Ee])[^/[:space:]\"'\`]*/($Q*/)?([0-9a-fA-F]{32,}|$UUID)([/?#\"'\`[:space:]]|$)" \
  "[Hh][Tt][Tt][Pp][Ss]?://[^/[:space:]\"'\`]*([Rr][Pp][Cc]|[Nn][Oo][Dd][Ee])"
add_pattern "Pimlico keyed URL (apikey=)" "pimlico\.io/$Q*[?&][Aa][Pp][Ii][Kk][Ee][Yy]=[A-Za-z0-9_-]{8,}"
add_pattern "Pimlico API key (pim_)" '(^|[^A-Za-z0-9_])pim_[A-Za-z0-9]{20,}' 'pim_[A-Za-z0-9]{20,}'
add_pattern "API key or token in a URL query (apikey= / key= / access_token=)" \
  '[?&]([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Dd]?[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Tt][Oo][Kk][Ee][Nn]|[Aa][Uu][Tt][Hh][_-]?[Tt][Oo][Kk][Ee][Nn])=[A-Za-z0-9_-]{16,}'
add_pattern "PEM private key" '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----'
add_pattern "age secret key" 'AGE-SECRET-KEY-1[0-9A-Z]{58}'
# NAME_KEY=0x…, deployerKey = 0x…, "ownerKey": "0X…" — any case; not a public key (see benign below).
add_pattern "private key assignment (KEY=0x + 64 hex)" \
  "[A-Za-z0-9_]*[Kk][Ee][Yy][\"']?[[:space:]]*[:=][[:space:]]*[\"']?0[xX][0-9a-fA-F]{64}([^0-9a-fA-F]|$)" \
  "[Kk][Ee][Yy][\"']?[[:space:]]*[:=][[:space:]]*[\"']?0[xX][0-9a-fA-F]{64}"
# privateKey: "0x…", private_key = "…", --private-key 0x… (any case; the 0x is optional for forge/cast).
add_pattern "private key assignment (private_key / --private-key + 64 hex)" \
  "[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-]?[Kk][Ee][Yy][\"']?([[:space:]]*[:=][[:space:]]*|[[:space:]]+)[\"']?(0[xX])?[0-9a-fA-F]{64}([^0-9a-fA-F]|$)"
add_pattern "Supabase secret key (sb_secret_)" 'sb_secret_[A-Za-z0-9_-]{20,}'
add_pattern "Supabase access token (sbp_)" 'sbp_[0-9a-f]{40}'
# A JWT whose payload carries "service_role" (its base64url in each of the three byte alignments).
add_pattern "Supabase service_role JWT" 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*(c2VydmljZV9yb2xl|NlcnZpY2Vfcm9sZ|zZXJ2aWNlX3JvbG)'
# Any other JWT (a Privy or Pinata token, a session): header.payload.signature. Supabase anon keys are masked first.
add_pattern "JSON Web Token" 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
add_pattern "Privy app secret (privy_app_secret_)" 'privy_app_secret_[A-Za-z0-9_-]{20,}'
add_pattern "Privy authorization key (wallet-auth:)" 'wallet-auth:[A-Za-z0-9+/]{40,}'
add_pattern "GitHub token (ghp_/gho_/ghs_/ghu_/ghr_)" 'gh[pousr]_[A-Za-z0-9]{36}'
add_pattern "GitHub fine-grained token (github_pat_)" 'github_pat_[A-Za-z0-9_]{60,}'
add_pattern "AWS access key id (AKIA/ASIA)" '(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Za-z0-9]|$)' '(AKIA|ASIA)[0-9A-Z]{16}'
add_pattern "AWS secret access key assignment" \
  "[Aa][Ww][Ss][A-Za-z0-9_.-]{0,20}[Ss][Ee][Cc][Rr][Ee][Tt][A-Za-z0-9_.-]{0,20}[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9/+]{40}([^A-Za-z0-9/+=]|$)"
add_pattern "Slack token (xox*)" 'xox[abeoprs]-[0-9A-Za-z-]{10,}'
add_pattern "Slack webhook URL" 'hooks\.slack\.com/(services|workflows|triggers)/[A-Za-z0-9_/-]{20,}'
add_pattern "Discord webhook URL" 'discord(app)?\.com/api/webhooks/[0-9]{15,}/[A-Za-z0-9_-]{30,}'
add_pattern "Stripe live key (sk_live_/rk_live_)" '(sk|rk)_live_[0-9A-Za-z]{20,}'
add_pattern "Anthropic API key (sk-ant-)" 'sk-ant-[A-Za-z0-9_-]{20,}'
add_pattern "OpenAI API key (sk-proj-/sk-svcacct-/sk-admin-)" 'sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}'
add_pattern "OpenAI-style API key (sk-…)" '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9]{32,}([^A-Za-z0-9_-]|$)' 'sk-[A-Za-z0-9]{32,}'
add_pattern "Google API key (AIza)" 'AIza[0-9A-Za-z_-]{35}'
add_pattern "npm token (npm_)" '(^|[^A-Za-z0-9_])npm_[A-Za-z0-9]{36}([^A-Za-z0-9]|$)' 'npm_[A-Za-z0-9]{36}'
add_pattern "Telegram bot token" '(^|[^0-9])[0-9]{8,10}:AA[0-9A-Za-z_-]{33}([^0-9A-Za-z_-]|$)' ':AA[0-9A-Za-z_-]{33}'
# NAME=value for the secrets this project uses (also as the end of a longer name, e.g. NEXT_PUBLIC_…), when the value
# is a literal token: no $VAR, <placeholder>, call or dotted expression (JWTs and URLs are left to the patterns above).
add_pattern "known secret variable with a literal value" \
  "(APP_JWT_SECRET|PRIVY_APP_SECRET|AURORA_API_KEY|SUPABASE_SERVICE_ROLE_KEY|SERVICE_ROLE_KEY|PINATA_JWT|PINATA_API_KEY|PINATA_API_SECRET|OPENSEA_API_KEY|ALCHEMY_API_KEY|PIMLICO_API_KEY|TREASURY_KEY|OWNER_KEY|DEPLOYER_KEY|RELAYER_KEY|KEEPER_KEY|OPERATOR_KEY|SIGNER_KEY|MNEMONIC|SEED_PHRASE)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9_+/=-]{16,}" \
  "(SECRET|_KEY|_JWT|MNEMONIC|SEED_PHRASE)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9_+/=-]{16,}"
# let auroraKey = "<uuid>", API_TOKEN: '<uuid>' — the Aurora API key, like many provider keys, is a UUID.
add_pattern "UUID given to a key-named variable" \
  "[A-Za-z0-9_]*([Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn])[A-Za-z0-9_]*[\"']?[[:space:]]*[:=][[:space:]]*[\"'\`]$UUID[\"'\`]" \
  "[:=][[:space:]]*[\"'\`]$UUID[\"'\`]"

# Masked before the patterns and heuristics run, so they never count as findings (a value from .env is still matched
# even if it is one of these):
#   anvil / hardhat default accounts 0-9 (the public "test test … junk" mnemonic): world-known dev keys;
#   the fork-only dev keys of IOS-app's scripts/dev/seed-moments-fork.mjs, keccak256("dyorhq-moments-fork-wallet-1..3"):
#   derived from public labels, for local anvil forks only, never funded on mainnet.
PUBLIC_TEST_KEYS="($(echo \
  ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
  5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a \
  7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6 \
  47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a \
  8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba \
  92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e \
  4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356 \
  dbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97 \
  2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 \
  57bcbb515c0a9835560414863de2a2903e4f195eb93fa071b8d0557608ee952a \
  3470e801c46dde26c5827e7caa3e523b54f026eec2b2d0bbbae6ad2e98179270 \
  130eadc747f9b9e2c55ec6772c90b96a89e3b2890fa0f66ebd35aba462e32dd5 | tr ' ' '|'))"
# A Supabase anon key: a JWT whose payload carries "role":"anon" (base64url in each byte alignment). It is public by
# design (row-level security protects the data), like the sb_publishable_ key the apps ship today.
ANON_JWT='eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*(InJvbGUiOiJhbm9uI|Jyb2xlIjoiYW5vbi|icm9sZSI6ImFub24i)[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*'
# The jwt.io example token ({"sub":"1234567890","name":"John Doe",…}), in any variant of its claims and signature.
EXAMPLE_JWT='eyJ[A-Za-z0-9_-]*\.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lI[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*'
# The example credentials of the AWS documentation.
AWS_EXAMPLES='AKIAIOSFODNN7EXAMPLE|wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
# Well-known public test seed phrases, "|"-separated: the BIP-39 vector for entropy 0x00…1f (DyorKit's Mera tests),
# the anvil/hardhat mnemonic and the all-zero-entropy vector. Low-entropy vectors (repeated words) never count anyway.
PUBLIC_PHRASES="abandon amount liar amount expire adjust cage candy arch gather drum bullet absurd math era live bid rhythm alien crouch range attend journey unaware|test test test test test test test test test test test junk|abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
# Frequent English words: a run of wordlist words in which at least half are among these is a sentence, not a phrase
# (the heuristic keeps only the ones that are BIP-39 words). A random 12-word phrase has ~0.7 of them on average.
COMMON_WORDS=$(echo about above across act action actual add after again against age agree all almost alone also \
  always among amount and any area around ask away back bad base basic because become before begin behind below best \
  better between beyond big both bring build business but call can capital card case cause change check choose city \
  claim clean clear close come common control cost could country course cover create cross current day deal decide \
  describe design detail develop differ direct do does door down during each early easy edge effort either else end \
  enough enjoy enter entire even event ever every exact example exchange exist expect face fact fall family far fast \
  feature fee few field figure file final find fine first fit follow for force form forward found free fresh from \
  front full fun future gain general get give glad goal good great group grow have head health hear heavy help here \
  high hold home hour however human idea if include increase index inside interest into issue item just keep kind \
  know large last late later lead learn leave left less let level life light like limit line link list little live \
  load local long look lot low main major make manage many market may mean media member middle might minute miss \
  mode modify more most move much must name near need never new next nice night no normal not note now number object \
  obvious off offer often okay old on once one only open option or order other our out over own page part pass \
  people perfect place plan please point possible post power present price private problem process produce program \
  project proof proper protect provide public pull purpose put quality question quick quite range rather reach \
  ready real reason recall record reduce regular release remain remember remove report require rest result return \
  review right road room rule run safe same save say school scope screen search second section see seek select self \
  sell send sense service session set setup several share short should show side sign simple since size small so \
  social some something soon sort sound source space speak special spend stand start state stay step still stock stop \
  story strategy stuff subject such suggest supply support sure system table take talk task team tell term test than \
  that the their them then there these they thing think this those though three through ticket time to today \
  together token too top total toward track trade trigger true trust try turn type under unit until up update upon \
  usage use useful user usual valid value very view visit wait want warn watch way wealth web well what when where \
  which while who whole why wide will wish with within without word work world would write wrong year yet you young \
  your)

usage() { sed -n '6,15p' "$0" | sed 's/^# //' >&2; exit 2; }
die() { echo "secret-scan: $*" >&2; exit 2; }

MODE=staged; TARGET=; FORCE=; REPO=; HIST_ARGS=(); CONFIGS=(); MSG_FILE=; REMOTE=; URL=
while [ $# -gt 0 ]; do
  case "$1" in
    --staged) MODE=staged ;;
    --all) MODE=all ;;
    --path) [ $# -ge 2 ] || usage; MODE=path; TARGET=$2; shift ;;
    --pre-push) MODE=push; REMOTE=${2:-}; URL=${3:-}; break ;; # git passes the remote and its URL; refs on stdin
    --history) MODE=history; shift; HIST_ARGS=("$@"); break ;; # the rest are git-log revision arguments
    --commit-msg) [ $# -ge 2 ] || usage; MODE=msg; MSG_FILE=$2; shift ;;
    --config) [ $# -ge 2 ] || usage; [ -f "$2" ] || die "no such config file: $2"
      CONFIGS[${#CONFIGS[@]}]="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;; # absolute: the scan cds
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift ;;
    --install-hook) MODE=install ;;
    --force) FORCE=1 ;;
    *) usage ;;
  esac
  shift
done
[ "$MODE" = history ] && [ ${#HIST_ARGS[@]} -eq 0 ] && HIST_ARGS=(--all)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || TOP=
COMMON=
[ -n "$TOP" ] && COMMON=$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$COMMON" ]; then MAIN=$(cd "$COMMON/.." && pwd); else MAIN="$HOME/Hackathon"; fi
WORDLIST="$SCRIPT_DIR/bip39-english.txt"

# ---------- install the hooks: the tracked .githooks/, set up by install-hooks.sh ----------
if [ "$MODE" = install ]; then
  [ -f "$SCRIPT_DIR/install-hooks.sh" ] || die "install-hooks.sh is missing next to $0"
  exec /bin/bash "$SCRIPT_DIR/install-hooks.sh" ${FORCE:+--force}
fi

# ---------- collect secret values (kept in memory; a value is never echoed or passed as an argument) ----------
V_LABEL=(); V_VAL=(); V_ICASE=()
add_value() { # label value icase — an identical value from another variable just extends the label
  local i=0
  while [ $i -lt ${#V_VAL[@]} ]; do
    if [ "${V_VAL[$i]}" = "$2" ]; then V_LABEL[$i]="${V_LABEL[$i]}, $1"; return; fi
    i=$((i + 1))
  done
  V_LABEL[${#V_LABEL[@]}]=$1; V_VAL[${#V_VAL[@]}]=$2; V_ICASE[${#V_ICASE[@]}]=$3
}
trim() { _T=$1; _T="${_T#"${_T%%[![:space:]]*}"}"; _T="${_T%"${_T##*[![:space:]]}"}"; } # result in $_T (no subshell)
is_public() { case " $PUBLIC_VARS " in *" $1 "*) return 0 ;; esac; return 1; }
add_secret() { # label value — the value plus the other forms it can leak in
  local key
  if [[ $2 =~ $RE_HEX32 ]]; then add_value "$1" "${2#0x}" 1; return; fi
  add_value "$1" "$2" 0
  if [[ $2 =~ $RE_URL ]]; then
    key=${2%%[?#]*}; key=${key%/}; key=${key##*/}
    [ ${#key} -ge 16 ] && add_value "$1 (key part)" "$key" 0
  fi
}

SOURCES=()
load_env() { # file label
  local line name value q
  SOURCES[${#SOURCES[@]}]=$2
  while IFS= read -r line || [ -n "$line" ]; do
    trim "$line"; line=$_T
    case "$line" in ''|'#'*) continue ;; esac
    if [[ $line =~ ^export[[:space:]] ]]; then trim "${line#export}"; line=$_T; fi
    case "$line" in *=*) ;; *) continue ;; esac
    trim "${line%%=*}"; name=$_T
    [[ $name =~ $RE_NAME ]] || continue
    trim "${line#*=}"; value=$_T
    q=${value:0:1}
    if [ "$q" = '"' ] || [ "$q" = "'" ]; then
      value=${value:1}; value=${value%%"$q"*}
    else
      trim "${value%%[[:space:]]#*}"; value=$_T
    fi
    is_public "$name" && continue
    case "$name" in NEXT_PUBLIC_*) [[ $value =~ $RE_HEX32 ]] || continue ;; esac
    [[ $value =~ $RE_ADDRESS ]] && continue
    [ ${#value} -ge 12 ] || continue
    add_secret "$name ($2)" "$value"
  done < "$1"
}
load_xcconfig() { # file label — parsed exactly like ios/scripts/testflight.sh
  local line name value
  SOURCES[${#SOURCES[@]}]=$2
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $RE_XCCONFIG_PARTS ]] || continue
    name=${BASH_REMATCH[1]}
    is_public "$name" && continue
    value=$(printf '%s' "${BASH_REMATCH[3]}" | sed -e 's:[[:space:]]//.*$::' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\$(DYOR_SLASH)/\//g')
    [[ $value =~ $RE_ADDRESS ]] && continue
    [ ${#value} -ge 8 ] || continue
    add_secret "$name ($2)" "$value"
  done < "$1"
}
SEEN_FILES=" "
load_once() { # env|xcconfig file label
  local key
  [ -f "$2" ] || return 0
  key="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
  case "$SEEN_FILES" in *" $key "*) return 0 ;; esac
  SEEN_FILES="$SEEN_FILES$key "
  if [ "$1" = env ]; then load_env "$2" "$3"; else load_xcconfig "$2" "$3"; fi
}
load_dir() { # dir label-prefix — the env files and Secrets.xcconfig of one checkout
  local f
  for f in "$1/.env" "$1"/.env.* "$1/.envrc"; do
    case "$f" in *.example|*.sample|*.template) continue ;; esac
    load_once env "$f" "$2${f##*/}"
  done
  load_once xcconfig "$1/ios/DyorHQ/Config/Secrets.xcconfig" "${2}Secrets.xcconfig"
}

if [ -n "${SECRET_SCAN_ENV:-}${SECRET_SCAN_XCCONFIG:-}" ]; then
  [ -n "${SECRET_SCAN_ENV:-}" ] && load_once env "$SECRET_SCAN_ENV" "$(basename "$SECRET_SCAN_ENV")"
  [ -n "${SECRET_SCAN_XCCONFIG:-}" ] && load_once xcconfig "$SECRET_SCAN_XCCONFIG" "$(basename "$SECRET_SCAN_XCCONFIG")"
else
  load_dir "$MAIN" ""
  [ -n "$TOP" ] && load_dir "$TOP" ""
  # IOS-app's values (the treasury, deployer and API keys) also guard the other repositories on this machine.
  [ -d "$HOME/Hackathon" ] && load_dir "$HOME/Hackathon" "~/Hackathon/"
  IFS=: read -r -a EXTRA <<< "${SECRET_SCAN_EXTRA_SOURCES:-}"
  for dir in "${EXTRA[@]}"; do [ -n "$dir" ] && [ -d "$dir" ] && load_dir "$dir" "$dir/"; done
fi
[ ${#SOURCES[@]} -gt 0 ] || echo "secret-scan: warning — no .env or Secrets.xcconfig found; only the generic patterns are checked." >&2
[ -f "$WORDLIST" ] || echo "secret-scan: warning — $WORDLIST is missing; seed phrases are not checked." >&2

# --repo: everything below runs in that repository, with the values collected above.
if [ -n "$REPO" ]; then
  TOP=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $REPO"
fi
case "$MODE" in
  staged|all|push|history|msg)
    [ -n "$TOP" ] || die "not inside a git repository"
    cd "$TOP" || die "cannot enter $TOP" ;;
esac
[ "$MODE" = push ] && REFS=$(cat) # "<local ref> <local sha> <remote ref> <remote sha>" per ref

# ---------- repository policy: the "@" lines of .leakguard ----------
# Every version that counts (see the header) is read; @public applies when any version has it, @internal and each
# @allow line only when every version has them.
POL_N=0; POL_TEXT=()
pol_add() { # text
  local i=0
  while [ $i -lt $POL_N ]; do [ "${POL_TEXT[$i]}" = "$1" ] && return 0; i=$((i + 1)); done
  POL_TEXT[$POL_N]=$(printf '%s\n' "$1" | tr -d '\r' | sed -n -e 's/^[[:space:]]*\(@[^[:space:]].*\)$/\1/p' |
    sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/ $//')
  POL_N=$((POL_N + 1))
}
pol_file() { [ -f "$1" ] && pol_add "$(cat "$1")"; return 0; }
pol_rev() { local t; t=$(git show "$1:.leakguard" 2>/dev/null) && pol_add "$t"; return 0; }
remote_base() { # remote — the remote's default branch as fetched here, if any
  local r
  git config --get "remote.$1.url" >/dev/null 2>&1 || return 0
  r=$(git symbolic-ref -q "refs/remotes/$1/HEAD" 2>/dev/null)
  [ -n "$r" ] || for r in "refs/remotes/$1/main" "refs/remotes/$1/master" ""; do
    git rev-parse -q --verify "$r" >/dev/null 2>&1 && break
  done
  [ -n "$r" ] && git rev-parse -q --verify "$r^{commit}"
  return 0
}
if [ ${#CONFIGS[@]} -gt 0 ]; then
  for f in "${CONFIGS[@]}"; do pol_file "$f"; done
elif [ -n "$TOP" ]; then
  case "$MODE" in
    staged|msg) pol_rev HEAD; pol_rev "" ;;
    all|history) pol_rev HEAD; pol_file "$TOP/.leakguard" ;;
    path) pol_file "$TOP/.leakguard" ;;
    push)
      while read -r lref lsha rref rsha; do
        case "$lsha" in *[!0]*) pol_rev "$lsha" ;; esac
        case "$rsha" in *[!0]*) git rev-parse -q --verify "$rsha^{commit}" >/dev/null 2>&1 && pol_rev "$rsha" ;; esac
        base=$(remote_base "$REMOTE"); [ -n "$base" ] && pol_rev "$base"
      done <<< "$REFS" ;;
  esac
fi
PUBLIC=; INTERNAL=; ALLOWS=()
if [ $POL_N -gt 0 ]; then
  INTERNAL=1; i=0
  while [ $i -lt $POL_N ]; do
    case $'\n'"${POL_TEXT[$i]}"$'\n' in *$'\n@public\n'*) PUBLIC=1 ;; esac
    case $'\n'"${POL_TEXT[$i]}"$'\n' in *$'\n@internal\n'*) ;; *) INTERNAL= ;; esac
    i=$((i + 1))
  done
  while IFS= read -r line; do
    case "$line" in '@allow '*' '*) ;; *) continue ;; esac
    i=1; ok=1
    while [ $i -lt $POL_N ]; do
      case $'\n'"${POL_TEXT[$i]}"$'\n' in *$'\n'"$line"$'\n'*) ;; *) ok=; break ;; esac
      i=$((i + 1))
    done
    [ -n "$ok" ] && ALLOWS[${#ALLOWS[@]}]=${line#@allow }
  done <<< "${POL_TEXT[0]}"
fi
# Content rules that depend on the repository. The marker is written with a bracket here so this file never carries it.
[ -n "$INTERNAL" ] || add_pattern "internal-document marker (DyorHQ/internal only)" 'dyorhq[:]internal'
[ -n "$PUBLIC" ] && add_pattern "internal audit finding ID (public repository)" \
  '(^|[^A-Za-z0-9_-])(AI|AW|GE|GL|GN|GP|GR|GT|IOSK|IOST|LP|LR|MO|OH|PR|RI|RO|RS|RT|RW|SB|SEC|UI|WEB)-[0-9]+([^0-9A-Za-z_]|$)' \
  '(AI|AW|GE|GL|GN|GP|GR|GT|IOSK|IOST|LP|LR|MO|OH|PR|RI|RO|RS|RT|RW|SB|SEC|UI|WEB)-[0-9]'
HEURISTIC_NAMES="|32-byte hex key in a key-named array|32-byte hex key passed to a key or wallet constructor|32-byte hex key after a key-like name|BIP-39 seed phrase (12+ wordlist words)|"
VALID=()
for e in "${ALLOWS[@]}"; do # an @allow name must be a pattern or heuristic name, never a value from .env
  n=${e#* }; ok=
  case "$HEURISTIC_NAMES" in *"|$n|"*) ok=1 ;; esac
  for p in "${P_NAME[@]}"; do [ "$p" = "$n" ] && ok=1; done
  if [ -n "$ok" ]; then VALID[${#VALID[@]}]=$e
  else echo "secret-scan: warning — .leakguard \"@allow ${e%% *} $n\": no finding has that name; ignored." >&2; fi
done
ALLOWS=(${VALID[@]+"${VALID[@]}"})

# ---------- scanning: every finding is one "location: NAME" line; matched text is never output ----------
report() { echo "$1: $2"; }
values_all() { local i=0; while [ $i -lt ${#V_VAL[@]} ]; do printf '%s\n' "${V_VAL[$i]}"; i=$((i + 1)); done; }
icase_flag() { [ "${V_ICASE[$1]}" = 1 ] && printf '%s' -i; }
mask_public() {
  sed -E -e "s/$PUBLIC_TEST_KEYS/<public test key>/gI" -e "s/$ANON_JWT/<public anon JWT>/g" \
    -e "s/$EXAMPLE_JWT/<public example JWT>/g" -e "s#$AWS_EXAMPLES#<public example key>#g"
}
PATTERN_ARGS=(); i=0
while [ $i -lt ${#P_FAST[@]} ]; do PATTERN_ARGS[${#PATTERN_ARGS[@]}]=-e; PATTERN_ARGS[${#PATTERN_ARGS[@]}]=${P_FAST[$i]}; i=$((i + 1)); done

# Key-shaped literals no fixed pattern describes, as one awk program for every input. MODE is "file" (the lines of the
# file FNAME, or of each file awk is given) or "tagged" (the added lines of a diff, "path<TAB>line<TAB>text"). Prints
# "location: NAME" lines; a matched value never leaves awk.
# Portable awk only (macOS awk, mawk, gawk): no interval expressions, no gawk extensions.
read -r -d '' HEURISTICS_AWK <<'AWK'
BEGIN {
  nbip = 0
  if (WL != "") { while ((getline w < WL) > 0) { bip[w] = 1; nbip++ } close(WL) }
  nphr = split(PHRASES, phr, "|")
  n = split(COMMON, tmp, " ")
  for (i = 1; i <= n; i++) if (tmp[i] in bip) com[tmp[i]] = 1
  H16 = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
  nrun = 0; lastpath = ""; lastln = -2
}
function say(name) { print loc ": " name }
# 1 when h (64 hex digits) is too regular to be a key: fewer than 8 distinct digits (0x000…0, 0x1111…, deadbeef…).
function low_entropy(h,   i, c, seen, n) {
  split("", seen); n = 0
  for (i = 1; i <= 64; i++) { c = substr(h, i, 1); if (!(c in seen)) { seen[c] = 1; if (++n >= 8) return 0 } }
  return 1
}
# 1 when s has a quoted literal of exactly 32 bytes of hex (0x optional).
function has_hex32(s,   h) {
  while (match(s, /["'`](0x)?[0-9a-f]+["'`]/)) {
    h = substr(s, RSTART + 1, RLENGTH - 2); sub(/^0x/, "", h)
    if (length(h) == 64 && !low_entropy(h)) return 1
    s = substr(s, RSTART + RLENGTH)
  }
  return 0
}
# 1 when a quoted 32-byte hex literal is passed to something named like a key or a wallet: privateKeyToAccount("0x…"),
# new Wallet("…"), Account(privateKeyHex: "…"), key = Data(hex: "…"), Account.from_key("…").
function key_call(s,   off, h, pre) {
  off = 0
  while (match(substr(s, off + 1), /["'`](0x)?[0-9a-f]+["'`]/)) {
    h = substr(s, off + RSTART + 1, RLENGTH - 2); sub(/^0x/, "", h)
    if (length(h) == 64 && !low_entropy(h)) {
      pre = substr(s, 1, off + RSTART - 1)
      if (length(pre) > 60) pre = substr(pre, length(pre) - 59)
      if (pre ~ /(^|[^a-z0-9_])(private[a-z0-9_]*|privkey|secret[a-z0-9_]*|signing_?key|signer[a-z0-9_]*|wallet[a-z0-9_]*|from_key|keypair|key|pk|sk)["'` \t]*[(:=][^"'`]*$/) return 1
    }
    off += RSTART + RLENGTH - 1
  }
  return 0
}
# 1 when a 32-byte hex value, quoted or not (0x optional), follows a key-like name within 40 characters on the line:
# `uint256 deployerKey = 0x…;`, `RELAYER_PK=0x…`, `Treasury key: 0x…`, `| Treasury | 0x… |`, `wallet: …`,
# `vm.startBroadcast(0x…)`.
function key_literal(s,   off, st, len, c, p, pre) {
  off = 0
  while (match(substr(s, off + 1), H16 "+")) {
    st = off + RSTART; len = RLENGTH; off = st + len - 1
    if (len != 64) continue
    p = st; c = substr(s, st - 1, 1)
    if (c == "x" && substr(s, st - 2, 1) == "0") { p = st - 2; c = substr(s, st - 3, 1) }
    if (c ~ /[a-z0-9_]/ || substr(s, st + 64, 1) ~ /[g-z_]/) continue # part of a longer word or number
    if (low_entropy(substr(s, st, 64))) continue
    pre = substr(s, 1, p - 1)
    if (length(pre) > 40) pre = substr(pre, length(pre) - 39)
    if (pre ~ /pub(lic)?[_-]?key[a-z0-9_]*["'` \t]*[:=(]?[ \t"'`]*$/) continue # a public key
    if (pre ~ /(key|pk|priv|secret|seed|signer|deployer|owner|treasury|relayer|keeper|operator|wallet|mnemonic|broadcast|vm\.addr|vm\.sign)/) return 1
  }
  return 0
}
function sorted(a, i, j,   k) { for (k = i; k < j; k++) if (!(a[k] < a[k + 1])) return 0; return 1 }
function distinct(a, i, j,   k, n, seen) {
  split("", seen); n = 0
  for (k = i; k <= j; k++) if (!(a[k] in seen)) { seen[a[k]] = 1; n++ }
  return n
}
# A seed phrase: 12+ consecutive BIP-39 words, also across consecutive lines of one file (one word per line, "1. w"
# numbering, "w-w-w", a JSON array), that are not in wordlist order (a copy of the list), at least 10 distinct (test
# vectors repeat words), not a public test phrase and not a sentence (at most half frequent English words). A list of
# individually quoted words only counts at a real phrase length (12, 15, 18, 21 or 24): UI word lists are common.
function flush_seed(   i, joined, k, ncom, allq, ok) {
  if (nrun >= 12) {
    ok = !sorted(run, 1, nrun) && distinct(run, 1, nrun) >= 10
    if (ok) {
      joined = run[1]; for (i = 2; i <= nrun; i++) joined = joined " " run[i]
      for (k = 1; k <= nphr; k++) if (index(joined, phr[k])) ok = 0
      ncom = 0; allq = 1
      for (i = 1; i <= nrun; i++) { if (run[i] in com) ncom++; if (!runq[i]) allq = 0 }
      if (ncom * 2 >= nrun) ok = 0
      if (allq && nrun != 12 && nrun != 15 && nrun != 18 && nrun != 21 && nrun != 24) ok = 0
    }
    if (ok) print runloc ": BIP-39 seed phrase (12+ wordlist words)"
  }
  nrun = 0
}
function seed_words(s,   t, n, i, w, nq, nb, q, tmp) {
  tmp = s; nq = gsub(/["'`][a-z]+["'`]/, "", tmp)
  s = " " s " "
  for (i = 1; i <= nphr; i++) if (index(s, phr[i])) gsub(phr[i], " = ", s)
  gsub(/\\n/, " ", s)
  sub(/^[ \t]*[-*+#>]+[ \t]/, " ", s) # a list bullet
  gsub(/[ \t][0-9]+[.)][ \t]/, " ", s) # list numbers: "1. w", "2) w"
  gsub(/\.[ \t]/, " ", s)
  gsub(/[=:;(){}<>*#+]/, " = ", s) # operators and punctuation end a run
  gsub(/[][ \t"'`,|_\\-]+/, " ", s) # what stands between the words of a phrase
  n = split(s, t, " ")
  nb = 0; for (i = 1; i <= n; i++) if (t[i] in bip) nb++
  q = (nq > 0 && nq >= nb)
  for (i = 1; i <= n; i++) {
    w = t[i]
    if (w ~ /^[0-9]+\.?$/) continue # list numbering
    if (w in bip) { if (!nrun) runloc = loc; nrun++; run[nrun] = w; runq[nrun] = q; continue }
    flush_seed()
  }
}
{
  if (MODE == "tagged") {
    p = index($0, "\t"); path = substr($0, 1, p - 1); rest = substr($0, p + 1)
    p = index(rest, "\t"); ln = substr(rest, 1, p - 1) + 0; text = substr(rest, p + 1)
  } else { path = FNAME != "" ? FNAME : FILENAME; ln = FNR; text = $0 }
  sub(/^\.\//, "", path)
  if (path != lastpath || ln != lastln + 1) { flush_seed(); depth = 0 } # runs and arrays continue on the next line only
  lastpath = path; lastln = ln
  loc = path ":" ln
  s = tolower(text)
  gsub(/\001/, "", s) # NUL bytes of UTF-16 text (the diff reader turns them into \001)
  if (PUBKEYS != "") gsub(PUBKEYS, "<public test key>", s)
  hit = 0
  # An array assigned to a name with key, secret, signer, wallet, seed…: `keys = [`, `signerKeys: string[] = [`.
  if (depth <= 0 && match(s, /[a-z0-9_]*(priv|secret|signer|signing|wallet|mnemonic|seed|key)[a-z0-9_]*[ \t]*(:[^=]*)?[=:][ \t]*\[/)) {
    seg = substr(s, RSTART)
    arrpub = seg ~ /^[a-z0-9_]*pub(lic)?_?key/ # public keys
    if (!arrpub && has_hex32(seg)) { say("32-byte hex key in a key-named array"); hit = 1 }
    depth = gsub(/\[/, "[", seg) - gsub(/\]/, "]", seg)
  } else if (depth > 0) {
    seg = s
    if (!arrpub && has_hex32(seg)) { say("32-byte hex key in a key-named array"); hit = 1 }
    depth += gsub(/\[/, "[", seg) - gsub(/\]/, "]", seg)
  }
  if (!hit && s ~ H16) {
    j = s
    gsub(/["'`][ \t]*\+?[ \t]*["'`]/, "", j) # "0x" + "…" + "…" and "…" "…": one literal
    if (key_call(j)) say("32-byte hex key passed to a key or wallet constructor")
    else if (key_literal(j)) say("32-byte hex key after a key-like name")
  }
  if (nbip) seed_words(s)
}
END { flush_seed() }
AWK
HEURISTICS_WL=
[ -f "$WORDLIST" ] && HEURISTICS_WL=$WORDLIST
heuristics() { # mode label — the text on stdin
  awk -v MODE="$1" -v FNAME="$2" -v WL="$HEURISTICS_WL" -v PHRASES="$PUBLIC_PHRASES" -v PUBKEYS="$PUBLIC_TEST_KEYS" \
    -v COMMON="$COMMON_WORDS" "$HEURISTICS_AWK"
}
# Text files, NUL-separated on stdin, in as few awk runs as xargs needs (starting a process is the slow part). A
# relative name gets "./" first, so awk never reads a name like a=b.ts as a variable assignment.
heuristics_files() {
  while IFS= read -r -d '' f; do case "$f" in /*) printf '%s\0' "$f" ;; *) printf './%s\0' "$f" ;; esac; done |
    xargs -0 -r awk -v MODE=file -v FNAME= -v WL="$HEURISTICS_WL" -v PHRASES="$PUBLIC_PHRASES" \
      -v PUBKEYS="$PUBLIC_TEST_KEYS" -v COMMON="$COMMON_WORDS" "$HEURISTICS_AWK"
}

# A placeholder or a public example, not a secret: the value part of the matched text (after its last "=", "/" or
# ":") names YOUR_…/REPLACE…/EXAMPLE…, or its 32-byte hex has fewer than 8 distinct digits, or a KEY= assignment is a
# public key.
benign() { # matched-text pattern-name
  local h c n=0 r=1
  shopt -s nocasematch
  case "${1##*[=/:]}" in *your*|*replace*|*example*|*changeme*|*change_me*|*placeholder*|*xxxx*|*redacted*|*dummy*) r=0 ;; esac
  case "$2" in "private key assignment (KEY=0x"*) case "$1" in *public*|*pubkey*) r=0 ;; esac ;; esac
  if [ $r = 1 ] && [[ $1 =~ [0-9a-fA-F]{64} ]]; then
    h=${BASH_REMATCH[0]}
    for c in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do [[ $h == *$c* ]] && n=$((n + 1)); done
    [ $n -lt 8 ] && r=0
  fi
  shopt -u nocasematch
  return $r
}
# Line numbers (only) where value i occurs in a file.
value_lines() { grep -naF $(icase_flag "$1") -f <(printf '%s\n' "${V_VAL[$1]}") -- "$2" 2>/dev/null | cut -d: -f1; }
# Every pattern that matches one line of text (already masked), reported at the location. The patterns are tested in
# bash, not with a grep each: starting processes is what makes a scan slow. A placeholder match is skipped and the
# rest of the line is tested again.
report_line() { # location text
  local i=0 t m
  while [ $i -lt ${#P_RE[@]} ]; do
    t=$2
    while [[ $t =~ ${P_RE[$i]} ]]; do
      m=${BASH_REMATCH[0]}
      [ -n "$m" ] || break
      if ! benign "$m" "${P_NAME[$i]}"; then report "$1" "${P_NAME[$i]}"; break; fi
      t=${t#*"$m"}
    done
    i=$((i + 1))
  done
}
scan_file() {
  local i n line
  if [ ${#V_VAL[@]} -gt 0 ] && grep -qaiF -f <(values_all) -- "$1" 2>/dev/null; then
    i=0
    while [ $i -lt ${#V_VAL[@]} ]; do
      for n in $(value_lines $i "$1"); do report "$1:$n" "${V_LABEL[$i]}"; done
      i=$((i + 1))
    done
  fi
  while IFS= read -r line; do report_line "$1:${line%%:*}" "${line#*:}"; done \
    < <(grep -naE "${PATTERN_ARGS[@]}" -- "$1" 2>/dev/null | mask_public)
}

# File names that must never be committed, whatever they contain (scripts/dev/forbidden-paths.sh has the full list).
check_name() { # path [label]
  shopt -s nocasematch
  case "${1##*/}" in
    .env.example|.env.sample|.env.template|.env.*.example|.env.*.sample|.env.*.template|*.env.example|*.env.sample|\
*.env.template|.dev.vars.example|.dev.vars.sample|.dev.vars.template|Secrets.example.xcconfig) ;;
    .env*|*.env|*.env.*|.dev.vars*) report "${2:-$1}" "env file must not be committed" ;;
    Secrets*.xcconfig*) report "${2:-$1}" "Secrets.xcconfig must not be committed" ;;
    AuthKey_*.p8*) report "${2:-$1}" "App Store Connect API key must not be committed" ;;
  esac
  shopt -u nocasematch
}

# ---------- binary files: archives and UTF-16 text ----------
# Recognized by their first bytes, whatever their name. Archive-like names are checked even when git sees text.
ARCHIVE_GLOBS=('*.tar' '*.tgz' '*.tbz2' '*.txz' '*.tar.bz2' '*.tar.xz' '*.tar.zst' '*.zip' '*.ipa' '*.gz' '*.bz2' '*.xz'
  '*.zst' '*.7z' '*.jar' '*.apk' '*.aar' '*.docx' '*.xlsx' '*.pptx' '*.odt' '*.ods' '*.odp' '*.pages' '*.numbers' '*.key')
is_archive_name() { local g; for g in "${ARCHIVE_GLOBS[@]}"; do case "$1" in $g) return 0 ;; esac; done; return 1; }
have() { command -v "$1" >/dev/null 2>&1; }
file_kind() { # file — zip, gzip, bzip2, xz, zstd, 7z, utf16 or nothing
  case "$(od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n')" in
    504b0304*|504b0506*|504b0708*) echo zip ;;
    1f8b*) echo gzip ;;
    425a68*) echo bzip2 ;;
    fd377a585a00) echo xz ;;
    28b52ffd*) echo zstd ;;
    377abcaf271c) echo 7z ;;
    fffe*|feff*) echo utf16 ;;
  esac
}
unpack() { # kind file dir — each extracted file is capped at 256 MB
  (
    ulimit -f 262144
    case "$1" in
      zip|7z)
        if have bsdtar; then bsdtar -xf "$2" -C "$3"
        elif [ "$1" = zip ] && have unzip; then unzip -qq -o "$2" -d "$3"
        else exit 1; fi ;;
      *) # a compressed tar is unpacked, and the decompressed stream itself is always checked too: some tar builds
         # take a single compressed file (a .log.gz) for an archive and unpack nothing from it
        extracted=
        if have bsdtar && bsdtar -tf "$2" >/dev/null 2>&1; then bsdtar -xf "$2" -C "$3" || exit 1; extracted=1
        elif tar -tf "$2" >/dev/null 2>&1; then tar -xf "$2" -C "$3" || exit 1; extracted=1
        fi
        # Written after the unpacking, so an archive entry of the same name cannot replace it.
        if ! { case "$1" in gzip) gzip -dc ;; bzip2) bzip2 -dc ;; xz) xz -dc ;; zstd) zstd -dcq ;; esac < "$2" > "$3/.decompressed-stream"; }; then
          rm -f "$3/.decompressed-stream"
          [ -n "$extracted" ] || exit 1
        fi ;;
    esac
  ) >/dev/null 2>&1
}
DEPTH=0; BLOBS=0
# A binary file: an archive is unpacked and its files checked, UTF-16 text is decoded and checked, anything else
# (an image, a compiled file) is left to the value and pattern checks. Each finding is named once per file.
blob_scan() { # label reader… — the reader writes the file's bytes to stdout
  local label=$1 f kind
  shift
  BLOBS=$((BLOBS + 1)); f="$TMP_DIR/blob.$DEPTH.$BLOBS"
  "$@" > "$f" 2>/dev/null || { report "$label" "file that cannot be read for scanning"; rm -f "$f"; return 0; }
  kind=$(file_kind "$f")
  case "$kind" in
    '') ;;
    utf16) # ASCII-range text: drop the NUL bytes and the byte-order mark
      if [ $DEPTH -ge 2 ]; then report "$label" "archive nested too deep to scan"
      elif mkdir "$f.d" && tr -d '\000\376\377' < "$f" > "$f.d/text"; then scan_unpacked "$label (UTF-16 text)" "$f.d"
      else report "$label" "file that cannot be read for scanning"; fi ;;
    *)
      if [ $DEPTH -ge 2 ]; then report "$label" "archive nested too deep to scan"
      elif mkdir "$f.d" && unpack "$kind" "$f" "$f.d"; then scan_unpacked "$label (inside the archive)" "$f.d"
      else report "$label" "compressed archive that cannot be unpacked for scanning"; fi ;;
  esac
  rm -rf "$f" "$f.d"
  return 0
}
scan_unpacked() { # label dir — every finding in the directory, once per name, at the label
  local n
  {
    DEPTH=$((DEPTH + 1))
    find "$2" -type f -print0 | while IFS= read -r -d '' n; do check_name "${n#"$2"/}"; done
    ( scan_tree path "$2" ) || echo "x: contents that could not be scanned"
  } | sed 's/.*: //' | sort -u | while IFS= read -r n; do report "$1" "$n"; done
}

# A fast pass lists the candidate files (NUL-separated); the per-file pass then attributes each hit to a name. The
# heuristics read every text file; binary files go to blob_scan.
scan_tree() { # all | path TARGET
  local f e
  {
    if [ "$1" = all ]; then
      [ ${#V_VAL[@]} -gt 0 ] && git grep -l -z --text -i -F -f <(values_all)
      git grep -l -z --text -E "${PATTERN_ARGS[@]}"
    else
      [ ${#V_VAL[@]} -gt 0 ] && grep -rlaiF --null -f <(values_all) -- "$2"
      grep -rlaE --null "${PATTERN_ARGS[@]}" -- "$2"
    fi
  } 2>/dev/null | sort -zu | while IFS= read -r -d '' f; do scan_file "$f"; done
  if [ "$1" = all ]; then git grep -I -l -z -e ''; else find "$2" -type f -print0 | xargs -0 -r grep -I -l --null -e ''; fi 2>/dev/null |
    heuristics_files
  [ "${PIPESTATUS[1]}" = 0 ] || die "the key and seed-phrase heuristics (awk) failed"
  if [ "$1" = all ]; then
    { git ls-files --eol -z | while IFS= read -r -d '' e; do case "$e" in i/-text*) printf '%s\0' "${e#*$'\t'}" ;; esac; done
      git ls-files -z -- "${ARCHIVE_GLOBS[@]}"; } | sort -zu | while IFS= read -r -d '' f; do blob_scan "$f" cat -- "$f"; done
  else
    find "$2" -type f -print0 | while IFS= read -r -d '' f; do
      if is_archive_name "$f" || [ -n "$(file_kind "$f")" ]; then blob_scan "$f" cat -- "$f"; fi
    done
  fi
  return 0
}

# Added lines of a diff on stdin as "path<TAB>line<TAB>text" ("sha:path" after a `commit <sha>` line of git log); a
# match keeps only path and line. A `+++ ` line is a file name only in a file header (between `diff --git` and the first
# `@@`); inside a hunk it is an added line that starts with "++ ". NUL bytes become \001 first, because awk ends a
# record at a NUL and would drop the rest of the line; a line that is mostly \001 (UTF-16 text) loses them.
added_lines() {
  tr '\000' '\001' | awk '
    /^commit [0-9a-f]+$/ { c = substr($0, 8) ":"; next }
    /^diff --git / { hdr = 1; next }
    hdr && /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); f = c f; next }
    /^@@/ { hdr = 0; match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    !hdr && /^\+/ { t = substr($0, 2); x = t; if (gsub(/\001/, "", x) * 3 > length(t)) t = x; print f "\t" n "\t" t; n++ }'
}
# Commit messages (git log --format="$MSG_FORMAT") on stdin as "sha:(commit message)<TAB>line<TAB>text".
MSG_FORMAT='%x01%h%n%B'
message_lines() {
  awk '/^\001[0-9a-f]+$/ { c = substr($0, 2) ":(commit message)"; n = 0; next } { n++; print c "\t" n "\t" $0 }'
}
tag_message_lines() { # tag-object label — its message as "label:(tag message)<TAB>line<TAB>text", without a signature
  git cat-file tag "$1" 2>/dev/null |
    awk -v L="$2:(tag message)" 'body && /^-----BEGIN [A-Z ]*SIGNATURE-----/ { exit } body { n++; print L "\t" n "\t" $0; next } /^$/ { body = 1 }'
}
pipe_ok() { local s; for s in "$@"; do [ "$s" = 0 ] || return 1; done; return 0; }
DIFF_OPTS=(--no-color --no-ext-diff --no-textconv --text --src-prefix=a/ --dst-prefix=b/ -U0 --diff-filter=ACMRT)
# The added lines and unpacked archives go to a private temporary directory (removed on exit), which every pass reads.
TMP_DIR=
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT
TMP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/secret-scan.XXXXXX") || die "cannot create a temporary directory"
LINES="$TMP_DIR/added"
scan_lines() { # file of added_lines output
  local i p n line rest
  [ -s "$1" ] || return 0
  # One pass over everything first; the per-name passes below only run when something matched.
  if [ ${#V_VAL[@]} -gt 0 ] && grep -qaiF -f <(values_all) -- "$1"; then
    i=0
    while [ $i -lt ${#V_VAL[@]} ]; do
      while IFS=$'\t' read -r p n; do report "$p:$n" "${V_LABEL[$i]}"; done \
        < <(grep -aF $(icase_flag $i) -f <(printf '%s\n' "${V_VAL[$i]}") -- "$1" | cut -f1,2)
      i=$((i + 1))
    done
  fi
  while IFS= read -r line; do
    p=${line%%$'\t'*}; rest=${line#*$'\t'}
    report_line "$p:${rest%%$'\t'*}" "${rest#*$'\t'}"
  done < <(grep -aE "${PATTERN_ARGS[@]}" -- "$1" | mask_public)
  heuristics tagged "" < "$1" || die "the key and seed-phrase heuristics (awk) failed"
}
numstat_binary() { # numstat entries (NUL-separated) on stdin, label prefix, object prefix — names and binary files
  local e a p
  while IFS= read -r -d '' e; do
    a=${e%%$'\t'*}; p=${e#*$'\t'}; p=${p#*$'\t'}
    check_name "$p" "$1$p"
    if [ "$a" = - ] || is_archive_name "$p"; then blob_scan "$1$p" git cat-file blob "$2$p"; fi
  done
}
scan_staged() {
  git diff --cached --no-renames --numstat -z --diff-filter=ACMT | numstat_binary "" ":"
  git diff --cached "${DIFF_OPTS[@]}" | added_lines > "$LINES"
  pipe_ok "${PIPESTATUS[@]}" || die "git diff or the diff reader (awk) failed"
  scan_lines "$LINES"
  return 0
}
scan_message_file() { # a commit message file: its lines up to git's scissors line, without "#" comments
  awk '/^# -+ >8 -+$/ { exit } /^#/ { next } { print "(commit message)\t" NR "\t" $0 }' "$1" > "$LINES" ||
    die "the message reader (awk) failed"
  scan_lines "$LINES"
  return 0
}

# Commits being pushed. git writes "<local ref> <local sha> <remote ref> <remote sha>" per ref on stdin. Every commit
# the remote does not have yet is scanned patch by patch (a merge against its first parent), so a secret that was
# added and removed again inside the push is still caught — it would be in the pushed history. So are the messages of
# those commits and of a pushed annotated tag.
commit_numstat() { # sha — changes of the commit (a merge: against its first parent), NUL-separated
  if git rev-parse -q --verify "$1^" >/dev/null; then git diff-tree -r --no-renames --numstat -z --diff-filter=ACMT "$1^" "$1"
  else git diff-tree -r --root --no-renames --no-commit-id --numstat -z --diff-filter=ACMT "$1"; fi
}
scan_commits() { # git rev-list arguments — names and binary files of every listed commit, then added lines and messages
  local c a
  for c in $(git rev-list "$@"); do commit_numstat "$c" | numstat_binary "${c:0:7}:" "$c:"; done
  git log -p --format='commit %h' --diff-merges=first-parent "${DIFF_OPTS[@]}" "$@" | added_lines > "$LINES"
  pipe_ok "${PIPESTATUS[@]}" || die "git log or the diff reader (awk) failed"
  git log --format="$MSG_FORMAT" "$@" | message_lines >> "$LINES"
  pipe_ok "${PIPESTATUS[@]}" || die "git log or the message reader (awk) failed"
  # Annotated tags named in the arguments, or every one of them with --all / --tags.
  for a in "$@"; do
    case "$a" in
      --all|--tags) git for-each-ref --format='%(objecttype) %(objectname) %(refname:short)' refs/tags |
        while read -r t o n; do [ "$t" = tag ] && tag_message_lines "$o" "$n"; done ;;
      --not) break ;;
      -*|^*|*..*) ;;
      *) [ "$(git cat-file -t "$a" 2>/dev/null)" = tag ] && tag_message_lines "$a" "${a#refs/tags/}" ;;
    esac
  done >> "$LINES"
  scan_lines "$LINES"
  return 0
}
scan_pushed() {
  local lref lsha rref rsha base
  while read -r lref lsha rref rsha; do
    case "$lsha" in *[!0]*) ;; *) continue ;; esac # a deleted ref pushes no commits
    git rev-parse -q --verify "$lsha^{commit}" >/dev/null || die "cannot read the pushed commit for $lref"
    set -- "$lsha"
    case "$lref" in refs/tags/*) [ "$(git cat-file -t "$lsha")" = tag ] && set -- "$lref" ;; esac # its message too
    set -- "$@" --not
    # Only this remote's refs count: a commit on another remote (a private one, a fork) is not on this one yet.
    git config --get "remote.$REMOTE.url" >/dev/null 2>&1 && set -- "$@" --remotes="$REMOTE/*"
    case "$rsha" in *[!0]*) git rev-parse -q --verify "$rsha^{commit}" >/dev/null && set -- "$@" "$rsha" ;; esac
    scan_commits "$@"
  done <<< "$REFS"
  return 0
}

# ---------- self-check: the helpers must find a known fake key and phrase, or nothing is reported clean ----------
self_check() {
  local k c w out
  k=0123456789abcdef; k=$k$k$k$k
  c="DEPLOYER_KEY=0x$k"
  [ -n "$(printf '%s\n' "$c" | grep -aE "${PATTERN_ARGS[@]}" 2>/dev/null)" ] || die "self-check failed: grep -E"
  [ -n "$(report_line canary "$c")" ] || die "self-check failed: bash patterns"
  [ "$(printf 'x\n' | mask_public 2>/dev/null)" = x ] || die "self-check failed: sed -E"
  printf '%s\n' "$c" | grep -qaiF -f <(printf '%s\n' "$k") 2>/dev/null || die "self-check failed: grep -F"
  out=$(printf 'diff --git a/c b/c\n+++ b/c\n@@ -0,0 +1 @@\n+%s\n' "$c" | added_lines 2>/dev/null)
  [ "$out" = "c	1	$c" ] || die "self-check failed: the diff reader (awk)"
  out=$(printf 'c\t1\tconst signerKeys = ["0x%s"];\nc\t3\tuint256 deployerKey = 0x%s;\n' "$k" "$k" | heuristics tagged "" 2>/dev/null)
  case "$out" in *"c:1: 32-byte hex key in a key-named array"*"c:3: 32-byte hex key after a key-like name"*) ;;
    *) die "self-check failed: the key heuristics (awk)" ;; esac
  if [ -n "$HEURISTICS_WL" ]; then
    w=$(awk 'NR % 150 == 7 { print }' "$HEURISTICS_WL" | awk '{ a[NR] = $0 } END { for (i = NR; i > NR - 12; i--) printf "%s ", a[i] }')
    out=$(printf 'c\t1\tphrase = "%s"\n' "$w" | heuristics tagged "" 2>/dev/null)
    [ "$out" = "c:1: BIP-39 seed phrase (12+ wordlist words)" ] || die "self-check failed: the seed-phrase heuristic (awk)"
  fi
}
self_check

# ---------- @allow: reviewed false positives ----------
pmatch() { # path glob — .leakguard glob rules
  case "$2" in
    /*) [[ $1 == ${2#/} ]] ;;
    */*) [[ $1 == $2 ]] ;;
    *) [[ ${1##*/} == $2 ]] ;;
  esac
}
ALLOWED=
filter_allowed() { # findings in OUT — the ones an @allow line covers are dropped and counted in ALLOWED
  local line name loc path e kept=
  [ ${#ALLOWS[@]} -gt 0 ] && [ -n "$OUT" ] || return 0
  shopt -s nocasematch
  while IFS= read -r line; do
    name=${line##*: }; loc=${line%: *}
    path=${loc% (inside the archive)}; path=${path% (UTF-16 text)}
    [[ $path =~ :[0-9]+$ ]] && path=${path%:*}
    case "$MODE" in history|push) [[ $path =~ ^[0-9a-f]{7}: ]] && path=${path#*:} ;; esac
    for e in "${ALLOWS[@]}"; do
      if [ "${e#* }" = "$name" ] && pmatch "$path" "${e%% *}"; then ALLOWED="$ALLOWED$name"$'\n'; continue 2; fi
    done
    kept="$kept$line"$'\n'
  done <<< "$OUT"
  shopt -u nocasematch
  OUT=${kept%$'\n'}
}

case "$MODE" in
  staged)
    WHAT="staged changes"
    OUT=$(scan_staged) || exit 2 ;;
  all)
    WHAT="tracked files in $TOP"
    OUT=$(while IFS= read -r -d '' p; do check_name "$p"; done < <(git ls-files -z); scan_tree all) || exit 2 ;;
  path)
    [ -e "$TARGET" ] || die "no such file or directory: $TARGET"
    WHAT=$TARGET
    OUT=$(scan_tree path "$TARGET") || exit 2 ;;
  push)
    WHAT="commits being pushed"
    OUT=$(scan_pushed) || exit 2 ;;
  history)
    git rev-list -n 1 "${HIST_ARGS[@]}" >/dev/null 2>&1 || die "git log cannot read the revisions: ${HIST_ARGS[*]}"
    WHAT="commits of git log ${HIST_ARGS[*]} in $TOP"
    OUT=$(scan_commits "${HIST_ARGS[@]}") || exit 2 ;;
  msg)
    [ -f "$MSG_FILE" ] || die "no such commit message file: $MSG_FILE"
    WHAT="the commit message"
    OUT=$(scan_message_file "$MSG_FILE") || exit 2 ;;
esac
filter_allowed
if [ -n "$ALLOWED" ]; then
  echo "secret-scan: $(printf '%s' "$ALLOWED" | wc -l | tr -d ' ') finding(s) allowed by .leakguard @allow:" \
    "$(printf '%s' "$ALLOWED" | sort | uniq -c | sed 's/^ *\([0-9]*\) \(.*\)$/\2 ×\1/' | paste -sd ';' - | sed 's/;/; /g')." >&2
fi

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  echo "secret-scan: $(printf '%s\n' "$OUT" | wc -l | tr -d ' ') finding(s) in $WHAT — locations and names only, values are never printed." >&2
  echo "  Take the value out (keep it server-side or in an ignored env file) and rotate it if it was ever shared." >&2
  echo "  A reviewed false positive gets an \"@allow <path glob> <finding name>\" line in .leakguard, committed on its own." >&2
  exit 1
fi
echo "secret-scan: clean — $WHAT (${#V_VAL[@]} secret value forms from ${SOURCES[*]:-no env files}, ${#P_RE[@]} patterns + seed-phrase and key-literal checks)." >&2
exit 0
