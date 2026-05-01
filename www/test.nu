use std/assert

const script_dir = path self | path dirname

use ./projection.nu
use ./stacks *

# Synthetic frames stand in for what xs would emit. Real frames have hash
# populated by xs's CAS; here we leave it null where it doesn't matter.
const FRAMES = [
  {topic: "stack.add" id: "s1" hash: null meta: {name: "Inbox" sort: "auto"}}
  {topic: "stack.add" id: "s2" hash: null meta: {name: "Pinned" sort: "manual"}}
  {topic: "clip.add" id: "c1" hash: "sha256-aaa" meta: {stack_id: "s1" mime_type: "text/plain"}}
  {topic: "clip.add" id: "c2" hash: "sha256-bbb" meta: {stack_id: "s1" mime_type: "text/plain"}}
  {topic: "clip.add" id: "c3" hash: "sha256-ccc" meta: {stack_id: "s2" mime_type: "image/png" position: "a"}}
  {topic: "stack.update" id: "u1" hash: null meta: {id: "s1" name: "Recent"}}
  {topic: "clip.patch" id: "u2" hash: null meta: {id: "c1" stack_id: "s2" position: "am"}}
  {topic: "clip.delete" id: "u3" hash: null meta: {id: "c2"}}
]

print "1. project: end-to-end fold over synthetic frames"
let state = $FRAMES | projection project
assert equal ($state.stacks | length) 2
let s1 = $state.stacks | where id == "s1" | first
assert equal $s1.name "Recent"
assert equal ($s1.clips | length) 0
let s2 = $state.stacks | where id == "s2" | first
assert equal ($s2.clips | length) 2
print "   ok"

print "2. project: selection defaults to first stack / first clip"
# After all FRAMES, s1 is empty and s2 has clips. Projection picks s1 (first
# stack), and selectedClipId is null because s1 has no clips.
assert equal $state.selectedStackId "s1"
assert equal $state.selectedClipId null
print "   ok"

print "3. stack.select cycle: down then up returns to start"
let with_sel = $FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {action: "down"}}
  ] | projection project
assert equal $with_sel.selectedStackId "s2"
# s2 has its original c3 plus the moved c1. sorted-clips for manual sort
# orders by position; c1's position "am" sorts after c3's "a".
assert equal $with_sel.selectedClipId "c3"

let cycled = $FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {action: "down"}}
    {topic: "stack.select" id: "x" hash: null meta: {action: "up"}}
  ] | projection project
assert equal $cycled.selectedStackId "s1"
print "   ok"

print "4. clip.select cycle: within selected stack"
let on_s2 = $FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "s2"}}
    {topic: "clip.select" id: "x" hash: null meta: {action: "down"}}
  ] | projection project
# stack.select to s2 starts on c3 (first by manual position); down -> c1
assert equal $on_s2.selectedClipId "c1"
print "   ok"

print "5. project-stream: silent until xs.threshold; threshold emit has selection"
let stream_input = ($FRAMES | first 2)
  | append [{topic: "xs.threshold"}]
  | append ($FRAMES | skip 2)
let outs = $stream_input | projection project-stream
let at_threshold = $outs | first
# Default tracks lastTouched-desc; s2 was added after s1 with no explicit select.
assert equal $at_threshold.selectedStackId "s2" "threshold emit should pick the most recent stack"
let final = $outs | last
assert equal ($final.stacks | where id == "s2" | first | get clips | length) 2
print "   ok"

print "5a. clip.add into the selected auto stack bumps selection to the new clip"
# After all FRAMES, s1 is empty (sort=auto) with no selected clip.
# Re-select s1 explicitly, then add a new clip -- selection should jump to it.
let bumped = $FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "s1"}}
    {topic: "clip.add" id: "c9" hash: "sha256-zzz" meta: {stack_id: "s1" mime_type: "text/plain"}}
  ] | projection project
assert equal $bumped.selectedClipId "c9" $"auto bump expected c9"

# Manual stack: no bump -- user-curated order isn't disrupted.
let manual = $FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "s2"}}
    {topic: "clip.select" id: "x" hash: null meta: {id: "c3"}}
    {topic: "clip.add" id: "c8" hash: "sha256-yyy" meta: {stack_id: "s2" mime_type: "text/plain" position: "z"}}
  ] | projection project
