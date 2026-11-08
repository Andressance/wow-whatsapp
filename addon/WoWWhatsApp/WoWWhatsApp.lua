-- WoWWhatsApp: a WhatsApp messenger inside WoW, without reloading.
--
-- The WoW sandbox has no network and no file reads at runtime. Two doors remain open:
--
--   OUT ("pixel" mode): pending messages are drawn as a strip of colored squares in
--        the top-left corner of the screen until the bridge acknowledges them.
--        bridge.js screen-captures that corner and decodes it. Nothing touches the game.
--   IN:  load-on-demand addons read their files from disk at the moment they load.
--        The bridge writes the latest replies for every chat into a pool of pre-made
--        slot addons (WoWWhatsApp_S001..S200); we load a fresh slot from a timer.
--        Each slot is single-use per session; a /reload frees them all.
--   Fallback ("reload" mode): SavedVariables + Inbox.lua, a ReloadUI() per step.
--
-- Chats: each chat is one WhatsApp conversation (a contact or a group) with its own
-- history. Chats are created by incoming messages, or by /wa new <phone number>.
-- Everything here is plain addon API. No automation, no memory reading.

local ADDON_NAME = ...
local WoWWhatsApp = {}
_G.WoWWhatsApp = WoWWhatsApp
local Codec = WoWWhatsApp_Codec

local MAX_HISTORY = 200
local MAX_CHATS = 50

local SLOT_COUNT = 200
local SLOT_PREFIX = "WoWWhatsApp_S"
local PRESENCE_MAX = 2000 -- presence/0001..2000.wav, one flipped by the bridge every 30 s
local INCOMING_MAX = 2000 -- incoming/0001..2000.wav, one flipped per WhatsApp message
local STRIP_TRIES = 3 -- re-show an unacknowledged message this many times before falling back
local CELL, CELLS_PER_ROW, MAX_ROWS = 4, 200, 48
local STRIP_SECONDS = 40 -- max per message; it leaves the strip as soon as the bridge acknowledges
local POLL_SCHEDULE = { 5, 10, 16, 24, 34, 46, 60, 80, 100, 130, 160, 200, 240, 300 }
local POLL_TAIL = 60
local TICK_SECONDS = 2
local CONNECT_WAIT = 15 -- seconds the Connect button waits for the bridge before giving up
local IDLE_POLL_SECONDS = 600 -- without the sound channel, spend one slot this often while idle to check the bridge
local INCOMING_POLL_SECONDS = 5 -- fallback when the client's sound-file readiness channel is unavailable
local RS, US = "\30", "\31" -- record / unit separators in the strip payload

local db
local ui = {}
-- Transport state for this UI session. outbound[id] = { chat, cwd, flags, text, sentAt, acked }
local run = { outbound = {} }

-- Shared window backdrop. Declared up here because ShowCopy (rendering section)
-- uses it too: a later `local` would be invisible there and resolve to a nil global.
local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ToHex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- EditBoxes do not render UI escape sequences, so just make pipes harmless.
local function Display(s)
	return (tostring(s or ""):gsub("|", "¦"))
end

local function Trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function FmtDur(sec)
	sec = math.floor(sec or 0)
	if sec < 60 then return sec .. "s" end
	if sec < 3600 then return math.floor(sec / 60) .. "m" .. string.format("%02d", sec % 60) .. "s" end
	return math.floor(sec / 3600) .. "h" .. string.format("%02d", math.floor(sec / 60) % 60) .. "m"
end

local function NewId()
	return string.format("%x%04x", time() % 0xFFFFFF, math.random(0, 0xFFFF))
end

local function FindChat(id)
	for i, c in ipairs(db.chats) do
		if c.id == id then return c, i end
	end
end

local function ActiveChat()
	return FindChat(db.activeChat)
end

local function IsWhatsAppId(name)
	return type(name) == "string" and (name:find("@g.us", 1, true) ~= nil or name:find("@c.us", 1, true) ~= nil
		or name:find("@lid", 1, true) ~= nil)
end

local function IsDefaultChatName(name)
	return type(name) == "string" and (name == "" or name == "Chat 1" or name == "New chat"
		or name:match("^Chat %d+$") ~= nil)
end

