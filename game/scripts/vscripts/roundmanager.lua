if RoundManager == nil then
	print ( 'creating round manager' )
	RoundManager = {}
	RoundManager.__index = RoundManager
end

function RoundManager:new( o )
	o = o or {}
	setmetatable( o, RoundManager )
	return o
end

require("events/base_event")

EVENTS_PER_RAID = 3
RAIDS_PER_ZONE = 4
ZONE_COUNT = 2

POSSIBLE_ZONES = {"Sepulcher", "Grove"}

COMBAT_CHANCE = 60
ELITE_CHANCE = 20
EVENT_CHANCE = 100 - COMBAT_CHANCE

PREP_TIME = 15

ELITE_ABILITIES_TO_GIVE = 1

function RoundManager:Initialize()
	RoundManager = self
	self.bossPool = LoadKeyValues('scripts/kv/boss_pool.txt')
	self.eventPool = LoadKeyValues('scripts/kv/event_pool.txt')
	self.combatPool = LoadKeyValues('scripts/kv/combat_pool.txt')

	self.zones = {}
	self.eventsFinished = 0
	local zonesToSpawn = ZONE_COUNT
	for i = 1, ZONE_COUNT do
		local zoneID = RandomInt(1, #POSSIBLE_ZONES)
		local zoneName = POSSIBLE_ZONES[zoneID]
		table.remove(POSSIBLE_ZONES, zoneID)
		RoundManager:ConstructRaids(zoneName)
		if zonesToSpawn <= 0 then
			break
		end
	end
	
	self.eventsCreated = nil
	
	self.spawnPositions = {}
	for _,spawnPos in ipairs(Entities:FindAllByName("boss_spawner")) do
		table.insert( self.spawnPositions, spawnPos:GetAbsOrigin() )
	end
	
	ListenToGameEvent( "npc_spawned", Dynamic_Wrap( RoundManager, "OnNPCSpawned" ), self )
	ListenToGameEvent( "dota_holdout_revive_complete", Dynamic_Wrap( RoundManager, 'OnHoldoutReviveComplete' ), self )
end

function RoundManager:OnNPCSpawned(event)
	Timers:CreateTimer(function()
		local spawnedUnit = EntIndexToHScript( event.entindex )
		
		if not spawnedUnit 
		or spawnedUnit:IsPhantom() 
		or spawnedUnit:GetClassname() == "npc_dota_thinker" 
		or spawnedUnit:GetUnitName() == "" 
		or spawnedUnit:IsFakeHero() 
		or spawnedUnit:GetUnitName() == "npc_dummy_unit" 
		or spawnedUnit:GetUnitName() == "npc_dummy_blank" then
			return
		end
		if spawnedUnit then
			if spawnedUnit:IsCreature() then
				AddFOWViewer(DOTA_TEAM_GOODGUYS, spawnedUnit:GetAbsOrigin(), 516, 3, false) -- show spawns
				if spawnedUnit:IsRoundBoss() then
					ParticleManager:FireParticle("particles/econ/events/nexon_hero_compendium_2014/blink_dagger_end_nexon_hero_cp_2014.vpcf", PATTACH_POINT_FOLLOW, spawnedUnit)
					EmitSoundOn("DOTA_Item.BlinkDagger.NailedIt", spawnedUnit)
				end
				if not spawnedUnit.hasBeenInitialized then
					RoundManager:InitializeUnit(spawnedUnit, spawnedUnit:IsRoundBoss() and RoundManager:GetCurrentEvent():IsElite() )
					GridNav:DestroyTreesAroundPoint(spawnedUnit:GetAbsOrigin(), spawnedUnit:GetHullRadius() + spawnedUnit:GetCollisionPadding() + 350, true)
					FindClearSpaceForUnit(spawnedUnit, spawnedUnit:GetAbsOrigin(), true)
				end
			elseif spawnedUnit:IsRealHero() then
				spawnedUnit:AddNewModifier(spawnedUnit, nil, "modifier_tombstone_respawn_immunity", {duration = 3})
			end
		end
	end)
end

function RoundManager:OnHoldoutReviveComplete( event )
	local castingHero = EntIndexToHScript( event.caster )
	local target = EntIndexToHScript( event.target )
	
	if castingHero then
		castingHero.Resurrections = (castingHero.Resurrections or 0) + 1
		target:AddNewModifier(target, nil, "modifier_tombstone_respawn_immunity", {duration = 3})
		castingHero:AddGold(self._nRoundNumber)
	end
	target.tombstoneEntity = nil
end

function RoundManager:RollRandomEvent(zoneName, eventType)
	local eventPool = {}
	local eventTypeName = ""
	if eventType == EVENT_TYPE_COMBAT or eventType == EVENT_TYPE_ELITE then
		eventTypeName = "combat"
	elseif eventType == EVENT_TYPE_EVENT then
		eventTypeName = "event"
	else
		eventTypeName = "boss"
	end
	for event, weight in pairs( MergeTables(self[eventTypeName.."Pool"][zoneName], self[eventTypeName.."Pool"]["Generic"]) ) do
		for i = 1, weight do
			table.insert(eventPool, event)
		end
	end
	
	return BaseEvent(zoneName, eventType, eventPool[RandomInt(1, #eventPool)] )
end

function RoundManager:ConstructRaids(zoneName)
	self.zones[zoneName] = {}
	
	local bossPool = {}
	local eventPool = {}
	local combatPool = {}
	
	self.eventsCreated = self.eventsCreated or 0
	
	for event, weight in pairs( MergeTables(self.bossPool[zoneName], self.bossPool["Generic"]) ) do
		for i = 1, weight do
			table.insert(bossPool, event)
		end
	end
	
	for event, weight in pairs( MergeTables(self.eventPool[zoneName], self.eventPool["Generic"]) ) do
		for i = 1, weight do
			table.insert(eventPool, event)
		end
	end
	
	for event, weight in pairs( MergeTables(self.combatPool[zoneName], self.combatPool["Generic"]) ) do
		for i = 1, weight do
			table.insert(combatPool, event)
		end
	end
	for j = 1, RAIDS_PER_ZONE do
		local raid = {}
		local raidContent
		for i = 1, EVENTS_PER_RAID do
			if RollPercentage(COMBAT_CHANCE) or not eventPool[1] then -- Rolled Combat
				local combatType = EVENT_TYPE_COMBAT
				if RollPercentage(ELITE_CHANCE) and self.eventsCreated > 3 then
					combatType = EVENT_TYPE_ELITE
				end
				raidContent = BaseEvent(zoneName, combatType, combatPool[RandomInt(1, #combatPool)] )
			else -- Event
				local eventPick = RandomInt(1, #eventPool)
				raidContent = BaseEvent(zoneName, EVENT_TYPE_EVENT, eventPool[eventPick] )
				table.remove( eventPool, eventPick )
			end
			table.insert( raid, raidContent )
			self.eventsCreated = self.eventsCreated + 1
		end
		local bossRoll = RandomInt(1, #bossPool)
		local bossPick = bossPool[bossRoll]
		RoundManager:RemoveEventFromPool(bossPick, "boss")
		table.remove(bossPool, bossRoll)
		table.insert( raid, BaseEvent(zoneName, EVENT_TYPE_BOSS, bossPick ) )
		
		table.insert( self.zones[zoneName], raid )
	end
end

function RoundManager:RemoveEventFromPool(eventToRemove, pool)	
	for zone, zoneEvents in pairs( self[pool.."Pool"] ) do
		for event, weight in pairs( zoneEvents ) do
			if event == eventToRemove then
				zoneEvents[eventToRemove] = nil
			end
		end
	end
end

function RoundManager:StartGame()
	local selection = {}
	for zoneName, _ in pairs( self.zones ) do
		table.insert(selection, zoneName)
	end
	self.currentZone = selection[RandomInt(1, #selection)]
	
	RoundManager:StartPrepTime()
end

function RoundManager:StartPrepTime(fPrep)
	if self.zones[self.currentZone] and self.zones[self.currentZone][1] and not self.prepTimeTimer then
		local event = self.zones[self.currentZone][1][1]
		for _, hero in ipairs( HeroList:GetRealHeroes() ) do
			PlayerResource:SetCustomBuybackCost(hero:GetPlayerID(), 100 + self.eventsFinished * 25)
		end
		if event and not event.precacheComplete then
			event.precacheComplete = event:PrecacheUnits()
		end
		
		local timer = fPrep or PREP_TIME
		local textFormatting = RAIDS_PER_ZONE - #self.zones[self.currentZone] + 1
		local romanVersion = ""
		if textFormatting < 4 then
			for i = 1, textFormatting do
				romanVersion = romanVersion.."I"
			end
		elseif textFormatting == 4 then
			romanVersion = "IV"
		else
			textFormatting = textFormatting - 5
			romanVersion = "V"
			if textFormatting > 0 then
				for i = textFormatting, 3 do
					romanVersion = romanVersion.."I"
				end
			end
		end
		CustomGameEventManager:Send_ServerToAllClients( "updateQuestRound", { eventName = RoundManager:GetCurrentEventName(), roundText = self.currentZone.." "..romanVersion } )
		self.prepTimeTimer = Timers:CreateTimer(1, function()
			timer = timer - 1
			CustomGameEventManager:Send_ServerToAllClients( "updateQuestPrepTime", { prepTime = math.floor(timer + 0.5) } )
			if timer <= 0 then
				
				RoundManager:EndPrepTime()
			else
				return 1
			end
		end)
	end
end

function RoundManager:EndPrepTime(bReset)
	print("Starting event", self:GetCurrentEvent():GetEventName(), self:GetCurrentEvent():IsElite() )
	if self.prepTimeTimer then Timers:RemoveTimer( self.prepTimeTimer ) end
	self.prepTimeTimer = nil
	CustomGameEventManager:Send_ServerToAllClients("boss_hunters_prep_time_has_ended", {})
	if not bReset then
		RoundManager:StartEvent()
	end
end

function RoundManager:StartEvent()
	GameRules:RefreshPlayers()
	EmitGlobalSound("Round.Start")
	
	local playerData = {}
	for _, hero in ipairs ( HeroList:GetAllHeroes() ) do
		if not hero:IsFakeHero() then
			playerData[hero:GetPlayerID()] = {DT = hero.statsDamageTaken or 0, DD = hero.statsDamageDealt or 0, DH = hero.statsDamageHealed or 0}
		end
	end
	CustomGameEventManager:Send_ServerToAllClients( "player_update_stats", playerData )
	
	if self.zones[self.currentZone] and self.zones[self.currentZone][1] and self.zones[self.currentZone][1][1] then
		local event = RoundManager:GetCurrentEvent()
		event.eventHasStarted = true
		event.eventEnded = false
		event:StartEvent()
		return true
	else
		RoundManager:GameIsFinished()
		return false
	end
end

function RoundManager:EndEvent(bWonRound)
	GameRules:RefreshPlayers()
	CustomGameEventManager:Send_ServerToAllClients("boss_hunters_event_has_ended", {})
	local event = self.zones[self.currentZone][1][1]
	event.eventEnded = true
	event.eventHasStarted = false
	if event.eventHandler then Timers:RemoveTimer( event.eventHandler ) end
	if event then
		if bWonRound then
			EventManager:FireEvent("boss_hunters_event_finished", {eventType = event:GetEventType()})
			event:HandoutRewards(true)
			self.zones[self.currentZone][1][1] = false
			UTIL_Remove( event )
			table.remove( self.zones[self.currentZone][1], 1 )
			
			self.eventsFinished = self.eventsFinished + 1
			if self.zones[self.currentZone][1][1] == nil then RoundManager:RaidIsFinished() end
			EmitGlobalSound("Round.Won")
		else
			GameRules._lives = GameRules._lives - 1
			event:HandoutRewards(false)
			EmitGlobalSound("Round.Lost")
		end
	end
	
	local clearPeriod = 3
	Timers:CreateTimer(function()
		for _, unit in ipairs( FindAllUnits({team = DOTA_UNIT_TARGET_TEAM_ENEMY}) ) do
			if unit:IsCreature() then
				unit:ForceKill(false)
			end
		end
		clearPeriod = clearPeriod - 0.1
		if clearPeriod > 0 then
			return 0.1
		end
	end)
	local fTime = PREP_TIME
	if RoundManager:GetCurrentEvent():IsEvent() then
		fTime = 5
	end
	CustomGameEventManager:Send_ServerToAllClients( "updateQuestLife", { lives = GameRules._lives, maxLives = GameRules._maxLives } )
	if GameRules._lives == 0 then
		return RoundManager:GameIsFinished()
	end
	self:StartPrepTime(fTime)
end

function RoundManager:RaidIsFinished()
	table.remove( self.zones[self.currentZone], 1 )
	EventManager:FireEvent("boss_hunters_raid_finished")
	self.raidsFinished = (self.raidsFinished or 0) + 1
	if self.zones[self.currentZone][1] == nil then RoundManager:ZoneIsFinished() end
end

function RoundManager:ZoneIsFinished()
	self.zones[self.currentZone] = nil
	self.currentZone = nil
	
	local selection = {}
	for zoneName, _ in pairs( self.zones ) do
		table.insert(selection, zoneName)
	end
	self.currentZone = selection[RandomInt(1, #selection)]
	EventManager:FireEvent("boss_hunters_game_finished")
	self.zonesFinished = (self.zonesFinished or 0) + 1
	if self.currentZone == nil then
		RoundManager:GameIsFinished()
	end
end

function RoundManager:GameIsFinished(bWon)
	EventManager:FireEvent("boss_hunters_event_finished")
	if bWon then
		GameRules:SetCustomVictoryMessage ("Congratulations!")
		GameRules:SetGameWinner(DOTA_TEAM_GOODGUYS)
		GameRules.Winner = DOTA_TEAM_GOODGUYS
	else
		GameRules:SetCustomVictoryMessage ("Congratulations!")
		GameRules:SetGameWinner(DOTA_TEAM_BADGUYS)
		GameRules.Winner = DOTA_TEAM_BADGUYS
	end
	GameRules._finish = true
	GameRules.EndTime = GameRules:GetGameTime()
	statCollection:submitRound(true)
end

function RoundManager:GetCurrentEvent()
	return self.zones[self.currentZone][1][1]
end

function RoundManager:PickRandomSpawn()
	return self.spawnPositions[RandomInt(1, #self.spawnPositions)]
end

function RoundManager:EvaluateLoss()
	for _, hero in ipairs( HeroList:GetRealHeroes() ) do
		if hero:NotDead() then return false end
	end
	return true
end

function RoundManager:GetEventsFinished()
	return self.eventsFinished or 0
end

function RoundManager:GetRaidsFinished()
	return self.raidsFinished or 0
end

function RoundManager:GetZonesFinished()
	return self.zonesFinished or 0
end

function RoundManager:GetCurrentEventName()
	return self.zones[self.currentZone][1][1]:GetEventName()
end

function RoundManager:GetCurrentZone()
	return self.currentZone
end

function RoundManager:IsRoundGoing()
	return self:GetCurrentEvent():HasStarted()
end

function RoundManager:InitializeUnit(unit, bElite)
	unit.hasBeenInitialized = true
	local expectedHP = unit:GetBaseMaxHealth() * RandomFloat(0.9, 1.15)
	local playerHPMultiplier = 0.35
	local playerDMGMultiplier = 0.06
	if GameRules:GetGameDifficulty() == 4 then 
		expectedHP = expectedHP * 1.35
		playerHPMultiplier = 0.5 
		playerDMGMultiplier = 0.09
	end
	local effective_multiplier = (HeroList:GetActiveHeroCount() - 1) 
	local effPlayerHPMult = ( 1 + (RoundManager:GetEventsFinished() * 0.08) + (RoundManager:GetRaidsFinished() * 0.33) ) + effective_multiplier * playerHPMultiplier
	local effPlayerDMGMult = ( 0.8 + (RoundManager:GetEventsFinished() * 0.04) + (RoundManager:GetRaidsFinished() * 0.40) ) + effective_multiplier * playerDMGMultiplier
	
	if bElite then
		effPlayerHPMult = effPlayerHPMult * 1.35
		effPlayerDMGMult = effPlayerDMGMult * 1.2
		
		
		local nParticle = ParticleManager:CreateParticle( "particles/econ/courier/courier_onibi/courier_onibi_yellow_ambient_smoke_lvl21.vpcf", PATTACH_ABSORIGIN_FOLLOW, unit )
		ParticleManager:ReleaseParticleIndex( nParticle )
		
		unit:SetHealth(unit:GetMaxHealth())
		unit:SetModelScale(unit:GetModelScale()*1.15)
		
		local eliteTypes = {}
		for eliteType, activated in pairs(GameRules._Elites) do
			if activated ~= "0" then
				table.insert(eliteTypes, eliteType)
			end
		end
		
		for i = 1, ELITE_ABILITIES_TO_GIVE do
			local roll = RandomInt(1, #eliteTypes)
			local eliteAbName = eliteTypes[roll]
			table.remove(eliteTypes, roll)
			local eliteAb = unit:AddAbilityPrecache(eliteAbName)
			eliteAb:SetLevel(eliteAb:GetMaxLevel())
		end
	end
	
	expectedHP = expectedHP * effPlayerHPMult
	unit:SetBaseMaxHealth(expectedHP)
	unit:SetMaxHealth(expectedHP)
	unit:SetHealth(expectedHP)
	
	unit:SetAverageBaseDamage(unit:GetAverageBaseDamage() * effPlayerDMGMult * RandomFloat(0.85, 1.15) + self.eventsFinished, 35)
	unit:SetBaseHealthRegen(self.eventsFinished * RandomFloat(0.85, 1.15) )
	unit:SetBaseHealthRegen(self.eventsFinished * RandomFloat(0.85, 1.15) )
	
	unit:AddNewModifier(unit, nil, "modifier_boss_attackspeed", {})
	unit:AddNewModifier(unit, nil, "modifier_power_scaling", {}):SetStackCount(self.eventsFinished)
	unit:AddNewModifier(unit, nil, "modifier_spawn_immunity", {duration = 4/GameRules.gameDifficulty})
	
	if unit:GetHullRadius() >= 16 then
		unit:SetHullRadius( math.ceil(16 * unit:GetModelScale()) )
	end
	
	unit:SetMaximumGoldBounty(0)
	unit:SetMinimumGoldBounty(0)
	unit:SetDeathXP(0)
end