assert equal $manual.selectedClipId "c3" $"manual should not bump"
print "   ok"

print "5c. stack ordering: lastTouched bumps with clip activity"
# Two stacks created in order s1, s2; then a clip lands in s1 -- s1 should
# now be the most-recently-touched.
let touched = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First" sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "clip.add" id: "a3" hash: "x" meta: {stack_id: "a1" mime_type: "text/plain"}}
] | projection project
assert equal $touched.stacks.0.lastTouched "a3" $"a1.lastTouched should be a3 after the clip.add"
assert equal $touched.stacks.1.lastTouched "a2" "untouched a2 should still hold its add id"

# stack.update also bumps activity.
let renamed_state = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First" sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "stack.update" id: "a4" hash: null meta: {id: "a1" name: "Renamed"}}
] | projection project
assert equal ($renamed_state.stacks | where id == "a1" | first | get lastTouched) "a4" "rename should bump a1"
print "   ok"

print "5e. default selection tracks lastTouched until user picks explicitly"
# (a) startup case: a2 has the most recent activity, so it's the default.
let startup = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First" sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "clip.add" id: "a3" hash: "x" meta: {stack_id: "a2" mime_type: "text/plain"}}
] | projection project
assert equal $startup.selectedStackId "a2" $"expected a2"

# Even though the streaming projection reconciles after every frame and
# would otherwise pin selection to the first stack added.
let stream_result = $startup
# mimic project-stream's per-frame reconcile by feeding through xs.threshold
# This case is covered by the project test above; this assertion is a sanity
# check that the default is recomputed.
assert (not $stream_result.selectionExplicit) "no user select event yet"

# (b) once the user explicitly picks a1, it sticks even if a2 gets fresh activity.
let explicit = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First" sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "stack.select" id: "u1" hash: null meta: {id: "a1"}}
  {topic: "clip.add" id: "a3" hash: "x" meta: {stack_id: "a2" mime_type: "text/plain"}}
] | projection project
assert equal $explicit.selectedStackId "a1" $"explicit pick should stick"
assert $explicit.selectionExplicit
print "   ok"

print "5d. stack.select cycle follows lastTouched order, not insertion order"
# a1, a2 created; clip lands in a1 -> a1 is newest. Selection starts on a1
# (the rendered top). Pressing 'down' should land on a2 (next in render order),
# not on a1 (insertion-order next-after-a1).
let cycled = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First" sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "clip.add" id: "a3" hash: "x" meta: {stack_id: "a1" mime_type: "text/plain"}}
  {topic: "stack.select" id: "a4" hash: null meta: {action: "down"}}
] | projection project
assert equal $cycled.selectedStackId "a2" $"cycle should follow render order"
print "   ok"

print "5g. clip.update swaps hash, bumps clip+stack lastTouched, records versions"
let edited = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "X" sort: "auto"}}
  {topic: "clip.add" id: "c1" hash: "h1" meta: {stack_id: "a1" mime_type: "text/plain"}}
  {topic: "clip.update" id: "u1" hash: "h2" meta: {id: "c1"}}
] | projection project
let stack = $edited.stacks | first
let live_clip = $stack.clips | first
assert equal $live_clip.id "c1" "clip identity is stable across edits"
assert equal $live_clip.hash "h2" $"hash should track the latest update"
assert equal $live_clip.lastTouched "u1" "edit bumps clip lastTouched"
assert equal $live_clip.versions (["u1" "c1"]) "versions list is most-recent-first"
assert equal $stack.lastTouched "u1" "edit bumps the stack's lastTouched"

# Render order in auto-sort follows clip lastTouched, so an edit floats
# the older clip above a newer-but-untouched one.
let two = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "X" sort: "auto"}}
  {topic: "clip.add" id: "c1" hash: "h1" meta: {stack_id: "a1" mime_type: "text/plain"}}
  {topic: "clip.add" id: "c2" hash: "h2" meta: {stack_id: "a1" mime_type: "text/plain"}}
  {topic: "clip.update" id: "u9" hash: "h1b" meta: {id: "c1"}}
] | projection project
let order = projection sorted-clips ($two.stacks | first) | get id
assert equal $order (["c1" "c2"]) $"edited c1 should bubble above c2 in auto-sort"
print "   ok"

