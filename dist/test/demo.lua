-- A clean Neovim with the plugin from this checkout, replaying a synthetic
-- account. Nothing from the user's config loads, so recordings look the same
-- on every machine and before/after shots differ only by the code.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)
vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showcmd = false

local fixture = vim.env.WHATSAPP_FIXTURE
if not fixture or fixture == "" then
  fixture = root .. "/test/fixtures/synthetic.json"
end

require("whatsapp").setup({
  fixture = fixture,
  -- Recordings render text only, so pictures stay as tags.
  images = { mode = "tag" },
})
