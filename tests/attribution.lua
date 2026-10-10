-- Run from the repository root: nvim --headless -u NONE -l tests/attribution.lua
local root = vim.fn.getcwd()
local directory = "/tmp/mdview-attribution-" .. vim.fn.getpid()
vim.fn.mkdir(directory, "p")
local source = root .. "/tests/fixtures/attribution-continuation.md"
local css = root .. "/styles/markdown.css"
local worker = root .. "/build/mdview-preview"
local function run(args, stdin)
  return vim.system(args, {text=true, stdin=stdin}):wait()
end
local function hex(value)
  return (value:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local outputs = {}
for _, mode in ipairs({"plain", "marked"}) do
  local result = run({worker, "--html", source, css, mode})
  assert(result.code == 0, mode .. " attribution failed: " .. result.stderr)
  local html = directory .. "/" .. mode .. ".html"
  vim.fn.writefile(vim.split(result.stdout, "\n", {plain=true}), html)
  vim.fn.writefile({"bestfit: false", "width: 700", "height: 500"}, html .. ".cfg")
  local rendered = run({root .. "/build/mdview-render", html, directory .. "/" .. mode .. ".png", "700"})
  assert(rendered.code == 0, mode .. " render failed: " .. rendered.stderr)
  outputs[#outputs+1] = directory .. "/" .. mode .. ".png"
end
local parity = run({"magick", "compare", "-metric", "AE", outputs[1], outputs[2], "null:"})
assert(parity.code == 0 and tonumber(parity.stderr:match("^[%d.]+")) == 0,
  "source attribution changed rendered pixels: " .. parity.stderr)

local protocol = table.concat({"LOAD", 1, 700, hex(source), hex(directory), hex(css)}, " ")
  .. "\nDRAW 1 1 0 0 0 500 " .. hex(directory .. "/frame.png") .. "\nQUIT\n"
local traced = run({worker}, protocol)
assert(traced.code == 0, traced.stderr)
local anchors = {}
for line, first, last in traced.stdout:gmatch("FRAG (%d+) (%d+) (%d+) [%d.]+") do
  anchors[tonumber(line) .. ":" .. tonumber(first) .. ":" .. tonumber(last)] = true
end
local required = {
  "2:8:10", "2:13:15", -- emphasis and its adjacent text sibling
  "4:0:5", "4:8:13", "4:16:21", -- repeated words
  "6:0:4", "6:6:6", -- UTF-8 bytes and the source start of &amp;
  "6:12:18", "6:20:26", -- ordinary text and escaped punctuation
  "8:8:11", "8:14:17", -- ordinary list control
  "10:9:12", "10:15:18", -- ordinary quote control
}
for _, anchor in ipairs(required) do
  assert(anchors[anchor], "missing or shifted original-byte anchor " .. anchor .. "\n" .. traced.stdout)
end
assert(not traced.stdout:find("WARN ", 1, true), "known-success attribution emitted a warning")

local recovery = root .. "/tests/fixtures/attribution-recovery.md"
local message = "Could not match parsed text to original source; navigation for this block is approximate. Edit this block to retry."
local recovery_png = {}
for _, mode in ipairs({"plain", "marked"}) do
  local result = run({worker, "--html", recovery, css, mode})
  assert(result.code == 0, mode .. " recovery conversion failed: " .. result.stderr)
  local html = directory .. "/recovery-" .. mode .. ".html"
  vim.fn.writefile(vim.split(result.stdout, "\n", {plain=true}), html)
  vim.fn.writefile({"bestfit: false", "width: 700", "height: 500"}, html .. ".cfg")
  recovery_png[mode] = directory .. "/recovery-" .. mode .. ".png"
  local rendered = run({root .. "/build/mdview-render", html, recovery_png[mode], "700"})
  assert(rendered.code == 0, mode .. " recovery render failed: " .. rendered.stderr)
end
local recovery_parity = run({"magick", "compare", "-metric", "AE", recovery_png.plain, recovery_png.marked, "null:"})
assert(recovery_parity.code == 0 and tonumber(recovery_parity.stderr:match("^[%d.]+")) == 0,
  "recovery changed visual text or inline emphasis: " .. recovery_parity.stderr)
local recovery_load = table.concat({"LOAD", 7, 700, hex(recovery), hex(directory), hex(css)}, " ")
local recovery_result = run({worker}, recovery_load .. "\nDRAW 7 1 4 0 0 500 " .. hex(directory .. "/recovery-frame.png") .. "\nQUIT\n")
assert(recovery_result.code == 0 and recovery_result.stdout:find("READY 7",1,true)
  and recovery_result.stdout:find("FRAME 7 1",1,true), "attribution mismatch still rejects the layout: " .. recovery_result.stdout)
assert(recovery_result.stdout:find("WARN 7 4 4 " .. hex(message) .. "\n",1,true), "missing or inaccurate revision-scoped warning: " .. recovery_result.stdout)
local warning_count = 0
for _ in recovery_result.stdout:gmatch("WARN 7 ") do warning_count = warning_count + 1 end
assert(warning_count == 1, "attribution warning was not deduplicated")
assert(recovery_result.stdout:find("FRAG 4 0 0 ",1,true), "mismatch did not degrade to a coarse line-only anchor: " .. recovery_result.stdout)
assert(recovery_result.stdout:find("FRAG 6 ",1,true), "following block lost its independent source anchor: " .. recovery_result.stdout)
assert(not recovery_result.stdout:find("ERROR ",1,true), "recoverable mismatch invalidated layout")
local warning_at = recovery_result.stdout:find("WARN 7")
local ready_at = recovery_result.stdout:find("READY 7")
local frame_at = recovery_result.stdout:find("FRAME 7")
assert(warning_at < ready_at and ready_at < frame_at and not recovery_result.stdout:find("WARN ", frame_at, true),
  "warnings were emitted out of LOAD/READY order or repeated during DRAW")
local fatal = directory .. "/fatal.md"
vim.fn.writefile({"<div>unsupported raw HTML</div>"}, fatal)
local fatal_result = run({worker}, table.concat({"LOAD", 8, 700, hex(fatal), hex(directory), hex(css), "html=0"}, " ") .. "\nQUIT\n")
assert(fatal_result.stdout:find("ERROR ",1,true) and not fatal_result.stdout:find("WARN ",1,true)
  and not fatal_result.stdout:find("READY ",1,true), "structural HTML failure was recovered or warned: " .. fatal_result.stdout)

vim.opt.runtimepath:prepend(root)
local renders, clears = 0, 0
package.preload["image"] = function()
  return {from_file=function()
    return {id="attribution-test", global_state={images={}}, clear=function() clears=clears+1 end,
      render=function() renders=renders+1 end}
  end}
end
package.preload["image.utils.term"] = function()
  return {get_size=function() return {cell_width=10, cell_height=20} end}
end
local warning_hex, error_hex = hex(message), hex("test structural failure")
local fake = directory .. "/fake-renderer"
vim.fn.writefile({"#!/bin/sh", "while IFS= read -r request; do", "  set -- $request", "  case $1 in",
  "    LOAD)", "      case $2 in",
  "        1|2|4|6) printf 'WARN %s 1 1 " .. warning_hex .. "\\nREADY %s 700 500 1\\n' \"$2\" \"$2\" ;;",
  "        3) printf 'WARN 2 1 1 " .. warning_hex .. "\\nWARN 3 1 1 " .. warning_hex .. "\\nERROR " .. error_hex .. "\\n' ;;",
  "        5) printf 'READY %s 700 500 1\\n' \"$2\" ;;",
  "      esac ;;",
  "    TOGGLE) printf 'DETAIL 1 1 2 0 0 700 500 0\\nWARN %s 1 1 " .. warning_hex .. "\\nREADY %s 700 500 1\\n' \"$2\" \"$2\" ;;",
  "    DRAW) printf 'WARN %s 1 1 " .. warning_hex .. "\\nFRAME %s %s %s %s 0 800 %s 1\\n' \"$2\" \"$2\" \"$3\" \"$4\" \"$5\" \"$7\" ;;",
  "    QUIT) exit 0 ;;", "  esac", "done"}, fake)
vim.fn.setfperm(fake, "rwx------")
local mdview = require("mdview")
local original_notify, notices = vim.notify, {}
vim.notify = function(text, level) notices[#notices+1] = {text=text, level=level} end
mdview.setup({renderer=fake, raw=false, smooth=false})
local test_source = directory .. "/diagnostics.md"
vim.fn.writefile({"# revision one"}, test_source)
vim.opt.columns, vim.opt.lines = 100, 30
vim.cmd("edit " .. vim.fn.fnameescape(test_source))
mdview.open("replace")
local function wait(predicate, label)
  assert(vim.wait(5000, predicate, 10), label .. ": " .. vim.inspect(mdview.status()))
end
wait(function() local s=mdview.status(); return s and s.frame and not s.busy end, "warning revision ready")
local state = mdview.status()
local ns, buf = state.attribution_ns, state.source_buf
local function diagnostics() return vim.diagnostic.get(buf, {namespace=ns}) end
local first = diagnostics()
assert(#first == 1 and first[1].lnum == 0 and first[1].end_lnum == 1
  and first[1].message == message and renders == 1 and clears == 0,
  "successful warning did not publish a positioned, nonblocking diagnostic")
assert(#notices == 1 and notices[1].level == vim.log.levels.WARN
  and notices[1].text:find("Line 1", 1, true) and notices[1].text:find("approximate", 1, true),
  "successful warning was not surfaced once with its line and approximate-navigation context")
local external_ns = vim.api.nvim_create_namespace("attribution-test.external")
vim.diagnostic.set(external_ns, buf, {{lnum=0, col=0, message="other plugin", severity=vim.diagnostic.severity.INFO}})
local seq = state.sequence
state.scroll_to(20)
wait(function() return state.sequence > seq and state.frame and not state.busy end, "warning-free redraw")
assert(#diagnostics() == 1 and renders == 2 and clears == 0 and #notices == 1,
  "warning handling cleared the preview or repeated on DRAW")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"# unrelated source edit"})
wait(function() return state.revision == 2 and state.frame and state.frame.revision == 2 and not state.busy end, "same-warning revision")
assert(#diagnostics() == 1 and #notices == 1,
  "unrelated source edit repeated an identical successful warning notification")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"# failing source"})
