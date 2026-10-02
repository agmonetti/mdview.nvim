-- Run from repository root: nvim --headless -u NONE -l tests/details.lua
local api = vim.api
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/mdview.lua")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local shown
package.preload["image"] = function()
  return {from_file=function(path)
    return {id="details-test", global_state={images={}}, original_path=path,
      clear=function() shown=nil end, render=function(self) shown=assert(io.open(self.original_path,"rb")):read("*a") end}
  end}
end
package.preload["image.utils.term"] = function()
  return {get_size=function() return {cell_width=10,cell_height=20} end}
end
local mdview=require("mdview")
local function wait_for(predicate,label)
  assert(vim.wait(15000,predicate,10),label .. ": " .. tostring(mdview.status() and mdview.status().error))
end
local function settled()
  local s=mdview.status()
  return s and s.frame and s.loaded and not s.busy and not s.dirty and not s.debouncing and not s.error
    and s.frame.revision==s.revision
end
local function details(s)
  local list=vim.tbl_values(s.details)
  table.sort(list,function(a,b) return a.start_line<b.start_line end)
  return list
end
local function file(path)
  local f=assert(io.open(path,"rb")); local bytes=f:read("*a"); f:close(); return bytes
end
local source=directory .. "/document.md"
vim.fn.writefile({
  "# Before", "", "<details>", "  <summary><b>Outer &amp; title</b></summary>", "",
  "  ### Body heading", "  Outer body", "", "  <details>",
  "    <summary>Inner title</summary>", "", "    Inner body", "  </details>",
  "", "  Outer tail", "</details>", "", "After details", "",
  "<details>", "  <summary>Independent title</summary>", "", "  Independent body", "</details>", "", "# Last"
},source)
local disk=file(source)
local function check()
  for _, width in ipairs({360,700}) do
    local outputs={}
    for _, mode in ipairs({"plain","marked"}) do
      local result=vim.system({root.."/build/mdview-preview","--html",source,root.."/styles/markdown.css",mode},
        {text=true}):wait()
      assert(result.code==0,result.stderr)
      local html=directory.."/details-"..width.."-"..mode..".html"
      local out=html..".png"
      local f=assert(io.open(html,"wb")); assert(f:write(result.stdout)); f:close()
      vim.fn.writefile({"bestfit: false","width: "..width,"height: 1500"},html..".cfg")
      local rendered=vim.system({root.."/build/mdview-render",html,out,tostring(width)},{text=true}):wait()
      assert(rendered.code==0,rendered.stderr)
      outputs[mode]=out
    end
    local compared=vim.system({"magick","compare","-metric","AE",outputs.plain,outputs.marked,"null:"},
      {text=true}):wait()
    assert(compared.code==0 or compared.code==1,compared.stderr)
    assert(tonumber(compared.stderr:match("^[%d.]+"))==0,"details source labels changed rendered pixels at "..width)
  end
  mdview.setup({raw=false,smooth=false,theme="nvim",alerts=true,html=true})
  vim.cmd.edit(vim.fn.fnameescape(source))
  mdview.open("replace")
  wait_for(settled,"initial reader")
  local s=mdview.status()
  local list=details(s)
  assert(#list==3 and list[1].open and list[2].open and list[3].open,"default open or nested details missing")
  local full_height=s.document_height
  local outer,inner,independent=list[1],list[2],list[3]
  assert(outer.start_line<inner.start_line and inner.end_line<outer.end_line,"source ranges wrong")
  local function line_y(state,line)
    local y
    for _,f in ipairs(state.fragments) do if f.line==line then y=math.min(y or f.y,f.y) end end
    return y
  end
  assert(line_y(s,12) and line_y(s,12)>inner.y,"open body lacks its own anchor")
  local revision=s.revision
  vim.cmd("normal za")
  assert(s.revision==revision and s.selected_detail==nil,"za toggled without selection")
  local before=shown
  vim.cmd("normal ]d")
  wait_for(function() return settled() and s.selected_detail==outer.id and shown~=before end,"visible reader selection")
  local selected=shown
  vim.cmd("normal ]d")
  wait_for(function() return settled() and s.selected_detail==inner.id and shown~=selected end,"nested reader navigation")
  vim.cmd("normal [d")
  wait_for(function() return settled() and s.selected_detail==outer.id end,"previous details selection")
  s.scroll_to(240)
  wait_for(function() return settled() and s.frame.y==240 end,"reader scrolled with detail selection")
  assert(s.selected_detail==outer.id and s.details[outer.id].open,"scroll changed selected detail state")
  s.scroll_to(outer.y)
  wait_for(function() return settled() and s.frame.y==math.floor(outer.y) end,"reader returned to selected header")
  local before_toggles=s.revision
  s.toggle_detail(inner.id)
  s.toggle_detail(inner.id)
  wait_for(function()
    return settled() and s.revision==before_toggles+2 and s.details[inner.id].open
  end,"rapid opposite toggles converged to open")
  assert(s.frame.revision==s.revision and s.document_height==full_height,"old frame published after rapid toggles")
  s.toggle_detail(inner.id)
  wait_for(function() return settled() and not mdview.status().details[inner.id].open end,"close inner")
  s=mdview.status()
  local inner_height=s.document_height
  assert(inner_height<full_height and s.details[outer.id].open and s.details[independent.id].open,"inner did not reflow independently")
  assert(math.abs(assert(line_y(s,12))-s.details[inner.id].y)<1,"closed body does not anchor to its header")
  assert(math.abs(s.details[inner.id].y - inner.y)<1,"toggling moved header in document layout")
  s.toggle_detail(outer.id)
  wait_for(function() return settled() and not mdview.status().details[outer.id].open end,"close outer")
  s=mdview.status()
  assert(s.document_height<inner_height and s.details[independent.id].open,"outer did not reflow")
  assert(s.details[outer.id].height>0,"closed header has no hitbox")
  assert(math.abs(assert(line_y(s,12))-s.details[outer.id].y)<1,"hidden nested body did not navigate to visible outer header")
  s.toggle_detail(outer.id)
  wait_for(function() return settled() and mdview.status().details[outer.id].open end,"reopen outer")
  assert(mdview.status().details[inner.id].open==false,"nested state lost when outer reopened")
  assert(shown and #shown>0,"no rendered viewport")
  api.nvim_buf_set_lines(s.source_buf,0,0,false,{"New line before details"})
  wait_for(function()
    local current=mdview.status()
    if not settled() or #details(current)~=3 then return false end
    local blocks=details(current)
    return blocks[1].start_line==outer.start_line+1 and not blocks[2].open
  end,"unique unchanged nested state after edit")
  assert(file(source)==disk,"toggle or unsaved edit wrote source file")
  api.nvim_buf_set_lines(s.source_buf,12,13,false,{"    Changed inner body"})
  wait_for(function()
    local current=mdview.status()
    return settled() and #details(current)==3 and details(current)[2].open
  end,"changed block reopened instead of borrowing prior state")
  assert(file(source)==disk,"changed details content wrote disk")
  api.nvim_buf_set_lines(s.source_buf,4,5,false,{"  <summary></summary>"})
  wait_for(function() return settled() and #details(mdview.status())==1 end,"malformed outer block fell back locally")
  assert(line_y(s,27) and file(source)==disk,"invalid block removed following source or wrote disk")
  api.nvim_buf_set_lines(s.source_buf,4,5,false,{"  <summary><b>Outer &amp; title</b></summary>"})
  wait_for(function() return settled() and #details(mdview.status())==3 end,"corrected block recovered in same worker")
  mdview.close()
  mdview.open("split")
  wait_for(settled,"split opened")
  s=mdview.status()
  list=details(s)
  assert(list[1].open and list[2].open,"close/reopen retained session state")
  api.nvim_win_set_cursor(s.source_win,{list[2].start_line,0})
  vim.cmd("MdViewToggleDetail")
  wait_for(function() return settled() and not mdview.status().details[list[2].id].open end,"split innermost toggle")
  assert(mdview.status().details[list[1].id].open,"split toggled outer instead of inner")
  local old_width=s.width
  vim.o.equalalways=false
  api.nvim_win_set_width(s.preview_win,math.max(10,api.nvim_win_get_width(s.preview_win)-4))
  api.nvim_exec_autocmds("WinResized",{})
  wait_for(function()
    return settled() and s.width~=old_width and not details(s)[2].open
  end,"resize retained unique closed state")
  local palette_revision=s.revision
  api.nvim_set_hl(0,"Normal",{fg="#fefefe",bg="#102030"})
  api.nvim_exec_autocmds("ColorScheme",{})
  wait_for(function()
    return settled() and s.revision>palette_revision and not details(s)[2].open
  end,"palette reload retained unique closed state")
  api.nvim_win_set_cursor(s.source_win,{1,0})
  local revision=s.revision
  vim.cmd("MdViewToggleDetail")
  assert(s.revision==revision and s.details[list[1].id].open,"outside command changed layout")
  mdview.close()
  mdview.setup({html=false})
  mdview.open("replace")
  wait_for(function()
    local current=mdview.status()
    return current and current.error and current.error:find("Raw HTML is not supported",1,true) and not current.loaded
  end,"html=false rejects raw details")
  mdview.close()
  assert(file(source)==disk,"source file changed")
  print("PASS: nested details reflow, hidden anchors, reader selection, unique-state preservation and changed-block reset, split toggle, session reset, html opt-out")
end
local ok,err=xpcall(check,debug.traceback)
mdview.close()
vim.fn.delete(directory,"rf")
if not ok then error(err) end
