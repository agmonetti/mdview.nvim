-- Run from the repository root, after scripts/build-html-subset:
--   nvim --headless -u NONE -l tests/html/regression.lua
-- Uses only the isolated renderer. Real bundled Mermaid is required when available;
-- an absent optional binary is reported explicitly, never downloaded or mocked.
local api = vim.api
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local directory = (vim.env.TMPDIR or "/tmp") .. "/mdview-html-regression-" .. vim.fn.getpid()
vim.fn.mkdir(directory,"p")
local worker = root .. "/build/html-subset/mdview-preview"
local css = root .. "/styles/markdown.css"
local mermaid = root .. "/build/merman-evaluation/target/release/merman-cli"
local has_mermaid = vim.fn.executable(mermaid)==1
local mdview, displayed, renders
renders = {}
local function contents(path)
  local file=assert(io.open(path,"rb")); local result=file:read("*a"); file:close(); return result
end
local function save(path,value)
  local file=assert(io.open(path,"wb")); assert(file:write(value)); file:close(); return path
end
package.preload["image"] = function()
  return {from_file=function(path)
    assert(vim.fn.filereadable(path)==1,"missing isolated HTML viewport")
    return {id="html-subset-regression",global_state={images={}},original_path=path,
      clear=function() displayed=nil end,
      render=function(self)
        local s=assert(mdview.status())
        assert(not s.dirty and s.tick==api.nvim_buf_get_changedtick(s.source_buf),"stale source frame reached image display")
        displayed=contents(self.original_path)
        renders[#renders+1]={revision=s.revision,tick=s.tick,bytes=displayed}
      end}
  end}
end
package.preload["image.utils.term"] = function()
  return {get_size=function() return {cell_width=10,cell_height=20} end}
end
mdview = require("mdview")
local environment = {}
for _,name in ipairs({"FPLOG_RAW","FPLOG_SMOOTH","FPLOG_RAW_ZBELOW","FPLOG_CLAMP_PX","FPLOG_C","FPLOG_STEP","FPLOG_CLAMP","KITTY_WINDOW_ID"}) do
  environment[name]=vim.env[name]; vim.env[name]=nil
end
local function hex(text)
  return (text:gsub(".",function(c) return string.format("%02x",c:byte()) end))
end
local function command(args,input)
  local result=vim.system(args,{text=true,stdin=input}):wait(30000)
  assert(result.code==0,table.concat(args," ") .. ": " .. (result.stderr or ""))
  return result.stdout,result.stderr
end
local function equal(a,b)
  local result=vim.system({"magick","compare","-metric","AE",a,b,"null:"},{text=true}):wait(30000)
  assert(result.code==0 or result.code==1,"pixel comparison failed: " .. (result.stderr or ""))
  return assert(tonumber(result.stderr:match("^[%d.]+")),result.stderr)==0
end
local function settled(s)
  return s and s.loaded and s.frame and not s.busy and not s.dirty and not s.debouncing
    and not s.error and s.frame.revision==s.revision
end
local function wait(predicate,label)
  assert(vim.wait(30000,predicate,10),label .. ": " .. tostring(mdview.status() and mdview.status().error))
end
local function lines(text)
  return vim.split(text,"\n",{plain=true})
end
local function source_text(s)
  return table.concat(api.nvim_buf_get_lines(s.source_buf,0,-1,false),"\n")
end
local serial=0
local function oracle(s,options)
  serial=serial+1
  local location=directory .. "/oracle-" .. serial
  vim.fn.mkdir(location,"p")
  local snapshot=save(location .. "/snapshot.md",source_text(s) .. "\n")
  local load={"LOAD",1,s.frame.width,hex(snapshot),hex(directory),hex(s.stylesheet)}
  if options.alerts then load[#load+1]="alerts=1" end
  if options.mermaid then
    load[#load+1]=hex(mermaid); load[#load+1]=hex(location .. "/diagrams")
    load[#load+1]=hex("#0d1117")
  end
  local botline=0
  if s.mode=="split" then
    botline=api.nvim_win_call(s.source_win,function() return vim.fn.line("w$",s.source_win) end)
  end
  local output=location .. "/oracle.png"
  -- Explicit pixel offset avoids depending on the oracle worker's source selection.
  local draw={"DRAW",1,1,0,s.frame.y,botline,s.frame.height,hex(output)}
  local response=command({worker},table.concat(load," ") .. "\n" .. table.concat(draw," ") .. "\nQUIT\n")
  assert(response:match("FRAME 1 1 "),"fresh native oracle failed: " .. response)
  assert(displayed and displayed==contents(s.frame_path),"displayed viewport is not the latest published frame")
  assert(equal(output,s.frame_path),"published HTML frame differs from latest unsaved source/options/geometry")
  vim.fn.delete(location,"rf")
end
local function token_line(text,token)
  for number,line in ipairs(lines(text)) do if line:find(token,1,true) then return number end end
  error("missing fixture token " .. token)
end
local function anchors(s,text)
  for _,token in ipairs({"PRE001","POST001"}) do
    local line=token_line(text,token)
    local found=false
    for _,fragment in ipairs(s.fragments) do if fragment.line==line then found=true end end
    assert(found,"HTML lost unrelated heading anchor: " .. token)
  end
end
local function html(snapshot,marked,alerts)
  local args={worker,"--html",snapshot,css,marked and "marked" or "plain"}
  if alerts then args[#args+1]="alerts" end
  return command(args)
end
local matrix={
  {"br variants","before001<br>middle001<br/>next001<br />after001"},
  {"br only","<br>\n\nafter002"},
  {"kbd","before003 <kbd>keyboard003</kbd> after003"},
  {"sup","before004 <sup>upper004</sup> after004"},
  {"sub","before005 <sub>lower005</sub> after005"},
  {"span","before006 <span>plain006</span> after006"},
  {"nest repeat Unicode entities multiline","before007 <kbd>repeat007 <sup>café <sub>東京 <span>&amp; &#233; 🙂\nrepeat007</span></sub></sup></kbd> after007"},
  {"nested br variants","before024 <kbd>kbd024<br><sup>sup024<br/><sub>sub024<br /><span>span024</span></sub></sup></kbd> after024"},
  {"repeated Unicode","<span>café 東京</span> <kbd>café 東京</kbd>"},
  {"opaque p","<p>opaque008 **literal008** <kbd>key008</kbd> &amp;</p>\n\n**parsed008**"},
  {"opaque div","<div>\nopaque009 **literal009** <span>inner009</span>\n</div>\n\n**parsed009**"},
  {"blockquote opaque bytes","> <div>\n> quoted025 **raw025** <kbd>key025</kbd>\n> </div>\n>\n> after025"},
  {"list opaque bytes","- <div>\n  listed026 **raw026** <span>inner026</span>\n  </div>\n\n  after026"},
  {"quote list opaque bytes","> - <div>\n>   nested027 **raw027** <kbd>key027</kbd>\n>   </div>\n>\n>   after027"},
  {"blank separation","<div>\n\n**parsed010**\n\n</div>\n\n<p>\n\n**parsed011**\n\n</p>"},
  {"inline comment","before012<!-- secret012\ncontinued secret012 -->after012",hidden="secret012"},
  {"spaced multiline inline comment","Before <!-- complete\nmultiline comment --> after comment.",hidden="multiline"},
  {"comment literal length","<!-- secret013\ncontinued secret013\n-->tail013",hidden="secret013"},
  {"unclosed comment","<!-- malformed014\nrest014\n# swallowed014",error=true},
  {"mismatched","before015 <span>malformed015</kbd> following015",error=true},
  {"unclosed","<div>malformed016\nrest016\n# swallowed016",error=true},
  {"malformed attribute","<span title=\"unfinished>bad023\nrest023",error=true},
  {"escaped code and fence","\\<kbd>escaped017\\</kbd>\n\n`<span>code017</span>`\n\n```html\n<div>fence017</div>\n<!-- fencecomment017 -->\n```"},
}
local attributes=' style="display:none" onclick="bad()" onerror="bad()" id="bad-id" class="bad-class"'
  .. ' align="right" width="1" height="1" src="file:///never-resource" href="https://invalid.example/never"'
  .. ' data-mdview="99999" data-mdview-image="99999" data-mdview-mermaid="99999" data-mdview-mermaid-end="99999" title="quoted > delimiter"'
  .. ' data-mdview-break="99999" data-mdview-break-column="99999"'
for _,tag in ipairs({"kbd","sup","sub","span","p","div"}) do
  matrix[#matrix+1]={"attributes " .. tag,"<" .. tag .. attributes .. ">safe018</" .. tag .. ">\n\nafter018",attributes=true}
end
matrix[#matrix+1]={"attributes br","before019<br" .. attributes .. "/>after019",attributes=true}
for _,tag in ipairs({"details","summary","picture","source","img","table","a","script","style"}) do
  local body=tag=="style" and ".markdown-body { display:none }" or tag=="script" and "alert('never')" or "literal020"
  matrix[#matrix+1]={"unsupported " .. tag,"<" .. tag .. ">" .. body .. "</" .. tag .. ">\nfollowing020",error=true}
end
local function document(body,options)
  local text="# PRE001\n\n" .. body .. "\n\n# POST001\n"
  if options.alerts then text=text .. "\n> [!NOTE]\n> Alert body with <kbd>alert021</kbd>.\n" end
  if options.mermaid then text=text .. "\n```mermaid\nerDiagram\n Alpha ||--o{ Beta : owns\n```\n" end
  for number=1,45 do text=text .. "\nParagraph " .. number .. " after HTML for real scrolling.\n" end
  return text:gsub("\n$","")
end
local function mermaid_pixels(s)
  local images=vim.fn.glob(s.directory .. "/diagrams/*.png",false,true)
  assert(#images==1,"real Mermaid did not leave exactly one PNG")
  local input=save(directory .. "/independent.mmd","erDiagram\n Alpha ||--o{ Beta : owns\n")
  local output=directory .. "/independent.png"
  local fit=math.max(1,s.frame.width-64)
  command({mermaid,"render",input,"--format","png","--output",output,"--theme","dark",
    "--background","#0d1117","--raster-fit-width",tostring(fit),"--raster-max-width",tostring(fit),
    "--raster-max-height","4096","--raster-max-pixels",tostring(math.min(fit*4096,4194304)),
    "--resource-profile","interactive","--operation-timeout-ms","5000","--quiet"})
  assert(equal(output,images[1]),"real Mermaid raster differs from independent current-source/current-width render")
end
local function check()
  assert(vim.fn.executable(worker)==1,"Run scripts/build-html-subset; never substitute production binary")
  assert(vim.fn.executable("magick")==1,"existing ImageMagick required for independent plugin pixel comparison")
  vim.o.columns=120; vim.o.lines=32
  vim.o.equalalways=false
  local source=save(directory .. "/source.md","# Original disk bytes\n\nNever saved by preview.\n")
  local disk=contents(source)
  vim.cmd("edit " .. vim.fn.fnameescape(source))
  local source_buf=api.nvim_get_current_buf()
  -- Both modes exercise the full policy, then repeat with alerts and real Mermaid.
  for _,options in ipairs({{alerts=false,mermaid=false},{alerts=true,mermaid=has_mermaid}}) do
    for _,mode in ipairs({"replace","split"}) do
      api.nvim_buf_set_lines(source_buf,0,-1,false,lines(document(matrix[1][2],options)))
      api.nvim_win_set_cursor(0,{1,0})
      mdview.setup({renderer=worker,stylesheet=css,raw=false,smooth=false,zbelow=false,clamp=false,
        alerts=options.alerts,mermaid=options.mermaid and {renderer=mermaid} or false,split_follow="viewport"})
      mdview.open(mode)
      wait(function() return settled(mdview.status()) end,mode .. " first isolated HTML")
      local s=mdview.status()
      local job,pid=s.job,vim.fn.jobpid(s.job)
      local function edit(text,label)
        local revision=s.revision
        api.nvim_buf_set_lines(s.source_buf,0,-1,false,lines(text))
        api.nvim_exec_autocmds("TextChanged",{buffer=s.source_buf})
        wait(function() return settled(s) and s.revision>revision end,label)
        assert(s.job==job and vim.fn.jobpid(job)==pid,"HTML failure restarted persistent worker")
        assert(source_text(s)==text,"preview altered original buffer bytes")
        assert(contents(source)==disk,"preview saved unsaved source")
        assert(vim.bo[s.source_buf].modified,"preview reset source modified flag")
        anchors(s,text); oracle(s,options)
      end
      for _,case in ipairs(matrix) do
        local text=document(case[2],options)
        edit(text,mode .. " " .. case[1])
        local snapshot=save(directory .. "/inspect.md",text .. "\n")
        local rendered,diagnostics=html(snapshot,false,options.alerts)
        local body=assert(rendered:match("<main[^>]*>(.*)</main>"),"missing generated document body")
        if case.error then
          assert(diagnostics:match("HTML subset at %d+:%d+:"),"malformed/unsupported HTML has no localized diagnostic")
          assert(rendered:find("following020",1,true) or not case[1]:match("unsupported"),"unsupported HTML hid following text")
          local tag=case[1]:match("^unsupported (%w+)$")
          if tag then
            assert(body:find("&lt;" .. tag .. "&gt;",1,true),"unsupported HTML was not escaped literally")
            assert(not body:find("<" .. tag .. ">",1,true),"unsupported HTML reached native layout as a real tag")
          end
        else
          assert(diagnostics=="","supported HTML emitted diagnostic: " .. diagnostics)
        end
        if case.hidden then assert(not rendered:find(case.hidden,1,true),"complete comment became visible") end
        if case.attributes then
          for _,value in ipairs({"bad()","bad-id","bad-class","never-resource","99999","quoted &gt; delimiter"}) do
            assert(not rendered:find(value,1,true),"hostile attribute reached sanitized HTML: " .. value)
          end
        end
      end
      -- Rapid unsaved invalid -> correction while rendering/debouncing: only latest
      -- source revision may reach the image callback, and worker identity is retained.
      local before=s.revision
      api.nvim_buf_set_lines(s.source_buf,0,-1,false,lines(document("<span>obsolete022</kbd>",options)))
      api.nvim_exec_autocmds("TextChanged",{buffer=s.source_buf})
      local corrected=document("before022 <kbd>corrected022</kbd> after022",options)
      api.nvim_buf_set_lines(s.source_buf,0,-1,false,lines(corrected))
      api.nvim_exec_autocmds("TextChanged",{buffer=s.source_buf})
      wait(function() return settled(s) and s.revision>before end,mode .. " rapid correction")
      assert(s.job==job and vim.fn.jobpid(job)==pid,"rapid correction changed worker")
      assert(source_text(s)==corrected and contents(source)==disk,"correction mutated source")
      oracle(s,options)
      if options.mermaid then mermaid_pixels(s) end
      if mode=="replace" then
        s.scroll_to(200)
        wait(function() return settled(s) and s.frame.y==200 end,"HTML reader scroll")
      else
        api.nvim_set_current_win(s.source_win)
        local line=token_line(corrected,"Paragraph 20")
        api.nvim_win_set_cursor(s.source_win,{line,0}); vim.cmd("normal! zt")
        api.nvim_exec_autocmds("WinScrolled",{pattern=tostring(s.source_win)})
        wait(function() return settled(s) and s.frame.line==line end,"HTML split source scroll")
        assert(s.frame.y>0,"split scroll remained at document start")
      end
      oracle(s,options)
      local old_width=s.width
      local sibling
      if mode=="replace" then
        api.nvim_set_current_win(s.preview_win); vim.cmd("rightbelow vsplit")
        sibling=api.nvim_get_current_win(); api.nvim_win_set_buf(sibling,s.source_buf)
        api.nvim_set_current_win(s.preview_win)
      end
      api.nvim_win_set_width(s.preview_win,math.max(20,api.nvim_win_get_width(s.preview_win)-10))
      api.nvim_exec_autocmds("WinResized",{})
      wait(function() return settled(s) and s.width~=old_width end,"HTML resize reflow")
      oracle(s,options)
      if options.mermaid then mermaid_pixels(s) end
      local session_directory=s.directory
      mdview.close()
      wait(function() return vim.fn.isdirectory(session_directory)==0 end,"HTML session artifacts cleanup")
      assert(vim.fn.jobwait({job},1000)[1]~=-1,"closed HTML worker still running")
      assert(mdview.status()==nil and displayed==nil,"preview image/session survived cleanup")
      if sibling and api.nvim_win_is_valid(sibling) then api.nvim_win_close(sibling,true) end
      api.nvim_set_current_win(s.source_win)
      assert(api.nvim_win_get_buf(s.source_win)==source_buf,"close did not restore original source")
      assert(source_text(s)==corrected and contents(source)==disk,"cleanup mutated source")
    end
  end
  assert(#renders>0,"regression never displayed a frame")
  print("PASS: " .. #matrix .. " HTML policy cases in replace/split, original unsaved bytes, same-worker fallback/correction, independent current-frame pixels, alerts, resize/scroll/cleanup, escapes/code/fences")
  print(has_mermaid and "PASS: existing real Mermaid enabled and independently rendered before/after resize" or
    "SKIP: optional real Mermaid binary absent at " .. mermaid .. " (no download)")
end
local ok,err=xpcall(check,debug.traceback)
mdview.close()
for name,value in pairs(environment) do vim.env[name]=value end
if not ok then io.stderr:write(err .. "\nArtifacts: " .. directory .. "\n"); vim.cmd("cquit 1") end
vim.fn.delete(directory,"rf")
vim.cmd("qall!")
