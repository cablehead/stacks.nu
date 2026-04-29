# Builders for the stacks event protocol.
#
# Each builder returns a "frame request" record:
#   {topic: <string>, ttl: <"forever"|"ephemeral">, meta: <record>, body?: <any>}
#
# Pipe it into `send` to write to xs:
#   stack add "Inbox" --sort auto | send
#   "hello" | clip add $sid --mime-type text/plain | send
#
# All builders are pure (no store access). `send` is the only side effect.

# Merge non-null fields from `opts` into the input record. Keeps the optional-
# flag pattern declarative -- callers list every flag once instead of guarding
# each with `if $x != null { upsert ... }`.
def merge-some [opts: record]: record -> record {
  let base = $in
  $opts
  | items {|k, v| {key: $k value: $v}}
  | where value != null
  | reduce -f $base {|it, acc| $acc | upsert $it.key $it.value}
}

# --- stacks ------------------------------------------------------------------

@example "Build a stack.add frame request" {
  stack add "Inbox" --sort manual
} --result {topic: "stack.add" ttl: "forever" meta: {name: "Inbox" sort: "manual"}}
export def "stack add" [
  name: string
  --sort: string = "auto"   # "auto" | "manual"
]: nothing -> record {
  {topic: "stack.add" ttl: "forever" meta: {name: $name sort: $sort}}
}

@example "stack.update with only the fields you set" {
  stack update "s1" --name "Renamed"
} --result {topic: "stack.update" ttl: "forever" meta: {id: "s1" name: "Renamed"}}
export def "stack update" [
  id: string
  --name: string
  --sort: string             # "auto" | "manual"
]: nothing -> record {
  let meta = {id: $id} | merge-some {name: $name sort: $sort}
  {topic: "stack.update" ttl: "forever" meta: $meta}
}

@example "stack.delete by id" {
  stack delete "s1"
} --result {topic: "stack.delete" ttl: "forever" meta: {id: "s1"}}
export def "stack delete" [id: string]: nothing -> record {
  {topic: "stack.delete" ttl: "forever" meta: {id: $id}}
}

# Selection: id wins over --down/--up. At least one must be supplied.
@example "Select a specific stack by id" {
  stack select "s1"
} --result {topic: "stack.select" ttl: "ephemeral" meta: {id: "s1"}}
@example "Cycle to the next stack" {
  stack select --down
} --result {topic: "stack.select" ttl: "ephemeral" meta: {action: "down"}}
export def "stack select" [
  id?: string
  --down
  --up
]: nothing -> record {
  let meta = if $id != null { {id: $id} } else if $down { {action: "down"} } else if $up { {action: "up"} } else { error make {msg: "stack select needs an id or --down/--up"} }
  {topic: "stack.select" ttl: "ephemeral" meta: $meta}
}

# --- clips -------------------------------------------------------------------


# Body bytes (piped in) become the clip's content; xs CAS-stores them.
@example "Add a clip to a stack" {
  "hello" | clip add "s2" --mime-type "text/plain" --position "am"
} --result {topic: "clip.add" ttl: "forever" meta: {stack_id: "s2" mime_type: "text/plain" position: "am"} body: "hello"}
@example "clip.add with defaults" {
  clip add "s2"
} --result {topic: "clip.add" ttl: "forever" meta: {stack_id: "s2" mime_type: "text/plain"} body: null}
export def "clip add" [
  stack_id: string
  --mime-type: string = "text/plain"
  --position: string         # fractional index; only honored when stack sort=manual
]: any -> record {
  let body = $in
  let meta = {stack_id: $stack_id mime_type: $mime_type} | merge-some {position: $position}
  {topic: "clip.add" ttl: "forever" meta: $meta body: $body}
}

# Move a clip across stacks and/or reposition. At least one of
# --to-stack / --position is required.
@example "Move a clip to another stack at a position" {
  clip move "c1" --to-stack "s2" --position "z"
} --result {topic: "clip.patch" ttl: "forever" meta: {id: "c1" stack_id: "s2" position: "z"}}
@example "Reposition a clip without changing stack" {
  clip move "c1" --position "n"
} --result {topic: "clip.patch" ttl: "forever" meta: {id: "c1" position: "n"}}
export def "clip move" [
  id: string
  --to-stack: string
  --position: string
]: nothing -> record {
  if $to_stack == null and $position == null {
    error make {msg: "clip move needs --to-stack and/or --position"}
  }
  let meta = {id: $id} | merge-some {stack_id: $to_stack position: $position}
  {topic: "clip.patch" ttl: "forever" meta: $meta}
}

@example "clip.delete by id" {
  clip delete "c1"
} --result {topic: "clip.delete" ttl: "forever" meta: {id: "c1"}}
export def "clip delete" [id: string]: nothing -> record {
  {topic: "clip.delete" ttl: "forever" meta: {id: $id}}
}

@example "Cycle to the previous clip" {
  clip select --up
} --result {topic: "clip.select" ttl: "ephemeral" meta: {action: "up"}}
export def "clip select" [
  id?: string
  --down
  --up
]: nothing -> record {
  let meta = if $id != null { {id: $id} } else if $down { {action: "down"} } else if $up { {action: "up"} } else { error make {msg: "clip select needs an id or --down/--up"} }
  {topic: "clip.select" ttl: "ephemeral" meta: $meta}
}

# --- writer ------------------------------------------------------------------

# Pipe a frame request into the store. Requires the xs store commands
# (`.append`) to be in scope -- i.e. an `http-nu --store ...` context.
export def send []: record -> record {
  let req = $in
  let body = $req.body? | default null
  if $body == null {
    .append $req.topic --meta $req.meta --ttl $req.ttl
  } else {
    $body | .append $req.topic --meta $req.meta --ttl $req.ttl
  }
}
