# NX addon template

A minimal, complete [NX](https://nx-panel.org) addon to start from.
It registers with a panel by claim code, receives the panel's signed events,
answers the health check and shows a page with the panel's account count —
nothing of its own yet. Built on
[addon-kit](https://github.com/nx-panel/addon-kit).

| File | What it is |
| --- | --- |
| [`nx-addon.json`](nx-addon.json) | The manifest, at the repository root where the directory and the panel's install wizard read it ([spec](https://github.com/nx-panel/addon-kit/blob/main/SPEC.md)) |
| [`main.go`](main.go) | The program: about a hundred lines on top of the kit |
| [`install.sh`](install.sh) | Install, update or remove on a Linux host — `--method script` (binary + systemd) or `--method docker` (compose) — by hand or by the panel over SSH |
| [`deploy/compose.yml`](deploy/compose.yml) | The compose stack the docker method runs |
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | On a `v*` tag: binaries, checksums, the release and the image `ghcr.io/nx-panel/addon-template`. Then sign the checksums with the manifest's key — `nx-addon sign-sums -key addon.key SHA256SUMS > SHA256SUMS.sig` — and `gh release upload <tag> SHA256SUMS.sig`: the panel installs a release over SSH only when its `install.sh` and binary match them |

## Run it

```sh
NX_OPT_PORT=8090 go run .
# not registered yet — claim code 3F9A1C0B7E21
```

Then on the panel: **Services → Addons → Add**, the addon's address and the
claim code. A panel registers by claim code only a manifest signed by a key
it trusts; for a local try, sign with the development key and run a panel
built with `-tags addondev`:

```sh
go run github.com/nx-panel/addon-kit/cmd/nx-addon sign -dev nx-addon.json > signed.json
NX_MANIFEST_FILE=signed.json go run .
```

An addon nobody signed is registered by hand on the same page.

## Make it yours

1. Change `slug`, `name`, `publisher`, the scopes and events in
   `nx-addon.json`, and `SLUG` / `REPO` / `BIN` at the top of
   `install.sh`.
2. Declare the questions your install needs under `install.options`; the
   answers arrive as `NX_OPT_<KEY>` (`addon.Option("key")`).
3. Keep your own data in your own database; read the panel with the token
   (`panel.Client`). The panel stores nothing of an addon's.
4. To be listed at [addons.nx-panel.org](https://addons.nx-panel.org),
   sign the manifest with your own key (`nx-addon keygen`, `sign`) and
   open a pull request on the directory.

Licensed under the Apache License 2.0.
