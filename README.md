# ex_undercover

Elixir + Rust replacement for `fauxbrowser`, with one deliberate change:

- `fauxbrowser` embedded WireGuard in userspace via gVisor
- `ex_undercover` uses kernel WireGuard managed from Elixir through `wireguardex`

The transport side is still browser-oriented:

- latest Chrome profile selection
- TLS + HTTP/2 fingerprinting in a Rustler NIF
- escalation path to a real Chrome solver when antibot protection requires it
- file-backed profile store for version bumps
- optional custom CA bundle install path

## Scope

This scaffold preserves the useful subsystem split from the Go project while
moving the implementation boundary to idiomatic Elixir + Rust:

1. Elixir owns orchestration, supervision, profile selection, WireGuard device management, and solver policy.
2. Rust owns the browser transport and wire-level impersonation.
3. The operating system owns packet routing through the kernel WireGuard interface.

## Key decision

Do not rebuild fauxbrowser's userspace tunnel stack here.

The Elixir process should:

- create and configure a kernel `wg` interface with `wireguardex`
- optionally attach an `fwmark`
- rely on system routing/policy routing for egress

The Rust NIF should:

- open ordinary outbound sockets
- impersonate Chrome at the TLS + HTTP/2 layer
- remain unaware of WireGuard internals

## Project layout

- [lib/ex_undercover.ex](./lib/ex_undercover.ex): public API
- [lib/ex_undercover/client.ex](./lib/ex_undercover/client.ex): Elixir-side request path
- [lib/ex_undercover/profile/chrome_147.ex](./lib/ex_undercover/profile/chrome_147.ex): browser profile registry
- [lib/ex_undercover/profile/store.ex](./lib/ex_undercover/profile/store.ex): JSON-backed profile store
- [lib/ex_undercover/wire_guard/manager.ex](./lib/ex_undercover/wire_guard/manager.ex): kernel WireGuard lifecycle
- [lib/ex_undercover/solver/chrome.ex](./lib/ex_undercover/solver/chrome.ex): escalation boundary for real browser solving
- [lib/ex_undercover/nif.ex](./lib/ex_undercover/nif.ex): Rustler boundary
- [native/ex_undercover_nif/src/lib.rs](./native/ex_undercover_nif/src/lib.rs): native transport crate
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md): migration map from `fauxbrowser`

## Current target profile

`chrome_latest` is currently pinned to Chrome `147`, based on the official
stable release update published on April 15, 2026.

## What is implemented

- proper Mix application scaffold
- Elixir request/response structs
- versioned browser profile registry
- kernel WireGuard manager wrapper around `wireguardex`
- Linux policy routing helper for `fwmark`/routing-table based egress control
- antibot response classification and solver escalation orchestration
- host-level rotation/debounce coordinator for future peer swapping
- Rustler NIF boundary with request/profile entry points
- native request-plan builder for profile/header inspection
- BoringSSL-backed browser transport via `wreq` inside the Rust NIF
- Chrome 147 TLS + HTTP/2 profile wiring
- file-backed `priv/profiles/*.json` profile loading with `chrome_latest` alias file
- profile maintenance tasks:
  `mix ex_undercover.export_profile`
  `mix ex_undercover.import_profile`
  `mix ex_undercover.set_latest`
- custom CA bundle install path:
  `mix ex_undercover.install_ca_bundle path/to/roots.pem`
- real Chrome CDP solver path for cookie extraction after challenge escalation
- real Chrome update/capture tasks:
  `mix ex_undercover.capture_tls_clienthello`
  `mix ex_undercover.verify_solver_alignment`
  `mix ex_undercover.capture_update_bundle`
- `tls.peet.ws` verification task:
  `mix ex_undercover.verify_peet`

## What is intentionally not implemented yet

- policy routing / firewall setup around the WireGuard interface
- profile capture pipeline from a live Chrome binary
- automatic Chrome-major bump tooling for `chrome_148+`

## Verified fingerprint

Current `chrome_147` transport verifies against `https://tls.peet.ws/api/all`
with:

- `http_version = h2`
- `ja4 = t13d1717h2_5b57614c22b0_3cbfd9057e0d`
- `akamai_fingerprint_hash = 6ea73faa8fc5aac76bded7bd238f6433`

## Solver path

`ExUndercover.Solver.Chrome` now launches real Chrome over CDP, opens a page,
waits, and extracts cookies via `Network.getAllCookies`.

Smoke-tested locally against `tls.peet.ws`:

- browser launch succeeded
- CDP target creation succeeded
- final URL readback succeeded

## Chrome update workflow

Current intended bump flow:

1. `mix ex_undercover.capture_update_bundle`
2. inspect `summary.json` for JA4 / Akamai / header-order drift
3. inspect `clienthello.hex` and `clienthello.json` for raw TLS drift
4. update `priv/profiles/chrome_NNN.json`
5. `mix ex_undercover.set_latest chrome_NNN`
6. rerun:
   `mix ex_undercover.verify_peet`
   `mix ex_undercover.verify_solver_alignment`

## License

This repository is private and not licensed for public use, redistribution, or modification without explicit permission from the repository owner.
