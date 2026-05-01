# Pure projection over the stacks event stream.
#
# Persistent topics:
#   stack.add    meta: {name, sort}                          frame.id = stack id
#   stack.update meta: {id, name?, sort?}
#   stack.delete meta: {id}
#   clip.add     meta: {stack_id, mime_type, position?}      frame.id = clip id
#   clip.update  meta: {id}                                   body -> new hash; clip id stays stable
#   clip.patch   meta: {id, stack_id?, position?, mime_type?, ...}  # field merge; stack_id moves
#   clip.delete  meta: {id}
#
# Ephemeral selection topics (TTL=ephemeral; replay window is "live only"):
#   stack.select  meta: {action: "down"|"up"} | {id}
#   clip.select   meta: {action: "down"|"up"} | {id}
#   compose.open  meta: {stack_id}                  # enter compose mode
#   compose.close meta: {}                          # exit compose mode
#   editor.open   meta: {clip_id}                   # enter edit mode
#   editor.close  meta: {}                          # exit edit mode
#   rename.open   meta: {stack_id}                  # enter rename mode
#   rename.close  meta: {}                          # exit rename mode
#   set-mime.open  meta: {clip_id}                  # enter set-mime mode
#   set-mime.close meta: {}                         # exit set-mime mode
#
# State shape:
#   {
#     stacks: [{id, name, sort, lastTouched, clips: [{id, hash, mime_type, position, lastTouched, versions}]}]
#     selectedStackId: string|null
#     selectedClipId:  string|null
#     mode:            "main" | "compose" | "edit" | "rename" | "actions" | "set-mime"
#     composeStackId:  string|null
#     editClipId:      string|null
#     renameStackId:   string|null
#     setMimeClipId:   string|null
#     clipCursors:     {stack_id: clip_id, ...}  # last selected clip per stack
#     frameId:         string|null   # id of the last frame that produced this state
#   }
#
# `sort` is "auto" or "manual". `sorted-clips` returns a stack's clips in
# render order: auto = lastTouched desc (newest activity first, so edits
# float to the top), manual = position asc.

export def empty []: nothing -> record {
  {stacks: [] selectedStackId: null selectedClipId: null mode: "main" composeStackId: null editClipId: null renameStackId: null setMimeClipId: null clipCursors: {} selectionExplicit: false frameId: null deleted: [] selectedDeletedFrameId: null}
}

# Pick the id that occupies the same slot after `removed` is dropped from
# `ids`. Falls back to the last remaining id when the removed one was the
# bottom, and null when nothing remains. Used by stack/clip delete to keep
# the cursor under the user's eye.
def slot-after-removal [ids: list removed: any]: nothing -> any {
  let idx = $ids | enumerate | where item == $removed | get index.0?
  let post = $ids | where {|x| $x != $removed }
  if $idx == null or ($post | is-empty) {
    null
  } else if $idx >= ($post | length) {
    $post | last
  } else {
    $post | get $idx
  }
}

export def sorted-clips [stack: record]: nothing -> list {
  if $stack.sort == "manual" {
    $stack.clips | sort-by {|c| [($c.position? | default "") $c.id] }
  } else {
    $stack.clips | sort-by lastTouched | reverse
  }
}

# Stash the current (stack, clip) selection in clipCursors so a later
# stack switch can restore the per-stack cursor. Idempotent and safe to
# call after every state transition.
def remember-cursor [state: record]: nothing -> record {
  if $state.selectedStackId != null and $state.selectedClipId != null {
    $state | update clipCursors ($state.clipCursors | upsert $state.selectedStackId $state.selectedClipId)
  } else { $state }
}

export def apply-frame [state: record frame: record]: nothing -> record {
  let s = match $frame.topic {
    "stack.add" => (stack-add $state $frame)
    "stack.update" => (stack-update $state $frame)
    "stack.delete" => (stack-delete $state $frame)
    "clip.add" => (clip-add $state $frame)
    "clip.update" => (clip-update $state $frame)
    "clip.patch" => (clip-patch $state $frame)
    "clip.delete" => (clip-delete $state $frame)
    "stack.select" => (stack-select $state $frame)
    "clip.select" => (clip-select $state $frame)
    "compose.open" => ($state | update mode "compose" | update composeStackId ($frame.meta?.stack_id?))
    "compose.close" => ($state | update mode "main" | update composeStackId null)
    "editor.open" => ($state | update mode "edit" | update editClipId ($frame.meta?.clip_id?))
    "editor.close" => ($state | update mode "main" | update editClipId null)
    "rename.open" => ($state | update mode "rename" | update renameStackId ($frame.meta?.stack_id?))
    "rename.close" => ($state | update mode "main" | update renameStackId null)
    "actions.open" => ($state | update mode "actions")
    "actions.close" => ($state | update mode "main")
    "set-mime.open" => ($state | update mode "set-mime" | update setMimeClipId ($frame.meta?.clip_id?))
    "set-mime.close" => ($state | update mode "main" | update setMimeClipId null)
    "trash.open" => ($state | update mode "trash")
    "trash.close" => ($state | update mode "main" | update selectedDeletedFrameId null)
    "deleted.select" => (deleted-select $state $frame)
    "clip.restore" => (clip-restore $state $frame)
    "stack.restore" => (stack-restore $state $frame)
    _ => $state
  }
  remember-cursor $s | update frameId ($frame.id? | default $s.frameId)
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
  let memorized = $state.clipCursors | get -i $sel_stack
  let sel_clip = if ($state.selectedClipId in $clip_ids) {
    $state.selectedClipId
  } else if $memorized != null and ($memorized in $clip_ids) {
    $memorized
  } else {
    $clip_ids | get -i 0
  }
  $state | update selectedStackId $sel_stack | update selectedClipId $sel_clip
}

