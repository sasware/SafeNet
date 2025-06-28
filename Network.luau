--!strict
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local IsServer = RunService:IsServer()

local Encryption = require("./Encryption.luau")
local Signal = require("./Signal.luau")

local Packet = {
    Status = {
        Success = newproxy(true),
        Error = newproxy(true),
        Timeout = newproxy(true),
    }
}

for Name, Status in next, Packet.Status do
    getmetatable(Status).__tostring = function()
        return Name
    end
end

type TotallyARemoteEventLinterLeaveMeAlone = RemoteEvent | nil

local _RespondToClientInvoke: (Player, number, string) -> ()
local ClientToServerInvokePlaceholder = function(Player : Player, PacketId : number, Packet : string) return "Unhandled C->S Invocation" end
local ServerToClientInvokePlaceholder = function(Packet : string) return "Unhandled S->C Invocation" end

type InvokePlaceholder = ((Player, number, string) -> string) | ((string) -> string)

local Network = {
    Remote = nil :: TotallyARemoteEventLinterLeaveMeAlone,
    PacketCache = {},
    PacketIds = { Send = 0, Invoke = 0 },
    Initialized = false,
    Timeout = 15,
}

local Entries = {}

if IsServer then
    Players.PlayerAdded:Connect(function(Player)
        Entries[Player] = {
            ClientExpectedInvokeId = 1,
            ClientExpectedSendId = 1,
            ServerNextInvokeId = 1,
            ServerNextSendId = 1,
            PacketCache = {}
        }
    end)

    Players.PlayerRemoving:Connect(function(Player)
        Entries[Player] = nil
    end)
end

local function CastToEncryptedBuffer(Packet : string | buffer) : buffer
    local ConvertedPacket = if type(Packet) == "string" then Packet else buffer.tostring(Packet)
    return Encryption.Pack(ConvertedPacket)
end

--//=============================================================================\\
--||                           CLIENT + SERVER METHODS                           ||
--\\=============================================================================//

if IsServer then
    _RespondToClientInvoke = function(Player : Player, PacketId : number, Packet : string)
        assert(Network.Remote, "Network not initialized")
        local FormattedPacket = "%1" .. Packet
        local EncryptedPacket = CastToEncryptedBuffer(FormattedPacket)
        Network.Remote:FireClient(Player, PacketId, EncryptedPacket)
    end

    function Network.SendToClient(Player: Player, PacketString: string)
        assert(Network.Remote, "Network not initialized")
        local PlayerEntry = Entries[Player]
        if not PlayerEntry then return end

        local PacketId = PlayerEntry.ServerNextSendId
        PlayerEntry.ServerNextSendId += 1
        
        local FormattedPacket = "%2" .. PacketString
        local EncryptedPacket = CastToEncryptedBuffer(FormattedPacket)
        Network.Remote:FireClient(Player, PacketId, EncryptedPacket)
        return PacketId
    end

    function Network.InvokeClient(Player: Player, PacketString: string, Callback : ((any, string?) -> ...any?)?)
        assert(Network.Remote, "Network not initialized")
        local PlayerEntry = Entries[Player]
        if not PlayerEntry then return end

        local PacketId = PlayerEntry.ServerNextInvokeId
        PlayerEntry.ServerNextInvokeId += 1

        local FormattedPacket = "%3" .. PacketString
        local EncryptedPacket = CastToEncryptedBuffer(FormattedPacket)
        
        if Callback then
            PlayerEntry.PacketCache[PacketId] = Callback
            task.delay(Network.Timeout, function()
                if PlayerEntry and PlayerEntry.PacketCache[PacketId] then
                    local StoredCallback = PlayerEntry.PacketCache[PacketId]
                    PlayerEntry.PacketCache[PacketId] = nil
                    StoredCallback(Packet.Status.Timeout, "Request to client timed out.")
                end
            end)
        end
        
        Network.Remote:FireClient(Player, PacketId, EncryptedPacket)
        return PacketId
    end
else -- Client-side functions
    function Network.Send(Packet : string | buffer) : number
        assert(Network.Remote, "Network not initialized")
        Network.PacketIds.Send += 1
        local PacketId = Network.PacketIds.Send
        local FormattedPacket = "%0" .. tostring(Packet)
        local EncryptedPacket = CastToEncryptedBuffer(FormattedPacket)
        Network.Remote:FireServer(PacketId, EncryptedPacket)
        return PacketId
    end

    function Network.Invoke(PacketString : string, Callback : ((any, string?) -> ...any?)?) : number
        assert(Network.Remote, "Network not initialized")
        Network.PacketIds.Invoke += 1
        local PacketId = Network.PacketIds.Invoke
        local FormattedPacket = "%1" .. PacketString
        local EncryptedPacket = CastToEncryptedBuffer(FormattedPacket)
        if Callback then
            Network.PacketCache[PacketId] = Callback
            task.delay(Network.Timeout, function()
                local StoredCallback = Network.PacketCache[PacketId]
                if StoredCallback then
                    Network.PacketCache[PacketId] = nil
                    StoredCallback(Packet.Status.Timeout, "Request to server timed out.")
                end
            end)
        end
        Network.Remote:FireServer(PacketId, EncryptedPacket)
        return PacketId
    end