-- When did anything last happen in this chat (for sorting the list)?
local function LastActivity(c)
	local m = c.history[#c.history]
	return (m and m.t) or c.created or 0
end

-- Room for a new chat: when the list is full, the chat that has been quiet the
-- longest goes (never the one in front, one with a message in flight, or unread).
local function MakeRoom()
	if #db.chats < MAX_CHATS then return true end
	local victim, oldest
	for i, c in ipairs(db.chats) do
		if c.id ~= db.activeChat and not c.pendingId and (c.unread or 0) == 0
			and (not oldest or LastActivity(c) < oldest) then
			victim, oldest = i, LastActivity(c)
		end
	end
	if not victim then return false end
	table.remove(db.chats, victim)
	return true
end

local function AddChat(name, id)
	if not MakeRoom() then return nil end
	local c = {
		id = id or NewId(),
		name = name or ("Chat " .. (#db.chats + 1)),
		history = {},
		unread = 0,
		created = time(),
	}
	table.insert(db.chats, c)
	return c
end

local function AnyPending()
	for _, c in ipairs(db.chats) do
		if c.pendingId then return true end
	end
	return false
end

local function InitDB()
	WoWWhatsAppDB = WoWWhatsAppDB or {}
	db = WoWWhatsAppDB
	db.settings = db.settings or {}
	local s = db.settings
	if s.autoRefresh == nil then s.autoRefresh = true end
	if s.signal == nil then s.signal = true end
	s.echo = s.echo or "full" -- how much of each incoming message to print in the game chat
	s.mode = s.mode or "pixel"
	s.interval = s.interval or 20
	s.width = s.width or 820
	s.height = s.height or 520
	-- Leftovers of the AI-assistant version of this addon.
	s.context, s.cwd, db.outbox = nil, nil, nil
	db.lastSeq = db.lastSeq or 0
	-- Chats deleted in game that the bridge hasn't confirmed forgetting yet.
	db.forget = db.forget or {}
	-- Identifies this counter's lifetime. If the saved data is ever reset, a new
	-- session lets the bridge tell "message #1 again" from "message #1, already done".
	if not db.session then
		db.session = string.format("%x%04x%04x", time() % 0xFFFFFF, math.random(0, 0xFFFF), math.random(0, 0xFFFF))
	end
	if not db.chats then
		-- Migrate the single-chat layout into the first chat.
		db.chats = {}
		local c = {
			id = NewId(),
			name = "Chat 1",
			history = db.history or {},
			pendingId = db.pendingId,
			unread = db.unread or 0,
			draft = db.draft,
			created = time(),
		}
		table.insert(db.chats, c)
		db.activeChat = c.id
		db.history, db.pendingId, db.unread, db.draft = nil, nil, nil, nil
	end
	if #db.chats == 0 then AddChat() end
	if not FindChat(db.activeChat) then db.activeChat = db.chats[1].id end
	for _, c in ipairs(db.chats) do
		c.cwd, c.progress = nil, nil
		for _, m in ipairs(c.history) do
			m.denied = nil
			-- Roles from older versions: everything that is not ours or a note is theirs.
			if m.role == "whatsapp" or m.role == "claude" or m.role == "assistant" then m.role = "contact" end
		end
	end
end

-- opts: sender (who wrote it, for groups), replyTo (who was quoted), t (when).
local function AddHistory(chat, role, text, id, opts)
	opts = opts or {}
	table.insert(chat.history, { role = role, text = text, id = id, t = opts.t or time(), sender = opts.sender, replyTo = opts.replyTo })
	while #chat.history > MAX_HISTORY do
		table.remove(chat.history, 1)
	end
end

local function SlotName(i)
	return string.format("%s%03d", SLOT_PREFIX, i)
end

local function SlotNumber(id)
	return ((id - 1) % SLOT_COUNT) + 1
end

---------------------------------------------------------------------------
-- Reload plumbing (fallback path)
---------------------------------------------------------------------------

local function SafeReload()
	if InCombatLockdown() then
		WoWWhatsApp.reloadAfterCombat = true
		if ui.status then
			ui.status:SetText("In combat - will reload as soon as it ends")
		end
		return
	end
	ReloadUI()
end

-- ReloadUI() only works from a hardware event (a keypress or click), never from
-- a timer. So the automatic reload piggybacks on the player's own next keypress
-- once the interval has elapsed. The key still reaches the game normally.
local keyCatcher = CreateFrame("Frame", "WoWWhatsAppKeyCatcher", UIParent)
keyCatcher:Hide()
keyCatcher:EnableKeyboard(true)
keyCatcher:SetScript("OnKeyDown", function(self, key)
	if db and AnyPending() and db.settings.autoRefresh
		and GetTime() >= (WoWWhatsApp.nextAutoRefresh or 0)
		and not InCombatLockdown() then
		self:Hide()
		ReloadUI()
	end
end)

-- Arm the keypress reload. In pixel mode this is only used once the slot pool
-- is exhausted (a reload frees every slot) or the slots are not installed.
function WoWWhatsApp.ArmAutoRefresh()
	keyCatcher:Hide()
	if not AnyPending() or not db.settings.autoRefresh then return end
	if db.settings.mode == "pixel" and not (run.slotsExhausted or run.slotsMissing or run.pixelFailed) then return end
	-- Propagation can't be changed in combat. Never show the catcher without it,
	-- or it would eat every keypress. PLAYER_REGEN_ENABLED re-arms after combat.
	if not keyCatcher.propagates then
		if InCombatLockdown() or not keyCatcher.SetPropagateKeyboardInput then return end
		keyCatcher:SetPropagateKeyboardInput(true)
		keyCatcher.propagates = true
	end
	WoWWhatsApp.nextAutoRefresh = GetTime() + db.settings.interval
	keyCatcher:Show()
end

---------------------------------------------------------------------------
-- Pixel strip (out)
---------------------------------------------------------------------------

local strip
local cellPool = {}

local function EnsureStrip()
	if strip then return strip end
	strip = CreateFrame("Frame", "WoWWhatsAppStrip", UIParent)
	strip:SetFrameStrata("TOOLTIP")
	strip:SetFrameLevel(10000)
	-- Scale so that one UI unit is exactly one physical pixel (see Blizzard's PixelUtil).
	local physH = 1080
	if GetPhysicalScreenSize then
		local _, h = GetPhysicalScreenSize()
		physH = h or physH
	end
	if strip.SetIgnoreParentScale then strip:SetIgnoreParentScale(true) end
	strip:SetScale(768 / physH)
	strip:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	strip:SetSize(CELLS_PER_ROW * CELL, MAX_ROWS * CELL)
	strip:Hide()
	return strip
end

local function HideStrip()
	if strip then strip:Hide() end
	run.stripShown = nil
end

local function ShowStrip(id, payload)
	local cells = Codec.Encode(id % 65536, payload)
	local s = EnsureStrip()
	local rows = math.ceil(#cells / CELLS_PER_ROW)
	local total = rows * CELLS_PER_ROW
	for i = 1, total do
		local t = cellPool[i]
		if not t then
			t = s:CreateTexture(nil, "OVERLAY")
			t:SetSize(CELL, CELL)
			local c = (i - 1) % CELLS_PER_ROW
			local r = math.floor((i - 1) / CELLS_PER_ROW)
			t:SetPoint("TOPLEFT", s, "TOPLEFT", c * CELL, -r * CELL)
			cellPool[i] = t
		end
		local cr, cg, cb = Codec.CellColor(cells[i] or 0)
		t:SetColorTexture(cr, cg, cb, 1)
		t:Show()
	end
	for i = total + 1, #cellPool do
		cellPool[i]:Hide()
	end
	s:Show()
	run.stripShown = true
end

-- Record: session, chat, id, (unused), flags, name, text. Several records per
-- frame. A record separator inside any field would split the record, so they
-- are replaced by spaces everywhere (the text is the last field, but the
-- separators between records are still \30).
local function Wire(s)
	return (tostring(s or ""):gsub("[\30\31]", " "))
end

local function RecordFor(id, rec)
	return table.concat({ db.session, Wire(rec.chat), tostring(id), "", rec.flags or "", Wire(rec.name), Wire(rec.text) }, US)
end

-- Redraw the strip from every outbound message the bridge hasn't acknowledged.
local function RefreshStrip()
	local ids = {}
	for id, rec in pairs(run.outbound) do
		if not rec.acked then table.insert(ids, id) end
	end
	if #ids == 0 then
		HideStrip()
		return
	end
	table.sort(ids)
	-- Newest first; drop the oldest if the frame would overflow.
	local parts, size, latest = {}, 0, ids[#ids]
	for i = #ids, 1, -1 do
		local r = RecordFor(ids[i], run.outbound[ids[i]])
		if size + #r + 1 > Codec.MAX_PAYLOAD then break end
		table.insert(parts, 1, r)
		size = size + #r + 1
	end
	ShowStrip(latest, table.concat(parts, RS))
end

---------------------------------------------------------------------------
-- Signals and slots (in)
---------------------------------------------------------------------------

-- Optional cheap poll: an empty .wav won't play, a valid one will. The bridge
-- fills sig/NNN.wav when reply NNN is ready. Self-disables if it misbehaves.
local signalAvailable = type(PlaySoundFile) == "function"
local signalStats = { checks = 0, hits = 0, lastHit = nil }

local function SoundValid(path)
	if not signalAvailable or not db.settings.signal then return false end
	signalStats.checks = signalStats.checks + 1
	local ok, willPlay, handle = pcall(PlaySoundFile, path, "Master")
	if not ok then
		signalAvailable = false
		signalStats.error = tostring(willPlay)
		return false
	end
	if willPlay and handle then pcall(StopSound, handle) end
	if willPlay then
		signalStats.hits = signalStats.hits + 1
		signalStats.lastHit = GetTime()
	end
	return willPlay and true or false
end

local function CheckSignal(kind, id)
	if run.signalUnreliable then return false end
	return SoundValid(string.format("Interface\\AddOns\\WoWWhatsApp\\%s\\%03d.wav", kind, SlotNumber(id)))
end


-- Bridge presence. Evidence the bridge is alive comes from several places:
-- presence beats, acks, slot data (which carries the bridge's clock), replies.
local function NotedBridge(at)
	at = at or GetTime()
	if not run.bridgeSeen or at > run.bridgeSeen then run.bridgeSeen = at end
	run.pixelFailed = nil
end

local function PresencePath(k)
	return string.format("Interface\\AddOns\\WoWWhatsApp\\presence\\%04d.wav", k)
end

-- Valid presence files form a prefix 1..k, so a binary search finds the head.
local function FindPresenceHead()
	local lo, hi = 0, PRESENCE_MAX
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if SoundValid(PresencePath(mid)) then lo = mid else hi = mid - 1 end
	end
	return lo
end

local function PollPresence()
	if not signalAvailable or not db.settings.signal then return end
	run.presence = run.presence or { last = FindPresenceHead() }
	local p = run.presence
	for _ = 1, 3 do
		local k = (p.last % PRESENCE_MAX) + 1
		if not SoundValid(PresencePath(k)) then break end
		p.last = k
		p.beats = (p.beats or 0) + 1
		NotedBridge()
	end
end

local function IncomingPath(k)
	return string.format("Interface\\AddOns\\WoWWhatsApp\\incoming\\%04d.wav", k)
end

local TryLoadSlot -- defined below

local function FindIncomingHead()
	local lo, hi = 0, INCOMING_MAX
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if SoundValid(IncomingPath(mid)) then lo = mid else hi = mid - 1 end
	end
	return lo
end

local function PollIncoming()
	if not signalAvailable or not db.settings.signal then return end
	run.incoming = run.incoming or { last = FindIncomingHead() }
	local p = run.incoming
	for _ = 1, 3 do
		local k = (p.last % INCOMING_MAX) + 1
		if not SoundValid(IncomingPath(k)) then break end
		p.last = k
		TryLoadSlot("incoming")
	end
end

-- Whether the 30-second presence beats can reach us at all. When they can't
-- (self-test failed, or signal checks turned off), the only evidence of the
-- bridge is a slot read: the idle poll below and the replies themselves.
local function PresenceWorks()
	return signalAvailable and db ~= nil and db.settings.signal
end

-- Returns state ("ok" | "stale" | "down" | "unknown"), a color and a description.
-- With presence beats the bridge is heard from every 30 s, so 90 s of silence is
-- suspicious. Without them the addon only hears from it every IDLE_POLL_SECONDS,
-- so the windows have to be wider or the light could never stay green between
-- messages and every reply would be followed by a Reconnect.
function WoWWhatsApp.BridgeState()
	local seen = run.bridgeSeen
	if not seen then
		return "unknown", 0.6, 0.6, 0.6, "Bridge: not seen yet this session"
	end
	local age = GetTime() - seen
	local okFor, staleFor = 90, 300
	if not PresenceWorks() then
		okFor, staleFor = IDLE_POLL_SECONDS + 120, IDLE_POLL_SECONDS * 2 + 120
	end
	if age < okFor then
		return "ok", 0.2, 0.9, 0.3, "Bridge: connected (seen " .. FmtDur(age) .. " ago)"
	elseif age < staleFor then
		return "stale", 0.95, 0.8, 0.2, "Bridge: last seen " .. FmtDur(age) .. " ago"
	end
	return "down", 0.9, 0.25, 0.25, "Bridge: not seen for " .. FmtDur(age) .. " - is the bridge running?"
end

-- Same icons the friends list uses for online / away / busy / offline.
local STATE_ICON = {
	ok = "Interface\\FriendsFrame\\StatusIcon-Online",
	stale = "Interface\\FriendsFrame\\StatusIcon-Away",
	down = "Interface\\FriendsFrame\\StatusIcon-DnD",
	unknown = "Interface\\FriendsFrame\\StatusIcon-Offline",
}

function WoWWhatsApp.UpdateDot()
	local state, _, _, _, tip = WoWWhatsApp.BridgeState()
	if run.pixelFailed then state = "down" end
	if not signalAvailable and signalStats.selftest then
		tip = tip .. "\n(sound-file channel unavailable: " .. signalStats.selftest .. "; using slot checks only)"
	end
	for _, dot in ipairs({ ui.dot, ui.miniDot }) do
		if dot then
			dot:SetTexture(STATE_ICON[state] or STATE_ICON.unknown)
			dot.tip = tip
		end
	end
end

-- Connected = the bridge has been seen recently. In pixel mode, sending needs this;
-- until then the Connect button takes the Send button's place. The reload
-- transport has no idea whether the bridge is there, so it never gates.
function WoWWhatsApp.IsConnected()
	if not db or db.settings.mode ~= "pixel" then return true end
	return WoWWhatsApp.BridgeState() == "ok" and not run.pixelFailed
end

-- Connect button: say hello to the bridge (it acks, refreshes the slots and
-- offers a restore), ignoring SayHello's throttle so a click always does something.
function WoWWhatsApp.Connect()
	if db.settings.mode ~= "pixel" then
		SafeReload()
		return
	end
	run.lastHelloAt = nil
	run.pixelFailed = nil
	run.connectFailed = nil
	run.connectingAt = GetTime()
	WoWWhatsApp.SayHello()
end

-- One word for the connection state, so Tick can tell when it changed.
local function ConnectionKey()
	if WoWWhatsApp.IsConnected() then return "ok" end
	if run.connectingAt then return "connecting" end
	if run.connectFailed then return "failed" end
	return WoWWhatsApp.BridgeState()
end

-- Called every tick: time out a Connect attempt, and redraw when the state flips
-- (light, button, status line, placeholder) without redrawing every tick.
function WoWWhatsApp.CheckConnection()
	if run.connectingAt then
		if WoWWhatsApp.IsConnected() then
			run.connectingAt, run.connectFailed = nil, nil
			-- A message typed while disconnected goes out now, without a second click,
			-- as long as the same chat is still in front and free.
			local queued = run.sendOnConnect
			run.sendOnConnect = nil
			local c = queued and ActiveChat()
			if c and c.id == queued.chat and not c.pendingId then
				if ui.input and Trim(ui.input:GetText() or "") == queued.text then ui.input:SetText("") end
				WoWWhatsApp.Send(queued.text)
			end
		elseif GetTime() - run.connectingAt > CONNECT_WAIT then
			run.connectingAt, run.connectFailed = nil, true
			run.sendOnConnect = nil -- the text is still in the box
		end
	elseif run.connectFailed and WoWWhatsApp.IsConnected() then
		run.connectFailed = nil
	end
	local key = ConnectionKey()
	if key ~= run.connKey then
		run.connKey = key
		WoWWhatsApp.Render()
	end
end

-- Swap Send and Connect depending on the state; part of UpdateStatus.
function WoWWhatsApp.UpdateConnect()
	if not ui.connect or not ui.send then return end
	local connected = WoWWhatsApp.IsConnected()
	ui.send:SetShown(connected)
	ui.connect:SetShown(not connected)
	if connected then return end
	if run.connectingAt then
		ui.connect:SetText("Connecting...")
		ui.connect:Disable()
	else
		ui.connect:SetText(WoWWhatsApp.BridgeState() == "stale" and "Reconnect" or "Connect")
		ui.connect:Enable()
	end
end

-- Prove the sound-file trick actually distinguishes empty from valid files on this
-- client before trusting it for presence, heartbeats and readiness signals.
local function SelfTestSignals()
	if not signalAvailable then
		signalStats.selftest = "PlaySoundFile missing"
		return
	end
	local emptyLooksValid = SoundValid("Interface\\AddOns\\WoWWhatsApp\\ctl\\empty.wav")
	local validLooksValid = SoundValid("Interface\\AddOns\\WoWWhatsApp\\ctl\\valid.wav")
	if emptyLooksValid then
		signalAvailable = false
		signalStats.selftest = "an empty file reports as playable"
	elseif not validLooksValid then
		signalAvailable = false
		signalStats.selftest = "a valid file reports as unplayable (files not indexed? restart WoW)"
	else
		signalStats.selftest = "passed"
	end
end

local function FreeSlot()
	for i = 1, SLOT_COUNT do
		local name = SlotName(i)
		if not C_AddOns.IsAddOnLoaded(name) then
			return name
		end
	end
end

local function ScheduleNextPoll()
	local idx = (run.polls or 0) + 1
	local t = POLL_SCHEDULE[idx]
	if not t then
		t = POLL_SCHEDULE[#POLL_SCHEDULE] + POLL_TAIL * (idx - #POLL_SCHEDULE)
	end
	run.nextPollAt = (run.sentAt or GetTime()) + t
end

local Transmit -- defined in the sending section
local NotifyIncoming -- defined in the notification section

---------------------------------------------------------------------------
-- What the bridge tells us
---------------------------------------------------------------------------

-- The message with this id went to WhatsApp (the bridge acked it, or said "sent").
-- The chat is free again: whatever was typed meanwhile goes out next.
local function NextQueued(chat)
	for _, m in ipairs(chat.history) do
		if m.queued then
			m.queued = nil
			Transmit(chat, m)
			return
		end
	end
end

local function Delivered(chat, id)
	if not chat or not chat.pendingId or chat.pendingId ~= id then return end
	for i = #chat.history, 1, -1 do
		local m = chat.history[i]
		if m.role == "user" and m.id == id then m.sent, m.failed = true, nil break end
	end
	chat.pendingId = nil
	NextQueued(chat)
	WoWWhatsApp.Render()
end

local function Failed(chat, id, why)
	if not chat or not chat.pendingId or chat.pendingId ~= id then return end
	for i = #chat.history, 1, -1 do
		local m = chat.history[i]
		if m.role == "user" and m.id == id then m.failed = true break end
	end
	chat.pendingId = nil
	AddHistory(chat, "system", "Not sent: " .. tostring(why or "unknown error"))
	NextQueued(chat)
	WoWWhatsApp.Render()
end

local function NoteAcked(rec)
	rec.acked = true
end

local function MarkAcked(id)
	local rec = run.outbound[id]
	if rec and not rec.acked then
		NoteAcked(rec)
		RefreshStrip()
	end
	NotedBridge()
end

-- Has this exact message been stored already? (A slot can carry it again.)
local function HasMessage(chat, r)
	for i = #chat.history, 1, -1 do
		local m = chat.history[i]
		if m.text == r.text and (m.ext == r.id or (m.role == "contact" and m.id == r.id)) then return true end
	end
	return false
end

-- A message from WhatsApp: someone wrote to us, or we wrote from the phone (fromMe).
local function ApplyIncoming(r)
	local c = FindChat(r.chat)
	if not c then
		c = AddChat(r.chatName or r.name or r.chat, r.chat)
		if not c then return false end
		c.remoteName = r.chatName or r.name or r.chat
	end
	local remoteName = r.chatName or r.name
	if remoteName and remoteName ~= "" and not c.customName
		and (not c.name or c.name == c.remoteName or IsWhatsAppId(c.name) or IsDefaultChatName(c.name)) then
		c.name = remoteName
		c.remoteName = remoteName
	end
	if r.isGroup ~= nil then c.isGroup = r.isGroup end
	if HasMessage(c, r) then return true end
	local t = tonumber(r.timestamp)
	if t and t <= 0 then t = nil end
	if r.fromMe then
		AddHistory(c, "user", r.text, nil, { t = t, replyTo = r.replyTo })
		local m = c.history[#c.history]
		m.ext, m.sent = r.id, true
		return true
	end
	AddHistory(c, "contact", r.text, r.id, { t = t, sender = r.sender, replyTo = r.replyTo })
	c.history[#c.history].ext = r.id
	if db.activeChat ~= c.id or not (ui.frame and ui.frame:IsShown()) then c.unread = (c.unread or 0) + 1 end
	NotifyIncoming(c, r.text, c.isGroup and r.sender or nil)
	return true
end

-- Dispatch a list of records from the bridge. Returns whether any of them was news.
local function ApplyReplies(replies)
	local matched = false
	for _, r in ipairs(replies or {}) do
		if r.status == "incoming" and r.chat and r.text then
			if ApplyIncoming(r) then matched = true end
		else
			local c = FindChat(r.chat)
			if c and c.pendingId and r.id == c.pendingId then
				matched = true
				if r.status == "sent" then
					MarkAcked(r.id)
					Delivered(c, r.id)
				elseif r.status == "error" then
					MarkAcked(r.id)
					Failed(c, r.id, r.text)
				end
			end
		end
	end
	return matched
end

-- The bridge keeps every chat's transcript. After the client wipes our saved data,
-- it sends them back once, addressed to our new session token.
local function ImportRestore(r)
	if type(r) ~= "table" or r.token ~= db.session or db.restored then return end
	db.restored = true
	local added = 0
	local current = ActiveChat()
	for _, rc in ipairs(r.chats or {}) do
		-- Skip chats deleted here that the bridge hasn't been told about yet.
		if type(rc) == "table" and rc.id and not FindChat(rc.id) and not db.forget[rc.id] and #db.chats < MAX_CHATS then
			local chat = {
				id = rc.id,
				name = (rc.name and rc.name ~= "") and rc.name or ("Chat " .. (#db.chats + 1)),
				history = {},
				unread = 0,
				created = time(),
				isGroup = tostring(rc.id):find("@g.us", 1, true) ~= nil or nil,
			}
			for _, m in ipairs(rc.messages or {}) do
				local role = (m.role == "user" or m.role == "system") and m.role or "contact"
				table.insert(chat.history, { role = role, text = m.text, id = m.id, t = m.t, sender = m.sender ~= "" and m.sender or nil,
					replyTo = m.replyTo ~= "" and m.replyTo or nil, sent = role == "user" or nil })
			end
			-- Keep the chat we're currently using last so it stays where it was.
			table.insert(db.chats, math.max(1, #db.chats), chat)
			added = added + 1
		end
	end
	run.restoring = nil
	if added > 0 then
		if current and #current.history <= 2 then
			for _, ch in ipairs(db.chats) do
				if ch ~= current and ch.name == current.name then current.name = "New chat" end
			end
		end
		AddHistory(current, "system", "Restored " .. added .. " chat(s) from the bridge after the game reset the saved data.")
		WoWWhatsApp.Render()
	end
end

TryLoadSlot = function(why)
	local name = FreeSlot()
	if not name then
		run.slotsExhausted = true
		WoWWhatsApp.ArmAutoRefresh()
		WoWWhatsApp.UpdateStatus()
		return
	end
	WoWWhatsApp_SlotData = nil
	local loaded, reason = C_AddOns.LoadAddOn(name)
	if not loaded then
		run.slotError = reason
		if reason == "MISSING" or reason == "DISABLED" then
			run.slotsMissing = true
			WoWWhatsApp.ArmAutoRefresh()
		end
		WoWWhatsApp.UpdateStatus()
		return
	end
	run.polls = (run.polls or 0) + 1
	ScheduleNextPoll()
	local data = WoWWhatsApp_SlotData
	if type(data) == "table" and type(data.now) == "number" then
		-- The bridge's clock and ours are the same machine; translate to GetTime().
		NotedBridge(GetTime() - (time() - data.now))
	end
	local matched = ApplyReplies(type(data) == "table" and data.replies or nil)
	if type(data) == "table" and data.restore then ImportRestore(data.restore) end
	if why == "signal" and not matched then
		run.signalUnreliable = true
	end
	WoWWhatsApp.Render()
end

local function Tick()
	if not db then return end
	local now = GetTime()
	PollPresence()
	PollIncoming()
	-- Without presence beats, the only evidence is a slot read; spend one every
	-- IDLE_POLL_SECONDS while idle so the light still reflects reality (and stays
	-- green while the bridge is up: BridgeState allows for this interval).
	if not PresenceWorks() and db.settings.mode == "pixel" and not AnyPending()
		and now - (run.lastIdlePoll or -1e9) >= IDLE_POLL_SECONDS then
		run.lastIdlePoll = now
		run.lastIncomingPoll = now
		TryLoadSlot("idle")
	end
	WoWWhatsApp.UpdateDot()
	WoWWhatsApp.CheckConnection()
	if db.settings.mode ~= "pixel" then return end
	local changed = false
	if run.helloPollAt and now >= run.helloPollAt then
		run.helloPollAt = nil
		TryLoadSlot("hello")
		-- Whatever that slot held, the wait is over.
		if run.restoring then
			run.restoring = nil
			WoWWhatsApp.Render()
		end
	end
	if run.restoring and now - run.restoring > 25 then
		run.restoring = nil
		WoWWhatsApp.Render()
	end
	local delivered = {}
	for id, rec in pairs(run.outbound) do
		if not rec.acked and CheckSignal("ack", id) then
			NoteAcked(rec)
			changed = true
			NotedBridge()
		end
		-- A hello only needs the bridge to have been seen; it never escalates.
		-- A forget is the same, but the bridge must have been seen a moment after
		-- the record went up, so it had a chance to read it.
		if (rec.hello or rec.forget) and not rec.acked and run.bridgeSeen and run.bridgeSeen >= rec.sentAt + (rec.forget and 2 or 0) then
			NoteAcked(rec)
			changed = true
		end
		if rec.acked then
			-- The bridge acks a message once it has sent it, so that is "delivered".
			if rec.forget then db.forget[rec.forget] = nil
			elseif not rec.hello then table.insert(delivered, { rec.chat, id }) end
			run.outbound[id] = nil
			changed = true
		elseif rec.hello and now - rec.sentAt >= 20 then
			run.outbound[id] = nil
			changed = true
		elseif now - rec.sentAt >= STRIP_SECONDS then
			rec.tries = (rec.tries or 1) + 1
			if rec.tries <= STRIP_TRIES then
				-- Nobody picked it up: show it again.
				rec.sentAt = now
				changed = true
			elseif rec.forget then
				-- The bridge is away; db.forget keeps it for the next hello.
				run.outbound[id] = nil
				changed = true
			else
				-- Give up on pixels for this message; the reload path still has it.
				run.outbound[id] = nil
				run.pixelFailed = true
				changed = true
				WoWWhatsApp.ArmAutoRefresh()
			end
		end
	end
	-- After the loop: delivering may queue the next message, which adds to run.outbound.
	for _, d in ipairs(delivered) do Delivered(FindChat(d[1]), d[2]) end
	if changed then
		RefreshStrip()
		WoWWhatsApp.UpdateStatus()
	end
	if not AnyPending() then
		if db.settings.mode == "pixel" and not PresenceWorks()
			and now - (run.lastIncomingPoll or -1e9) >= INCOMING_POLL_SECONDS then
			run.lastIncomingPoll = now
			TryLoadSlot("incoming-poll")
		end
		return
	end
	for _, c in ipairs(db.chats) do
		if c.pendingId and CheckSignal("sig", c.pendingId) then
			TryLoadSlot("signal")
			return
		end
	end
	if run.nextPollAt and now >= run.nextPollAt then
		TryLoadSlot("schedule")
	end
end

-- Pull whatever bridge.js last wrote into Inbox.lua (the reload path).
local function ProcessInbox()
	local inbox = WoWWhatsApp_Inbox
	if type(inbox) ~= "table" then return end
	ApplyReplies(inbox.replies)
	if inbox.restore then ImportRestore(inbox.restore) end
end

---------------------------------------------------------------------------
-- Links
---------------------------------------------------------------------------

-- Shift-clicked items, spells and quests are meaningless markup to anyone outside
-- the game: each link becomes its plain [Name]. Returns the new text.
function WoWWhatsApp.ExpandLinks(text)
	-- Coloured links first (|cAARRGGBB|H...|h[Name]|h|r), then bare ones.
	local out = text:gsub("|c%x%x%x%x%x%x%x%x|H[^|]+|h(%[[^%]]*%])|h|r", "%1")
	out = out:gsub("|H[^|]+|h(%[[^%]]*%])|h", "%1")
	return out
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- Put one stored message on its way (pixel strip, or the SavedVariables outbox
-- for the reload path). The chat is "pending" until the bridge says it is sent.
Transmit = function(c, m)
	db.lastSeq = db.lastSeq + 1
	local id = db.lastSeq
	m.id, m.t = id, time()
	c.pendingId = id
	db.outbox = { id = id, session = db.session, chat = ToHex(c.id), text = ToHex(m.text), t = time() }
	if db.settings.mode == "pixel" then
		run.outbound[id] = { chat = c.id, flags = "", name = c.name, text = m.text, sentAt = GetTime() }
		run.sentAt = GetTime()
		run.polls = 0
		ScheduleNextPoll()
		RefreshStrip()
		WoWWhatsApp.Render()
	else
		SafeReload()
	end
end

-- c: the chat to send to (default: the one in front).
function WoWWhatsApp.Send(text, c)
	c = c or ActiveChat()
	if not c then return end
	text = Trim(text or "")
	if text == "" then return end
	if not WoWWhatsApp.IsConnected() then
		-- Not connected: the message stays in the box and we try to connect;
		-- CheckConnection sends it the moment the light turns green. If the bridge
		-- never answers, the text is still in the box for a later try.
		if ui.input then ui.input:SetText(text) end
		run.sendOnConnect = { chat = c.id, text = text }
		if not run.connectingAt then WoWWhatsApp.Connect() end
		WoWWhatsApp.Toggle(true)
		return
	end
	text = WoWWhatsApp.ExpandLinks(text)
	local limit = Codec.MAX_PAYLOAD - 300
	if #text > limit then
		AddHistory(c, "system", "That message is too long for one send (" .. #text .. " chars, max ~" .. limit .. "). Split it up.")
		WoWWhatsApp.Render()
		return
	end
	AddHistory(c, "user", text, nil)
	local m = c.history[#c.history]
	db.settings.shown = true
	if c.pendingId then
		-- The previous message is still on its way: this one follows when it is delivered.
		m.queued = true
		WoWWhatsApp.Render()
	else
		Transmit(c, m)
	end
end

-- Forget: a record with no text telling the bridge a chat was deleted, so it drops
-- the transcript (which a later restore would otherwise bring back).
-- db.forget keeps the id until the bridge acks, so a delete made while the bridge
-- was away is sent again with the next hello.
local function SendForget(chatId)
	if db.settings.mode ~= "pixel" then return end
	for _, rec in pairs(run.outbound) do
		if rec.forget == chatId and not rec.acked then return end
	end
	local info = db.forget[chatId] or {}
	db.lastSeq = db.lastSeq + 1
	run.outbound[db.lastSeq] = { chat = chatId, flags = "d", name = info.name or "", text = "", sentAt = GetTime(), forget = chatId }
	RefreshStrip()
end

local function ForgetOnBridge(c)
	if not c or not c.id then return end
	db.forget[c.id] = { name = c.name }
	SendForget(c.id)
end

-- Hello: a record with no text that just announces our session token. The bridge
-- acks it, offers a restore if our saved data is fresh, and refreshes the slots,
-- so the status light and any lost chats come back before the first message.
function WoWWhatsApp.SayHello()
	if db.settings.mode ~= "pixel" then return end
	local now = GetTime()
	if run.lastHelloAt and now - run.lastHelloAt < 60 then return end
	run.lastHelloAt = now
	db.lastSeq = db.lastSeq + 1
	local c = ActiveChat()
	run.outbound[db.lastSeq] = { chat = c and c.id or "", flags = "h", name = c and c.name or "", text = "", sentAt = now, hello = true }
	run.helloPollAt = now + 5
	-- Deletions the bridge never confirmed ride along with the hello.
	for id in pairs(db.forget) do SendForget(id) end
	-- Fresh saved data: show "restoring" instead of an empty panel until we hear back.
	if not db.restored then
		local empty = true
		for _, ch in ipairs(db.chats) do
			if #ch.history > 0 then empty = false end
		end
		if empty then run.restoring = now end
	end
	RefreshStrip()
	WoWWhatsApp.Render()
end

-- Put the active chat's pending message back on the strip.
function WoWWhatsApp.Resend()
	local c = ActiveChat()
	if not c or not c.pendingId then return end
	local text
	for i = #c.history, 1, -1 do
		if c.history[i].id == c.pendingId and c.history[i].role == "user" then
			text = c.history[i].text
			break
		end
	end
	if not text then return end
	run.outbound[c.pendingId] = { chat = c.id, flags = "", name = c.name, text = text, sentAt = GetTime() }
	run.sentAt = GetTime()
	run.polls = 0
	ScheduleNextPoll()
	RefreshStrip()
	WoWWhatsApp.UpdateStatus()
end

function WoWWhatsApp.SendFromInput()
	if not ui.input then return end
	local text = ui.input:GetText()
	ui.input:SetText("")
	ui.input:ClearFocus() -- hand the keyboard back to the game after sending
	WoWWhatsApp.Send(text)
end

---------------------------------------------------------------------------
-- Chats
---------------------------------------------------------------------------

function WoWWhatsApp.SwitchChat(id)
	local c = FindChat(id)
	if not c then return end
	local prev = ActiveChat()
	if prev and prev ~= c and ui.input then
		local typed = Trim(ui.input:GetText() or "")
		prev.draft = typed ~= "" and typed or nil
	end
	db.activeChat = c.id
	c.unread = 0
	if ui.input then
		ui.input:SetText(c.draft or "")
		c.draft = nil
	end
	run.scrollToEnd = true
	WoWWhatsApp.Render()
end

-- "+34 600 11 22 33" -> "34600112233@c.us"; nil when it doesn't look like a phone number.
local function PhoneId(text)
	local digits = tostring(text or ""):gsub("[%s%-%.%(%)]", ""):gsub("^%+", ""):gsub("^00", "")
	if digits:match("^%d+$") and #digits >= 7 and #digits <= 15 then return digits .. "@c.us", digits end
end

-- Start (or go to) a chat with a phone number written with its country code.
function WoWWhatsApp.NewChat(number)
	local id, digits = PhoneId(number)
	if not id then
		local a = ActiveChat()
		AddHistory(a, "system", "To start a chat, give a phone number with its country code: /wa new 34600112233")
		WoWWhatsApp.Render()
		WoWWhatsApp.Toggle(true)
		return
	end
	local c = FindChat(id)
	if not c then
		c = AddChat(digits, id)
		if not c then
			AddHistory(ActiveChat(), "system", "Chat list full and every chat has something unread or pending.")
			WoWWhatsApp.Render()
			return
		end
	end
	WoWWhatsApp.SwitchChat(c.id)
	WoWWhatsApp.Toggle(true)
end

StaticPopupDialogs["WOWWHATSAPP_NEW"] = {
	text = "New WhatsApp chat\n\nPhone number with country code, digits only.\nExample: 34600112233",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = 24,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText("")
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		WoWWhatsApp.NewChat(box and box:GetText() or "")
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWWHATSAPP_NEW"].OnAccept(dialog)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

function WoWWhatsApp.NewChatPrompt()
	StaticPopup_Show("WOWWHATSAPP_NEW")
end

StaticPopupDialogs["WOWWHATSAPP_RENAME"] = {
	text = "Rename this chat",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = 24,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.name or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		local name = box and Trim(box:GetText() or "") or ""
		if chat and name ~= "" then
			chat.name = name:sub(1, 24)
			chat.customName = true
			WoWWhatsApp.Render()
		end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWWHATSAPP_RENAME"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Rename dialog for a chat (the active one when no id is given).
function WoWWhatsApp.RenamePrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWWHATSAPP_RENAME", nil, nil, { id = c.id, name = c.name })
end
WoWWhatsApp.RenameActive = WoWWhatsApp.RenamePrompt

-- Delete a chat. The last one is cleared instead of removed, and either way the
-- bridge is told to forget it, so a restore won't bring it back.
function WoWWhatsApp.DeleteChat(id)
	local c, idx = nil, nil
	if id then c, idx = FindChat(id) else c, idx = ActiveChat() end
	if not c then return end
	ForgetOnBridge(c)
	if #db.chats <= 1 then
		wipe(c.history)
		c.pendingId, c.unread, c.draft = nil, 0, nil
		c.name = "Chat 1"
		c.customName, c.remoteName, c.isGroup = nil, nil, nil
		WoWWhatsApp.Render()
		return
	end
	table.remove(db.chats, idx)
	if db.activeChat == c.id then
		WoWWhatsApp.SwitchChat(db.chats[math.min(idx, #db.chats)].id)
	else
		WoWWhatsApp.Render()
	end
end

-- The trash can asks first; /wa delete does not.
StaticPopupDialogs["WOWWHATSAPP_DELETE"] = {
	text = "Delete chat \"%s\"?\n\nIts history goes away from the game (WhatsApp itself keeps the conversation). The last chat is cleared instead of removed.",
	button1 = OKAY,
	button2 = CANCEL,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnAccept = function(dialog, data)
		if data then WoWWhatsApp.DeleteChat(data.id) end
	end,
}

function WoWWhatsApp.ConfirmDelete(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWWHATSAPP_DELETE", Display(c.name), nil, { id = c.id })
end

function WoWWhatsApp.ClearChat(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	wipe(c.history)
	WoWWhatsApp.Render()
end

---------------------------------------------------------------------------
-- Look: a flat messenger window (chat list on the left, bubbles on the right)
---------------------------------------------------------------------------

local COLOR = {
	frame   = { 0.07, 0.08, 0.10, 0.98 },
	border  = { 0.20, 0.22, 0.26, 1 },
	header  = { 0.04, 0.30, 0.26, 1 },
	panel   = { 0.09, 0.10, 0.12, 1 },
	area    = { 0.05, 0.06, 0.075, 1 },
	mine    = { 0.00, 0.36, 0.30, 1 },
	theirs  = { 0.17, 0.19, 0.22, 1 },
	pill    = { 0.15, 0.18, 0.21, 0.95 },
	field   = { 0.13, 0.15, 0.18, 1 },
	accent  = { 0.15, 0.82, 0.45, 1 },
	text    = { 0.93, 0.95, 0.96 },
	dim     = { 0.62, 0.66, 0.70 },
	warn    = { 0.95, 0.70, 0.30 },
	bad     = { 0.95, 0.40, 0.40 },
}
local AVATAR_COLORS = {
	{ 0.20, 0.65, 0.45 }, { 0.25, 0.52, 0.85 }, { 0.80, 0.45, 0.25 }, { 0.62, 0.38, 0.80 },
	{ 0.85, 0.65, 0.20 }, { 0.80, 0.33, 0.45 }, { 0.30, 0.70, 0.75 }, { 0.55, 0.65, 0.30 },
}
local FLAT = "Interface\\Buttons\\WHITE8X8"
local LIST_W, HEADER_H, ROW_H = 230, 44, 54
local TITLE_H = 30

local function ColorFor(key)
	key = tostring(key or "")
	local h = 0
	for i = 1, #key do h = (h * 31 + key:byte(i)) % 997 end
	return AVATAR_COLORS[h % #AVATAR_COLORS + 1]
end

-- First character (UTF-8 aware), upper-cased when plain ASCII.
local function Initial(name)
	local ch = tostring(name or ""):match("^[%w\128-\255]") and tostring(name):match("^[%z\1-\127\194-\244][\128-\191]*") or "#"
	return ch:upper()
end

local function Paint(tex, c, alpha)
	tex:SetColorTexture(c[1], c[2], c[3], alpha or c[4] or 1)
end

local function ClockOf(t) return date("%H:%M", t) end
local function DayKey(t) return date("%Y%m%d", t) end
local function DayLabel(t)
	local key, now = DayKey(t), time()
	if key == DayKey(now) then return "Today" end
	if key == DayKey(now - 86400) then return "Yesterday" end
	return date("%d %b %Y", t)
end
-- List rows: the time today, otherwise the day.
local function ShortStamp(t)
	local key, now = DayKey(t), time()
	if key == DayKey(now) then return ClockOf(t) end
	if key == DayKey(now - 86400) then return "Yesterday" end
	return date("%d/%m", t)
end

-- A plain rectangular button; SetText/Enable/Disable work like the real thing.
local function FlatButton(parent, label, width, height, onClick, color)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(width, height)
	b.base = color or COLOR.field
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	Paint(b.bg, b.base)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.12)
	b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.label:SetText(label)
	b.SetText = function(self, t) self.label:SetText(t) end
	b.Enable = function(self) self.disabled = nil; Paint(self.bg, self.base) end
	b.Disable = function(self) self.disabled = true; Paint(self.bg, self.base, 0.35) end
	b:SetScript("OnClick", function(self, ...)
		if not self.disabled and onClick then onClick(self, ...) end
	end)
	return b
end

-- Mouse wheel scrolling for a plain ScrollFrame.
local function WheelScroll(sf, step)
	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function(self, delta)
		local cur, max = self:GetVerticalScroll() or 0, self:GetVerticalScrollRange() or 0
		self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * step)))
	end)
end

-- Round an avatar when the client can mask textures; square otherwise.
local function Round(tex, parent)
	if parent.CreateMaskTexture and tex.AddMaskTexture then
		local ok, mask = pcall(parent.CreateMaskTexture, parent)
		if ok and mask then
			mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			mask:SetAllPoints(tex)
			tex:AddMaskTexture(mask)
		end
	end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function WoWWhatsApp.UpdateStatus()
	if not ui.status then return end
	local c = ActiveChat()
	local mode = db.settings.mode
	local s, problem
	if c and c.pendingId then
		local id = c.pendingId
		local elapsed = run.sentAt and (GetTime() - run.sentAt) or 0
		local rec = run.outbound[id]
		if mode == "pixel" then
			if run.slotsMissing then
				s, problem = "Reply slots not installed (run install-slots.js, restart WoW). Using reload instead: Enter or Reload", true
			elseif run.slotsExhausted then
				s, problem = "Slot pool used up this session - next keypress reloads to free it", true
			elseif run.pixelFailed then
				s, problem = "Bridge didn't see #" .. id .. " after " .. STRIP_TRIES .. " tries - next keypress switches to the reload path (or /wa reload)", true
			elseif rec and not rec.acked then
				s = "Sending #" .. id .. (rec.tries and rec.tries > 1 and (" (try " .. rec.tries .. "/" .. STRIP_TRIES .. ")") or "") .. "..."
				if WoWWhatsApp.BridgeState() == "down" then s, problem = s .. " - bridge not seen lately, is the bridge running?", true end
			else
				s = "Waiting for WhatsApp to take #" .. id .. " (checked " .. (run.polls or 0) .. "x)"
				if elapsed > 45 then s, problem = s .. " - no sign of the bridge. Is it running? /wa resend", true end
			end
		else
			s = "Message #" .. id .. " goes out on reload. Enter or Reload checks now"
			if db.settings.autoRefresh then s = s .. "; auto on next keypress after " .. db.settings.interval .. "s" end
		end
	elseif not WoWWhatsApp.IsConnected() then
		problem = true
		if run.connectingAt and run.sendOnConnect then
			s = "Connecting to the bridge... your message goes out as soon as it answers"
		elseif run.connectingAt then
			s = "Connecting to the bridge..."
		elseif run.connectFailed then
			s = "No answer from the bridge. Is it running (npm start)? Connect tries again"
		elseif WoWWhatsApp.BridgeState() == "stale" then
			s = "Bridge not seen for a while - click Reconnect"
		else
			s = "Not connected - start the bridge, then click Connect"
		end
	elseif run.restoring then
		s = "Connecting to the bridge..."
	elseif c and IsWhatsAppId(c.id) then
		s = c.isGroup and "Group" or (c.id:match("^(%d+)@c%.us$") and ("+" .. c.id:match("^(%d+)@c%.us$")) or "WhatsApp")
	else
		s = "Not linked to a WhatsApp contact - delete it and start a chat with the + button"
	end
	run.statusText = s
	ui.status:SetText(s)
	local tone = problem and COLOR.warn or COLOR.dim
	ui.status:SetTextColor(tone[1], tone[2], tone[3])
	WoWWhatsApp.UpdateDot()
	WoWWhatsApp.UpdateConnect()
	if ui.title then ui.title:SetText(c and Display(c.name) or "WhatsApp") end
	if ui.avatar and c then
		Paint(ui.avatar, ColorFor(c.id))
		ui.avatarInitial:SetText(Initial(c.name))
	end
	if ui.resend then ui.resend:SetShown(c and c.pendingId ~= nil and mode == "pixel") end
	if ui.refresh then ui.refresh:SetShown(mode ~= "pixel" or run.slotsExhausted or run.slotsMissing or run.pixelFailed or false) end
	WoWWhatsApp.UpdateMini()
end

-- One row of the conversation: a bubble, a date pill or a centred note.
local function GetItem(i)
	local b = ui.items[i]
	if b then return b end
	b = CreateFrame("Frame", nil, ui.content)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.who = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.who:SetJustifyH("LEFT")
	b.qbar = b:CreateTexture(nil, "BORDER")
	b.qbar:SetWidth(2)
	b.quote = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.quote:SetJustifyH("LEFT")
	b.quote:SetWordWrap(false)
	b.body = b:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	b.body:SetJustifyH("LEFT")
	b.body:SetJustifyV("TOP")
	b.body:SetWordWrap(true)
	b.body:SetNonSpaceWrap(true)
	b.when = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.tick = b:CreateTexture(nil, "OVERLAY")
	b.tick:SetSize(12, 12)
	-- FontStrings can't be selected, so a click opens the message in the copy box.
	b:EnableMouse(true)
	b:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and self.text and self.text ~= "" then WoWWhatsApp.ShowCopy(self.text) end
	end)
	ui.items[i] = b
	return b
end

local TICK = {
	sent = "Interface\\RAIDFRAME\\ReadyCheck-Ready",
	pending = "Interface\\RAIDFRAME\\ReadyCheck-Waiting",
	failed = "Interface\\RAIDFRAME\\ReadyCheck-NotReady",
}

local PAD_X, PAD_Y = 10, 6

function WoWWhatsApp.Render()
	local c = ActiveChat()
	if ui.content and c then
		local width = ui.scroll:GetWidth()
		if not width or width < 120 then width = 460 end
		ui.content:SetWidth(width)
		local maxInner = math.max(120, math.floor(width * 0.72) - 2 * PAD_X)
		local y, n, prevKey = 4, 0, nil
		local function Natural(text)
			ui.measure:SetText(text)
			return ui.measure:GetStringWidth() or 0
		end
		-- kind: "msg" (m = history entry), "date" or "note" (text only)
		local function Place(kind, text, m)
			n = n + 1
			local b = GetItem(n)
			b.text = text
			b.who:Hide(); b.quote:Hide(); b.qbar:Hide(); b.tick:Hide(); b.when:SetText("")
			b:ClearAllPoints()
			b.body:ClearAllPoints()
			b.when:ClearAllPoints()
			b.tick:ClearAllPoints()
			if kind == "date" or kind == "note" then
				local w = math.min(kind == "date" and 200 or maxInner, Natural(text) + 4)
				b.body:SetWidth(w)
				b.body:SetJustifyH("CENTER")
				b.body:SetText(Display(text))
				local tone = kind == "date" and COLOR.text or COLOR.dim
				b.body:SetTextColor(tone[1], tone[2], tone[3])
				local h = b.body:GetStringHeight()
				if not h or h < 1 then h = 14 end
				b.body:SetPoint("TOP", b, "TOP", 0, -4)
				Paint(b.bg, COLOR.pill, kind == "date" and 0.95 or 0.5)
				b:SetSize(w + 20, h + 8)
				b:SetPoint("TOP", ui.content, "TOP", 0, -y)
				b.text = kind == "note" and text or nil
				b:Show()
				y = y + b:GetHeight() + 8
				prevKey = nil
				return
			end
			local mine = m.role == "user"
			local group = c.isGroup and not mine and m.sender and m.sender ~= ""
			local quote = m.replyTo and m.replyTo ~= "" and ("Reply to " .. Display(m.replyTo)) or nil
			-- Size the bubble to its content, up to 72% of the window.
			local bodyW = math.min(maxInner, Natural(Display(text)) + 4)
			local inner = math.max(bodyW, 58)
			if group then
				b.who:SetText(Display(m.sender))
				local sc = ColorFor(m.sender)
				b.who:SetTextColor(sc[1], sc[2], sc[3])
				inner = math.max(inner, math.min(maxInner, b.who:GetStringWidth() or 0))
			end
			if quote then
				b.quote:SetText(quote)
				inner = math.max(inner, math.min(maxInner, (b.quote:GetStringWidth() or 0) + 8))
			end
			local top = PAD_Y
			if group then
				b.who:SetPoint("TOPLEFT", b, "TOPLEFT", PAD_X, -top)
				b.who:SetWidth(inner)
				b.who:Show()
				top = top + 14
			end
			if quote then
				b.qbar:SetPoint("TOPLEFT", b, "TOPLEFT", PAD_X, -top)
				b.qbar:SetHeight(12)
				b.qbar:SetColorTexture(COLOR.accent[1], COLOR.accent[2], COLOR.accent[3], 0.9)
				b.qbar:Show()
				b.quote:SetPoint("TOPLEFT", b, "TOPLEFT", PAD_X + 6, -top)
				b.quote:SetWidth(inner - 6)
				b.quote:Show()
				top = top + 16
			end
			b.body:SetJustifyH("LEFT")
			b.body:SetPoint("TOPLEFT", b, "TOPLEFT", PAD_X, -top)
			b.body:SetWidth(bodyW)
			b.body:SetText(Display(text))
			local failed, pending = m.failed, mine and not m.sent and not m.failed
			local tone = (m.role == "system") and COLOR.dim or COLOR.text
			b.body:SetTextColor(tone[1], tone[2], tone[3])
			local h = b.body:GetStringHeight()
			if not h or h < 1 then h = 14 end
			b.when:SetText(m.t and ClockOf(m.t) or "")
			b.when:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -PAD_X - (mine and 15 or 0), 4)
			if mine then
				b.tick:SetTexture(failed and TICK.failed or (pending and TICK.pending) or TICK.sent)
				b.tick:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -PAD_X + 1, 3)
				b.tick:Show()
			end
			Paint(b.bg, mine and COLOR.mine or COLOR.theirs)
			b:SetSize(inner + 2 * PAD_X, top + h + 2 + 12 + PAD_Y)
			-- Same sender twice in a row sit closer together.
			local key = (mine and "me" or tostring(m.sender or "them"))
			if prevKey == key then y = y - 4 end
			prevKey = key
			if mine then
				b:SetPoint("TOPRIGHT", ui.content, "TOPRIGHT", -6, -y)
			else
				b:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 6, -y)
			end
			b:Show()
			y = y + b:GetHeight() + 6
		end

		local lastDay
		for _, m in ipairs(c.history) do
			if m.t then
				local day = DayKey(m.t)
				if day ~= lastDay then
					lastDay = day
					Place("date", DayLabel(m.t))
				end
			end
			if m.role == "system" then
				Place("note", m.text)
			else
				Place("msg", m.text, m)
			end
		end
		if #c.history == 0 then
			if run.restoring then
				Place("note", "Connecting to the bridge and restoring your chats...")
			elseif not WoWWhatsApp.IsConnected() then
				Place("note", "Not connected to the bridge. Start it (npm start in the wow-whatsapp folder), then click Connect below.")
			else
				Place("note", "No messages yet. Type below to write to this chat. Shift-click an item or spell to link it by name.")
			end
		end
		for i = n + 1, #ui.items do
			ui.items[i]:Hide()
		end
		ui.content:SetHeight(math.max(y, 1))
		local atEnd = run.scrollToEnd or (ui.scroll:GetVerticalScroll() or 0) >= (ui.scroll:GetVerticalScrollRange() or 0) - 40
		run.scrollToEnd = nil
		if atEnd then
			C_Timer.After(0.05, function()
				if ui.scroll then ui.scroll:SetVerticalScroll(ui.scroll:GetVerticalScrollRange() or 0) end
			end)
		end
	end
	WoWWhatsApp.UpdateStatus()
	WoWWhatsApp.RenderChatList()
end

-- Copy box (/wa copy, or click a message): a selectable EditBox pre-highlighted for Ctrl+C.
function WoWWhatsApp.ShowCopy(text)
	if not ui.copy then
		local cf = CreateFrame("Frame", "WoWWhatsAppCopy", UIParent, "BackdropTemplate")
		cf:SetSize(560, 320)
		cf:SetPoint("CENTER")
		cf:SetFrameStrata("FULLSCREEN_DIALOG")
		cf:SetMovable(true)
		cf:SetClampedToScreen(true)
		cf:EnableMouse(true)
		cf:RegisterForDrag("LeftButton")
		cf:SetScript("OnDragStart", cf.StartMoving)
		cf:SetScript("OnDragStop", cf.StopMovingOrSizing)
		cf:SetBackdrop(BACKDROP)
		cf:SetBackdropColor(COLOR.frame[1], COLOR.frame[2], COLOR.frame[3], 0.98)
		cf:SetBackdropBorderColor(COLOR.border[1], COLOR.border[2], COLOR.border[3], 1)
		tinsert(UISpecialFrames, "WoWWhatsAppCopy")

		local t = cf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -12)
		t:SetText("Text is selected - press Ctrl+C, then Esc")

		local x = CreateFrame("Button", nil, cf, "UIPanelCloseButton")
		x:SetPoint("TOPRIGHT", cf, "TOPRIGHT", -4, -4)

		local sc = CreateFrame("ScrollFrame", "WoWWhatsAppCopyScroll", cf, "UIPanelScrollFrameTemplate")
		sc:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -36)
		sc:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -32, 14)
		local eb = CreateFrame("EditBox", "WoWWhatsAppCopyBox", sc)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject(ChatFontNormal)
		eb:SetMaxLetters(0)
		eb:SetSize(500, 260)
		eb:SetScript("OnEscapePressed", function() cf:Hide() end)
		sc:SetScrollChild(eb)
		sc:HookScript("OnSizeChanged", function(self, w) eb:SetWidth(w) end)
		ui.copy, ui.copyBox = cf, eb
	end
	ui.copyBox:SetText(text)
	ui.copy:Show()
	ui.copyBox:SetFocus()
	ui.copyBox:HighlightText()
end

-- The chat list: newest conversation first, filtered by the search box.
local function SortedChats()
	local list = {}
	local filter = ui.filter and ui.filter ~= "" and ui.filter:lower() or nil
	for i, c in ipairs(db.chats) do
		if not filter or tostring(c.name):lower():find(filter, 1, true) then
			table.insert(list, { chat = c, order = i, last = LastActivity(c) })
		end
	end
	table.sort(list, function(a, b)
		if a.last ~= b.last then return a.last > b.last end
		return a.order < b.order
	end)
	return list
end

local function GetRow(i)
	local b = ui.rows[i]
	if b then return b end
	b = CreateFrame("Button", nil, ui.listContent)
	b:SetHeight(ROW_H)
	b.selected = b:CreateTexture(nil, "BACKGROUND")
	b.selected:SetAllPoints()
	Paint(b.selected, { 1, 1, 1, 0.09 })
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.05)
	b.avatar = b:CreateTexture(nil, "ARTWORK")
	b.avatar:SetSize(38, 38)
	b.avatar:SetPoint("LEFT", b, "LEFT", 10, 0)
	b.avatar:SetColorTexture(0.3, 0.3, 0.3, 1)
	Round(b.avatar, b)
	b.initial = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	b.initial:SetPoint("CENTER", b.avatar, "CENTER", 0, 0)
	b.initial:SetTextColor(1, 1, 1)
	b.stamp = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.stamp:SetPoint("TOPRIGHT", b, "TOPRIGHT", -10, -10)
	b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	b.name:SetPoint("TOPLEFT", b.avatar, "TOPRIGHT", 10, -2)
	b.name:SetPoint("RIGHT", b.stamp, "LEFT", -6, 0)
	b.name:SetJustifyH("LEFT")
	b.name:SetWordWrap(false)
	b.badge = b:CreateTexture(nil, "ARTWORK")
	b.badge:SetSize(20, 16)
	b.badge:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -10, 9)
	Paint(b.badge, COLOR.accent)
	Round(b.badge, b)
	b.count = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.count:SetPoint("CENTER", b.badge, "CENTER", 0, 0)
	b.count:SetTextColor(0.02, 0.1, 0.05)
	b.preview = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.preview:SetPoint("BOTTOMLEFT", b.avatar, "BOTTOMRIGHT", 10, 2)
	b.preview:SetPoint("RIGHT", b, "RIGHT", -38, 0)
	b.preview:SetJustifyH("LEFT")
	b.preview:SetWordWrap(false)
	-- Left-click opens the chat; right-click opens its menu (Rename, Clear, Delete).
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			WoWWhatsApp.ShowChatMenu(self.chatId, self)
		else
			WoWWhatsApp.SwitchChat(self.chatId)
		end
	end)
	b:SetScript("OnDoubleClick", function(self)
		WoWWhatsApp.SwitchChat(self.chatId)
		WoWWhatsApp.RenamePrompt(self.chatId)
	end)
	ui.rows[i] = b
	return b
end

local function PreviewOf(c)
	if c.pendingId then return "|cffd0d0d0Sending...|r" end
	local m = c.history[#c.history]
	if not m then return "" end
	local flat = (tostring(m.text or ""):gsub("%s+", " "))
	local prefix = ""
	if m.role == "user" then prefix = "You: "
	elseif c.isGroup and m.sender and m.sender ~= "" then prefix = m.sender .. ": " end
	return Display(prefix .. flat)
end

function WoWWhatsApp.RenderChatList()
	if not ui.rows then return end
	local list = SortedChats()
	for i, entry in ipairs(list) do
		local c = entry.chat
		local b = GetRow(i)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", ui.listContent, "TOPLEFT", 0, -(i - 1) * ROW_H)
		b:SetPoint("TOPRIGHT", ui.listContent, "TOPRIGHT", 0, -(i - 1) * ROW_H)
		Paint(b.avatar, ColorFor(c.id))
		b.initial:SetText(Initial(c.name))
		b.name:SetText(Display(c.name))
		b.stamp:SetText(#c.history > 0 and entry.last > 0 and ShortStamp(entry.last) or "")
		b.preview:SetText(PreviewOf(c))
		local unread = c.unread or 0
		b.badge:SetShown(unread > 0)
		b.count:SetText(unread > 0 and (unread > 99 and "99+" or tostring(unread)) or "")
		b.chatId = c.id
		b.selected:SetShown(c.id == db.activeChat)
		b:Show()
	end
	for i = #list + 1, #ui.rows do ui.rows[i]:Hide() end
	ui.listContent:SetHeight(math.max(#list * ROW_H, 1))
end

function WoWWhatsApp.UpdateMini()
	if not ui.miniBadge then return end
	local unread, sending = 0, 0
	for _, c in ipairs(db.chats) do
		unread = unread + (c.unread or 0)
		if c.pendingId then sending = sending + 1 end
	end
	local t
	if unread > 0 then
		t = "|cff25d366" .. unread .. (unread == 1 and " new message" or " new messages") .. "|r"
	elseif sending > 0 then
		t = "|cffd0d0d0sending...|r"
	else
		t = "|cff999999no new messages|r"
	end
	ui.miniBadge:SetText(t)
	if ui.miniPulse then
		if unread > 0 then
			if not ui.miniPulse:IsPlaying() then ui.miniPulse:Play() end
		else
			ui.miniPulse:Stop()
			ui.miniBadge:SetAlpha(1)
		end
	end
end

---------------------------------------------------------------------------
-- Notifications and the game chat
---------------------------------------------------------------------------

local ECHO_DEFAULT = 4000 -- characters of a message to print into the game chat ("/wa echo <n>")

local function OpenLink(chat)
	return "|Hwhatsapp:open:" .. chat.id .. "|h|cff7ec8ff[open]|r|h"
end

-- Print an incoming message into the game chat, whisper style: the name is a
-- link that starts a reply in the chat box. `short` prints one preview line.
local function EchoToChat(chat, text, sender)
	local mode = db.settings.echo
	if mode == "off" then return end
	local who = Display(chat.name) .. (sender and sender ~= "" and (" · " .. Display(sender)) or "")
	local prefix = "|cff25d366WhatsApp|r |Hwhatsapp:whatsapp:" .. chat.id .. "|h|cff66ffcc[" .. who .. "]|r|h: "
	local body = Display(text)
	if mode == "short" then
		local flat = (body:gsub("%s+", " "))
		if #flat > 200 then flat = flat:sub(1, 200) .. " ..." end
		print(prefix .. flat .. "  " .. OpenLink(chat))
		return
	end
	local limit = tonumber(mode) or ECHO_DEFAULT
	local first, shown = true, 0
	for line in (body .. "\n"):gmatch("(.-)\n") do
		if line:match("%S") then
			if shown + #line > limit then
				print("    |cff888888... " .. (#body - shown) .. " more characters, click [open] to read it all|r")
				break
			end
			print((first and prefix or "    ") .. line)
			first = false
			shown = shown + #line
		end
	end
	print("    " .. OpenLink(chat))
end

NotifyIncoming = function(chat, text, sender)
	pcall(PlaySound, 3081)
	WoWWhatsApp.UpdateMini()
	-- Until a real whisper arrives, /r replies to this chat.
	run.lastMessenger = "whatsapp"
	run.lastReplyChat = chat.id
	EchoToChat(chat, text, sender)
	if ui.frame and ui.frame:IsShown() and db.activeChat == chat.id then return end
	if UIErrorsFrame then
		UIErrorsFrame:AddMessage("WhatsApp: " .. Display(chat.name), 0.4, 1, 0.8, 1)
	end
end

-- /r goes to WhatsApp when WhatsApp was the last one to message you, exactly like
-- whisper reply, and the box shows a "To WhatsApp [chat]:" header while you type.
--
-- The chat type underneath is left alone (a custom type would leak into chat
-- settings); instead the box remembers a WhatsApp target, the header is repainted
-- over the game's own, and the send entry points are intercepted. Any other chat
-- type, Tab, Esc or a cleared box drops the target again.
local function PaintTargetHeader(eb, chat)
	local header = _G[eb:GetName() .. "Header"]
	local suffix = _G[eb:GetName() .. "HeaderSuffix"]
	if not header then return end
	eb.whatsappPainting = true
	eb:UpdateHeader() -- lay out normally first, then repaint
	eb.whatsappPainting = nil
	header:SetWidth(0)
	header:SetText("To WhatsApp [" .. Display(chat.name) .. "]: ")
	header:SetTextColor(0.4, 1, 0.8)
	if suffix then suffix:Hide() end
	eb:SetTextInsets(15 + header:GetWidth(), 13, 0, 0)
	eb:SetTextColor(0.4, 1, 0.8)
end

local function SendBoxToTarget(eb)
	local chat = FindChat(eb.whatsappTarget)
	local text = Trim(eb:GetText() or "")
	eb.whatsappTarget = nil
	eb:ClearChat()
	if chat and db.activeChat ~= chat.id then WoWWhatsApp.SwitchChat(chat.id) end
	if text ~= "" then
		WoWWhatsApp.Send(text, chat)
	else
		WoWWhatsApp.Toggle(true)
		if ui.input then ui.input:SetFocus() end
	end
end

local function HookReplyCommand()
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local eb = _G["ChatFrame" .. i .. "EditBox"]
		if eb and eb.ProcessChatType and not eb.whatsappReplyHooked then
			eb.whatsappReplyHooked = true

			local origProcess = eb.ProcessChatType
			eb.ProcessChatType = function(self, msg, index, send, ...)
				if index ~= "REPLY" then
					self.whatsappTarget = nil
					return origProcess(self, msg, index, send, ...)
				end
				if not (db and run.lastMessenger == "whatsapp") then
					return origProcess(self, msg, index, send, ...)
				end
				local chat = FindChat(run.lastReplyChat) or ActiveChat()
				self.whatsappTarget = chat and chat.id
				self:SetText(msg or "")
				if send == 1 then
					SendBoxToTarget(self)
					return true
				end
				if chat then PaintTargetHeader(self, chat) end
				return true
			end

			-- Enter arrives here; nothing below us ever sees a WhatsApp-targeted box.
			for _, name in ipairs({ "SendMessage", "SendText" }) do
				local orig = eb[name]
				if orig then
					eb[name] = function(self, ...)
						if self.whatsappTarget then
							SendBoxToTarget(self)
							return
						end
						return orig(self, ...)
					end
				end
			end

			-- Anything that repaints the header normally (Tab, /s, sticky reset) ends WhatsApp mode.
			hooksecurefunc(eb, "UpdateHeader", function(self)
				if not self.whatsappPainting then self.whatsappTarget = nil end
			end)
			hooksecurefunc(eb, "ClearChat", function(self)
				self.whatsappTarget = nil
			end)
		end
	end
end

-- Clicks on our name / [open] links in the chat frame.
hooksecurefunc("SetItemRef", function(link)
	local action, chatId = tostring(link):match("^whatsapp:(%a+):(.+)$")
	if not action or not db then return end
	local chat = FindChat(chatId)
	if chat then WoWWhatsApp.SwitchChat(chatId) end
	if action == "whatsapp" and chat then
		run.lastMessenger = "whatsapp"
		run.lastReplyChat = chat.id
		local eb = _G["ChatFrame1EditBox"]
		if eb then
			ChatEdit_ActivateChat(eb)
			eb:SetChatType("REPLY")
			eb.whatsappTarget = chat.id
			eb:SetText("")
			PaintTargetHeader(eb, chat)
		end
		return
	end
	WoWWhatsApp.Toggle(true)
end)

-- Shift-clicking an item, spell, quest or name puts its link into the chat box
-- being typed in. Blizzard's insert function only knows its own boxes, so when
-- ours has the keyboard, take the link too. With no box focused the shift-click
-- keeps its normal meaning (splitting a stack, for one).
--
-- On this client (modern UI code, Blizzard_ChatFrameUtil) every shift-click
-- ends in ChatFrameUtil.InsertLink; ChatEdit_InsertLink is the older global
-- name, hooked only where the new one is missing so one click inserts once.
local function TakeLink(text)
	if text and text ~= "" and ui.input and ui.input:HasFocus() then
		ui.input:Insert(text)
	end
end
if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
	hooksecurefunc(ChatFrameUtil, "InsertLink", TakeLink)
elseif type(ChatEdit_InsertLink) == "function" then
	hooksecurefunc("ChatEdit_InsertLink", TakeLink)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function BuildUI()
	if ui.frame then return end
	local s = db.settings

	local f = CreateFrame("Frame", "WoWWhatsAppFrame", UIParent, "BackdropTemplate")
	ui.frame = f
	f:SetSize(s.width, s.height)
	if s.point then
		f:SetPoint(s.point, UIParent, s.relPoint or s.point, s.x or 0, s.y or 0)
	else
		f:SetPoint("CENTER")
	end
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetResizable(true)
	f:SetClampedToScreen(true)
	f:SetResizeBounds(600, 340)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.point, s.relPoint, s.x, s.y = point, relPoint, x, y
	end)
	f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
	f:SetBackdropColor(COLOR.frame[1], COLOR.frame[2], COLOR.frame[3], COLOR.frame[4])
	f:SetBackdropBorderColor(COLOR.border[1], COLOR.border[2], COLOR.border[3], 1)
	f:Hide()
	tinsert(UISpecialFrames, "WoWWhatsAppFrame")

	-- Status light: green = bridge seen recently, yellow = stale, red = gone.
	local function MakeDot(parent)
		local holder = CreateFrame("Frame", nil, parent)
		holder:SetSize(16, 16)
		local dot = holder:CreateTexture(nil, "OVERLAY")
		dot:SetAllPoints()
		dot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")
		holder:EnableMouse(true)
		holder:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(dot.tip or "Bridge status", 0.9, 0.9, 0.9, 1, true)
			GameTooltip:Show()
		end)
		holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return holder, dot
	end

	-- Title bar
	local bar = f:CreateTexture(nil, "ARTWORK")
	bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
	bar:SetHeight(TITLE_H)
	Paint(bar, COLOR.header)

	local dotHolder, dot = MakeDot(f)
	dotHolder:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
	ui.dot = dot
	local brand = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	brand:SetPoint("LEFT", dotHolder, "RIGHT", 6, 0)
	brand:SetText("WhatsApp")
	brand:SetTextColor(1, 1, 1)

	-- Minimize button in the corner where a close X would be: this window is never
	-- closed from here, only collapsed to the mini bar (Esc does the same, see OnHide).
	-- The mini bar's own X is the one that hides everything.
	local mini = FlatButton(f, "_", 26, 22, function() WoWWhatsApp.Minimize(true) end, { 0, 0, 0, 0.0 })
	mini:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -5)
	mini:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Minimize to the small bar  (Esc)")
		GameTooltip:AddLine("Messages keep arriving; the bar shows when one lands.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	mini:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Esc (via UISpecialFrames) just calls Hide(); treat that as a minimize unless
	-- we're hiding on purpose. Ignore hides caused by the whole UI going away.
	f:SetScript("OnHide", function()
		if ui.quitting then
			ui.quitting = nil
			return
		end
		if not db or not db.settings.shown or not UIParent:IsShown() then return end
		db.settings.minimized = true
		if ui.mini then ui.mini:Show() end
		WoWWhatsApp.UpdateMini()
	end)

	-- Left panel: search, new chat, chat list
	local panel = CreateFrame("Frame", nil, f)
	panel:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -(TITLE_H + 1))
	panel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
	panel:SetWidth(LIST_W)
	local panelBg = panel:CreateTexture(nil, "BACKGROUND")
	panelBg:SetAllPoints()
	Paint(panelBg, COLOR.panel)
	local divider = f:CreateTexture(nil, "BORDER")
	divider:SetPoint("TOPLEFT", panel, "TOPRIGHT", 0, 0)
	divider:SetPoint("BOTTOMLEFT", panel, "BOTTOMRIGHT", 0, 0)
	divider:SetWidth(1)
	Paint(divider, COLOR.border)

	local newBtn = FlatButton(panel, "+", 28, 28, function() WoWWhatsApp.NewChatPrompt() end, COLOR.accent)
	newBtn.label:SetTextColor(0.02, 0.1, 0.05)
	newBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -8)
	newBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("New chat (phone number)")
		GameTooltip:Show()
	end)
	newBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local searchBg = CreateFrame("Frame", nil, panel)
	searchBg:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
	searchBg:SetPoint("RIGHT", newBtn, "LEFT", -6, 0)
	searchBg:SetHeight(28)
	local searchTex = searchBg:CreateTexture(nil, "BACKGROUND")
	searchTex:SetAllPoints()
	Paint(searchTex, COLOR.field)
	local search = CreateFrame("EditBox", "WoWWhatsAppSearch", searchBg)
	search:SetPoint("TOPLEFT", searchBg, "TOPLEFT", 8, 0)
	search:SetPoint("BOTTOMRIGHT", searchBg, "BOTTOMRIGHT", -8, 0)
	search:SetAutoFocus(false)
	search:SetFontObject(ChatFontNormal)
	search:SetMaxLetters(40)
	local searchHint = searchBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	searchHint:SetPoint("LEFT", searchBg, "LEFT", 8, 0)
	searchHint:SetText("Search chats")
	search:SetScript("OnTextChanged", function(self)
		local text = Trim(self:GetText() or "")
		ui.filter = text
		searchHint:SetShown(text == "")
		WoWWhatsApp.RenderChatList()
	end)
	search:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
	end)
	search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	ui.search = search

	local listScroll = CreateFrame("ScrollFrame", "WoWWhatsAppList", panel)
	listScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -44)
	listScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 4)
	local listContent = CreateFrame("Frame", "WoWWhatsAppListContent", listScroll)
	listContent:SetSize(LIST_W, 1)
	listScroll:SetScrollChild(listContent)
	WheelScroll(listScroll, ROW_H)
	ui.listScroll, ui.listContent, ui.rows = listScroll, listContent, {}
	listScroll:HookScript("OnSizeChanged", function(self, w) listContent:SetWidth(w) end)

	-- Per-chat menu, opened by right-clicking a chat row. A plain frame of our
	-- own rather than a Blizzard dropdown, so it looks the same on every client.
	local MENU_W, MENU_ITEM = 130, 22
	local menu = CreateFrame("Frame", "WoWWhatsAppChatMenu", f, "BackdropTemplate")
	menu:SetSize(MENU_W, 4 * MENU_ITEM + 28)
	menu:SetFrameStrata("TOOLTIP")
	menu:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
	menu:SetBackdropColor(0.10, 0.11, 0.14, 0.98)
	menu:SetBackdropBorderColor(COLOR.border[1], COLOR.border[2], COLOR.border[3], 1)
	menu:EnableMouse(true)
	menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	menu.title:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, -8)
	menu.title:SetPoint("RIGHT", menu, "RIGHT", -8, 0)
	menu.title:SetJustifyH("LEFT")
	menu.title:SetWordWrap(false)
	local function MenuItem(label, order, onClick)
		local it = CreateFrame("Button", nil, menu)
		it:SetSize(MENU_W - 8, MENU_ITEM)
		it:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -22 - (order - 1) * MENU_ITEM)
		local hl = it:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.10)
		it.label = it:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		it.label:SetPoint("LEFT", it, "LEFT", 6, 0)
		it.label:SetText(label)
		it:SetScript("OnClick", function()
			menu:Hide()
			onClick(menu.chatId)
		end)
		return it
	end
	MenuItem("Rename...", 1, WoWWhatsApp.RenamePrompt)
	MenuItem("Mark as read", 2, function(id)
		local c = FindChat(id)
		if c then c.unread = 0 WoWWhatsApp.Render() end
	end)
	MenuItem("Clear history", 3, WoWWhatsApp.ClearChat)
	MenuItem("Delete...", 4, WoWWhatsApp.ConfirmDelete)
	-- Close once the mouse has wandered away from the menu and the row it came from.
	menu:SetScript("OnUpdate", function(self, dt)
		if not MouseIsOver then return end
		if MouseIsOver(self) or (self.owner and MouseIsOver(self.owner)) then
			self.away = 0
		else
			self.away = (self.away or 0) + dt
			if self.away > 0.5 then self:Hide() end
		end
	end)
	menu:Hide()
	ui.chatMenu = menu

	function WoWWhatsApp.ShowChatMenu(chatId, anchor)
		local c = FindChat(chatId)
		if not c then return end
		if menu:IsShown() and menu.chatId == chatId then
			menu:Hide()
			return
		end
		menu.chatId = chatId
		menu.owner = anchor
		menu.away = 0
		menu.title:SetText(Display(c.name))
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 40, 2)
		menu:Show()
	end

	-- Right pane header: avatar, name, status line, and the buttons that only show when needed
	local header = f:CreateTexture(nil, "ARTWORK")
	header:SetPoint("TOPLEFT", panel, "TOPRIGHT", 1, 0)
	header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -(TITLE_H + 1))
	header:SetHeight(HEADER_H)
	Paint(header, COLOR.panel)

	local avatar = f:CreateTexture(nil, "OVERLAY")
	avatar:SetSize(32, 32)
	avatar:SetPoint("TOPLEFT", header, "TOPLEFT", 10, -6)
	avatar:SetColorTexture(0.3, 0.3, 0.3, 1)
	Round(avatar, f)
	ui.avatar = avatar
	ui.avatarInitial = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ui.avatarInitial:SetPoint("CENTER", avatar, "CENTER", 0, 0)
	ui.avatarInitial:SetTextColor(1, 1, 1)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", avatar, "TOPRIGHT", 10, 2)
	title:SetPoint("RIGHT", f, "RIGHT", -170, 0)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)
	title:SetTextColor(COLOR.text[1], COLOR.text[2], COLOR.text[3])
	ui.title = title

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	status:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
	status:SetPoint("RIGHT", f, "RIGHT", -170, 0)
	status:SetJustifyH("LEFT")
	status:SetWordWrap(false)
	ui.status = status

	-- Reload is the fallback transport's button; Resend puts a stuck message back on the strip.
	local refresh = FlatButton(f, "Reload", 56, 22, function() SafeReload() end)
	refresh:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -(TITLE_H + 12))
	refresh:Hide()
	ui.refresh = refresh
	local resend = FlatButton(f, "Resend", 56, 22, WoWWhatsApp.Resend)
	resend:SetPoint("RIGHT", refresh, "LEFT", -6, 0)
	resend:Hide()
	ui.resend = resend

	-- Conversation
	local areaBg = f:CreateTexture(nil, "BACKGROUND")
	areaBg:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
	areaBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
	Paint(areaBg, COLOR.area)

	-- Composer: input box with Send docked at its right end, like a messaging app.
	local SEND_W = 70
	local inputBg = CreateFrame("Frame", nil, f)
	inputBg:SetPoint("BOTTOMLEFT", panel, "BOTTOMRIGHT", 10, 10)
	inputBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10 - SEND_W - 6, 10)
	inputBg:SetHeight(38)
	local inputTex = inputBg:CreateTexture(nil, "BACKGROUND")
	inputTex:SetAllPoints()
	Paint(inputTex, COLOR.field)
	ui.inputBg = inputBg

	local inScroll = CreateFrame("ScrollFrame", "WoWWhatsAppInputScroll", inputBg)
	inScroll:SetPoint("TOPLEFT", inputBg, "TOPLEFT", 10, -7)
	inScroll:SetPoint("BOTTOMRIGHT", inputBg, "BOTTOMRIGHT", -10, 7)
	WheelScroll(inScroll, 14)

	local input = CreateFrame("EditBox", "WoWWhatsAppInput", inScroll)
	input:SetMultiLine(true)
	input:SetAutoFocus(false)
	input:SetFontObject(ChatFontNormal)
	input:SetMaxLetters(0)
	input:SetSize(400, 20)
	input:SetScript("OnEnterPressed", function() WoWWhatsApp.SendFromInput() end)
	input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	inScroll:SetScrollChild(input)
	inScroll:HookScript("OnSizeChanged", function(self, w, h)
		input:SetWidth(w)
	end)
	inputBg:EnableMouse(true)
	inputBg:SetScript("OnMouseDown", function() input:SetFocus() end)
	ui.input = input

	local placeholder = inputBg:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	placeholder:SetPoint("LEFT", inputBg, "LEFT", 12, 0)
	placeholder:SetText("Type a message")
	input:SetScript("OnTextChanged", function(self)
		local empty = (self:GetText() or "") == ""
		placeholder:SetShown(empty)
		-- The box grows with what is typed, up to about five lines.
		local h = empty and 20 or (self:GetHeight() or 20)
		inputBg:SetHeight(math.max(38, math.min(110, h + 18)))
	end)

	local send = FlatButton(f, "Send", SEND_W, 38, WoWWhatsApp.SendFromInput, COLOR.accent)
	send.label:SetTextColor(0.02, 0.1, 0.05)
	send:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
	ui.send = send

	-- Connect stands in for Send until the bridge has been seen (see UpdateConnect).
	local connect = FlatButton(f, "Connect", SEND_W, 38, WoWWhatsApp.Connect, COLOR.header)
	connect:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
	connect:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Connect to the bridge")
		GameTooltip:AddLine("The bridge must be running on this PC (npm start in wow-whatsapp). The light turns green once it answers.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	connect:SetScript("OnLeave", function() GameTooltip:Hide() end)
	connect:Hide()
	ui.connect = connect

	local scroll = CreateFrame("ScrollFrame", "WoWWhatsAppScroll", f)
	-- Opposite corners, so the rectangle is fully defined without over-constraining it.
	scroll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(TITLE_H + HEADER_H + 4))
	scroll:SetPoint("BOTTOMLEFT", inputBg, "TOPLEFT", -10, 8)
	WheelScroll(scroll, 60)
	ui.scroll = scroll

	local content = CreateFrame("Frame", "WoWWhatsAppContent", scroll)
	content:SetSize(500, 1)
	scroll:SetScrollChild(content)
	ui.content = content
	ui.items = {}
	ui.measure = f:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
	ui.measure:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	ui.measure:SetAlpha(0)
	scroll:HookScript("OnSizeChanged", function(self, w, h)
		if ui.frame:IsShown() then WoWWhatsApp.Render() end
	end)

	-- A named, always-present button so a keybinding can click it (see /wa bind).
	local hotkey = CreateFrame("Button", "WoWWhatsAppRefreshButton", UIParent)
	hotkey:SetSize(1, 1)
	hotkey:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
	hotkey:SetScript("OnClick", function()
		local c = ActiveChat()
		if c and c.pendingId then
			TryLoadSlot("manual")
		else
			WoWWhatsApp.Toggle()
		end
	end)

	-- Resize grip
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		s.width, s.height = f:GetSize()
	end)

	-- Mini bar: what the window collapses into. Click it to expand, drag to move.
	local m = CreateFrame("Frame", "WoWWhatsAppMini", UIParent, "BackdropTemplate")
	ui.mini = m
	m:SetSize(250, 30)
	if s.miniPoint then
		m:SetPoint(s.miniPoint, UIParent, s.miniRelPoint or s.miniPoint, s.miniX or 0, s.miniY or 0)
	else
		m:SetPoint("TOP", UIParent, "TOP", 0, -40)
	end
	m:SetFrameStrata("DIALOG")
	m:SetMovable(true)
	m:SetClampedToScreen(true)
	m:EnableMouse(true)
	m:RegisterForDrag("LeftButton")
	m:SetScript("OnDragStart", function(self)
		self.dragging = true
		self:StartMoving()
	end)
	m:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.miniPoint, s.miniRelPoint, s.miniX, s.miniY = point, relPoint, x, y
		C_Timer.After(0, function() self.dragging = nil end)
	end)
	m:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and not self.dragging then
			WoWWhatsApp.Minimize(false)
		end
	end)
	m:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
	m:SetBackdropColor(COLOR.header[1], COLOR.header[2], COLOR.header[3], 0.97)
	m:SetBackdropBorderColor(COLOR.border[1], COLOR.border[2], COLOR.border[3], 1)
	m:Hide()

	local miniDotHolder, miniDot = MakeDot(m)
	miniDotHolder:SetPoint("LEFT", m, "LEFT", 9, 0)
	ui.miniDot = miniDot

	local mlabel = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	mlabel:SetPoint("LEFT", miniDotHolder, "RIGHT", 6, 0)
	mlabel:SetText("WhatsApp")
	mlabel:SetTextColor(1, 1, 1)

	local badge = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	badge:SetPoint("LEFT", mlabel, "RIGHT", 8, 0)
	badge:SetPoint("RIGHT", m, "RIGHT", -26, 0)
	badge:SetJustifyH("LEFT")
	badge:SetWordWrap(false)
	ui.miniBadge = badge

	local ok, pulse = pcall(function()
		local g = badge:CreateAnimationGroup()
		local a1 = g:CreateAnimation("Alpha")
		a1:SetFromAlpha(1)
		a1:SetToAlpha(0.25)
		a1:SetDuration(0.6)
		a1:SetOrder(1)
		local a2 = g:CreateAnimation("Alpha")
		a2:SetFromAlpha(0.25)
		a2:SetToAlpha(1)
		a2:SetDuration(0.6)
		a2:SetOrder(2)
		g:SetLooping("REPEAT")
		return g
	end)
	if ok then ui.miniPulse = pulse end

	local mclose = CreateFrame("Button", nil, m, "UIPanelCloseButton")
	mclose:SetSize(24, 24)
	mclose:SetPoint("RIGHT", m, "RIGHT", -2, 0)
	mclose:SetScript("OnClick", function() WoWWhatsApp.Toggle(false) end)
	mclose:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Quit: hide completely (/wa brings it back)")
		GameTooltip:Show()
	end)
	mclose:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function WoWWhatsApp.Toggle(show)
	if not ui.frame then return end
	if show == nil then show = not ui.frame:IsShown() end
	if show then
		db.settings.minimized = false
		local c = ActiveChat()
		if c then c.unread = 0 end
		run.scrollToEnd = true
	end
	if ui.mini then ui.mini:Hide() end
	if not show then ui.quitting = true end
	ui.frame:SetShown(show)
	ui.quitting = nil
	db.settings.shown = show
	if show then
		WoWWhatsApp.Render()
		-- No auto-focus: the game keeps the keyboard until you click the box.
		-- No automatic hello either: if the bridge hasn't been seen, the panel
		-- shows Connect in place of Send and waits for a click.
	end
	WoWWhatsApp.UpdateMini()
