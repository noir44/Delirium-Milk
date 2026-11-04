-- Delirium Milk - the server side.
--
-- Cows: lactation ends a set number of game days after calving, and the
-- udder is kept from growing past a share of its genetic maximum, which is
-- what lets vanilla hurt an unmilked cow.
-- Milk: cow, sheep and generic animal milk turns into sour milk after a set
-- number of game days in any container. Vanilla fluids never age at all.
--
-- What the vanilla code does (read from projectzomboid.jar with javap; see
-- E:\mods\claude\Delirium-Milk.md for the full walk-through):
-- * AnimalData.updateMilk, every game hour, server only: milk grows by
--   maxMilkActual / 20 while canHaveMilk; lactation stops only when the cow
--   is not pregnant, has no calves and nobody milked her for 21 days.
-- * IsoAnimal.milkAnimal grows maxMilkActual up to 1.3 x getMaxMilk() on every
--   milking; reduceHealthDueToMilk hurts the cow once milk > 1.15 x getMaxMilk().
--   A cow milked for a while and then left alone is the one that dies.
-- * milkAnimal also sets canHaveMilk back to true, so drying a cow off has
--   to empty the udder too.
--
-- media/lua/server/ is also executed by connected clients, hence the guard
-- (see E:\mods\CLAUDE.md).
if isClient() then return end

require "TimedActions/Animals/ISMilkAnimal"
require "Fluids/ISFluidTransferAction"

local KEY_MILK = "DelMilk"           -- container modData: { age, amt, t }
local KEY_LACT = "DelMilk_lact"      -- animal modData: world hour lactation began
local KEY_PREG = "DelMilk_preg"      -- animal modData: pregnant at the last check
local SOUR_FLUID = "DelSourMilk"
local EPS = 0.001
local SLICES = 30                    -- a full scan around each player takes 30 game minutes
local MAX_DEPTH = 3                  -- bags in bags in a crate

local function log(msg)
	print("DelMilk: " .. msg)
	writeLog("DelMilk", msg)
end

-- Read inline every time: top-level reads see the schema defaults.
local function option(name, default)
	local page = SandboxVars and SandboxVars.DelMilk
	local value = page and tonumber(page[name])
	if value == nil then return default end
	return value
end

local function now()
	return getGameTime():getWorldAgeHours()
end

-- ---------------------------------------------------------------------------
-- Milk ageing
-- ---------------------------------------------------------------------------

local milkFluids = nil

local function fluids()
	if not milkFluids then
		milkFluids = {}
		for _, fluid in ipairs({ Fluid.CowMilk, Fluid.SheepMilk, Fluid.AnimalMilk }) do
			if fluid then table.insert(milkFluids, fluid) end
		end
	end
	return milkFluids
end

local function milkAmount(fc)
	if fc:isEmpty() then return 0 end
	local total = 0
	for _, fluid in ipairs(fluids()) do
		total = total + fc:getSpecificFluidAmount(fluid)
	end
	return total
end

-- Ageing speed, as a share of normal, for an item where it lies now: a
-- powered fridge or freezer anywhere up the chain of bags slows it down.
local function itemRate(item)
	local container = item:getContainer()
	local depth = 0
	while container and depth <= MAX_DEPTH do
		if container:isPowered() then
			if container:isFreezer() then return option("FreezerPercent", 5) / 100 end
			if container:isFridge() then return option("FridgePercent", 25) / 100 end
		end
		local holder = container:getContainingItem()
		container = holder and holder:getContainer() or nil
		depth = depth + 1
	end
	return 1
end

local function forget(owner)
	if owner:hasModData() and owner:getModData()[KEY_MILK] then
		owner:getModData()[KEY_MILK] = nil
	end
end

-- Brings the age of the milk in `owner` up to now and returns its state, or
-- nil when it holds no milk. Kept as accumulated age rather than a birth time
-- so that a fridge can slow it down. Milk that arrived since the last look is
-- fresh and thins the age out; milk seen for the first time (stock from
-- before the mod) starts at age 0.
local function touch(owner, fc, rate)
	local amount = milkAmount(fc)
	if amount < EPS then
		forget(owner)
		return nil
	end
	local t = now()
	local md = owner:getModData()
	local s = md[KEY_MILK]
	if type(s) ~= "table" then
		s = { age = 0, amt = amount, t = t }
		md[KEY_MILK] = s
		return s
	end
	local dt = t - (tonumber(s.t) or t)
	if dt < 0 then dt = 0 end
	local age = (tonumber(s.age) or 0) + dt * rate
	local old = tonumber(s.amt) or 0
	if amount > old + EPS then age = age * old / amount end
	s.age = age
	s.amt = amount
	s.t = t
	return s
