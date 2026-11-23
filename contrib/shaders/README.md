# Tree-sitter shader samples

Five post-process shaders that draw from the structure of the code, not from
its pixels: which function holds the cursor, which identifiers are its
parameters, how deep a line is nested, where the syntax is broken.

| Shader | What it shows |
|---|---|
| `ts_spotlight.glsl` | The function under the cursor is framed; other functions step back. The frame beats twice when the cursor enters. |
| `ts_threads.glsl` | Each parameter of the cursor's function gets its own colour: a pill where it is declared, an underline at every use. The argument under the cursor in a call is ringed. |
| `ts_gutter_glyphs.glsl` | Icons in the sign column for functions, classes, loops, branches and exits, drawn by the shader. A hairline rules off each function. |
| `ts_strata.glsl` | Nesting as stacked plates behind the text, warm past four levels. A rail marks the scope holding the cursor. |
| `ts_faultline.glsl` | Syntax errors get a zigzag, a halo and a tick at the window edge, but only once you stop typing. |

## Use

```toml
[shaders]
enabled = true
paths = ["/absolute/path/to/contrib/shaders/ts_spotlight.glsl"]
```

The buffer needs a Tree-sitter parser. Neovim bundles C, Lua, Markdown, Vim
script, Vimdoc and Query; other languages need their parser installed (for
example through nvim-treesitter). A buffer without one is drawn unchanged.

Load one sample at a time. A shader reads a group as "bit i of the cell's
mask", where i counts the names declared across the whole shader chain, so
a sample placed second in `paths` would read the first one's bits. To
combine two, merge their `@zonvie-hl-groups:` lines into one file and
renumber the bit constants at the top.

Every sample has its tuning constants at the top of the file: amounts,
colours for dark and light themes, durations.

## How it works

1. A shader declares the highlight groups it wants to read:

   ```glsl
   // @zonvie-hl-groups: ZonvieTsFnB0 ZonvieTsFnB1 ZonvieTsFnB2 ZonvieTsFnB3 ZonvieTsFnB4 ZonvieTsFnB5
   // @zonvie-hl-groups: ZonvieTsCursorBuf ZonvieTsFnName
   ```

2. Names starting with `ZonvieTs` are markers. While a loaded shader
   declares one, Zonvie runs its Tree-sitter layer
   (`src/core/shader_ts_layer.lua`) in Neovim. The layer defines the marker
   groups and places them from each buffer's syntax tree. A marker carries
   only a cterm colour, so it changes nothing an RGB UI draws, and no
   colorscheme needs to know about it.

3. The markers say what a cell *is*, never where the cursor is: which
   function and scope it belongs to (as small numbers, a few marker bits
   each), how deep it is nested, whether it is a parameter. They are placed
   once and follow edits, so moving the cursor resends no text.

4. Where the cursor is arrives separately, as three uniforms:

   | Uniform | Value |
   |---|---|
   | `iTsCursorFn` | id of the innermost function holding the cursor, 0 = none |
   | `iTsCursorScope` | id of the innermost multi-line scope holding it, 0 = none |
   | `iTsCursorNested` | ids of up to four functions nested in that function, 6 bits each |

   The shader compares them with the ids on the cell it shades:

   ```glsl
   uint g = zonvieCellGroupsAt(cell);              // bit i = the i-th declared name
   bool here = (g & 63u) == uint(iTsCursorFn + 0.5) // same function id ...
       && (g & 64u) != 0u;                          // ... in the cursor's buffer
   ```

Removing the shader, or declaring no marker, tears the layer down.

## Markers

On the cells of scopes (functions, classes, loops and branches that span
several lines). A scope covers its rows from its first line's indent to the
window's right edge; where scopes nest, a cell belongs to the innermost one.

| Name | Cells |
|---|---|
| `ZonvieTsFnB0` .. `B5` | id of the function the cell is in, a 6-bit number, 0 = none |
| `ZonvieTsScopeB0` .. `B5` | id of the cell's scope, 0 = none |
| `ZonvieTsDepthB0` `B1` `B2` | the cell's nesting depth, 0 to 7 |

Ids are 1 to 63, per buffer. Scopes within 400 rows of each other get
different ids, and a scope keeps its id while the text around it is edited.

On tokens and rows:

| Name | Cells |
|---|---|
| `ZonvieTsFnHead` | a function's first line, from the function rightward |
| `ZonvieTsFnName` | the name in a function definition |
| `ZonvieTsParam` | a parameter name in a function definition |
| `ZonvieTsParamB0` `B1` `B2` | on a parameter's name, where it is declared and where its function's body uses it: its position, 1 to 7 (cycling) |
| `ZonvieTsExit` | a `return`, `break`, `continue`, `throw` or `goto` statement |
| `ZonvieTsError` | an `ERROR` or `MISSING` node (the first line of one spanning several) |
| `ZonvieTsErrorRow` | one blank cell at the window's right edge, on each row that has such a node |

On blank sign-column cells of a construct's first row:

| Name | Row |
|---|---|
| `ZonvieTsSignFn` `ZonvieTsSignClass` `ZonvieTsSignLoop` `ZonvieTsSignBranch` | where a multi-line function, class, loop or branch starts |
| `ZonvieTsSignExit` | an exit statement, on a row no construct starts on |

Following the cursor of the current window (a few cells each, apart from
the first):

