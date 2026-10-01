-- Run from the repository root: nvim --headless -u NONE -l tests/alerts.lua
local api = vim.api
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local directory = "/tmp/mdview-alerts-test-" .. vim.fn.getpid()
vim.fn.mkdir(directory, "p")
package.preload["image"] = function()
  return {from_file=function(path)
    assert(vim.fn.filereadable(path)==1, "missing alert viewport")
    return {id="alerts-test",global_state={images={}},original_path=path,clear=function() end,render=function() end}
  end}
end
package.preload["image.utils.term"] = function()
  return {get_size=function() return {cell_width=10,cell_height=20} end}
end
local mdview = require("mdview")
local theme = require("mdview.theme")
local worker = root .. "/build/mdview-preview"
local css = root .. "/styles/markdown.css"
local function save(path,text)
  vim.fn.writefile(vim.split(text,"\n",{plain=true}),path)
  return path
end
local function contents(path)
  local f=assert(io.open(path,"rb")); local value=f:read("*a"); f:close(); return value
end
local function command(args,input)
  local result=vim.system(args,{text=true,stdin=input}):wait()
  assert(result.code==0,result.stderr)
  return result.stdout
end
local function hex(text)
  return (text:gsub(".",function(c) return string.format("%02x",c:byte()) end))
end
local function equal(a,b)
  local result=vim.system({"magick","compare","-metric","AE",a,b,"null:"},{text=true}):wait()
  assert(result.code==0 or result.code==1,result.stderr)
  return result.code==0 and tonumber(result.stderr:match("^[%d.]+"))==0
end
local function wait(predicate,description)
  assert(vim.wait(15000,predicate,10),description .. ": " .. tostring(mdview.status() and mdview.status().error))
end
local function settled(s)
  return s and s.frame and not s.busy and not s.dirty and not s.debouncing and not s.error and s.frame.revision==s.revision
