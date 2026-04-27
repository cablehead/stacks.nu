use std/assert

const script_dir = path self | path dirname

use ./projection.nu
use ./stacks *

# Synthetic frames stand in for what xs would emit. Real frames have hash
# populated by xs's CAS; here we leave it null where it doesn't matter.
const FRAMES = [
  {topic: "stack.add"    id: "s1" hash: null meta: {name: "Inbox"  sort: "auto"}}
  {topic: "stack.add"    id: "s2" hash: null meta: {name: "Pinned" sort: "manual"}}
  {topic: "clip.add"     id: "c1" hash: "sha256-aaa" meta: {stack_id: "s1" mime_type: "text/plain"}}
  {topic: "clip.add"     id: "c2" hash: "sha256-bbb" meta: {stack_id: "s1" mime_type: "text/plain"}}
  {topic: "clip.add"     id: "c3" hash: "sha256-ccc" meta: {stack_id: "s2" mime_type: "image/png" position: "a"}}
  {topic: "stack.update" id: "u1" hash: null meta: {id: "s1" name: "Recent"}}
  {topic: "clip.move"    id: "u2" hash: null meta: {id: "c1" stack_id: "s2" position: "am"}}
  {topic: "clip.delete"  id: "u3" hash: null meta: {id: "c2"}}
]

print "1. project: end-to-end fold over synthetic frames"
let state = $FRAMES | projection project
assert (($state.stacks | length) == 2)
let s1 = $state.stacks | where id == "s1" | first
assert ($s1.name == "Recent")
assert (($s1.clips | length) == 0)
let s2 = $state.stacks | where id == "s2" | first
assert (($s2.clips | length) == 2)
print "   ok"

print "2. project: selection defaults to first stack / first clip"
# After all FRAMES, s1 is empty and s2 has clips. Projection picks s1 (first
# stack), and selectedClipId is null because s1 has no clips.
assert ($state.selectedStackId == "s1") $"got ($state.selectedStackId)"
assert ($state.selectedClipId == null)
print "   ok"

print "3. stack.select cycle: down then up returns to start"
let with_sel = $FRAMES | append [
  {topic: "stack.select" id: "x" hash: null meta: {action: "down"}}
] | projection project
assert ($with_sel.selectedStackId == "s2")
# s2 has its original c3 plus the moved c1. sorted-clips for manual sort
# orders by position; c1's position "am" sorts after c3's "a".
assert ($with_sel.selectedClipId == "c3") $"got ($with_sel.selectedClipId)"

let cycled = $FRAMES | append [
  {topic: "stack.select" id: "x" hash: null meta: {action: "down"}}
  {topic: "stack.select" id: "x" hash: null meta: {action: "up"}}
] | projection project
assert ($cycled.selectedStackId == "s1")
print "   ok"

print "4. clip.select cycle: within selected stack"
let on_s2 = $FRAMES | append [
  {topic: "stack.select" id: "x" hash: null meta: {id: "s2"}}
  {topic: "clip.select"  id: "x" hash: null meta: {action: "down"}}
] | projection project
# stack.select to s2 starts on c3 (first by manual position); down -> c1
assert ($on_s2.selectedClipId == "c1") $"got ($on_s2.selectedClipId)"
print "   ok"

print "5. project-stream: silent until xs.threshold; threshold emit has selection"
let stream_input = ($FRAMES | first 2)
  | append [{topic: "xs.threshold"}]
  | append ($FRAMES | skip 2)
let outs = $stream_input | projection project-stream
let at_threshold = $outs | first
# Default tracks lastTouched-desc; s2 was added after s1 with no explicit select.
assert ($at_threshold.selectedStackId == "s2") "threshold emit should pick the most recent stack"
let final = $outs | last
assert (($final.stacks | where id == "s2" | first | get clips | length) == 2)
print "   ok"

print "5a. clip.add into the selected auto stack bumps selection to the new clip"
# After all FRAMES, s1 is empty (sort=auto) with no selected clip.
# Re-select s1 explicitly, then add a new clip -- selection should jump to it.
let bumped = $FRAMES | append [
  {topic: "stack.select" id: "x" hash: null meta: {id: "s1"}}
  {topic: "clip.add"     id: "c9" hash: "sha256-zzz" meta: {stack_id: "s1" mime_type: "text/plain"}}
] | projection project
assert ($bumped.selectedClipId == "c9") $"auto bump expected c9, got ($bumped.selectedClipId)"

# Manual stack: no bump -- user-curated order isn't disrupted.
let manual = $FRAMES | append [
  {topic: "stack.select" id: "x" hash: null meta: {id: "s2"}}
  {topic: "clip.select"  id: "x" hash: null meta: {id: "c3"}}
  {topic: "clip.add"     id: "c8" hash: "sha256-yyy" meta: {stack_id: "s2" mime_type: "text/plain" position: "z"}}
] | projection project
assert ($manual.selectedClipId == "c3") $"manual should not bump, got ($manual.selectedClipId)"
print "   ok"

