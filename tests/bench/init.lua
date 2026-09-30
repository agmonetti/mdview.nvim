-- Isolated real-terminal measurement config, invoked only by scripts/bench-scroll.
local api = vim.api
local root = assert(vim.env.MDVIEW_BENCH_ROOT)
local output = assert(vim.env.MDVIEW_BENCH_OUTPUT)
local factor = assert(tonumber(vim.env.MDVIEW_BENCH_FACTOR))
local renderer = vim.env.MDVIEW_BENCH_RENDERER or root .. "/build/mdview-preview"
local renderer_cpu = tonumber(vim.env.MDVIEW_BENCH_RENDERER_CPU)
local trace, phase, mdview
local start = vim.uv.hrtime()
local function now() return (vim.uv.hrtime() - start) / 1e6 end
local function save(name, value)
  vim.fn.writefile({vim.json.encode(value)}, output .. "/" .. name)
end
local function fail(message)
  save("error.json", {error=tostring(message), scenario=trace and trace.scenario, time_ms=now()})
  if mdview then pcall(mdview.close) end
  vim.cmd("cquit 1")
end
vim.notify = function(message, level)
  if level == vim.log.levels.ERROR then error(message) end
end
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(assert(vim.env.MDVIEW_IMAGE_PLUGIN))
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.cmdheight = 1
vim.o.mouse = "a"
vim.o.termguicolors = true
vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = "no"
vim.o.foldcolumn = "0"