end

function WoWWhatsApp.Minimize(mini)
	if not ui.frame then return end
	if mini == nil then mini = not db.settings.minimized end
	if mini then
		db.settings.minimized = true
		db.settings.shown = true
		ui.frame:Hide() -- OnHide shows the mini bar
		if ui.mini and not ui.mini:IsShown() then ui.mini:Show() end
		WoWWhatsApp.UpdateMini()
	else
		WoWWhatsApp.Toggle(true)
	end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local HELP = table.concat({
	"/wa                       toggle the WhatsApp window",
	"/wa mini                  collapse to the small bar",
	"/wa hide                  hide the window completely",
	"/wa <text>                send text to the current chat (/ai <text> too)",
	"/r <text>                 reply to the last WhatsApp message",
	"/wa new <phone number>    start a chat (country code, digits only)",
	"/wa chat <n|name>         switch chats",
	"/wa rename [name]         rename the current chat",
	"/wa delete                delete the current chat",
	"/wa clear                 clear this chat's history",
	"/wa echo full|short|off   incoming messages echoed to the game chat",
	"/wa mode pixel|reload     normal or reload fallback transport",
	"/wa reload                reload now and free the slot pool",
	"/wa copy                  copy the last received message",
	"/wa slots                 show remaining reply slots",
	"/wa diag                  show transport diagnostics",
}, "\n")