end

--//=============================================================================\\
--||                         INITIALIZATION AND LISTENERS                        ||
--\\=============================================================================//

if IsServer then
    Network.OnEvent = Signal.new()
    Network.OnInvoked = ClientToServerInvokePlaceholder :: InvokePlaceholder
else -- Client-side event handlers
    Network.OnEvent = Signal.new();
    (Network :: any).OnInvoked = ServerToClientInvokePlaceholder :: InvokePlaceholder
end

Network.OnInitialized = Signal.new()

function Network.Initialize(Remote : RemoteEvent)
    assert(not Network.Initialized, "Network has already been initialized")
    assert(Remote, "RemoteEvent cannot be nil")
    Network.Remote = Remote
    Network.Initialized = true
    assert(Network.Remote)

    if IsServer then -- Server-side router
        Network.Remote.OnServerEvent:Connect(function(Player : Player, PacketId : number, EncryptedPacket : buffer)
            local PlayerEntry = Entries[Player]
            if not PlayerEntry then
                -- JIT create a new entry for the player
                PlayerEntry = {
                    ClientExpectedInvokeId = 1,
                    ClientExpectedSendId = 1,
                    ServerNextInvokeId = 1,
                    ServerNextSendId = 1,
                    PacketCache = {}
                }
                Entries[Player] = PlayerEntry
            end

            local PacketData = Encryption.Unpack(EncryptedPacket)
            local Prefix = PacketData:sub(1, 2)
            local Data = PacketData:sub(3)

            if Prefix == "%0" then -- C->S Send
                if PacketId ~= PlayerEntry.ClientExpectedSendId then Player:Kick("Packet desync (Send)"); return end
                PlayerEntry.ClientExpectedSendId += 1
                Network.OnEvent:Fire(Player, PacketId, Data)
            elseif Prefix == "%1" then -- C->S Invoke
                if PacketId ~= PlayerEntry.ClientExpectedInvokeId then Player:Kick("Packet desync (Invoke)"); return end
                local CurrentPacketId = PlayerEntry.ClientExpectedInvokeId
                PlayerEntry.ClientExpectedInvokeId += 1
                local ResponseData = (Network.OnInvoked :: (Player, number, string) -> string)(Player, CurrentPacketId, Data)
                _RespondToClientInvoke(Player, CurrentPacketId, ResponseData)
            elseif Prefix == "%3" then -- C->S Response to a S->C Invoke
                local StoredCallback = PlayerEntry.PacketCache[PacketId]
                if StoredCallback then
                    PlayerEntry.PacketCache[PacketId] = nil
                    StoredCallback(Packet.Status.Success, Data)
                end
            else
                warn("Received unknown packet from player:", Player.Name, "PacketId:", PacketId, "Packet:", PacketData)
            end
        end)
    else -- Client-side router
        Network.Remote.OnClientEvent:Connect(function(PacketId : number, EncryptedPacket : buffer)
            local PacketData = Encryption.Unpack(EncryptedPacket)
            local Prefix = PacketData:sub(1, 2)
            local Data = PacketData:sub(3)
            
            if Prefix == "%1" then -- S->C Response to a C->S Invoke
                local StoredCallback = Network.PacketCache[PacketId]
                if StoredCallback then
                    Network.PacketCache[PacketId] = nil
                    StoredCallback(Packet.Status.Success, Data)
                else
                    warn("Received response for unknown/timed-out C->S invoke:", PacketId)
                end
            elseif Prefix == "%2" then -- S->C Send
                (Network.OnEvent :: any):Fire(Data)
            elseif Prefix == "%3" then -- S->C Invoke
                local ResponseData = (Network :: any).OnInvoked(Data)
                local FormattedPacket = "%3" .. tostring(ResponseData)
                local EncryptedResponse = CastToEncryptedBuffer(FormattedPacket)
                Network.Remote:FireServer(PacketId, EncryptedResponse)
            end
        end)
    end

    Network.OnInitialized:Fire(Remote)
    print("Network Initialized:", IsServer and "Server" or "Client")
end

Network.Packet = Packet

return Network
