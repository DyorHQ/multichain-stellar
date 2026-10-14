# ios/Integration

The app side of the Stellar network switch no longer lives here as a patch. Since the owner's decision of 2026-10-14,
this repository holds a copy of the public DyorHQ app under [`app/`](../../app) (a git subtree of DyorHQ/IOS-app,
squashed), and the Stellar code is committed there directly:

- `app/ios/DyorHQ/Lite/`: the Stellar screens, every file wholly inside `#if STELLAR_LITE`;
- the `#if STELLAR_LITE` hooks in the app's existing files (`docs/INTEGRATION-ios.md` §2 lists them);
- `app/ios/Internal/`: the internal project (`generate.py`, which finds the packages in this repository's
  `ios/Packages`), its resources and the checks that keep the App Store build equal to the public app
  (`check-build23.py`, `check-lite-strings.py`, `check-copies.py`; their README is
  [`app/ios/Internal/README.md`](../../app/ios/Internal/README.md)).

Nothing from the app copy is pushed to the public repository.

## Taking a newer public app

```sh
scripts/app-subtree-pull.sh <public app checkout> <branch>     # e.g. a checkout of DyorHQ/IOS-app, release/25
```

It runs `git subtree pull --prefix=app --squash` on a clean working tree and prints only the conflicts, if there are
any. Conflicts can only be in the hooked files, around their `#if STELLAR_LITE` blocks; `Lite/` and `Internal/` aren't
in the public app. After the merge it runs `check-build23.py` against the new snapshot and `check-copies.py`, which
names every Stellar copy whose Monad source changed upstream and needs re-syncing.

The patch that used to be here (`network-switch.patch`, the commits of IOS-app's `lite/network-switch` on build 23)
is gone: the same commits are in `app/`, and git's history keeps the file.
