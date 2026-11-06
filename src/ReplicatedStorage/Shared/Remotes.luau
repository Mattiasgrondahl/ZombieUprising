--!strict
-- Single source of truth for client<->server networking.
-- All RemoteEvents/RemoteFunctions live under ReplicatedStorage.Remotes,
-- created by this module on the server once at boot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

local folderName = "Remotes"

local function ensureFolder(): Folder
	local f = ReplicatedStorage:FindFirstChild(folderName)
	if f and f:IsA("Folder") then
		return f
	end
	f = Instance.new("Folder")
	f.Name = folderName
	f.Parent = ReplicatedStorage
	return f
end

export type RemoteMap = {
	-- Client -> Server
	RequestFire: RemoteEvent,
	RequestReload: RemoteEvent,
	RequestPurchaseWeapon: RemoteEvent,
	RequestPurchasePerk: RemoteEvent,
	RequestRespawn: RemoteEvent,
	RequestOpenDoor: RemoteEvent,
	RequestMachine: RemoteEvent,

	-- Server -> Client
	WeaponStateChanged: RemoteEvent,
	PlayerStatsChanged: RemoteEvent,
	WaveStateChanged: RemoteEvent,
	DamageDealt: RemoteEvent,       -- for hit markers / floating numbers
	ZombieDamagedPlayer: RemoteEvent,
	ShopStateChanged: RemoteEvent,
	Notify: RemoteEvent,
	RunEnded: RemoteEvent,
}

local cache: { [string]: RemoteEvent } = {}

local function get(name: string): RemoteEvent
	local c = cache[name]
	if c then
		return c
	end
	local folder = ensureFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		cache[name] = existing
		return existing
	end
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = folder
	cache[name] = r
	return r
end

-- Lazily resolved accessors. Used by both client and server code so a missing
-- remote can never nil-index at runtime.
function Remotes.RequestFire(): RemoteEvent return get("RequestFire") end
function Remotes.RequestReload(): RemoteEvent return get("RequestReload") end
function Remotes.RequestPurchaseWeapon(): RemoteEvent return get("RequestPurchaseWeapon") end
function Remotes.RequestPurchasePerk(): RemoteEvent return get("RequestPurchasePerk") end
function Remotes.RequestRespawn(): RemoteEvent return get("RequestRespawn") end
function Remotes.RequestOpenDoor(): RemoteEvent return get("RequestOpenDoor") end
function Remotes.RequestMachine(): RemoteEvent return get("RequestMachine") end

function Remotes.WeaponStateChanged(): RemoteEvent return get("WeaponStateChanged") end
function Remotes.PlayerStatsChanged(): RemoteEvent return get("PlayerStatsChanged") end
function Remotes.WaveStateChanged(): RemoteEvent return get("WaveStateChanged") end
function Remotes.DamageDealt(): RemoteEvent return get("DamageDealt") end
function Remotes.ZombieDamagedPlayer(): RemoteEvent return get("ZombieDamagedPlayer") end
function Remotes.ShopStateChanged(): RemoteEvent return get("ShopStateChanged") end
function Remotes.Notify(): RemoteEvent return get("Notify") end
function Remotes.RunEnded(): RemoteEvent return get("RunEnded") end

-- Server-only prewarm; safe to call repeatedly.
function Remotes.InitServer()
	for _, n in ipairs({
		"RequestFire", "RequestReload", "RequestPurchaseWeapon", "RequestPurchasePerk", "RequestRespawn",
		"RequestOpenDoor",
		"RequestMachine",
		"WeaponStateChanged", "PlayerStatsChanged", "WaveStateChanged", "DamageDealt",
		"ZombieDamagedPlayer", "ShopStateChanged", "Notify", "RunEnded",
	}) do
		get(n)
	end
end

return Remotes