print "5k. switching stacks restores the per-stack cursor"
# Three stacks; explicitly pick a non-default clip in s2, leave it, come
# back -- selection should restore to that clip.
let memo_setup = [
  {topic: "stack.add" id: "m1" hash: null meta: {name: "M1" sort: "manual"}}
  {topic: "stack.add" id: "m2" hash: null meta: {name: "M2" sort: "manual"}}
  {topic: "clip.add" id: "p1" hash: "h" meta: {stack_id: "m2" mime_type: "text/plain" position: "a"}}
  {topic: "clip.add" id: "p2" hash: "h" meta: {stack_id: "m2" mime_type: "text/plain" position: "b"}}
  {topic: "clip.add" id: "p3" hash: "h" meta: {stack_id: "m2" mime_type: "text/plain" position: "c"}}
]

let memorized = $memo_setup | append [
    {topic: "stack.select" id: "u" hash: null meta: {id: "m2"}}
    {topic: "clip.select" id: "u" hash: null meta: {id: "p2"}} # explicit pick
    {topic: "stack.select" id: "u" hash: null meta: {id: "m1"}} # leave
    {topic: "stack.select" id: "u" hash: null meta: {id: "m2"}} # come back
  ] | projection project
assert equal $memorized.selectedStackId "m2"
assert equal $memorized.selectedClipId "p2" $"expected p2 restored"

# Memorized clip removed -> falls back to first clip in render order.
let stale = $memo_setup | append [
    {topic: "stack.select" id: "u" hash: null meta: {id: "m2"}}
    {topic: "clip.select" id: "u" hash: null meta: {id: "p2"}}
    {topic: "stack.select" id: "u" hash: null meta: {id: "m1"}}
    {topic: "clip.delete" id: "u" hash: null meta: {id: "p2"}} # remove memorized
    {topic: "stack.select" id: "u" hash: null meta: {id: "m2"}}
  ] | projection project
assert equal $stale.selectedClipId "p1" $"stale memory should fall back"
print "   ok"

print "5l. stack.delete bounce restores the destination stack's cursor"
let bounced = $memo_setup | append [
    {topic: "stack.select" id: "u" hash: null meta: {id: "m2"}}
    {topic: "clip.select" id: "u" hash: null meta: {id: "p2"}} # remember p2 in m2
    {topic: "stack.select" id: "u" hash: null meta: {id: "m1"}} # switch to m1
    {topic: "stack.delete" id: "u" hash: null meta: {id: "m1"}} # delete m1, bounce to m2
  ] | projection project
assert equal $bounced.selectedStackId "m2"
assert equal $bounced.selectedClipId "p2" $"bounce should restore p2"
print "   ok"

print "5h. clip.delete preserves cursor position within the stack"
# Manual sort, deterministic order: c1, c2, c3 (positions a, b, c).
# Cursor on c2 -> deleting c2 should land cursor on c3 (slot stays).
# Cursor on c3 -> deleting c3 should land cursor on c2 (last falls back).
# Cursor on c1 (and c1 deleted) -> cursor goes to c2 (slot 0 still slot 0).
const DEL_FRAMES = [
  {topic: "stack.add" id: "ds" hash: null meta: {name: "D" sort: "manual"}}
  {topic: "clip.add" id: "c1" hash: "h1" meta: {stack_id: "ds" mime_type: "text/plain" position: "a"}}
  {topic: "clip.add" id: "c2" hash: "h2" meta: {stack_id: "ds" mime_type: "text/plain" position: "b"}}
  {topic: "clip.add" id: "c3" hash: "h3" meta: {stack_id: "ds" mime_type: "text/plain" position: "c"}}
]

let middle_gone = $DEL_FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "ds"}}
    {topic: "clip.select" id: "x" hash: null meta: {id: "c2"}}
    {topic: "clip.delete" id: "x" hash: null meta: {id: "c2"}}
  ] | projection project
assert equal $middle_gone.selectedClipId "c3" $"slot kept; expected c3"

let last_gone = $DEL_FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "ds"}}
    {topic: "clip.select" id: "x" hash: null meta: {id: "c3"}}
    {topic: "clip.delete" id: "x" hash: null meta: {id: "c3"}}
  ] | projection project
