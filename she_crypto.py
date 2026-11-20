"""Sindoh .she encryption in plain Python (no openssl needed).

Copied unchanged from catawalks/sindoh-boot-logo (bootlogo_core.py), by the
same author. Byte-compatible with `openssl des3 -salt -md md5` and
`openssl aes-256-cbc -K hex(key) -iv hex(key)`, which is what the printers'
stock /app/auto_update.sh uses to decrypt.

SPDX-License-Identifier: GPL-3.0-or-later
"""
import hashlib
import os

# ---------------------------------------------------------------- DES ----
# Standard DES tables (FIPS 46-3), bit 1 = most significant.

_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
       62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
       57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
       61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
_FP = [_IP.index(i) + 1 for i in range(1, 65)]
_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
        10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
        14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10,
        23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48,
        44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
      2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
_S = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
     0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
     15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
     3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
     13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
     13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
     1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
     13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
     3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
     14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
     11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
     10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
     4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
     13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
     6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
     1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
     2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]]


def _permute(v, table, nin):
    out = 0
    for t in table:
        out = (out << 1) | ((v >> (nin - t)) & 1)
    return out


def _byte_tables(table):
    """64-bit permutation as 8 lookups of 256 (input byte i, value) -> output bits."""
    tabs = []
    for i in range(8):
        tabs.append([_permute(b << (56 - 8 * i), table, 64) for b in range(256)])
    return tabs


_IPT = _byte_tables(_IP)
_FPT = _byte_tables(_FP)
# S-box i followed by P, indexed by the 6-bit S-box input
_SP = []
for _i in range(8):
    _t = []
    for _v in range(64):
        _row = ((_v >> 4) & 2) | (_v & 1)
        _col = (_v >> 1) & 15
        _t.append(_permute(_S[_i][_row * 16 + _col] << (28 - 4 * _i), _P, 32))
    _SP.append(_t)


def _perm64(v, tabs):
    o = 0
    for i in range(8):
        o |= tabs[i][(v >> (56 - 8 * i)) & 0xFF]
    return o


def _des_subkeys(key8):
    k = _permute(int.from_bytes(key8, "big"), _PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    keys = []
    for s in _SHIFTS:
        c = ((c << s) | (c >> (28 - s))) & 0xFFFFFFF
        d = ((d << s) | (d >> (28 - s))) & 0xFFFFFFF
        k48 = _permute((c << 28) | d, _PC2, 56)
        keys.append([(k48 >> (42 - 6 * i)) & 63 for i in range(8)])
    return keys


def _des_rounds(l, r, keys):
    sp0, sp1, sp2, sp3, sp4, sp5, sp6, sp7 = _SP
    for k in keys:
        x = ((r >> 1) | (r << 31)) & 0xFFFFFFFF          # E: rotate right by 1,
        f = (sp0[((x >> 26) & 63) ^ k[0]] | sp1[((x >> 22) & 63) ^ k[1]] |
             sp2[((x >> 18) & 63) ^ k[2]] | sp3[((x >> 14) & 63) ^ k[3]] |
             sp4[((x >> 10) & 63) ^ k[4]] | sp5[((x >> 6) & 63) ^ k[5]] |
             sp6[((x >> 2) & 63) ^ k[6]] |
             sp7[(((x << 2) | (x >> 30)) & 63) ^ k[7]])  # then 6-bit windows
        l, r = r, l ^ f
    return r, l                                          # undo the last swap


class TripleDES:
    """DES-EDE3 (24-byte key), the cipher of `openssl des3`."""

    def __init__(self, key24):
        k1, k2, k3 = (_des_subkeys(key24[i:i + 8]) for i in (0, 8, 16))
        self.enc = (k1, k2[::-1], k3)
        self.dec = (k3[::-1], k2, k1[::-1])

    def _block(self, v, ks):
        v = _perm64(v, _IPT)
        l, r = v >> 32, v & 0xFFFFFFFF
        for k in ks:                 # inner FP/IP pairs cancel out
            l, r = _des_rounds(l, r, k)
        return _perm64((l << 32) | r, _FPT)

    def encrypt_block(self, v):
        return self._block(v, self.enc)

    def decrypt_block(self, v):
        return self._block(v, self.dec)


# ---------------------------------------------------------------- AES ----

def _aes_tables():
    sbox = [0] * 256
    p = q = 1
    while True:                       # generate the S-box from GF(2^8) inverses
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1 | q >> 7) & 0xFF) ^ ((q << 2 | q >> 6) & 0xFF) \
            ^ ((q << 3 | q >> 5) & 0xFF) ^ ((q << 4 | q >> 4) & 0xFF)
        sbox[p] = x ^ 0x63
        if p == 1:
            break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, v in enumerate(sbox):
        inv[v] = i
    return sbox, inv


_SBOX, _INV_SBOX = _aes_tables()


