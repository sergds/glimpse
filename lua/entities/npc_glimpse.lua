-- Glimpse NextBot
-- Based on Inside The Backrooms Smiler's behaviour.
-- Appears in dark/not seen, reachable areas. Waits glimpse_staretime in that place for a victim and them picks a new place.
-- While seen by a player, the glimpse will deplete player's health. (psychic damage)
-- If touched by a player, player will be killed (dissolved) if glimpse_lethal_touch is set to 1 
--
-- SergDS (C) 2024

AddCSLuaFile()

ENT.Base 			= "base_nextbot"
ENT.Spawnable		= true
ENT.Author          = "SergDS"
ENT.AutomaticFrameAdvance = true

-- Common
local LoseTargetDist = 3000
local SearchRadius = 2000
--

-- CVars
local glimpse_debug = CreateConVar("glimpse_debug", "0", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "Print debug messages to console, as well as enable debug objects drawing. CVar's Integer also defines the log level: 1 - Most messages; 2 - Performance timing traces")
local glimpse_staretime = CreateConVar("glimpse_staretime", "10", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "How long does it take for Glimpse to disappear and migrate to a new dark/unseen place. In seconds.")
local glimpse_staretime_multiplier = CreateConVar("glimpse_staretime_multiplier", "10", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "Affects the rate of idletime depletion during stare.")
local glimpse_debug_noai = CreateConVar("glimpse_debug_noai", "0", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "All Glimpse on map stop thinking and just stand lobotomized. AKA No thoughts, head empty mode. Useful for artistic screenshoting and stuff.")
local glimpse_immortal = CreateConVar("glimpse_immortal", "0", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "All Glimpse are immortal, HP-wise affects only newly spawned Glimpse (after CVar was set). IMO not that interesting if you can't just punch it in the face and kill it.")
local glimpse_health = CreateConVar("glimpse_health", "10", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "Health of all new Glimpse.")
local glimpse_damage = CreateConVar("glimpse_damage", "1", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "Amount of psychic damage dealt by glimpse every damage tick.")
local glimpse_damage_rate = CreateConVar("glimpse_damage_rate", "0.3", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "Delay between psychic damage.")
local glimpse_lethal_touch = CreateConVar("glimpse_lethal_touch", "1", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "Makes glimpse lethal to touch.")
local glimpse_damage_rate_viewangle_multiplier = CreateConVar("glimpse_damage_rate_viewangle_multiplier", "0.1", {FCVAR_GAMEDLL, FCVAR_REPLICATED, FCVAR_ARCHIVE}, "if > 0, Damage rate is faster, the more directly you look at the glimpse. Higher values makes this damage boost more severe.")
--

if CLIENT then
    killicon.Add("npc_glimpse", "materials/glimpse/glimpse.png", color_white)
end

function ENT:dPrint(msg, func, tracelevel)
    -- Debug Print
    if (glimpse_debug:GetInt() < tracelevel) then
        return
    end
    if (glimpse_debug:GetBool() or tracelevel == 0) then
        print("[npc_glimpse][".. self:GetCreationID() .."]->".. func ..": " .. msg)
    end
end

function ENT:Initialize()
    self:SetSpawnEffect(false)
    self:SetRenderMode(RENDERMODE_TRANSALPHA)
	self:SetColor(Color(255, 255, 255, 1))
    if (glimpse_immortal:GetBool()) then
        self:SetHealth(1e8)
    else
        self:SetHealth(glimpse_health:GetInt())
    end
    self:SetCollisionBounds(Vector(-13, -13, 0), Vector(13, 13, 72))

    self.isVisible = true
    self.targetPly = nil -- TODO: Unused. Remove.
    self.prevNode = Vector(0,0,0)
    self.curNode = Vector(0,0,0)
    self.failedLastSearch = false
    self.failedLastSearch2 = false
    self.stareTimer = glimpse_staretime:GetFloat()
    self.lastVel = Vector(0,0,0) -- For lookdir simulation for door interaction. TODO: Now Unused. Remove.
    self.lastInter = CurTime()
    self.dmgTimer = glimpse_damage_rate:GetFloat() -- Damage every this seconds.
    self.damage = glimpse_damage:GetInt()


    self.isVisible = true
