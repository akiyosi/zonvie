-- Zonvie shader Tree-sitter layer.
--
-- The core runs this chunk with the `ZonvieTs*` names the loaded shaders
-- declared in `@zonvie-hl-groups:`. Each name is a marker highlight group
-- this chunk places from the buffer's Tree-sitter tree; a shader reads it as
-- one bit of a cell's group mask. A marker carries only a cterm colour, so it
-- gets an attribute id of its own and changes no pixel of an RGB UI.
-- An empty list tears the layer down.
--
-- Markers placed for every visible row (ephemeral, redrawn with the text):
--   ZonvieTsFn          cells of a function, from its line's indent rightward
--   ZonvieTsFnHead      a function's first line, from the function rightward
--   ZonvieTsFnName      the name in a function definition
--   ZonvieTsParam       a parameter name in a function definition
--   ZonvieTsExit        a return / break / continue / throw / goto statement
--   ZonvieTsError       an ERROR or MISSING node (the first line of one
--                       that spans several)
--   ZonvieTsDepthB0..2  nesting depth of the cell, as a 3-bit number (0..7):
--                       scope k of a row covers the cells from its header's
--                       indent rightward
-- Markers that follow the cursor of the current window (extmarks):
--   ZonvieTsFnCursor    cells of the innermost function holding the cursor
--   ZonvieTsScopeCursor cells of the innermost multi-line scope holding it
--   ZonvieTsArg1..6     parameter i of that function (cycling past 6), at its
--                       definition and at every use in the body
--   ZonvieTsRef         the identifier under the cursor, wherever that
--                       function names it
--   ZonvieTsCallCursor  the argument list holding the cursor
--   ZonvieTsCallArg     the argument holding the cursor
-- Markers on blank sign-column cells of a scope's or exit's first row:
--   ZonvieTsSignFn  ZonvieTsSignClass  ZonvieTsSignLoop  ZonvieTsSignBranch
--   ZonvieTsSignExit
local names = ...
local api, ts, fn = vim.api, vim.treesitter, vim.fn

local old = _G.zonvie_shader_ts
if old and old.teardown then pcall(old.teardown) end
local S = { bufs = {} }
_G.zonvie_shader_ts = S

local want = {}
for _, n in ipairs(names) do want[n] = true end
if next(want) == nil then return end

local ns_view = api.nvim_create_namespace('zonvie_shader_ts_view')
local ns_cur = api.nvim_create_namespace('zonvie_shader_ts_cursor')
local ns_sign = api.nvim_create_namespace('zonvie_shader_ts_sign')
local aug = api.nvim_create_augroup('ZonvieShaderTs', { clear = true })

local function words(s)
  local t = {}
  for w in s:gmatch('%S+') do t[w] = true end
  return t
end

-- Node types by role, across the common grammars.
local FN = words([[
  function_declaration function_definition function_item function_expression
  function_statement function local_function local_function_statement
  method_definition method_declaration method singleton_method
  constructor_declaration arrow_function func_literal lambda lambda_expression
  closure_expression anonymous_function generator_function
  generator_function_declaration
]])
local CLASS = words([[
  class_declaration class_definition class_specifier struct_specifier
  struct_item struct_declaration impl_item trait_item enum_item enum_specifier
  enum_declaration interface_declaration type_declaration class module
]])
local LOOP = words([[
  for_statement for_in_statement for_of_statement for_numeric_statement
  for_generic_statement for_expression for_range_loop foreach_statement
  while_statement while_expression repeat_statement do_statement
  do_while_statement loop_expression
]])
local BRANCH = words([[
  if_statement if_expression switch_statement switch_expression
  match_statement match_expression expression_switch_statement
  type_switch_statement select_statement try_statement try_expression
  with_statement unless
]])
local EXIT = words([[
  return_statement return_expression break_statement break_expression
  continue_statement continue_expression throw_statement raise_statement
  goto_statement
]])
local CALL = words([[
  call_expression function_call call method_invocation invocation_expression
  macro_invocation method_call new_expression
]])
local ARGS = words('arguments argument_list')
local IDENT = words('identifier variable_name simple_identifier')

local view_wanted = want.ZonvieTsFn or want.ZonvieTsFnHead or want.ZonvieTsFnName
  or want.ZonvieTsParam or want.ZonvieTsExit or want.ZonvieTsError
  or want.ZonvieTsDepthB0 or want.ZonvieTsDepthB1 or want.ZonvieTsDepthB2
