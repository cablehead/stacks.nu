# Browser tests

End-to-end tests that drive a real chromium against an isolated `http-nu`
instance. Useful for verifying client-side wiring (Datastar bindings, key
handling, fetch chains) that pure-projection tests can't cover.

## Setup

```bash
cd tests-browser && npm install
```

Uses `playwright-core` (no bundled browser) + the system chromium at
`/usr/bin/chromium`.

## Run

From the repo root:

```bash
node tests-browser/pipe-history.test.mjs
```

Each test file spawns its own `http-nu --datastar` on a unique port with
a fresh `mktemp`d store, so tests are isolated from each other and from
the dev server.