end

local function spoil(owner, fc)
	local total = 0
	for _, fluid in ipairs(fluids()) do
		local amount = fc:getSpecificFluidAmount(fluid)
		if amount > 0 then
			fc:adjustSpecificFluidAmount(fluid, 0)
			total = total + amount
		end
	end
	local sour = Fluid.Get(SOUR_FLUID)
	if not sour then
		log("fluid " .. SOUR_FLUID .. " not found, soured milk is dropped")
	elseif total > 0 then
		fc:addFluid(sour, total)
	end
	forget(owner)
	owner:sendSyncEntity(nil)
	return total
end

local stats = { spoiled = 0, litres = 0 }

-- The fridge lookup only for containers that do hold milk.
local function check(owner, fc, rateFn)
	if milkAmount(fc) < EPS then
		forget(owner)
		return
	end
	local s = touch(owner, fc, rateFn(owner))
	local days = option("SpoilDays", 3)
	if s and days > 0 and s.age >= days * 24 then
		stats.spoiled = stats.spoiled + 1
		stats.litres = stats.litres + spoil(owner, fc)
	end
end

local function objectRate() return 1 end

local function scanContainer(container, depth)
	if not container then return end
	local items = container:getItems()
	for i = 0, items:size() - 1 do
		local item = items:get(i)
		local fc = item:getFluidContainer()
		if fc then check(item, fc, itemRate) end
		if depth < MAX_DEPTH and instanceof(item, "InventoryContainer") then
			scanContainer(item:getInventory(), depth + 1)
		end
	end
end

local function scanSquare(square)
	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if instanceof(object, "IsoWorldInventoryObject") then
			local item = object:getItem()
			if item then
				local fc = item:getFluidContainer()
				if fc then check(item, fc, objectRate) end
				if instanceof(item, "InventoryContainer") then scanContainer(item:getInventory(), 1) end
			end
		else
			local fc = object:getFluidContainer()
			if fc then check(object, fc, objectRate) end
			for c = 0, object:getContainerCount() - 1 do
				scanContainer(object:getContainerByIndex(c), 0)
			end
		end
	end
end

-- getVehicles() is a java.util.Set: toArray() + ipairs, as in Delirium-Zones-Vehicles.
local function scanVehicles()
	local set = getCell():getVehicles()
	local array = set and set:toArray()
	if not array then return end
	for _, vehicle in ipairs(array) do
		for i = 0, vehicle:getPartCount() - 1 do
			local part = vehicle:getPartByIndex(i)
			if part then scanContainer(part:getItemContainer(), 0) end
		end
	end
end

-- Each game minute every online player gets one slice of the rows around
-- them, three floors deep; squares several players share are done once.
local function scanAroundPlayers(slice)
	local players = getOnlinePlayers()
	if not players then return end
	local radius = math.floor(option("ScanRadius", 40))
	local cell = getCell()
	local seen = {}
	for p = 0, players:size() - 1 do
		local player = players:get(p)
		if slice == 0 then scanContainer(player:getInventory(), 0) end
		local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
		for dy = -radius, radius do
			if (dy + radius) % SLICES == slice then
				local y = py + dy
				for z = pz - 1, pz + 1 do
					for x = px - radius, px + radius do
						local key = (z + 64) * 10000000000 + x * 100000 + y
						if not seen[key] then
							seen[key] = true
							local square = cell:getGridSquare(x, y, z)
							if square then scanSquare(square) end
						end
					end
				end
			end
		end
	end
end

-- Pouring passes the age along: milk poured into another container keeps
-- the age it had, instead of turning fresh there.
local function snapshot(action)
	local src, dst = action.source, action.target
	if not src or not dst or not src.getOwner or not dst.getOwner then return nil end
	local srcOwner, dstOwner = src:getOwner(), dst:getOwner()
	local srcFc, dstFc = src:getFluidContainer(), dst:getFluidContainer()
	if not srcOwner or not dstOwner or not srcFc or not dstFc then return nil end
	if not srcOwner.getModData or not dstOwner.getModData then return nil end
	if milkAmount(srcFc) < EPS then return nil end
	local function rate(owner)
		if instanceof(owner, "InventoryItem") then return itemRate(owner) end
		return 1
	end
	local s = touch(srcOwner, srcFc, rate(srcOwner))
	local d = touch(dstOwner, dstFc, rate(dstOwner))
	return {
		srcOwner = srcOwner, srcFc = srcFc, srcAge = s and s.age or 0,
		dstOwner = dstOwner, dstFc = dstFc, dstAge = d and d.age or 0,
		dstAmt = milkAmount(dstFc),
	}