local args_wanted = false
for i = 1, 6 do args_wanted = args_wanted or want['ZonvieTsArg' .. i] end
local cursor_wanted = want.ZonvieTsFnCursor or want.ZonvieTsScopeCursor or args_wanted
  or want.ZonvieTsRef or want.ZonvieTsCallCursor or want.ZonvieTsCallArg
local sign_wanted = want.ZonvieTsSignFn or want.ZonvieTsSignClass or want.ZonvieTsSignLoop
  or want.ZonvieTsSignBranch or want.ZonvieTsSignExit

-- A buffer past this many lines is left alone unless its tree is already
-- kept by the highlighter: a first parse of it would stall the redraw.
local max_unparsed_lines = 20000
-- Rows a cursor box is drawn for; a longer function keeps its head.
local max_box_rows = 4000
-- Signs are placed this many rows beyond the rows a window shows.
local sign_margin_rows = 200
-- Blanks that carry a segment from past a line's end to the window's right
-- edge; the window clips them.
local overlay_tail = string.rep(' ', 400)

local function define_markers()
  for n in pairs(want) do
    if n:sub(1, 8) == 'ZonvieTs' then api.nvim_set_hl(0, n, { ctermfg = 7 }) end
  end
end

--- 'Fn' | 'Class' | 'Loop' | 'Branch' for a scope node, else nil. An `if`
--- that is the else-branch of another continues that scope.
local function scope_kind(node)
  if not node:named() then return nil end
  local t = node:type()
  if FN[t] then return 'Fn' end
  if CLASS[t] then return 'Class' end
  if LOOP[t] then return 'Loop' end
  if BRANCH[t] then
    local p = node:parent()
    if p and (p:type() == t or p:type():find('else', 1, true)) then return nil end
    return 'Branch'
  end
  return nil
end

local function get_parser(buf)
  local ok, parser = pcall(ts.get_parser, buf, nil, { error = false })
  if not ok or not parser then return nil end
  if not ts.highlighter.active[buf] and api.nvim_buf_line_count(buf) > max_unparsed_lines then
    return nil
  end
  local st = S.bufs[buf]
  if not st then
    st = {}
    S.bufs[buf] = st
    -- Rows whose structure changed are redrawn so their markers follow.
    parser:register_cbs({
      on_changedtree = function(changes)
        if S.dead then return end
        for _, ch in ipairs(changes) do
          pcall(api.nvim__redraw, { buf = buf, range = { ch[1], ch[4] + 1 }, flush = false })
        end
      end,
      on_detach = function()
        S.bufs[buf] = nil
      end,
    }, true)
  end
  return parser, st
end

--- Lines of `buf` by row, fetched once each.
local function line_reader(buf)
  local cache = {}
  return function(row)
    local l = cache[row]
    if l == nil then
      l = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
      cache[row] = l
    end
    return l
  end
end

--- Byte length and display width of a line's leading whitespace.
local function indent_of(line)
  local ws = line:match('^%s*')
  if #ws == 0 then return 0, 0 end
  return #ws, fn.strdisplaywidth(ws)
end

