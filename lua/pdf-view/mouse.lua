--- Wheel events are resolved in the focused buffer, even when the pointer is over another split.
--- Dispatch only events over a PDF; everywhere else keep the existing mapping or native scrolling.
local M = {}
local installed = false
local directions = {
  ScrollWheelDown = { 0, 1 },
  ScrollWheelUp = { 0, -1 },
  ScrollWheelRight = { 1, 0 },
  ScrollWheelLeft = { -1, 0 },
}

local function target()
  local mouse = vim.fn.getmousepos()
  if not mouse.winid or mouse.winid == 0 or not vim.api.nvim_win_is_valid(mouse.winid) then
    return
  end
  local s = require("pdf-view.session").sessions[vim.api.nvim_win_get_buf(mouse.winid)]
  if s and not s.closed then
    return s, mouse.winid
  end
end

function M.scroll(direction)
  local s, win = target()
  local delta = directions[direction]
  if not s or not delta then
    return
  end
  vim.api.nvim_win_call(win, function()
    require("pdf-view.actions").scroll(s, delta[1], delta[2])
  end)
end

function M.setup()
  if installed then
    return
  end
  installed = true
  for direction in pairs(directions) do
    local key = "<" .. direction .. ">"
    local fallback = key
    for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
      if map.lhs == key then
        fallback = "<Plug>(PdfViewFallback" .. direction .. ")"
        vim.keymap.set("n", fallback, map.callback or map.rhs, {
          expr = map.expr == 1,
          remap = map.noremap == 0,
          silent = map.silent == 1,
          nowait = map.nowait == 1,
          replace_keycodes = map.expr == 1,
        })
        break
      end
    end
    vim.keymap.set("n", key, function()
      if require("pdf-view.config").options.mouse_wheel and target() then
        return "<Cmd>lua require('pdf-view.mouse').scroll('" .. direction .. "')<CR>"
      end
      return fallback
    end, { expr = true, silent = true, desc = "PDF: scroll the viewer under the pointer" })
  end
end

return M