wait(function() return state.revision == 3 and state.error and not state.busy end, "fatal revision")
assert(#diagnostics() == 0 and #notices == 1, "warning from a failed or stale revision was published or notified")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"# same warning after failed revision"})
wait(function() return state.revision == 4 and state.frame and state.frame.revision == 4 and not state.busy end, "same-warning recovery")
assert(#diagnostics() == 1 and #notices == 1, "failed revision altered the remembered successful warning")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"# corrected source"})
wait(function() return state.revision == 5 and state.frame and state.frame.revision == 5 and not state.busy end, "corrected revision")
assert(#diagnostics() == 0 and #notices == 1, "corrected successful revision retained stale warnings or notified")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"# warning recurs after correction"})
wait(function() return state.revision == 6 and state.frame and state.frame.revision == 6 and not state.busy end, "recovered warning revision")
assert(#diagnostics() == 1 and #notices == 2, "successful corrected revision warning was not restored and announced")
mdview.close()
assert(#vim.diagnostic.get(buf, {namespace=ns}) == 0, "close retained owned diagnostics")
assert(#vim.diagnostic.get(buf, {namespace=external_ns}) == 1, "close cleared another plugin's diagnostics")
vim.fn.delete(test_source)
vim.fn.writefile({"<details><summary>x</summary>y</details>"}, test_source)
vim.cmd("edit! " .. vim.fn.fnameescape(test_source))
mdview.open("split")
wait(function() local s=mdview.status(); return s and s.loaded and not s.busy end, "split warning ready")
state = mdview.status()
state.details[1] = {id=1, start_line=1, end_line=2, y=0, open=true}
ns, buf = state.attribution_ns, state.source_buf
vim.diagnostic.set(external_ns, buf, {{lnum=0, col=0, message="other plugin", severity=vim.diagnostic.severity.INFO}})
assert(#notices == 3, "split warning did not use the same visible notification")
state.toggle_detail(1)
wait(function() return state.revision == 2 and state.loaded and not state.busy end, "warning-bearing details toggle")
assert(#notices == 3 and #vim.diagnostic.get(buf, {namespace=ns}) == 1,
  "TOGGLE repeated identical warning or lost its source diagnostic")
mdview.close()
assert(#vim.diagnostic.get(buf, {namespace=ns}) == 0 and #vim.diagnostic.get(buf, {namespace=external_ns}) == 1,
  "split close did not preserve external diagnostics while clearing owned warnings")
vim.notify = original_notify
vim.fn.delete(directory, "rf")
print("source attribution regression passed")
