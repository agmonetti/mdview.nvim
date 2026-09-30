-- Document palettes: concrete color overrides only; layout stays in the user's CSS.
local M = {}
local dark = {bg="#0d1117", fg="#c9d1d9", heading="#e6edf3", accent="#58a6ff", muted="#8b949e", surface="#161b22", inline="#30363d", border="#30363d", code="#e6edf3"}
local light = {bg="#fafafa", fg="#24292f", heading="#1f2328", accent="#0969da", muted="#57606a", surface="#eff1f3", inline="#e6e9ed", border="#c6ccd2", code="#24292f"}
local function channels(hex)
  return tonumber(hex:sub(2,3),16), tonumber(hex:sub(4,5),16), tonumber(hex:sub(6,7),16)
end
local function luminance(hex)
  local r,g,b = channels(hex)
  local function linear(c)
    c=c/255
    return c<=0.04045 and c/12.92 or ((c+0.055)/1.055)^2.4
  end
  return 0.2126*linear(r)+0.7152*linear(g)+0.0722*linear(b)
end
function M.contrast(a,b)
  local x,y=luminance(a),luminance(b)
  return (math.max(x,y)+0.05)/(math.min(x,y)+0.05)
end
local function mix(bg,fg,amount)
  local r,g,b=channels(bg)
  local x,y,z=channels(fg)
  return string.format("#%02x%02x%02x", math.floor(r+(x-r)*amount+0.5), math.floor(g+(y-g)*amount+0.5), math.floor(b+(z-b)*amount+0.5))
end
local function readable(color,bg,fallback)
  if M.contrast(color,bg)>=4.5 then return color end
  if M.contrast(fallback,bg)>=4.5 then return fallback end
  return M.contrast("#000000",bg)>M.contrast("#ffffff",bg) and "#000000" or "#ffffff"
end
local function highlight(name,key)
  local hl=vim.api.nvim_get_hl(0,{name=name,link=false,create=false})
  return hl[key] and string.format("#%06x",hl[key]) or nil
end
function M.resolve(name)
  assert(name=="dark" or name=="light" or name=="nvim", "mdview: unknown theme " .. tostring(name))
  if name~="nvim" then return vim.deepcopy(name=="dark" and dark or light) end
  local base=vim.o.background=="light" and light or dark
  local p={}
  p.bg=highlight("Normal","bg") or base.bg
  p.fg=readable(highlight("Normal","fg") or base.fg,p.bg,base.fg)
  p.heading=readable(highlight("Title","fg") or p.fg,p.bg,p.fg)
  p.accent=readable(highlight("Underlined","fg") or highlight("Identifier","fg") or base.accent,p.bg,p.fg)
  p.muted=readable(highlight("Comment","fg") or base.muted,p.bg,p.fg)
  p.surface=highlight("NormalFloat","bg") or p.bg
  if p.surface==p.bg then p.surface=mix(p.bg,p.fg,0.06) end
  p.inline=p.surface
  p.border=mix(p.bg,p.fg,0.22)
  p.code=readable(p.fg,p.surface,base.code)
  return p
end
function M.css(p)
  -- Adaptive palettes share one code surface; stock palettes retain inherited table text.
  return table.concat({
    "html, body { background-color: "..p.bg.."; }",
    "body { color: "..p.fg.."; }",
    "h1, h2, h3, h4, h5, h6 { color: "..p.heading.."; }",
    "a { color: "..p.accent.."; }",
    "code { color: "..p.code.."; background-color: "..p.inline.."; }",
    "pre { background-color: "..p.surface.."; }",
    "pre code { color: "..(p.inline==p.surface and p.code or p.fg).."; background-color: transparent; }",
    "blockquote { color: "..p.muted.."; border-left-color: "..p.border.."; }",
    "h1, h2 { border-bottom-color: "..p.border.."; }",
    "tr, th, td { border-color: "..p.border.."; }",
    "th { background-color: "..p.surface.."; color: "..(p.inline==p.surface and p.code or "inherit").."; }",
    "hr { border-top-color: "..p.border.."; }",
  },"\n")
end
return M
