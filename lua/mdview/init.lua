local M = {}
local api = vim.api
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local options = { renderer = root .. "/build/mdview-preview", stylesheet = root .. "/styles/markdown.css", mode = "replace", raw = nil }
-- ponytail: one preview session; add per-window sessions when simultaneous previews are needed.
local session
local function wants_zbelow(opts)
  if opts.zbelow ~= nil then return opts.zbelow end
  return vim.env.FPLOG_RAW_ZBELOW == "1"
end
local function can_use_raw(opts)
  if opts.raw == false then return false end
  local opt_in = (opts.raw == true) or (vim.env.FPLOG_RAW == "1") or wants_zbelow(opts)
  if not opt_in then return false end
  -- Detección de soporte al inicio (Kitty local); si no hay soporte o es remoto (SSH), usar fallback PNG
  if vim.env.SSH_CLIENT ~= nil or vim.env.SSH_TTY ~= nil or vim.env.SSH_CONNECTION ~= nil or vim.env.TMUX ~= nil then return false end
  local is_kitty = (vim.env.TERM == "xterm-kitty") or (vim.env.KITTY_WINDOW_ID ~= nil)
  if not is_kitty then return false end
  return true
end
local function hex(value)
  if value == "" then return "-" end
  return (value:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function unhex(value)
  return (value:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end))
end
local function notify(message) vim.notify("mdview: " .. message, vim.log.levels.ERROR) end

-- guicursor is global: hide only while the document buffer has focus.
-- With termguicolors, blend=100 makes the TUI emit civis instead of painting over the raster.
local function viewer_cursor(s)
  local saved, hidden, cmdline
  local function restore()
    if hidden and vim.o.guicursor == hidden then vim.o.guicursor = saved end
    hidden = nil
  end
  local function refresh()
    if session ~= s then return end
    local mode = api.nvim_get_mode().mode
    if not cmdline and api.nvim_get_current_win() == s.preview_win
      and api.nvim_get_current_buf() == s.preview_buf and (mode == "n" or mode == "v" or mode == "V") then
      -- A color keeps the attribute nonempty; blend=100 hides it regardless of that color.
      api.nvim_set_hl(0, "MdviewHiddenCursor", {bg=0, blend=100})
      if not hidden or vim.o.guicursor ~= hidden then
        saved = vim.o.guicursor
        hidden = saved .. (saved ~= "" and "," or "") .. "n-v:block-blinkon0-MdviewHiddenCursor"
        vim.o.guicursor = hidden
      end
    else
      restore()
    end
  end
  api.nvim_create_autocmd({"WinEnter", "BufEnter", "ModeChanged", "ColorScheme"}, {group=s.group, callback=refresh})
  api.nvim_create_autocmd("CmdlineEnter", {group=s.group, callback=function() cmdline=true; restore() end})
  api.nvim_create_autocmd("CmdlineLeave", {group=s.group, callback=function()
    cmdline=false
    vim.schedule(refresh)
  end})
  s.restore_cursor = restore
  refresh()
end

