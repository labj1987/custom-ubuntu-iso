# Testing

Everything runs locally: build the ISO, then install and boot it in a QEMU VM with UEFI Secure Boot (OVMF with Microsoft keys). KVM makes the VM fast; without `/dev/kvm` it falls back to TCG. ISOs and disks stay under `out/` and `work/` (both ignored by git); nothing is uploaded.

```bash
sudo apt install -y xorriso squashfs-tools gpg curl qemu-system-x86 qemu-utils ovmf dosfstools mtools gdisk python3-pil socat sshpass
sudo ./build.sh
```

## Scripts

- `disk-test.sh install ISO`: lays the ISO's install layers onto `work/disktest/disk.raw` the way the installer does, GRUB included, without the installer's UI.
- `disk-test.sh boot`: boots that disk. SSH: `ssh -p 2222 tester@127.0.0.1`, password `test1234`. QEMU monitor: `work/disktest/monitor.sock`. Serial console: `work/disktest/serial.log`.
- `mok-enroll.sh [PASSWORD]`: run while the VM boots. It waits for MOK Manager on the serial console and enrolls the queued key over the monitor, saving a screenshot of each screen to `work/disktest/mok/`.
- `vm-test.sh install ISO` / `boot`: an unattended run of the real installer (`user-data`).

`build.sh` and `disk-test.sh` mount inside their own mount namespace, so their mounts never show up in the host's or in other services' namespaces.

## Procedure

```bash
sudo tests/disk-test.sh install out/ubuntu-26.10-custom-amd64.iso
sudo tests/disk-test.sh boot &
sudo tests/mok-enroll.sh
```

First boot logs these `[custom-iso]` lines to the serial console, in order: SSH host keys ready; created the signing key; signed systemd-boot; GRUB removed; boot entry added; removed firmware entry (Linux Boot Manager), twice; systemd-boot installed behind shim; Remote Login set up on port 3389; key queued; rebooting into MOK Manager.

Then over SSH:

- `sudo bootctl status`: systemd-boot is the current loader, Secure Boot enabled. `mokutil --list-enrolled` shows `CN=Kernel Pop kernel signing key`.
- `sudo efibootmgr`: "Ubuntu" is the only Linux entry and comes first.
- `dpkg -l | grep grub` shows only `custom-iso-no-grub`; `/boot/grub` and GRUB's files on the ESP are gone.
- `systemctl is-enabled ssh tailscaled gnome-remote-desktop`, `sudo grdctl --system status`, `flatpak list --system`, `apt-cache policy claude-desktop steam-launcher tailscale`. Running `ldd` on every binary in `/opt/remmina-gpu` finds no missing libraries.
- Update path: `sudo apt-get install --reinstall -y shim-signed systemd-boot systemd-boot-efi linux-image-$(uname -r)` exits 0, `dpkg --audit` is clean, the re-added "Linux Boot Manager" is pruned again, and the system still boots after a reboot.
- First login (the test user logs in automatically): `~/.local/state/custom-iso/firstlogin.log` shows the four AppImages integrated. The RDP login window opens behind Ubuntu's welcome window (and Steam's update notice); it appears once those are closed. Autologin without a password leaves the login keyring locked, so before submitting it in the VM, unlock the keyring the way a password login would:
  ```bash
  export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
  systemctl --user stop gnome-keyring-daemon.socket gnome-keyring-daemon.service
  printf test1234 | gnome-keyring-daemon --unlock --daemonize --components=secrets,pkcs11 --control-directory=$XDG_RUNTIME_DIR/keyring
  ```
  Then ports 3389 and 3390 both listen. Check a login through an SSH tunnel (`-L 13389:127.0.0.1:3389 -L 13390:127.0.0.1:3390`) with `/opt/remmina-gpu/bin/xfreerdp /v:127.0.0.1:13390 /u:USER /p:PASS /cert:ignore +auth-only`.
- Skipping MOK Manager (let the 10 s countdown run out) ends in shim's "Verification failed: (0x1A) Security Violation"; there is no fallback loader.

## Results

2026-10-26, LordNikon, KVM, ISO built from 587c807 plus the fixes made during this run:

- First boot logged all of its steps. The key was enrolled with `mok-enroll.sh`, and the system booted "Ubuntu" -> shim -> systemd-boot 261.3-0ubuntu3 with Secure Boot on. "Ubuntu" was the only Linux firmware entry, and no GRUB was left.
- Claude desktop 3.6556.2, Steam 1.0.0.87, Tailscale 1.104.2 and VLC came from their own repositories. Gear Lever 4.6.2, Proton Plus 0.6.8 and OpenRGB 1.1 came from Flathub. GPU Remmina 1.4.43 found all its libraries. ZeroCool's key was in `authorized_keys`, sudo needed no password, and no units failed.
- Update path: apt exited 0, `dpkg --audit` was clean, the re-added "Linux Boot Manager" entries were removed again, and the system rebooted fine.
- At first login Gear Lever integrated Green Light 2.10.3, Kernel Pop 2.1.2, Steam Punk 0.7.0 and Neural Forge 3.8.14, the latest releases. The RDP window set up both ports. FreeRDP logged in with the chosen login on 3390 and 3389 and was refused with a wrong one.
- Skipping MOK enrollment: Security Violation, as intended.
- Not covered: the installer's own UI on real hardware, and the README's recovery steps when MOK Manager was missed (Secure Boot off, `mokutil --import`, Secure Boot on).

Fixed during this run:

- `build.sh` copied `rootfs/` with the checkout's owner. From a checkout that isn't owned by root, the image's `/etc` belonged to that user and `sudo` refused to run in the chroot. Copies are now always owned by root.
- `build.sh` and `disk-test.sh` now mount in a private mount namespace. Before, the test disk's mount spread into the namespaces of services with `ProtectHome=` and of sandboxes such as Steam. It stayed mounted there after the script finished, so the next boot found a dirty filesystem and GRUB could not read it. Unmounting the chroot's bound `/dev` could also reach the host's `/dev/pts`.
- The first-login RDP window is now zenity's username/password dialog. The old form did not submit on Enter.