local function run()
  assert(vim.fn.has("nvim-0.10") == 1, "Neovim 0.10+ is required")
  assert(vim.env.KITTY_WINDOW_ID and vim.env.TERM == "xterm-kitty", "measurement must run in actual local Kitty")
  require("image").setup({backend="kitty", processor="magick_cli", integrations={
    markdown={enabled=false}, asciidoc={enabled=false}, typst={enabled=false}, neorg={enabled=false}, syslang={enabled=false},
  }})
  mdview = require("mdview")
  mdview.setup({raw=true, smooth=true, factor=factor, clamp=84, zbelow=false, renderer=renderer})

  -- Wrappers observe the real worker and installed image.nvim backend; no fake image or terminal geometry.
  local chansend, jobstart = vim.fn.chansend, vim.fn.jobstart
  vim.fn.chansend = function(channel, data)
    if trace and type(data) == "string" and data:match("^DRAW ") then
      local fields = vim.split(data, " ", {trimempty=true})
      trace.draws[#trace.draws+1] = {time_ms=now(), phase=phase, revision=tonumber(fields[2]),
        sequence=tonumber(fields[3]), y=tonumber(fields[5]), height=tonumber(fields[7]),
        current_y=mdview.status().current_y, target_y=mdview.status().target_y}
    end
    return chansend(channel, data)
  end
  local latest_frame
  vim.fn.jobstart = function(command, opts)
    local worker = type(command) == "table" and command[1] == renderer
    if worker then
      local callback, pending = opts.on_stdout, ""
      opts.on_stdout = function(channel, chunks, event)
        pending = pending .. table.concat(chunks, "\n")
        local lines = vim.split(pending, "\n", {plain=true})
        pending = table.remove(lines)
        for _, line in ipairs(lines) do
          if line:match("^FRAME ") then
            local fields = vim.split(line, " ", {trimempty=true})
            latest_frame = {time_ms=now(), phase=phase, revision=tonumber(fields[2]), sequence=tonumber(fields[3]),
              y=tonumber(fields[6]), width=tonumber(fields[7]), height=tonumber(fields[8]), native_ms=tonumber(fields[9])}
            if trace then trace.frames[#trace.frames+1] = latest_frame end
          end
        end
        return callback(channel, chunks, event)
      end
    end
    if worker and renderer_cpu then command = {"taskset", "-c", tostring(renderer_cpu), renderer} end
    local job = jobstart(command, opts)
    if worker and renderer_cpu and job > 0 then
      local function affinity(pid)
        local status = table.concat(vim.fn.readfile("/proc/" .. pid .. "/status"), "\n")
        return assert(status:match("Cpus_allowed_list:%s*([^\n]+)"))
      end
      -- taskset execs the renderer in the same PID; wait until affinity is applied.
      local pid = vim.fn.jobpid(job)
      assert(vim.wait(1000, function() return affinity(pid) == tostring(renderer_cpu) end, 1),
        "renderer affinity was not applied")
      save("affinity.json", {nvim_pid=vim.fn.getpid(), nvim=affinity(vim.fn.getpid()),
        renderer_pid=pid, renderer=affinity(pid), kitty_pid=tonumber(vim.env.KITTY_PID),
        kitty=affinity(assert(tonumber(vim.env.KITTY_PID)))})
    end
    return job
  end
  local helpers = require("image/backends/kitty/helpers")
  local graphics, place = helpers.write_graphics, helpers.write_graphics_at
  local awaiting, last_transmission = {}, nil
  helpers.write_graphics = function(config, data, ...)
    if config.action ~= "t" or config.transmit_format ~= 32 then return graphics(config, data, ...) end
    assert(trace and latest_frame, "raw transmission without captured native frame")
    local measured = vim.tbl_extend("force", config, {quiet=0}) -- Request real Kitty load ACK, harness only.
    local s = assert(mdview.status())
    local transmission = {start_ms=now(), phase=phase, sequence=latest_frame.sequence, revision=latest_frame.revision,
      y=latest_frame.y, target_y_at_publication=s.target_y or s.current_y, image_id=config.image_id,
      width=config.transmit_width, height=config.transmit_height}
    trace.transmissions[#trace.transmissions+1] = transmission
    awaiting[#awaiting+1] = transmission
    last_transmission = transmission
    local result = graphics(measured, data, ...)
    transmission.write_return_ms = now()
    return result
  end
  helpers.write_graphics_at = function(config, ...)
    local result = place(config, ...)
    if config.action == "p" and last_transmission then
      last_transmission.publication_ms = now()
      last_transmission.target_y_at_publication = mdview.status().target_y or mdview.status().current_y
    end
    return result
  end
  api.nvim_create_autocmd("TermResponse", {callback=function(ev)
    local response = ev.data and ev.data.sequence or vim.v.termresponse
    local id, message = response:match("_G[^;]*i=(%d+)[^;]*;([^\27]+)")
    if not id then return end
    -- Same image id is reused by production; Kitty returns ordered load replies for this serial stream.
    for n, transmission in ipairs(awaiting) do
      if transmission.image_id == tonumber(id) then
        table.remove(awaiting, n)
        transmission.ack_ms, transmission.ack_message = now(), message
        if trace then trace.acks[#trace.acks+1] = {time_ms=transmission.ack_ms, sequence=transmission.sequence,
          image_id=tonumber(id), message=message} end
        return
      end
    end
  end})
  local function wait(predicate, label, timeout)
    assert(vim.wait(timeout or 15000, function()
      local s = mdview.status()
      assert(not (s and s.error), s and s.error)
      return predicate()
    end, 5), "timeout waiting for " .. label)
  end
  for _, scenario in ipairs({"5hz", "10hz", "30hz", "burst"}) do
    trace = {schema_version=1, scenario=scenario, factor=factor, clamp_pixels=84,
      draws={}, frames={}, transmissions={}, inputs={}, acks={}}
    phase, latest_frame, last_transmission = "positioning", nil, nil
    assert(#awaiting == 0, "previous scenario has outstanding Kitty ACKs")
    local source = api.nvim_get_current_buf()
    api.nvim_win_set_cursor(0, {math.floor(api.nvim_buf_line_count(source)/2), 0})
    mdview.open("replace")
    -- This driver stays inside a callback while vim.wait services async work.
    -- Flush the buffer swap now: otherwise Kitty can retain source text over z=-1 graphics.
    vim.cmd("redraw!")
    local s = assert(mdview.status(), "preview did not open")
    wait(function() return s.frame and not s.busy and #awaiting == 0 end, "initial native frame and actual Kitty ACK")
    vim.cmd("redraw")
    if scenario == "5hz" and vim.fn.executable("grim") == 1 then
      vim.wait(150, function() return false end, 10)
      local capture = vim.system({"grim", output .. "/surface.png"}, {text=true}):wait()
      save("surface-capture.json", {code=capture.code, stderr=capture.stderr})
      assert(capture.code == 0, "desktop screenshot failed: " .. capture.stderr)
    end
    assert(s.raw and s.smooth, "raw transport and smoothing are required, no PNG/headless fallback permitted")
    trace.viewport = {width=s.frame.width, height=s.frame.height,
      columns=api.nvim_win_get_width(s.preview_win), rows=api.nvim_win_get_height(s.preview_win),
      cell=require("image.utils.term").get_size()}
    trace.document_height, trace.max_y, trace.start_y = s.document_height, math.floor(s.document_height-s.height), s.frame.y
    local callbacks = {}
    for _, mapping in ipairs(api.nvim_buf_get_keymap(s.preview_buf, "n")) do
      if mapping.callback then callbacks[mapping.lhs] = mapping.callback end
    end
    for _, key in ipairs({"<Down>", "<Up>", "<ScrollWheelDown>", "<ScrollWheelUp>"}) do
      assert(callbacks[key], "missing installed mapping callback " .. key)
    end
    local count = scenario == "burst" and 400 or 20
    local period = scenario == "burst" and 20 or 1000/tonumber(scenario:match("%d+"))
    -- Largest excursion: 50 arrows + 50 default wheel steps (two/four cells respectively).
    local cell_h = trace.viewport.cell.cell_height
    assert(trace.start_y > 1000 and trace.max_y - trace.start_y > 300*cell_h + 1000,
      "fixture/start lacks headroom for the entire workload; boundary saturation would invalidate results")
    local revision = s.revision
    phase = "input"
    local input_start = now()
    for n=1,count do
      local deadline = input_start+(n-1)*period
      local delay = deadline-now()
      if delay > 0 then vim.wait(math.ceil(delay), function() return now() >= deadline end, 1) end
      local key = "<ScrollWheelDown>"
      if scenario == "burst" then
        local down = math.floor((n-1)/100)%2 == 0
        key = n%2 == 1 and (down and "<Down>" or "<Up>") or (down and "<ScrollWheelDown>" or "<ScrollWheelUp>")
      end
      local old = s.target_y or s.current_y
      local input = {index=n, key=key, scheduled_ms=deadline, time_ms=now(), old_target_y=old}
      callbacks[key]()
      input.target_y = s.target_y
      trace.inputs[#trace.inputs+1] = input
      assert(input.target_y ~= old and input.target_y > 0 and input.target_y < trace.max_y,
        "no-op or boundary-saturated input invalidates the sample")
      assert(s.revision == revision, "viewport changed during workload; keep the benchmark window fixed")
    end
    wait(function() return not s.busy and s.current_y == s.target_y and s.frame.y == s.target_y and #awaiting == 0 end,
      "final target publication and ACK", 10000)
    assert(s.revision == revision, "viewport changed during workload")
    trace.end_ms = now()
    for _, transmission in ipairs(trace.transmissions) do
      assert(transmission.ack_message == "OK", "missing/error real Kitty ACK: " .. tostring(transmission.ack_message))
    end
    save(scenario .. ".json", trace)
    phase = "closing"
    mdview.close()
    vim.cmd("redraw!")
    vim.wait(150, function() return s.exit_code ~= nil end, 5)
  end
  vim.fn.chansend, vim.fn.jobstart = chansend, jobstart
  helpers.write_graphics, helpers.write_graphics_at = graphics, place
  save("complete.json", {scenarios={"5hz", "10hz", "30hz", "burst"}, time_ms=now()})
  vim.cmd("qall!")
end
api.nvim_create_autocmd("VimEnter", {once=true, callback=function()
  vim.defer_fn(function()
    local ok, err = xpcall(run, debug.traceback)
    if not ok then fail(err) end
  end, 800)
end})
