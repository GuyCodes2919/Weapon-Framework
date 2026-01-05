-- Weapon Framework Application

--[[
	It implements a client-side weapon framework using:
	- Object-Oriented pattern using metatables
	- Private state for the weapon and its state
	- ContextActionService for input handling instead of UserInputService
	- Flipper: A open-source animation library mainly for sway/bob movements of the viewmodel
	- ReplicatedStorage for shared assets and remote events
	-- RemoteEvents for Damaging & Ammo Signal for demo purpose
	-- RunService for smooth frame-by-frame synchronization
	-- A client side ammo GUI handling done through a client-script (Not Included Here)
	-- Object Pooling for efficiently managing bullets 
	-- A demo zombie spawner has been added for demo purposes which might not be the best for performance (Not Included Here)
	
]]

-- Services
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Camera = Workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- OPEN SOURCE LIBRARY FOR SMOOTH MOTIONS
local Flipper = require(ReplicatedStorage.Packages.Flipper)

-- REMOTE EVENTS 
local ammoEvent = ReplicatedStorage:WaitForChild("AmmoChanged")

-- A damage signal to tell the server to damage a humanoid for demo purposes
local DamageHum = ReplicatedStorage:WaitForChild("DamageHum") 
local ViewModel = ReplicatedStorage.ViewModel -- Default ViewModel

local Weapon = {}
Weapon.__index = Weapon -- OOP

-- Private State Storage
local state = setmetatable({}, {__mode = "k"}) -- __mode = "k" creates a weak table

-- Weapon Base Damage
local BASE_DAMAGE = 10
-- Distance for damage falloffs
local FALLOFF_START = 120 --// studs
local FALLOFF_END = 500 -- // studs

-- If headshot then do twice the damage
local HEADSHOT_MULTIPLIER = 2

-- For ContextActionService Handler 
local handleFire
local handleReload

-- BULLET OBJECT POOLING (Client-Side & Visual Only)
local BULLET_POOL_SIZE = 40

-- Track ActiveWeapons by Player
local activeWeapons = {}

-- Limiting the number of damage indicators for performance reasons
local activeDamageIndicators = 0
local MAX_DAMAGE_INDICATOR = 10

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
	self.BulletPool = {} --// Pool of pre-created bullets
	self.ActiveBullets = {} --// To store the active bullets
	self.Motors = {} --// To store the flipper motors
	
	-- Pre-create the bullets for this weapon
	for i = 1, BULLET_POOL_SIZE do
		local bullet = self:createBulletTemplate()
		table.insert(self.BulletPool, bullet)
	end
	
	return self
end


