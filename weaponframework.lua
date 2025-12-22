-- Weapon Framework Application

--[[
 I decided to build a fully functional weapon system with OOP, recoil, ammo, raycasting etc as I think it would be the best 
 method for me to showcase my skills in the field. I wanted to try out using private state closures, while i could use __newindex metamethod 
 I went with the state table to keep the code clean and readable, I have used this method before and it works well.
]]--

-- Services
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Camera = Workspace.CurrentCamera
-- REMOTE EVENTS 
local ammoEvent = ReplicatedStorage:WaitForChild("AmmoChanged")
-- A damage signal to tell the server to damage a humanoid for demo purposes
local DamageHum = ReplicatedStorage:WaitForChild("DamageHum") 


local ViewModel = ReplicatedStorage.ViewModel -- Default ViewModel

local Weapon = {}
Weapon.__index = Weapon -- OOP

-- Private State Storage
local state = {}

-- Weapon Base Damage
local BASE_DAMAGE = 10
-- Distance for damage falloffs
local FALLOFF_START = 120 --// studs
local FALLOFF_END = 500 -- // studs

-- If headshot then do twice the damage
local HEADSHOT_MULTIPLIER = 2

-- Added a utility function to validate configuration values
local function validateConfig(config: any)
	assert(type(config) == "table", "Weapon config must be a table")
	assert(type(config.Magsize) == "number", "Magsize must be a number")
	assert(type(config.FireRate) == "number", "FireRate must be a number")
end

-- Constuctor
function Weapon.new(config: any) --// config data may include ammo, magSize, FireRate, etc
	validateConfig(config)
	local self = setmetatable({}, Weapon)
	
	-- Private Instance state for Data Encapsulation
	-- To avoid mutation of the original config data
	state[self] = {
		Ammo = config.Magsize or 10, --// To track the current ammo
		Magsize = config.Magsize or 40, --// Default mag size
		MaxAmmo = 200, --// Max ammo for the weapon
		Reloading = false, --// to track if the player is reloading
		LastFire = 0, --// to track when the player fires the gun
		RecoilIndex = 1, --// used for recoil
		SwayCF = CFrame.new(), --// Used for smooth movement/sway for ViewModel
		FireRate = config.FireRate or 0.2,
	}
	
	self.ViewModel = config.ViewModel or ViewModel
	self.Player = config.Player or nil --// To store the player
	self.Equipped = false --// to track if the weapon is equipped
	self.ClonedViewModel = nil --// To store the cloned viewmodel
	self.ViewModelOffset = nil --// For the offset of the viewmodel
	self.RenderConnection = nil --// To store the render connections
	self.LoadedAnimations = {} --// To store the loaded animations
	self.LoadedSounds = {} --// To store the loaded sounds
	 
	
	return self
end

