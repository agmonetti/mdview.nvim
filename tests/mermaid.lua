-- Run from the repository root: nvim --headless -u NONE -l tests/mermaid.lua
-- Requires the already evaluated build/merman-evaluation/target/release/merman-cli; never downloads it.
local api = vim.api
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local directory = "/tmp/mdview-mermaid-test-" .. vim.fn.getpid()
vim.fn.mkdir(directory, "p")
local binary = root .. "/build/merman-evaluation/target/release/merman-cli"
local worker = root .. "/build/mdview-preview"
local calls = directory .. "/renderer-calls"
local pause = directory .. "/renderer-pause"
local children = directory .. "/renderer-children"
local wrapper = directory .. "/counted merman"
local displayed, renders = nil, 0
local function contents(path)
  local file = assert(io.open(path, "rb")); local value = file:read("*a"); file:close(); return value
end
package.preload["image"] = function()
  return {from_file=function(path)
    assert(vim.fn.filereadable(path)==1, "missing viewport image")
    return {id="mermaid-test", global_state={images={}}, original_path=path,
      clear=function() displayed=nil end,
      render=function(self)
        displayed=contents(self.original_path)
        renders=renders+1
      end}
  end}
end
package.preload["image.utils.term"] = function()
  return {get_size=function() return {cell_width=10, cell_height=20} end}
end
local mdview = require("mdview")
local environment = {}
local env_names = {"FPLOG_RAW", "FPLOG_SMOOTH", "FPLOG_RAW_ZBELOW", "FPLOG_CLAMP_PX", "FPLOG_C", "FPLOG_STEP", "FPLOG_CLAMP", "KITTY_WINDOW_ID"}
for _, name in ipairs(env_names) do environment[name]=vim.env[name]; vim.env[name]=nil end
local original = {background=vim.o.background, columns=vim.o.columns, lines=vim.o.lines, equalalways=vim.o.equalalways}
local names = {"Normal", "NormalFloat", "Title", "Underlined", "Identifier", "Comment"}
local highlights = {}
for _, name in ipairs(names) do highlights[name]=api.nvim_get_hl(0,{name=name,link=true}) end
local function wait(predicate, description, timeout)
  assert(vim.wait(timeout or 15000, predicate, 10), description .. ": " .. tostring(mdview.status() and mdview.status().error))
end
local function settled(s)
  return s.frame and s.loaded and not s.busy and not s.dirty and not s.debouncing and not s.error and s.frame.revision==s.revision
end
local function command(args, stdin)
  local result=vim.system(args,{text=true,stdin=stdin}):wait()
  assert(result.code==0, table.concat(args," ") .. ": " .. (result.stderr or ""))
  return result.stdout
end
local function hex(value)
  return (value:gsub(".",function(c) return string.format("%02x",c:byte()) end))
end
local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end
local function save(path, value)
  local file=assert(io.open(path,"wb")); assert(file:write(value)); file:close(); return path
end
local function pixels_equal(a,b)
  local result=vim.system({"magick","compare","-metric","AE",a,b,"null:"},{text=true}):wait()
  assert(result.code==0 or result.code==1,"pixel comparison failed: " .. result.stderr)
  return assert(tonumber(result.stderr:match("^[%d.]+")),result.stderr)==0
end
local function call_count()
  return vim.fn.filereadable(calls)==1 and #vim.fn.readfile(calls) or 0