def stack-add [state: record frame: record] {
  let stack = {
    id: $frame.id
    name: ($frame.meta?.name? | default "Untitled")
    sort: ($frame.meta?.sort? | default "auto")
    clips: []
    lastTouched: $frame.id
  }
  $state | update stacks ($state.stacks | append $stack)
}

def stack-update [state: record frame: record] {
  let id = $frame.meta.id
  let patch = $frame.meta | reject id
  let stacks = $state.stacks | each {|s|
      if $s.id == $id { $s | merge $patch | update lastTouched $frame.id } else { $s }
    }
  $state | update stacks $stacks
}

def stack-delete [state: record frame: record] {
  let id = $frame.meta.id
  let victim = $state.stacks | where id == $id | get -i 0
  let stacks = $state.stacks | where id != $id
  # Preserve cursor position across stacks: if the deleted stack was selected,
  # take whatever now sits in the same slot (render order is lastTouched-desc),
  # falling back to the last stack when the deleted one was the bottom.
  let new_selected = if $state.selectedStackId != $id {
    $state.selectedStackId
  } else {
    let pre = $state.stacks | sort-by lastTouched | reverse | get id
    slot-after-removal $pre $id
  }
  # If we're landing on a different stack, restore its memorized cursor;
  # otherwise leave selectedClipId alone (reconcile will sort it out).
  let new_clip = if $new_selected == null or $new_selected == $state.selectedStackId {
    $state.selectedClipId
  } else {
    let stack = $stacks | where id == $new_selected | get -i 0
    let clip_ids = if $stack == null { [] } else { sorted-clips $stack | get id }
    let memorized = $state.clipCursors | get -i $new_selected
    if $memorized != null and ($memorized in $clip_ids) {
      $memorized
    } else {
      $clip_ids | get -i 0
    }
  }
  # Drop the deleted stack's cursor entry to keep clipCursors tidy.
  let cursors = if ($id in ($state.clipCursors | columns)) {
    $state.clipCursors | reject $id
  } else { $state.clipCursors }
  let deleted = if $victim == null { $state.deleted } else {
    [{frame_id: $frame.id kind: "stack" snapshot: {stack: $victim} deleted_at: $frame.id}] | append $state.deleted
  }
  $state
  | update stacks $stacks
  | update selectedStackId $new_selected
  | update selectedClipId $new_clip
  | update clipCursors $cursors
  | update deleted $deleted
}