end

local function inherit(snap)
	if not snap then return end
	local amount = milkAmount(snap.dstFc)
	local poured = amount - snap.dstAmt
	if poured > EPS then
		local md = snap.dstOwner:getModData()
		md[KEY_MILK] = {
			age = (snap.dstAge * snap.dstAmt + snap.srcAge * poured) / amount,
			amt = amount,
			t = now(),
		}
	end
	local left = milkAmount(snap.srcFc)
	if left < EPS then
		forget(snap.srcOwner)
	elseif snap.srcOwner:hasModData() and type(snap.srcOwner:getModData()[KEY_MILK]) == "table" then
		snap.srcOwner:getModData()[KEY_MILK].amt = left
	end
end

local originalTransferUpdate = ISFluidTransferAction.update
function ISFluidTransferAction:update()
	local snap = snapshot(self)
	originalTransferUpdate(self)
	inherit(snap)
end

local originalTransferComplete = ISFluidTransferAction.complete
function ISFluidTransferAction:complete()
	local snap = snapshot(self)
	local result = originalTransferComplete(self)
	inherit(snap)
	return result
end

-- ---------------------------------------------------------------------------
-- Cows
-- ---------------------------------------------------------------------------

-- Keeps maxMilkActual at or under UdderCapPercent of the cow's genetic
-- maximum. Vanilla only hurts a cow above 115%, so a cap up to 115 means an
-- unmilked cow is never hurt by her milk. Returns true when it cut something.
local function capUdder(animal)
	local data = animal and animal:getData()
	if not data then return false end
	local maxMilk = data:getMaxMilk()
	if not maxMilk or maxMilk <= 0 then return false end
	local cap = maxMilk * option("UdderCapPercent", 100) / 100
	local cut = false
	if data:getMaxMilkActual() > cap then
		data:setMaxMilkActual(cap)
		cut = true
	end
	if data:getMilkQuantity() > cap then
		data:setMilkQuantity(cap)
		cut = true
	end
	return cut
end

-- Ends lactation LactationDays after calving. A calving is seen as the cow
-- having been pregnant at the last check and not now; cows met in milk for
-- the first time (before the mod) count from that moment.
local function checkLactation(animal, t)
	local data = animal:getData()
	local md = animal:getModData()
	local pregnant = data:isPregnant()
	if md[KEY_PREG] and not pregnant then md[KEY_LACT] = t end
	md[KEY_PREG] = pregnant or nil
	if not data:canHaveMilk() then
		md[KEY_LACT] = nil
		return false
	end
	if not md[KEY_LACT] then md[KEY_LACT] = t end
	local days = option("LactationDays", 300)
	if days <= 0 or t - md[KEY_LACT] < days * 24 then return false end
	-- canHaveMilk first: setMilkQuantity on a lactating cow would count as
	-- a milking and restart vanilla's 21-day timer.
	data:setCanHaveMilk(false)
	data:setMilkQuantity(0)
	md[KEY_LACT] = nil
	return true
end

local function sweepAnimals()
	local list = getCell():getAnimals()
	if not list then return 0, 0, 0 end
	local t = now()
	local cows, capped, dried = 0, 0, 0
	for i = 0, list:size() - 1 do
		local animal = list:get(i)
		if animal and not animal:isDead() and animal:hasUdder() and animal:getData() then
			cows = cows + 1
			if checkLactation(animal, t) then dried = dried + 1 end
			if capUdder(animal) then capped = capped + 1 end
		end
	end
	return cows, capped, dried
end

-- Milking grows the udder; cap it right away, so a cow milked and then left
-- in an unloaded area is not caught above the limit by the hourly sweep.
local originalMilk = ISMilkAnimal.milk
function ISMilkAnimal:milk()
	originalMilk(self)
	capUdder(self.animal)
end

-- ---------------------------------------------------------------------------
-- Schedule
-- ---------------------------------------------------------------------------

local firstReport = true

local function everyMinute()
	local slice = math.floor(now() * 60 + 0.5) % SLICES
	scanAroundPlayers(slice)
	if slice ~= 0 then return end

	scanVehicles()
	local cows, capped, dried = sweepAnimals()
	if firstReport or capped > 0 or dried > 0 or stats.spoiled > 0 then
		log("hour: " .. cows .. " cows loaded, " .. capped .. " udders capped, " .. dried
			.. " dried off; " .. stats.spoiled .. " containers soured, "
			.. math.floor(stats.litres + 0.5) .. " L")
		firstReport = false
	end
	stats.spoiled, stats.litres = 0, 0
end

Events.EveryOneMinute.Add(everyMinute)
