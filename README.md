<h1>stacks.nu</h1>

Event-sourced clipboard stacks.
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

## Event protocol

Persistent (the data):

| Topic          | Meta                                              |
| -------------- | ------------------------------------------------- |
| `stack.add`    | `{name, sort}`                                    |
| `stack.update` | `{id, name?, sort?}`                              |
| `stack.delete` | `{id}`                                            |
| `clip.add`     | `{stack_id, mime_type, position?}` + body -> CAS  |
| `clip.update`  | `{id}` + body -> CAS  (clip identity stays)       |
| `clip.move`    | `{id, stack_id?, position?}`                      |
| `clip.delete`  | `{id}`                                            |

Ephemeral (UI state, broadcast to live subscribers only):

| Topic           | Meta                                |
| --------------- | ----------------------------------- |
| `stack.select`  | `{id}` or `{action: "down"\|"up"}`  |
| `clip.select`   | `{id}` or `{action: "down"\|"up"}`  |
| `compose.open`  | `{stack_id}`                        |
| `compose.close` | `{}`                                |
| `editor.open`   | `{clip_id}`                         |
| `editor.close`  | `{}`                                |

A `stack.add` frame's id _is_ the stack id; same for `clip.add`. `sort` is
`"auto"` (clips ordered by activity, newest first) or `"manual"` (fractional
`position` strings). Edits use `clip.update` -- the clip id stays stable;
prior content is reachable by walking earlier `clip.add`/`clip.update` frames
with the same id. Stacks are ordered by recent activity (any event touching
the stack or its clips).

## Keys

Bindings are mode-aware -- the status bar at the bottom always lists the
active mode's keys; clicking a binding fires the same action a keypress would.

Main mode:

| Key                 | Action            |
| ------------------- | ----------------- |
| `J` / `K`           | Next / prev clip  |
| `Shift+J` / `Shift+K` | Next / prev stack |
| `N`                 | New clip          |
| `Shift+N`           | New stack (timestamp name) |
| `E`                 | Edit selected clip |

Compose / edit modal:

| Key         | Action |
| ----------- | ------ |
| `Cmd+Enter` | Save   |
| `Esc`       | Cancel |

## Tests

```sh
http-nu eval --store /tmp/test ./www/test.nu
```

Covers projection folds, selection cycling, threshold gating, route
roundtrips through xs, and the meta builder shapes.

## Screenshots

```sh
HOST=http://localhost:4777 scripts/shoot.py
```

Bakes posed screenshots into `www/static/shots/` (gitignored). View the
catalog at <http://localhost:4777/shots>. Each filename is a slug
(`main-rest`, `main-hover-edit-clip`, `compose-rest`) that doubles as the
caption in the grid.
