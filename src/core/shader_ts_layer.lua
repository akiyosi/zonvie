-- Zonvie shader Tree-sitter layer.
--
-- The core runs this chunk with the `ZonvieTs*` names the loaded shaders
-- declared in `@zonvie-hl-groups:`. Each name is a marker highlight group
-- this chunk places from the buffer's Tree-sitter tree; a shader reads it as
-- one bit of a cell's group mask. A marker carries only a cterm colour, so it
-- gets an attribute id of its own and changes no pixel of an RGB UI.
-- An empty list tears the layer down.
--
-- What a cell carries does not depend on the cursor. The markers are
-- extmarks placed once and kept in step with edits (after the edit itself
-- is on screen), so a redraw runs no Lua and a cursor move resends no
-- cell. What does depend on the cursor is three numbers, sent to the core
-- as the `zonvie_ts_cursor` notification and handed to shaders as the
-- uniforms iTsCursorFn, iTsCursorScope and iTsCursorNested: the ids of the
-- function and of the scope holding the cursor, and of the functions
-- nested in that function. A shader compares them with the ids on its
-- cells.
--
-- Markers on the cells of scopes (functions, classes, loops, branches that
-- span several lines). A scope covers its rows from its first line's
-- indent to the window's right edge; where scopes nest, a cell belongs to
-- the innermost one.
--   ZonvieTsScopeB0..5  id of the cell's scope, a 6-bit number (0 = none);
--                       scopes near each other have different ids
--   ZonvieTsFnB0..5     id of the function the cell is in (0 = none)
--   ZonvieTsDepthB0..2  nesting depth of the cell, 0..7; a scope's first and
--                       closing rows count for the scope around it
-- Markers on tokens and rows:
--   ZonvieTsFnHead      a function's first line, from the function rightward
--   ZonvieTsFnName      the name in a function definition
--   ZonvieTsParam       a parameter name in a function definition
--   ZonvieTsParamB0..2  on a parameter's name, declared or used in its own
--                       function's body: its position, 1..7 (cycling)
--   ZonvieTsExit        a return / break / continue / throw / goto statement
--   ZonvieTsError       an ERROR or MISSING node (the first line of one
--                       that spans several)
--   ZonvieTsErrorRow    one blank cell at the window's right edge, on each
--                       row that has such a node
--   ZonvieTsErrorLine   every cell of such a row, to the window's right edge
--   ZonvieTsSignFn  ZonvieTsSignClass  ZonvieTsSignLoop  ZonvieTsSignBranch
--   ZonvieTsSignExit    blank sign-column cells on a scope's or exit's row
-- Markers that follow the cursor (a few cells each):
--   ZonvieTsCursorBuf   every cell of the buffer the cursor is in: ids are
--                       per buffer, so this tells which buffer the two
--                       cursor ids speak of
--   ZonvieTsRef         the identifier under the cursor, wherever its
--                       function names it
--   ZonvieTsCallCursor  the argument list holding the cursor
--   ZonvieTsCallArg     the argument holding the cursor
local names = ...
local api, ts, fn = vim.api, vim.treesitter, vim.fn

local old = _G.zonvie_shader_ts
if old and old.teardown then pcall(old.teardown) end
local S = { bufs = {} }
_G.zonvie_shader_ts = S

local want = {}
for _, n in ipairs(names) do want[n] = true end
if next(want) == nil then return end

local ns_static = api.nvim_create_namespace('zonvie_shader_ts_static')
local ns_anchor = api.nvim_create_namespace('zonvie_shader_ts_anchor')
local ns_cur = api.nvim_create_namespace('zonvie_shader_ts_cursor')
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
  for_generic_statement for_expression for_range_loop for_loop
  foreach_statement while_statement while_expression while_loop
  repeat_statement do_statement do_while_statement loop_expression
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

