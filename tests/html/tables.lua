-- Run: nvim --headless -u NONE -l tests/html/tables.lua
local api=vim.api
local root=vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local directory=(vim.env.TMPDIR or '/tmp') .. '/mdview-tables-' .. vim.fn.getpid()
vim.fn.mkdir(directory,'p')
local function bytes(path)
  local file=assert(io.open(path,'rb')); local data=file:read('*a'); file:close(); return data
end
local function save(path,text)
  local file=assert(io.open(path,'wb')); assert(file:write(text)); file:close()
end
local function hex(value) return (value:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
local mdview,displayed
package.preload['image']=function()
  return {from_file=function(path)
    return {id='table-test',global_state={images={}},original_path=path,
      clear=function() displayed=nil end,
      render=function(self) displayed=bytes(self.original_path) end}
  end}
end
package.preload['image.utils.term']=function()
  return {get_size=function() return {cell_width=10,cell_height=20} end}
end
mdview=require('mdview')
for _,name in ipairs({'FPLOG_RAW','FPLOG_SMOOTH','FPLOG_RAW_ZBELOW','KITTY_WINDOW_ID'}) do vim.env[name]=nil end
local worker=root .. '/build/mdview-preview'
local css=root .. '/styles/markdown.css'
local function settled(s)
  return s and s.loaded and s.frame and not s.busy and not s.dirty and not s.debouncing
    and not s.error and s.frame.revision==s.revision
end
local function wait(label)
  assert(vim.wait(30000,function() return settled(mdview.status()) end,10),label .. ': ' .. tostring(mdview.status() and mdview.status().error))
end
local function document(value)
  return '# Top\n\n<table><thead><tr><th>Item</th><th>Value</th></tr></thead>\n'
    .. '<tbody><tr><td>One</td><td>' .. value .. '</td></tr>'
    .. '<tr><td colspan="2">A long cell that wraps across several viewport widths with plain text.</td></tr></tbody></table>\n\n# Bottom'
end
local function oracle(s)
  local snapshot=directory .. '/snapshot.md'
  save(snapshot,table.concat(api.nvim_buf_get_lines(s.source_buf,0,-1,false),'\n') .. '\n')
  local output=directory .. '/oracle.png'
  local botline=0
  if s.mode=='split' then botline=api.nvim_win_call(s.source_win,function() return vim.fn.line('w$',s.source_win) end) end
  local request=table.concat({'LOAD',1,s.frame.width,hex(snapshot),hex(directory),hex(s.stylesheet)},' ')
    .. '\n' .. table.concat({'DRAW',1,1,0,s.frame.y,botline,s.frame.height,hex(output)},' ') .. '\nQUIT\n'
  local result=vim.system({worker},{text=true,stdin=request}):wait(30000)
  assert(result.code==0 and result.stdout:find('FRAME 1 1 ',1,true),result.stdout .. result.stderr)
  assert(displayed==bytes(s.frame_path),'display did not publish latest table frame')
  local compare=vim.system({'magick','compare','-metric','AE',output,s.frame_path,'null:'},{text=true}):wait(30000)
  assert(compare.code==0 and tonumber(compare.stderr:match('^[%d.]+'))==0,'table frame differs from unsaved source oracle: ' .. compare.stderr)
end
local function run()
  vim.o.columns=120; vim.o.lines=32; vim.o.equalalways=false
  local source=directory .. '/source.md'
  save(source,'# Unmodified file\n')
  vim.cmd('edit ' .. vim.fn.fnameescape(source))
  local buf=api.nvim_get_current_buf()
  for _,mode in ipairs({'replace','split'}) do
    api.nvim_buf_set_lines(buf,0,-1,false,vim.split(document('Initial'), '\n',{plain=true}))
    mdview.setup({renderer=worker,stylesheet=css,raw=false,smooth=false,zbelow=false,mermaid=false})
    mdview.open(mode)
    wait(mode .. ' open')
    local s=mdview.status()
    local job=s.job
    oracle(s)
    local initial=displayed
    local revision=s.revision
    api.nvim_buf_set_lines(s.source_buf,0,-1,false,vim.split(document('Edited long value'), '\n',{plain=true}))
    api.nvim_exec_autocmds('TextChanged',{buffer=s.source_buf})
    assert(vim.wait(30000,function() return settled(s) and s.revision>revision end,10),mode .. ' edit: ' .. tostring(s.error))
    assert(s.job==job and bytes(source)=='# Unmodified file\n' and vim.bo[s.source_buf].modified)
    assert(displayed~=initial,'table edit did not change raster')
    oracle(s)
    if mode=='split' then
      local width=s.frame.width
      api.nvim_win_set_width(s.preview_win,math.max(35,api.nvim_win_get_width(s.preview_win)-12))
      api.nvim_exec_autocmds('WinResized',{})
      assert(vim.wait(30000,function() return settled(s) and s.frame.width~=width end,10),'table width reflow')
      oracle(s)
    end
    mdview.close()
    assert(not mdview.status() and bytes(source)=='# Unmodified file\n','table session cleanup or disk changed')
  end
  vim.fn.delete(directory,'rf')
  print('PASS: HTML table replace/split edit, reflow, latest native pixels and close')
end
local ok,err=xpcall(run,debug.traceback)
if not ok then vim.fn.delete(directory,'rf'); error(err) end