-- Functions
function Weapon:Equip(player: Player)
	if self.Equipped then return end
	self.Equipped = true
	self.Player = player
	self.Mouse = LocalPlayer:GetMouse()

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

	-- Create Flipper motors for sway (mouse movement and bobbing)
	-- SignalMotor.new() creates a spring-driven motor starting at 0
	self.Motors.swayX = Flipper.SingleMotor.new(0) -- horizontal sway
	self.Motors.swayY = Flipper.SingleMotor.new(0) -- vertical sway
	
	self.Motors.bobX = Flipper.SingleMotor.new(0) -- horizontal bobbing
	self.Motors.bobY = Flipper.SingleMotor.new(0) -- vertical bobbing
	
	-- RenderStepped connection for smooth frame-by-frame updates
	self.RenderConnection = RunService.RenderStepped:Connect(function()
		if not self.ClonedViewModel or not self.ClonedViewModel.PrimaryPart then return end
		local s = state[self]

		-- Mouse-based target values
		local mouseDelta = UserInputService:GetMouseDelta() / 50
		-- Clamped the mousedelta value to avoid any extreme sway on high DPI mouses
		local targetSwayX = math.clamp(mouseDelta.X, -.2, .2)
		local targetSwayY = math.clamp(mouseDelta.Y, -.2, .2)

		-- Set spring goals for sway motors
		-- Flipper.Spring.new() defines how "springy" you want the motion
		self.Motors.swayX:setGoal(Flipper.Spring.new(targetSwayX, { frequency = 4, dampingRatio = 1 }))
		self.Motors.swayY:setGoal(Flipper.Spring.new(targetSwayY, { frequency = 4, dampingRatio = 1 }))

		-- Bob based on walk speed
		local humanoid = self.Player.Character and self.Player.Character:FindFirstChild("Humanoid")
		local rootPart = self.Player.Character:FindFirstChild("HumanoidRootPart")
		local speed = 0
		if humanoid and rootPart then
			speed = Vector3.new(rootPart.Velocity.X, 0, rootPart.Velocity.Z).Magnitude -- horizontal speed
		end
		local bobIntensity = math.clamp(speed / 16, 0, 1)  -- [0,1] for intensity
		
		local bobXTarget, bobYTarget = 0, 0
		if bobIntensity > 0 then
			local time = os.clock()
			-- slower at low speed, faster at high speed
			local frequency = 6 + speed * 0.1

			-- Bob along forward/back
			bobYTarget = math.sin(time * frequency) * 0.03 * bobIntensity
			-- Bob along sideways (strafe)
			bobXTarget = math.sin(time * frequency * 0.5) * 0.02 * bobIntensity
		end
		
		-- Setting the spring goal using bob motors
		self.Motors.bobX:setGoal(Flipper.Spring.new(bobXTarget, { frequency = 3, dampingRatio = 1 }))
		self.Motors.bobY:setGoal(Flipper.Spring.new(bobYTarget, { frequency = 3, dampingRatio = 1 }))

		-- Combine sway + bob
		-- Combine Sway and Bob into a single CFrame Offset
		local finalCF = CFrame.new(self.Motors.bobY:getValue() + self.Motors.swayY:getValue(), self.Motors.bobX:getValue() + self.Motors.swayX:getValue(), 0)
		s.SwayCF = finalCF -- storing the final offset in weapon's private state

		-- Applying the offset to the viewmodel PrimaryPart
		-- Multiply the Camera CFrame by the offset to move the viewmodel
		self.ClonedViewModel:SetPrimaryPartCFrame(Camera.CFrame * self.ViewModelOffset * s.SwayCF)
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
	
	-- Storing the reference of the weapon so ContextActionService handler can forward inputs
	activeWeapons[player.UserId] = self
	
	-- Bind weapon action through ContextActionService instad of UserInputService
	-- it keeps input logic separate from weapon logic and makes it easier to remove on unequip
	ContextActionService:BindAction(
		"WeaponFire",
		handleFire, 
		false,
		Enum.UserInputType.MouseButton1
	)
	ContextActionService:BindAction(
		"WeaponReload",
		handleReload, 
		false,
		Enum.KeyCode.R
	)
end


function Weapon:Unequip(player: Player)
	if not self.Equipped then return end
	self.Equipped = false
	local s = state[self]
	
	if self.Motors then
		for key, motor in pairs(self.Motors) do
			motor:destroy() -- Flipper uses lowercase :destroy()
			self.Motors[key] = nil
		end
	end
	
	-- Disconnect RenderStepped connection
	-- THIS IS IMPORTANT to prevent memory leaks
	if self.RenderConnection then
		self.RenderConnection:Disconnect()
		self.RenderConnection = nil
	end
	
	-- Stop Animations
	for name, track in pairs(self.LoadedAnimations) do
		track:Stop()
		track:Destroy()
		self.LoadedAnimations[name] = nil
	end
	
	-- Destroy ViewModel
	if self.ClonedViewModel then
		self.ClonedViewModel:Destroy()
		self.ClonedViewModel = nil
	end
	
	self.Player = nil -- Ensure player reference is cleared
	self.Mouse = nil -- Ensure mouse is cleared
	if s then s.Reloading = false end -- Ensure reloading state is reset
	
	-- Clean up bullet pools
	for _, bullet in pairs(self.ActiveBullets) do
		if bullet then bullet:Destroy() end
	end
	table.clear(self.ActiveBullets) 
	
	-- Unbind actions on unequip to ensure only active weapon receives input
	ContextActionService:UnbindAction("WeaponFire")
	ContextActionService:UnbindAction("WeaponReload")
	-- Clear the active weapon reference when unequipped
	activeWeapons[player.UserId] = nil
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

-- Function to create a bullet template
function Weapon:createBulletTemplate()
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 255, 0) --// bright yellow color
	part.Transparency = 1
	part.Size = Vector3.new(0.1, 0.1, 1)
	part.Parent = Workspace
	return part
end

-- Function to get a bullet from the pool
function Weapon:GetBullet()
	local bullet: Part = table.remove(self.BulletPool)
	-- If no bullet is available, create a new one
	if not bullet then
		bullet = self:createBulletTemplate()
	end
	
	bullet:SetAttribute("InUse", true)
	table.insert(self.ActiveBullets, bullet) -- Track for cleanup
	return bullet
end

function Weapon:ReturnBullet(bullet)
	bullet:SetAttribute("InUse", false)
	bullet.Transparency = 1
	bullet.Size = Vector3.new(0.1, 0.1, 1)
	bullet.Parent = nil
	-- Remove from active tracking
	local idx = table.find(self.ActiveBullets, bullet)
	if idx then table.remove(self.ActiveBullets, idx) end
	table.insert(self.BulletPool, bullet)
end

-- Function to create Visual Bullet Trails when firing
function Weapon:CreateBulletTrail(startPos, endPos)
	local bullet = self:GetBullet()
	if not bullet then
		-- failed to get a bullet, maybe the pool is empty
		return
	end
	
	-- Calculate the distance and direction of the bullet trail
	local distance = (endPos - startPos).Magnitude
	bullet.Size = Vector3.new(0.1, 0.1, distance)
	-- Set the bullet's CFrame to look at the end position
	bullet.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -distance / 2)
	bullet.Transparency = 0.5
	bullet.Parent = Workspace
	
	-- Return bullet to pool after short delay
	task.delay(.1, function()
		if bullet:GetAttribute("InUse") == true then
			self:ReturnBullet(bullet)
		end
	end)
