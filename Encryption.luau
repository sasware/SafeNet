--!strict
-- file: modules/Encryption.luau
-- RC4 Luau Implementation

print("Encryption.luau")

local Encryption = {
    DefaultKey = "default"
}

local function KSA(Key: string)
    local KeyLength = #Key
    local S = {}
    for I = 0, 255 do
        S[I] = I
    end

    local J = 0
    for I = 0, 255 do
        local KeyByte = string.byte(Key, (I % KeyLength) + 1)
        J = (J + S[I] + KeyByte) % 256
        S[I], S[J] = S[J], S[I]
    end

    return S
end

local function PRGA(S: { [number]: number }, DataLength: number)
    local I, J = 0, 0
    local Keystream = {}

    for N = 1, DataLength do
        I = (I + 1) % 256
        J = (J + S[I]) % 256
        S[I], S[J] = S[J], S[I]

        local K = S[(S[I] + S[J]) % 256]
        Keystream[N] = K
    end

    return Keystream
end

local function StringToBytes(Str: string)
    local Bytes = {}
    for I = 1, #Str do
        Bytes[I] = string.byte(Str, I)
    end
    return Bytes
end

local function BytesToString(Bytes: { [number]: number })
    local Chars = {}
    for I = 1, #Bytes do
        Chars[I] = string.char(Bytes[I])
    end
    return table.concat(Chars)
end

function Encryption.Process(Key: string, Data: string): string
    assert(type(Key) == "string" and #Key > 0, "Key must be a non-empty string")
    assert(type(Data) == "string", "Data must be a string")
    local S = KSA(Key)
    local Keystream = PRGA(S, #Data)
    local DataBytes = StringToBytes(Data)
    local OutputBytes = {}
    for I = 1, #DataBytes do
        OutputBytes[I] = bit32.bxor(DataBytes[I], Keystream[I])
    end
    return BytesToString(OutputBytes)
end

function Encryption.Decrypt(Key: string, Ciphertext: string): string
    return Encryption.Process(Key, Ciphertext)
end

function Encryption.Encrypt(Key: string, Plaintext: string): string
    return Encryption.Process(Key, Plaintext)
end

function Encryption.Pack(Data : string, Key : string?): buffer
    assert(type(Data) == "string", "Data must be a string")
    local Packed

    if Key and type(Key) == "string" and #Key > 0 then
        Packed = buffer.fromstring(Encryption.Process(Key, Data))
    else
        Packed = buffer.fromstring(Encryption.Process(Encryption.DefaultKey, Data))
    end

    return Packed
end

function Encryption.Unpack(Packed: buffer, Key: string?): string
    assert(type(Packed) == "buffer", "Packed must be a buffer")
    local Data = buffer.tostring(Packed)

    if Key and type(Key) == "string" and #Key > 0 then
        return Encryption.Decrypt(Key, Data)
    else
        return Encryption.Decrypt(Encryption.DefaultKey, Data)
    end
end

function Encryption.SetDefaultKey(Key: string)
    assert(type(Key) == "string" and #Key > 0, "Key must be a non-empty string")
    Encryption.DefaultKey = Key
end

function Encryption.EncPacked(Data: buffer, Key: string?): buffer
    assert(type(Data) == "buffer", "Data must be a buffer")
    local DataString = buffer.tostring(Data)

    if Key and type(Key) == "string" and #Key > 0 then
        return Encryption.Pack(DataString, Key)
    else
        return Encryption.Pack(DataString, Encryption.DefaultKey)
    end
end

function Encryption.Noise() : buffer
    local Junk = {}
    local Length = math.random(32, 64)

    for _ = 1, Length do
        local Byte = math.random(0, 255)
        table.insert(Junk, Byte)
    end

    local JunkString = table.concat(Junk, "")

    return Encryption.Pack(JunkString, Encryption.DefaultKey)
end

return Encryption
