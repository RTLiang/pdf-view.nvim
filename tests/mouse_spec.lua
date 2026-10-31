local h = require("tests.harness")
local eq, wait = h.eq, h.wait_for
local fixture = require("tests.fixture")
local viewer = require("pdf-view.viewer")
local terminal = require("pdf-view.terminal")
local kitty = require("pdf-view.kitty")

if vim.fn.executable("mutool") ~= 1 then
  io.stdout:write("  skip  mouse (mutool not installed)\n")
  return
end

local dir = fixture.tmpdir()
local path = dir .. "/wheel.pdf"
fixture.write(path, { { w = 612, h = 792 }, { w = 612, h = 792 }, { w = 612, h = 792 } })

describe("PDF mouse wheel", function()
  it("scrolls the PDF under the pointer when the source split is focused", function()
    local old_ui, old_write = terminal.ui_attached, kitty.write
    terminal.ui_attached = function()
      return true
    end
    kitty.write = function() end
    vim.env.TMUX = nil
    vim.o.mouse = "a"
    local fallback_calls = 0
    vim.keymap.set("n", "<ScrollWheelUp>", function()
      fallback_calls = fallback_calls + 1
    end)
    require("pdf-view").setup({ force = true, cell_size = { 10, 20 }, live_reload = false })
    vim.cmd("silent! only")
    vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn["repeat"]({ "source line" }, 200))
    vim.bo.modified = false
    local source_win = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    local buf = viewer.open(path)
    local s = viewer.sessions[buf]
    wait(function()
      return s.display ~= nil and s.job == nil
    end, "first PDF render")
    local pdf_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(source_win)
    vim.cmd("redraw")
    local origin = vim.fn.win_screenpos(pdf_win)
    vim.api.nvim_input_mouse("move", "", "", 0, origin[1] + 2, origin[2] + 2)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true), "mx", false)
    wait(function()
      return s.page == 2 and s.job == nil
    end, "wheel down turns PDF page", 2000)
    eq(source_win, vim.api.nvim_get_current_win(), "wheel keeps source focus")
    vim.api.nvim_input_mouse("move", "", "", 0, origin[1] + 2, origin[2] + 2)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<ScrollWheelUp>", true, false, true), "mx", false)
    wait(function()
      return s.page == 1 and s.job == nil
    end, "wheel up turns PDF page", 2000)
    eq(source_win, vim.api.nvim_get_current_win())
    eq(0, fallback_calls, "PDF wheel does not invoke the original text mapping")

    -- While zoomed, wheel events pan within the page instead of immediately turning it.
    s.mode, s.zoom, s.cx, s.cy = "width", 3, 0, 0
    require("pdf-view.render").show(s)
    wait(function()
      return s.display.fit.scale ~= nil and s.job == nil
    end, "zoomed render")
    local start_y = s.cy
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true), "mx", false)
    wait(function()
      return s.cy > start_y and s.job == nil
    end, "vertical pan")
    eq(1, s.page)
    local start_x = s.cx
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<ScrollWheelRight>", true, false, true), "mx", false)
    wait(function()
      return s.cx > start_x and s.job == nil
    end, "horizontal pan")
    eq(source_win, vim.api.nvim_get_current_win())

    -- Away from a PDF, preserve user mappings and native source-buffer scrolling.
    local source_origin = vim.fn.win_screenpos(source_win)
    vim.api.nvim_input_mouse("move", "", "", 0, source_origin[1] + 2, source_origin[2] + 2)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<ScrollWheelUp>", true, false, true), "mx", false)
    eq(1, fallback_calls, "existing global wheel mapping preserved")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true), "mx", false)
    eq(true, vim.fn.getwininfo(source_win)[1].topline > 1, "native source scrolling preserved")
    vim.api.nvim_buf_delete(buf, { force = true })
    terminal.ui_attached, kitty.write = old_ui, old_write
  end)
end)