--- The wanted groups for the set bits of a number, lowest bit first.
local function bit_field(prefix, nbits)
  local cache = {}
  return function(value)
    local g = cache[value]
    if not g then
      g = {}
      local v = value
      for i = 0, nbits - 1 do
        local name = prefix .. i
        if v % 2 == 1 and want[name] then g[#g + 1] = name end
        v = math.floor(v / 2)
      end
      cache[value] = g
    end
    return g
  end
end
local scope_bits = bit_field('ZonvieTsScopeB', 6)
local fn_bits = bit_field('ZonvieTsFnB', 6)
local depth_bits = bit_field('ZonvieTsDepthB', 3)
local param_bits = bit_field('ZonvieTsParamB', 3)

local function any_wanted(prefix, nbits)
  for i = 0, nbits - 1 do
    if want[prefix .. i] then return true end
  end
  return false
end
local region_wanted = any_wanted('ZonvieTsScopeB', 6) or any_wanted('ZonvieTsFnB', 6)
  or any_wanted('ZonvieTsDepthB', 3)
local param_index_wanted = any_wanted('ZonvieTsParamB', 3)
local error_wanted = want.ZonvieTsError or want.ZonvieTsErrorRow or want.ZonvieTsErrorLine
local cursor_tokens_wanted = want.ZonvieTsRef or want.ZonvieTsCallCursor or want.ZonvieTsCallArg

-- Ids are 1..63 and handed out in turn, so scopes near each other differ.
local max_id = 63
-- A scope taking a fresh id avoids those in use within this many rows.
local avoid_rows = 400
-- A buffer past this many lines is left alone unless its tree is already
-- kept by the highlighter: a first parse of it would stall the editor.
local max_unparsed_lines = 20000
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
  if FN[t] then
    -- A function's signature can be a node of a function type itself
    -- (Vim script: function_definition > function_declaration).
    local p = node:parent()
    if p and FN[p:type()] and #node:field('body') == 0 then return nil end
    return 'Fn'
  end
  if CLASS[t] then return 'Class' end
  if LOOP[t] then return 'Loop' end
  if BRANCH[t] then
    local p = node:parent()
    if p and (p:type() == t or p:type():find('else', 1, true)) then return nil end
    return 'Branch'
  end
  return nil
end

--- Byte length and display width of a line's leading whitespace.
local function indent_of(line)
  local ws = line:match('^%s*')
  if #ws == 0 then return 0, 0 end
  return #ws, fn.strdisplaywidth(ws)
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

--- The node holding a function's name and parameters: the function, or
--- its signature child where the grammar has one.
local function signature_of(func)
  for _, f in ipairs({ 'parameters', 'parameter', 'name', 'declarator' }) do
    if #func:field(f) > 0 then return func end
  end
  for c in func:iter_children() do
    if c:named() and FN[c:type()] and #c:field('body') == 0 then return c end
  end
  return func
end

--- The identifiers of a function's parameters, in order.
local function params_of(func)
  func = signature_of(func)
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
  func = signature_of(func)
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

local function get_parser(buf)
  local ok, parser = pcall(ts.get_parser, buf, nil, { error = false })
  if not ok or not parser then return nil end
  if not ts.highlighter.active[buf] and api.nvim_buf_line_count(buf) > max_unparsed_lines then
    return nil
  end
  return parser
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

--- Mark the cells of `row` by segment: `segs` is a list of { b, w, groups }
--- in ascending order, each covering the cells from byte column b (display
--- column w, inside the indent) up to the next segment, the last one to the
--- right edge of the window. Cells left of the first segment stay unmarked.
local function put_row(put, row, line, segs)
  local len = #line
  for i, s in ipairs(segs) do
    if #s.groups > 0 then
      local nxt = segs[i + 1]
      local b0 = math.min(s.b, len)
      if nxt == nil then
        if s.b <= len then
          put(row, b0, { end_row = row + 1, end_col = 0, hl_group = s.groups, hl_eol = true })
        end
      else
        local b1 = math.min(nxt.b, len)
        if b1 > b0 then put(row, b0, { end_row = row, end_col = b1, hl_group = s.groups }) end
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

--- The marks of one top-level node and the scopes it holds. `ids(sr, sc,
--- is_fn)` gives the ids of the scope starting there: scope id, and the
--- function's own id when it is one.
local function block_marks(buf, node, line_of, ids)
  local marks, scopes = {}, {}
  local function put(row, col, opts)
    marks[#marks + 1] = { row, col, opts }
  end
  local function put_range(group, sr, sc, er, ec)
    put(sr, sc, { end_row = er, end_col = ec, hl_group = group })
  end
  local error_rows = {}
  local sign_rows = {}

  -- ctx: the parameter positions of the innermost function, by name.
  local function visit(n, parent, ctx)
    local sr, sc, er, ec = n:range()
    if error_wanted and (n:missing() or n:type() == 'ERROR') then
      if want.ZonvieTsError then
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
      if not error_rows[sr] then
        error_rows[sr] = true
        if want.ZonvieTsErrorRow then
          put(sr, 0, { virt_text = { { ' ', 'ZonvieTsErrorRow' } }, virt_text_pos = 'right_align' })
        end
        if want.ZonvieTsErrorLine then
          put(sr, 0, { end_row = sr + 1, end_col = 0, hl_group = 'ZonvieTsErrorLine', hl_eol = true })
        end
      end
    end
    if not n:named() then return end
    local scope = parent
    local kind = scope_kind(n)
    if kind then
      if kind == 'Fn' then
        if want.ZonvieTsFnHead then
          put(sr, sc, { end_row = sr + 1, end_col = 0, hl_group = 'ZonvieTsFnHead', hl_eol = true })
        end
        if want.ZonvieTsFnName then
          local nm = name_of(n)
          if nm then put_range('ZonvieTsFnName', nm:range()) end
        end
        if want.ZonvieTsParam or param_index_wanted then
          ctx = { index = {} }
          for i, id in ipairs(params_of(n)) do
            if want.ZonvieTsParam then put_range('ZonvieTsParam', id:range()) end
            ctx.index[ts.get_node_text(id, buf)] = (i - 1) % 7 + 1
          end
        end
      end
      if er > sr then
        if want['ZonvieTsSign' .. kind] and not sign_rows[sr] then
          sign_rows[sr] = true
          put(sr, 0, { sign_text = '  ', sign_hl_group = 'ZonvieTsSign' .. kind, priority = 1 })
        end
        local ib, iw = indent_of(line_of(sr))
        local _, w_end = indent_of(line_of(er))
        local scope_id, own_fn = ids(sr, sc, kind == 'Fn')
        scope = {
          sr = sr, sc = sc, er = er, b = ib, w = iw,
          -- The last row closes the scope (`end`, `}`) when it is indented
          -- no deeper than the first; otherwise it is body.
          body_last = (w_end <= iw) and er - 1 or er,
          id = scope_id,
          fn = own_fn or (parent and parent.fn) or 0,
        }
        scopes[#scopes + 1] = scope
      end
    elseif EXIT[n:type()] then
      if want.ZonvieTsExit then put_range('ZonvieTsExit', sr, sc, er, ec) end
      if want.ZonvieTsSignExit and not sign_rows[sr] then
        sign_rows[sr] = true
        put(sr, 0, { sign_text = '  ', sign_hl_group = 'ZonvieTsSignExit', priority = 1 })
      end
    elseif param_index_wanted and ctx and IDENT[n:type()] then
      local pos = ctx.index[ts.get_node_text(n, buf)]
      if pos and not is_member(n) then
        local g = param_bits(pos)
        if #g > 0 then put(sr, sc, { end_row = er, end_col = ec, hl_group = g }) end
      end
    end
    for child in n:iter_children() do visit(child, scope, ctx) end
  end
  visit(node, nil, nil)

  if region_wanted and #scopes > 0 then
    local first, last = node:range()
    local _, _, er = node:range()
    last = er
    -- row -> the scopes holding it, outer first (scopes are in pre-order).
    local rows = {}
    for _, s in ipairs(scopes) do
      for r = s.sr, s.er do
        local l = rows[r]
        if not l then
          l = {}
          rows[r] = l
        end
        l[#l + 1] = s
      end
    end
    -- A run of rows that one scope covers from column 0 is one mark.
    local run_from, run_to, run_groups, run_key = nil, nil, nil, nil
    local function flush_run()
      if run_from then
        put(run_from, 0, { end_row = run_to + 1, end_col = 0, hl_group = run_groups, hl_eol = true })
        run_from = nil
      end
    end
    for r = first, last do
      local held = rows[r]
      if not held then
        flush_run()
      else
        local segs, b, w, depth = {}, 0, 0, 0
        for k, s in ipairs(held) do
          -- A scope indented less than the one around it starts where that one does.
          b, w = math.max(b, s.b), math.max(w, s.w)
          if r > s.sr and r <= s.body_last then depth = depth + 1 end
          local g = {}
          for _, name in ipairs(scope_bits(s.id)) do g[#g + 1] = name end
          for _, name in ipairs(fn_bits(s.fn)) do g[#g + 1] = name end
          for _, name in ipairs(depth_bits(math.min(depth, 7))) do g[#g + 1] = name end
          segs[k] = { b = b, w = w, groups = g }
        end
        if #segs == 1 and segs[1].b == 0 then
          local key = table.concat(segs[1].groups, ' ')
          if run_from and run_key == key then
            run_to = r
          else
            flush_run()
            if #segs[1].groups > 0 then
              run_from, run_to, run_groups, run_key = r, r, segs[1].groups, key
            end
          end
        else
          flush_run()
          put_row(put, r, line_of(r), segs)
        end
      end
    end
    flush_run()
  end
  return marks, scopes
end

--- What a mark carries, as one string. Kept per placed mark: Neovim reports
--- only the last group of a stacked `hl_group` back.
local function content_of(o)
  local g = o.hl_group
  if type(g) == 'table' then g = table.concat(g, '+') end
  local v = ''
  if o.virt_text then
    local parts = {}
    for i, c in ipairs(o.virt_text) do
      local cg = c[2]
      if type(cg) == 'table' then cg = table.concat(cg, '+') end
      parts[i] = #c[1] .. ':' .. tostring(cg or '')
    end
    v = table.concat(parts, '/')
  end
  return table.concat({
    tostring(g or ''), o.hl_eol and 1 or 0, o.sign_hl_group or '', o.virt_text_pos or '', v,
  }, ',')
end

--- One line that tells two marks apart: where it is and what it carries.
local function mark_key(row, col, end_row, end_col, content)
  return table.concat({ row, col, end_row or -1, end_col or -1, content }, ',')
end

-- An anchor is an extmark at a scope's start whose id holds the scope's
-- ids: seq * 4096 + fn * 64 + scope. It moves with the text, so a scope
-- keeps its ids across edits, and the cursor's scope is looked up by where
-- its node starts.
local function anchor_ids(mark_id)
  return mark_id % 64, math.floor(mark_id / 64) % 64
end

--- The top-level node at `row`, or the nearest one before it.
local function top_node_near(root, line_of, row)
  for r = row, math.max(row - 200, 0), -1 do
    local line = line_of(r)
    local c = #line:match('^%s*')
    if c < #line then
      local n = root:descendant_for_range(r, c, r, c)
      while n and not n:equal(root) do
        local p = n:parent()
        if not p or p:equal(root) then return n end
        n = p
      end
    end
  end
  return root:child(0)
end

--- Bring the marks of rows lo..hi (the whole buffer when nil) in step with
--- the tree: the top-level nodes touching those rows are marked afresh, and
--- only the marks that differ are removed or placed.
local function refresh(buf, st, parser, lo, hi)
  local tree = parser:trees()[1]
  if not tree then return end
  local root = tree:root()
  local line_of = line_reader(buf)
  local nodes = {}
  local first_row, last_row
  if lo == nil then
    for child in root:iter_children() do nodes[#nodes + 1] = child end
    first_row, last_row = 0, api.nvim_buf_line_count(buf)
  else
    local n = top_node_near(root, line_of, lo)
    while n do
      local sr, _, er = n:range()
      if sr > hi and #nodes > 0 then break end
      nodes[#nodes + 1] = n
      first_row = math.min(first_row or sr, sr, lo)
      last_row = math.max(last_row or er, er, hi)
      n = n:next_sibling()
    end
    if not first_row then first_row, last_row = lo, hi end
  end

  -- The anchors there are: by position for the scopes that stay, and by
  -- neighbourhood for the ids a new scope must not take.
  local held, taken_scope, taken_fn = {}, {}, {}
  local a0, a1 = math.max(first_row - avoid_rows, 0), last_row + avoid_rows
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns_anchor, { a0, 0 }, { a1, -1 }, {})) do
    local scope_id, fn_id = anchor_ids(m[1])
    if m[2] >= first_row and m[2] <= last_row then
      held[m[2] .. ':' .. m[3]] = m[1]
    else
      taken_scope[scope_id], taken_fn[fn_id] = true, true
    end
  end
  local function fresh(counter, taken)
    for _ = 1, max_id do
      st[counter] = st[counter] % max_id + 1
      if not taken[st[counter]] then break end
    end
    taken[st[counter]] = true
    return st[counter]
  end
  local kept = {}
  local new_anchors = {}
  local function ids(sr, sc, is_fn)
    local key = sr .. ':' .. sc
    local mark = held[key]
    if mark and not kept[mark] then
      kept[mark] = true
      local scope_id, fn_id = anchor_ids(mark)
      taken_scope[scope_id] = true
      if is_fn then taken_fn[fn_id] = true end
      return scope_id, is_fn and fn_id or nil
    end
    local scope_id = fresh('next_scope', taken_scope)
    local fn_id = is_fn and fresh('next_fn', taken_fn) or 0
    new_anchors[#new_anchors + 1] = { sr, sc, scope_id, fn_id }
    return scope_id, is_fn and fn_id or nil
  end
  -- The scopes that stay claim their ids before any new one is handed out.
  for key, mark in pairs(held) do
    local scope_id, fn_id = anchor_ids(mark)
    taken_scope[scope_id] = true
    if fn_id ~= 0 then taken_fn[fn_id] = true end
    held[key] = mark
  end

  local wanted_marks = {}
  for _, node in ipairs(nodes) do
    local marks = block_marks(buf, node, line_of, ids)
    for _, m in ipairs(marks) do wanted_marks[#wanted_marks + 1] = m end
  end

  -- Anchors: drop those whose scope is gone, add those of new scopes.
  for _, mark in pairs(held) do
    if not kept[mark] then api.nvim_buf_del_extmark(buf, ns_anchor, mark) end
  end
  for _, a in ipairs(new_anchors) do
    st.seq = st.seq + 1
    pcall(api.nvim_buf_set_extmark, buf, ns_anchor, a[1], a[2], {
      id = st.seq * 4096 + a[4] * 64 + a[3],
      right_gravity = true,
    })
  end

  -- Marks: what is already there and still wanted stays untouched.
  local have = {}
  local existing = api.nvim_buf_get_extmarks(buf, ns_static, { first_row, 0 }, { last_row, -1 }, { details = true })
  for _, m in ipairs(existing) do
    local key = mark_key(m[2], m[3], m[4].end_row, m[4].end_col, st.content[m[1]] or '')
    local list = have[key]
    if not list then
      list = {}
      have[key] = list
    end
    list[#list + 1] = m[1]
  end
  for _, m in ipairs(wanted_marks) do
    local content = content_of(m[3])
    local list = have[mark_key(m[1], m[2], m[3].end_row, m[3].end_col, content)]
    if list and #list > 0 then
      list[#list] = nil
    else
      local ok, id = pcall(api.nvim_buf_set_extmark, buf, ns_static, m[1], m[2], m[3])
      if ok then st.content[id] = content end
    end
  end
  for _, list in pairs(have) do
    for _, id in ipairs(list) do
      api.nvim_buf_del_extmark(buf, ns_static, id)
      st.content[id] = nil
    end
  end
end

--- Drop what the tree gave a buffer. The cursor's own marks stay: they
--- follow the cursor, not the tree.
local function clear_static(buf)
  if api.nvim_buf_is_loaded(buf) then
    api.nvim_buf_clear_namespace(buf, ns_static, 0, -1)
    api.nvim_buf_clear_namespace(buf, ns_anchor, 0, -1)
  end
end

local function clear_buf(buf)
  clear_static(buf)
  if api.nvim_buf_is_loaded(buf) then api.nvim_buf_clear_namespace(buf, ns_cur, 0, -1) end
end

--- Build the marks of a buffer seen for the first time, or catch up with
--- the edits made to it since.
local function ensure(buf)
  if S.dead or not api.nvim_buf_is_loaded(buf) then return end
  local parser = get_parser(buf)
  local st = S.bufs[buf]
  if not parser then
    if st then
      clear_static(buf)
      S.bufs[buf] = nil
    end
    return
  end
  local full = false
  if not st or st.lang ~= parser:lang() then
    clear_static(buf)
    st = { lang = parser:lang(), next_scope = 0, next_fn = 0, seq = 0, content = {} }
    S.bufs[buf] = st
    full = true
    api.nvim_buf_attach(buf, false, {
      on_bytes = function(_, _, _, srow, _, _, old_erow, _, _, new_erow)
        if S.dead or S.bufs[buf] ~= st then return true end
        st.lo = math.min(st.lo or srow, srow)
        st.hi = math.max(st.hi or 0, srow + math.max(old_erow, new_erow))
        -- Marks follow once the edit itself is on screen: the typed
        -- character is not held back by them, and the marks of the text
        -- around it move with the text meanwhile. One pass per burst.
        if not st.scheduled then
          st.scheduled = true
          vim.schedule(function()
            st.scheduled = false
            if S.bufs[buf] == st then
              S.ensure(buf)
              S.update_cursor()
            end
          end)
        end
      end,
      on_reload = function()
        -- A reload drops every extmark: mark the buffer afresh.
        if S.bufs[buf] ~= st then return end
        st.reload = true
        vim.schedule(function()
          if S.bufs[buf] == st then
            S.ensure(buf)
            S.update_cursor()
          end
        end)
      end,
      on_detach = function()
        if S.bufs[buf] == st then S.bufs[buf] = nil end
      end,
    })
    -- Rows whose structure changed without an edit touching them (an
    -- unclosed block swallowing what follows) are marked afresh too.
    parser:register_cbs({
      on_changedtree = function(changes)
        if S.dead or S.bufs[buf] ~= st then return end
        for _, ch in ipairs(changes) do
          st.lo = math.min(st.lo or ch[1], ch[1])
          st.hi = math.max(st.hi or 0, ch[4])
        end
      end,
    }, true)
  end
  if st.reload then
    st.reload, full = false, true
    clear_static(buf)
    st.content = {}
  end
  if not full and not st.lo then return end
  parser:parse()
  local lo, hi = st.lo, st.hi
  st.lo, st.hi = nil, nil
  local ok, err
  if full then
    ok, err = pcall(refresh, buf, st, parser, nil, nil)
  else
    ok, err = pcall(refresh, buf, st, parser, lo, hi)
  end
  if not ok then S.last_error = err end
end
S.ensure = ensure

--- Tell the core where the cursor is: the ids of its function and scope,
--- and `nested`, the ids of up to four functions inside that function, six
--- bits each (a shader counts their cells as the cursor's function too).
local function notify_cursor(fn_id, scope_id, nested)
  if S.cursor_fn == fn_id and S.cursor_scope == scope_id and S.cursor_nested == nested then return end
  S.cursor_fn, S.cursor_scope, S.cursor_nested = fn_id, scope_id, nested
  pcall(vim.rpcnotify, vim.g.zonvie_channel or 0, 'zonvie_ts_cursor', fn_id, scope_id, nested)
end

--- The ids held by the anchor at a scope's start, 0 when it has none.
local function ids_of(buf, node)
  local sr, sc = node:range()
  local m = api.nvim_buf_get_extmarks(buf, ns_anchor, { sr, sc }, { sr, sc }, { limit = 1 })[1]
  if not m then return 0, 0 end
  return anchor_ids(m[1])
end

--- The ids of the first four multi-line functions inside `func`, packed
--- six bits each. Kept while the function and the text stay the same.
local function nested_fns(buf, st, func)
  local fr, fc, er, ec = func:range()
  local key = table.concat({ fr, fc, er, ec, api.nvim_buf_get_changedtick(buf) }, ':')
  if st.nested_key == key then return st.nested end
  local packed, count = 0, 0
  local function scan(nd)
    for c in nd:iter_children() do
      if count >= 4 then return end
      local sr, _, er2 = c:range()
      if c:named() and er2 > sr then
        if scope_kind(c) == 'Fn' then
          local m = api.nvim_buf_get_extmarks(buf, ns_anchor, { sr, select(2, c:range()) },
            { sr, select(2, c:range()) }, { limit = 1 })[1]
          local id = m and math.floor(m[1] / 64) % 64 or 0
          if id ~= 0 then
            packed = packed + id * 64 ^ count
            count = count + 1
          end
        end
        scan(c)
      end
    end
  end
  scan(func)
  st.nested_key, st.nested = key, packed
  return packed
end

--- The few cells that follow the cursor: a list of { row, col, opts }.
local function cursor_token_marks(buf, st, node, func, call_span, call_arg)
  local marks = {}
  if want.ZonvieTsCallCursor and call_span then
    marks[#marks + 1] = { call_span[1], call_span[2],
      { end_row = call_span[3], end_col = call_span[4], hl_group = 'ZonvieTsCallCursor' } }
  end
  if want.ZonvieTsCallArg and call_arg then
    local sr, sc, er, ec = call_arg:range()
    marks[#marks + 1] = { sr, sc, { end_row = er, end_col = ec, hl_group = 'ZonvieTsCallArg' } }
  end
  if want.ZonvieTsRef and func and IDENT[node:type()] then
    local name = ts.get_node_text(node, buf)
    -- The scan is kept while the function and the text stay the same.
    local fr, fc, er, ec = func:range()
    local key = table.concat({ fr, fc, er, ec, api.nvim_buf_get_changedtick(buf), name }, ':')
    if st.ref_key ~= key then
      st.ref_key = key
      local out = {}
      local function scan(nd)
        for c in nd:iter_children() do
          if c:named() then
            if IDENT[c:type()] then
              if not is_member(c) and ts.get_node_text(c, buf) == name then
                local sr, sc, r2, c2 = c:range()
                out[#out + 1] = { sr, sc, { end_row = r2, end_col = c2, hl_group = 'ZonvieTsRef' } }
              end
            elseif c:child_count() > 0 then
              scan(c)
            end
          end
        end
      end
      scan(func)
      st.ref_marks = out
    end
    for _, m in ipairs(st.ref_marks) do marks[#marks + 1] = m end
  end
  return marks
end

local function update_cursor()
  if S.dead then return end
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  -- The cursor's cells belong to the current window's buffer alone.
  local last = S.cursor_buf
  if last ~= buf then
    if last and api.nvim_buf_is_valid(last) then api.nvim_buf_clear_namespace(last, ns_cur, 0, -1) end
    S.cursor_buf, S.cursor_key, S.cursor_buf_mark = buf, nil, nil
  end
  if want.ZonvieTsCursorBuf then
    -- One mark over the whole buffer. Loading a file into the buffer, or
    -- replacing its text, can take the mark away or leave it short.
    local lines = api.nvim_buf_line_count(buf)
    local m = S.cursor_buf_mark
      and api.nvim_buf_get_extmark_by_id(buf, ns_cur, S.cursor_buf_mark, { details = true })
    if not m or #m == 0 or m[1] ~= 0 or m[3].end_row ~= lines then
      local ok, id = pcall(api.nvim_buf_set_extmark, buf, ns_cur, 0, 0, {
        id = S.cursor_buf_mark,
        end_row = lines, end_col = 0, hl_group = 'ZonvieTsCursorBuf',
        hl_eol = true, right_gravity = false, end_right_gravity = true,
      })
      if ok then S.cursor_buf_mark = id end
    end
  end
  local st = S.bufs[buf]
  local parser = st and get_parser(buf)
  if not parser then
    notify_cursor(0, 0, 0)
    return
  end
  local pos = api.nvim_win_get_cursor(win)
  local row, col = pos[1] - 1, pos[2]
  parser:parse({ row, row + 1 })
  local node = parser:named_node_for_range({ row, col, row, col }, { ignore_injections = false })
  local func, scope, call_span, call_arg
  local prev, n = nil, node
  while n do
    local t = n:type()
    if not call_span and prev and ARGS[t] then
      local p = n:parent()
      if p and CALL[p:type()] then
        call_span = { n:range() }
        if prev:named() then call_arg = prev end
      end
    elseif not call_span and prev and prev:named() and CALL[t] and #n:field('arguments') == 0 then
      -- A call whose arguments are its own children (Vim script): the
      -- list runs from the end of the callee to the end of the call.
      local callee = n:field('function')[1] or n:field('name')[1]
      if callee and not callee:equal(prev) and not ARGS[prev:type()] then
        local _, _, cr, cc = callee:range()
        local _, _, er, ec = n:range()
        call_span = { cr, cc, er, ec }
        call_arg = prev
      end
    end
    local kind = scope_kind(n)
    if kind then
      local sr, _, er = n:range()
      if er > sr then
        if not scope then scope = n end
        if kind == 'Fn' then
          func = n
          break
        end
      end
    end
    prev = n
    n = n:parent()
  end

  local scope_id = scope and ids_of(buf, scope) or 0
  local fn_id, nested = 0, 0
  if func then
    local _, f = ids_of(buf, func)
    fn_id = f
    if fn_id ~= 0 then nested = nested_fns(buf, st, func) end
  end
  notify_cursor(fn_id, scope_id, nested)

  if not cursor_tokens_wanted or not node then return end
  local marks = cursor_token_marks(buf, st, node, func, call_span, call_arg)
  local parts = {}
  for i, m in ipairs(marks) do
    parts[i] = mark_key(m[1], m[2], m[3].end_row, m[3].end_col, content_of(m[3]))
  end
  local key = table.concat(parts, ';')
  if S.cursor_key == key then return end
  S.cursor_key = key
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns_cur, 0, -1, { details = true })) do
    if m[4].hl_group ~= 'ZonvieTsCursorBuf' then api.nvim_buf_del_extmark(buf, ns_cur, m[1]) end
  end
  for _, m in ipairs(marks) do
    pcall(api.nvim_buf_set_extmark, buf, ns_cur, m[1], m[2], m[3])
  end
end
S.update_cursor = update_cursor

function S.teardown()
  S.dead = true
  pcall(api.nvim_del_augroup_by_id, aug)
  for _, b in ipairs(api.nvim_list_bufs()) do clear_buf(b) end
  pcall(vim.rpcnotify, vim.g.zonvie_channel or 0, 'zonvie_ts_cursor', 0, 0, 0)
end

define_markers()
api.nvim_create_autocmd('ColorScheme', { group = aug, callback = define_markers })
api.nvim_create_autocmd({ 'BufWinEnter', 'FileType' }, {
  group = aug,
  callback = function(ev)
    ensure(ev.buf)
    update_cursor()
  end,
})
api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'WinEnter' },
  { group = aug, callback = update_cursor })
for _, win in ipairs(api.nvim_list_wins()) do ensure(api.nvim_win_get_buf(win)) end
update_cursor()
