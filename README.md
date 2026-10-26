# Custom Ubuntu 26.10 ISO

A rebuild of the official Ubuntu 26.10 desktop image that installs a ready-to-use system:

- systemd-boot as the default boot loader, with Secure Boot (shim loads a systemd-boot signed with your own key; GRUB stays behind it as a fallback boot entry)
- Flatpak with Flathub, and GNOME Software as the store for Flatpak apps (snaps and the App Center are unchanged)
- Claude desktop, Steam, VLC and Tailscale from their official repositories
- Gear Lever, Proton Plus and OpenRGB from Flathub
- Green Light, Kernel Pop, Steam Punk and Neural Forge, the latest releases, integrated through Gear Lever at first login
- GNOME Remote Desktop: Remote Login on port 3389, Desktop Sharing on port 3390
- GPU-accelerated Remmina (FreeRDP with H.264) in `/opt/remmina-gpu`
- SSH server, with a pre-authorized key
- Passwordless sudo for administrators
- TLP power management on laptops only

## Installing

Boot the ISO and install as usual. Then:

1. **First boot.** Before the login screen, the system sets up systemd-boot and, with Secure Boot on, reboots once by itself.
2. **Blue MOK Manager screen.** Choose *Enroll MOK*, *Continue*, *Yes*, then type the one-time password **`enrollmok`** and reboot. This enrolls the key that signs systemd-boot. If the screen is skipped, the computer still boots through GRUB, and Kernel Pop's signing setup can enroll the key later.
3. **First login.** The four AppImage apps download and install in the background. A window asks for the remote desktop username and password (used for both ports). On a computer with an NVIDIA GPU, a notification points to Green Light for the driver.
4. **Sign in** to Tailscale (`tailscale up`), Claude desktop and Steam.

The signing key lives in `/var/lib/kernel-pop/mok/`, the same place Kernel Pop keeps its own, so kernels Kernel Pop installs boot with the same enrollment. Updates to systemd-boot are re-signed automatically after every apt run.

## Building

```bash
sudo ./build.sh
```

The script downloads the official image, checks it against Ubuntu's signed checksums, adds one squashfs layer on top of the installer's own layers, and writes `out/ubuntu-26.10-custom-amd64.iso` with a `.sha256` next to it. Use `--iso PATH` to build from an image you already have. It needs root, `xorriso`, `squashfs-tools`, `gpg` and `curl`, and about 25 GB of free space.

Optional inputs:

- `keys/zerocool.pub`: an SSH public key added to every new user's `authorized_keys`.
- `remmina-gpu/`: the GPU Remmina build script and patch.

## License

AGPL-3.0. See `LICENSE`.
