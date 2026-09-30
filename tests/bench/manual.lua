-- Use the user's normal configuration/dependencies, but this checkout's controller.
vim.opt.runtimepath:prepend(vim.env.MDVIEW_MANUAL_ROOT)
package.loaded["mdview"] = nil
local variant = vim.env.MDVIEW_MANUAL_VARIANT
local opts = { raw=false, smooth=false, zbelow=false, clamp=false }
if variant == "fluid" then
  opts = { preset="fluid", zbelow=false }
elseif variant == "layers" then
  -- Exercise the environment switch independently of the fluid preset.
  opts = { smooth=false, clamp=false }
end
require("mdview").setup(opts)
require("mdview").open("replace")
