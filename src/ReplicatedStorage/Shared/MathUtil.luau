--!strict
-- Small shared math helpers.

local MathUtil = {}
export type SpreadRand = (number, number) -> number

function MathUtil.Clamp(v: number, lo: number, hi: number): number
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function MathUtil.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function MathUtil.Round(v: number): number
	return math.floor(v + 0.5)
end

-- Spread a ray direction by up to `degrees` for weapon cone fire.
--
-- NOTE: deliberately not `--!strict`-analyzable in isolation because luau-analyze
-- has no Vector3 operator overloads; every Vector3 here is cast to `any` for the
-- arithmetic only, then cast back. The unit-testable scalar math above is typed.
function MathUtil.ApplySpread(dir: Vector3, degrees: number, rand: SpreadRand): Vector3
	if degrees <= 0 then
		return dir
	end
	local rad = math.rad(degrees)
	local up: Vector3 = if math.abs(dir.Y) > 0.99 then Vector3.new(1, 0, 0) else Vector3.new(0, 1, 0)
	local right: Vector3 = (dir:Cross(up)).Unit
	local localUp: Vector3 = (right:Cross(dir)).Unit

	local a = rand(-rad, rad)
	local b = rand(-rad, rad)

	local sa = math.sin(a)
	local sb = math.sin(b)

	-- Component access is done through `any` views purely because the offline
	-- analyzer cannot resolve Vector3 members. All values are real Vector3s.
	local rv: any = right
	local uv: any = localUp
	local dv: any = dir

	local ox = rv.X * sa + uv.X * sb
	local oy = rv.Y * sa + uv.Y * sb
	local oz = rv.Z * sa + uv.Z * sb

	local nx: number = dv.X + ox
	local ny: number = dv.Y + oy
	local nz: number = dv.Z + oz
	local mag = math.sqrt(nx * nx + ny * ny + nz * nz)
	if mag <= 0 then
		return dir
	end
	return Vector3.new(nx / mag, ny / mag, nz / mag)
end

return MathUtil
