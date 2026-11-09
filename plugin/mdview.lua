if vim.g.loaded_mdview then return end
vim.g.loaded_mdview = true
local commands = {
  { "MdView", "toggle" },
  { "MdViewOpen", "open" },
  { "MdViewClose", "close" },
}
for _, entry in ipairs(commands) do
  local command, action = entry[1], entry[2]
  vim.api.nvim_create_user_command(command, function(opts)
    local arg = opts.args ~= "" and opts.args or nil
    require("mdview")[action](arg)
  end, {
    nargs = "?",
    complete = function() return { "replace", "split" } end,
    desc = "Markdown preview: " .. action,
  })
end
vim.api.nvim_create_user_command("MdViewToggleDetail", function()
  require("mdview").toggle_detail()
end, {desc="Toggle the innermost details block at the source cursor"})

if vim.g.mdview_default_keymaps ~= false and vim.g.mdview_no_mappings ~= 1 then
  if vim.fn.mapcheck("<leader>md", "n") == "" then
    vim.keymap.set("n", "<leader>md", "<cmd>MdView<cr>", { silent = true, desc = "Toggle Markdown preview" })
  end
end