def clip-add [state: record frame: record] {
  let stack_id = $frame.meta.stack_id
  let clip = {
    id: $frame.id
    hash: ($frame.hash?)
    mime_type: ($frame.meta?.mime_type? | default "text/plain")
    position: ($frame.meta?.position?)
    lastTouched: $frame.id
    versions: [$frame.id]
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

def clip-update [state: record frame: record] {
  let clip_id = $frame.meta.id
  let new_hash = $frame.hash?
  let stacks = $state.stacks | each {|s|
      if ($s.clips | any {|c| $c.id == $clip_id }) {
        let updated_clips = $s.clips | each {|c|
            if $c.id == $clip_id {
              $c
              | update hash $new_hash
              | update lastTouched $frame.id
              | update versions ([$frame.id] | append $c.versions)
            } else { $c }
          }
        $s | update clips $updated_clips | update lastTouched $frame.id
      } else {
        $s
      }
    }
  $state | update stacks $stacks
}

# clip.patch: field-level merge into a clip's meta. stack_id in the patch
# moves the clip to a different stack (structural). Other fields are merged
# directly. lastTouched only bumps for structural changes (move or position
# update), not for pure metadata patches like mime_type -- those are a
# re-classification, not activity.
def clip-patch [state: record frame: record] {
  let clip_id = $frame.meta.id
  let patch = $frame.meta | reject id

  let owners = $state.stacks | where ($it.clips | any {|c| $c.id == $clip_id })
  if ($owners | is-empty) { return $state }
  let current = $owners | first
  let clip = $current.clips | where id == $clip_id | first

  let target_id = $patch.stack_id? | default $current.id
  # Apply non-structural field updates (everything except stack_id).
  let field_patch = if "stack_id" in ($patch | columns) {
    $patch | reject stack_id
  } else { $patch }
  let patched = $clip | merge $field_patch
  let bump = ($target_id != $current.id) or (($patch.position?) != null)

  let stacks = $state.stacks | each {|s|
      let stripped = $s | update clips ($s.clips | where id != $clip_id)
      let was_source = ($s.id == $current.id)
      let is_target = ($s.id == $target_id)
      if $is_target {
        let next = $stripped | update clips ($stripped.clips | append $patched)
        if $bump { $next | update lastTouched $frame.id } else { $next }
      } else if $was_source {
        if $bump { $stripped | update lastTouched $frame.id } else { $stripped }
      } else {
        $stripped
      }
    }
  $state | update stacks $stacks
}

def clip-delete [state: record frame: record] {
  let clip_id = $frame.meta.id
  let owner = $state.stacks
    | where ($it.clips | any {|c| $c.id == $clip_id })
    | get -i 0
  let owner_id = $owner | get -i id
  let victim = if $owner == null { null } else { $owner.clips | where id == $clip_id | first }
  let stacks = $state.stacks | each {|s|
      let cleaned = $s | update clips ($s.clips | where id != $clip_id)
      if $s.id == $owner_id { $cleaned | update lastTouched $frame.id } else { $cleaned }
    }
  let new_selected = if $owner == null or $state.selectedClipId != $clip_id {
    $state.selectedClipId
  } else {
    slot-after-removal (sorted-clips $owner | get id) $clip_id
  }
  let deleted = if $victim == null { $state.deleted } else {
    [{frame_id: $frame.id kind: "clip" snapshot: {clip: $victim stack_id: $owner_id} deleted_at: $frame.id}] | append $state.deleted
  }
  $state | update stacks $stacks | update selectedClipId $new_selected | update deleted $deleted
}

# Restore a previously-deleted clip. frame.meta.target points at the
# clip.delete frame's id; we read the snapshot out of state.deleted and
# splice the clip back into its original stack.
def clip-restore [state: record frame: record] {
  let target = $frame.meta?.target?
  if $target == null { return $state }
  let entry = $state.deleted | where frame_id == $target | get -i 0
  if $entry == null or $entry.kind != "clip" { return $state }
  let stack_id = $entry.snapshot.stack_id
  let parent_alive = ($state.stacks | any {|s| $s.id == $stack_id })
  if not $parent_alive { return $state }
  let clip = $entry.snapshot.clip
  let stacks = $state.stacks | each {|s|
      if $s.id == $stack_id {
        $s | update clips ($s.clips | append $clip)
      } else { $s }
    }
  let deleted = $state.deleted | where frame_id != $target
  $state | update stacks $stacks | update deleted $deleted
}

def stack-restore [state: record frame: record] {
  let target = $frame.meta?.target?
  if $target == null { return $state }
  let entry = $state.deleted | where frame_id == $target | get -i 0
  if $entry == null or $entry.kind != "stack" { return $state }
  let stack = $entry.snapshot.stack
  let stacks = $state.stacks | append $stack
  let deleted = $state.deleted | where frame_id != $target
  $state | update stacks $stacks | update deleted $deleted
}

def deleted-select [state: record frame: record] {
  let ids = $state.deleted | get frame_id
  let new_id = if ($frame.meta?.id? != null) {
    if ($frame.meta.id in $ids) { $frame.meta.id } else { $state.selectedDeletedFrameId }
  } else {
    cycle $ids $state.selectedDeletedFrameId ($frame.meta?.action? | default "")
  }
  $state | update selectedDeletedFrameId $new_id
}

# Cycle by `action`, jump by `id`. "top" jumps to the first id in render order.
def cycle [ids: list current: any action: string]: nothing -> any {
  if ($ids | is-empty) { return null }
  let n = $ids | length
  let idx = $ids | enumerate | where item == $current | get index.0?
  let cur = $idx | default 0
  match $action {
    "down" => ($ids | get (($cur + 1) mod $n))
    "up" => ($ids | get (($cur - 1 + $n) mod $n))
    "top" => ($ids | first)
    _ => $current
  }
}

def stack-select [state: record frame: record] {
  # Cycle in the same order the UI renders: most-recently-touched first.
  let stack_ids = $state.stacks | sort-by lastTouched | reverse | get id
  let new_id = if ($frame.meta?.id? != null) {
    if ($frame.meta.id in $stack_ids) { $frame.meta.id } else { $state.selectedStackId }
  } else {
    cycle $stack_ids $state.selectedStackId ($frame.meta?.action? | default "")
  }
  # Restore the per-stack cursor when re-entering a stack we've visited
  # before; otherwise default to its first clip in render order.
  let stack = $state.stacks | where id == $new_id | get -i 0
  let clip_ids = if $stack == null { [] } else { sorted-clips $stack | get id }
  let memorized = $state.clipCursors | get -i $new_id
  let target_clip = if $memorized != null and ($memorized in $clip_ids) {
    $memorized
  } else {
    $clip_ids | get -i 0
  }
  $state
  | update selectedStackId $new_id
  | update selectedClipId $target_clip
  | update selectionExplicit true
}

def clip-select [state: record frame: record] {
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
  reduce -f (empty) {|frame acc| apply-frame $acc $frame } | reconcile-selection
}

# Streaming projection. Buffers silently until xs.threshold; emits the state
# at threshold (with default selection applied) and on every subsequent frame.
export def project-stream []: any -> any {
  generate {|frame state|
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
