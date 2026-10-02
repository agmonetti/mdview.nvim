-- Run: nvim --headless -u NONE -l tests/html/images_regression.lua
-- Real isolated native renderer; only terminal image display is mocked.
local api=vim.api
local root=vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local directory=(vim.env.TMPDIR or '/tmp') .. '/mdview-html-images-' .. vim.fn.getpid()
vim.fn.mkdir(directory,'p')
local worker=root .. '/build/html-subset/mdview-preview'
local css=root .. '/styles/markdown.css'
local mdview,displayed
local renders={}
local function contents(path)
  local file=assert(io.open(path,'rb')); local bytes=file:read('*a'); file:close(); return bytes
end
local function save(path,bytes)
  local file=assert(io.open(path,'wb')); assert(file:write(bytes)); file:close(); return path
end
local function command(args,input)
  local result=vim.system(args,{text=true,stdin=input}):wait(30000)
  assert(result.code==0,table.concat(args,' ') .. ': ' .. (result.stderr or ''))
  return result.stdout,result.stderr
end
local function hex(text)
  return (text:gsub('.',function(c) return string.format('%02x',c:byte()) end))
end
local function equal(a,b)
  local result=vim.system({'magick','compare','-metric','AE',a,b,'null:'},{text=true}):wait(30000)
  assert(result.code==0 or result.code==1,result.stderr)
  assert(tonumber(result.stderr:match('^[%d.]+'))==0,'latest independent viewport pixels differ: ' .. result.stderr)
