# ios/Integration

The app side of the network switch lives in `DyorHQ/IOS-app`, branch `lite/network-switch`, on top of `release/23`
(`d387a64`, build 23). This folder keeps it as one patch, for two reasons:

- the work survives in this private repository while that branch is unpushed (IOS-app is public);
- the patch can be re-applied to another base.

```
cd <IOS-app checkout>
git switch -c lite/network-switch <base>
git am --3way <this repository>/ios/Integration/network-switch.patch
```

`network-switch.patch` is `git format-patch --binary --stdout d387a64..lite/network-switch`. Regenerate it after the
branch changes; the first lines of each commit in it name the commit it came from.

On a base other than build 23, any conflicts are in the `#if STELLAR_LITE` hooks of the seven existing files listed in
`docs/INTEGRATION-ios.md` §2. The `ios/DyorHQ/Lite/` and `ios/Internal/` files are new and apply cleanly. Then run the
checks in §8 of that page.

The four drop-in files that used to be here (`ProLiteRoot.swift` and friends) drove the old Pro ⇄ Lite pill
(superseded by DECISIONS #18). Their successors are in the patch.
