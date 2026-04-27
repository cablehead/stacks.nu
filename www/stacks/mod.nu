# Builders for the stacks event protocol.
#
# Each builder returns a "frame request" record:
#   {topic: <string>, ttl: <"forever"|"ephemeral">, meta: <record>, body?: <any>}
#
# Pipe it into `append` to write to xs:
#   stack add "Inbox" --sort auto | send
#   "hello" | clip add $sid --mime-type text/plain | send
#
# Or read the record directly if you just need the protocol shape:
#   stack update $id --name "Renamed" | get meta
#   # => {id: <id>, name: "Renamed"}
#
# All builders are pure (no store access). `append` is the only side effect.

# --- stacks ------------------------------------------------------------------

export def "stack add" [
  name: string
  --sort: string = "auto"   # "auto" | "manual"
]: nothing -> record {
  {topic: "stack.add" ttl: "forever" meta: {name: $name sort: $sort}}
}

export def "stack update" [
  id: string
  --name: string
  --sort: string             # "auto" | "manual"
]: nothing -> record {
  mut meta = {id: $id}
  if $name != null { $meta = $meta | upsert name $name }
  if $sort != null { $meta = $meta | upsert sort $sort }
  {topic: "stack.update" ttl: "forever" meta: $meta}
}

export def "stack delete" [id: string]: nothing -> record {
  {topic: "stack.delete" ttl: "forever" meta: {id: $id}}
}

# Selection: id wins over --down/--up. At least one must be supplied.
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
export def "clip add" [
  stack_id: string
  --mime-type: string = "text/plain"
  --position: string         # fractional index; only honored when stack sort=manual
]: any -> record {
  let body = $in
  mut meta = {stack_id: $stack_id mime_type: $mime_type}
  if $position != null { $meta = $meta | upsert position $position }
  {topic: "clip.add" ttl: "forever" meta: $meta body: $body}
}

# Move a clip across stacks and/or reposition. At least one of
# --to-stack / --position is required.
export def "clip move" [
  id: string
  --to-stack: string
  --position: string
]: nothing -> record {
  if $to_stack == null and $position == null {
    error make {msg: "clip move needs --to-stack and/or --position"}
  }
  mut meta = {id: $id}
  if $to_stack != null { $meta = $meta | upsert stack_id $to_stack }
  if $position != null { $meta = $meta | upsert position $position }
  {topic: "clip.move" ttl: "forever" meta: $meta}
}

export def "clip delete" [id: string]: nothing -> record {
  {topic: "clip.delete" ttl: "forever" meta: {id: $id}}
}

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