assert equal $last_gone.selectedClipId "c2" $"bottom falls back; expected c2"

let top_gone = $DEL_FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "ds"}}
    {topic: "clip.select" id: "x" hash: null meta: {id: "c1"}}
    {topic: "clip.delete" id: "x" hash: null meta: {id: "c1"}}
  ] | projection project
assert equal $top_gone.selectedClipId "c2" $"top slot promotes c2"

# Deleting an unselected clip leaves the cursor alone.
let other_gone = $DEL_FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "ds"}}
    {topic: "clip.select" id: "x" hash: null meta: {id: "c2"}}
    {topic: "clip.delete" id: "x" hash: null meta: {id: "c3"}}
  ] | projection project
assert equal $other_gone.selectedClipId "c2" $"unrelated delete should not move the cursor"
print "   ok"

print "5i. stack.delete preserves cursor position across stacks"
# Three stacks; render order follows lastTouched-desc. With no other activity,
# that's reverse insertion: s3, s2, s1. Cursor stays in the same slot.
const STACK_DEL_FRAMES = [
  {topic: "stack.add" id: "s1" hash: null meta: {name: "A" sort: "auto"}}
  {topic: "stack.add" id: "s2" hash: null meta: {name: "B" sort: "auto"}}
  {topic: "stack.add" id: "s3" hash: null meta: {name: "C" sort: "auto"}}
]

# Render order: [s3, s2, s1]. Selecting s2 (slot 1), deleting s2 -> slot 1 is now s1.
let mid = $STACK_DEL_FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "s2"}}
    {topic: "stack.delete" id: "x" hash: null meta: {id: "s2"}}
  ] | projection project
assert equal $mid.selectedStackId "s1" $"slot kept; expected s1"

# Selecting s1 (bottom slot), deleting s1 -> falls back to the new last (s2).
let bottom = $STACK_DEL_FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "s1"}}
    {topic: "stack.delete" id: "x" hash: null meta: {id: "s1"}}
  ] | projection project
assert equal $bottom.selectedStackId "s2" $"bottom falls back; expected s2"

# Selecting s3 (top slot), deleting s3 -> top slot promotes s2.
let top = $STACK_DEL_FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "s3"}}
    {topic: "stack.delete" id: "x" hash: null meta: {id: "s3"}}
  ] | projection project
assert equal $top.selectedStackId "s2" $"top slot promotes s2"

# Deleting an unselected stack leaves the cursor alone.
let other = $STACK_DEL_FRAMES | append [
    {topic: "stack.select" id: "x" hash: null meta: {id: "s2"}}
    {topic: "stack.delete" id: "x" hash: null meta: {id: "s3"}}
  ] | projection project
assert equal $other.selectedStackId "s2" $"unrelated delete should not move the cursor"
print "   ok"

print "5f. editor.open / editor.close toggle mode + editClipId"
let editing = $FRAMES | append [
    {topic: "editor.open" id: "u4" hash: null meta: {clip_id: "c1"}}
  ] | projection project
assert equal $editing.mode "edit"
assert equal $editing.editClipId "c1"

let edit_done = $FRAMES | append [
    {topic: "editor.open" id: "u4" hash: null meta: {clip_id: "c1"}}
    {topic: "editor.close" id: "u5" hash: null meta: {}}
  ] | projection project
assert equal $edit_done.mode "main"
assert equal $edit_done.editClipId null
print "   ok"

print "5j. rename.open / rename.close toggle mode + renameStackId"
let renaming = $FRAMES | append [
    {topic: "rename.open" id: "u6" hash: null meta: {stack_id: "s2"}}
  ] | projection project
assert equal $renaming.mode "rename"
assert equal $renaming.renameStackId "s2"

let rename_done = $FRAMES | append [
    {topic: "rename.open" id: "u6" hash: null meta: {stack_id: "s2"}}
    {topic: "rename.close" id: "u7" hash: null meta: {}}
  ] | projection project
assert equal $rename_done.mode "main"
assert equal $rename_done.renameStackId null
print "   ok"

print "5b. compose.open / compose.close toggle mode + composeStackId"
let opened = $FRAMES | append [
    {topic: "compose.open" id: "x" hash: null meta: {stack_id: "s2"}}
  ] | projection project