end
package.preload['image']=function()
  return {from_file=function(path)
    assert(vim.fn.filereadable(path)==1,'missing native viewport')
    return {id='html-images-regression',global_state={images={}},original_path=path,
      clear=function() displayed=nil end,
      render=function(self)
        local s=assert(mdview.status())
        assert(not s.dirty and s.tick==api.nvim_buf_get_changedtick(s.source_buf),'stale image source reached display')
        displayed=contents(self.original_path)
        renders[#renders+1]={revision=s.revision,tick=s.tick,bytes=displayed}
      end}
  end}
end
package.preload['image.utils.term']=function()
  return {get_size=function() return {cell_width=10,cell_height=20} end}
end
mdview=require('mdview')
local environment={}
for _,name in ipairs({'FPLOG_RAW','FPLOG_SMOOTH','FPLOG_RAW_ZBELOW','FPLOG_CLAMP_PX','FPLOG_C','FPLOG_STEP','FPLOG_CLAMP','KITTY_WINDOW_ID'}) do
  environment[name]=vim.env[name]; vim.env[name]=nil
end
local function settled(s)
  return s and s.loaded and s.frame and not s.busy and not s.dirty and not s.debouncing
    and not s.error and s.frame.revision==s.revision
end
local function wait(predicate,label)
  assert(vim.wait(30000,predicate,10),label .. ': ' .. tostring(mdview.status() and mdview.status().error))
end
local function lines(text) return vim.split(text,'\n',{plain=true}) end
local function source_text(s) return table.concat(api.nvim_buf_get_lines(s.source_buf,0,-1,false),'\n') end
local function document(image)
  local text='# PRE001\n\nbefore inline ' .. image .. ' after inline\n\n' .. image .. '\n\n# POST001'
  for number=1,60 do text=text .. '\n\nParagraph ' .. number .. ' for image scrolling.' end
  return text
end
local serial=0
local function oracle(s)
  serial=serial+1
  local location=directory .. '/oracle-' .. serial
  vim.fn.mkdir(location,'p')
  local snapshot=save(location .. '/snapshot.md',source_text(s) .. '\n')
  local output=location .. '/viewport.png'
  local botline=0
  if s.mode=='split' then botline=api.nvim_win_call(s.source_win,function() return vim.fn.line('w$',s.source_win) end) end
  local request=table.concat({'LOAD',1,s.frame.width,hex(snapshot),hex(directory),hex(s.stylesheet)},' ')
    .. '\n' .. table.concat({'DRAW',1,1,0,s.frame.y,botline,s.frame.height,hex(output)},' ') .. '\nQUIT\n'
  local response=command({worker},request)
  assert(response:match('FRAME 1 1 ') and not response:match('ERROR '),'independent native oracle aborted: ' .. response)
  assert(displayed==contents(s.frame_path),'display is not current published native raster')
  equal(output,s.frame_path)
  vim.fn.delete(location,'rf')
end
local function check()
  assert(vim.fn.executable(worker)==1,'Build isolated HTML worker first')
  assert(vim.fn.executable('magick')==1,'Installed ImageMagick required; no downloads')
  command({'magick','-size','37x23','xc:#3592c7',directory .. '/東京 space&image.png'})
  save(directory .. '/corrupt.png','not an image')
  vim.o.columns=120; vim.o.lines=32; vim.o.equalalways=false
  local source=save(directory .. '/source.md','# Original disk bytes\n\nNever saved by preview.\n')
  local disk=contents(source)
  vim.cmd('edit ' .. vim.fn.fnameescape(source))
  local source_buf=api.nvim_get_current_buf()
  local valid='<img src="%E6%9D%B1%E4%BA%AC%20space&amp;image.png" alt="café &amp; image">'
  local invalid={
    '<img src="missing.png" alt="missing">', '<img src="corrupt.png" alt="corrupt">',
    '<img src="https://invalid.example/no" onerror="evil()">', '<img src="//invalid.example/no">',
    '<img src="data:image/png;base64,AAAA">', '<img src="file:///tmp/no.png">',
  }
  for _,mode in ipairs({'replace','split'}) do
    api.nvim_buf_set_lines(source_buf,0,-1,false,lines(document(valid)))
    api.nvim_win_set_cursor(0,{1,0})
    mdview.setup({renderer=worker,stylesheet=css,raw=false,smooth=false,zbelow=false,clamp=false,
      alerts=false,mermaid=false,split_follow='viewport'})
    mdview.open(mode)
    wait(function() return settled(mdview.status()) end,mode .. ' initial local image')
    local s=mdview.status()
    local job,pid=s.job,vim.fn.jobpid(s.job)
    local function edit(text,label)
      local revision=s.revision
      api.nvim_buf_set_lines(s.source_buf,0,-1,false,lines(text))
      api.nvim_exec_autocmds('TextChanged',{buffer=s.source_buf})
      wait(function() return settled(s) and s.revision>revision end,label)
      assert(s.job==job and vim.fn.jobpid(job)==pid,'invalid image restarted worker')
      assert(source_text(s)==text and contents(source)==disk,'preview mutated unsaved or disk bytes')
      assert(vim.bo[s.source_buf].modified,'preview cleared unsaved flag')
      oracle(s)
    end
    oracle(s)
    for _,literal in ipairs(invalid) do
      edit(document(literal),mode .. ' rejected src')
      local snapshot=save(directory .. '/inspect.md',source_text(s) .. '\n')
      local rendered,diagnostics=command({worker,'--html',snapshot,css,'plain'})
      assert(diagnostics:match('HTML subset at %d+:%d+:'),'rejected src missing source-position diagnostic')
      assert(not rendered:match('<img[%s>]'),'rejected src reached image loader as HTML')
      local decoded=rendered:gsub('&quot;','"'):gsub('&#39;',"'"):gsub('&lt;','<'):gsub('&gt;','>'):gsub('&amp;','&')
      assert(decoded:find(literal,1,true),'original rejected img literal not preserved')
      edit(document(valid),mode .. ' corrected src')
    end
    -- Rapid unsaved failure/correction must never publish an obsolete source tick.
    local revision=s.revision
    api.nvim_buf_set_lines(s.source_buf,0,-1,false,lines(document(invalid[1])))
    api.nvim_exec_autocmds('TextChanged',{buffer=s.source_buf})
    local corrected=document(valid)
    api.nvim_buf_set_lines(s.source_buf,0,-1,false,lines(corrected))
    api.nvim_exec_autocmds('TextChanged',{buffer=s.source_buf})
    wait(function() return settled(s) and s.revision>revision end,mode .. ' rapid src correction')
    assert(s.job==job and vim.fn.jobpid(job)==pid,'rapid correction changed worker identity')
    oracle(s)
    if mode=='replace' then
      s.scroll_to(200)
      wait(function() return settled(s) and s.frame.y==200 end,'reader scroll')
    else
      api.nvim_set_current_win(s.source_win)
      local target
      for index,line in ipairs(lines(corrected)) do if line:find('Paragraph 20 ',1,true) then target=index end end
      api.nvim_win_set_cursor(s.source_win,{assert(target),0}); vim.cmd('normal! zt')
      api.nvim_exec_autocmds('WinScrolled',{pattern=tostring(s.source_win)})
      wait(function() return settled(s) and s.frame.line==target end,'source viewport scroll')
      assert(s.frame.y>0,'source scrolling stayed at top')
    end
    oracle(s)
    local old_width=s.width
    local sibling
    if mode=='replace' then
      api.nvim_set_current_win(s.preview_win); vim.cmd('rightbelow vsplit')
      sibling=api.nvim_get_current_win(); api.nvim_win_set_buf(sibling,s.source_buf)
      api.nvim_set_current_win(s.preview_win)
    end
    api.nvim_win_set_width(s.preview_win,math.max(20,api.nvim_win_get_width(s.preview_win)-10))
    api.nvim_exec_autocmds('WinResized',{})
    wait(function() return settled(s) and s.width~=old_width end,'real-window resize reflow')
    oracle(s)
    local session=s.directory
    mdview.close()
    wait(function() return vim.fn.isdirectory(session)==0 end,'session cleanup')
    assert(vim.fn.jobwait({job},1000)[1]~=-1,'closed image worker still running')
    assert(mdview.status()==nil and displayed==nil,'session/image survived close')
    if sibling and api.nvim_win_is_valid(sibling) then api.nvim_win_close(sibling,true) end
    api.nvim_set_current_win(s.source_win)
    assert(api.nvim_win_get_buf(s.source_win)==source_buf,'close did not restore original buffer')
    assert(source_text(s)==corrected and contents(source)==disk,'close changed source bytes')
  end
  assert(#renders>0,'no real viewport displayed')
  print('PASS: local HTML images, unsaved rejected/corrected src, same-worker recovery, latest independent pixels, replace/split scroll/real resize/close')
end
local ok,err=xpcall(check,debug.traceback)
mdview.close()
for name,value in pairs(environment) do vim.env[name]=value end
if not ok then io.stderr:write(err .. '\nArtifacts: ' .. directory .. '\n'); vim.cmd('cquit 1') end
vim.fn.delete(directory,'rf')
vim.cmd('qall!')
