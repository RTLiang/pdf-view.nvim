-- Optional smoke test: VIMTEX_DIR=/path/to/vimtex nvim --headless -u NONE -i NONE -l tests/vimtex_integration.lua
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(assert(vim.env.VIMTEX_DIR, "set VIMTEX_DIR to a VimTeX checkout"))
vim.g.tex_flavor = "latex"
vim.g.vimtex_view_method = "pdf_view"
vim.g.vimtex_view_automatic = 1
vim.g.vimtex_compiler_latexmk = { out_dir = "build" }
vim.cmd("filetype plugin indent on")
vim.cmd("runtime plugin/pdf-view.lua")
vim.cmd("runtime plugin/vimtex.vim")

local dir = vim.fn.tempname() .. " vimtex integration 中文"
vim.fn.mkdir(dir .. "/build", "p")
vim.fn.writefile({
  "\\documentclass{article}",
  "\\begin{document}",
  "First page.",
  "\\newpage",
  "\\input{chapter}",
  "\\end{document}",
}, dir .. "/main.tex")
vim.fn.writefile({ "% !TeX root = main.tex", "Second page from included source." }, dir .. "/chapter.tex")
require("pdf-view").setup({ force = true, cell_size = { 10, 20 } })
require("pdf-view.terminal").ui_attached = function()
  return true
end
require("pdf-view.kitty").write = function() end
vim.cmd.edit(vim.fn.fnameescape(dir .. "/chapter.tex"))
assert(vim.b.vimtex, "VimTeX not initialized")
assert(vim.b.vimtex.viewer.name == "pdf-view.nvim", "wrong viewer")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local source_win = vim.api.nvim_get_current_win()
local success = false
vim.api.nvim_create_autocmd("User", {
  pattern = "VimtexEventCompileSuccess",
  callback = function()
    success = true
  end,
})
vim.cmd("VimtexCompileSS")
assert(
  vim.wait(45000, function()
    return success
  end, 100),
  "compilation callback timed out"
)
local s
assert(
  vim.wait(10000, function()
    for _, v in pairs(require("pdf-view.session").sessions) do
      if v.path:match("main.pdf$") then
        s = v
        return v.page == 2 and v.display and v.job == nil
      end
    end
  end, 50),
  "automatic callback did not open page 2"
)
assert(vim.api.nvim_get_current_win() == source_win, "source focus changed")
print("VimTeX compile callback: included source -> build/main.pdf page 2 OK")
vim.cmd("VimtexView")
assert(vim.wait(5000, function()
  return s.job == nil and s.sync_pending == nil
end, 50))
assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "duplicate PDF split")
local col, row = require("pdf-view.synctex").point_to_cell(s.display.fit, s.display.geom, s.sync_hit.x, s.sync_hit.y)
assert(col, "target marker not visible")
vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
require("pdf-view").inverse({ winid = s.win, wincol = col + 1, line = row + 1 })
assert(
  vim.wait(5000, function()
    return vim.api.nvim_win_get_cursor(source_win)[1] == 2
  end, 50),
  "inverse search failed"
)
assert(vim.api.nvim_buf_get_name(0):match("chapter.tex$"), "wrong source file")
print("VimTeX :VimtexView and inverse search -> chapter.tex line 2 OK")
vim.cmd("qa!")
