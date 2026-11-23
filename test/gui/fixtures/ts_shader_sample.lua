-- Sample buffer for the contrib/shaders/ts_*.glsl scenarios.
local M = {}

local function clamp(value, low, high)
  if value < low then
    return low
  end
  return math.min(value, high)
end

function M.blend(base, tint, amount)
  local weight = clamp(amount, 0, 1)
  local mixed = {}
  for channel = 1, 3 do
    if base[channel] ~= tint[channel] then
      local delta = tint[channel] - base[channel]
      mixed[channel] = base[channel] + delta * weight

    else
      mixed[channel] = base[channel]
    end
  end
  return mixed
end

function M.palette(colors, steps)
  local out = {}
  for index, color in ipairs(colors) do
    for step = 1, steps do
      if step % 2 == 0 then
        while #out > 64 do
          table.remove(out, 1)
        end
        out[#out + 1] = M.blend(color, colors[index + 1] or color, step / steps)
      end
    end
  end
  return out
end

return M
