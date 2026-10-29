-- Driven by test/gui/scenarios/visual/per_grid_font_workflow.zig. Each phase
-- is one call, so the scenario chooses where it waits for the app.
PGF = {}

local text = {
  "fn main() -> Result<(), Error> { a != b && c == d || e >= f }",
  "x => y === z !== w <= v :: u |> t <| s <!-- r --> q ... p",
  "while (i <= n) { i += 1; j -= 1; k *= 2; } // www ### ;;",
}

local function fill(buf, n, tag)
  local lines = {}
  for i = 1, n do
    lines[i] = string.format("%s%03d %s", tag, i, text[(i % #text) + 1])
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

function PGF.setup()
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.ruler = false
  vim.o.showcmd = false
  vim.o.swapfile = false
  vim.o.number = true
  fill(0, 300, "")
  return 1
end

function PGF.splits()
  vim.cmd("vsplit")
  vim.cmd("vsplit")
  vim.cmd("3wincmd w")
  vim.cmd("split")
  local w = vim.api.nvim_tabpage_list_wins(0)
  PGF.w = w
  zonvie.set_window_font(w[1], { guifont = "Fira Code:h15" })
  zonvie.set_window_font(w[2], { guifont = "JetBrains Mono:h10" })
  zonvie.set_window_font(w[3], { scale = 0.7 })
  zonvie.set_window_font(w[4], { guifont = "Iosevka:h16", scale = 0.8 })
  vim.api.nvim_set_current_win(w[1])
  return #w
end

-- Every size change in one RPC call: Neovim answers the app's earlier
-- requests while the layout keeps moving underneath them.
function PGF.resize_burst()
  local w = PGF.w
  for i = 1, 6 do
    vim.api.nvim_win_set_width(w[1], 20 + i * 4)
    vim.api.nvim_win_set_width(w[2], 40 - i * 3)
    vim.api.nvim_win_set_height(w[4], 5 + i * 2)
    vim.cmd("redraw")
  end
  vim.cmd("wincmd =")
  return 1
end

function PGF.resize_step(i)
  local w = PGF.w
  -- Heights only on the stacked pair: shrinking a full-height window grows
  -- the command line instead.
  if i % 2 == 0 then
    vim.api.nvim_win_set_width(w[(i % 4) + 1], 18 + (i * 7) % 30)
  else
    vim.api.nvim_win_set_height(w[3 + (math.floor(i / 2) % 2)], 6 + (i * 5) % 20)
  end
  return 1
end

local function float(row, col, width, height, tag)
  local b = vim.api.nvim_create_buf(false, true)
  fill(b, 120, tag)
  return vim.api.nvim_open_win(b, false, {
    relative = "editor", row = row, col = col, width = width, height = height,
    border = "single", zindex = 50,
  })
end

function PGF.floats()
  local f1 = float(2, 6, 40, 10, "F")
  local f2 = float(6, 30, 36, 8, "G")
  local f3 = float(12, 14, 44, 9, "H")
  zonvie.set_window_font(f1, { guifont = "Fira Code:h18" })
  zonvie.set_window_font(f2, { scale = 0.6 })
  vim.w[f3].neovide_font_scale = 0.5
  zonvie.set_window_font(f3, {})
  PGF.f = { f1, f2, f3 }
  return 3
end

function PGF.float_step(i)
  for k, f in ipairs(PGF.f) do
    local d = (i + k) % 5
    vim.api.nvim_win_set_config(f, {
      relative = "editor",
      row = 2 + k * 3 + d,
      col = 4 + k * 10 + d * 2,
      width = 24 + ((i * 3 + k * 7) % 20),
      height = 5 + ((i + k) % 7),
    })
  end
  return 1
end

function PGF.float_scroll()
  for _, f in ipairs(PGF.f) do
    vim.api.nvim_win_call(f, function() vim.cmd("normal! 40Gzt") end)
  end
  return 1
end

function PGF.font_churn(i)
  local w1 = PGF.w[1]
  local specs = {
    { guifont = "Fira Code:h9" },
    { guifont = "Fira Code:h15" },
    { scale = 1.4 },
    { guifont = "JetBrains Mono:h12" },
  }
  zonvie.set_window_font(w1, specs[(i % #specs) + 1])
  return 1
end

-- Close a font window and open a new one in its place with another font.
function PGF.close_reopen()
  vim.api.nvim_win_close(PGF.w[2], true)
  vim.api.nvim_set_current_win(PGF.w[1])
  vim.cmd("vsplit")
  PGF.w[2] = vim.api.nvim_get_current_win()
  zonvie.set_window_font(PGF.w[2], { guifont = "Iosevka:h12" })
  vim.cmd("normal! 120Gzz")
  return 1
end

function PGF.tab_roundtrip()
  vim.cmd("tabnew")
  vim.cmd("vsplit")
  zonvie.set_window_font(0, { guifont = "Fira Code:h14" })
  vim.cmd("redraw")
  vim.cmd("tabprevious")
  return 1
end

function PGF.check_layout()
  local bad = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_width(w) <= 0 or vim.api.nvim_win_get_height(w) <= 0 then
      bad = bad + 1
    end
  end
  return bad
end