assert equal $opened.mode "compose"
assert equal $opened.composeStackId "s2"

let closed = $FRAMES | append [
    {topic: "compose.open" id: "x" hash: null meta: {stack_id: "s2"}}
    {topic: "compose.close" id: "y" hash: null meta: {}}
  ] | projection project
assert equal $closed.mode "main"
assert equal $closed.composeStackId null
print "   ok"

print "5m. clip.delete captures snapshot to state.deleted; clip.restore brings it back"
let trash_setup = [
  {topic: "stack.add" id: "ts1" hash: null meta: {name: "T" sort: "manual"}}
  {topic: "clip.add" id: "tc1" hash: "h1" meta: {stack_id: "ts1" mime_type: "text/plain" position: "a"}}
  {topic: "clip.add" id: "tc2" hash: "h2" meta: {stack_id: "ts1" mime_type: "text/plain" position: "b"}}
]
let after_del = $trash_setup | append [
    {topic: "clip.delete" id: "td1" hash: null meta: {id: "tc1"}}
  ] | projection project
assert equal ($after_del.deleted | length) 1
let entry = $after_del.deleted | first
assert equal $entry.frame_id "td1"
assert equal $entry.kind "clip"
assert equal $entry.snapshot.stack_id "ts1"
assert equal $entry.snapshot.clip.id "tc1"
let s_after = $after_del.stacks | where id == "ts1" | first
assert equal ($s_after.clips | length) 1

let after_restore = $trash_setup | append [
    {topic: "clip.delete" id: "td1" hash: null meta: {id: "tc1"}}
    {topic: "clip.restore" id: "tr1" hash: null meta: {target: "td1"}}
  ] | projection project
assert equal ($after_restore.deleted | length) 0
let s_back = $after_restore.stacks | where id == "ts1" | first
assert equal ($s_back.clips | length) 2
let restored = $s_back.clips | where id == "tc1" | first
assert equal $restored.hash "h1"
assert equal $restored.position "a"
print "   ok"

print "5n. stack.delete captures snapshot incl. clips; stack.restore brings the whole thing back"
let after_sdel = $trash_setup | append [
    {topic: "stack.delete" id: "tsd1" hash: null meta: {id: "ts1"}}
  ] | projection project
assert equal ($after_sdel.stacks | length) 0
assert equal ($after_sdel.deleted | length) 1
let sentry = $after_sdel.deleted | first
assert equal $sentry.kind "stack"
assert equal ($sentry.snapshot.stack.clips | length) 2

let after_srestore = $trash_setup | append [
    {topic: "stack.delete" id: "tsd1" hash: null meta: {id: "ts1"}}
    {topic: "stack.restore" id: "tsr1" hash: null meta: {target: "tsd1"}}
  ] | projection project
assert equal ($after_srestore.deleted | length) 0
let back_stack = $after_srestore.stacks | where id == "ts1" | first
assert equal ($back_stack.name) "T"
assert equal ($back_stack.clips | length) 2
print "   ok"

print "5o. clip.restore is a no-op when parent stack is itself deleted"
let blocked = $trash_setup | append [
    {topic: "clip.delete" id: "td1" hash: null meta: {id: "tc1"}}
    {topic: "stack.delete" id: "tsd1" hash: null meta: {id: "ts1"}}
    {topic: "clip.restore" id: "tr1" hash: null meta: {target: "td1"}}
  ] | projection project
# parent ts1 still in trash, so restore did nothing
assert equal ($blocked.deleted | length) 2
# but restoring the stack first then the clip works
let ordered = $trash_setup | append [
    {topic: "clip.delete" id: "td1" hash: null meta: {id: "tc1"}}
    {topic: "stack.delete" id: "tsd1" hash: null meta: {id: "ts1"}}
    {topic: "stack.restore" id: "tsr1" hash: null meta: {target: "tsd1"}}
    {topic: "clip.restore" id: "tr1" hash: null meta: {target: "td1"}}
  ] | projection project
assert equal ($ordered.deleted | length) 0
let ordered_stack = $ordered.stacks | where id == "ts1" | first
# stack snapshot was taken with one clip (tc1 already deleted before stack.delete);
# clip.restore then puts tc1 back. expect 2 clips total.
assert equal ($ordered_stack.clips | length) 2
print "   ok"

