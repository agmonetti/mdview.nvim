-- Run: nvim --headless -u NONE -l tests/cursor.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api=vim.api
package.preload["image"]=function()
  return {from_file=function() return {id="cursor-test",global_state={images={}},clear=function() end,render=function() end} end}
end
package.preload["image.utils.term"]=function()
  return {get_size=function() return {cell_width=10,cell_height=20} end}
end
local mdview=require("mdview")
mdview.setup({raw=false,smooth=false,zbelow=false})
local initial=vim.o.guicursor
local function visible() assert(vim.o.guicursor==initial,"cursor configuration leaked outside viewer") end
local function hidden()
  assert(vim.o.guicursor:find("MdviewHiddenCursor",1,true),"focused viewer cursor is visible")
  assert(api.nvim_get_hl(0,{name="MdviewHiddenCursor",link=false}).blend==100)
end
local function wait_frame()
  assert(vim.wait(10000,function() local s=mdview.status(); return s and s.frame and not s.busy end,10),"missing native frame")
end
local function check()
  api.nvim_buf_set_lines(0,0,-1,false,{"# Cursor fixture","","Text."})
  mdview.open("replace"); wait_frame(); hidden()
  local s=mdview.status()
  local float=api.nvim_open_win(api.nvim_create_buf(false,true),true,{relative="editor",row=2,col=2,width=20,height=2,style="minimal"})
  visible()
  api.nvim_win_close(float,true); hidden()
  api.nvim_exec_autocmds("CmdlineEnter",{pattern=":"}); visible()
  api.nvim_exec_autocmds("CmdlineLeave",{pattern=":"})
  vim.wait(50,function() return false end,10); hidden()
  api.nvim_set_hl(0,"MdviewHiddenCursor",{})
  api.nvim_exec_autocmds("ColorScheme",{}); hidden()
  -- Editing leaves the viewer and restores the exact original setting.
  vim.cmd("normal e")
  assert(api.nvim_get_current_buf()==s.source_buf and not mdview.status(),"edit did not restore source")
  visible()
  vim.wait(50,function() return not mdview.status() end,10)
  mdview.close(); visible()
  mdview.open("split"); wait_frame(); visible()
  s=mdview.status()
  api.nvim_set_current_win(s.preview_win); hidden()
  api.nvim_set_current_win(s.source_win); visible()
  api.nvim_set_current_win(s.preview_win); hidden()
  mdview.close(); visible()
  -- Closing must not overwrite a newer user/plugin cursor configuration.
  mdview.open("replace"); wait_frame(); hidden()
  vim.o.guicursor="a:ver25"
  mdview.close()
  assert(vim.o.guicursor=="a:ver25","close overwrote external cursor change")
end
local ok,err=xpcall(check,debug.traceback)
mdview.close(); vim.o.guicursor=initial
if not ok then io.stderr:write(err.."\n"); vim.cmd("cquit 1") end
print("PASS: viewer cursor focus, float/cmdline/edit/split transitions, colorscheme, close restoration")
vim.cmd("qa!")
