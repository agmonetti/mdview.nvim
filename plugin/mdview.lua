if vim.g.loaded_mdview then return end
vim.g.loaded_mdview = true
for command, action in pairs({ MdViewOpen="open", MdViewClose="close", MdViewToggle="toggle" }) do
  vim.api.nvim_create_user_command(command, function(opts)
    local arg = opts.args ~= "" and opts.args or nil
    require("mdview")[action](arg)
  end, {
    nargs = "?",
    complete = function() return { "replace", "split" } end,
    desc = "Markdown preview: " .. action,
  })
end
