-- A layout's frame, so a layout can face any way: positions and directions are worked out in the layout's
-- own terms (x along it, y across it, as if it ran east with its side to the south) and turned or mirrored
-- onto the map by a matrix m = {a, b, c, d}: world offset = (a*x + b*y, c*x + d*y). Nil or IDENTITY is
-- "as written" (x east, y south). Directions are 0-3 from north, as in tool arguments.
local M = {}

local SIDES = {[0] = {0, -1}, {1, 0}, {0, 1}, {-1, 0}}
M.IDENTITY = {1, 0, 0, 1}

-- The frame whose x runs toward direction `dir` (0-3) with y to its right, or to its left with `mirror`.
function M.make(dir, mirror)
  local u = SIDES[dir]
  local sx, sy = -u[2], u[1]
  if mirror then sx, sy = -sx, -sy end
  return {u[1], sx, u[2], sy}
end

-- A vector in the frame's terms, on the map.
function M.vec(m, x, y)
  if not m then return x, y end
  return m[1] * x + m[2] * y, m[3] * x + m[4] * y
end

-- A map vector in the frame's terms (the matrix is a turn or mirror, so its inverse is its transpose).
function M.unvec(m, x, y)
  if not m then return x, y end
  return m[1] * x + m[3] * y, m[2] * x + m[4] * y
end

-- The point (x, y) of the frame whose origin (its (0, 0)) is the map point o.
function M.at(m, o, x, y)
  local dx, dy = M.vec(m, x, y)
  return {x = o.x + dx, y = o.y + dy}
end

-- A direction (0-3) in the frame's terms, on the map.
function M.dir(m, d)
  if not m then return d end
  local x, y = M.vec(m, SIDES[d][1], SIDES[d][2])
  for k = 0, 3 do
    if SIDES[k][1] == x and SIDES[k][2] == y then return k end
  end
end

-- The box with corners (x0, y0) and (x1, y1) in the frame's terms, on the map.
function M.box(m, o, x0, y0, x1, y1)
  local a, b = M.at(m, o, x0, y0), M.at(m, o, x1, y1)
  return {left_top = {x = math.min(a.x, b.x), y = math.min(a.y, b.y)},
    right_bottom = {x = math.max(a.x, b.x), y = math.max(a.y, b.y)}}
end

return M
