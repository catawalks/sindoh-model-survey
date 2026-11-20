# Sindoh model survey

A USB stick that maps out a Sindoh 3D printer's hardware and firmware, so
we can bring the [Klipper port](https://github.com/catawalks/sindoh) and
the [boot logo tool](https://github.com/catawalks/sindoh-boot-logo) to more
models. It **only reads**. It changes nothing on the printer, and the printer
boots normally afterwards.

The printer's own USB update runs it, so you don't need a serial cable, a
root shell or any extra software. It saves one text file on the stick. Send
us that file.

> **Status:** new. It has been tested on a PC against a fake printer, but not
> yet on a real printer of any model. See [Tested so far](#tested-so-far).

## Supported printers

| Model | USB folder |
|---|---|
| DP200 / DP201 / Model 1 (Sindoh, Stanley, Leon3D, Mimaki) | `_update_rodin` |
| 3DWOX 1 | `_update_rodin_up` |
| 3DWOX 2X | `_update_rodin_prime` |
| 3DWOX 1X | `_update_rodin_1x` |
| 3DWOX 7X | `_update_rodin_h` |
| 3DWOX 30X | not yet: its update key is unknown |

Each printer only looks in its own folder. So one stick with all five
folders works on every model above.

## How to use it (Windows)

1. **Get the files.** On this page, click *Code* → *Download ZIP*. Unzip it.
   The ready-made folders are in `stick\`.
2. **Prepare a USB stick** formatted as **FAT32**. Most sticks up to 32 GB
   come that way. To check, right-click the stick in *This PC* →
   *Properties* and look at *File system*. To format, right-click → *Format...*
   → *File system: FAT32* → *Start*. **Formatting erases the stick.** Windows
   doesn't offer FAT32 for sticks over 32 GB, so use a smaller one.
3. **Copy the folders.** Copy all the `_update_...` folders from `stick\` to
   the top level of the stick, not into another folder. The stick should look
   like this:
   ```
   E:\
     _update_rodin\unmistakable_model_survey.she
     _update_rodin_up\unmistakable_model_survey.she
     _update_rodin_prime\unmistakable_model_survey.she
     _update_rodin_1x\unmistakable_model_survey.she
     _update_rodin_h\unmistakable_model_survey.she
   ```
   Make sure those folders hold **no other files**, especially no Sindoh
   `update.she`. The printer runs a firmware update right after the
   survey if it finds one.
4. **Eject the stick** in Windows (*Safely Remove Hardware*), then plug it
   into the printer while the printer is on, idle and not printing.
5. **Wait.** The screen shows "Model survey / Reading printer info". After
   about a minute it shows **"Model survey done"** and the file name. If
   nothing happens after two minutes, power the printer off and on with the
   stick still plugged in.
6. **Remove the stick, then power the printer off and on.** The normal
   screen comes back.
7. **Send us the file.** It's at the top level of the stick, named like
   `survey_RODUP_220111_1_3DWOX1_20261120-153000.txt` (firmware, model code,
   date). Open an issue on this repository and attach it, and say which
   printer it is (model and brand). Read it first if you like: it's plain
   text.

You can run it again at any time; each run makes a new file.

## What it collects

All of this describes the printer, not you:
- **Firmware:** the version tag from `/snapshot_version.sh` (read as text;
  the survey never runs it), the model variant (`RODIN_SUB`), the board name,
  the `auto_update.sh` version, and the busybox, OpenSSL and sqlite versions
  with the list of busybox commands.
- **The printer's database `karas.db`:** its table layout, the row count of
  each table, and the contents of the machine and settings tables
  (`INST_MACHINE`, `CONF_*`, `MCONF_*`). Those hold the model code and the
  motion, temperature and fan settings. The survey reads a copy in memory,
  never the database itself. History and log tables are not read.
- **Chip and kernel:** `/proc/cpuinfo`, memory, kernel version and boot
  command line, the memory map, interrupts, drivers and modules, the device
  tree (node names and `compatible` strings), and the kernel build config.
- **Storage:** the flash partitions (`/proc/mtd`, `/proc/partitions`, UBI
  volumes, mounts, free space) and the size and type of each disk. It
  records an **md5 checksum** of the first 256 KB of the boot partition, to
  tell boot loader builds apart. It never copies the data itself.
- **U-Boot settings:** `fw_printenv` (read-only).
- **Hardware:** serial ports and which programs use them, `/dev`,
  `/sys/class`, buses, USB devices, I²C adapters (the list only; it doesn't
  scan the bus), and on the DP200 / 3DWOX 1 chip only, the GPIO input,
  output and direction registers (plain reads).
- **Software:** the running programs (`ps`), network interfaces, and the
  program and library file names. It lists the file names and sizes under
  `/app`, with an md5 checksum of each program there, and gives each
  folder's size. File contents are not copied.
- **The kernel log** (`dmesg`).

### What is hidden before the file is written

- **Wi-Fi:** network names (SSIDs) and keys. `wpa_supplicant.conf` and the
  saved-network table are never read. Anything after "ssid", "psk",
  "password", "passkey", "secret" or "token" is replaced with `<masked>`.
- **Accounts:** user ID and password, e-mail and SMTP settings, cloud and
  job-log server addresses, recently printed file names, location.
- **Serial numbers:** only the first half is kept (the start usually gives
  the model and production batch).
- **MAC addresses:** only the first half (the maker), `00:50:43:xx:xx:xx`.
- **IP addresses:** only the first two numbers, `192.168.x.x`.
- **Print files:** names ending in `.gcode`, `.gco`, `.3dw` or `.stl` become
  `<print file>`.
- **Printer id:** an 8-character checksum of the serial number and MAC. It
  lets us tell two reports from the same printer apart, and it can't be
  turned back into either.

### What it never does

- write to the flash (NAND or eMMC), an mtd partition, the U-Boot settings
  (no `fw_setenv`), `karas.db` or the filament cartridge chip;
- copy a flash image or any firmware file;
- move a motor, heat anything, reboot, scan for Wi-Fi or probe the I²C
  bus;
- run any of Sindoh's scripts. The one exception is `/app/display.sh`, the
  screen-message helper every stock update uses. The survey first checks
  that the file only draws text.

The script is [`unmistakable_model_survey.sh`](unmistakable_model_survey.sh).
Every command in it has a time limit, and a failing command doesn't stop the
rest. The only files it writes are its report on the stick and scratch files
in `/tmp` (memory), which it deletes again.

## How it works

Every Sindoh model above has a stock `/app/auto_update.sh` that runs when a
USB stick is plugged in. It looks in the model's folder on the stick and,
for each `unmistakable*.she` file, decrypts it with the model's update key,
unpacks it to `/tmp` and runs the script inside. Then it runs a firmware
update if there is an `update.she`. The boot logo tool uses the same route.

`pack.py` makes those files: it packs the script (tar + bzip2) and encrypts
it with each model's key (Triple DES for the DP200 and 2X, AES-256 for the
others). It then decrypts each file again to check it. The keys are the ones
each model's `/app/crypto_key.dat` holds, and they are already public.

To rebuild the `stick\` folders after changing the script (Python 3.8 or
newer, nothing else needed):
```
python pack.py
```
`--out DIR` writes them elsewhere. The same script always gives the same
files.

## Tested so far

- `pack.py`: every `.she` decrypts with `openssl` (`des3 -md md5` and
  `aes-256-cbc -K -iv`, the way each model's `auto_update.sh` does it) and
  unpacks to the exact script.
- The script passes `sh -n` and ran under `dash` and `bash --posix` against
  a fake printer folder, which held a real DP200 `karas.db` and fake mtd,
  U-Boot, network and serial data. Checks:
  - no private value from that database (Wi-Fi names and keys, account,
    serial), MAC, IP or print file name appeared in the report;
  - a command that hangs is stopped after its time limit, and the rest
    still runs;
  - the script always exits 0, which the stock update needs, and cleans up
    `/tmp`.
- **Not tested on a printer yet**, on any model. The DP200 family will be
  first. The 3DWOX 1, 2X, 1X and 7X are untested until an owner runs it.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). `she_crypto.py` is copied from
[catawalks/sindoh-boot-logo](https://github.com/catawalks/sindoh-boot-logo).