end
local function html(source,stylesheet,mode,enabled)
  local args={worker,"--html",source,stylesheet,mode}
  if enabled then args[#args+1]="alerts" end
  return command(args)
end
local function frame(source,stylesheet,width,y,height,output,enabled)
  local load=table.concat({"LOAD",1,width,hex(source),hex(directory),hex(stylesheet)}," ")
  if enabled then load=load .. " alerts=1" end
  local draw=table.concat({"DRAW",1,1,0,y,0,height,hex(output)}," ")
  local response=command({worker},load .. "\n" .. draw .. "\nQUIT\n")
  assert(response:match("FRAME 1 1 "),response)
  return response
end
local function oracle(s,enabled)
  local snapshot=save(directory .. "/latest.md",table.concat(api.nvim_buf_get_lines(s.source_buf,0,-1,false),"\n"))
  local output=directory .. "/oracle.png"
  frame(snapshot,s.stylesheet,s.frame.width,s.frame.y,s.frame.height,output,enabled)
  assert(equal(output,s.frame_path),"published frame does not reflect latest source/options/geometry")
end
-- Independent sRGB contrast calculation: diagnostic colors can be unreadable on a custom background.
local function contrast(a,b)
  local function luminance(color)
    local sum=0
    for n,weight in ipairs({0.2126,0.7152,0.0722}) do
      local value=tonumber(color:sub(n*2,n*2+1),16)/255
      sum=sum+weight*(value<=0.04045 and value/12.92 or ((value+0.055)/1.055)^2.4)
    end
    return sum
  end
  local x,y=luminance(a),luminance(b)
  return (math.max(x,y)+0.05)/(math.min(x,y)+0.05)
end
local types={"NOTE","TIP","IMPORTANT","WARNING","CAUTION"}
local fixture={"# GitHub alerts",""}
local marker_lines,body_lines={},{}
for _,kind in ipairs(types) do
  marker_lines[kind]=#fixture+1
  fixture[#fixture+1]="> [!" .. kind .. "]"
  body_lines[kind]=#fixture+1
  fixture[#fixture+1]="> " .. kind .. " body with **bold**, *emphasis*, `code`, &amp; café."
  fixture[#fixture+1]=">"
  fixture[#fixture+1]="> - first item"
  fixture[#fixture+1]="> - second item"
  fixture[#fixture+1]=">"
  fixture[#fixture+1]="> First line with a hard break.  "
  fixture[#fixture+1]="> Second line after the break."
  fixture[#fixture+1]=""
end
local source=save(directory .. "/source.md",table.concat(fixture,"\n"))
local original=contents(source)
local function check()
  assert(not pcall(mdview.setup,{alerts="yes"}),"nonboolean alerts option accepted")
  for _,background in ipairs({"#101010","#f0f0f0","#777777"}) do
    api.nvim_set_hl(0,"Normal",{fg="#ffffff",bg=background})
    for _,name in ipairs({"DiagnosticInfo","DiagnosticHint","DiagnosticWarn","DiagnosticError","Special"}) do
      api.nvim_set_hl(0,name,{fg=background})
    end
    local palette=theme.resolve("nvim")
    for _,kind in ipairs(types) do
      assert(contrast(palette["alert_" .. kind:lower()],palette.bg)>=4.5,"unreadable adaptive alert title: " .. kind)
    end
  end
  -- Visible centers and independent SVG silhouettes catch misplaced/wrong/missing icons.
  local alignment_source=save(directory .. "/alignment.md",table.concat({
    "> [!NOTE]","> Body.","","> [!TIP]","> Body.","","> [!IMPORTANT]","> Body.","",
    "> [!WARNING]","> Body.","","> [!CAUTION]","> Body."
  },"\n"))
  local icon_names={"info","light-bulb","report","alert","stop"}
  local silhouettes={}
  for index,name in ipairs(icon_names) do
    local decoded=vim.system({"magick","-background","none",root .. "/assets/octicons/" .. name .. "-16.svg",
      "-depth","8","RGBA:-"}):wait()
    assert(decoded.code==0 and #decoded.stdout==16*16*4,decoded.stderr)
    silhouettes[index]=decoded.stdout
  end
  for _,name in ipairs({"dark","light","nvim"}) do
    local palette=theme.resolve(name)
    local stylesheet=save(directory .. "/alignment-" .. name .. ".css",contents(css) .. "\n" .. theme.css(palette))
    local function channels(color)
      return {tonumber(color:sub(2,3),16),tonumber(color:sub(4,5),16),tonumber(color:sub(6,7),16)}
    end
    local bg=channels(palette.bg)
    for _,width in ipairs({360,700}) do
      local output=directory .. "/alignment.png"
      local response=frame(alignment_source,stylesheet,width,0,800,output,true)
      local anchors={}
      for line,y in response:gmatch("FRAG (%d+) %d+ %d+ ([%d.]+)") do anchors[tonumber(line)]=tonumber(y) end
      local pixels=vim.system({"magick",output,"-depth","8","RGB:-"}):wait()
      assert(pixels.code==0,pixels.stderr)
      for index,kind in ipairs(types) do
        local fg=channels(palette["alert_" .. kind:lower()])
        local channel=1
        for c=2,3 do if math.abs(fg[c]-bg[c])>math.abs(fg[channel]-bg[channel]) then channel=c end end
        local function visible(x,y)
          local offset=(y*width+x)*3
          local alpha=(pixels.stdout:byte(offset+channel)-bg[channel])/(fg[channel]-bg[channel])
          if alpha<0.5 or alpha>1.01 then return false end
          for c=1,3 do
            if math.abs(pixels.stdout:byte(offset+c)-(bg[c]+alpha*(fg[c]-bg[c])))>2 then return false end
          end
          return true
        end
        local top=math.floor(assert(anchors[1+(index-1)*3]))
        local function bounds(left,right)
          local first,last
          for y=top,top+35 do
            for x=left,right do
              if visible(x,y) then first=first or y; last=y end
            end
          end
          assert(first,"missing visible icon/title pixels: " .. kind)
          return first,last
        end
        local first,last=bounds(20,35)
        local text_first,text_last=bounds(44,159)
        assert(math.abs((first+last-text_first-text_last)/2)<=2,
          "alert icon is vertically displaced from title: " .. name .. "/" .. width .. "/" .. kind)
        local expected=silhouettes[index]
        local expected_first
        for y=0,15 do
          for x=0,15 do
            if expected:byte((y*16+x)*4+4)>=128 then expected_first=expected_first or y end
          end
        end
        local origin=first-assert(expected_first)
        local differences=0
        for y=0,15 do
          for x=0,15 do
            if visible(20+x,origin+y)~=(expected:byte((y*16+x)*4+4)>=128) then differences=differences+1 end
          end
        end
        -- ImageMagick and librsvg differ at antialiased edges; reject substantive shape changes.
        assert(differences<=24,"wrong alert SVG silhouette: " .. name .. "/" .. width .. "/" .. kind)
      end
    end
  end
  -- Only a standalone exact, unescaped marker is an alert. The following remain ordinary Markdown.
  local ordinary=save(directory .. "/ordinary.md",table.concat({
    "> [!CUSTOM]","> unknown","","> \\[!NOTE]","> escaped","",
    "> `[!TIP]`","> inline code","","> prefix [!WARNING]","> prose","",
    "> [!CAUTION] extra","> same-line prose","","> [!note]","> lowercase","",
    "> > [!IMPORTANT]","> > nested quote","","- item","  > [!NOTE]","  > nested list","",
    "```md","> [!WARNING]","```","","> Ordinary **quote**","",
    "> &#91;!NOTE]","> entity marker","","> [!**NOTE**]","> formatted marker"
  },"\n"))
  assert(html(ordinary,css,"plain",true)==html(ordinary,css,"plain",false),"non-alert content was transformed")
  local enabled=html(source,css,"plain",true)
  local body=assert(enabled:match("<main[^>]*>(.*)</main>"))
  assert(not body:find("[!",1,true),"recognized marker leaked into rendered alert")
  for _,kind in ipairs(types) do
    local title=kind:sub(1,1) .. kind:sub(2):lower()
    assert(body:find(">" .. title .. "</p>",1,true),"missing visible alert title " .. kind)
    assert(body:find("<strong>bold</strong>",1,true) and body:find("<code>code</code>",1,true)
      and body:find("<li>first item</li>",1,true),"alert body lost Markdown semantics")
  end
  -- Marker-only and blank-first-paragraph alerts must not swallow following content.
  local edges=save(directory .. "/edges.md","> [!NOTE]\n\nFollowing paragraph.\n\n> [!TIP]\n>\n> Blank-separated body.\n\n# Following heading\n")
  local edgehtml=html(edges,css,"plain",true)
  assert(edgehtml:find("Following paragraph.",1,true) and edgehtml:find("Blank-separated body.",1,true)
    and edgehtml:find("<h1>Following heading</h1>",1,true),"alert conversion consumed adjacent content")
  local ambiguous=save(directory .. "/ambiguous.md","> [!NOTE]\n> (https://example.invalid)\n\n> [!TIP]\n> ---\n> Body after rule.\n")
  local ambiguous_html=html(ambiguous,css,"plain",true)
  assert(ambiguous_html:find('href="https://example.invalid"',1,true),"marker consumed a body link destination")
  assert(ambiguous_html:find("<hr",1,true) and ambiguous_html:find("Body after rule.",1,true),"marker consumed a body thematic break")
  local lazy=save(directory .. "/lazy.md","> [!NOTE]\n(https://example.invalid)\ncontinued **bold**\n> explicit continuation\n")
  for _,path in ipairs({ambiguous,lazy}) do
    local marked=html(path,css,"marked",true)
    assert(marked:find('href="https://example.invalid"',1,true),"attributed alert lost its body link")
  end
  local crlf=directory .. "/crlf.md"
  local f=assert(io.open(crlf,"wb")); f:write("> [!NOTE]\r\n> CRLF body.\r\n"); f:close()
  assert(html(crlf,css,"plain",true):find(">Note</p>",1,true),"CRLF marker not recognized")
  -- Source instrumentation must leave every rendered pixel unchanged at wide and wrapped widths.
  for _,name in ipairs({"dark","light","nvim"}) do
    local stylesheet=save(directory .. "/" .. name .. ".css",contents(css) .. "\n" .. theme.css(theme.resolve(name)))
    for _,width in ipairs({360,700}) do
      local paths={}
      for _,mode in ipairs({"plain","marked"}) do
        local path=save(directory .. "/" .. name .. "-" .. width .. "-" .. mode .. ".html",html(source,stylesheet,mode,true))
        save(path .. ".cfg","bestfit: false\nwidth: " .. width .. "\nheight: 2500\n")
        paths[mode]=path .. ".png"
        command({root .. "/build/mdview-render",path,paths[mode],tostring(width)})
      end
      assert(equal(paths.plain,paths.marked),"alert source spans changed pixels: " .. name .. "/" .. width)
    end
  end
  local response=frame(source,css,700,0,2500,directory .. "/native.png",true)
  local anchors={}
  for line in response:gmatch("[^\n]+") do
    local source_line,column,finish,y=line:match("^FRAG (%d+) (%d+) (%d+) ([%d.]+)")
    if source_line then
      source_line=tonumber(source_line); y=tonumber(y)
      anchors[source_line]=math.min(anchors[source_line] or math.huge,y)
    end
  end
  for _,kind in ipairs(types) do
    assert(anchors[marker_lines[kind]] and anchors[body_lines[kind]],"missing title/body source anchors: " .. kind)
    assert(anchors[body_lines[kind]]>anchors[marker_lines[kind]],"alert body pinned to its title: " .. kind)
    local color=theme.resolve("dark")["alert_" .. kind:lower()]
    local rgb=string.char(tonumber(color:sub(2,3),16),tonumber(color:sub(4,5),16),tonumber(color:sub(6,7),16))
    local row=vim.system({"magick",directory .. "/native.png","-crop",
      "700x1+0+" .. math.floor(anchors[marker_lines[kind]]+30),"+repage","-depth","8","RGB:-"}):wait()
    assert(row.code==0 and row.stdout:find(rgb,1,true),"missing visible colored alert border: " .. kind)
  end
  vim.o.columns=120; vim.o.lines=30
  vim.cmd("edit " .. vim.fn.fnameescape(source))
  mdview.setup({raw=false,smooth=false,zbelow=false,clamp=false,stylesheet=css})
  mdview.open("replace")
  wait(function() return settled(mdview.status()) end,"default literal alert reader")
  local s=mdview.status(); oracle(s,false); mdview.close()
  for _,mode in ipairs({"replace","split"}) do
    api.nvim_set_current_win(s.source_win)
    api.nvim_win_set_cursor(0,{1,0})
    api.nvim_set_hl(0,"Normal",{fg="#eeeeee",bg="#101010"})
    mdview.setup({alerts=true,theme=mode=="split" and "nvim" or "light",split_follow="viewport"})
    mdview.open(mode)
    wait(function() return settled(mdview.status()) end,mode .. " first alerts")
    s=mdview.status(); oracle(s,true)
    local revision=s.revision
    api.nvim_buf_set_lines(s.source_buf,marker_lines.NOTE-1,marker_lines.NOTE,false,{"> [!WARNING]"})
    api.nvim_exec_autocmds("TextChanged",{buffer=s.source_buf})
    wait(function() return settled(s) and s.revision>revision end,mode .. " unsaved type change")
    oracle(s,true)
    if mode=="split" then
      local before=s.revision
      local previous=directory .. "/before-diagnostic.png"
      vim.fn.writefile(vim.fn.readfile(s.frame_path,"b"),previous,"b")
      api.nvim_set_hl(0,"DiagnosticWarn",{fg="#ffffff"})
      api.nvim_exec_autocmds("ColorScheme",{})
      wait(function() return settled(s) and s.revision>before end,"diagnostic-only alert palette reload")
      assert(not equal(previous,s.frame_path),"diagnostic-only change did not recolor the visible warning")
      oracle(s,true)
    end
    assert(contents(source)==original,"preview saved unsaved alert changes")
    if mode=="split" then
      api.nvim_set_current_win(s.source_win)
      api.nvim_win_set_cursor(s.source_win,{body_lines.IMPORTANT,0})
      vim.cmd("normal! zt")
      api.nvim_exec_autocmds("WinScrolled",{pattern=tostring(s.source_win)})
      wait(function() return settled(s) and s.frame.line==body_lines.IMPORTANT end,"interior alert scroll")
      assert(s.frame.y>s.fragments[1].y,"interior alert navigation stayed at document start")
    else
      s.scroll_to(180)
      wait(function() return settled(s) and s.frame.y==180 end,"reader alert scroll")
    end
    local width=s.width
    local sibling
    if mode=="replace" then
      api.nvim_set_current_win(s.preview_win)
      vim.cmd("rightbelow vsplit")
      sibling=api.nvim_get_current_win()
      api.nvim_win_set_buf(sibling,s.source_buf)
      api.nvim_set_current_win(s.preview_win)
    end
    api.nvim_win_set_width(s.preview_win,math.max(36,api.nvim_win_get_width(s.preview_win)-12))
    api.nvim_exec_autocmds("WinResized",{})
    wait(function() return settled(s) and s.width~=width end,mode .. " width reflow")
    oracle(s,true)
    local session_dir=s.directory
    mdview.close()
    wait(function() return vim.fn.isdirectory(session_dir)==0 end,mode .. " cleanup")
    if sibling and api.nvim_win_is_valid(sibling) then api.nvim_win_close(sibling,true) end
    api.nvim_set_current_win(s.source_win)
    api.nvim_buf_set_lines(s.source_buf,0,-1,false,fixture)
  end
  mdview.setup({alerts=false})
  mdview.open("replace")
  wait(function() return settled(mdview.status()) end,"explicit alert disable")
  oracle(mdview.status(),false)
  print("PASS: five opt-in alerts, literal/escaped/code/nested boundaries, body formatting, title/body source anchors, themed pixel parity, reader/split unsaved edits/scroll/resize, disable and cleanup")
end
local ok,err=xpcall(check,debug.traceback)
mdview.close()
if not ok then io.stderr:write(err .. "\nArtifacts: " .. directory .. "\n"); vim.cmd("cquit 1") end
vim.fn.delete(directory,"rf")
vim.cmd("qall!")
