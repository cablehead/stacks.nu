<h1>stacks.nu</h1>

Event-sourced clipboard stacks.
[xs](https://github.com/cablehead/xs) for the log,
[http-nu](https://github.com/cablehead/http-nu) for the routes,
[Datastar](https://data-star.dev) for the UI.

The page holds no state. Selection, compose mode, the visible HTML -- all
projected on the server from frames in the event store and patched into
`<main>` over SSE.

https://github.com/user-attachments/assets/10d6b5e8-d6a3-4e4d-ba85-79c7a803b94b

## Run

```sh
http-nu --datastar --store ./store :4777 -w ./www/serve.nu
```

Open <http://localhost:4777>.

## Event protocol

Persistent (the data):

| Topic           | Meta                                          |
| --------------- | --------------------------------------------- |
| `stack.add`     | `{name, sort}`                                |
| `stack.update`  | `{id, name?, sort?}`                          |
| `stack.delete`  | `{id}`                                        |
| `clip.add`      | `{stack_id, mime_type, position?}` + body -> CAS |
| `clip.move`     | `{id, stack_id?, position?}`                  |
| `clip.delete`   | `{id}`                                        |

Ephemeral (UI state, broadcast to live subscribers only):

| Topic           | Meta                                |
| --------------- | ----------------------------------- |
| `stack.select`  | `{id}` or `{action: "down"\|"up"}`  |
| `clip.select`   | `{id}` or `{action: "down"\|"up"}`  |
| `compose.open`  | `{stack_id}`                        |
| `compose.close` | `{}`                                |

`sort` is `"auto"` (newest first) or `"manual"` (fractional `position` strings).
A `stack.add` frame's id _is_ the stack id; same for `clip.add`.

## Keys

| Key            | Action                            |
| -------------- | --------------------------------- |
| `j` / `k`      | Next / prev clip                  |
| `Ctrl+J` / `Ctrl+K` | Next / prev stack            |
| `c`            | New clip in current stack         |
| `Cmd+Enter`    | Save (in compose modal)           |
| `Esc`          | Cancel (in compose modal)         |

## Tests

```sh
http-nu eval --store /tmp/test ./www/test.nu
```

The suite covers projection folds, selection cycling, threshold gating, route
roundtrips through xs, and the meta builder shapes.
