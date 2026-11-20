--[[--
RSA-OAEP (SHA-256) for QR code login, through LuaJIT FFI on the libcrypto
(LibreSSL) that ships with KOReader. Nothing to install.

@module koplugin.discord.crypto
]]

local ffi = require("ffi")

local C = {}

local cdefs = {
    "typedef struct bignum_st BIGNUM;",
    "typedef struct rsa_st RSA;",
    "typedef struct evp_pkey_st EVP_PKEY;",
    "typedef struct evp_pkey_ctx_st EVP_PKEY_CTX;",
    "typedef struct env_md_st EVP_MD;",
    "typedef struct engine_st ENGINE;",
    "typedef struct bn_gencb_st BN_GENCB;",
    [[
BIGNUM *BN_new(void);
void BN_free(BIGNUM *);
int BN_set_word(BIGNUM *, unsigned long);
RSA *RSA_new(void);
void RSA_free(RSA *);
int RSA_generate_key_ex(RSA *, int, BIGNUM *, BN_GENCB *);
EVP_PKEY *EVP_PKEY_new(void);
void EVP_PKEY_free(EVP_PKEY *);
int EVP_PKEY_set1_RSA(EVP_PKEY *, RSA *);
int i2d_PUBKEY(EVP_PKEY *, unsigned char **);
void CRYPTO_free(void *, const char *, int);
EVP_PKEY_CTX *EVP_PKEY_CTX_new(EVP_PKEY *, ENGINE *);
void EVP_PKEY_CTX_free(EVP_PKEY_CTX *);
int EVP_PKEY_CTX_ctrl(EVP_PKEY_CTX *, int, int, int, int, void *);
int EVP_PKEY_decrypt_init(EVP_PKEY_CTX *);
int EVP_PKEY_decrypt(EVP_PKEY_CTX *, unsigned char *, size_t *, const unsigned char *, size_t);
const EVP_MD *EVP_sha256(void);
]],
}
for _, d in ipairs(cdefs) do pcall(ffi.cdef, d) end

local lib
local function load()
    if lib then return lib end
    local ok, l = pcall(function()
        if ffi.loadlib then return ffi.loadlib("crypto", "57") end
        return ffi.load("libs/libcrypto.so.57")
    end)
    if not ok or not l then
        local ok2, l2 = pcall(ffi.load, "crypto")
        if not ok2 then error("cannot load libcrypto: " .. tostring(l)) end
        l = l2
    end
    lib = l
    return lib
end

local EVP_PKEY_RSA = 6
local EVP_PKEY_ALG_CTRL = 0x1000
local EVP_PKEY_CTRL_RSA_PADDING = EVP_PKEY_ALG_CTRL + 1
local EVP_PKEY_CTRL_RSA_MGF1_MD = EVP_PKEY_ALG_CTRL + 5
local EVP_PKEY_CTRL_RSA_OAEP_MD = EVP_PKEY_ALG_CTRL + 9
local EVP_PKEY_OP_ENCRYPT = bit.lshift(1, 8)
local EVP_PKEY_OP_DECRYPT = bit.lshift(1, 9)
local EVP_PKEY_OP_TYPE_CRYPT = bit.bor(EVP_PKEY_OP_ENCRYPT, EVP_PKEY_OP_DECRYPT)
local RSA_PKCS1_OAEP_PADDING = 4

local KeyPair = {}
KeyPair.__index = KeyPair

--- Generate a 2048-bit RSA key pair.
function C.generate()
    local L = load()
    local e = L.BN_new()
    assert(L.BN_set_word(e, 65537) == 1, "BN_set_word failed")
    local rsa = L.RSA_new()
    local ok = L.RSA_generate_key_ex(rsa, 2048, e, nil)
    L.BN_free(e)
    if ok ~= 1 then
        L.RSA_free(rsa)
        error("RSA key generation failed")
    end
    local pkey = L.EVP_PKEY_new()
    assert(L.EVP_PKEY_set1_RSA(pkey, rsa) == 1, "EVP_PKEY_set1_RSA failed")
    L.RSA_free(rsa) -- pkey holds its own reference
    pkey = ffi.gc(pkey, L.EVP_PKEY_free)
    return setmetatable({ pkey = pkey }, KeyPair)
end

--- DER-encoded SubjectPublicKeyInfo.
function KeyPair:publicKeyDER()
    local L = load()
    local pp = ffi.new("unsigned char *[1]")
    local len = L.i2d_PUBKEY(self.pkey, pp)
    if len <= 0 then error("i2d_PUBKEY failed") end
    local der = ffi.string(pp[0], len)
    L.CRYPTO_free(pp[0], "discord_crypto", 0)
    return der
end

--- RSA-OAEP (SHA-256 / MGF1-SHA-256) decrypt.
function KeyPair:decrypt(ciphertext)
    local L = load()
    local ctx = L.EVP_PKEY_CTX_new(self.pkey, nil)
    if ctx == nil then return nil, "EVP_PKEY_CTX_new failed" end
    local function fail(msg)
        L.EVP_PKEY_CTX_free(ctx)
        return nil, msg
    end
    if L.EVP_PKEY_decrypt_init(ctx) ~= 1 then return fail("decrypt_init failed") end
    if L.EVP_PKEY_CTX_ctrl(ctx, EVP_PKEY_RSA, -1, EVP_PKEY_CTRL_RSA_PADDING, RSA_PKCS1_OAEP_PADDING, nil) <= 0 then
        return fail("set padding failed")
    end
    local md = ffi.cast("void *", L.EVP_sha256())
    if L.EVP_PKEY_CTX_ctrl(ctx, EVP_PKEY_RSA, EVP_PKEY_OP_TYPE_CRYPT, EVP_PKEY_CTRL_RSA_OAEP_MD, 0, md) <= 0 then
        return fail("set oaep md failed")
    end
    -- MGF1 defaults to the OAEP digest, but be explicit where supported.
    L.EVP_PKEY_CTX_ctrl(ctx, EVP_PKEY_RSA, -1, EVP_PKEY_CTRL_RSA_MGF1_MD, 0, md)
    local outlen = ffi.new("size_t[1]")
    if L.EVP_PKEY_decrypt(ctx, nil, outlen, ciphertext, #ciphertext) ~= 1 then
        return fail("decrypt (size) failed")
    end
    local out = ffi.new("unsigned char[?]", tonumber(outlen[0]))
    if L.EVP_PKEY_decrypt(ctx, out, outlen, ciphertext, #ciphertext) ~= 1 then
        return fail("decrypt failed")
    end
    L.EVP_PKEY_CTX_free(ctx)
    return ffi.string(out, tonumber(outlen[0]))
end

return C
