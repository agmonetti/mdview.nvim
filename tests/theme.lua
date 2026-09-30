-- Run from the repository root: nvim --headless -u NONE -l tests/theme.lua
local api = vim.api
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local directory = "/tmp/mdview-theme-test-" .. vim.fn.getpid()
vim.fn.mkdir(directory, "p")
package.preload["image"] = function()
  return {from_file=function(path)
    assert(vim.fn.filereadable(path)==1, "missing viewport image")
    return {id="theme-test", global_state={images={}}, original_path=path,
      clear=function() end, render=function() end}
  end}
end
package.preload["image.utils.term"] = function()
  return {get_size=function() return {cell_width=10, cell_height=20} end}
end
local mdview = require("mdview")
local theme = require("mdview.theme")
local original = {background=vim.o.background, columns=vim.o.columns, lines=vim.o.lines}
local env_names = {"FPLOG_RAW", "FPLOG_SMOOTH", "FPLOG_RAW_ZBELOW", "FPLOG_CLAMP_PX", "FPLOG_C", "FPLOG_STEP", "FPLOG_CLAMP", "KITTY_WINDOW_ID"}
local environment = {}
for _, name in ipairs(env_names) do environment[name]=vim.env[name]; vim.env[name]=nil end
local names = {"Normal", "NormalFloat", "Title", "Underlined", "Identifier", "Comment", "MdviewThemeTestNormal", "MdviewThemeTestTitle", "MdviewThemeTestAccent", "MdviewThemeTestComment", "MdviewThemeTestFloat"}
local highlights = {}
for _, name in ipairs(names) do highlights[name]=api.nvim_get_hl(0,{name=name,link=true}) end
local original_win = api.nvim_get_current_win()
local original_namespace = api.nvim_get_hl_ns({winid=original_win})
local function wait(predicate, description)
  assert(vim.wait(15000, predicate, 10), description .. ": " .. tostring(mdview.status() and mdview.status().error))
end
local function settled(s)
  return s.frame and not s.busy and not s.dirty and not s.debouncing and not s.error and s.frame.revision==s.revision
end
local function command(args, stdin)
  local result=vim.system(args, {text=true, stdin=stdin}):wait()
  assert(result.code==0, result.stderr)
  return result.stdout
