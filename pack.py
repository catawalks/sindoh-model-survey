#!/usr/bin/env python3
"""Pack unmistakable_model_survey.sh into each Sindoh model's USB folder.

    python pack.py [--out stick]

Writes <out>/<model folder>/unmistakable_model_survey.she for every model
below, the encrypted update file the printer's stock /app/auto_update.sh
decrypts and runs from a USB stick. Each file is checked by decrypting it
again. Copy all the folders to the root of a FAT32 stick: each printer only
reads its own folder.

Needs Python 3.8+ only (the ciphers are in she_crypto.py). The output is
reproducible: the same script gives the same files.

SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse
import bz2
import hashlib
import io
import os
import sys
import tarfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import she_crypto  # noqa: E402

SCRIPT = "unmistakable_model_survey.sh"

# The same table as catawalks/sindoh-boot-logo (keys are what each model's
# /app/crypto_key.dat decrypts to; they are public).
MODELS = [
    # (name, USB folder, cipher, key)
    ("DP200 / DP201 / Model 1 (all brands)", "_update_rodin", "des3", "sindoh024601779"),
    ("3DWOX 1", "_update_rodin_up", "aes", "sindoh024601779U"),
    ("3DWOX 2X", "_update_rodin_prime", "des3", "sindoh024601779"),
    ("3DWOX 1X", "_update_rodin_1x", "aes", "sindoh0246017791"),
    ("3DWOX 7X", "_update_rodin_h", "aes", "sindoh024601779H"),
]


def tar_bz2(name, data):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as t:
        ti = tarfile.TarInfo(name)
        ti.size, ti.mode, ti.uid, ti.gid, ti.mtime = len(data), 0o755, 0, 0, 0
        ti.uname = ti.gname = "root"
        t.addfile(ti, io.BytesIO(data))
    return bz2.compress(buf.getvalue(), 9)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "stick"))
    args = ap.parse_args()

    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), SCRIPT)
    script = open(src, "rb").read().replace(b"\r\n", b"\n")
    if b"\r" in script:
        sys.exit("the script has stray CR characters")
    blob = tar_bz2(SCRIPT, script)
    salt = hashlib.md5(script).digest()[:8]       # reproducible des3 output
    for name, folder, cipher, key in MODELS:
        if cipher == "des3":
            she = she_crypto.des3_encrypt(key, blob, salt)
        else:
            she = she_crypto.aes_encrypt(key, blob)
        # self-check: decrypt and unpack the way the printer does
        with tarfile.open(fileobj=io.BytesIO(bz2.decompress(she_crypto.decrypt(cipher, key, she)))) as t:
            if t.getnames() != [SCRIPT] or t.extractfile(SCRIPT).read() != script:
                sys.exit(f"self-check failed for {folder}")
        d = os.path.join(args.out, folder)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, SCRIPT + "e")
        with open(path, "wb") as f:
            f.write(she)
        print(f"{folder:22} {name:38} {len(she):6} bytes  verified")
    print(f"script md5 {hashlib.md5(script).hexdigest()}")


if __name__ == "__main__":
    main()