end
local function diagram(s)
  local files=vim.fn.glob(s.directory .. "/diagrams/*.png",false,true)
  assert(#files==1,"single Mermaid fence did not leave exactly one diagram PNG")
  return files[1]
end
local function dimensions(path)
  local size=command({"magick","identify","-format","%w %h",path})
  local w,h=size:match("^(%d+) (%d+)$")
  return assert(tonumber(w)),assert(tonumber(h))
end
local schemes = {
  {bg="#102030",fg="#f0f0f0",heading="#ffffff",accent="#88ccff",muted="#bbbbbb",surface="#203040"},
  {bg="#faf0d8",fg="#202838",heading="#102030",accent="#153f80",muted="#405040",surface="#e3d7be"},
}
local function scheme(n)
  local p=schemes[n]
  api.nvim_set_hl(0,"Normal",{fg=p.fg,bg=p.bg})
  api.nvim_set_hl(0,"Title",{fg=p.heading})
  api.nvim_set_hl(0,"Underlined",{fg=p.accent})
  api.nvim_set_hl(0,"Identifier",{})
  api.nvim_set_hl(0,"Comment",{fg=p.muted})
  api.nvim_set_hl(0,"NormalFloat",{bg=p.surface})
end
local source=directory .. "/source with spaces.md"
local reference=vim.fn.readfile(root .. "/tests/merman/reference.mmd")
local function document(body, image)
  local text={"# Automatic Mermaid", ""}
  if image then text[#text+1]="![Mermaid diagram](" .. image:gsub(" ","%%20") .. ")"
  else
    text[#text+1]="```mermaid"
    vim.list_extend(text,body)
    text[#text+1]="```"
  end
  text[#text+1]=""
  for n=1,90 do
    text[#text+1]="Paragraph " .. n .. " after the diagram, for a real scrolling viewport."
    text[#text+1]=""
  end
  return text
end
local disk=document(reference)
local function native_frame(path, s, output)
  local load=table.concat({"LOAD",1,s.frame.width,hex(path),hex(directory),hex(s.stylesheet)}," ")
  local draw=table.concat({"DRAW",1,1,0,s.frame.y,0,s.frame.height,hex(output)}," ")
  local response=command({worker},load .. "\n" .. draw .. "\nQUIT\n")
  assert(response:match("FRAME 1 1 "),"reference worker failed to draw: " .. response)
end
local oracle_serial=0
-- Compare actual displayed pixels to an independently rendered real diagram embedded as a normal image.
-- No Mermaid protocol is used by the oracle's native worker.
local function matches_reference(s, body, palette)
  oracle_serial=oracle_serial+1
  local prefix=directory .. "/oracle-" .. oracle_serial
  local input=prefix .. ".mmd"
  local png=prefix .. ".png"
  vim.fn.writefile(body,input)
  local fit=math.max(1,s.frame.width-64)
  command({binary,"render",input,"--format","png","--output",png,
    "--theme",palette==1 and "dark" or "default","--background",schemes[palette].bg,
    "--raster-fit-width",tostring(fit),"--raster-max-width",tostring(fit),
    "--raster-max-height","4096","--raster-max-pixels",tostring(math.min(fit*4096,4194304)),
    "--resource-profile","interactive","--operation-timeout-ms","5000","--quiet"})
  local actual=diagram(s)
  local w,h=dimensions(actual)
  assert(w<=fit and h<=4096 and w*h<=4194304,"unbounded intermediate Mermaid raster")
  assert(pixels_equal(png,actual),"Mermaid raster is not the current source/width/background")
  local markdown=prefix .. ".md"
  vim.fn.writefile(document(body,png),markdown)
  local frame=prefix .. "-viewport.png"
  native_frame(markdown,s,frame)
  assert(displayed,"native frame was not displayed")
  local shown=save(prefix .. "-displayed.png",displayed)
  if s.mode=="split" then
    -- Split intentionally clips at the source viewport's last block. The ordinary-image
    -- oracle has different source-line counts; compare the complete visible diagram,
    -- not following paragraphs that may correctly be clipped in the actual split.
    local block_y
    for _, f in ipairs(s.fragments) do if f.line==3 then block_y=f.y; break end end
    local visible=math.min(s.frame.height,math.floor(assert(block_y)+h-s.frame.y))
    assert(visible>0,"split viewport misses the diagram")
    local geometry=s.frame.width .. "x" .. visible .. "+0+0"
    command({"magick",frame,"-crop",geometry,"+repage",prefix .. "-expected-region.png"})
    command({"magick",shown,"-crop",geometry,"+repage",prefix .. "-shown-region.png"})
    assert(pixels_equal(prefix .. "-expected-region.png",prefix .. "-shown-region.png"),
      "split viewport does not contain the complete visible diagram")
  else
    assert(pixels_equal(frame,shown),"displayed viewport does not contain the correctly laid-out diagram")
  end
  return actual,w,h
end
local function anchors(s, body)
  local first,last=3,#body+4
  local y,seen=nil,{}
  for _, f in ipairs(s.fragments) do
    if f.line>=first and f.line<=last then
      assert(f.column==0 and f.finish==0,"diagram invents relation-level source attribution")
      assert(not seen[f.line],"diagram source line has multiple anchors")
      if y then assert(f.y==y,"diagram lines do not share the block's vertical anchor") else y=f.y end
      seen[f.line]=true
    end
  end
  for line=first,last do assert(seen[line],"missing block anchor at source line " .. line) end
  return y
end
local function edit(s, body)
  api.nvim_buf_set_lines(s.source_buf,0,-1,false,document(body))
end
local function prepare_source()
  api.nvim_set_current_buf(vim.fn.bufnr(source))
  api.nvim_win_set_cursor(0,{1,0})
  vim.wo.wrap=false; vim.wo.number=false; vim.wo.signcolumn="no"
  vim.cmd("normal! ggzt")
end
local function close(s)
  mdview.close()
  wait(function() return not mdview.status() and vim.fn.isdirectory(s.directory)==0 end,"session/diagram cleanup")
  assert(vim.fn.jobwait({s.job},0)[1]~=-1,"native worker survived close")
  assert(not displayed,"closed session left its image displayed")
  assert(api.nvim_buf_is_valid(s.source_buf),"close deleted the unsaved source")
end
local function alive(pid)
  local stat=io.open("/proc/" .. pid .. "/stat","r")
  if not stat then return false end
  local text=stat:read("*a"); stat:close()
  local state=text:match("^%d+ %(.+%) (%S)")
  return state~=nil and state~="Z" and state~="X"
end
local function check()
  assert(vim.fn.executable(binary)==1,"missing evaluated Merman binary: " .. binary)
  assert(vim.fn.executable(worker)==1,"missing built native worker: " .. worker)
  assert(vim.fn.executable("magick")==1,"ImageMagick is required for pixel regression checks")
  vim.fn.writefile({"#!/bin/sh",
    "printf '%s\\n' \"$$\" >> " .. quote(calls),
    "if [ -f " .. quote(pause) .. " ]; then",
    "  IFS= read -r delay < " .. quote(pause),
    "  sleep \"$delay\" & child=$!",
    "  printf '%s %s\\n' \"$$\" \"$child\" >> " .. quote(children),
    "  trap 'kill \"$child\" 2>/dev/null; wait \"$child\"; exit 143' TERM INT",
    "  wait \"$child\"",
    "fi",
    "exec " .. quote(binary) .. " \"$@\""},wrapper)
  assert(vim.uv.fs_chmod(wrapper,493))
  vim.fn.writefile(disk,source)
  vim.o.background="dark"; vim.o.columns=110; vim.o.lines=36
  vim.cmd("edit " .. vim.fn.fnameescape(source))
  prepare_source()
  -- No opt-in: the same embedded reference stays literal code and matches the existing worker.
  mdview.setup({raw=false,smooth=false,clamp=false,zbelow=false})
  mdview.open("replace")
  wait(function() local s=mdview.status(); return s and settled(s) end,"literal baseline")
  local baseline=mdview.status()
  native_frame(source,baseline,directory .. "/literal.png")
  assert(pixels_equal(directory .. "/literal.png",save(directory .. "/literal-displayed.png",assert(displayed))),"unconfigured Mermaid stopped rendering as literal code")
  assert(call_count()==0,"renderer ran without Mermaid opt-in")
  close(baseline)

  for _, mode in ipairs({"replace","split"}) do
    vim.o.columns=110; vim.o.lines=36
    prepare_source()
    api.nvim_buf_set_lines(0,0,-1,false,disk)
    scheme(1)
    mdview.setup({theme="nvim",mermaid={renderer=wrapper}})
    local before=call_count()
    mdview.open(mode)
    wait(function() local s=mdview.status(); return s and settled(s) end,mode .. " automatic first render")
    local s=mdview.status()
    assert(call_count()>before,"opening Mermaid did not invoke the real renderer automatically")
    assert(s.frame.width==api.nvim_win_get_width(s.preview_win)*10 and s.frame.height==api.nvim_win_get_height(s.preview_win)*20,"diagram viewport ignores terminal cell geometry")
    anchors(s,reference)
    local first_png=matches_reference(s,reference,1)
    local original_png=save(directory .. "/" .. mode .. "-original.png",contents(first_png))

    local unsaved={}
    for _, line in ipairs(reference) do unsaved[#unsaved+1]=line:gsub("users","unsaved_accounts") end
    local revision=s.revision
    edit(s,unsaved)
    wait(function() return s.revision>revision and settled(s) end,mode .. " unsaved diagram edit")
    local changed=matches_reference(s,unsaved,1)
    assert(not pixels_equal(original_png,changed),"unsaved diagram edit did not change rendered pixels")
    assert(vim.deep_equal(vim.fn.readfile(source),disk),"diagram render wrote the unsaved buffer to disk")

    edit(s,{"erDiagram",'users ||--o{ buyers : "incompleto'})
    wait(function() return s.error and not s.busy and not s.dirty and not s.debouncing end,mode .. " invalid diagram")
    assert(not s.loaded and not displayed,"invalid diagram retained an old displayed image")
    assert(#vim.fn.glob(s.directory .. "/diagrams/*",false,true)==0,"failed LOAD retained diagram files")
    local error_renders=renders
    vim.wait(300,function() return false end,10)
    assert(renders==error_renders and not displayed,"invalid diagram redisplayed stale pixels")
    revision=s.revision
    edit(s,unsaved)
    wait(function() return s.revision>revision and settled(s) end,mode .. " invalid/fix recovery")
    matches_reference(s,unsaved,1)

    -- Start a real LOAD, then change the source while its bounded subprocess is still pending.
    vim.fn.writefile({"0.4"},pause)
    before=call_count()
    local draft={}
    for _, line in ipairs(reference) do draft[#draft+1]=line:gsub("users","draft_accounts") end
    edit(s,draft)
    wait(function() return call_count()>before and s.busy end,mode .. " in-flight burst start")
    vim.fn.delete(pause)
    local newest
    for n=1,6 do
      newest={}
      for _, line in ipairs(reference) do newest[#newest+1]=line:gsub("users","newest_accounts_" .. n) end
      edit(s,newest)
    end
    wait(function() return settled(s) end,mode .. " rapid revision convergence")
    assert(call_count()-before<=2,"rapid edits rendered every obsolete diagram revision")
    anchors(s,newest)
    matches_reference(s,newest,1)

    local old_width=select(1,dimensions(diagram(s)))
    revision=s.revision
    local resize_window
    if mode=="replace" then
      -- 'columns' alone does not resize a headless grid. Change the real window geometry.
      api.nvim_set_current_win(s.preview_win)
      vim.cmd("rightbelow vsplit")
      resize_window=api.nvim_get_current_win()
      api.nvim_win_set_buf(resize_window,api.nvim_create_buf(false,true))
      api.nvim_win_set_width(s.preview_win,45)
      api.nvim_set_current_win(s.preview_win)
      api.nvim_exec_autocmds("WinResized",{})
    else
      api.nvim_win_set_width(s.preview_win,35)
      api.nvim_exec_autocmds("WinResized",{})
    end
    wait(function() return s.revision>revision and settled(s) and s.frame.width==api.nvim_win_get_width(s.preview_win)*10 end,mode .. " diagram resize")
    local dark_png,resized_width=matches_reference(s,newest,1)
    assert(resized_width<old_width,"width reload reused the old intermediate raster")
    local dark_copy=save(directory .. "/" .. mode .. "-before-theme.png",contents(dark_png))
    revision=s.revision
    scheme(2)
    api.nvim_exec_autocmds("ColorScheme",{})
    wait(function() return s.revision>revision and settled(s) end,mode .. " theme reload")
    local light_png=matches_reference(s,newest,2)
    assert(not pixels_equal(dark_copy,light_png),"theme reload did not recolor the diagram itself")

    local png_bytes=contents(light_png)
    local mtime=assert(vim.uv.fs_stat(light_png)).mtime
    before=call_count()
    revision=s.revision
    local sequence=s.sequence
    if mode=="replace" then
      for _, y in ipairs({100,220,300}) do
        s.scroll_to(y)
        wait(function() return settled(s) and s.frame.y==y end,"reader diagram scroll " .. y)
      end
    else
      for _, line in ipairs({10,20}) do
        api.nvim_win_call(s.source_win,function() vim.cmd("normal! " .. line .. "Gzt") end)
        api.nvim_exec_autocmds("WinScrolled",{})
        wait(function() return settled(s) and s.frame.line==line end,"split diagram block scroll " .. line)
      end
      assert(s.frame.y==math.floor(anchors(s,newest)),"scroll inside a diagram did not stay on its block anchor")
    end
    assert(s.sequence>sequence and s.revision==revision,"scroll did not DRAW the existing layout")
    assert(call_count()==before,"scroll reran Merman instead of drawing the loaded diagram")
    assert(contents(light_png)==png_bytes and vim.deep_equal(assert(vim.uv.fs_stat(light_png)).mtime,mtime),"scroll rewrote intermediate diagram pixels")
    matches_reference(s,newest,2)
    assert(vim.deep_equal(vim.fn.readfile(source),disk),"reload/burst changed the source file")
    close(s)
    if resize_window and api.nvim_win_is_valid(resize_window) then api.nvim_win_close(resize_window,true) end

    -- Reopening uses the unsaved buffer, creates a fresh raster, and does not resurrect closed pixels.
    prepare_source()
    before=call_count()
    mdview.open(mode)
    wait(function() local reopened=mdview.status(); return reopened and settled(reopened) end,mode .. " reopen")
    local reopened=mdview.status()
    assert(call_count()>before,"reopen did not render its own diagram")
    matches_reference(reopened,newest,2)
    close(reopened)
  end

  -- A concealed closing fence can remain winsaveview().topline even when the
  -- heading for the next diagram is the first visible source content.
  if vim.fn.has("nvim-0.11")==1 then
    prepare_source()
    local two={"# Two diagrams","","```mermaid"}
    vim.list_extend(two,reference)
    two[#two+1]="```"
    local closing=#two
    two[#two+1]="## Second diagram"
    local heading=#two
    two[#two+1]="```mermaid"
    local second=#two
    vim.list_extend(two,vim.fn.readfile(root .. "/tests/merman/boundary.mmd"))
    two[#two+1]="```"
    for n=1,60 do two[#two+1]="Trailing paragraph " .. n end
    api.nvim_buf_set_lines(0,0,-1,false,two)
    vim.wo.conceallevel=2
    vim.wo.concealcursor="nvic"
    local ns=api.nvim_create_namespace("mermaid-concealed-fence")
    api.nvim_buf_set_extmark(0,ns,closing-1,0,{conceal_lines=""})
    mdview.open("split")
    wait(function() local s=mdview.status(); return s and settled(s) end,"two-diagram concealed-fence layout")
    local s=mdview.status()
    local heading_y,second_y
    for _,f in ipairs(s.fragments) do
      if f.line==heading then heading_y=f.y end
      if f.line==second then second_y=f.y end
    end
    assert(heading_y and second_y and second_y>heading_y,"missing second diagram geometry")
    local count,revision=call_count(),s.revision
    api.nvim_win_call(s.source_win,function()
      vim.cmd("normal! " .. closing .. "Gzt")
      assert(vim.fn.winsaveview().topline==closing,"concealed fence is not the logical topline")
      assert(api.nvim_win_text_height(s.source_win,{start_row=closing-1,end_row=closing-1}).all==0,
        "closing fence is not concealed")
    end)
    api.nvim_exec_autocmds("WinScrolled",{})
    wait(function() return settled(s) and s.frame.line==heading end,"split follows visible heading instead of concealed previous fence",2500)
    assert(s.frame.y==math.floor(heading_y),"split kept the first diagram at the visible second heading")
    assert(call_count()==count and s.revision==revision,"concealed-line scrolling rebuilt diagrams")
    close(s)
    api.nvim_buf_clear_namespace(0,ns,0,-1)
    vim.wo.conceallevel=0
    vim.wo.concealcursor=""
  end

  -- Cursor reveal does not need the source viewport to move, and keeps the
  -- complete next diagram visible when its preceding heading becomes active.
  prepare_source()
  vim.o.columns=160; vim.o.lines=30
  local two={"# Cursor follow","","```mermaid"}
  vim.list_extend(two,reference)
  two[#two+1]="```"; two[#two+1]=""
  local heading=#two+1
  two[#two+1]="## Second diagram"; two[#two+1]=""
  local second=#two+1
  two[#two+1]="```mermaid"
  vim.list_extend(two,vim.fn.readfile(root .. "/tests/merman/boundary.mmd"))
  two[#two+1]="```"; two[#two+1]=""
  local paragraphs={}
  for n=1,60 do
    paragraphs[#paragraphs+1]="Trailing paragraph " .. n
    paragraphs[#paragraphs+1]=""
  end
  vim.list_extend(two,paragraphs)
  api.nvim_buf_set_lines(0,0,-1,false,two)
  mdview.setup({split_follow="cursor"})
  mdview.open("split")
  wait(function() local s=mdview.status(); return s and settled(s) end,"cursor-follow layout")
  local followed=mdview.status()
  local heading_y,second_y
  for _,f in ipairs(followed.fragments) do
    if f.line==heading then heading_y=f.y end
    if f.line==second then second_y=f.y end
  end
  local pngs=vim.fn.glob(followed.directory .. "/diagrams/*.png",false,true)
  table.sort(pngs)
  local _,second_height=dimensions(pngs[2])
  local expected_bottom=math.ceil(assert(second_y)+second_height)
  assert(expected_bottom-math.floor(assert(heading_y))<=followed.frame.height,"second diagram cannot fit this test viewport")
  local function moved(line,col)
    api.nvim_win_set_cursor(followed.source_win,{line,col or 0})
    api.nvim_exec_autocmds("CursorMoved",{buffer=followed.source_buf})
  end
  api.nvim_win_call(followed.source_win,function() vim.cmd("normal! 17Gzt") end)
  api.nvim_exec_autocmds("WinScrolled",{})
  wait(function() return settled(followed) and followed.frame.line==17 end,"first active diagram")
  local source_top=api.nvim_win_call(followed.source_win,vim.fn.winsaveview).topline
  local old_y=followed.frame.y
  local count,revision=call_count(),followed.revision
  moved(heading)
  wait(function() return settled(followed) and followed.frame.y~=old_y end,"cursor reveals next diagram without source scroll")
  assert(api.nvim_win_call(followed.source_win,vim.fn.winsaveview).topline==source_top,"cursor-follow test scrolled the source")
  assert(followed.frame.y==expected_bottom-followed.frame.height,"cursor reveal moved more than necessary")
  assert(followed.frame.y<=math.floor(heading_y),"cursor reveal clipped the active heading")
  local revealed_y=followed.frame.y
  local sequence=followed.frame.sequence
  moved(second+3)
  wait(function() return settled(followed) and followed.frame.sequence>sequence end,"cursor inside already visible diagram")
  assert(followed.frame.y==revealed_y,"moving inside a visible diagram unnecessarily repositioned it")
  assert(call_count()==count and followed.revision==revision,"cursor movement regenerated diagrams")
  local oracle={"# Cursor follow","","![First](" .. pngs[1] .. ")","","## Second diagram","","![Second](" .. pngs[2] .. ")",""}
  vim.list_extend(oracle,paragraphs)
  local oracle_path=directory .. "/cursor-oracle.md"
  vim.fn.writefile(oracle,oracle_path)
  native_frame(oracle_path,followed,directory .. "/cursor-oracle.png")
  assert(pixels_equal(directory .. "/cursor-oracle.png",save(directory .. "/cursor-shown.png",assert(displayed))),
    "revealed diagram differs from the independent ordinary-image viewport")
  -- Returning to a tall graph reveals its start, not a guessed relation position.
  moved(18)
  wait(function() return settled(followed) and followed.frame.y==math.floor(anchors(followed,reference)) end,"cursor returns to tall first diagram")
  local first_y=followed.frame.y
  sequence=followed.frame.sequence
  moved(19)
  wait(function() return settled(followed) and followed.frame.sequence>sequence end,"cursor moves inside tall graph")
  assert(followed.frame.y==first_y,"tall diagram oscillated on cursor movement")
  -- Height-only resize reuses diagrams and prioritizes graph start when it no longer fits.
  moved(heading)
  sequence=followed.frame.sequence
  vim.o.equalalways=false
  local lower=api.nvim_win_call(followed.preview_win,function()
    vim.cmd("belowright new")
    return api.nvim_get_current_win()
  end)
  api.nvim_win_set_height(followed.preview_win,4)
  api.nvim_exec_autocmds("WinResized",{})
  wait(function() return settled(followed) and followed.frame.sequence>sequence
    and followed.frame.height==api.nvim_win_get_height(followed.preview_win)*20 end,"cursor reveal after height shrink")
  assert(followed.frame.y==math.floor(second_y),"short viewport did not prioritize the active diagram's start: "
    .. vim.inspect({frame=followed.frame,second_y=second_y,cursor=api.nvim_win_get_cursor(followed.source_win),
      view=api.nvim_win_call(followed.source_win,vim.fn.winsaveview),request=followed.request_cursor_key}))
  assert(call_count()==count and followed.revision==revision,"height resize regenerated diagrams")
  api.nvim_win_close(lower,true)
  api.nvim_exec_autocmds("WinResized",{})
  wait(function() return settled(followed) and followed.frame.height==api.nvim_win_get_height(followed.preview_win)*20 end,"cursor reveal height restore")
  -- Width reflow must use the current diagram geometry, not the previous frame's bounds.
  api.nvim_win_set_width(followed.preview_win,50)
  api.nvim_exec_autocmds("WinResized",{})
  wait(function() return settled(followed) and followed.revision>revision end,"cursor reveal width reflow")
  for _,f in ipairs(followed.fragments) do if f.line==second then second_y=f.y end end
  pngs=vim.fn.glob(followed.directory .. "/diagrams/*.png",false,true)
  table.sort(pngs)
  _,second_height=dimensions(pngs[2])
  assert(followed.frame.y<=math.floor(second_y) and followed.frame.y+followed.frame.height>=math.ceil(second_y+second_height),
    "width reflow failed to reveal the newly sized active graph")
  -- Latest cursor wins across rapid movements, including ordinary Markdown text.
  local final_line=#two-1
  for _,line in ipairs({#two-21,#two-11,final_line}) do moved(line) end
  wait(function() return settled(followed) and followed.request_cursor_key==final_line .. ":0:" .. final_line end,"latest ordinary-text cursor reveal")
  local final_y
  for _,f in ipairs(followed.fragments) do if f.line==final_line and f.column==0 then final_y=f.y end end
  assert(final_y and final_y>=followed.frame.y and final_y<followed.frame.y+followed.frame.height,
    "latest active ordinary text stayed outside the rendered viewport")
  close(followed)
  mdview.setup({split_follow="viewport"})

  -- Closing a pending LOAD must terminate both the native child and its wrapper's sleeping child.
  prepare_source()
  vim.fn.writefile({"4"},pause)
  local markers=vim.fn.filereadable(children)==1 and #vim.fn.readfile(children) or 0
  mdview.open("replace")
  local pending=mdview.status()
  local pid,child
  wait(function()
    if vim.fn.filereadable(children)==0 then return false end
    local records=vim.fn.readfile(children)
    if #records<=markers then return false end
    pid,child=records[#records]:match("^(%d+) (%d+)$")
    return pid and alive(pid) and alive(child) and pending.busy
  end,"pending renderer child")
  mdview.close()
  wait(function() return not alive(pid) and not alive(child) and vim.fn.isdirectory(pending.directory)==0 end,"pending child/process-group cancellation",2500)
  assert(not mdview.status() and not displayed,"pending close retained preview state")
  assert(api.nvim_buf_is_valid(pending.source_buf),"pending close lost unsaved source")
  print("PASS: opt-in Mermaid real pixels in replace/split, automatic render, unsaved edits, error recovery, revision coalescing, resize/theme, LOAD-only rendering, reopen/cleanup and pending child cancellation")
end
local ok,err=xpcall(check,debug.traceback)
mdview.close()
for _, name in ipairs(names) do api.nvim_set_hl(0,name,highlights[name]) end
for name,value in pairs(original) do vim.o[name]=value end
for _, name in ipairs(env_names) do vim.env[name]=environment[name] end
if not ok then io.stderr:write(err .. "\nArtifacts: " .. directory .. "\n"); vim.cmd("cquit 1") end
vim.fn.delete(directory,"rf")
vim.cmd("qall!")
