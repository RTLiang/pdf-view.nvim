local config = require("pdf-view.config")

local M = {}

local group = vim.api.nvim_create_augroup("PdfView", { clear = true })

--- Own `*.pdf` reads when `auto_open` is on. Re-run after the configuration changes.
local function sync_handler()
  vim.api.nvim_clear_autocmds({ group = group, event = "BufReadCmd" })
  if not config.options.auto_open then
    return
  end
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = { "*.pdf", "*.PDF" },
    desc = "Open PDF files in pdf-view",
    callback = function(args)
      require("pdf-view.viewer").read(args.buf)
    end,
  })
end

--- Configure the plugin. Optional: the defaults are used when this is never called.
---@param opts? table see `PdfView.Config` in lua/pdf-view/config.lua
function M.setup(opts)
  config.setup(opts)
  sync_handler()
  return M
end

--- Open a PDF in the current window.
---@param path string
function M.open(path)
  return require("pdf-view.viewer").open(path)
end

--- Re-render the page shown in `buf` (default: the current buffer).
---@param buf? integer
function M.reload(buf)
  local s = require("pdf-view.viewer").sessions[buf or vim.api.nvim_get_current_buf()]
  if s then
    require("pdf-view.viewer").reload(s)
  end
end

--- "page / pages" for the viewer in `buf`, e.g. for a statusline component. Empty for other buffers.
---@param buf? integer
---@return string
function M.status(buf)
  local viewer = package.loaded["pdf-view.viewer"]
  return viewer and viewer.status(buf) or ""
end

--- SyncTeX forward search from the current source into a PDF split.
function M.forward(opts)
  return require("pdf-view.synctex").forward(opts)
end

--- SyncTeX reverse search at a mouse position (defaults to getmousepos()).
function M.inverse(mouse)
  return require("pdf-view.synctex").inverse(mouse)
end

--- Zoom the current PDF, or the sole visible PDF in this tab, without changing source focus.
---@param value number|"+"|"-"|"reset" percentage or relative step
---@param buf? integer explicit viewer buffer
function M.zoom(value, buf)
  local sessions = require("pdf-view.session").sessions
  local s = sessions[buf or vim.api.nvim_get_current_buf()]
  if not s and not buf then
    local seen = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local candidate = sessions[vim.api.nvim_win_get_buf(win)]
      if candidate then
        seen[candidate.buf] = candidate
      end
    end
    local candidates = vim.tbl_values(seen)
    if #candidates == 1 then
      s = candidates[1]
    end
    if #candidates > 1 then
      error("pdf-view: focus the PDF to zoom; multiple previews are visible", 0)
    end
  end
  if not s then
    error("pdf-view: open a PDF preview with :VimtexView or :PdfView first", 0)
  end
  require("pdf-view.actions").zoom(s, value)
end

--- Called by plugin/pdf-view.lua: register the command and the default handler.
function M._init()
  vim.api.nvim_create_user_command("PdfZoom", function(args)
    local ok, err = pcall(M.zoom, args.args ~= "" and args.args or "+")
    if not ok then
      vim.notify(tostring(err), vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    desc = "Zoom a PDF (percentage, +, -, reset)",
    complete = function()
      return { "+", "-", "100", "125", "150", "200", "reset" }
    end,
  })
  vim.api.nvim_create_user_command("PdfForward", function(args)
    M.forward({ pdf = args.args ~= "" and args.args or nil })
  end, { nargs = "?", complete = "file", desc = "SyncTeX: locate source in a PDF split" })
  vim.api.nvim_create_user_command("PdfInverse", function()
    M.inverse()
  end, { desc = "SyncTeX: locate PDF mouse position in source" })
  vim.api.nvim_create_user_command("PdfView", function(args)
    local path = args.fargs[1]
    if not path then
      path = vim.api.nvim_buf_get_name(0)
      if not path:lower():match("%.pdf$") then
        return vim.notify("pdf-view: usage: :PdfView {file.pdf}", vim.log.levels.ERROR)
      end
    end
    local ok, err = pcall(M.open, path)
    if not ok then
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end, { nargs = "?", complete = "file", desc = "Open a PDF in the current window" })
  sync_handler()
end

return M
