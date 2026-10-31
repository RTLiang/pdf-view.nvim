--- SyncTeX queries and navigation. Coordinates are PDF points, measured from the top left.
local M = {}
local ns = vim.api.nvim_create_namespace("pdf-view-synctex")
local request = 0

local function notify(message)
  vim.notify("pdf-view: " .. message, vim.log.levels.WARN)
end

--- Parse complete result records; never combine fields from separate matches.
function M.parse(text, inverse)
  local results, record = {}, nil
  local function finish()
    if not record then
      return
    end
    if inverse and record.Input and record.Line and record.Line > 0 then
      results[#results + 1] = { file = record.Input, line = record.Line, column = math.max(0, record.Column or 0) }
    elseif not inverse and record.Page and record.Page > 0 and record.x and record.y then
      results[#results + 1] = { page = record.Page, x = record.x, y = record.y }
    end
  end
  for line in (text .. "\n"):gmatch("([^\r\n]*)[\r\n]+") do
    if line == "SyncTeX result begin" then
      record = {}
    elseif line == "SyncTeX result end" then
      finish()
      record = nil
    elseif record then
      local key, value = line:match("^([%a]+):(.*)$")
      if key == "Output" or key == "Input" then
        finish()
        record = { [key] = value }
      elseif key then
        record[key] = tonumber(value)
      end
    end
  end
  return results
end

--- Convert a displayed cell to a page point. Blank margins have no page point.
function M.cell_to_point(fit, geom, col, row)
  local x, y = col - fit.pad_left, row - fit.pad_top
  if x < 0 or y < 0 or x >= fit.cols or y >= fit.rows then
    return nil
  end
  if fit.scale then
    return ((x + 0.5) * fit.width / fit.cols + fit.x) / fit.scale,
      ((y + 0.5) * fit.height / fit.rows + fit.y) / fit.scale
  end
  return (x + 0.5) / fit.cols * geom.w, (y + 0.5) / fit.rows * geom.h
end

function M.point_to_cell(fit, geom, x, y)
  local col, row
  if fit.scale then
    col = (x * fit.scale - fit.x) / fit.width * fit.cols
    row = (y * fit.scale - fit.y) / fit.height * fit.rows
  else
    col, row = x / geom.w * fit.cols, y / geom.h * fit.rows
  end
  if col < 0 or row < 0 or col >= fit.cols or row >= fit.rows then
    return nil
  end
  return math.floor(col) + fit.pad_left, math.floor(row) + fit.pad_top
end

local function query(args, cwd, inverse, done)
  if vim.fn.executable("synctex") ~= 1 then
    return done("synctex executable not found; install a TeX distribution")
  end
  local ok, err = pcall(vim.system, args, { cwd = cwd, text = true, timeout = 10000 }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        return done("SyncTeX failed: " .. vim.trim(result.stderr or ""))
      end
      local hit = M.parse(result.stdout or "", inverse)[1]
      if not hit then
        return done("no SyncTeX match; compile with -synctex=1 first")
      end
      done(nil, hit)
    end)
  end)
  if not ok then
    done(tostring(err))
  end
end

--- Called after presenting an image; overlay one marker cell without changing its image id elsewhere.
function M.mark(s)
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  local hit, display = s.sync_hit, s.display
  if not hit or not display or display.page ~= hit.page then
    return
  end
  local col, row = M.point_to_cell(display.fit, display.geom, hit.x, hit.y)
  if not col then
    return
  end
  -- Placeholder cells contain combining marks: use virtual-column lookup, not character count.
  local byte = vim.api.nvim_buf_call(s.buf, function()
    return vim.fn.virtcol2col(s.win, row + 1, col + 1) - 1
  end)
  if byte < 0 then
    return
  end
  vim.api.nvim_set_hl(0, "PdfViewSync", { fg = "#ff8c1a", bold = true })
  vim.api.nvim_buf_set_extmark(s.buf, ns, row, byte, {
    virt_text = { { "▶", "PdfViewSync" } },
    virt_text_pos = "overlay",
    priority = 300,
  })
end

--- Forward search. With VimTeX, the PDF and build cwd come from its compiler state.
---@param opts? {pdf?: string, source?: string, line?: integer, column?: integer, root?: string}
function M.forward(opts)
  opts = opts or {}
  local source_win = vim.api.nvim_get_current_win()
  local source = vim.fn.fnamemodify(opts.source or vim.api.nvim_buf_get_name(0), ":p")
  local pos = vim.api.nvim_win_get_cursor(0)
  local state = vim.b.vimtex
  local pdf = opts.pdf
  if not pdf and state and state.compiler then
    local ok, path = pcall(vim.fn.eval, "b:vimtex.compiler.get_file('pdf')")
    if ok and path ~= "" then
      pdf = path
    end
  end
  pdf = vim.fn.fnamemodify(pdf or source:gsub("%.[^.]+$", ".pdf"), ":p")
  local root = opts.root or (state and state.root) or vim.fs.dirname(pdf)
  -- Neovim resolves /var to /private/var on macOS; TeX may have recorded the build cwd's spelling.
  local real_root = vim.uv.fs_realpath(root) or root
  local relative = vim.fs.relpath(real_root, vim.uv.fs_realpath(source) or source)
  if relative then
    source = vim.fs.joinpath(root, relative)
  end
  request = request + 1
  local token = request
  query(
    { "synctex", "view", "-i", ("%d:%d:%s"):format(opts.line or pos[1], opts.column or pos[2] + 1, source), "-o", pdf },
    root,
    false,
    function(err, hit)
      if token ~= request or not vim.api.nvim_win_is_valid(source_win) then
        return
      end
      if err then
        return notify(err)
      end
      pdf = vim.uv.fs_realpath(pdf) or pdf
      local viewer = require("pdf-view.viewer")
      local win
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local s = viewer.sessions[vim.api.nvim_win_get_buf(w)]
        if s and s.path == pdf then
          win = w
          break
        end
      end
      if not win then
        vim.api.nvim_win_call(source_win, function()
          vim.cmd("botright vsplit")
          win = vim.api.nvim_get_current_win()
        end)
      end
      vim.api.nvim_win_call(win, function()
        local buf = viewer.open(pdf)
        local s = viewer.sessions[buf]
        s.source_win, s.sync_root = source_win, root
        s.sync_hit, s.sync_pending = hit, hit
        s.target = hit.page
        require("pdf-view.render").show(s, hit.page)
      end)
    end
  )
end

--- Reverse search at a mouse cell, using the geometry of the image actually on screen.
function M.inverse(mouse)
  mouse = mouse or vim.fn.getmousepos()
  if not mouse.winid or not vim.api.nvim_win_is_valid(mouse.winid) then
    return
  end
  local s = require("pdf-view.session").sessions[vim.api.nvim_win_get_buf(mouse.winid)]
  local d = s and s.display
  if not d or not s.geom then
    return
  end
  local info = vim.fn.getwininfo(mouse.winid)[1]
  if not mouse.line or mouse.line < 1 or not mouse.wincol then
    return
  end
  local x, y = M.cell_to_point(d.fit, d.geom, mouse.wincol - info.textoff - 1, mouse.line - 1)
  if not x then
    return
  end
  local root = s.sync_root or vim.fs.dirname(s.path)
  s.inverse_request = (s.inverse_request or 0) + 1
  local token = s.inverse_request
  query({ "synctex", "edit", "-o", ("%d:%.6f:%.6f:%s"):format(d.page, x, y, s.path) }, root, true, function(err, hit)
    if s.closed or token ~= s.inverse_request then
      return
    end
    if err then
      return notify(err)
    end
    local absolute = hit.file:match("^/") or hit.file:match("^%a:[/\\]") or hit.file:match("^\\\\")
    local path = absolute and hit.file or vim.fs.joinpath(root, hit.file)
    if vim.fn.filereadable(path) ~= 1 then
      return notify("source file not found: " .. path)
    end
    local win = s.source_win
    if
      not win
      or not vim.api.nvim_win_is_valid(win)
      or require("pdf-view.session").sessions[vim.api.nvim_win_get_buf(win)]
    then
      win = nil
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not require("pdf-view.session").sessions[vim.api.nvim_win_get_buf(w)] then
          win = w
          break
        end
      end
    end
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("leftabove vsplit")
    end
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_win_set_buf(0, buf)
    local line = math.min(hit.line, vim.api.nvim_buf_line_count(buf))
    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    vim.api.nvim_win_set_cursor(0, { line, math.min(math.max(0, hit.column - 1), #text) })
    vim.cmd("normal! zz")
  end)
end

return M