| Name | Cells |
|---|---|
| `ZonvieTsCursorBuf` | every cell of the buffer the cursor is in: ids are per buffer, so this says which buffer the cursor uniforms speak of |
| `ZonvieTsRef` | the identifier under the cursor, wherever its function names it |
| `ZonvieTsCallCursor` | the argument list holding the cursor |
| `ZonvieTsCallArg` | the argument holding the cursor |

Depth is per cell, not per row: scope k of a row covers the cells from the
column of its first line rightward, so a shader can draw nested blocks.
Blank lines inside a scope carry the same steps.

Raw Tree-sitter captures (`@keyword.return`, `@markup.heading.1`, ...) and
ordinary groups (`Comment`, `DiagnosticUnderlineError`) can be declared in
the same line and need no layer. At most 32 names are read across the
shader chain.

### Several windows

A shader runs once per surface: the main window with all its splits, and
each external window. The cursor's rect is one value handed to all of them,
so in a window that does not hold the cursor it lands on unrelated cells. A
shader that should look the same in every window therefore reads what to
draw from the cells it shades and from the cursor uniforms, and uses the
cursor's rect only to time an animation:

- The cursor uniforms are the same on every surface, and every window
  showing the cursor's buffer carries `ZonvieTsCursorBuf`, split or
  external. A cell in another buffer may carry the same id by chance; the
  marker tells them apart.
- "Some function holds the cursor" is `iTsCursorFn > 0.5`, whatever buffer
  the shaded cell is in: `ts_spotlight` dims the functions of every window
  with it.
- A marker that needs a window's edge is placed there by the layer
  (`ZonvieTsErrorRow`), not searched for along the row: in a split, the
  cells further along a row belong to the next window.

## Design notes

The samples follow a few rules, taken from a survey of editor features and
of the reading research behind them:

- **Structure before colour.** The syntax colours are already in use.
  These effects use what is left: lightness of the background, enclosure,
  outline, position in the gutter. Where colour carries meaning
  (`ts_threads`), shape carries it too.
- **The text is not touched.** Tints go to the background only: each
  sample recovers how much of a pixel is glyph from the cell's own colours
  and paints under it. Nothing blurs or glows over a letter. The one
  exception is `ts_spotlight`, which moves other functions' text toward its
  background by 38% (it keeps 62% of the contrast).
- **Only the active thing is loud.** Ambient layers (plates, icons, rules)
  stay near the background. The accent colour is spent on the scope the
  cursor is in.
- **Motion marks an arrival, then stops.** Animation starts when the cursor
  enters a new function or scope, never on a move inside it, and ends
  within 0.3 to 1.5 s. `ts_spotlight` keeps a faint breath at rest; set
  `BREATH` to 0 for a still frame. `ts_faultline` waits for the keys to be
  quiet instead of flagging every half-typed line.

## Limits

- Constructs are recognised by node type across the common grammars (the
  tables at the top of `shader_ts_layer.lua`). The layer has been run on
  Lua, C and Vim script, the grammars Neovim bundles; the entries for other
  languages are written from their grammars and not yet exercised. A
  grammar that names its nodes differently gets fewer markers until its
  types are added.
- The samples have been run on macOS, on dark and light backgrounds. For
  Windows and Linux they are only known to compile (HLSL, GLSL 3.3).
- Ids are 6 bits. Two scopes more than 400 rows apart can share one, so two
  windows showing distant parts of one buffer can both light a function.
  A function holding more than four nested functions lights the first four
  with it.
- Parameter positions are marked in the function's own body. A use inside
  a nested function is not marked; a local variable that reuses the name
  is.
- The cursor uniforms follow the current window: two windows on one buffer
  show the same spotlight.
- External windows have been run as `nvim_open_win(..., { external = true })`.
  `--extwindows` takes the same surface path but has not been run: it needs
  a Neovim that accepts the `ext_windows` UI option.
- A sample asks "is this row inside the cursor's function" by looking up
  to 16 cells along the row. A window narrower than that beside another one
  can pick up its neighbour's answer.
- A shader that names `iTime` is redrawn every frame. Four of the five do,
  for their entry animations; `ts_gutter_glyphs` does not.
- Marks follow an edit one redraw after the edit itself: typed text is not
  held back, and a line whose structure just changed shows its old marks
  for that one frame.
- Cost, measured through the core with a real Neovim on a large Lua
  file, Neovim's own `lsp.lua` (key to first flush, release build): scrolling, cursor moves and
  typing stay within 0.1 to 0.6 ms of running no layer with one sample
  declared. Every combination of syntax colour and marker bits on screen is
  an attribute id Neovim defines once; paging through new text with all 32
  names declared defines thousands and costs 3 to 4 ms a page.
- A buffer over 20,000 lines is left alone unless Tree-sitter highlighting
  already keeps its tree.

## Checking

```bash
zig build e2e -Dtest-filter=shader_ts_layer              # markers reach the cell masks, real Neovim (Lua, C)
zig build test -Dtest-filter="sample shaders"            # the samples compile to MSL, HLSL and GLSL 3.3
zig build gui-test -Dtest-filter=visual_ts_shader_samples # the samples draw in the real app
zig build gui-test -Dtest-filter=visual_ts_shader_windows # ... in splits and external windows
```

`visual_ts_shader_samples` shows each sample a Lua and a C buffer on a dark
and a light background and compares every view against the same view
without markers. `visual_ts_shader_windows` does the same for a vertical
split of two buffers and for two external windows beside the main one, and
checks that no window draws from its neighbour's rows. Both write their
captures under `tmp/`.
