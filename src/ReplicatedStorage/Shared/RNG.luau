--!strict
-- Deterministic PRNG so procedural map geometry is identical on every build
-- and identical across server/client when needed.

local RNG = {}
RNG.__index = RNG

export type Random = typeof(setmetatable({} :: { _seed: number }, RNG))

function RNG.new(seed: number): Random
	local self = {}
	self._seed = (math.floor(seed) % 2147483647)
	if self._seed <= 0 then
		self._seed = self._seed + 2147483646
	end
	return setmetatable(self, RNG)
end

function RNG.Next(self: Random): number
	-- Park-Miller minimal standard
	self._seed = (self._seed * 16807) % 2147483647
	return self._seed / 2147483647
end

function RNG.Range(self: Random, min: number, max: number): number
	return min + self.Next(self) * (max - min)
end

function RNG.Int(self: Random, min: number, max: number): number
	return math.floor(self.Range(self, min, max + 1))
end

function RNG.Pick(self: Random, list: { any }): any
	if #list == 0 then
		return nil
	end
	return list[self.Int(self, 1, #list)]
end

-- Weighted pick. entries: array of { weight = number, value = any }
function RNG.Weighted(self: Random, entries: { { weight: number, value: any } }): any
	local total = 0
	for _, e in ipairs(entries) do
		total += (e.weight :: number) or 0
	end
	if total <= 0 then
		return nil
	end
	local roll = self.Next(self) * total
	local acc = 0
	for _, e in ipairs(entries) do
		acc += (e.weight :: number) or 0
		if roll <= acc then
			return e.value
		end
	end
	return entries[#entries].value
end

return RNG
