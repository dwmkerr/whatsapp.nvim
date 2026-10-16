if vim.g.loaded_whatsapp then
  return
end
vim.g.loaded_whatsapp = true

local subcommands = {
  open = function() require("whatsapp").open() end,
  toggle = function() require("whatsapp").toggle() end,
  close = function() require("whatsapp").close() end,
  pair = function() require("whatsapp").pair() end,
  status = function() require("whatsapp").status() end,
  stop = function() require("whatsapp").stop() end,
  names = function() require("whatsapp").refresh_names() end,
}

vim.api.nvim_create_user_command("WhatsApp", function(cmd)
  local wa = require("whatsapp")
  if not require("whatsapp.state").opts then
    wa.setup()
  end
  local args = cmd.fargs
  if #args == 0 then
    return wa.open()
  end
  local sub = args[1]
  if subcommands[sub] then
    return subcommands[sub]()
  end
  -- Anything else is a chat name: :WhatsApp open Alice / :WhatsApp Alice
  if sub == "open" then
    table.remove(args, 1)
  end
  wa.open_by_name(table.concat(args, " "))
end, {
  nargs = "*",
  complete = function(lead)
    return vim.tbl_filter(function(s)
      return s:find(lead, 1, true) == 1
    end, vim.tbl_keys(subcommands))
  end,
  desc = "WhatsApp in Neovim",
})