print "5p. trash.open / trash.close toggle mode and clear selection"
let in_trash = $trash_setup | append [
    {topic: "clip.delete" id: "td1" hash: null meta: {id: "tc1"}}
    {topic: "trash.open" id: "to1" hash: null meta: {}}
    {topic: "deleted.select" id: "ds1" hash: null meta: {id: "td1"}}
  ] | projection project
assert equal $in_trash.mode "trash"
assert equal $in_trash.selectedDeletedFrameId "td1"
let closed_trash = $trash_setup | append [
    {topic: "clip.delete" id: "td1" hash: null meta: {id: "tc1"}}
    {topic: "trash.open" id: "to1" hash: null meta: {}}
    {topic: "deleted.select" id: "ds1" hash: null meta: {id: "td1"}}
    {topic: "trash.close" id: "tx1" hash: null meta: {}}
  ] | projection project
assert equal $closed_trash.mode "main"
assert equal $closed_trash.selectedDeletedFrameId null
print "   ok"

print "6. apply-frame: ignores unknown topics"
let s = projection empty
let out = projection apply-frame $s {topic: "xs.pulse" id: "p" hash: null meta: null}
# unknown topics still update frameId -- strip it before comparing
assert equal ($out | reject frameId) ($s | reject frameId)
print "   ok"

print "7. serve.nu: GET / returns the bootstrap HTML"
let handler = source ($script_dir | path join serve.nu)
let response = do $handler {method: "GET" path: "/" headers: {} query: {}}
let html = $response | get __html
assert ($html | str contains "<main>") "page should include the <main> mount point"
assert ($html | str contains "/keys.js") "page should load the keymap handler"
assert ($html | str contains "/updates") "page should bootstrap the SSE stream"
assert ($html | str contains "iconify-icon@2") "bootstrap should pull in the iconify runtime"
print "   ok"

print "8. serve.nu: POST /stacks appends a stack.add frame"
'{"name": "Inbox", "sort": "auto"}' | do $handler {
  method: "POST"
  path: "/stacks"
  headers: {}
  query: {}
}
# `last` rather than `first` because bootstrap-if-empty seeds a Welcome
# stack on the first source; the new Inbox is the most recent stack.add.
let added = .cat | where topic == "stack.add" | last
assert equal $added.meta.name "Inbox"
let stack_id = $added.id

# Add a clip; body bytes go to CAS via xs.
"hello, clipboard" | do $handler {
  method: "POST"
  path: $"/stacks/($stack_id)/clips"
  headers: {}
  query: {mime_type: "text/plain"}
}
let clip_frame = .cat | where topic == "clip.add" | last
assert equal $clip_frame.meta.stack_id $stack_id
assert ($clip_frame.hash != null) "clip body should be CAS-stored, hash populated"

let live_state = .cat | projection project
let stack = $live_state.stacks | where id == $stack_id | first
assert equal $stack.name "Inbox"
assert equal ($stack.clips | length) 1
print "   ok"

print "9. stacks module: meta builders produce the documented shapes"
let a = stack add "Inbox" --sort manual
assert equal $a ({topic: "stack.add" ttl: "forever" meta: {name: "Inbox" sort: "manual"}})

let b = stack update "s1" --name "Renamed"
assert equal $b.topic "stack.update"
assert equal $b.meta ({id: "s1" name: "Renamed"}) "stack update should omit unset fields"

let c = stack delete "s1"
assert equal $c ({topic: "stack.delete" ttl: "forever" meta: {id: "s1"}})

let d = "the body" | clip add "s2" --mime-type "text/plain" --position "am"
assert equal $d.topic "clip.add"
assert equal $d.ttl "forever"
assert equal $d.meta ({stack_id: "s2" mime_type: "text/plain" position: "am"})
assert equal $d.body "the body" "clip add captures piped body"

let d2 = clip add "s2" # defaults: mime_type=text/plain, no position, body=null
assert equal $d2.meta ({stack_id: "s2" mime_type: "text/plain"})

let e = clip move "c1" --to-stack "s2" --position "z"
assert equal $e ({topic: "clip.patch" ttl: "forever" meta: {id: "c1" stack_id: "s2" position: "z"}})

