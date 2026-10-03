-- Run inside a PTY, not --headless: TERM=xterm-256color nvim -u tests/details_mouse.lua
-- MDVIEW_MOUSE_RAW=1 uses mocked Kitty transport. No user configuration is changed.
local api=vim.api
local root=vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.mouse='a'
local directory=vim.fn.tempname()
vim.fn.mkdir(directory,'p')
local source=directory .. '/source.md'
local fixture={'# Before',''}
for i=1,18 do fixture[#fixture+1]='Preface paragraph '..i..' fills the viewport before the interactive header.'; fixture[#fixture+1]='' end
vim.list_extend(fixture,{'<details>',
  '<summary><h3>Click this <b>long header</b> even when it wraps onto another terminal cell row at the narrow preview width</h3></summary>',
  '', 'Body text','</details>','','# After'})
for i=1,18 do fixture[#fixture+1]='Following paragraph '..i..' keeps the header scrollable.'; fixture[#fixture+1]='' end
vim.fn.writefile(fixture,source)
local original=vim.fn.readfile(source)
package.preload['image']=function() return {from_file=function(path)
  assert(vim.fn.filereadable(path)==1)
  return {id='detail-mouse-test',global_state={images={}},original_path=path,clear=function() end,render=function() end}
end} end
package.preload['image.utils.term']=function() return {get_size=function() return {cell_width=10,cell_height=20} end} end
local raw=vim.env.MDVIEW_MOUSE_RAW=='1'
local mode=vim.env.MDVIEW_MOUSE_MODE=='replace' and 'replace' or 'split'
if raw then
  vim.env.KITTY_WINDOW_ID='details-tui-test'
  package.preload['image/backends/kitty/helpers']=function()
    return {write_graphics=function(_,path) if path then assert(vim.fn.filereadable(path)==1) end end,
      write_graphics_at=function() end}
  end
end
local mdview=require('mdview')
local timer
local function finish(message)
  if timer then timer:stop();timer:close();timer=nil end
  mdview.close()
  vim.fn.delete(directory,'rf')
  if message then
    api.nvim_err_writeln(message)
    vim.cmd('cquit')
  else
    print('PASS: outside and final-row header mouse clicks in '..mode..' ('..(raw and 'raw' or 'PNG')..')')
    vim.cmd('qa!')
  end
end
api.nvim_create_autocmd('VimEnter',{once=true,callback=function()
  vim.schedule(function()
    vim.cmd.edit(source)
    mdview.setup({raw=raw,smooth=false,zbelow=false})
    mdview.open(mode)
    local s=mdview.status()
    local start=vim.uv.hrtime()
    timer=vim.uv.new_timer()
    timer:start(20,20,vim.schedule_wrap(function()
      if not mdview.status() then return finish('preview closed unexpectedly') end
      if vim.uv.hrtime()-start>8e9 then return finish('mouse click did not toggle: '..tostring(s.error)) end
      if not s.frame or s.busy or not s.loaded or s.frame.revision~=s.revision then return end
      local detail=s.details[0]
      if not detail then return finish('missing header hitbox') end
      if detail.height<=20 then return finish('fixture header did not wrap across cell rows') end
      if not s.offset_requested then
        s.offset_requested=true
        if mode=='split' then
          api.nvim_win_set_cursor(s.source_win,{detail.start_line,0})
          api.nvim_win_call(s.source_win,function() vim.cmd('normal! zt') end)
        else
          s.scroll_to(detail.y-40)
        end
        return
      end
      if s.frame.y==0 or detail.y<s.frame.y or detail.y+detail.height+60>s.frame.y+s.frame.height then return end
      if not s.outside_click_at then
        s.outside_click_at=vim.uv.hrtime()
        local pos=api.nvim_win_get_position(s.preview_win)
        local row=pos[1]+math.floor((detail.y+detail.height+50-s.frame.y)/20)
        local col=pos[2]+math.floor((detail.x+detail.width/2)/10)
        api.nvim_input_mouse('left','press','',0,row,col)
        api.nvim_input_mouse('left','release','',0,row,col)
        return
      end
      if not s.clicked then
        if vim.uv.hrtime()-s.outside_click_at<1e8 then return end
        if s.revision~=1 or not detail.open then return finish('click outside header changed document') end
        s.clicked=true
        local pos=api.nvim_win_get_position(s.preview_win)
        local row=pos[1]+math.floor((detail.y+detail.height-1-s.frame.y)/20)
        local col=pos[2]+math.floor((detail.x+detail.width/2)/10)
        api.nvim_input_mouse('left','press','',0,row,col)
        api.nvim_input_mouse('left','release','',0,row,col)
        return
      end
      if detail.open then return end
      if api.nvim_get_current_win()~=(mode=='split' and s.source_win or s.preview_win) then
        return finish('preview click left focus in the wrong window')
      end
      if not vim.deep_equal(api.nvim_buf_get_lines(s.source_buf,0,-1,false),original)
        or not vim.deep_equal(vim.fn.readfile(source),original) then
        return finish('mouse altered source buffer or file')
      end
      finish(nil)
    end))
  end)
end})
