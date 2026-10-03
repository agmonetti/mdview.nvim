-- Run from the repository root: nvim --headless -u NONE -l tests/plugin.lua
local api = vim.api
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local directory = "/tmp/mdview-plugin-test-" .. vim.fn.getpid()
vim.fn.mkdir(directory, "p")
local cleared, rendered, image_options = 0, 0, nil
package.preload["image"] = function()
  return {from_file=function(path, opts)
    image_options = opts
    assert(vim.fn.filereadable(path)==1)
    return {id="test", global_state={images={}}, original_path=path,
      clear=function() cleared=cleared+1 end, render=function() rendered=rendered+1 end}
  end}
end
package.preload["image.utils.term"] = function()
  return {get_size=function() return {cell_width=10, cell_height=20} end}
end
local mdview = require("mdview")
assert(not pcall(mdview.setup, {html="false"}), "nonboolean HTML option accepted")
vim.cmd("runtime plugin/mdview.lua")
local command_completion = vim.fn.getcompletion("MdV", "cmdline")
assert(command_completion[1] == "MdView", "toggle is not first in command completion")
assert(vim.fn.exists(":MdViewOpen") == 2 and vim.fn.exists(":MdViewClose") == 2,
  "explicit open/close commands are missing")
local function wait(predicate, description)
  assert(vim.wait(15000, predicate, 10), description .. ": " .. tostring(mdview.status() and mdview.status().error))
end
local function command(args, stdin)
  local result=vim.system(args, {text=true, stdin=stdin}):wait()
  assert(result.code==0, result.stderr)
  return result.stdout
