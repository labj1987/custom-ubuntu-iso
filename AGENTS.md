# Custom Ubuntu ISO

Builds a custom Ubuntu 26.10 desktop install ISO from the official image. `build.sh` is the only entry point.

## Layout

- `build.sh`: verify the official ISO, stack its install layers (`minimal` -> `minimal.standard` -> `minimal.standard.en`) under an overlay, customize in a chroot, squash the overlay's upper dir into `casper/minimal.standard.en.custom.squashfs`, point `casper/install-sources.yaml` at it, repack with `xorriso -boot_image any replay`.
- `scripts/customize-chroot.sh`: runs inside the chroot. Repos, packages, Flatpaks, service enables. Must not leave build-only settings behind; `build.sh` owns those (proxy, CA, `policy-rc.d`, the stashed `cdrom.sources`).
- `rootfs/`: files copied into the image as-is.
  - `custom-iso-firstboot.service` + `firstboot.sh`: root, before the login screen. SSH host keys, OpenRGB udev rules, systemd-boot behind shim, Remote Login TLS, MOK enrollment.
  - `sdboot-sign.sh` + `apt.conf.d/99custom-iso-sdboot-sign`: keep the signed systemd-boot and the shim copies in `EFI/systemd` current after every apt run.
  - `custom-iso-laptop-power.service`: TLP on laptops, after the network is up.
  - `etc/xdg/autostart/custom-iso-firstlogin.desktop` + `firstlogin.sh`: per user. AppImages via Gear Lever, RDP login, NVIDIA hint.
- `keys/`, `remmina-gpu/`: optional inputs (see README).

## Rules

- Nothing that goes stale is bundled: apps come from their repos or GitHub releases at build or first login.
- Installer layer stacking is by file name (curtin splits the name on dots). The custom layer has no `preinstalled_langs`, so the installer never appends a language suffix to its path. Keep it that way or the stack breaks.
- Secure Boot chain: firmware -> shim (`EFI/systemd/shimx64.efi`) -> `EFI/systemd/grubx64.efi`, which is systemd-boot signed with the Kernel Pop key in `/var/lib/kernel-pop/mok/`. Same key format, CN and location as Kernel Pop's `generate_signing_key`; keep them identical so Kernel Pop treats it as its own key.
- The "Ubuntu (systemd-boot)" firmware entry stays LAST in BootOrder until `mokutil --test-key` says the key is enrolled (or Secure Boot is off); only then does `promote_sdboot` put it first. shim refuses an unenrolled systemd-boot with "Security Violation" and the firmware does not fall back to the next entry, so promoting it early leaves a machine that cannot boot (seen in the VM test).
- GRUB stays installed (shim-signed depends on it) with `grub2/update_nvram=false`, so its updates never take the first boot slot.
- No backward compatibility code; the only user is the author.