end

-- Shows damage numbers floating up when you hit something
-- Could have used Object-Pooling like for bullets, but I think this is fine for now.
function Weapon:CreateDamageIndicator(position: Vector3, damage: number, isHeadshot: boolean)
	if activeDamageIndicators >= MAX_DAMAGE_INDICATOR then
		return -- skip if too many active for performance reasons
	end
	
	activeDamageIndicators += 1 -- Track number of active damage indicators
	
	local indicator = Instance.new("Part")
	indicator.Size = Vector3.new(0.1, 0.1, 0.1)
	indicator.Transparency = 1
	indicator.CanCollide = false
	indicator.Anchored = true
	indicator.CFrame = CFrame.new(position)
	indicator.Parent = Workspace

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(0, 100, 0, 50)
	gui.StudsOffset = Vector3.new(0, 2, 0)
	gui.AlwaysOnTop = true
	gui.Parent = indicator

	local dmgText = Instance.new("TextLabel")
	dmgText.Size = UDim2.new(1, 0, 1, 0)
	dmgText.BackgroundTransparency = 1
	-- The text is the damage amount 
	dmgText.Text = "-" .. math.floor(damage)
	-- Change color to red for headshots
	dmgText.TextColor3 = isHeadshot and Color3.new(1, 0.2, 0.2) or Color3.new(1, 1, 1) 
	dmgText.TextScaled = true
	dmgText.Font = Enum.Font.GothamBold
	dmgText.Parent = gui

	-- Basing tweening on gui for fading and floating effect
	local floatUp = TweenService:Create(gui, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),{StudsOffset = Vector3.new(0, 4, 0)})

	local fadeOut = TweenService:Create(dmgText,TweenInfo.new(0.8, Enum.EasingStyle.Quad),{TextTransparency = 1})

	floatUp:Play()
	fadeOut:Play()

	fadeOut.Completed:Once(function()
		activeDamageIndicators -= 1 -- Clean up after tween completes
		indicator:Destroy()
	end)
	-- If it fails to destroy, it will be destroyed by the Debris service after 2 second
	Debris:AddItem(indicator, 2)
end

function Weapon:Fire(player, mouse)
	local s = state[self]
	if not self.Equipped or s.Reloading then return end
	
	local now = os.clock()
	
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
	local size = .6 -- Size of the spherecast
	
	--[[
		For reviewers, here I have used client-side raycasting for demonstration purposes only.
		In a production settings, you would want to handle raycasting and damaging in the server-side,
		to avoid exploits and ensure synchronization.
		
		But because one of the requirements is that I submit only one script, I opted for client-side raycasting.
	]]
	-- Raycast Params 
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {self.ClonedViewModel, self.Player.Character} -- Avoids the ViewModel and the Player's Character
	params.IgnoreWater = true
	
	-- Used Spherecast instead of Raycast because it is more reliable and efficient.
	local result = Workspace:Spherecast(startPos, size, aimDirection * Range, params)
	
	if result then
		local hitPart = result.Instance
		local character = hitPart:FindFirstAncestorOfClass("Model")
		local humanoid = character and character:FindFirstChild("Humanoid")
		local distance = (result.Position - startPos).Magnitude -- Calculate distance
		local damage = self:CalculateDamage(hitPart, distance) -- Calculate damage based on distance
		
		-- Visualise the bullet trail
		self:CreateBulletTrail(muzzleStartPos, result.Position)
		
		if humanoid then
			-- Applying Damage on client-side is not recommended because it can be easily exploited.
			-- humanoid.Health -= damage (NOT IDEAL)
			-- BETTER WAY: Notify the server to deal damage to the humanoid by passing it
			DamageHum:FireServer(humanoid, damage) 
			self:CreateDamageIndicator(result.Position, damage, hitPart.Name == "Head")
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

-- Recoil Pattern that simulates incrementing vertical kick (Simple Recoil-System)
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

-- ContextActionService Handlers 
-- These functions forward input to the weapon object
local firing = false

handleFire = function(actionName, inputState)
	local weapon = activeWeapons[LocalPlayer.UserId]
	if not weapon then return Enum.ContextActionResult.Pass end

	if inputState == Enum.UserInputState.Begin then
		firing = true
		-- Start a loop that fires as long as player holds mouse
		task.spawn(function()
			local s = state[weapon] -- Get the current weapon state
			while firing and weapon and weapon.Equipped do
				weapon:Fire(weapon.Player, weapon.Mouse) 
				task.wait(s.FireRate)
			end
		end)
	elseif inputState == Enum.UserInputState.End then
		firing = false -- stops firing loop when mouse released
	end

	return Enum.ContextActionResult.Sink
end

handleReload = function(actionName, inputState)
	-- Only react to input begin events
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	local weapon = activeWeapons[LocalPlayer.UserId]
	if weapon then
		weapon:Reload() -- Reload the weapon
	end

	return Enum.ContextActionResult.Sink
end

return Weapon