-- Functions
function Weapon:Equip(player: Player)
	if self.Equipped then return end
	self.Equipped = true
	self.Player = player

	-- Clone ViewModel and store reference
	self.ClonedViewModel = self.ViewModel:Clone()
	self.ClonedViewModel.Name = "ViewModel"
	self.ClonedViewModel.Parent = Workspace.CurrentCamera
	self.ViewModelOffset = CFrame.new(0.25, -0.25, 0)

	-- Disable collisions for all parts of the viewmodel
	for _, part in pairs(self.ClonedViewModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end

	-- Align PrimaryPart with camera
	self.RenderConnection = RunService.RenderStepped:Connect(function()
		if self.ClonedViewModel and self.ClonedViewModel.PrimaryPart then
			local s = state[self]
	
			-- Smooth sway based on mouse delta 
			local mouseDelta = UserInputService:GetMouseDelta()/50 
			-- Clamped the mousedelta value to avoid any extreme sway on high DPI mouses
			local SwayX = math.clamp(mouseDelta.X, -.2, .2) 
			local SwayY = math.clamp(mouseDelta.Y, -.2, .2)
			s.SwayCF = s.SwayCF:Lerp(CFrame.new(SwayY, SwayX, 0), 0.3) -- Used :Lerp Instead for smoothness and preventing jitters
			
			-- I believe :PivotTo is preferred for model transforms
			-- But I am going to use :SetPrimaryCFrame for simplicity 
			self.ClonedViewModel:SetPrimaryPartCFrame(Camera.CFrame * self.ViewModelOffset * s.SwayCF)
		end
	end)
	
	local s = state[self]
	
	ammoEvent:Fire(s.Ammo, s.MaxAmmo)
	
	-- Load Animation & Sounds for the ViewModel upon equipping
	-- Load animations
	for _, anim in pairs(self.ClonedViewModel.Animations:GetChildren()) do
		local track = self.ClonedViewModel.AnimationController.Animator:LoadAnimation(anim)
		self.LoadedAnimations[anim.Name] = track
	end
	-- Load Sounds
	for _, sound in pairs(self.ClonedViewModel.Sounds:GetChildren()) do
		self.LoadedSounds[sound.Name] = sound
	end
end


function Weapon:Unequip(player: Player)
	if not self.Equipped then return end
	self.Equipped = false
	local s = state[self]
	
	-- Disconnect RenderStepped connection
	-- THIS IS IMPORTANT to prevent memory leaks
	if self.RenderConnection then
		self.RenderConnection:Disconnect()
		self.RenderConnection = nil
	end
	
	-- Destroy ViewModel
	if self.ClonedViewModel then
		self.ClonedViewModel:Destroy()
		self.ClonedViewModel = nil
	end
	
	self.Player = nil
	self.Mouse = nil
	s.Reloading = false
end

-- Damage Calculation with distance-based falloff
-- NOTE: This logic should only be applied in the server. The client should only send the direction and the server should calculate the damage based on the distance.
function Weapon:CalculateDamage(hitPart: BasePart, distance: number) -- For Demonstration, I am putting it right here.
	local damage = BASE_DAMAGE
	
	-- Apply distance-based damage falloff 
	if distance > FALLOFF_START then
		local alpha = math.clamp((distance - FALLOFF_START) / (FALLOFF_END - FALLOFF_START), 0, 1)
		damage = damage * (1 - alpha)
	end
	
	-- Apply headshot multiplier if the hit part is the head
	if hitPart.Name == "Head" then
		damage *= HEADSHOT_MULTIPLIER
	end
	
	-- Prevent no damage 
	return math.max(damage, 1) -- Applies minimum damage of 1 if extreme range
end

-- Function to create Visual Bullet Trails when firing
local function createbulletTrail(startPos, endPos)
	local trailPart = Instance.new("Part")
	trailPart.Anchored = true --// Anchored = true to prevent physics from affecting it
	trailPart.CanCollide = false --// // CanCollide = false to prevent it from colliding with other parts
	trailPart.Size = Vector3.new(.1, .1, (endPos - startPos).Magnitude) --// Size of the trail part, Z is the distance between start and end
	trailPart.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -trailPart.Size.Z/2) --// CFrame to look at the end position and place the trail in the middle
	trailPart.Material = Enum.Material.Neon 
	trailPart.BrickColor = BrickColor.new("Bright yellow")
	trailPart.Parent = Workspace --// Parent the trail part to Workspace
	trailPart.Transparency = 0.5 --// Transparency of the trail part

	game.Debris:AddItem(trailPart, 0.1) -- auto remove after .1s to prevent lag 
end

