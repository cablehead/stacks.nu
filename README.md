<h1>stacks.nu</h1>

A "clip" manager where a clip can be a README, an image, a random thought,
a JSON dataset. Pipe clips through Nushell pipelines. Built on
[xs](https://github.com/cablehead/xs) for the log,
[http-nu](https://github.com/cablehead/http-nu) for the routes,
[Datastar](https://data-star.dev) for the UI.

The page holds no state. Selection, mode, the visible HTML -- all projected
on the server from frames in the event store and patched into `<main>` over
SSE.

https://github.com/user-attachments/assets/10d6b5e8-d6a3-4e4d-ba85-79c7a803b94b

## Run

```sh
http-nu --datastar --store ./store :4777 -w ./www/serve.nu
```

Open <http://localhost:4777>.

First boot drops in a `Tutorial` stack whose clips walk you through the
keymap; delete it when you're done.

## What's a clip

Any byte sequence with a mime type. Text clips render inline; images render
via `/cas/<hash>` with `Cache-Control: immutable` (identical content across
stacks shares a URL and a cache entry). New mime types fall through to a
generic preview without code changes.

Stacks group clips. Sort modes:

- `auto` -- ordered by activity, newest first. Edits float a clip to the top.
- `manual` -- fractional `position` strings; user-curated order.

## Piping

Press `P` on a clip to open the pipe panel. Type any Nushell pipeline; `$in`
is the clip's body. `Mod+Enter` runs. Result renders below; errors surface
with source excerpts pointing at the offending span.

```nushell
$in | from json | get users | length
str upcase
lines | where {|l| $l =~ "TODO"}
```

History is persisted to the log -- arrow up or start typing to recall.
Implemented via http-nu's `.run` so any change to the Nushell language or
library is immediately available.

## Trash

`clip.delete` and `stack.delete` snapshot what was removed into projection
state. `Shift+T` (or the actions panel) opens the trash; Enter restores.
Deleting a stack with previously-deleted clips inside is handled -- restore
the stack first, then the orphaned clips become restorable.

## Event protocol

Persistent topics (the durable log):

| Topic           | Meta                                                  |
| --------------- | ----------------------------------------------------- |
| `stack.add`     | `{name, sort}`                                        |
| `stack.update`  | `{id, name?, sort?}`                                  |
| `stack.delete`  | `{id}`                                                |
| `stack.restore` | `{target}` (id of the original `stack.delete` frame)  |
| `clip.add`      | `{stack_id, mime_type, position?}` + body -> CAS      |
| `clip.update`  | `{id}` + body -> CAS  (clip identity stays stable)     |
| `clip.patch`    | `{id, stack_id?, position?, mime_type?, ...}`         |
| `clip.delete`   | `{id}`                                                |
| `clip.restore`  | `{target}` (id of the original `clip.delete` frame)   |
| `pipe.command`  | `{source, clip_id}` (pipe history)                    |

A `stack.add` frame's id _is_ the stack id; same for `clip.add`. Stacks are
ordered by recent activity. Prior versions of a clip are reachable by
walking earlier `clip.add`/`clip.update` frames with the same id.

Ephemeral UI signals (selection, mode toggles, transient input, pipe
results) go through http-nu's [Local Bus](https://github.com/cablehead/http-nu#local-bus) --
in-process pub/sub, no persistence, no cross-host wire traffic. The
`/updates` SSE handler interleaves `.cat -f` with `.bus sub` and folds both
through the same projection.

## Keys

Mode-aware. The status bar at the bottom always lists the active mode's
keys; clicking a binding fires the same action a keypress would. `Mod` is
`Cmd` on macOS, `Ctrl` elsewhere (resolved per-request via
`sec-ch-ua-platform` / User-Agent).

Main:

| Key                   | Action                       |
| --------------------- | ---------------------------- |
| `J` / `K`             | Next / prev clip             |
| `Shift+J` / `Shift+K` | Next / prev stack            |
| `N`                   | New clip                     |
| `Shift+N`             | New stack (timestamp name)   |
| `E`                   | Edit selected clip           |
| `P`                   | Pipe selected clip           |
| `R`                   | Rename selected stack        |
| `DEL`                 | Delete selected clip         |
| `Shift+DEL`           | Delete selected stack        |
| `Shift+T`             | Open trash                   |
| `Mod+K`               | Open actions panel           |

Compose / edit / rename / pipe modals: `Mod+Enter` commits, `Esc` cancels.

## Layout

```
www/
  serve.nu             route table + view-model
  projection.nu        pure fold over the event stream
  test.nu              projection + route round-trip tests
  templates/           minijinja templates rendered server-side
  static/              keys.js, action-panel.js, base.css
  stacks/mod.nu        protocol builders (`stack add`, `clip move`, ...)
scripts/
  lint.nu              topiary fmt on every .nu
  check.sh             verify formatted
  shoot-design.sh      screenshot /design and post as a clip
tests-browser/         playwright + system chromium e2e
```

## Tests

```sh
http-nu eval --store /tmp/test ./www/test.nu     # projection + routes
node tests-browser/pipe-history.test.mjs         # browser e2e
```

## Formatting

```sh
nu scripts/lint.nu     # format every .nu via topiary
scripts/check.sh       # verify (exit non-zero if drift)
```