end

-- Rendering
local mat = Material("materials/glimpse/glimpse.png", "mips")
local drawOffset = Vector(0, 0, 64)
local prevNodeColor = Color(1,0,0,1)
local curNodeColor = Color(0,1,0,1)
--

function ENT:RenderOverride()
    if (self:GetVelocity():LengthSqr() > 10) then
        if (glimpse_debug:GetBool()) then
            render.DrawBox(self:GetPos() + drawOffset, Angle(0,0,0), Vector(0,0,0), Vector(42,30,30), color_black)
        end
        return
    end
    render.SetMaterial(mat)
    render.DrawSprite(self:GetPos() + drawOffset, 42, 30)
end

local function VecAngle2D(vec1, vec2) -- some expensive shit
    local theta = (math.acos((vec1.x * vec2.x + vec1.y * vec2.y)/(math.sqrt(vec1.x*vec1.x + vec1.y*vec1.y)*math.sqrt(vec2.x*vec2.x + vec2.y*vec2.y))))
    -- print(theta * 180/math.pi) -- to check if i suck at math (i do, so don't)
    return theta * 180/math.pi -- return in degrees, because imo radians suck.
end

function ENT:Think() -- cogito ergo sum
    -- CVar update
    self.damage = glimpse_damage:GetInt()
    --
    
    if (self:GetVelocity():LengthSqr() > 10) then
        self.lastVel = self:GetVelocity()
    end
    -- React to health.
    if (self:Health() <= 0 and !glimpse_immortal:GetBool()) then
        self:Remove()
    end
    local stareTimeModified = false
    if (self.isVisible) then -- Damage players with eyes, seeing us.
        local ply = player.GetAll()
        for _, v in pairs(ply) do
            local glimpseAndMeLookinAngle = VecAngle2D((self:GetPos() - v:GetPos()), v:GetAimVector())
            if v:IsLineOfSightClear(self) and glimpseAndMeLookinAngle < v:GetFOV() - v:GetFOV() * 0.37 then
                if self.dmgTimer > 0 then
                    if glimpse_damage_rate_viewangle_multiplier:GetFloat() > 0 then
                        if SERVER then
                            -- self:dPrint("ViewAngle Psychic damage to player: " .. (((v:GetFOV() - v:GetFOV() * 0.37) - glimpseAndMeLookinAngle) * glimpse_damage_rate_viewangle_multiplier:GetFloat()), "Think", 2)
                        end
                        self.dmgTimer = self.dmgTimer - FrameTime() * (((v:GetFOV() - v:GetFOV() * 0.37) - glimpseAndMeLookinAngle) * glimpse_damage_rate_viewangle_multiplier:GetFloat()) -- damage rate should depend on view angle
                    else
                        self.dmgTimer = self.dmgTimer - FrameTime()
                    end
                    return
                else
                    self.dmgTimer = glimpse_damage_rate:GetFloat() -- Restore full dmg rate.
                end
                stareTimeModified = true
                self.stareTimer = self.stareTimer - FrameTime() * glimpse_staretime_multiplier:GetFloat() -- nom
                if SERVER then
                    local dmg = DamageInfo()
                    dmg:SetDamage(glimpse_damage:GetInt())
                    dmg:SetDamageType(DMG_NERVEGAS)
                    dmg:SetAttacker(self)
                    dmg:SetInflictor(self)
                    v:TakeDamageInfo(dmg)
                end
            end
        end
    end
    if (self.isVisible) then
        self.stareTimer = self.stareTimer - FrameTime()
    end
    if SERVER then
        self:dPrint("stare timer: " .. self.stareTimer, "Think", 2)
    end
end

function ENT:OnStuck()
    if CurTime() - self.lastInter < 1 then
        return
    end
    self.lastInter = CurTime()
    self:dPrint("Fck i'm stuck", "OnStuck", 2)
    -- let's see if there's a door on our way...
    local letmesee = {}
    table.insert(letmesee, 1, {
        mask = MASK_SOLID,
        start = self:GetPos() + drawOffset,
        endpos = self:GetPos() + drawOffset + Vector(1,0,0)*50,
        filter = {self}
    })
    table.insert(letmesee, 2, {
        mask = MASK_SOLID,
        start = self:GetPos() + drawOffset,
        endpos = self:GetPos() + drawOffset + Vector(-1,0,0)*50,
        filter = {self}
    })
    table.insert(letmesee, 3, {
        mask = MASK_SOLID,
        start = self:GetPos() + drawOffset,
        endpos = self:GetPos() + drawOffset + Vector(0,1,0)*50,
        filter = {self}
    })
    table.insert(letmesee, 4, {
        mask = MASK_SOLID,
        start = self:GetPos() + drawOffset,
        endpos = self:GetPos() + drawOffset + Vector(0,-1,0)*50,
        filter = {self}
    })
    for _, v in pairs(letmesee) do
        local tr = util.TraceLine(v)
        if tr.Entity != NULL then
            if (tr.Entity:GetClass() == "prop_door_rotating" or tr.Entity:GetClass() == "func_door_rotating") then
                self:dPrint("fkin door", "OnStuck", 1)
                tr.Entity:Use(self, self, USE_ON, 1)
                break
            end
        end
    end
end

function ENT:OnContact(e)
    if (e:IsPlayer() and glimpse_lethal_touch:GetBool()) then
        self.stareTimer = 0 -- Instantly migrate to a new place.
        local dmg = DamageInfo() -- Create a server-side damage information class
        dmg:SetDamage(10000)
        dmg:SetAttacker(self)
        dmg:SetInflictor(self)
        dmg:SetDamageType(DMG_DISSOLVE)
        dmg:SetDamageForce((e:GetPos() - self:GetPos()) * 3000)
        e:TakeDamageInfo(dmg)
    end
end

function ENT:DistToAnotherGlimpse(point)
    local closest = 100000000000
    for _, ent in ents.Iterator() do
        if (ent:GetClass() == "npc_glimpse" and self:GetCreationID() != ent:GetCreationID()) then
            if (ent:GetPos() - point):LengthSqr() < closest then
                closest = (ent:GetPos() - point):LengthSqr()
            end
        end
    end
    return closest
end

function ENT:SetEnemy(ent)
	self.Enemy = ent
end
function ENT:GetEnemy()
	return self.Enemy
end

-- GMod Wiki sample code, lol.
function ENT:HaveEnemy()
	-- If our current enemy is valid
	if ( self:GetEnemy() and IsValid(self:GetEnemy()) ) then
		-- If the enemy is too far
		if ( self:GetRangeTo(self:GetEnemy():GetPos()) > LoseTargetDist ) then
			-- If the enemy is lost then call FindEnemy() to look for a new one
			-- FindEnemy() will return true if an enemy is found, making this function return true
			return self:FindEnemy()
		-- If the enemy is dead( we have to check if its a player before we use Alive() )
		elseif ( self:GetEnemy():IsPlayer() and !self:GetEnemy():Alive() ) then
			return self:FindEnemy()		-- Return false if the search finds nothing
		end	
		-- The enemy is neither too far nor too dead so we can return true
		return true
	else
		-- The enemy isn't valid so lets look for a new one
		return self:FindEnemy()
	end
end

function ENT:FindEnemy()
    local tStart = SysTime()
	-- Search around us for entities
	-- This can be done any way you want eg. ents.FindInCone() to replicate eyesight
	local _ents = ents.FindInSphere( self:GetPos(), SearchRadius )
	-- Here we loop through every entity the above search finds and see if it's the one we want
	for k,v in ipairs( _ents ) do
		if ( v:IsPlayer() ) then
			-- We found one so lets set it as our enemy and return true
			self:SetEnemy(v)
            self:dPrint("Evaluated in " .. SysTime() - tStart, "FindEnemy", 2)
            return true
		end
	end	
	-- We found nothing so we will set our enemy as nil (nothing) and return false
	self:SetEnemy(nil)
    self:dPrint("Evaluated in " .. SysTime() - tStart, "FindEnemy", 2)
	return false
end

local function isPointSeen(point) -- point can be an entity
    local tStart = SysTime()
    for _, ply in pairs(player.GetAll()) do
        if (IsValid(ply) and ply:Alive() and ply:IsLineOfSightClear(point)) then
            if (SysTime() - tStart > 0.005) then -- Don't flood console to crash with small values
                self:dPrint("Evaluated in " .. SysTime() - tStart, "isPointSeen", 2)
            end
            return true
        end
        if (SysTime() - tStart > 0.005) then -- Don't flood console to crash with small values
            self:dPrint("Evaluated in " .. SysTime() - tStart, "isPointSeen", 2)
        end
        return false
    end
end

local trace = {
	mask = MASK_SOLID
}

function ENT:IsSpaceOccupied(point)
    trace.start = point + Vector(0, 0, 2) -- Slightly above floor.
	trace.endpos = point + Vector(0, 0, 70)
    trace.filter = {self}

	local tr = util.TraceLine(trace)

	return tr.Hit
end

function ENT:FindStandSpot(mypos, from) -- from is not always mypos!
    local tStart = SysTime()
    local areas = navmesh.Find(from, 5000, 16000, 16000)
    -- Debug counters
    local dbg_cnt = 0
    local dbg_seennum = 0
    local dbg_samenavareanum = 0
    local dbg_tooclosenum = 0
    local dbg_occupiednum = 0
    local dbg_friendtooclosenum = 0
    for _, area in pairs(areas) do
        dbg_cnt = dbg_cnt + 1
        local dist = (mypos - area:GetCenter()):LengthSqr()
        if (!isPointSeen(area:GetCenter() + drawOffset) and navmesh.GetNavArea(mypos, 1000) != area and dist > 400000 and self:DistToAnotherGlimpse(area:GetCenter()) > 400000) then
            if self.prevNode != nil then
                if (self.prevNode == area) then
                    dbg_samenavareanum = dbg_samenavareanum + 1
                    continue
                end
            end
            if (self.curNode != nil) then
                if (self.curNode == area) then
                    dbg_samenavareanum = dbg_samenavareanum + 1
                    continue
                end
            end
            if (self:IsSpaceOccupied(area:GetCenter())) then
                dbg_occupiednum = dbg_occupiednum + 1
                continue
            end
            self:dPrint("distance to new node " .. dist, "findStandSpot", 1)
            self.prevNode = self.curNode
            self.curNode = area:GetCenter()
            self:dPrint("Evaluated in " .. SysTime() - tStart, "findStandSpot", 2)
            return area:GetCenter()
        else
            if (self:DistToAnotherGlimpse(area:GetCenter()) < 400000) then
                dbg_friendtooclosenum = dbg_friendtooclosenum + 1
                continue
            end
            if (isPointSeen(area:GetCenter() + drawOffset) ) then
                dbg_seennum = dbg_seennum + 1
                continue
            end
            if (dist < 400000) then
                dbg_tooclosenum = dbg_tooclosenum + 1
                continue
            end
        end
    end
    self:dPrint("Evaluated in " .. SysTime() - tStart, "findStandSpot", 2)
    self:dPrint("error: search exhausted with " .. dbg_cnt .. " options", "findStandSpot", 0)
    self:dPrint("[postmortem] failure reasons: [PointSeen: ".. dbg_seennum .." ] [SameNavArea: ".. dbg_samenavareanum .."] [TooClose: ".. dbg_tooclosenum .."] [SpaceOccupied: ".. dbg_occupiednum .."] [FriendTooClose: ".. dbg_friendtooclosenum .."]", "findStandSpot", 0)
    if (dbg_seennum > 5 and dbg_tooclosenum >= 2) then
        self:dPrint("your map MAY BE too small and/or open for glimpse to work properly :/ ...", "findStandSpot", 0)
    end
    return nil
end

function ENT:RunBehaviour()
    local iterSinceYield = 0 -- Iterations since last yield. Last guard against any infinite loops, in theory...
    while ( true ) do
        while (glimpse_debug_noai:GetBool()) do
            iterSinceYield = 0
            coroutine.yield()
        end
        if (iterSinceYield >= 20) then
            self:dPrint("Thought for too long. Defusing myself!", "RunBehaviour", 1)
            PrintMessage(HUD_PRINTTALK, "Glimpse[".. self:GetCreationID() .."] was removed, because of an infinite loop! Try a better place to spawn, or generate a navmesh if missing!")
            self:Remove()
            return
        end
        self.isVisible = false
		self:StartActivity( ACT_WALK )
        self:SetCollisionGroup(COLLISION_GROUP_WORLD)
        self.loco:SetJumpHeight(1000)
		self.loco:SetDesiredSpeed(500)
        self.loco:SetAcceleration(10000)
        self.loco:SetDeceleration(10000)
        local refpoint = nil
        if (self:HaveEnemy() and !self.failedLastSearch) then
            -- Have enemy(victim)? Use foe as a refpoint.
            self:dPrint("I Have a potential victim >:]", "RunBehaviour", 1)
            refpoint = Vector(self:GetEnemy():GetPos())
        else
            -- Have no enemy? Use me as a refpoint.
            self:dPrint("Have no enemies :D (Or failed last search with enemy pos)", "RunBehaviour", 1)
            refpoint = self:GetPos()
        end
        local pos = self:FindStandSpot(self:GetPos(), refpoint)
        if (pos != nil and !self.failedLastSearch2) then
            self:dPrint("found unseen point! Moving!", "RunBehaviour", 1)
            self.failedLastSearch = false
            self.failedLastSearch2 = false
            self:MoveToPos(pos)
        else
            if self.failedLastSearch then -- everything failed? fucking awesome, because now we have to work around infinite loop in the most lame way possible.
                self.failedLastSearch2 = true
            end
            if (self:HaveEnemy() and !self.failedLastSearch) then -- With enemy we have to try again with our pos. Because, maybe enemy is just noclipping, and we are failing to this.\
                self:dPrint("Failed to find unseen point! But we have enemy, soooo trying my pos.", "RunBehaviour", 1)
                self.failedLastSearch = true
                iterSinceYield = iterSinceYield + 1
                continue
            end
            self:dPrint("Failed to find unseen point! Moving to a completely random pos in hope of better days... (ignoring navmesh!1!!).", "RunBehaviour", 1)
            self.failedLastSearch = false
            self.failedLastSearch2 = false
            self:dPrint("iter Since Yield: " .. iterSinceYield .. " ticks", "RunBehaviour", 1)
            self:MoveToPos(self:GetPos() + Vector( math.Rand( -1, 1 ), math.Rand( -1, 1 ), math.Rand( 0, 0.02 ) ) * 1000)
        end
        if ( self.loco:IsStuck() ) then
            self:dPrint("Unstuck!", "RunBehaviour", 1)
			self:HandleStuck()
		end
        if isPointSeen(self) then
            self:dPrint("Not appearing in a seen point! Finding AGAIN!", "RunBehaviour", 1)
            iterSinceYield = iterSinceYield + 1
            continue
        end
        if (self:IsSpaceOccupied(self:GetPos())) then
            self:dPrint("Somebody is here. Moving away!", "RunBehaviour", 1)
            iterSinceYield = iterSinceYield + 1
            continue
        end
        if (self:DistToAnotherGlimpse(self:GetPos()) < 400000) then
            self:dPrint("My bro is here! Moving away!", "RunBehaviour", 1)
            iterSinceYield = iterSinceYield + 1
            continue
        end
        self:dPrint("Move complete! Checks passed! Appearing!", "RunBehaviour", 1)
        self.stareTimer = glimpse_staretime:GetFloat()
        self:StartActivity( ACT_IDLE )
        self:SetCollisionGroup(COLLISION_GROUP_NPC)
        self.isVisible = true
        while (self.stareTimer > 0) do
            if (iterSinceYield > 0) then
                self:dPrint("Yield after " .. iterSinceYield .. " ticks", "RunBehaviour", 1)
            end
            iterSinceYield = 0
            coroutine.yield()
        end
	end
end

list.Set("NPC", "npc_glimpse", {
	Name = "Glimpse",
	Class = "npc_glimpse",
	Category = "SergDS NextBots",
	AdminOnly = false
})