end
local function check()
  local path=directory .. "/source with spaces.md"
  local paragraph={}
  for n=1,100 do paragraph[#paragraph+1]="word" .. n .. " café repeated repeated" end
  local text={"# Native fixture", "", table.concat(paragraph, " "), "", "**bold** and *emphasis* &amp; \\*literal\\* [link](./other.md).", "",
    "| A | B |", "| - | - |", "| repeated | Unicode ñ |", "", "- [x] completed", "- parent", "  - nested", "",
    "> Quote with `inline code`", "", "```lua", "print('hello')", "repeated repeated", "```", "", "![alt repeated](local%20image.png)", "", "\tindented code", "", ">\t\tpartially indented code"}
  vim.fn.writefile(text, path)
  command({"magick", "-size", "20x20", "xc:red", directory .. "/local image.png"})
  local function hexpath(value)
    return (value:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
  local subset=directory .. "/html-subset.md"
  vim.fn.writefile({"<p>safe <kbd>kbd</kbd><br>next <sup>2</sup> <span>plain</span></p>", "",
    "<kbd>broken", "", "# HTML tail"}, subset)
  local html_default=command({root .. "/build/mdview-preview", "--html", subset, root .. "/styles/markdown.css", "marked"})
  assert(html_default:find("<kbd",1,true) and html_default:find("<br",1,true)
    and html_default:find("<sup",1,true)
    and html_default:find("&lt;kbd&gt;broken",1,true), "closed HTML subset or localized literal fallback")
  local disabled=vim.system({root .. "/build/mdview-preview", "--html", subset, root .. "/styles/markdown.css", "plain", "html=0"},
    {text=true}):wait()
  assert(disabled.code~=0 and disabled.stderr:find("Raw HTML",1,true), "html=0 did not restore raw HTML rejection")
  local centered=directory .. "/centered.md"
  vim.fn.writefile({"<h1 align=\"center\">Disambiguator</h1>", "",
    "<p align=\"center\">A zero-dependency prompt <strong>before any action is taken</strong>, safely.</p>",
    "", "## Following"}, centered)
  local centered_html=command({root .. "/build/mdview-preview", "--html", centered, root .. "/styles/markdown.css", "marked"})
  assert(centered_html:find('<h1 style="text-align:center"',1,true)
    and centered_html:find('<p style="text-align:center"',1,true)
    and centered_html:find("<strong data-mdview=",1,true)
    and not centered_html:find("&lt;h1",1,true), "centered heading/paragraph and emphasis fell back to literals")
  local center_load=table.concat({"LOAD", 1, 700, hexpath(centered), hexpath(directory),
    hexpath(root .. "/styles/markdown.css")}, " ")
  local center_result=command({root .. "/build/mdview-preview"}, center_load
    .. "\nDRAW 1 1 0 0 0 400 " .. hexpath(directory .. "/centered.png") .. "\nQUIT\n")
  assert(center_result:find("FRAG 1 ",1,true) and center_result:find("FRAG 3 ",1,true)
    and center_result:find("FRAG 5 ",1,true), "centered content lost heading/body/following source anchors")
  for _, mode in ipairs({"plain","marked"}) do
    local html=command({root .. "/build/mdview-preview","--html",centered,root .. "/styles/markdown.css",mode})
    local htmlpath=directory .. "/centered-" .. mode .. ".html"
    local f=assert(io.open(htmlpath,"wb")); assert(f:write(html)); f:close()
    vim.fn.writefile({"bestfit: false","width: 700","height: 400"},htmlpath .. ".cfg")
    command({root .. "/build/mdview-render",htmlpath,directory .. "/centered-" .. mode .. ".png","700"})
  end
  local center_parity=vim.system({"magick","compare","-metric","AE",directory .. "/centered-plain.png",
    directory .. "/centered-marked.png","null:"},{text=true}):wait()
  assert(tonumber(center_parity.stderr:match("^[%d.]+"))==0,
    "centered HTML source annotations changed pixels: " .. center_parity.stderr)
  local uncentered=directory .. "/uncentered.md"
  vim.fn.writefile({"<h1>Disambiguator</h1>", "",
    "<p>A zero-dependency prompt before any action is taken, safely.</p>", "", "## Following"}, uncentered)
  command({root .. "/build/mdview-preview"}, table.concat({"LOAD", 1, 700, hexpath(uncentered),
    hexpath(directory), hexpath(root .. "/styles/markdown.css")}, " ")
    .. "\nDRAW 1 1 0 0 0 400 " .. hexpath(directory .. "/uncentered.png") .. "\nQUIT\n")
  local changed=vim.system({"magick","compare","-metric","AE",directory .. "/centered.png",
    directory .. "/uncentered.png","null:"},{text=true}):wait()
  assert(tonumber(changed.stderr:match("^[%d.]+"))>0,"alignment/emphasis did not affect raster pixels")
  local html_image=directory .. "/html-image.md"
  vim.fn.writefile({"Before <img src=\"local image.png\" alt=\"HTML pixel\"> after", "", "# HTML image tail"}, html_image)
  local html_image_load=table.concat({"LOAD", 1, 700, hexpath(html_image), hexpath(directory),
    hexpath(root .. "/styles/markdown.css")}, " ")
  local html_image_output=directory .. "/html-image-viewport.png"
  local html_image_result=vim.system({root .. "/build/mdview-preview"}, {text=true, stdin=html_image_load
    .. "\nDRAW 1 1 0 0 0 400 " .. hexpath(html_image_output) .. "\nQUIT\n"}):wait()
  assert(html_image_result.code==0 and not html_image_result.stderr:find("HTML subset",1,true),
    "valid local HTML image hit the literal fallback: " .. html_image_result.stderr)
  assert(html_image_result.stdout:find("READY 1",1,true) and html_image_result.stdout:find("FRAME 1 1",1,true)
    and html_image_result.stdout:find("FRAG 1 7 ",1,true), "production local HTML image did not lay out, draw and retain its source anchor")
  local markdown_image=directory .. "/markdown-image.md"
  vim.fn.writefile({"Before ![HTML pixel](local%20image.png) after", "", "# HTML image tail"}, markdown_image)
  local markdown_output=directory .. "/markdown-image-viewport.png"
  local markdown_result=command({root .. "/build/mdview-preview"}, table.concat({"LOAD", 1, 700,
    hexpath(markdown_image), hexpath(directory), hexpath(root .. "/styles/markdown.css")}, " ")
    .. "\nDRAW 1 1 0 0 0 400 " .. hexpath(markdown_output) .. "\nQUIT\n")
  assert(markdown_result:find("FRAME 1 1",1,true), "Markdown image oracle did not render")
  local image_compare=vim.system({"magick", "compare", "-metric", "AE", html_image_output, markdown_output, "null:"},
    {text=true}):wait()
  assert(image_compare.code==0 and tonumber(image_compare.stderr:match("^[%d.]+"))==0,
    "production HTML image pixels/layout differ from the same Markdown image: " .. image_compare.stderr)
  -- A rejected remote image inside a raw block must inherit the surrounding
  -- paragraph's source label, not the document root's label.
  local remote_image=directory .. "/remote-image.md"
  vim.fn.writefile({"<p align=\"center\">", "  <img src=\"https://example.invalid/banner.png\" alt=\"banner\" width=\"600\">",
    "</p>", "", "# Following heading"}, remote_image)
  local remote_html=command({root .. "/build/mdview-preview", "--html", remote_image, root .. "/styles/markdown.css", "marked"})
  assert(remote_html:find("&lt;img src=",1,true) and not remote_html:find("<img src=",1,true),
    "remote HTML image was not preserved as a visible literal")
  local remote_load=table.concat({"LOAD", 1, 700, hexpath(remote_image), hexpath(directory),
    hexpath(root .. "/styles/markdown.css")}, " ")
  local remote_result=command({root .. "/build/mdview-preview"}, remote_load
    .. "\nDRAW 1 1 1 0 0 400 " .. hexpath(directory .. "/remote-image.png") .. "\nQUIT\n")
  assert(remote_result:find("READY 1",1,true) and remote_result:find("FRAME 1 1",1,true)
    and remote_result:find("FRAG 2 2 ",1,true) and remote_result:find("FRAG 5 2 ",1,true),
    "nested rejected image lost its source anchor or prevented following content from rendering")
  -- Native AST instrumentation must not change pixels or lose local image resolution.
  for _, mode in ipairs({"plain", "marked"}) do
    local html=command({root .. "/build/mdview-preview", "--html", path, root .. "/styles/markdown.css", mode})
    local htmlpath=directory .. "/" .. mode .. ".html"
    vim.fn.writefile(vim.split(html, "\n", {plain=true}), htmlpath)
    vim.fn.writefile({"bestfit: false", "width: 700", "height: 4000"}, htmlpath .. ".cfg")
    command({root .. "/build/mdview-render", htmlpath, directory .. "/" .. mode .. ".png", "700"})
  end
  local compare=vim.system({"magick", "compare", "-metric", "AE", directory .. "/plain.png", directory .. "/marked.png", "null:"}, {text=true}):wait()
  assert(compare.code==0 and tonumber(compare.stderr:match("^[%d.]+"))==0, "instrumentation changes pixels: " .. compare.stderr)
  -- Fast transient PNG encoding must preserve native viewport pixels, including local images.
  local load = table.concat({"LOAD", 1, 700, hexpath(path), hexpath(directory), hexpath(root .. "/styles/markdown.css")}, " ")
  local ready = command({root .. "/build/mdview-preview"}, load .. "\nQUIT\n")
  local document_height = math.floor(assert(tonumber(ready:match("READY %d+ %d+ ([%d.]+)"))))
  assert(document_height < 4000, "parity fixture exceeds the reference PNG")
  local requests = {load}
  for n, pos in ipairs({{0, 0, 600}, {0, 0, document_height}}) do
    requests[#requests+1] = table.concat({"DRAW", 1, n, pos[1], pos[2], 0, pos[3], hexpath(directory .. "/viewport-" .. n .. ".png")}, " ")
  end
  requests[#requests+1] = "DRAW 1 3 0 0 0 600 " .. hexpath(directory .. "/missing/frame.png")
  requests[#requests+1] = "QUIT"
  local responses = command({root .. "/build/mdview-preview"}, table.concat(requests, "\n") .. "\n")
  local frames = 0
  for line in responses:gmatch("[^\n]+") do
    if line:match("^FRAME ") then
      local fields = vim.split(line, " ", {trimempty=true})
      local seq, y, height = tonumber(fields[3]), tonumber(fields[6]), tonumber(fields[8])
      local crop = directory .. "/crop-" .. seq .. ".png"
      command({"magick", directory .. "/plain.png", "-crop", string.format("700x%d+0+%d", height, y), "+repage", crop})
      local parity = vim.system({"magick", "compare", "-metric", "AE", crop, directory .. "/viewport-" .. seq .. ".png", "null:"}, {text=true}):wait()
      assert(parity.code==0 and tonumber(parity.stderr:match("^[%d.]+"))==0, "viewport encoding changes pixels: " .. parity.stderr)
      frames = frames + 1
    end
  end
  assert(frames==2, "native viewport did not render all parity frames")
  assert(responses:find("ERROR " .. hexpath("Cannot write viewport PNG"), 1, true), "PNG write failure was not reported")
  -- Raw RGBA output must produce bit-exact pixels matching the Cairo reference crop.
  local raw_requests = {load, "DRAW 1 1 0 0 0 600 " .. hexpath(directory .. "/viewport-1.rgba"), "QUIT"}
  local raw_resp = command({root .. "/build/mdview-preview"}, table.concat(raw_requests, "\n") .. "\n")
  assert(raw_resp:match("FRAME 1 1 "), "raw RGBA viewport did not render")
  local ref_rgba = command({"magick", directory .. "/crop-1.png", "-depth", "8", "RGBA:-"})
  local raw_file = io.open(directory .. "/viewport-1.rgba", "rb")
  local out_rgba = raw_file:read("*a"); raw_file:close()
  assert(#out_rgba == 700 * 600 * 4 and ref_rgba == out_rgba, "raw RGBA output pixels differ from Cairo reference")
  vim.o.columns=100; vim.o.lines=30
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.wo.wrap=true; vim.wo.smoothscroll=true
  vim.wo.number=false; vim.wo.signcolumn="no"
  vim.cmd("MdView split")
  wait(function() local s=mdview.status(); return s and s.frame and not s.busy end, "initial frame")
  local s=mdview.status()
  assert(api.nvim_win_get_buf(s.source_win) ~= s.preview_buf, "shared source buffer")
  assert(s.frame.width==api.nvim_win_get_width(s.preview_win)*10)
  assert(s.document_height>s.frame.height)
  assert(not s.smooth and not s.raw, "default transport/scroll changed")
  local first_revision=s.revision
  local source_win=s.source_win
  api.nvim_win_call(source_win, function() vim.cmd("normal! 3Gzt") end)
  api.nvim_exec_autocmds("WinScrolled", {})
  wait(function() return s.frame.line==3 and not s.busy end, "physical line scroll")
  local initial_y=s.frame.y
  local fragments={}
  for _, f in ipairs(s.fragments) do if f.line==3 then fragments[#fragments+1]=f end end
  assert(#fragments>100)
  -- Check source byte positions against unique raw tokens, not a first-word heuristic.
  for _, f in ipairs(fragments) do
    assert(text[3]:sub(f.column+1, f.finish+1):match("%S"), "wrong source range")
  end
  -- Actual Neovim wrapped-row scrolling; no direct skipcol injection.
  api.nvim_win_call(source_win, function()
    for _=1,12 do vim.cmd("normal! \5") end
    vim.cmd("redraw")
  end)
  local view=api.nvim_win_call(source_win, vim.fn.winsaveview)
  assert(view.topline==3 and view.skipcol>0, "smoothscroll did not enter a wrapped row")
  api.nvim_exec_autocmds("WinScrolled", {})
  wait(function() return s.frame.column>0 and not s.busy end, "wrapped-row frame")
  assert(s.frame.y>initial_y, "soft-wrap remains pinned to physical row zero")
  local expected_col=api.nvim_win_call(source_win, function() return vim.fn.virtcol2col(source_win, 3, view.skipcol+1)-1 end)
  assert(s.frame.column==expected_col, "display-cell/UTF-8-byte conversion")
  local expected
  for _, f in ipairs(fragments) do
    if f.column<=expected_col and (not expected or f.column>expected.column) then expected=f end
  end
  assert(expected and math.abs(s.frame.y-expected.y)<1, "wrapped frame does not use source-column fragment")
  api.nvim_buf_set_lines(s.source_buf, 0, 0, false, {"# Unsaved heading", ""})
  wait(function() return s.revision>first_revision and s.frame.revision==s.revision and not s.busy end, "unsaved edit")
  assert(vim.fn.readfile(path)[1]=="# Native fixture", "modified disk source")
  local revision=s.revision
  api.nvim_win_set_width(s.preview_win, 35)
  api.nvim_exec_autocmds("WinResized", {})
  wait(function() return s.revision>revision and s.frame.width==350 and not s.busy end, "width relayout")
  local html_revision=s.revision
  api.nvim_buf_set_lines(s.source_buf, 0, 0, false, {"<kbd>default enabled</kbd>"})
  wait(function() return s.revision>html_revision and not s.error and s.loaded and s.frame.revision==s.revision and not s.busy end,
    "default HTML-enabled worker")
  mdview.setup({html=false})
  api.nvim_buf_set_lines(s.source_buf, 0, 0, false, {"<kbd>disabled</kbd>"})
  wait(function() return s.error and s.error:match("Raw HTML") end, "explicit HTML disable")
  mdview.setup({html=true})
  api.nvim_buf_set_lines(s.source_buf, 0, 1, false, {})
  wait(function() return not s.error and s.loaded and s.frame.revision==s.revision and not s.busy end, "HTML recovery")
  -- Overlapping edits and width changes must publish only the latest source revision.
  for n=1,6 do
    api.nvim_buf_set_lines(s.source_buf, 0, 1, false, {"# Latest " .. n})
    api.nvim_win_set_width(s.preview_win, 35+n)
    api.nvim_exec_autocmds("WinResized", {})
  end
  wait(function() return not s.busy and not s.dirty and s.frame.revision==s.revision and s.frame.width==410 end, "burst convergence")
  -- Beyond Cairo's full-image height limit; draw only a bounded lower viewport.
  local long={}
  for n=1,180 do
    vim.list_extend(long, {"## Chapter " .. n, "", table.concat(paragraph, " "):sub(1,400), ""})
  end
  api.nvim_buf_set_lines(s.source_buf, 0, -1, false, long)
  api.nvim_win_call(source_win, function() vim.cmd("normal! Gzt") end)
  local target=api.nvim_win_call(source_win, function() return vim.fn.line("w0") end)
  api.nvim_exec_autocmds("WinScrolled", {})
  wait(function() return not s.busy and not s.dirty and s.frame.revision==s.revision and s.frame.line==target end, "bounded long document")
  assert(s.document_height>32768 and s.frame.y>32768)
  assert(s.frame.height==api.nvim_win_get_height(s.preview_win)*20)
  -- A real repository document exercises the final native path too.
  api.nvim_buf_set_lines(s.source_buf, 0, -1, false, vim.fn.readfile(root .. "/README.md"))
  wait(function() return not s.busy and not s.dirty and s.frame.revision==s.revision end, "repository README")
  local job=s.job
  api.nvim_win_close(s.preview_win, true)
  wait(function() return not mdview.status() end, "manual preview close")
  assert(vim.fn.jobwait({job}, 2000)[1]==0, "renderer leaked")
  wait(function() return vim.fn.isdirectory(s.directory)==0 end, "temp cleanup")
  assert(api.nvim_buf_is_valid(s.source_buf), "source was deleted")
  assert(cleared>0)
  -- Test "replace" mode (in-place reader mode with smooth scrolling and keymaps)
  local orig_win = api.nvim_get_current_win()
  local orig_buf = api.nvim_get_current_buf()
  api.nvim_win_set_cursor(orig_win, {5, 0})
  vim.cmd("MdViewOpen replace")
  wait(function() local new=mdview.status(); return new and new.frame and not new.busy end, "replace open")
  local rep = mdview.status()
  assert(rep.mode == "replace", "mode is not replace")
  assert(rep.preview_win == orig_win, "replace mode did not reuse current window")
  assert(api.nvim_win_get_buf(orig_win) == rep.preview_buf, "replace mode did not show preview buffer")
  -- Verify reader mode scrolling by pixels and keymaps
  local y_before = rep.current_y
  rep.scroll_to(y_before + 120)
  wait(function() return rep.frame and rep.frame.y == rep.current_y and not rep.busy end, "reader scroll_to")
  assert(rep.current_y == y_before + 120, "current_y did not advance")
  local y_scroll = rep.current_y
  api.nvim_feedkeys("j", "x", true)
  assert(rep.current_y > y_scroll, "j key did not scroll down")
  local y_after_j = rep.current_y
  api.nvim_feedkeys("k", "x", true)
  assert(rep.current_y < y_after_j, "k key did not scroll up")
  -- 'q' keymap restores original buffer and cursor position
  api.nvim_feedkeys("q", "x", true)
  wait(function() return not mdview.status() end, "replace close with q")
  assert(api.nvim_win_get_buf(orig_win) == orig_buf, "replace close did not restore source buffer")
  -- Test the primary toggle command's configured default mode ("replace").
  api.nvim_win_set_cursor(orig_win, {1, 0})
  vim.cmd("MdView")
  wait(function() local new=mdview.status(); return new and new.frame and not new.busy end, "default replace open")
  local reopened = mdview.status()
  assert(reopened.mode == "replace", "default mode is not replace")
  assert(reopened.frame.y == 0, "reader opening at line one cropped the first text row")
  assert(image_options.render_offset_top == -1, "image placement leaves a blank terminal row")
  -- Continuous input must display intermediate frames, not freeze until input stops.
  local before_render, before_clear = rendered, cleared
  local events = 0
  local timer = vim.uv.new_timer()
  timer:start(0, 20, vim.schedule_wrap(function()
    events = events + 1
    local key = events % 2 == 0 and "<Down>" or "<ScrollWheelDown>"
    api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, false, true), "x", true)
    if events == 40 then timer:stop(); timer:close() end
  end))
  wait(function() return events == 40 end, "continuous reader input")
  assert(rendered - before_render >= 2, "reader discarded every frame while scrolling")
  wait(function() return reopened.frame.y == reopened.current_y and not reopened.busy end, "reader final position")
  assert(reopened.current_y == 2400, "arrow/wheel events were lost")
  assert(cleared == before_clear, "controller cleared the image on every scroll frame")
  assert(reopened.frame.height == api.nvim_win_get_height(orig_win) * 20, "reader geometry changed after drawing")
  -- Test edit transition with 'e' restores source buffer at line
  api.nvim_feedkeys("e", "x", true)
  wait(function() return not mdview.status() end, "replace close with e")
  assert(api.nvim_win_get_buf(orig_win) == orig_buf, "replace e did not restore source buffer")
  assert(vim.fn.jobwait({reopened.job}, 2000)[1]==0)
  -- Test explicit "split" mode
  vim.cmd("MdView split")
  wait(function() local new=mdview.status(); return new and new.frame and not new.busy end, "explicit split open")
  local split_s = mdview.status()
  assert(split_s.mode == "split", "explicit mode is not split")
  vim.cmd("MdView")
  assert(not mdview.status())

  -- Test raw RGBA mode: opt-in, support detection (local Kitty vs SSH/non-Kitty), Kitty transmission, and burst latency
  vim.env.FPLOG_RAW = "1"
  vim.env.SSH_CLIENT = "10.0.0.1"
  mdview.open("replace")
  local ssh_s = mdview.status()
  assert(ssh_s.raw == false, "SSH session incorrectly enabled raw mode")
  mdview.close()
  vim.env.SSH_CLIENT = nil

  vim.env.TERM = "xterm-256color"
  vim.env.KITTY_WINDOW_ID = nil
  mdview.open("replace")
  local non_kitty_s = mdview.status()
  assert(non_kitty_s.raw == false, "Non-kitty terminal incorrectly enabled raw mode")
  mdview.close()

  vim.env.KITTY_WINDOW_ID = "1"
  local raw_transmitted, raw_placed, raw_deleted, last_z = 0, 0, 0, nil
  local terminal_reply, terminal_color, terminal_opacity = false, "1234/5678/9abc", "0.65"
  local capability = ("kitty-query-background_opacity"):gsub(".", function(c) return string.format("%02x",c:byte()) end)
  package.preload["image/backends/kitty/helpers"] = function()
    return {
      write = function(query)
        assert(query:find("\27]11;?",1,true), "missing OSC 11 query")
        if terminal_reply then vim.schedule(function()
          api.nvim_exec_autocmds("TermResponse",{data={sequence="\27]11;rgb:" .. terminal_color}})
          local opacity=terminal_opacity:gsub(".",function(c) return string.format("%02x",c:byte()) end)
          api.nvim_exec_autocmds("TermResponse",{data={sequence="\27P1+r" .. capability .. "=" .. opacity}})
        end) end
      end,
      write_graphics = function(cfg, data)
        if cfg.action == "t" then
          assert(cfg.transmit_format == 32, "wrong raw transmit format")
          assert(cfg.transmit_medium == "t", "wrong raw transmit medium")
          assert(data:find("tty%-graphics%-protocol"), "path lacks tty-graphics-protocol marker: " .. tostring(data))
          raw_transmitted = raw_transmitted + 1
        elseif cfg.action == "d" then
          raw_deleted = raw_deleted + 1
        end
      end,
      write_graphics_at = function(cfg, _x, _y)
        assert(cfg.action == "p", "wrong placement action")
        assert(_x > 0 and _y > 0, "invalid placement coordinates")
        last_z = cfg.display_zindex
        raw_placed = raw_placed + 1
      end
    }
  end
  package.preload["image.backends.kitty.helpers"] = package.preload["image/backends/kitty/helpers"]

  mdview.open("replace")
  wait(function() local cur = mdview.status(); return cur and cur.frame and not cur.busy end, "raw replace open")
  local raw_s = mdview.status()
  assert(raw_s.raw == true, "raw mode did not activate on local Kitty")
  assert(raw_s.raw_image_id > 0, "missing raw image id")
  assert(raw_transmitted >= 1, "raw frame was not transmitted to Kitty")
  assert(raw_placed >= 1, "raw frame was not placed in Kitty")
  assert(last_z == -1, "default z-index changed")

  -- Coalescing latency test under sustained burst: must not queue up frames or exceed 200 ms latency
  local burst_start = vim.uv.hrtime() / 1e6
  for i = 1, 30 do
    raw_s.scroll_to(i * 30)
  end
  wait(function() return raw_s.frame.y == raw_s.current_y and not raw_s.busy end, "raw burst convergence")
  local burst_latency = (vim.uv.hrtime() / 1e6) - burst_start
  assert(burst_latency < 200, "coalesced burst latency exceeded 200 ms: " .. burst_latency)

  mdview.close()
  assert(raw_deleted >= 1, "raw image was not deleted on close")
  -- Opt-in smoothing: timer-paced exponential movement, bounded steps, exact snap and cleanup.
  vim.env.FPLOG_SMOOTH = "1"
  vim.env.FPLOG_SMOOTH_FACTOR = "0.4"
  vim.env.FPLOG_CLAMP_PX = "84"
  api.nvim_win_set_cursor(0, {1, 0})
  mdview.open("replace")
  wait(function() local cur=mdview.status(); return cur and cur.frame and not cur.busy end, "smooth open")
  local smooth_s=mdview.status()
  local before=raw_placed
  smooth_s.scroll_to(180)
  local smooth_timer=smooth_s.smooth_timer
  assert(smooth_s.current_y==72, "first step is not exponential")
  wait(function() return smooth_s.current_y==180 and smooth_s.frame.y==180 and not smooth_s.busy end, "smooth snap")
  assert(raw_placed-before>2, "smooth scroll did not generate intermediate frames")
  assert(smooth_s.clamp_max==84, "pixel clamp ignored")
  smooth_s.scroll_to(360)
  local closing_timer=smooth_s.smooth_timer
  mdview.close()
  assert(closing_timer:is_closing(), "smooth timer leaked after close")
  assert(smooth_timer:is_closing(), "settled timer was not released")
  -- Invalid tuning must not hang or crash the timer.
  vim.env.FPLOG_SMOOTH_FACTOR="0"; vim.env.FPLOG_SMOOTH_INTERVAL="bad"
  mdview.open("replace")
  wait(function() local cur=mdview.status(); return cur and cur.frame and not cur.busy end, "invalid tuning open")
  local safe=mdview.status(); safe.scroll_to(safe.current_y+40)
  wait(function() return safe.frame.y==safe.target_y and not safe.busy end, "invalid tuning recovery")
  mdview.close()
  vim.env.FPLOG_SMOOTH=nil; vim.env.FPLOG_SMOOTH_FACTOR=nil; vim.env.FPLOG_SMOOTH_INTERVAL=nil; vim.env.FPLOG_CLAMP_PX=nil
  vim.env.FPLOG_C="1"
  mdview.open("replace")
  wait(function() local cur=mdview.status(); return cur and cur.frame and not cur.busy end, "C open")
  local c=mdview.status(); local y=c.current_y
  api.nvim_feedkeys(api.nvim_replace_termcodes("<ScrollWheelDown>",true,false,true),"x",true)
  assert(c.target_y==y+40 and c.clamp_max==80, "C is not step 2 plus clamp 4")
  mdview.close(); vim.env.FPLOG_C=nil
  -- Window-local layer detection, theme refresh, opacity and safe fallback.
  local global_normal=api.nvim_get_hl(0,{name="Normal",link=true})
  local original_ns=api.nvim_get_hl_ns({winid=orig_win})
  local original_winhl=vim.wo[orig_win].winhighlight
  terminal_reply=true; vim.env.FPLOG_RAW=nil; vim.env.FPLOG_RAW_ZBELOW=nil
  mdview.setup({zbelow=true})
  mdview.open("replace")
  wait(function() local cur=mdview.status(); return cur and cur.frame and cur.layer.enabled and not cur.busy end,"detected lower layer")
  local below=mdview.status()
  assert(last_z==-1073741825 and below.layer.opacity==0.65,"wrong lower layer/opacity")
  local namespace=api.nvim_get_hl_ns({winid=below.preview_win})
  assert(namespace>=0 and api.nvim_get_hl(namespace,{name="Normal"}).bg==0x12569a,"OSC 11 conversion")
  assert(vim.deep_equal(global_normal,api.nvim_get_hl(0,{name="Normal",link=true})),"global Normal changed")
  local fb=api.nvim_create_buf(false,true)
  local fw=api.nvim_open_win(fb,false,{relative="editor",row=2,col=2,width=20,height=3,style="minimal"})
  assert(api.nvim_get_hl_ns({winid=fw})~=namespace,"viewer namespace leaked into float")
  api.nvim_win_close(fw,true)
  terminal_color="ffff/0000/0000"
  api.nvim_exec_autocmds("ColorScheme",{})
  wait(function() return below.layer.enabled and below.layer.color==0xff0000 end,"ColorScheme redetection")
  terminal_color="0000/aaaa/bbbb"
  api.nvim_exec_autocmds("TermResponse",{data={sequence="\27[?997;1n"}})
  wait(function() return below.layer.enabled and below.layer.color==0x00aabb end,"terminal theme redetection")
  terminal_reply=false
  local saved_notify=vim.notify; local warned=false
  vim.notify=function(msg) if msg:find("using z=-1",1,true) then warned=true end end
  api.nvim_exec_autocmds("ColorScheme",{})
  wait(function() return not below.layer.pending and not below.layer.enabled and warned end,"query timeout fallback")
  assert(last_z==-1,"timeout did not restore safe z-index")
  vim.notify=saved_notify
  mdview.close()
  assert(api.nvim_get_hl_ns({winid=orig_win})==original_ns,"namespace not restored on close")
  assert(vim.wo[orig_win].winhighlight==original_winhl,"winhighlight not restored")
  assert(vim.deep_equal(global_normal,api.nvim_get_hl(0,{name="Normal",link=true})),"global highlight leaked")
  vim.env.FPLOG_RAW_ZBELOW="1"
  mdview.setup({zbelow=false})
  mdview.open("replace")
  wait(function() local cur=mdview.status(); return cur and cur.frame and not cur.busy end,"explicit layer disable")
  assert(not mdview.status().raw and mdview.status().layer==nil,"zbelow=false did not override environment opt-in")
  mdview.close()
  vim.env.FPLOG_RAW_ZBELOW=nil
  assert(not pcall(mdview.setup,{zbelow="true"}),"nonboolean zbelow accepted")
  vim.env.FPLOG_RAW=nil
  assert(not pcall(mdview.setup,{preset="unknown"}),"unknown preset silently accepted")
  -- One explicit preset supplies the reference combination; setup values override tuning flags.
  vim.env.FPLOG_SMOOTH_FACTOR="0.25"; vim.env.FPLOG_CLAMP_PX="2"
  mdview.setup({preset="fluid"})
  api.nvim_win_set_cursor(0,{1,0})
  mdview.open("replace")
  wait(function() local cur=mdview.status(); return cur and cur.frame and not cur.busy end,"fluid preset open")
  local fluid=mdview.status()
  assert(fluid.raw and fluid.smooth and fluid.clamp_max==84 and fluid.layer==nil,"fluid preset combination")
  fluid.scroll_to(100)
  assert(fluid.current_y==60,"fluid reference factor is not 0.6")
  wait(function() return fluid.frame.y==100 and not fluid.busy end,"fluid preset settle")
  mdview.close()
  vim.env.FPLOG_SMOOTH_FACTOR=nil; vim.env.FPLOG_CLAMP_PX=nil
  local old_tmux=vim.env.TMUX; vim.env.TMUX="mock-tmux"
  mdview.open("replace")
  wait(function() local cur=mdview.status(); return cur and cur.frame and not cur.busy end,"fluid tmux fallback")
  assert(not mdview.status().raw and mdview.status().smooth,"tmux did not fall back to PNG with smooth retained")
  mdview.close(); vim.env.TMUX=old_tmux
  vim.env.FPLOG_SMOOTH="1"; vim.env.FPLOG_RAW="1"
  mdview.setup({preset="fluid",raw=false,smooth=false,clamp=false})
  mdview.open("replace")
  wait(function() local cur=mdview.status(); return cur and cur.frame and not cur.busy end,"explicit preset overrides")
  assert(not mdview.status().raw and not mdview.status().smooth,"explicit false ignored")
  mdview.close(); vim.env.FPLOG_SMOOTH=nil
  vim.env.KITTY_WINDOW_ID = nil
  vim.env.FPLOG_RAW = nil

  print("PASS: native pixel parity, UTF-8 soft-wrap, edit, resize, recovery, bursts, continuous reader scroll, placement, replace/split modes, close/reopen, cleanup")
end
local ok, err=xpcall(check, debug.traceback)
mdview.close()
if not ok then io.stderr:write(err .. "\nArtifacts: " .. directory .. "\n"); vim.cmd("cquit 1") end
vim.fn.delete(directory, "rf")
vim.cmd("qall!")
