# Custom Ubuntu ISO

Builds a custom Ubuntu 26.10 desktop install ISO from the official image. `build.sh` is the only entry point.

## Layout

- `build.sh`: verify the official ISO, stack its install layers (`minimal` -> `minimal.standard` -> `minimal.standard.en`) under an overlay, customize in a chroot, squash the overlay's upper dir into `casper/minimal.standard.en.custom.squashfs`, point `casper/install-sources.yaml` at it, repack with `xorriso -boot_image any replay`.
- `scripts/customize-chroot.sh`: runs inside the chroot. Repos, packages, Flatpaks, service enables. Must not leave build-only settings behind; `build.sh` owns those (proxy, CA, `policy-rc.d`, the stashed `cdrom.sources`).
- `rootfs/`: files copied into the image as-is.
  - `custom-iso-firstboot.service` + `firstboot.sh`: root, before the login screen. SSH host keys, OpenRGB udev rules, GRUB wiped and systemd-boot behind shim, Remote Login TLS, MOK enrollment.
  - `sdboot-sign.sh` + `apt.conf.d/99custom-iso-sdboot-sign`: keep systemd-boot signed and current on the ESP after every apt run.
  - `custom-iso-laptop-power.service`: TLP on laptops, after the network is up.
  - `etc/xdg/autostart/custom-iso-firstlogin.desktop` + `firstlogin.sh`: per user. AppImages via Gear Lever, RDP login, NVIDIA hint.
- `keys/`, `remmina-gpu/`: optional inputs (see README).
- `tests/`: local VM tests under UEFI Secure Boot; `tests/README.md` has the procedure and latest results. ISOs and test disks stay local (`out/`, `work/`); never commit or upload them.

## Rules

- Nothing that goes stale is bundled: apps come from their repos or GitHub releases at build or first login.
- Installer layer stacking is by file name (curtin splits the name on dots). The custom layer has no `preinstalled_langs`, so the installer never appends a language suffix to its path. Keep it that way or the stack breaks.
- No GRUB, anywhere. systemd-boot is the only boot loader; the owner enrolls the key at MOK Manager and accepts a Security Violation until then (no fallback loader). The installer always puts GRUB down (the ISO's pool carries it), so first boot wipes it: `custom-iso-no-grub` (built in `customize-chroot.sh`) replaces every GRUB package and stands in for what shim-signed depends on, then `/boot/grub`, GRUB's ESP files and its firmware entry go. GRUB must keep booting until the "Ubuntu" entry and its files are checked: its packages are only removed (purging deletes `/boot/grub/grub.cfg`), every failure before that restores the saved boot order, and only GRUB's own files are deleted afterwards (shim, fb and MOK Manager belong to the systemd-boot package). `tests/disk-test.sh` lays GRUB down only to mimic the installer.
- Secure Boot chain: firmware entry "Ubuntu" -> shim (`EFI/ubuntu/shimx64.efi`) -> `\EFI\systemd\systemd-bootx64.efi` (passed as shim's load option), systemd-boot signed with the Kernel Pop key in `/var/lib/kernel-pop/mok/`. Same key format, CN and location as Kernel Pop's `generate_signing_key`; keep them identical so Kernel Pop treats it as its own key. Ubuntu 26.10 has no Canonical-signed systemd-boot, so the enrolled key is required.
- shim on the ESP and the "Ubuntu" entry belong to the systemd-boot package (its `install_shim`, run by `dpkg-reconfigure systemd-boot` at first boot and by shim updates). It expects Debian's `fbx64.efi.signed`/`mmx64.efi.signed`; the image links them to Ubuntu's signed `fbx64.efi`/`mmx64.efi`, without which it fails and leaves no MOK Manager on the ESP.
- "Ubuntu" is the only firmware boot entry. `bootctl update` (run by every systemd-boot upgrade) re-adds "Linux Boot Manager"/"Fallback Linux Boot Manager", which skip shim; `sdboot-sign.sh --prune` removes them at first boot and after every apt run.
- No backward compatibility code; the only user is the author.

## Shared memory

The owner's Claude sessions (local, cloud and chat) share notes in the Google Drive folder "Claude Memory", one doc per topic; this repo's doc is "project: custom-ubuntu-iso". If you have the Google Drive connector:

- Before starting work, read that doc and the "prefs:" docs for decisions, things already tried or ruled out, and the release state.
- After meaningful work (a release, a decision, a failed attempt worth not repeating, an open issue), update the doc. The connector can't edit a doc's text: create a replacement doc with the same title in that folder, then trash the old one. The folder's "README - how this folder works" doc has the conventions.
