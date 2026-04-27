# Pure projection over the stacks event stream.
#
# Persistent topics:
#   stack.add    meta: {name, sort}                          frame.id = stack id
#   stack.update meta: {id, name?, sort?}
#   stack.delete meta: {id}
#   clip.add     meta: {stack_id, mime_type, position?}      frame.id = clip id
#   clip.move    meta: {id, stack_id?, position?}
#   clip.delete  meta: {id}
#
# Ephemeral selection topics (TTL=ephemeral; replay window is "live only"):
#   stack.select  meta: {action: "down"|"up"} | {id}
#   clip.select   meta: {action: "down"|"up"} | {id}
#   compose.open  meta: {stack_id}                  # enter compose mode
#   compose.close meta: {}                          # exit compose mode
#   editor.open   meta: {clip_id}                   # enter edit mode
#   editor.close  meta: {}                          # exit edit mode
#
# State shape:
#   {
#     stacks: [{id, name, sort, lastTouched, clips: [{id, hash, mime_type, position}]}]
#     selectedStackId: string|null
#     selectedClipId:  string|null
#     mode:            "main" | "compose" | "edit"
#     composeStackId:  string|null
#     editClipId:      string|null
#     frameId:         string|null   # id of the last frame that produced this state
#   }
#
# `sort` is "auto" or "manual". `sorted-clips` returns a stack's clips in
# render order: auto = id desc (newest first), manual = position asc.

export def empty []: nothing -> record {
  {stacks: [] selectedStackId: null selectedClipId: null mode: "main" composeStackId: null editClipId: null selectionExplicit: false frameId: null}
}

export def sorted-clips [stack: record]: nothing -> list {
  if $stack.sort == "manual" {
    $stack.clips | sort-by {|c| [($c.position? | default "") $c.id]}
  } else {
    $stack.clips | sort-by id | reverse
  }
}

export def apply-frame [state: record, frame: record]: nothing -> record {
  let s = match $frame.topic {
    "stack.add" => (stack-add $state $frame)
    "stack.update" => (stack-update $state $frame)
    "stack.delete" => (stack-delete $state $frame)
    "clip.add" => (clip-add $state $frame)
    "clip.move" => (clip-move $state $frame)
    "clip.delete" => (clip-delete $state $frame)
    "stack.select" => (stack-select $state $frame)
    "clip.select" => (clip-select $state $frame)
    "compose.open" => ($state | update mode "compose" | update composeStackId ($frame.meta?.stack_id?))
    "compose.close" => ($state | update mode "main" | update composeStackId null)
    "editor.open" => ($state | update mode "edit" | update editClipId ($frame.meta?.clip_id?))
    "editor.close" => ($state | update mode "main" | update editClipId null)
    _ => $state
  }
  $s | update frameId ($frame.id? | default $s.frameId)
}

# Apply default selection (first stack, first clip) when nothing is selected
# or when current selection has been deleted. Idempotent.
export def reconcile-selection []: record -> record {
  let state = $in
  # Default selection follows render order: most-recently-touched first.
  let stack_ids = $state.stacks | sort-by lastTouched | reverse | get id
  # Until the user explicitly picks a stack (via stack.select), the cursor
  # tracks the most-active stack. Once they have, we preserve their choice
  # and only fall back to the top when it's no longer valid.
  let sel_stack = if (not $state.selectionExplicit) {
    $stack_ids | get -i 0
  } else if ($state.selectedStackId in $stack_ids) {
    $state.selectedStackId
  } else {
    $stack_ids | get -i 0
  }
  if $sel_stack == null {
    return ($state | update selectedStackId null | update selectedClipId null)
  }
  let stack = $state.stacks | where id == $sel_stack | first
  let clips = sorted-clips $stack
  let clip_ids = $clips | get id
  let sel_clip = if ($state.selectedClipId in $clip_ids) {
    $state.selectedClipId
  } else {
    $clip_ids | get -i 0
  }
  $state | update selectedStackId $sel_stack | update selectedClipId $sel_clip
}

def stack-add [state: record, frame: record] {
  let stack = {
    id: $frame.id
    name: ($frame.meta?.name? | default "Untitled")
    sort: ($frame.meta?.sort? | default "auto")
    clips: []
    lastTouched: $frame.id
  }
  $state | update stacks ($state.stacks | append $stack)
}

def stack-update [state: record, frame: record] {
  let id = $frame.meta.id
  let patch = $frame.meta | reject id
  let stacks = $state.stacks | each {|s|
    if $s.id == $id { $s | merge $patch | update lastTouched $frame.id } else { $s }
  }
  $state | update stacks $stacks
}

def stack-delete [state: record, frame: record] {
  let id = $frame.meta.id
  $state | update stacks ($state.stacks | where id != $id)
}