-- /ai <text>: send straight from the game chat box (like /r, but for WhatsApp).
SLASH_WHATSAPPASK1 = "/ai"
SLASH_WHATSAPPASK2 = "/ask"
SlashCmdList["WHATSAPPASK"] = function(msg)
	msg = Trim(msg or "")
	if msg == "" then
		WoWWhatsApp.Toggle(true)
	else
		WoWWhatsApp.Send(msg)
	end
end

local function ApplyLongChat()
	local box = ChatFrame1EditBox
	if not box or not box.SetMaxLetters then return end
	box:SetMaxLetters(db.settings.longchat and 4000 or 255)
end

local function FreeSlots()
	local free = 0
	for i = 1, SLOT_COUNT do
		if not C_AddOns.IsAddOnLoaded(SlotName(i)) then free = free + 1 end
	end
	return free
end

SLASH_WOWWHATSAPP1 = "/wow-whatsapp"
SLASH_WOWWHATSAPP2 = "/wa"
SLASH_WOWWHATSAPP3 = "/whatsapp"
SlashCmdList["WOWWHATSAPP"] = function(msg)
	msg = Trim(msg or "")
	local cmd, rest = msg:match("^(%S+)%s*(.-)$")
	cmd = cmd and cmd:lower() or ""
	local s = db.settings
	local c = ActiveChat()
	local function Note(text)
		AddHistory(c, "system", text)
		WoWWhatsApp.Render()
		WoWWhatsApp.Toggle(true)
	end

	if cmd == "" then
		WoWWhatsApp.Toggle()
	elseif cmd == "mini" or cmd == "min" then
		WoWWhatsApp.Minimize(true)
	elseif cmd == "new" then
		WoWWhatsApp.NewChat(rest)
	elseif cmd == "chat" or cmd == "chats" then
		local n = tonumber(rest)
		local target = n and db.chats[n]
		if not target and rest ~= "" then
			for _, ch in ipairs(db.chats) do
				if ch.name:lower() == rest:lower() then target = ch end
			end
			if not target then
				local id = PhoneId(rest)
				target = id and FindChat(id)
			end
		end
		if target then
			WoWWhatsApp.SwitchChat(target.id)
			WoWWhatsApp.Toggle(true)
		else
			local lines = {}
			for i, ch in ipairs(db.chats) do
				table.insert(lines, i .. ". " .. ch.name .. (ch.id == db.activeChat and "  (current)" or "") .. ((ch.unread or 0) > 0 and ("  " .. ch.unread .. " new") or ""))
			end
			Note("Chats:\n" .. table.concat(lines, "\n"))
		end
	elseif cmd == "rename" then
		if rest ~= "" then
			c.name = rest:sub(1, 24)
			c.customName = true
			WoWWhatsApp.Render()
		else
			WoWWhatsApp.RenameActive()
		end
		WoWWhatsApp.Toggle(true)
	elseif cmd == "delete" then
		WoWWhatsApp.DeleteChat()
	elseif cmd == "clear" then
		WoWWhatsApp.ClearChat()
	elseif cmd == "mode" then
		if rest == "pixel" or rest == "reload" then
			s.mode = rest
			Note("mode set to " .. rest)
		else
			Note("mode is " .. s.mode .. " (pixel or reload)")
		end
	elseif cmd == "resend" then
		WoWWhatsApp.Resend()
	elseif cmd == "auto" then
		local n = tonumber(rest)
		if n then
			s.interval = math.max(5, math.floor(n))
			s.autoRefresh = true
		elseif rest == "on" then
			s.autoRefresh = true
		elseif rest == "off" then
			s.autoRefresh = false
		end
		WoWWhatsApp.UpdateStatus()
		WoWWhatsApp.ArmAutoRefresh()
	elseif cmd == "hide" or cmd == "quit" then
		WoWWhatsApp.Toggle(false)
	elseif cmd == "copy" then
		for i = #c.history, 1, -1 do
			if c.history[i].role == "contact" then
				WoWWhatsApp.ShowCopy(c.history[i].text)
				break
			end
		end
	elseif cmd == "echo" then
		if rest == "full" or rest == "short" or rest == "off" then
			s.echo = rest
		elseif tonumber(rest) then
			s.echo = tostring(math.max(200, math.floor(tonumber(rest))))
		end
		Note("incoming messages in game chat: " .. s.echo .. " (full = " .. ECHO_DEFAULT .. " chars, short, off, or a number of characters)")
	elseif cmd == "longchat" then
		if rest == "on" then s.longchat = true elseif rest == "off" then s.longchat = false end
		ApplyLongChat()
		Note("game chat box limit: " .. (s.longchat and "4000 characters (fine for /ai; real chat over 255 may be rejected by the server)" or "255 (default)"))
	elseif cmd == "signal" then
		if rest == "on" then s.signal = true elseif rest == "off" then s.signal = false end
		Note("signal check is " .. (s.signal and "on" or "off"))
	elseif cmd == "slots" then
		Note(FreeSlots() .. " of " .. SLOT_COUNT .. " reply slots free this session (a reload frees all)")
	elseif cmd == "refresh" or cmd == "reload" then
		SafeReload()
	elseif cmd == "bind" then
		local key = rest:upper()
		if key ~= "" and not InCombatLockdown() then
			SetBinding(key, "CLICK WoWWhatsAppRefreshButton:LeftButton")
			SaveBindings(GetCurrentBindingSet())
			Note(key .. " is now bound: checks for delivery while a message is on its way, otherwise toggles this window")
		else
			Note("/wa bind <KEY>, for example /wa bind F9 (not in combat)")
		end
	elseif cmd == "diag" then
		local lines = {
			"sound channel: " .. (signalAvailable and "usable" or "UNUSABLE") .. " (self-test: " .. tostring(signalStats.selftest) .. ")" .. (signalStats.error and (" error: " .. signalStats.error) or ""),
			"signal setting: " .. tostring(s.signal) .. ", marked unreliable this session: " .. tostring(run.signalUnreliable or false),
			"sound checks: " .. signalStats.checks .. ", valid hits: " .. signalStats.hits .. (signalStats.lastHit and (", last hit " .. FmtDur(GetTime() - signalStats.lastHit) .. " ago") or ""),
			"slot polls this session: " .. (run.polls or 0) .. ", free slots: " .. FreeSlots() .. "/" .. SLOT_COUNT,
			"presence: head at " .. tostring(run.presence and run.presence.last or "?") .. ", beats seen: " .. tostring(run.presence and run.presence.beats or 0),
			select(5, WoWWhatsApp.BridgeState()),
			"mode: " .. s.mode .. ", session token: " .. tostring(db.session),
		}
		for _, ch in ipairs(db.chats) do
			if ch.pendingId then table.insert(lines, ch.name .. ": message #" .. ch.pendingId .. " not confirmed yet") end
		end
		Note("Diagnostics:\n" .. table.concat(lines, "\n"))
	elseif cmd == "cancel" then
		if c.pendingId then
			for i = #c.history, 1, -1 do
				local m = c.history[i]
				if m.role == "user" and m.id == c.pendingId then m.failed = true break end
			end
			AddHistory(c, "system", "Gave up waiting on #" .. c.pendingId)
			run.outbound[c.pendingId] = nil
			c.pendingId = nil
			RefreshStrip()
			if not AnyPending() then keyCatcher:Hide() end
		end
		WoWWhatsApp.Render()
	elseif cmd == "help" then
		Note(HELP)
	else
		WoWWhatsApp.Send(msg)
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:RegisterEvent("CHAT_MSG_BN_WHISPER")
ev:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			InitDB()
		end
	elseif event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER" then
		-- A real person whispered: /r belongs to them again.
		run.lastMessenger = "player"
	elseif event == "PLAYER_LOGIN" then
		if not db then InitDB() end
		BuildUI()
		run = { outbound = {} }
		SelfTestSignals()
		ProcessInbox()
		if AnyPending() then
			-- Still waiting after a reload: resume polling with a fresh slot pool.
			run.sentAt = GetTime()
			run.polls = 0
			ScheduleNextPoll()
		end
		local c = ActiveChat()
		if c and c.draft and c.draft ~= "" then
			ui.input:SetText(c.draft)
			if not c.pendingId then c.draft = nil end
		end
		run.scrollToEnd = true
		WoWWhatsApp.Render()
		if db.settings.shown then
			if db.settings.minimized then
				WoWWhatsApp.Minimize(true)
			else
				WoWWhatsApp.Toggle(true)
			end
		end
		WoWWhatsApp.ArmAutoRefresh()
		WoWWhatsApp.UpdateDot()
		if db.settings.longchat then ApplyLongChat() end
		HookReplyCommand()
		C_Timer.NewTicker(TICK_SECONDS, Tick)
		C_Timer.After(3, WoWWhatsApp.SayHello)
	elseif event == "PLAYER_REGEN_ENABLED" then
		if WoWWhatsApp.reloadAfterCombat then
			WoWWhatsApp.reloadAfterCombat = nil
			ReloadUI()
		elseif db then
			WoWWhatsApp.ArmAutoRefresh()
		end
	end
end)