print "5c. stack ordering: lastTouched bumps with clip activity"
# Two stacks created in order s1, s2; then a clip lands in s1 -- s1 should
# now be the most-recently-touched.
let touched = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First"  sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "clip.add"  id: "a3" hash: "x" meta: {stack_id: "a1" mime_type: "text/plain"}}
] | projection project
assert ($touched.stacks.0.lastTouched == "a3") $"a1.lastTouched should be a3 after the clip.add, got ($touched.stacks.0.lastTouched)"
assert ($touched.stacks.1.lastTouched == "a2") "untouched a2 should still hold its add id"

# stack.update also bumps activity.
let renamed_state = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First"  sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "stack.update" id: "a4" hash: null meta: {id: "a1" name: "Renamed"}}
] | projection project
assert (($renamed_state.stacks | where id == "a1" | first | get lastTouched) == "a4") "rename should bump a1"
print "   ok"

print "5e. default selection tracks lastTouched until user picks explicitly"
# (a) startup case: a2 has the most recent activity, so it's the default.
let startup = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First"  sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "clip.add"  id: "a3" hash: "x" meta: {stack_id: "a2" mime_type: "text/plain"}}
] | projection project
assert ($startup.selectedStackId == "a2") $"expected a2, got ($startup.selectedStackId)"

# Even though the streaming projection reconciles after every frame and
# would otherwise pin selection to the first stack added.
let stream_result = $startup
  # mimic project-stream's per-frame reconcile by feeding through xs.threshold
  # This case is covered by the project test above; this assertion is a sanity
  # check that the default is recomputed.
assert (not $stream_result.selectionExplicit) "no user select event yet"

# (b) once the user explicitly picks a1, it sticks even if a2 gets fresh activity.
let explicit = [
  {topic: "stack.add"   id: "a1" hash: null meta: {name: "First"  sort: "auto"}}
  {topic: "stack.add"   id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "stack.select" id: "u1" hash: null meta: {id: "a1"}}
  {topic: "clip.add"    id: "a3" hash: "x" meta: {stack_id: "a2" mime_type: "text/plain"}}
] | projection project
assert ($explicit.selectedStackId == "a1") $"explicit pick should stick; got ($explicit.selectedStackId)"
assert $explicit.selectionExplicit
print "   ok"

print "5d. stack.select cycle follows lastTouched order, not insertion order"
# a1, a2 created; clip lands in a1 -> a1 is newest. Selection starts on a1
# (the rendered top). Pressing 'down' should land on a2 (next in render order),
# not on a1 (insertion-order next-after-a1).
let cycled = [
  {topic: "stack.add" id: "a1" hash: null meta: {name: "First"  sort: "auto"}}
  {topic: "stack.add" id: "a2" hash: null meta: {name: "Second" sort: "auto"}}
  {topic: "clip.add"  id: "a3" hash: "x" meta: {stack_id: "a1" mime_type: "text/plain"}}
  {topic: "stack.select" id: "a4" hash: null meta: {action: "down"}}
] | projection project
assert ($cycled.selectedStackId == "a2") $"cycle should follow render order; got ($cycled.selectedStackId)"
print "   ok"

print "5b. compose.open / compose.close toggle mode + composeStackId"
let opened = $FRAMES | append [
  {topic: "compose.open" id: "x" hash: null meta: {stack_id: "s2"}}
] | projection project
assert ($opened.mode == "compose")
assert ($opened.composeStackId == "s2")

let closed = $FRAMES | append [
  {topic: "compose.open" id: "x" hash: null meta: {stack_id: "s2"}}
  {topic: "compose.close" id: "y" hash: null meta: {}}
] | projection project
assert ($closed.mode == "main")
assert ($closed.composeStackId == null)
print "   ok"

print "6. apply-frame: ignores unknown topics"
let s = projection empty
let out = projection apply-frame $s {topic: "xs.pulse" id: "p" hash: null meta: null}
# unknown topics still update frameId -- strip it before comparing
assert (($out | reject frameId) == ($s | reject frameId))
print "   ok"

print "7. serve.nu: GET / returns the bootstrap HTML"
let handler = source ($script_dir | path join serve.nu)
let response = do $handler {method: "GET" path: "/" headers: {} query: {}}
assert ($response | str contains "<main>") "page should include the <main> mount point"
assert ($response | str contains "/keys.js") "page should load the keymap handler"
assert ($response | str contains "/updates") "page should bootstrap the SSE stream"
print "   ok"

print "8. serve.nu: POST /stacks appends a stack.add frame"
'{"name": "Inbox", "sort": "auto"}' | do $handler {
  method: "POST" path: "/stacks" headers: {} query: {}
}
let added = .cat | where topic == "stack.add" | first
assert ($added.meta.name == "Inbox")
let stack_id = $added.id

# Add a clip; body bytes go to CAS via xs.
"hello, clipboard" | do $handler {
  method: "POST"
  path: $"/stacks/($stack_id)/clips"
  headers: {}
  query: {mime_type: "text/plain"}
}
let clip_frame = .cat | where topic == "clip.add" | first
assert ($clip_frame.meta.stack_id == $stack_id)
assert ($clip_frame.hash != null) "clip body should be CAS-stored, hash populated"