--- Mark the cells of `row` by segment: `segs` is a list of { b, w, groups }
--- in ascending order, each covering the cells from byte column b (display
--- column w, inside the indent) up to the next segment, the last one to the
--- right edge of the window. Cells left of the first segment stay unmarked.
local function put_row(put, row, line, segs)
  local len = #line
  for i, s in ipairs(segs) do
    local nxt = segs[i + 1]
    local b0 = math.min(s.b, len)
    if nxt == nil then
      if s.b <= len then
        for _, g in ipairs(s.groups) do
          put(row, b0, { end_row = row + 1, end_col = 0, hl_group = g, hl_eol = true })
        end
      end
    else
      local b1 = math.min(nxt.b, len)
      if b1 > b0 then
        for _, g in ipairs(s.groups) do
          put(row, b0, { end_row = row, end_col = b1, hl_group = g })
        end
      end
    end
  end
  -- A segment that starts past the end of a short line: hl_eol would mark
  -- every cell from the line's end, so an overlay of blanks carries each
  -- segment's groups to its own cells instead. It combines, so the cells
  -- keep what other marks give them.
  local last = segs[#segs]
  if last.b > len then
    local at = fn.strdisplaywidth(line)
    local chunks, prev = {}, nil
    for _, s in ipairs(segs) do
      if s.w > at then
        chunks[#chunks + 1] = { string.rep(' ', s.w - at), prev }
        at = s.w
      end
      prev = #s.groups > 0 and s.groups or nil
    end
    chunks[#chunks + 1] = { overlay_tail, prev }
    put(row, len, { virt_text = chunks, virt_text_pos = 'overlay', hl_mode = 'combine' })
  end
end

local function depth_groups(depth)
  local d = math.min(depth, 7)
  local g = {}
  if d % 2 == 1 and want.ZonvieTsDepthB0 then g[#g + 1] = 'ZonvieTsDepthB0' end
  if math.floor(d / 2) % 2 == 1 and want.ZonvieTsDepthB1 then g[#g + 1] = 'ZonvieTsDepthB1' end
  if d >= 4 and want.ZonvieTsDepthB2 then g[#g + 1] = 'ZonvieTsDepthB2' end
  return g
end

--- The identifier a parameter node declares, or nil.
local function param_ident(n)
  for _ = 1, 8 do
    if IDENT[n:type()] then return n end
    local nx = n:field('name')[1] or n:field('pattern')[1] or n:field('declarator')[1]
    if not nx then
      for c in n:iter_children() do
        if c:named() and IDENT[c:type()] then return c end
      end
      return nil
    end
    n = nx
  end
  return nil
end

--- The identifiers of a function's parameters, in order.
local function params_of(func)
  local list = func:field('parameters')[1]
  if not list then
    local single = func:field('parameter')[1]
    if single then
      local id = param_ident(single)
      return id and { id } or {}
    end
    local d = func:field('declarator')[1]
    while d and not list do
      list = d:field('parameters')[1]
      d = d:field('declarator')[1]
    end
  end
  local out = {}
  if not list then return out end
  for c in list:iter_children() do
    if c:named() then
      local id = param_ident(c)
      if id then out[#out + 1] = id end
    end
  end
  return out
end

--- The node naming a function definition, or nil.
local function name_of(func)
  local n = func:field('name')[1]
  if n then return n end
  local d = func:field('declarator')[1]
  for _ = 1, 8 do
    if not d then return nil end
    if IDENT[d:type()] or d:type() == 'field_identifier' then return d end
    d = d:field('declarator')[1]
  end
  return nil
end

--- Whether an identifier names a member or a key rather than a variable.
local function is_member(n)
  local p = n:parent()
  if not p then return false end
  for _, f in ipairs({ 'field', 'attribute', 'property', 'key', 'method' }) do
    local c = p:field(f)[1]
    if c and c:equal(n) then return true end
  end
  local pt = p:type()
  if pt == 'field' or pt == 'keyword_argument' or pt == 'pair' then
    local c = p:field('name')[1]
    if c and c:equal(n) then return true end
  end
  return false
end

--- Whether the last row of a multi-line scope closes it (`end`, `}`) rather
--- than belonging to its body: it is indented no deeper than the first.
local function has_closer_row(line_of, sr, er)
  local _, w0 = indent_of(line_of(sr))
  local _, w1 = indent_of(line_of(er))
  return w1 <= w0
end

--- Markers for the rows top..bot (inclusive) of `buf`: a list of
--- { row, col, opts } for nvim_buf_set_extmark.
local function view_marks(buf, top, bot)
  local parser = get_parser(buf)
  if not parser then return {} end
  parser:parse({ top, bot + 1 })
  local line_of = line_reader(buf)
  local marks = {}
  local function put(row, col, opts)
    marks[#marks + 1] = { row, col, opts }
  end
  local function put_range(group, sr, sc, er, ec)
    put(sr, sc, { end_row = er, end_col = ec, hl_group = group })
  end
  local depth_wanted = want.ZonvieTsDepthB0 or want.ZonvieTsDepthB1 or want.ZonvieTsDepthB2
  local row_scopes = {} -- row -> scopes holding it in their body, outer first
  local fn_rows = {} -- row -> { b, w } of the outermost function box

  local function visit(node, sr, sc, er, ec)
    if want.ZonvieTsError and (node:missing() or node:type() == 'ERROR') then
      if er == sr and ec == sc then
        -- A MISSING node has no width: mark the cell before it.
        if sc > 0 then put_range('ZonvieTsError', sr, sc - 1, er, ec) end
      elseif er > sr then
        -- An ERROR node can swallow the rest of the buffer; where it
        -- starts is where to look.
        put_range('ZonvieTsError', sr, sc, sr, #line_of(sr))
      else
        put_range('ZonvieTsError', sr, sc, er, ec)
      end
    end
    if not node:named() then return end
    local kind = scope_kind(node)
    if kind then
      local ib, iw = indent_of(line_of(sr))
      if kind == 'Fn' then
        if want.ZonvieTsFnHead and sr >= top then
          put(sr, sc, { end_row = sr + 1, end_col = 0, hl_group = 'ZonvieTsFnHead', hl_eol = true })
        end
        if want.ZonvieTsFnName then
          local n = name_of(node)
          if n then put_range('ZonvieTsFnName', n:range()) end
        end
        if want.ZonvieTsParam then
          for _, id in ipairs(params_of(node)) do put_range('ZonvieTsParam', id:range()) end
        end
        if want.ZonvieTsFn then
          if er == sr then
            put_range('ZonvieTsFn', sr, sc, er, ec)
          else
            for r = math.max(sr, top), math.min(er, bot) do
              if not fn_rows[r] then fn_rows[r] = { b = ib, w = iw } end
            end
          end
        end
      end
      if depth_wanted and er > sr then
        local last = has_closer_row(line_of, sr, er) and er - 1 or er
        local scope = { b = ib, w = iw }
        for r = math.max(sr + 1, top), math.min(last, bot) do
          local l = row_scopes[r]
          if not l then
            l = {}
            row_scopes[r] = l
          end
          l[#l + 1] = scope
        end
      end
    elseif want.ZonvieTsExit and EXIT[node:type()] then
      put_range('ZonvieTsExit', sr, sc, er, ec)
    end
  end

  local function walk(node)
    for child in node:iter_children() do
      local sr, sc, er, ec = child:range()
      if er >= top and sr <= bot then
        visit(child, sr, sc, er, ec)
        if child:child_count() > 0 then walk(child) end
      end
    end
  end
  parser:for_each_tree(function(tree)
    walk(tree:root())
  end)

  for r, box in pairs(fn_rows) do
    put_row(put, r, line_of(r), { { b = box.b, w = box.w, groups = { 'ZonvieTsFn' } } })
  end
  for r, scopes in pairs(row_scopes) do
    local segs, b, w = {}, 0, 0
    for k, s in ipairs(scopes) do
      -- A scope indented less than the one around it starts where that one does.
      b, w = math.max(b, s.b), math.max(w, s.w)
      segs[k] = { b = b, w = w, groups = depth_groups(k) }
    end
    put_row(put, r, line_of(r), segs)
  end
  return marks
end
S.view_marks = view_marks

--- Markers that follow the cursor of `win`, a list like view_marks'.
local function cursor_marks(buf, win, st, parser)
  local pos = api.nvim_win_get_cursor(win)
  local row, col = pos[1] - 1, pos[2]
  parser:parse({ row, row + 1 })
  local node = parser:named_node_for_range({ row, col, row, col }, { ignore_injections = false })
  local marks = {}
  if not node then return marks end
  local line_of = line_reader(buf)
  local function put(r, c, opts)
    marks[#marks + 1] = { r, c, opts }
  end
  local function box(group, n)
    local sr, sc, er, ec = n:range()
    if er == sr then
      put(sr, sc, { end_row = er, end_col = ec, hl_group = group })
      return
    end
    local ib, iw = indent_of(line_of(sr))
    for r = sr, math.min(er, sr + max_box_rows) do
      put_row(put, r, line_of(r), { { b = ib, w = iw, groups = { group } } })
    end
  end

  local func, scope, call_args, call_arg
  local prev = nil
  local n = node
  while n do
    local t = n:type()
    if not call_args and prev and ARGS[t] then
      local p = n:parent()
      if p and CALL[p:type()] then
        call_args = n
        if prev:named() then call_arg = prev end
      end
    end
    local kind = scope_kind(n)
    if kind then
      local sr, _, er = n:range()
      if not scope and er > sr then scope = n end
      if kind == 'Fn' then
        func = n
        break
      end
    end
    prev = n
    n = n:parent()
  end

  if want.ZonvieTsCallCursor and call_args then
    local sr, sc, er, ec = call_args:range()
    put(sr, sc, { end_row = er, end_col = ec, hl_group = 'ZonvieTsCallCursor' })
  end
  if want.ZonvieTsCallArg and call_arg then
    local sr, sc, er, ec = call_arg:range()
    put(sr, sc, { end_row = er, end_col = ec, hl_group = 'ZonvieTsCallArg' })
  end
  if want.ZonvieTsScopeCursor and scope then box('ZonvieTsScopeCursor', scope) end
  if want.ZonvieTsFnCursor and func then box('ZonvieTsFnCursor', func) end

  local ref_name = nil
  if want.ZonvieTsRef and IDENT[node:type()] then
    ref_name = ts.get_node_text(node, buf)
  end
  if func and (args_wanted or ref_name) then
    -- The scan is kept while the function and the text stay the same.
    local fr, fc, er, ec = func:range()
    local key = table.concat({ fr, fc, er, ec, api.nvim_buf_get_changedtick(buf), ref_name or '' }, ':')
    if st.scan_key ~= key then
      st.scan_key = key
      local out = {}
      local index = {}
      if args_wanted then
        for i, id in ipairs(params_of(func)) do
          local g = 'ZonvieTsArg' .. ((i - 1) % 6 + 1)
          if want[g] then
            index[ts.get_node_text(id, buf)] = g
            local sr, sc, r2, c2 = id:range()
            out[#out + 1] = { sr, sc, { end_row = r2, end_col = c2, hl_group = g } }
          end
        end
      end
      local body = func:field('body')[1] or func
      local function scan(nd, shadow)
        for c in nd:iter_children() do
          if c:named() then
            local sh = shadow
            if FN[c:type()] then
              -- A nested function's own parameters hide the outer ones.
              for _, id in ipairs(params_of(c)) do
                local nm = ts.get_node_text(id, buf)
                if index[nm] then
                  if sh == shadow then sh = setmetatable({}, { __index = shadow }) end
                  sh[nm] = true
                end
              end
            end
            if IDENT[c:type()] and not is_member(c) then
              local nm = ts.get_node_text(c, buf)
              local sr, sc, r2, c2 = c:range()
              if index[nm] and not sh[nm] then
                out[#out + 1] = { sr, sc, { end_row = r2, end_col = c2, hl_group = index[nm] } }
              end
              if nm == ref_name then
                out[#out + 1] = { sr, sc, { end_row = r2, end_col = c2, hl_group = 'ZonvieTsRef' } }
              end
            elseif c:child_count() > 0 then
              scan(c, sh)
            end
          end
        end
      end
      scan(body, {})
      if ref_name and body ~= func then
        -- The header is outside the body: a parameter under the cursor is a use too.
        for _, id in ipairs(params_of(func)) do
          if ts.get_node_text(id, buf) == ref_name then
            local sr, sc, r2, c2 = id:range()
            out[#out + 1] = { sr, sc, { end_row = r2, end_col = c2, hl_group = 'ZonvieTsRef' } }
          end
        end
      end
      st.scan_marks = out
    end
    for _, m in ipairs(st.scan_marks) do marks[#marks + 1] = m end
  end
  return marks
end

local function marks_key(marks)
  local parts = {}
  for i, m in ipairs(marks) do
    local o = m[3]
    -- A cursor box's overlay is { gap, tail }: the gap's width tells two apart.
    parts[i] = table.concat({
      m[1], m[2], o.end_row or -1, o.end_col or -1, o.hl_group or '',
      o.virt_text and #o.virt_text[1][1] or 0,
    }, ',')
  end
  return table.concat(parts, ';')
end

local function update_cursor()
  if S.dead or not cursor_wanted then return end
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local parser, st = get_parser(buf)
  local marks = {}
  if parser then
    local ok, res = pcall(cursor_marks, buf, win, st, parser)
    if ok then marks = res end
  else
    st = S.bufs[buf] or {}
  end
  local key = marks_key(marks)
  if st.cursor_key == key then return end
  st.cursor_key = key
  api.nvim_buf_clear_namespace(buf, ns_cur, 0, -1)
  for _, m in ipairs(marks) do
    pcall(api.nvim_buf_set_extmark, buf, ns_cur, m[1], m[2], m[3])
  end
end
S.update_cursor = update_cursor

--- Row -> sign kind for the rows lo..hi: the outermost scope starting on a
--- row, or an exit statement on a row no scope starts on.
local function sign_rows(parser, lo, hi)
  parser:parse({ lo, hi + 1 })
  local rows = {}
  -- A statement sits at most two single-row nodes below a multi-row one
  -- (`if` > block > return), so the walk stops descending past that
  -- instead of visiting every expression.
  local function walk(node, single_rows_left)
    for child in node:iter_children() do
      local sr, _, er = child:range()
      if child:named() and er >= lo and sr <= hi then
        local kind = scope_kind(child)
        if kind and er > sr then
          if not rows[sr] and want['ZonvieTsSign' .. kind] then rows[sr] = kind end
        elseif EXIT[child:type()] and want.ZonvieTsSignExit then
          if not rows[sr] then rows[sr] = 'Exit' end
        end
        if er > sr then
          walk(child, 2)
        elseif single_rows_left > 0 then
          walk(child, single_rows_left - 1)
        end
      end
    end
  end
  for _, tree in ipairs(parser:trees()) do walk(tree:root(), 2) end
  return rows
end

--- Place the signs of the rows the buffer's windows have asked for (the
--- whole buffer when none has).
local function refresh_signs(buf)
  if S.dead or not api.nvim_buf_is_valid(buf) then return end
  local parser, st = get_parser(buf)
  if not parser then return end
  local lo, hi = st.sign_lo or 0, st.sign_hi or api.nvim_buf_line_count(buf)
  local ok, rows = pcall(sign_rows, parser, lo, hi)
  if not ok then return end
  local parts = {}
  for r, k in pairs(rows) do parts[#parts + 1] = r .. k end
  table.sort(parts)
  local key = table.concat(parts, ';')
  if st.sign_key == key then return end
  st.sign_key = key
  api.nvim_buf_clear_namespace(buf, ns_sign, 0, -1)
  for r, k in pairs(rows) do
    pcall(api.nvim_buf_set_extmark, buf, ns_sign, r, 0, {
      sign_text = '  ',
      sign_hl_group = 'ZonvieTsSign' .. k,
      priority = 1,
    })
  end
end
S.refresh_signs = refresh_signs

--- Signs cover the rows around the buffer's windows, and follow the text a
--- moment after it settles. A window scrolling out of the covered rows
--- widens them; an edit starts over from the window that shows it.
local function schedule_signs(buf, st, top, bot)
  local tick = api.nvim_buf_get_changedtick(buf)
  local edited = st.sign_tick ~= tick
  if not edited and st.sign_lo <= top and st.sign_hi >= bot then return end
  local lo, hi = math.max(top - sign_margin_rows, 0), bot + sign_margin_rows
  if not edited then lo, hi = math.min(lo, st.sign_lo), math.max(hi, st.sign_hi) end
  st.sign_tick, st.sign_lo, st.sign_hi = tick, lo, hi
  vim.defer_fn(function()
    if
      api.nvim_buf_is_valid(buf)
      and api.nvim_buf_get_changedtick(buf) == tick
      and st.sign_lo == lo
      and st.sign_hi == hi
    then
      refresh_signs(buf)
    end
  end, edited and 80 or 10)
end

local function on_win(_, _, buf, top, bot)
  if S.dead then return false end
  local parser, st = get_parser(buf)
  if not parser then return false end
  if sign_wanted then schedule_signs(buf, st, top, bot) end
  if not view_wanted then return false end
  local key = table.concat({ api.nvim_buf_get_changedtick(buf), top, bot }, ':')
  if st.view_key ~= key then
    local ok, marks = pcall(view_marks, buf, top, bot)
    if not ok then return false end
    for _, m in ipairs(marks) do m[3].ephemeral = true end
    st.view_key, st.view = key, marks
  end
  for _, m in ipairs(st.view) do
    pcall(api.nvim_buf_set_extmark, buf, ns_view, m[1], m[2], m[3])
  end
  return false
end

function S.teardown()
  S.dead = true
  pcall(api.nvim_set_decoration_provider, ns_view, {})
  pcall(api.nvim_del_augroup_by_id, aug)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) then
      api.nvim_buf_clear_namespace(b, ns_cur, 0, -1)
      api.nvim_buf_clear_namespace(b, ns_sign, 0, -1)
    end
  end
end

define_markers()
api.nvim_create_autocmd('ColorScheme', { group = aug, callback = define_markers })
if cursor_wanted then
  api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter', 'WinEnter' },
    { group = aug, callback = update_cursor }
  )
  update_cursor()
end
api.nvim_set_decoration_provider(ns_view, { on_win = on_win })
pcall(api.nvim__redraw, { valid = false })