def clip-add [state: record, frame: record] {
  let stack_id = $frame.meta.stack_id
  let clip = {
    id: $frame.id
    hash: ($frame.hash?)
    mime_type: ($frame.meta?.mime_type? | default "text/plain")
    position: ($frame.meta?.position?)
  }
  let stacks = $state.stacks | each {|s|
    if $s.id == $stack_id {
      $s | update clips ($s.clips | append $clip) | update lastTouched $frame.id
    } else {
      $s
    }
  }
  # In auto-sort stacks, a new clip is the new top -- bump selection to it
  # when it lands in the currently-selected stack.
  let target = $stacks | where id == $stack_id | get -i 0
  let bump = ($target != null) and ($target.sort == "auto") and ($state.selectedStackId == $stack_id)
  if $bump {
    $state | update stacks $stacks | update selectedClipId $frame.id
  } else {
    $state | update stacks $stacks
  }
}

def clip-move [state: record, frame: record] {
  let clip_id = $frame.meta.id
  let new_stack_id = $frame.meta?.stack_id?
  let new_position = $frame.meta?.position?

  let owners = $state.stacks | where ($it.clips | any {|c| $c.id == $clip_id })
  if ($owners | is-empty) { return $state }
  let current = $owners | first
  let clip = $current.clips | where id == $clip_id | first
  let target_id = $new_stack_id | default $current.id
  let moved = if $new_position != null {
    $clip | update position $new_position
  } else {
    $clip
  }

  let stacks = $state.stacks | each {|s|
    let stripped = $s | update clips ($s.clips | where id != $clip_id)
    let was_source = ($s.id == $current.id)
    let is_target = ($s.id == $target_id)
    if $is_target {
      $stripped | update clips ($stripped.clips | append $moved) | update lastTouched $frame.id
    } else if $was_source {
      $stripped | update lastTouched $frame.id
    } else {
      $stripped
    }
  }
  $state | update stacks $stacks
}

def clip-delete [state: record, frame: record] {
  let clip_id = $frame.meta.id
  let owner_id = $state.stacks
    | where ($it.clips | any {|c| $c.id == $clip_id })
    | get -i 0
    | get -i id
  let stacks = $state.stacks | each {|s|
    let cleaned = $s | update clips ($s.clips | where id != $clip_id)
    if $s.id == $owner_id { $cleaned | update lastTouched $frame.id } else { $cleaned }
  }
  $state | update stacks $stacks
}

# Cycle by `action`, jump by `id`.
def cycle [ids: list, current: any, action: string]: nothing -> any {
  if ($ids | is-empty) { return null }
  let n = $ids | length
  let idx = $ids | enumerate | where item == $current | get index.0?
  let cur = $idx | default 0
  match $action {
    "down" => ($ids | get (($cur + 1) mod $n))
    "up" => ($ids | get (($cur - 1 + $n) mod $n))
    _ => $current
  }
}

def stack-select [state: record, frame: record] {
  # Cycle in the same order the UI renders: most-recently-touched first.
  let stack_ids = $state.stacks | sort-by lastTouched | reverse | get id
  let new_id = if ($frame.meta?.id? != null) {
    if ($frame.meta.id in $stack_ids) { $frame.meta.id } else { $state.selectedStackId }
  } else {
    cycle $stack_ids $state.selectedStackId ($frame.meta?.action? | default "")
  }
  # Switching stacks resets clip selection to that stack's first clip.
  let stack = $state.stacks | where id == $new_id | get -i 0
  let first_clip = if $stack == null { null } else { sorted-clips $stack | get id | get -i 0 }
  $state
    | update selectedStackId $new_id
    | update selectedClipId $first_clip
    | update selectionExplicit true
}

def clip-select [state: record, frame: record] {
  let stack = $state.stacks | where id == $state.selectedStackId | get -i 0
  if $stack == null { return $state }
  let clip_ids = sorted-clips $stack | get id
  let new_id = if ($frame.meta?.id? != null) {
    if ($frame.meta.id in $clip_ids) { $frame.meta.id } else { $state.selectedClipId }
  } else {
    cycle $clip_ids $state.selectedClipId ($frame.meta?.action? | default "")
  }
  $state | update selectedClipId $new_id
}

# Fold a list of frames into final state, with selection reconciled. Pure.
export def project []: list -> record {
  reduce -f (empty) {|frame, acc| apply-frame $acc $frame } | reconcile-selection
}

# Streaming projection. Buffers silently until xs.threshold; emits the state
# at threshold (with default selection applied) and on every subsequent frame.
export def project-stream []: any -> any {
  generate {|frame, state|
    if $frame.topic == "xs.threshold" {
      let reconciled = $state.value | reconcile-selection
      let next = {value: $reconciled live: true}
      return {next: $next out: $reconciled}
    }
    # Heartbeats and other system noise: don't re-render.
    if ($frame.topic | str starts-with "xs.") {
      return {next: $state}
    }
    let new_value = apply-frame $state.value $frame | reconcile-selection
    let next = {value: $new_value live: $state.live}
    if $state.live {
      {next: $next out: $new_value}
    } else {
      {next: $next}
    }
  } {value: (empty) live: false}
}