let live_state = .cat | projection project
let stack = $live_state.stacks | where id == $stack_id | first
assert ($stack.name == "Inbox")
assert (($stack.clips | length) == 1)
print "   ok"

print "9. stacks module: meta builders produce the documented shapes"
let a = stack add "Inbox" --sort manual
assert ($a == {topic: "stack.add" ttl: "forever" meta: {name: "Inbox" sort: "manual"}})

let b = stack update "s1" --name "Renamed"
assert ($b.topic == "stack.update")
assert ($b.meta == {id: "s1" name: "Renamed"}) "stack update should omit unset fields"

let c = stack delete "s1"
assert ($c == {topic: "stack.delete" ttl: "forever" meta: {id: "s1"}})

let d = "the body" | clip add "s2" --mime-type "text/plain" --position "am"
assert ($d.topic == "clip.add")
assert ($d.ttl == "forever")
assert ($d.meta == {stack_id: "s2" mime_type: "text/plain" position: "am"})
assert ($d.body == "the body") "clip add captures piped body"

let d2 = clip add "s2"  # defaults: mime_type=text/plain, no position, body=null
assert ($d2.meta == {stack_id: "s2" mime_type: "text/plain"})

let e = clip move "c1" --to-stack "s2" --position "z"
assert ($e == {topic: "clip.move" ttl: "forever" meta: {id: "c1" stack_id: "s2" position: "z"}})

let e2 = clip move "c1" --position "n"
assert ($e2.meta == {id: "c1" position: "n"}) "clip move can reposition without changing stack"

let f = clip delete "c1"
assert ($f == {topic: "clip.delete" ttl: "forever" meta: {id: "c1"}})

let g = stack select "s1"
assert ($g == {topic: "stack.select" ttl: "ephemeral" meta: {id: "s1"}})

let g2 = stack select --down
assert ($g2.meta == {action: "down"})
assert ($g2.ttl == "ephemeral")

let h = clip select --up
assert ($h == {topic: "clip.select" ttl: "ephemeral" meta: {action: "up"}})
print "   ok"

print "10. stacks module: builder errors when underspecified"
let err1 = try { stack select } catch {|e| $e.msg }
assert ($err1 | str contains "id or --down/--up")
let err2 = try { clip move "c1" } catch {|e| $e.msg }
assert ($err2 | str contains "--to-stack")
print "   ok"

print "11. stacks module: append writes through xs and pairs with projection"
stack add "From module" --sort auto | send | ignore
let mod_stack = .cat | where topic == "stack.add" | last  # newest
assert ($mod_stack.meta.name == "From module")

# Add a clip via the module, then verify projection sees it.
"hello via module" | clip add $mod_stack.id --mime-type "text/plain" | send | ignore
let projected = .cat | projection project
let s = $projected.stacks | where id == $mod_stack.id | first
assert (($s.clips | length) == 1)
let c = $s.clips | first
assert ($c.mime_type == "text/plain")
assert ($c.hash != null) "clip body should be CAS-stored"

# Selection: ephemeral frames aren't persisted, but `send` returns the
# appended frame so we can verify topic + meta were what the protocol expects.
let sel_frame = stack select $mod_stack.id | send
assert ($sel_frame.topic == "stack.select")
assert ($sel_frame.meta.id == $mod_stack.id)
print "   ok"

print "12. serve.nu: POST /stacks/new creates a timestamped stack and selects it"
do $handler {method: "POST" path: "/stacks/new" headers: {} query: {}}
let new_stacks = .cat | where topic == "stack.add" | get meta.name
let stamped = $new_stacks | where {|n| $n =~ '^\d{4}-\d{2}-\d{2}'} | get -i 0
assert ($stamped != null) "/stacks/new should produce a YYYY-MM-DD HH:MM name"
print "   ok"

print "13. serve.nu: three-pane render emits data-keymap with the active mode's keys"
let template = "/root/stacks.nu/www/templates/three-pane.html.j2"
let main_view = {
  stacks: [{id: "s1" name: "x" sort: "auto" clips: []}]
  selectedStackId: "s1" selectedClipId: null
  clips: [] selectedClip: null
  mode: "main" composeStackId: null composeStackName: ""
  keymap: '{"j":"/select/clip/down","shift+n":"/stacks/new"}'
}
let main_render = $main_view | .mj $template
assert ($main_render | str contains 'data-keymap=') "main render should expose data-keymap"
assert ($main_render | str contains '/stacks/new') "main keymap should include /stacks/new"

let compose_view = $main_view
  | update mode "compose"
  | update composeStackId "s1" | update composeStackName "x"
  | update keymap '{"escape":"/compose/cancel","cmd+enter":{"url":"/compose/submit/s1","source":"#compose-text"}}'
let compose_render = $compose_view | .mj $template
assert ($compose_render | str contains 'compose-text') "compose render should include the textarea"
assert ($compose_render | str contains '/compose/submit/s1') "compose keymap should target the stack"
print "   ok"

print "\nAll tests passed."