def _xt(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xt(a)
        b >>= 1
    return r


_M2 = [_mul(i, 2) for i in range(256)]
_M3 = [_mul(i, 3) for i in range(256)]
_M9 = [_mul(i, 9) for i in range(256)]
_M11 = [_mul(i, 11) for i in range(256)]
_M13 = [_mul(i, 13) for i in range(256)]
_M14 = [_mul(i, 14) for i in range(256)]


class AES:
    """AES with a 16/24/32-byte key, one 16-byte block at a time."""

    def __init__(self, key):
        nk = len(key) // 4
        self.nr = nk + 6
        w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
        rcon = 1
        for i in range(nk, 4 * (self.nr + 1)):
            t = list(w[i - 1])
            if i % nk == 0:
                t = [_SBOX[b] for b in t[1:] + t[:1]]
                t[0] ^= rcon
                rcon = _xt(rcon)
            elif nk > 6 and i % nk == 4:
                t = [_SBOX[b] for b in t]
            w.append([a ^ b for a, b in zip(w[i - nk], t)])
        self.rk = [sum(w[4 * r:4 * r + 4], []) for r in range(self.nr + 1)]

    def encrypt_block(self, b):
        s = [x ^ k for x, k in zip(b, self.rk[0])]
        for r in range(1, self.nr + 1):
            s = [_SBOX[x] for x in s]
            s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]           # ShiftRows
            if r != self.nr:
                t = []
                for c in range(4):
                    a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                    t += [_M2[a0] ^ _M3[a1] ^ a2 ^ a3, a0 ^ _M2[a1] ^ _M3[a2] ^ a3,
                          a0 ^ a1 ^ _M2[a2] ^ _M3[a3], _M3[a0] ^ a1 ^ a2 ^ _M2[a3]]
                s = t
            s = [x ^ k for x, k in zip(s, self.rk[r])]
        return bytes(s)

    def decrypt_block(self, b):
        s = [x ^ k for x, k in zip(b, self.rk[self.nr])]
        for r in range(self.nr - 1, -1, -1):
            s = [s[(i - 4 * (i % 4)) % 16] for i in range(16)]           # InvShiftRows
            s = [_INV_SBOX[x] for x in s]
            s = [x ^ k for x, k in zip(s, self.rk[r])]
            if r:
                t = []
                for c in range(4):
                    a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                    t += [_M14[a0] ^ _M11[a1] ^ _M13[a2] ^ _M9[a3],
                          _M9[a0] ^ _M14[a1] ^ _M11[a2] ^ _M13[a3],
                          _M13[a0] ^ _M9[a1] ^ _M14[a2] ^ _M11[a3],
                          _M11[a0] ^ _M13[a1] ^ _M9[a2] ^ _M14[a3]]
                s = t
        return bytes(s)


# ----------------------------------------------------- openssl framing ----

def _pad(data, n):
    p = n - len(data) % n
    return data + bytes([p]) * p


def _unpad(data, n):
    p = data[-1] if data else 0
    if not 1 <= p <= n or data[-p:] != bytes([p]) * p:
        raise ValueError("bad padding (wrong key?)")
    return data[:-p]


def _cbc(cipher, iv, data, n, encrypt):
    out = bytearray()
    if n == 8:                                   # DES works on 64-bit ints
        prev = int.from_bytes(iv, "big")
        for i in range(0, len(data), 8):
            blk = int.from_bytes(data[i:i + 8], "big")
            if encrypt:
                prev = cipher.encrypt_block(blk ^ prev)
                out += prev.to_bytes(8, "big")
            else:
                out += (cipher.decrypt_block(blk) ^ prev).to_bytes(8, "big")
                prev = blk
        return bytes(out)
    prev = iv
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        if encrypt:
            prev = cipher.encrypt_block(bytes(a ^ b for a, b in zip(blk, prev)))
            out += prev
        else:
            out += bytes(a ^ b for a, b in zip(cipher.decrypt_block(blk), prev))
            prev = blk
    return bytes(out)


def _bytes_to_key(password, salt, nkey, niv):
    """OpenSSL EVP_BytesToKey with MD5, one iteration (openssl -md md5)."""
    d, prev = b"", b""
    while len(d) < nkey + niv:
        prev = hashlib.md5(prev + password + salt).digest()
        d += prev
    return d[:nkey], d[nkey:nkey + niv]


def des3_encrypt(password, data, salt=None):
    """= openssl des3 -e -salt -md md5 -pass pass:PASSWORD"""
    salt = salt or os.urandom(8)
    key, iv = _bytes_to_key(password.encode(), salt, 24, 8)
    return b"Salted__" + salt + _cbc(TripleDES(key), iv, _pad(data, 8), 8, True)


def des3_decrypt(password, data):
    if data[:8] != b"Salted__":
        raise ValueError("not an openssl salted file")
    key, iv = _bytes_to_key(password.encode(), data[8:16], 24, 8)
    return _unpad(_cbc(TripleDES(key), iv, data[16:], 8, False), 8)


def _aes_key_iv(password):
    # openssl aes-256-cbc -K hex(pw) -iv hex(pw): key zero-padded to 32 bytes
    k = password.encode()
    return (k + bytes(32))[:32], (k + bytes(16))[:16]


def aes_encrypt(password, data):
    key, iv = _aes_key_iv(password)
    return _cbc(AES(key), iv, _pad(data, 16), 16, True)


def aes_decrypt(password, data):
    key, iv = _aes_key_iv(password)
    return _unpad(_cbc(AES(key), iv, data, 16, False), 16)


def aes_pw_decrypt(password, data):
    """openssl aes-256-cbc -d -salt -k password (MD5 key derivation)."""
    if data[:8] != b"Salted__":
        raise ValueError("not a salted openssl file")
    key, iv = _bytes_to_key(password.encode(), data[8:16], 32, 16)
    return _unpad(_cbc(AES(key), iv, data[16:], 16, False), 16)


def encrypt(cipher, key, data):
    return des3_encrypt(key, data) if cipher == "des3" else aes_encrypt(key, data)


def decrypt(cipher, key, data):
    return des3_decrypt(key, data) if cipher == "des3" else aes_decrypt(key, data)

