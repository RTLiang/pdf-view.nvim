local h = require("tests.harness")
local eq, near, truthy, wait = h.eq, h.near, h.truthy, h.wait_for
local sync = require("pdf-view.synctex")
local layout = require("pdf-view.layout")

describe("SyncTeX", function()
  it("keeps result records separate and preserves paths and reverse columns", function()
    local text =
      "SyncTeX result begin\nInput:./a b:中文.tex\nLine:17\nColumn:9\nInput:./other.tex\nLine:24\nColumn:-1\nSyncTeX result end\n"
    eq(
      { { file = "./a b:中文.tex", line = 17, column = 9 }, { file = "./other.tex", line = 24, column = 0 } },
      sync.parse(text, true)
    )
    eq(
      {},
      sync.parse("SyncTeX result begin\nOutput:x.pdf\nPage:1\nx:12\nOutput:y.pdf\ny:45\nSyncTeX result end", false)
    )
    eq(
      { { page = 2, x = 120.5, y = 500 } },
      sync.parse("SyncTeX result begin\nOutput:a b.pdf\nPage:2\nx:120.5\ny:500\nh:20\nSyncTeX result end", false)
    )
  end)

  it("round-trips cells through fitted, zoomed and panned coordinates", function()
    local geom = { w = 612, h = 792 }
    local fits = { layout.fit(612, 792, 120, 40, 10, 20, 1024) }
    for _, mode in ipairs({ "page", "width", "height" }) do
      fits[#fits + 1] = layout.viewport(612, 792, 120, 40, 10, 20, 2, 0.7, 0.8, mode)
    end
    for _, fit in ipairs(fits) do
      local col, row = fit.pad_left + math.floor(fit.cols / 2), fit.pad_top + math.floor(fit.rows / 2)
      local x, y = sync.cell_to_point(fit, geom, col, row)
      local c, r = sync.point_to_cell(fit, geom, x, y)
      eq({ col, row }, { c, r })
      eq(nil, sync.cell_to_point(fit, geom, fit.pad_left - 1, row))
      eq(nil, sync.cell_to_point(fit, geom, col, fit.pad_top + fit.rows))
    end
  end)
end)

if vim.fn.executable("pdflatex") ~= 1 or vim.fn.executable("synctex") ~= 1 or vim.fn.executable("mutool") ~= 1 then
  io.stdout:write("  skip  SyncTeX integration (requires pdflatex, synctex and mutool)\n")
  return
end

describe("SyncTeX real LaTeX integration", function()
  it("opens a split at the source position, marks it, and jumps back after zooming", function()
    local dir = require("tests.fixture").tmpdir() .. "/sync space 中文"
    vim.fn.mkdir(dir .. "/build", "p")
    local tex = dir .. "/main.tex"
    vim.fn.writefile({
      "\\documentclass{article}",
      "\\begin{document}",
      "First page text.",
      "\\newpage",
      "Second page text for source synchronization.",
      "\\end{document}",
    }, tex)
    local result = vim
      .system(
        { "pdflatex", "-synctex=1", "-interaction=nonstopmode", "-output-directory=build", "main.tex" },
        { cwd = dir, text = true }
      )
      :wait(30000)
    eq(0, result.code, result.stdout)
    local pdf = dir .. "/build/main.pdf"
    local raw = vim.system({ "synctex", "view", "-i", "5:1:" .. tex, "-o", pdf }, { cwd = dir, text = true }):wait()
    local hit = sync.parse(raw.stdout, false)[1]
    truthy(hit, raw.stdout)
    eq(2, hit.page)

    local terminal = require("pdf-view.terminal")
    local old_ui, old_write = terminal.ui_attached, require("pdf-view.kitty").write
    terminal.ui_attached = function()
      return true
    end
    require("pdf-view.kitty").write = function() end
    vim.env.TMUX = nil
    require("pdf-view").setup({ force = true, cell_size = { 10, 20 }, live_reload = false })
    vim.cmd("silent! only")
    vim.cmd.edit(vim.fn.fnameescape(tex))
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    sync.forward({ pdf = pdf, root = dir })
    local s
    wait(function()
      for _, v in pairs(require("pdf-view.session").sessions) do
        if v.path == vim.uv.fs_realpath(pdf) then
          s = v
          return v.page == 2 and v.display and v.job == nil
        end
      end
      return false
    end, "forward render", 10000)
    eq(source_win, vim.api.nvim_get_current_win(), "preserve source focus")
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    local marks = vim.api.nvim_buf_get_extmarks(s.buf, vim.api.nvim_create_namespace("pdf-view-synctex"), 0, -1, {})
    eq(1, #marks, "visible marker")
    near(hit.x, s.sync_hit.x, 0.01)

    -- Same-page forward search must pan even when it is already open.
    s.zoom, s.mode = 3, "width"
    sync.forward({ pdf = pdf, root = dir })
    wait(function()
      return s.display.fit.scale ~= nil and s.job == nil
    end, "zoomed sync")
    local col, row = sync.point_to_cell(s.display.fit, s.display.geom, hit.x, hit.y)
    truthy(col, "target is visible when zoomed")
    local info = vim.fn.getwininfo(s.win)[1]
    vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
    sync.inverse({ winid = s.win, wincol = col + info.textoff + 1, line = row + 1 })
    wait(function()
      return vim.api.nvim_win_get_cursor(source_win)[1] == 5 and vim.api.nvim_get_current_win() == source_win
    end, "inverse search")
    -- Also query exact coordinates; terminal cells naturally reduce mouse precision.
    local inv = vim
      .system({ "synctex", "edit", "-o", ("2:%f:%f:%s"):format(hit.x, hit.y, pdf) }, { cwd = dir, text = true })
      :wait()
    eq(5, sync.parse(inv.stdout, true)[1].line)
    vim.api.nvim_buf_delete(s.buf, { force = true })
    terminal.ui_attached, require("pdf-view.kitty").write = old_ui, old_write
  end)
end)