function Weapon:Fire(player, mouse)
	local s = state[self]
	if not self.Equipped or s.Reloading then return end
	
	local now = tick()
	
	-- Check if the player is firing too fast (Slight Delay)
	if now - s.LastFire < s.FireRate then return end
	
	if s.Ammo <= 0 then
		return
	end
	
	s.Ammo -= 1
	-- Fire this event to update the Ammo UI on the client-side
	ammoEvent:Fire(s.Ammo, s.MaxAmmo)
	s.LastFire = now
	
	-- Raycasting Logic (Switched to Spherecasting)
	local MouseTarget = mouse.Hit and mouse.Hit.Position
	if not MouseTarget then return end
	
	-- Get the muzzle part and its position of the gun for muzzle flash effects/VFX
	local MuzzlePoint = self.ClonedViewModel:FindFirstChild("MuzzlePoint")
	local muzzleStartPos = MuzzlePoint.Position
	
	local startPos = Camera.CFrame.Position
	local Range = 500
	local aimDirection = (MouseTarget - startPos).Unit
	local size = .3
	
	-- Raycast Params
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {self.ClonedViewModel, self.Player.Character} -- Avoids the ViewModel and the Player's Character
	params.IgnoreWater = true
	
	-- Used Spherecast instead of Raycast because it is more reliable and accurate.
	local result = Workspace:Spherecast(startPos, size, aimDirection * Range, params)
	
	if result then
		local hitPart = result.Instance
		local character = hitPart:FindFirstAncestorOfClass("Model")
		local humanoid = character and character:FindFirstChild("Humanoid")
		local distance = (result.Position - startPos).Magnitude -- Calculate distance
		local damage = self:CalculateDamage(hitPart, distance) -- Calculate damage based on distance
		
		-- Visualise the bullet trail
		createbulletTrail(muzzleStartPos, result.Position)
		
		if humanoid then
			-- Applying Damage on client-side is not recommended because it can be easily exploited.
			-- humanoid.Health -= damage (NOT IDEAL)
			-- BETTER WAY: Notify the server to deal damage to the humanoid by passing it
			DamageHum:FireServer(humanoid, damage) 
		end
	end
	
	-- Adding a Muzzle Flash Effect & Sound
	local flash = self.ClonedViewModel:FindFirstChild("Flash")
	if flash then
		if flash:FindFirstChild("ParticleEmitter") then
			flash.ParticleEmitter:Emit()
		end
	end
	-- Play Fire Sound
	if self.LoadedSounds then
		local fireSound = self.LoadedSounds["Fire"]
		if fireSound then fireSound:Play() end
	end
	
	-- Play Fire Animation
	if self.LoadedAnimations then
		local Fire: AnimationTrack = self.LoadedAnimations["Fire"]
		if Fire then
			Fire:Play()
		end
	end
	
	-- Add a camera-recoil effect on every shot fired
	self:ShootRecoil()
end

function Weapon:Reload()
	local s = state[self]
	if not self.Equipped or s.Reloading or s.Ammo >= s.Magsize or s.MaxAmmo < 1 then return end
	s.Reloading = true
	
	-- Reload Logic & Playing Reload Animation
	if self.LoadedAnimations and self.LoadedSounds then
		local Reload: AnimationTrack = self.LoadedAnimations["Reload"]
		if Reload then
			Reload:Play()
		end
		local reloadSound = self.LoadedSounds["Reload"]
		if reloadSound then reloadSound:Play() end
		-- Used :Once instead of :Connect to ensure it only fires once and disconnects itself
		Reload.Stopped:Once(function()  
			if not s.Reloading then return end
			local PreviousAmmo = s.Ammo
			s.Ammo = s.Magsize
			-- Determines how many bullet can be reloaded without exceeding the MaxAmmo  
			local ammoNeeded = math.min(s.Magsize - PreviousAmmo, s.MaxAmmo)
			s.Ammo = PreviousAmmo + ammoNeeded
			s.MaxAmmo -= ammoNeeded
			-- Fire this event to update the Ammo UI on the client-side
			ammoEvent:Fire(s.Ammo, s.MaxAmmo)
			s.Reloading = false
		end)
	end
end

-- Recoil Pattern that simulates incrementing vertical kick
local recoil = {
	CFrame.Angles(math.rad(2), math.rad(0), 0);
	CFrame.Angles(math.rad(1), math.rad(0), 0);
	CFrame.Angles(math.rad(.5), math.rad(0), 0);
}

function Weapon:ShootRecoil()
	local s = state[self]
	if not self.Equipped then return end
	s.RecoilIndex += 1
	s.RecoilIndex = (s.RecoilIndex % #recoil) + 1
	
	-- Multiplaying current Camera.CFrame by the current Recoil for the Vertical kick
	Camera.CFrame = Camera.CFrame * recoil[s.RecoilIndex] 
end

return Weapon