let e2 = clip move "c1" --position "n"
assert equal $e2 ({topic: "clip.patch" ttl: "forever" meta: {id: "c1" position: "n"}}) "clip move can reposition without changing stack"

let f = clip delete "c1"
assert equal $f ({topic: "clip.delete" ttl: "forever" meta: {id: "c1"}})

let r1 = clip restore "f1"
assert equal $r1 ({topic: "clip.restore" ttl: "forever" meta: {target: "f1"}})

let r2 = stack restore "f1"
assert equal $r2 ({topic: "stack.restore" ttl: "forever" meta: {target: "f1"}})

let g = stack select "s1"
assert equal $g ({topic: "stack.select" ttl: "ephemeral" meta: {id: "s1"}})

let g2 = stack select --down
assert equal $g2.meta ({action: "down"})
assert equal $g2.ttl "ephemeral"

let h = clip select --up
assert equal $h ({topic: "clip.select" ttl: "ephemeral" meta: {action: "up"}})
print "   ok"

print "10. stacks module: builder errors when underspecified"
let err1 = try { stack select } catch {|e| $e.msg }
assert ($err1 | str contains "id or --down/--up")
let err2 = try { clip move "c1" } catch {|e| $e.msg }
assert ($err2 | str contains "--to-stack")
print "   ok"

print "11. stacks module: append writes through xs and pairs with projection"
stack add "From module" --sort auto | send | ignore
let mod_stack = .cat | where topic == "stack.add" | last # newest
assert equal $mod_stack.meta.name "From module"

# Add a clip via the module, then verify projection sees it.
"hello via module" | clip add $mod_stack.id --mime-type "text/plain" | send | ignore
let projected = .cat | projection project
let s = $projected.stacks | where id == $mod_stack.id | first
assert equal ($s.clips | length) 1
let c = $s.clips | first
assert equal $c.mime_type "text/plain"
assert ($c.hash != null) "clip body should be CAS-stored"

# Selection: ephemeral frames aren't persisted, but `send` returns the
# appended frame so we can verify topic + meta were what the protocol expects.
let sel_frame = stack select $mod_stack.id | send
assert equal $sel_frame.topic "stack.select"
assert equal $sel_frame.meta.id $mod_stack.id
print "   ok"

print "12. serve.nu: POST /stacks/new takes the name from the body and selects it"
"2026-04-28 14:32" | do $handler {method: "POST" path: "/stacks/new" headers: {} query: {}}
let named = .cat | where topic == "stack.add" | last
assert equal $named.meta.name "2026-04-28 14:32"

# Empty body -> name is null (left to the caller; the route doesn't fabricate).
do $handler {method: "POST" path: "/stacks/new" headers: {} query: {}}
let unnamed = .cat | where topic == "stack.add" | last
assert equal $unnamed.meta.name? null "empty body should leave the name null"
print "   ok"

print "12b. serve.nu: /editor/submit emits clip.update, clip identity stays stable"
'{"name":"EditTest","sort":"manual"}' | do $handler {
  method: "POST"
  path: "/stacks"
  headers: {}
  query: {}
}
let edit_stack = .cat | where topic == "stack.add" | last
"original body" | do $handler {
  method: "POST"
  path: $"/stacks/($edit_stack.id)/clips"
  headers: {}
  query: {mime_type: "text/plain" position: "a"}
}
let original = .cat | where topic == "clip.add" | last
"edited body" | do $handler {
  method: "POST"
  path: $"/editor/submit/($original.id)"
  headers: {}
  query: {}
}

# Single update event references the original by id; no add+delete dance.
let updates = .cat | where topic == "clip.update" and meta.id == $original.id
assert equal ($updates | length) 1 "edit produces exactly one clip.update"
assert (($updates | first | get hash) != null) "clip.update body is CAS-stored"

let projected = .cat | projection project
let live_clip = $projected.stacks | where id == $edit_stack.id | first | get clips | first
assert equal $live_clip.id $original.id "clip id stays stable across edit"
assert equal $live_clip.position "a" "manual position survives"
assert equal $live_clip.hash ($updates | first | get hash) "projection tracks the latest hash"
print "   ok"