-- Kitty compares resolved cell RGB with its default background, not Neovim's bg=NONE.
local function kitty_layer(s)
  if not s.raw or not wants_zbelow(options) then return end
  local ns = api.nvim_create_namespace("mdview.kitty-background")
  local previous_ns = api.nvim_get_hl_ns({winid=s.preview_win})
  local capability = hex("kitty-query-background_opacity")
  local layer = { enabled=false }
  s.layer = layer
  local function alive() return session == s and api.nvim_win_is_valid(s.preview_win) end
  local function place()
    if not alive() or not s.frame then return end
    local pos = api.nvim_win_get_position(s.preview_win)
    require("image/backends/kitty/helpers").write_graphics_at({
      action="p", image_id=s.raw_image_id, placement_id=s.raw_image_id, display_cursor_policy=1,
      display_zindex=layer.enabled and -1073741825 or -1,
      display_width=s.frame.width, display_height=s.frame.height, quiet=2,
    }, pos[2]+1, pos[1]+1)
  end
  local function restore()
    if api.nvim_win_is_valid(s.preview_win) then api.nvim_win_set_hl_ns(s.preview_win, previous_ns) end
  end
  local function fallback(reason)
    if not alive() then return end
    layer.enabled=false; restore(); place()
    if reason and layer.warning ~= reason then
      layer.warning=reason
      vim.notify("mdview: z-below disabled: " .. reason .. "; using z=-1", vim.log.levels.WARN)
    end
  end
  local function apply()
    if not alive() or not layer.color or layer.opacity == nil then return end
    -- A dedicated window namespace does not leak winhighlight into LSP floats.
    for _, name in ipairs({"Normal", "NormalNC", "EndOfBuffer", "SignColumn"}) do
      local hl = api.nvim_get_hl(0, {name=name, link=true})
      for _=1,10 do
        if not hl.link then break end
        hl=api.nvim_get_hl(0, {name=hl.link, link=true})
      end
      hl.link=nil
      hl.bg=layer.color; hl.ctermbg=nil
      api.nvim_set_hl(ns, name, hl)
    end
    api.nvim_win_set_hl_ns(s.preview_win, ns)
    layer.enabled=true; layer.warning=nil; place()
  end
  local function query(reset)
    if not alive() or layer.pending then return end
    layer.pending=true; layer.color=nil; layer.opacity=nil
    layer.token=(layer.token or 0)+1
    local token=layer.token
    -- On theme changes, use the safe layer until both current answers arrive.
    if reset or not layer.enabled then fallback() end
    local ok = pcall(function()
      require("image/backends/kitty/helpers").write("\27]11;?\7\27P+q" .. capability .. "\27\\")
    end)
    if not ok then layer.pending=false; fallback("cannot query terminal"); return end
    vim.defer_fn(function()
      if alive() and layer.pending and layer.token==token then
        layer.pending=false; fallback("background/opacity query timed out")
      end
    end, 500)
  end
  api.nvim_create_autocmd("TermResponse", {group=s.group, callback=function(ev)
    if not alive() then return end
    local seq = ev.data and ev.data.sequence or vim.v.termresponse
    if seq:match("^\27%[%?997;") then query(true); return end
    if not layer.pending then return end
    local color_response=seq:gsub("\27\\$", ""):gsub("\7$", "")
    local r,g,b = color_response:match("^\27%]11;rgb:(%x+)/(%x+)/(%x+)$")
    if r and #r<=4 and #g<=4 and #b<=4 then
      local function channel(v) return math.floor(tonumber(v,16)*255/(16^#v-1)+0.5) end
      layer.color=channel(r)*65536+channel(g)*256+channel(b)
    end
    -- TermResponse strips string terminators on real Neovim TUI responses.
    local answer = color_response:match("^\27P1%+r" .. capability .. "=(%x+)$")
    if answer and #answer%2==0 then
      local opacity=tonumber(unhex(answer))
      if opacity and opacity>=0 and opacity<=1 then layer.opacity=opacity end
    elseif seq:match("^\27P0%+r" .. capability) then
      layer.pending=false; fallback("terminal cannot report opacity"); return
    end
    if layer.color and layer.opacity ~= nil then layer.pending=false; apply() end
  end})
  api.nvim_create_autocmd({"ColorScheme", "FocusGained"}, {group=s.group, callback=query})
  -- Opacity changes need not emit a color notification. Poll only in this opt-in mode.
  local timer=vim.uv.new_timer()
  timer:start(1000,1000,vim.schedule_wrap(query))
  layer.close=function() timer:stop(); timer:close(); restore() end
  query()
end

function M.setup(opts)
  opts = opts or {}
  assert(opts.preset == nil or opts.preset == "fluid", "mdview: unknown preset " .. tostring(opts.preset))
  assert(opts.zbelow == nil or type(opts.zbelow) == "boolean", "mdview: zbelow must be boolean")
  assert(opts.alerts == nil or type(opts.alerts) == "boolean", "mdview: alerts must be boolean")
  assert(opts.split_follow == nil or opts.split_follow == "viewport" or opts.split_follow == "cursor",
    "mdview: split_follow must be 'viewport' or 'cursor'")
  assert(opts.theme == nil or opts.theme == "dark" or opts.theme == "light" or opts.theme == "nvim",
    "mdview: unknown theme " .. tostring(opts.theme))
  assert(opts.mermaid == nil or type(opts.mermaid) == "boolean"
    or (type(opts.mermaid) == "table" and type(opts.mermaid.renderer) == "string" and opts.mermaid.renderer ~= ""),
    "mdview: mermaid must be true, false or {renderer='/path/to/merman-cli'}")
  local preset = opts.preset == "fluid" and {raw=true, smooth=true, factor=0.6, clamp=84} or {}
  options = vim.tbl_extend("force", options, preset, opts)
  if options.mermaid == true then
    options.mermaid = {renderer = root .. "/build/merman-evaluation/target/release/merman-cli"}
  end
end

function M.close()
  local s = session
  if not s then return end
  session = nil
  if s.smooth_timer then s.smooth_timer:stop(); s.smooth_timer:close(); s.smooth_timer=nil end
  if s.layer then s.layer.close() end
  if s.restore_cursor then s.restore_cursor() end
  api.nvim_del_augroup_by_id(s.group)
  if s.raw and s.raw_image_id then
    pcall(function()
      require("image/backends/kitty/helpers").write_graphics({ action = "d", display_delete = "i", image_id = s.raw_image_id, quiet = 2 })
    end)
  end
  if s.image then
    pcall(function()
      s.image:clear()
      -- image.nvim has no dispose API; release our single registered image after clearing it.
      s.image.global_state.images[s.image.id] = nil
    end)
  end
  if s.job and s.job > 0 then
    pcall(vim.fn.chansend, s.job, "QUIT\n")
    -- Asynchronous shutdown, including layouts still in flight.
    vim.defer_fn(function()
      if vim.fn.jobwait({ s.job }, 0)[1] == -1 then pcall(vim.fn.jobstop, s.job) end
    end, 1000)
    if s.dead then vim.fn.delete(s.directory, "rf") end
  else vim.fn.delete(s.directory, "rf") end
  if s.mode == "replace" then
    if api.nvim_win_is_valid(s.source_win) and api.nvim_buf_is_valid(s.source_buf) then
      pcall(function() vim.wo[s.source_win].winfixbuf = false end)
      local target_line = 1
      if s.fragments and s.current_y then
        for _, f in ipairs(s.fragments) do
          if f.y <= (s.current_y + 10) and f.line > target_line then target_line = f.line end
        end
      end
      target_line = math.max(1, math.min(target_line, api.nvim_buf_line_count(s.source_buf)))
      api.nvim_win_set_buf(s.source_win, s.source_buf)
      pcall(function()
        api.nvim_win_set_cursor(s.source_win, { target_line, 0 })
        vim.cmd("normal! zt")
      end)
      if s.saved_win_opts then
        for k, v in pairs(s.saved_win_opts) do
          pcall(function() vim.wo[s.source_win][k] = v end)
        end
      end
    end
  else
    if api.nvim_win_is_valid(s.preview_win) then pcall(api.nvim_win_close, s.preview_win, true) end
  end
  if api.nvim_buf_is_valid(s.preview_buf) then pcall(api.nvim_buf_delete, s.preview_buf, { force = true }) end
end

function M.open(mode)
  mode = mode or options.mode or "replace"
  if mode ~= "split" and mode ~= "replace" then mode = "replace" end
  if session then
    if api.nvim_win_is_valid(session.source_win) then api.nvim_set_current_win(session.source_win) end
    return
  end
  if vim.fn.has("nvim-0.10") == 0 then return notify("Neovim 0.10+ is required") end
  if vim.fn.executable(options.renderer) ~= 1 then return notify("Build the renderer first: " .. root .. "/scripts/build.sh") end
  if vim.fn.filereadable(options.stylesheet) ~= 1 then return notify("Stylesheet not found: " .. options.stylesheet) end
  if options.mermaid and vim.fn.executable(options.mermaid.renderer) ~= 1 then
    return notify("Mermaid renderer not executable: " .. options.mermaid.renderer
      .. ". Build the bundled renderer with: bash " .. vim.fn.shellescape(root .. "/scripts/build-mermaid")
      .. " (or correct mermaid.renderer)")
  end
  local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  if vim.bo[source_buf].buftype ~= "" then return notify("Open a Markdown source buffer first") end
  local ok, image = pcall(require, "image")
  if not ok then return notify("image.nvim is required and must be configured") end
  local term_ok, cell = pcall(function() return require("image.utils.term").get_size() end)
  if not term_ok or not cell or not cell.cell_width or cell.cell_width <= 0 or not cell.cell_height or cell.cell_height <= 0 then
    return notify("Cannot query terminal pixel size; run Neovim inside Kitty")
  end
  local smooth = mode == "replace" and (options.smooth == true or (options.smooth ~= false and vim.env.FPLOG_SMOOTH == "1"))
  local function positive(value, fallback)
    value = tonumber(value)
    return value and value > 0 and value < math.huge and value or fallback
  end
  local smooth_factor = math.min(1, positive(options.factor or vim.env.FPLOG_SMOOTH_FACTOR, 0.4))
  local smooth_interval = math.max(16, math.min(20, positive(vim.env.FPLOG_SMOOTH_INTERVAL, 16)))
  local raw_supported = can_use_raw(options)
  local raw_image_id = raw_supported and (500000 + math.random(1, 400000)) or nil
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p", 448)
  local initial_line = api.nvim_win_get_cursor(source_win)[1]

  local preview_win, preview_buf, saved_win_opts
  if mode == "replace" then
    preview_win = source_win
    preview_buf = api.nvim_create_buf(false, true)
    saved_win_opts = {}
    for _, k in ipairs({ "number", "relativenumber", "signcolumn", "foldcolumn", "wrap", "cursorline", "spell", "winbar", "winhighlight" }) do
      saved_win_opts[k] = vim.wo[source_win][k]
    end
    api.nvim_win_set_buf(source_win, preview_buf)
  else
    vim.cmd("rightbelow vsplit")
    preview_win = api.nvim_get_current_win()
    preview_buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(preview_win, preview_buf)
    api.nvim_set_current_win(source_win)
  end

  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].filetype = "mdview"
  vim.bo[preview_buf].modifiable = false
  local win_opts = { number=false, relativenumber=false, signcolumn="no", foldcolumn="0", wrap=false, cursorline=false, spell=false }
  if vim.fn.exists("+winfixbuf") == 1 then win_opts.winfixbuf = true end
  for key, value in pairs(win_opts) do pcall(function() vim.wo[preview_win][key] = value end) end
  vim.wo[preview_win].fillchars = "eob: "

  local s = { mode=mode, source_win=source_win, source_buf=source_buf, preview_win=preview_win, preview_buf=preview_buf,
    saved_win_opts=saved_win_opts, directory=directory, group=api.nvim_create_augroup("mdview.session", {clear=true}), revision=0, sequence=0,
    dirty=true, busy=false, loaded=false, pending="", fragments={}, error=nil, tick=-1, initial_line=initial_line,
    current_y=0, initialized_y=false, raw=raw_supported, raw_image_id=raw_image_id, smooth=smooth }
  s.stylesheet = options.stylesheet
  s.split_follow = mode == "split" and options.split_follow == "cursor"
  local theme = options.theme
  local mermaid = options.mermaid
  local alerts = options.alerts == true
  local base_css
  if theme then
    base_css = table.concat(vim.fn.readfile(options.stylesheet), "\n")
    s.stylesheet = directory .. "/markdown.css"
    s.palette = require("mdview.theme").resolve(theme)
  end
  session = s
  kitty_layer(s)
  viewer_cursor(s)
  local function valid()
    if session ~= s or not api.nvim_buf_is_valid(source_buf) or not api.nvim_buf_is_valid(preview_buf) then return false end
    if s.mode == "replace" then
      return api.nvim_win_is_valid(preview_win) and api.nvim_win_get_buf(preview_win) == preview_buf
    else
      return api.nvim_win_is_valid(source_win) and api.nvim_win_is_valid(preview_win)
        and api.nvim_win_get_buf(source_win) == source_buf and api.nvim_win_get_buf(preview_win) == preview_buf
    end
  end
  local function status(message)
    if not valid() or s.message == message then return end
    s.message = message
    if s.raw and s.raw_image_id then
      pcall(function()
        require("image/backends/kitty/helpers").write_graphics({ action = "d", display_delete = "i", image_id = s.raw_image_id, quiet = 2 })
      end)
    elseif s.image then
      s.image:clear(true)
    end
    vim.bo[preview_buf].modifiable = true
    api.nvim_buf_set_lines(preview_buf, 0, -1, false, vim.split(message, "\n", {plain=true}))
    vim.bo[preview_buf].modifiable = false
  end
  local function size()
    local current = require("image.utils.term").get_size()
    if current and current.cell_width and current.cell_width > 0 then cell = current end
    local w = math.floor(api.nvim_win_get_width(preview_win) * cell.cell_width)
    local h = math.floor(api.nvim_win_get_height(preview_win) * cell.cell_height)
    if w < 64 or w > 4096 or h < 1 or h > 8192 then error("Unsupported viewport: " .. w .. "x" .. h) end
    return w, h
  end
  local function position()
    if s.mode == "replace" then return 0, math.floor(s.current_y or 0), 0 end
    local win = source_win
    local result = api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      local botline = vim.fn.line("w$", win)
      local topline = view.topline
      -- conceal_lines can leave a hidden closing fence as the logical topline.
      -- Anchor the first displayed line, not the previous diagram's hidden fence.
      while topline < botline
        and api.nvim_win_text_height(win, {start_row=topline-1, end_row=topline-1}).all == 0 do
        topline = topline + 1
      end
      local col = 0
      if topline == view.topline and (view.skipcol or 0) > 0 then
        -- skipcol is in display cells; source attribution is in UTF-8 bytes, not characters.
        col = math.max(0, vim.fn.virtcol2col(win, view.topline, view.skipcol + 1) - 1)
      end
      local cursor_line, cursor_col, through_line, previous_top = 0, 0, 0, -1
      if s.split_follow then
        local cursor = api.nvim_win_get_cursor(win)
        if cursor[1] >= topline and cursor[1] <= botline then
          cursor_line, cursor_col, through_line = cursor[1], cursor[2], cursor[1]
          -- A heading immediately followed by a diagram represents that diagram too.
          local text = api.nvim_buf_get_lines(source_buf, cursor_line-1, cursor_line, false)[1] or ""
          if mermaid and text:match("^%s*#+%s+") then
            local next_line = cursor_line + 1
            while next_line <= api.nvim_buf_line_count(source_buf) do
              local following = api.nvim_buf_get_lines(source_buf, next_line-1, next_line, false)[1] or ""
              if following:match("%S") then
                local fence, language = following:match("^%s*([`~]+)%s*(%S+)")
                if fence and (fence:match("^```+$") or fence:match("^~~~+$")) and language == "mermaid" then
                  through_line = next_line
                end
                break
              end
              next_line = next_line + 1
            end
          end
          if s.frame and s.frame.revision == s.revision then previous_top = s.frame.y end
        end
      end
      return {topline, col, botline, cursor_line, cursor_col, through_line, previous_top}
    end)
    return unpack(result)
  end
  local function send(command)
    if vim.fn.chansend(s.job, command .. "\n") == 0 then error("Renderer stdin is closed") end
  end
  local pump, safe_pump, tick_smooth
  pump = function()
    if not valid() or s.busy or s.debouncing or s.dead then return end
    local sized, w, h = pcall(size)
    if not sized then status(w); return end
    local tick = api.nvim_buf_get_changedtick(source_buf)
    if tick ~= s.tick or w ~= s.width then s.dirty = true end
    if s.dirty then
      s.revision = s.revision + 1
      s.tick, s.width, s.height = tick, w, h
      s.snapshot = directory .. "/snapshot.md"
      vim.fn.writefile(api.nvim_buf_get_lines(source_buf, 0, -1, false), s.snapshot)
      if theme then
        vim.fn.writefile(vim.split(base_css .. "\n" .. require("mdview.theme").css(s.palette), "\n", {plain=true}), s.stylesheet)
      end
      local name = api.nvim_buf_get_name(source_buf)
      local base = name ~= "" and vim.fn.fnamemodify(name, ":h") or vim.fn.getcwd()
      s.dirty, s.busy, s.loaded, s.error = false, true, false, nil
      s.fragments = {}
      status("Rendering Markdown…")
      local load = {"LOAD", s.revision, w, hex(s.snapshot), hex(base), hex(s.stylesheet)}
      if alerts then load[#load+1] = "alerts=1" end
      if mermaid then
        load[#load+1] = hex(mermaid.renderer)
        load[#load+1] = hex(directory .. "/diagrams")
        load[#load+1] = hex(s.palette and s.palette.bg or "#0d1117")
      end
      send(table.concat(load, " "))
    elseif s.loaded then
      if not s.smooth and s.clamp_max and s.target_y then
        local base_y = s.last_drawn_y or s.current_y or 0
        local dist = s.target_y - base_y
        if math.abs(dist) > s.clamp_max then
          local dir = dist > 0 and 1 or -1
          s.current_y = base_y + dir * s.clamp_max
        else
          s.current_y = s.target_y
        end
      end
      local line, col, botline, cursor_line, cursor_col, through_line, previous_top = position()
      local key = table.concat({s.revision, line, col, botline, w, h, cursor_line or 0, cursor_col or 0, through_line or 0}, ":")
      if key == s.last_key then return end
      local now = vim.uv.hrtime() / 1000000
      if not s.smooth and s.next_frame_at and now < s.next_frame_at then
        if not s.frame_timer then
          s.frame_timer = true
          vim.defer_fn(function() s.frame_timer=false; safe_pump() end, math.ceil(s.next_frame_at-now))
        end
        return
      end
      s.next_frame_at = now + (s.mode == "replace" and 16 or 100)
      s.sequence = s.sequence + 1
      s.busy, s.height, s.request_key = true, h, key
      if s.raw then
        s.frame_path = directory .. "/tty-graphics-protocol-frame-" .. s.sequence .. ".rgba"
      else
        s.frame_path = directory .. "/frame-" .. (s.sequence % 2) .. ".png"
      end
      local draw = {"DRAW", s.revision, s.sequence, line, col, botline, h, hex(s.frame_path)}
      if s.split_follow then
        s.request_cursor_key = table.concat({cursor_line, cursor_col, through_line}, ":")
        vim.list_extend(draw, {cursor_line, cursor_col, through_line, previous_top})
      end
      send(table.concat(draw, " "))
    end
  end
  safe_pump = function()
    local success, err = pcall(pump)
    if not success and valid() then s.busy=false; s.error=tostring(err); status(s.error) end
  end
  tick_smooth = function()
    if not valid() or s.dead then return end
    if not s.target_y or s.target_y == s.current_y then
      if s.smooth_timer then
        s.smooth_timer:stop()
        s.smooth_timer:close()
        s.smooth_timer = nil
      end
      return
    end
    local now = vim.uv.hrtime() / 1000000
    if s.busy or (s.next_smooth_at and now < s.next_smooth_at) then return end
    s.next_smooth_at = now + smooth_interval
    local dist = s.target_y - s.current_y
    if math.abs(dist) < 1 then
      s.current_y = s.target_y
    else
      local step = dist * smooth_factor
      if s.clamp_max and math.abs(step) > s.clamp_max then
        step = step > 0 and s.clamp_max or -s.clamp_max
      end
      s.current_y = s.current_y + step
    end
    safe_pump()
  end
  local function scroll_to(new_y)
    if not valid() or not s.loaded then return end
    local max_y = math.max(0, (s.document_height or 0) - (s.height or 800))
    new_y = math.floor(math.max(0, math.min(max_y, new_y)))
    s.target_y = new_y
    if s.smooth then
      if not s.smooth_timer then
        s.smooth_timer = vim.uv.new_timer()
        s.smooth_timer:start(smooth_interval, smooth_interval, vim.schedule_wrap(tick_smooth))
      end
      tick_smooth()
    elseif not s.clamp_max then
      if new_y == (s.current_y or 0) then return end
      s.current_y = new_y
      safe_pump()
    else
      safe_pump()
    end
  end
  s.scroll_to = scroll_to
  local function debounce(milliseconds, dirty)
    if not valid() then return end
    if dirty then
      s.dirty, s.debouncing = true, true
      s.edit_token = (s.edit_token or 0) + 1
      local token = s.edit_token
      vim.schedule(function() if valid() then status("Rendering Markdown…") end end)
      vim.defer_fn(function()
        if valid() and token == s.edit_token then s.debouncing=false; safe_pump() end
      end, milliseconds)
    else
      if s.scroll_timer then return end
      s.scroll_timer = true
      vim.defer_fn(function() s.scroll_timer=false; safe_pump() end, milliseconds)
    end
  end
  local function reply(line)
    if not valid() then return end
    local parts = vim.split(line, " ", {trimempty=true})
    local op = parts[1]
    if op == "FRAG" then
      s.fragments[#s.fragments+1] = {line=tonumber(parts[2]), column=tonumber(parts[3]), finish=tonumber(parts[4]), y=tonumber(parts[5])}
      return
    end
    s.busy = false
    if op == "ERROR" then
      s.loaded=false; s.error=unhex(parts[2] or "")
      status("Preview unavailable:\n" .. s.error .. "\nEdit the source to retry.")
      if s.dirty then safe_pump() end
    elseif op == "READY" then
      s.loaded=true; s.document_height=tonumber(parts[4]); s.layout_ms=tonumber(parts[5])
      vim.fn.delete(s.snapshot)
      if s.mode == "replace" and not s.initialized_y then
        local init_y, initial_anchor = 0, 0
        if s.initial_line > 1 then
          for _, f in ipairs(s.fragments) do
            if f.line <= s.initial_line and f.line > initial_anchor then
              initial_anchor, init_y = f.line, f.y
            elseif f.line == initial_anchor then init_y = math.min(init_y, f.y) end
          end
        end
        s.current_y = math.max(0, math.min(math.floor(init_y), s.document_height - s.height))
        s.initialized_y = true
      end
      safe_pump()
    elseif op == "FRAME" then
      local line_now, col_now, _, cursor_line, cursor_col, through_line = position()
      local sized, w, h = pcall(size)
      if not sized then status(w); return end
      local tick_check = api.nvim_buf_get_changedtick(source_buf) ~= s.tick
      -- Reader frames remain useful while input advances; rejecting them starves continuous scroll.
      local moved = s.mode == "split" and (tonumber(parts[4]) ~= line_now or tonumber(parts[5]) ~= col_now)
      if s.split_follow and s.request_cursor_key ~= table.concat({cursor_line, cursor_col, through_line}, ":") then moved = true end
      if s.dirty or tick_check or moved or tonumber(parts[2]) ~= s.revision
        or tonumber(parts[7]) ~= w or tonumber(parts[8]) ~= h then
        safe_pump(); return
      end
      local success, err = pcall(function()
        status("")
        if s.raw then
          local helpers = require("image/backends/kitty/helpers")
          helpers.write_graphics({
            action = "t", image_id = s.raw_image_id, transmit_format = 32, transmit_medium = "t",
            transmit_width = w, transmit_height = h, display_cursor_policy = 1, quiet = 2
          }, s.frame_path)
          local pos = api.nvim_win_get_position(preview_win)
          local zindex = s.layer and s.layer.enabled and -1073741825 or -1
          helpers.write_graphics_at({
            action = "p", image_id = s.raw_image_id, placement_id = s.raw_image_id, display_cursor_policy = 1,
            display_zindex = zindex, display_width = w, display_height = h, quiet = 2
          }, pos[2] + 1, pos[1] + 1)
        else
          if not s.image then
            -- image.nvim uses screenpos()'s 1-based row as a 0-based Kitty position.
            s.image = image.from_file(s.frame_path, { window=preview_win, buffer=preview_buf, x=0, y=0, render_offset_top=-1,
              max_width_window_percentage=100, max_height_window_percentage=100, namespace="mdview" })
            assert(s.image, "image.nvim could not load the viewport")
          else
            s.image.original_path=s.frame_path
            s.image.last_modified=-1
          end
          s.image:render()
        end
      end)
      if not success then s.error=tostring(err); status("Image display failed:\n" .. s.error); return end
      s.last_key=s.request_key
      s.last_drawn_y=tonumber(parts[6])
      s.frame={revision=tonumber(parts[2]), sequence=tonumber(parts[3]), line=tonumber(parts[4]), column=tonumber(parts[5]),
        y=tonumber(parts[6]), width=w, height=h, path=s.frame_path, ms=tonumber(parts[9])}
      s.error=nil
      -- Keep one draw in flight, then immediately catch up to the latest requested position.
      if s.smooth then
        if s.smooth_timer then tick_smooth() end
      else
        safe_pump()
      end
    else s.error="Invalid renderer response: " .. line; status(s.error) end
  end
  s.job = vim.fn.jobstart({options.renderer}, {
    on_stdout=function(_, chunks)
      if session ~= s then return end
      s.pending=s.pending .. table.concat(chunks, "\n")
      local lines=vim.split(s.pending, "\n", {plain=true}); s.pending=table.remove(lines)
      for _, line in ipairs(lines) do
        if line ~= "" then
          local success, err=pcall(reply, line)
          if not success and valid() then s.error=tostring(err); s.busy=false; status(s.error) end
        end
      end
    end,
    on_stderr=function(_, chunks)
      s.stderr=(s.stderr or "") .. table.concat(chunks, "\n")
      if #s.stderr > 4096 then s.stderr=s.stderr:sub(-4096) end
    end,
    on_exit=function(_, code)
      s.exit_code=code
      if session == s then s.dead=true; s.busy=false; s.error="Renderer exited (" .. code .. "): " .. (s.stderr or ""); status(s.error)
      else vim.fn.delete(directory, "rf") end
    end,
  })
  if s.job <= 0 then M.close(); return notify("Cannot start renderer") end
  api.nvim_buf_attach(source_buf, false, {
    on_lines=function() if session ~= s then return true end; debounce(200, true) end,
    on_detach=function() vim.schedule(function() if session == s then M.close() end end) end,
  })
  if theme == "nvim" then
    local function refresh_theme()
      if not valid() then return end
      local palette = require("mdview.theme").resolve(theme)
      if vim.deep_equal(palette, s.palette) then return end
      s.palette = palette
      -- Defer the CSS write until LOAD: never mutate a file a busy worker may be reading.
      debounce(0, true)
    end
    api.nvim_create_autocmd("ColorScheme", {group=s.group, callback=refresh_theme})
    api.nvim_create_autocmd("OptionSet", {group=s.group, pattern="background", callback=refresh_theme})
  end
  api.nvim_create_autocmd("WinScrolled", {group=s.group, callback=function() debounce(100, false) end})
  if s.split_follow then
    api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {group=s.group, buffer=source_buf, callback=function()
      if api.nvim_get_current_win() == source_win then debounce(0, false) end
    end})
  end
  api.nvim_create_autocmd({"WinResized", "VimResized"}, {group=s.group, callback=function()
    if not valid() then return end
    local sized, w=pcall(size)
    if sized then debounce(180, w ~= s.width) end
  end})
  api.nvim_create_autocmd({"BufWinEnter", "WinClosed", "BufWipeout"}, {group=s.group, callback=function()
    vim.schedule(function() if session == s and not valid() then M.close() end end)
  end})
  api.nvim_create_autocmd("VimLeavePre", {group=s.group, callback=function()
    M.close()
    if vim.fn.jobwait({s.job}, 1000)[1] == -1 then vim.fn.jobstop(s.job); vim.fn.jobwait({s.job}, 1000) end
    vim.fn.delete(directory, "rf")
  end})
  if mode == "replace" then
    local function cell_h()
      return (cell and cell.cell_height and cell.cell_height > 0 and cell.cell_height) or 18
    end
    local function step_size()
      return cell_h() * 2
    end
    local function page_size()
      return math.max(step_size(), (s.height or 800) - step_size() * 2)
    end
    local function half_page()
      return math.max(step_size(), math.floor((s.height or 800) / 2))
    end
    local wheel_mul = vim.env.FPLOG_C == "1" and 2 or (options.wheel_step or positive(vim.env.FPLOG_STEP, 4))
    local function wheel_step()
      return cell_h() * wheel_mul
    end
    if options.clamp or vim.env.FPLOG_P3 == "1" or s.smooth or vim.env.FPLOG_C == "1" then
      s.clamp_max = positive(options.clamp, positive(vim.env.FPLOG_CLAMP_PX, cell_h() * positive(vim.env.FPLOG_CLAMP, 4)))
    end
    local map = function(keys, fn, desc)
      for _, k in ipairs(type(keys) == "table" and keys or { keys }) do
        vim.keymap.set("n", k, fn, { buffer = preview_buf, silent = true, nowait = true, desc = desc })
      end
    end

    map({ "j", "<Down>" }, function() scroll_to((s.target_y or s.current_y or 0) + step_size()) end, "Scroll down")
    map({ "k", "<Up>" }, function() scroll_to((s.target_y or s.current_y or 0) - step_size()) end, "Scroll up")
    map({ "d", "<C-d>" }, function() scroll_to((s.target_y or s.current_y or 0) + half_page()) end, "Scroll half page down")
    map({ "u", "<C-u>" }, function() scroll_to((s.target_y or s.current_y or 0) - half_page()) end, "Scroll half page up")
    map({ "<Space>", "f", "<C-f>", "<PageDown>" }, function() scroll_to((s.target_y or s.current_y or 0) + page_size()) end, "Scroll page down")
    map({ "<S-Space>", "b", "<C-b>", "<PageUp>" }, function() scroll_to((s.target_y or s.current_y or 0) - page_size()) end, "Scroll page up")
    map({ "gg", "<Home>" }, function() scroll_to(0) end, "Scroll to top")
    map({ "G", "<End>" }, function() scroll_to(s.document_height or 0) end, "Scroll to bottom")
    map({ "<ScrollWheelDown>" }, function() scroll_to((s.target_y or s.current_y or 0) + wheel_step()) end, "Wheel down")
    map({ "<ScrollWheelUp>" }, function() scroll_to((s.target_y or s.current_y or 0) - wheel_step()) end, "Wheel up")
    map({ "q", "<Esc>" }, function() M.close() end, "Close reader mode")

    local edit = function(insert_cmd)
      local target_line = 1
      if s.fragments and s.current_y then
        for _, f in ipairs(s.fragments) do
          if f.y <= (s.current_y + 10) and f.line > target_line then target_line = f.line end
        end
      end
      target_line = math.max(1, math.min(target_line, api.nvim_buf_line_count(source_buf)))
      M.close()
      pcall(function()
        api.nvim_win_set_cursor(source_win, { target_line, 0 })
        vim.cmd("normal! zt")
        if insert_cmd then vim.cmd(insert_cmd) end
      end)
    end
    map("i", function() edit("startinsert") end, "Edit at current line (insert)")
    map("a", function() edit("startinsert") end, "Edit at current line (append)")
    map("o", function() edit("normal! o") end, "Edit below current line")
    map({ "e", "<CR>" }, function() edit(nil) end, "Edit at current line (normal)")

    local heading_nav = function(forward)
      if not s.fragments or #s.fragments == 0 then return end
      local lines = api.nvim_buf_get_lines(source_buf, 0, -1, false)
      local is_heading = {}
      for lnum, line in ipairs(lines) do
        if line:match("^#+%s+") then is_heading[lnum] = true end
      end
      local targets = {}
      for _, f in ipairs(s.fragments) do
        if is_heading[f.line] then table.insert(targets, f.y) end
      end
      table.sort(targets)
      local cur = s.current_y or 0
      if forward then
        for _, y in ipairs(targets) do
          if y > cur + 10 then scroll_to(y); return end
        end
      else
        for i = #targets, 1, -1 do
          if targets[i] < cur - 10 then scroll_to(targets[i]); return end
        end
      end
    end
    map("]]", function() heading_nav(true) end, "Next heading")
    map("[[", function() heading_nav(false) end, "Previous heading")

    map("t", function()
      local lines = api.nvim_buf_get_lines(source_buf, 0, -1, false)
      local items = {}
      for lnum, line in ipairs(lines) do
        local hashes, title = line:match("^(#+)%s+(.+)")
        if hashes then
          table.insert(items, { line = lnum, title = string.rep("  ", #hashes - 1) .. hashes .. " " .. title })
        end
      end
      if #items == 0 then return vim.notify("mdview: No headings found", vim.log.levels.INFO) end
      vim.ui.select(items, { prompt = "Headings:", format_item = function(it) return it.title end }, function(choice)
        if choice and s and s.fragments then
          for _, f in ipairs(s.fragments) do
            if f.line == choice.line then scroll_to(f.y); return end
          end
        end
      end)
    end, "Table of contents")

    local search_state = { query = "", matches = {}, idx = 0 }
    local search = function(reverse)
      local prompt = reverse and "? " or "/ "
      local query = vim.fn.input(prompt)
      if query == "" then return end
      search_state.query = query
      local lines = api.nvim_buf_get_lines(source_buf, 0, -1, false)
      local matches = {}
      local p = query:lower()
      for lnum, line in ipairs(lines) do
        if line:lower():find(p, 1, true) then
          local match_y = 0
          for _, f in ipairs(s.fragments) do
            if f.line <= lnum and f.line > 0 then match_y = f.y end
          end
          table.insert(matches, { line = lnum, y = match_y })
        end
      end
      if #matches == 0 then return vim.notify("mdview: Pattern not found: " .. query, vim.log.levels.WARN) end
      search_state.matches = matches
      local cur = s.current_y or 0
      search_state.idx = 1
      for i, m in ipairs(matches) do
        if m.y >= cur then search_state.idx = i; break end
      end
      scroll_to(matches[search_state.idx].y)
    end
    local search_step = function(forward)
      if #search_state.matches == 0 then return end
      local n = #search_state.matches
      search_state.idx = forward and ((search_state.idx % n) + 1) or (((search_state.idx - 2 + n) % n) + 1)
      scroll_to(search_state.matches[search_state.idx].y)
    end
    map("/", function() search(false) end, "Search forward")
    map("?", function() search(true) end, "Search backward")
    map("n", function() search_step(true) end, "Next search match")
    map("N", function() search_step(false) end, "Previous search match")
  end
  safe_pump()
end

function M.toggle(mode) if session then M.close() else M.open(mode) end end
function M.status() return session end -- Read-only diagnostics for regression checks and bug reports.
return M
