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
   // @zonvie-hl-groups: ZonvieTsFnCursor ZonvieTsFn ZonvieTsFnName
   ```

2. Names starting with `ZonvieTs` are markers. While a loaded shader
   declares one, Zonvie runs its Tree-sitter layer
   (`src/core/shader_ts_layer.lua`) in Neovim. The layer defines the marker
   groups and places them from each buffer's syntax tree. A marker carries
   only a cterm colour, so it changes nothing an RGB UI draws, and no
   colorscheme needs to know about it.

3. The shader reads the markers per cell, next to the cell's character and
   colours:

   ```glsl
   bool in_cursor_fn = zonvieCellHasGroup(fragCoord, 0); // the first declared name
   ```

Removing the shader, or declaring no marker, tears the layer down.

## Markers

Placed for the visible rows, redrawn with the text:

| Name | Cells |
|---|---|
| `ZonvieTsFn` | a function, from its line's indent to the window's right edge |
| `ZonvieTsFnHead` | a function's first line, from the function rightward |
| `ZonvieTsFnName` | the name in a function definition |
| `ZonvieTsParam` | a parameter name in a function definition |
| `ZonvieTsExit` | a `return`, `break`, `continue`, `throw` or `goto` statement |
| `ZonvieTsError` | an `ERROR` or `MISSING` node (the first line of one spanning several) |
| `ZonvieTsDepthB0` `B1` `B2` | the cell's nesting depth as a 3-bit number, 0 to 7 |

Following the cursor of the current window:

| Name | Cells |
|---|---|
| `ZonvieTsFnCursor` | the innermost function holding the cursor |
| `ZonvieTsScopeCursor` | the innermost multi-line scope holding the cursor |
| `ZonvieTsArg1` .. `ZonvieTsArg6` | parameter i of that function (cycling past six), declared and used |
| `ZonvieTsRef` | the identifier under the cursor, wherever that function names it |
| `ZonvieTsCallCursor` | the argument list holding the cursor |
| `ZonvieTsCallArg` | the argument holding the cursor |

On blank sign-column cells of a construct's first row:

| Name | Row |
|---|---|
| `ZonvieTsSignFn` `ZonvieTsSignClass` `ZonvieTsSignLoop` `ZonvieTsSignBranch` | where a multi-line function, class, loop or branch starts |
| `ZonvieTsSignExit` | an exit statement, on a row no construct starts on |

Depth is per cell, not per row: scope k of a row covers the cells from the
column of its first line rightward, so a shader can draw nested blocks.
Blank lines inside a scope carry the same steps.

Raw Tree-sitter captures (`@keyword.return`, `@markup.heading.1`, ...) and
ordinary groups (`Comment`, `DiagnosticUnderlineError`) can be declared in
the same line and need no layer.

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
- Parameter uses are matched by name inside the function. A nested
  function's own parameter of the same name is left out; a local variable
  that reuses the name is not.
- The cursor markers are per buffer and follow the current window: two
  windows on one buffer show the same spotlight.
- A shader that names `iTime` is redrawn every frame. Four of the five do,
  for their entry animations; `ts_gutter_glyphs` does not.
- The layer's cost, measured on a 1656-line Lua file with every marker
  declared: 1.9 ms to compute the markers of 60 visible rows (once per edit
  or scroll), 0.1 to 0.5 ms per cursor move. Signs are placed for the rows
  around the windows only.
- A buffer over 20,000 lines is left alone unless Tree-sitter highlighting
  already keeps its tree.

## Checking

```bash
zig build e2e -Dtest-filter=shader_ts_layer              # markers reach the cell masks, real Neovim (Lua, C)
zig build test -Dtest-filter="sample shaders"            # the samples compile to MSL, HLSL and GLSL 3.3
zig build gui-test -Dtest-filter=visual_ts_shader_samples # the samples draw in the real app
```

The last one shows each sample a Lua and a C buffer on a dark and a light
background, compares every view against the same view without markers, and
writes the captures to `tmp/ts_shader_samples/`.