end
local function hex(value)
  return (value:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function contents(path)
  local file=assert(io.open(path,"rb")); local text=file:read("*a"); file:close(); return text
end
local function save(path, text)
  vim.fn.writefile(vim.split(text,"\n",{plain=true}),path)
  return path
end
local function pixels_equal(a,b)
  local result=vim.system({"magick","compare","-metric","AE",a,b,"null:"},{text=true}):wait()
  assert(result.code==0 or result.code==1, "pixel comparison failed: " .. result.stderr)
  local difference=assert(tonumber(result.stderr:match("^[%d.]+")),result.stderr)
  return difference==0
end
-- Independent WCAG calculation checks the resolved colors, not resolver internals.
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
local function readable(p)
  for _, key in ipairs({"bg","fg","heading","accent","muted","surface","inline","border","code"}) do
    assert(type(p[key])=="string" and p[key]:match("^#%x%x%x%x%x%x$"), "invalid palette color " .. key)
  end
  for _, key in ipairs({"fg","heading","accent","muted"}) do
    assert(contrast(p[key],p.bg)>=4.5, key .. " is unreadable against the document background")
  end
  assert(p.surface~=p.bg, "code/table surface is indistinguishable from the document")
  assert(contrast(p.code,p.surface)>=4.5, "fenced code is unreadable")
  assert(contrast(p.code,p.inline)>=4.5, "inline code is unreadable")
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
  return theme.resolve("nvim")
end
local function geometry(output)
  local ready, fragments
  fragments={}
  for line in output:gmatch("[^\n]+") do
    if line:match("^READY ") then
      local fields=vim.split(line," ",{trimempty=true})
      ready=table.concat({fields[2],fields[3],fields[4]}," ") -- Exclude timing, not geometry.
    elseif line:match("^FRAG ") then fragments[#fragments+1]=line
    elseif line:match("^ERROR ") then error("native worker error: " .. line) end
  end
  assert(ready and #fragments>0,"worker did not produce document geometry")
  return {ready=ready,fragments=fragments}
end
local function native(source, stylesheet, width, output, y, height)
  local load=table.concat({"LOAD",1,width,hex(source),hex(directory),hex(stylesheet)}," ")
  local response=command({root .. "/build/mdview-preview"},load .. "\nQUIT\n")
  local shape=geometry(response)
  local document_height=assert(tonumber(shape.ready:match("%S+ %S+ (%S+)")))
  height=height or math.ceil(document_height)
  local request=table.concat({"DRAW",1,1,0,y or 0,0,height,hex(output)}," ")
  response=command({root .. "/build/mdview-preview"},load .. "\n" .. request .. "\nQUIT\n")
  assert(response:match("FRAME 1 1 "),"native worker did not draw viewport")
  assert(vim.deep_equal(shape,geometry(response)),"worker layout changed between identical loads")
  return shape
end
local css=root .. "/styles/markdown.css"
local function check()
  assert(math.abs(theme.contrast("#000000","#ffffff")-21)<1e-9,"incorrect black/white contrast")
  assert(theme.contrast("#123456","#123456")==1,"identical colors have nonunit contrast")
  -- Every role may be linked. Window-local namespaces must not affect global resolution.
  vim.o.background="dark"
  local p=schemes[1]
  for name, value in pairs({MdviewThemeTestNormal={fg=p.fg,bg=p.bg},MdviewThemeTestTitle={fg=p.heading},MdviewThemeTestAccent={fg=p.accent},MdviewThemeTestComment={fg=p.muted},MdviewThemeTestFloat={bg=p.surface}}) do
    api.nvim_set_hl(0,name,value)
  end
  for name, target in pairs({Normal="MdviewThemeTestNormal",Title="MdviewThemeTestTitle",Underlined="MdviewThemeTestAccent",Comment="MdviewThemeTestComment",NormalFloat="MdviewThemeTestFloat"}) do
    api.nvim_set_hl(0,name,{link=target})
  end
  local ns=api.nvim_create_namespace("mdview-theme-test-local")
  api.nvim_set_hl(ns,"Normal",{fg="#000000",bg="#ffffff"})
  api.nvim_win_set_hl_ns(original_win,ns)
  local linked=theme.resolve("nvim")
  for _, key in ipairs({"bg","fg","heading","accent","muted","surface"}) do assert(linked[key]==p[key],"linked/global resolution failed for " .. key) end
  readable(linked)
  api.nvim_set_hl(0,"Underlined",{})
  api.nvim_set_hl(0,"Identifier",{link="MdviewThemeTestAccent"})
  assert(theme.resolve("nvim").accent==p.accent,"linked Identifier fallback was not resolved")
  api.nvim_win_set_hl_ns(original_win,original_namespace)
  -- Absent and transparent Normal backgrounds follow 'background', not a stale palette.
  for _, background in ipairs({"dark","light"}) do
    vim.o.background=background
    for _, name in ipairs({"Normal","NormalFloat","Title","Underlined","Identifier","Comment"}) do api.nvim_set_hl(0,name,{}) end
    local fallback=theme.resolve("nvim")
    assert(fallback.bg==theme.resolve(background).bg,"missing Normal background ignored 'background'")
    readable(fallback)
    api.nvim_set_hl(0,"Normal",{fg=theme.resolve(background).fg,bg="NONE"})
    local transparent=theme.resolve("nvim")
    assert(transparent.bg==fallback.bg,"transparent Normal background did not fall back")
    readable(transparent)
    api.nvim_set_hl(0,"Normal",{fg="#777777",bg="#777777"})
    api.nvim_set_hl(0,"NormalFloat",{bg="#777777"})
    api.nvim_set_hl(0,"Comment",{fg="#777777"})
    api.nvim_set_hl(0,"Title",{fg="#777777"})
    api.nvim_set_hl(0,"Underlined",{fg="#777777"})
    readable(theme.resolve("nvim"))
  end
  api.nvim_set_hl(0,"Normal",{fg="#000000",bg="#ffffff"})
  api.nvim_set_hl(0,"NormalFloat",{bg="#000000"})
  readable(theme.resolve("nvim")) -- Code must be corrected for its own, opposite background.
  local dark, light=theme.resolve("dark"),theme.resolve("light")
  vim.o.background="dark"
  local nvim1, nvim2=scheme(1),scheme(2)
  readable(nvim1); readable(nvim2)
  local paragraph={}
  for n=1,100 do paragraph[#paragraph+1]="word" .. n .. " café repeated repeated" end
  local text={"# Theme fixture", "", "Text with **bold**, *emphasis*, [link](./other.md) and `inline code`.", "",
    "> A quote with `code` and ordinary text.", ">",
    "> | Quoted heading | Second |", "> | --- | --- |", "> | Quoted cell | Text |", "",
    "```lua", "print('hello theme')", "local n = 42", "```", "",
    "| Heading A | Heading B |", "| --- | --- |", "| Cell with `code` | Unicode ñ |", "", "---", "",
    "![local image](local%20image.png)", "", "## Another heading", "", table.concat(paragraph," ")}
  local source=directory .. "/source with spaces.md"
  vim.fn.writefile(text,source)
  command({"magick","-size","24x18","xc:red",directory .. "/local image.png"})
  local base=contents(css)
  local baseline_png=directory .. "/original.png"
  local baseline=native(source,css,700,baseline_png)
  local images={}
  for _, entry in ipairs({{"dark",dark},{"light",light},{"nvim1",nvim1},{"nvim2",nvim2}}) do
    local name,palette=entry[1],entry[2]
    local stylesheet=save(directory .. "/" .. name .. ".css",base .. "\n" .. theme.css(palette))
    images[name]=directory .. "/" .. name .. ".png"
    local shape=native(source,stylesheet,700,images[name])
    assert(vim.deep_equal(baseline,shape),name .. " changed READY/FRAG geometry")
  end
  assert(pixels_equal(baseline_png,images.dark),"explicit dark changed original pixels")
  for _, pair in ipairs({{"dark","light"},{"dark","nvim1"},{"dark","nvim2"},{"light","nvim1"},{"light","nvim2"},{"nvim1","nvim2"}}) do
    assert(not pixels_equal(images[pair[1]],images[pair[2]]),pair[1] .. "/" .. pair[2] .. " produced identical pixels")
  end
  -- A custom color sheet stays effective without an opt-in; explicit theme wins the cascade.
  local custom=save(directory .. "/custom.css",base .. "\n" .. theme.css(nvim1))
  local custom_before=contents(custom)
  vim.o.columns=100; vim.o.lines=30
  vim.cmd("edit " .. vim.fn.fnameescape(source))
  api.nvim_win_set_cursor(0,{1,0})
  mdview.setup({stylesheet=custom,raw=false,smooth=false,clamp=false,zbelow=false})
  mdview.open("replace")
  wait(function() local s=mdview.status(); return s and settled(s) end,"unthemed custom reader")
  local unthemed=mdview.status()
  assert(unthemed.stylesheet==custom and unthemed.palette==nil,"custom stylesheet changed without explicit theme")
  local custom_frame=directory .. "/custom-reference.png"
  native(source,custom,unthemed.frame.width,custom_frame,unthemed.frame.y,unthemed.frame.height)
  assert(pixels_equal(custom_frame,unthemed.frame_path),"unthemed reader ignored custom stylesheet")
  mdview.close()
  wait(function() return vim.fn.isdirectory(unthemed.directory)==0 end,"unthemed session cleanup")
  mdview.setup({theme="light"})
  mdview.open("replace")
  wait(function() local s=mdview.status(); return s and settled(s) end,"explicit light custom reader")
  local explicit=mdview.status()
  assert(explicit.stylesheet~=custom and vim.deep_equal(explicit.palette,light),"explicit theme did not produce effective palette stylesheet")
  local light_frame=directory .. "/light-reference.png"
  native(source,directory .. "/light.css",explicit.frame.width,light_frame,explicit.frame.y,explicit.frame.height)
  assert(pixels_equal(light_frame,explicit.frame_path),"explicit light did not override custom colors")
  assert(contents(custom)==custom_before,"explicit theme modified custom stylesheet")
  local explicit_css=explicit.stylesheet
  mdview.close()
  wait(function() return vim.fn.filereadable(explicit_css)==0 and vim.fn.isdirectory(explicit.directory)==0 end,"explicit temporary CSS cleanup")
  -- Reader scroll target survives color-only reload; overlapping work converges to newest source/palette/width.
  scheme(1)
  mdview.setup({stylesheet=css,theme="nvim"})
  mdview.open("replace")
  wait(function() local s=mdview.status(); return s and settled(s) end,"nvim themed reader")
  local s=mdview.status()
  assert(vim.deep_equal(s.palette,nvim1),"reader did not resolve nvim palette")
  s.scroll_to(180)
  wait(function() return settled(s) and s.frame.y==180 end,"themed reader scroll")
  local target,current,height=s.target_y,s.current_y,s.document_height
  local revision=s.revision
  local before=directory .. "/before-colors.png"
  vim.fn.writefile(vim.fn.readfile(s.frame_path,"b"),before,"b")
  scheme(2)
  api.nvim_exec_autocmds("ColorScheme",{})
  wait(function() return s.revision>revision and settled(s) end,"color-only reload")
  assert(s.current_y==current and s.target_y==target and s.frame.y==current,"color-only reload lost scroll target")
  assert(s.document_height==height,"color-only reload changed document height")
  assert(not pixels_equal(before,s.frame_path),"colorscheme reload did not recolor pixels")
  revision=s.revision
  local sequence=s.sequence
  api.nvim_exec_autocmds("ColorScheme",{})
  api.nvim_exec_autocmds("OptionSet",{pattern="background"})
  vim.wait(700,function() return false end,10)
  assert(s.revision==revision and s.sequence==sequence and settled(s),"unchanged palette reloaded/redrew reader")
  local newest
  for n=1,5 do
    newest=n%2+1
    scheme(newest)
    api.nvim_exec_autocmds("ColorScheme",{})
    api.nvim_buf_set_lines(s.source_buf,0,1,false,{"# Newest theme revision " .. n})
    vim.o.columns=100+n*2
    api.nvim_exec_autocmds("VimResized",{})
    s.scroll_to(180+n*20)
  end
  wait(function() return s.revision>revision and settled(s) and s.frame.y==s.current_y and s.frame.width==api.nvim_win_get_width(s.preview_win)*10 end,"theme/edit/resize convergence")
  assert(s.current_y==280 and s.target_y==280,"overlapping reload lost newest scroll target")
  assert(vim.deep_equal(s.palette,theme.resolve("nvim")),"published stale palette")
  assert(api.nvim_buf_get_lines(s.source_buf,0,1,false)[1]=="# Newest theme revision 5","published stale source")
  local latest=directory .. "/latest-unsaved.md"
  vim.fn.writefile(api.nvim_buf_get_lines(s.source_buf,0,-1,false),latest)
  local final_reference=directory .. "/latest-reference.png"
  native(latest,s.stylesheet,s.frame.width,final_reference,s.frame.y,s.frame.height)
  assert(pixels_equal(final_reference,s.frame_path),"final frame is not newest source/palette/geometry revision")
  assert(vim.fn.readfile(source)[1]=="# Theme fixture","reload modified disk source")
  -- OptionSet background changes the fallback even without a ColorScheme event.
  api.nvim_set_hl(0,"Normal",{fg="#202838",bg="NONE"})
  vim.o.background="dark"
  api.nvim_exec_autocmds("OptionSet",{pattern="background"})
  wait(function() return settled(s) and s.palette.bg==dark.bg end,"dark background fallback refresh")
  revision=s.revision
  vim.o.background="light"
  -- Neovim rebuilds default highlights on background changes; model a transparent scheme afterward.
  api.nvim_set_hl(0,"Normal",{fg="#202838",bg="NONE"})
  api.nvim_exec_autocmds("OptionSet",{pattern="background"})
  wait(function() return s.revision>revision and settled(s) and s.palette.bg==light.bg end,"light background fallback refresh")
  local generated_css,job=s.stylesheet,s.job
  mdview.close()
  wait(function() return not mdview.status() and vim.fn.filereadable(generated_css)==0 and vim.fn.isdirectory(s.directory)==0 end,"nvim session/CSS cleanup")
  assert(s.exit_code==0 and vim.fn.jobwait({job},0)[1]~=-1,"theme reader leaked worker")
  print("PASS: linked/fallback/contrast palettes, native color-only geometry and dark pixel parity, custom stylesheet opt-in, reader theme/scroll/edit/resize convergence, unchanged palette, cleanup")
end
local ok,err=xpcall(check,debug.traceback)
mdview.close()
for _, name in ipairs(names) do api.nvim_set_hl(0,name,highlights[name]) end
if api.nvim_win_is_valid(original_win) then api.nvim_win_set_hl_ns(original_win,original_namespace) end
for name,value in pairs(original) do vim.o[name]=value end
for _, name in ipairs(env_names) do vim.env[name]=environment[name] end
if not ok then io.stderr:write(err .. "\nArtifacts: " .. directory .. "\n"); vim.cmd("cquit 1") end
vim.fn.delete(directory,"rf")
vim.cmd("qall!")