print "12c. serve.nu: /stacks/:id/rename/submit emits stack.update with new name"
'{"name":"Pre","sort":"auto"}' | do $handler {
  method: "POST"
  path: "/stacks"
  headers: {}
  query: {}
}
let to_rename = .cat | where topic == "stack.add" | last
"Renamed via route" | do $handler {
  method: "POST"
  path: $"/stacks/($to_rename.id)/rename/submit"
  headers: {}
  query: {}
}
let rename_frame = .cat | where topic == "stack.update" and meta.id == $to_rename.id | last
assert ($rename_frame != null) "/rename/submit should emit a stack.update"
assert equal $rename_frame.meta.name "Renamed via route"
let proj = .cat | projection project
let renamed = $proj.stacks | where id == $to_rename.id | first
assert equal $renamed.name "Renamed via route"
print "   ok"

print "13. serve.nu: actions registry, keymap, and status bar all reference action ids"
let template = "/root/stacks.nu/www/templates/three-pane.html.j2"
let main_view = {
  stacks: [{id: "s1" name: "Inbox" sort: "auto" clips: []}]
  selectedStackId: "s1"
  selectedClipId: null
  clips: []
  selectedClip: null
  mode: "main"
  modeName: "Inbox"
  composeStackId: null
  composeStackName: ""
  editClipId: null
  editClip: null
  editStackName: ""
  bindings: [
    {action: "clip.next" label: "next clip" keys: ["J"]}
    {action: "stack.new" label: "new stack" keys: ["\u{21E7}" "N"]}
  ]
  stackActions: [
    {action: "stack.sort.toggle" label: "sort: auto" icon: "lucide:arrow-down-narrow-wide"}
  ]
  actions: '{"clip.next":"fetch(\"/select/clip/down\",{method:\"POST\"})","stack.new":"fetch(\"/stacks/new\",{method:\"POST\",body:new Date().toLocaleString(\"sv-SE\").slice(0,16)})","stack.sort.toggle":"fetch(\"/stacks/s1/sort/manual\",{method:\"POST\"})"}'
  keymap: '{"j":"clip.next","shift+n":"stack.new"}'
}
let main_render = $main_view | .mj $template
assert ($main_render | str contains 'data-actions=') "main render should expose data-actions"
assert ($main_render | str contains 'data-keymap=') "main render should expose data-keymap"
assert ($main_render | str contains "window.actions.invoke('clip.next')") "binding click should invoke action by id"
assert ($main_render | str contains "window.actions.invoke('stack.new')") "stack.new binding should be wired"
assert ($main_render | str contains "window.actions.invoke('stack.sort.toggle')") "stack-actions click should invoke action by id"
assert ($main_render | str contains '<footer aria-label="Status"') "status footer should be present"
assert ($main_render | str contains '>Inbox<') "status footer should show the stack name"
assert ($main_render | str contains 'iconify-icon') "stack actions should use iconify icons"
assert ($main_render | str contains 'next clip') "status footer should list binding labels"
assert ($main_render | str contains "\u{21E7}") "shift glyph should appear in keys"

let compose_view = $main_view
  | update mode "compose"
  | update modeName "New clip in Inbox"
  | update composeStackId "s1" | update composeStackName "Inbox"
  | update bindings [
    {action: "compose.save" label: "save" keys: ["\u{2318}" "\u{21B5}"]}
    {action: "compose.cancel" label: "cancel" keys: ["ESC"]}
  ]
  | update stackActions []
  | update actions '{"compose.save":"fetch(\"/compose/submit/s1\",{method:\"POST\",body:document.querySelector(\"#compose-text\").value})","compose.cancel":"fetch(\"/compose/cancel\",{method:\"POST\"})"}'
  | update keymap '{"cmd+enter":"compose.save","escape":"compose.cancel"}'
let compose_render = $compose_view | .mj $template
assert ($compose_render | str contains 'compose-text') "compose render should include the textarea"
assert ($compose_render | str contains "window.actions.invoke('compose.save')") "compose save binding should reference action id"
assert ($compose_render | str contains '>New clip in Inbox<') "status footer should show compose mode name"
assert ($compose_render | str contains 'save') "status footer should list compose actions"
print "   ok"

print "\nAll tests passed."
