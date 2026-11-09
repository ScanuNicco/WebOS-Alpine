# WebOS Alpine
WebOS Alpine provides all the tools you need to run desktop linux applications on your WebOS TV.

## Installation
### Requirements
- Rooted WebOS TV (This app has only been tested on WebOS 22, but other versions will likely work)
- USB drive (2GB or more)
- Bluetooth Keyboard and Mouse

### Installation
This project assumes you will be Alpine off of a USB drive. My TV didn't have any partitions larger than 2GB, so installing on the TV's disk was not an option. This may be possible on higher end TVs that have more storage

**Preparing your Drive:**
- Format the drive as ext4. This will wipe the drive
- Go to https://alpinelinux.org/downloads/ and download the rootfs image. Choose aarch64 or armv7 depending on the architecture of your TV
- Unzip the contents of the dowloaded image onto the drive. If you have done this right you will see typical linux folders like `bin`, `boot`, and `home` at the top level

**Configuring Alpine:**

Before you can use Alpine on your TV, you will need to install LXQt and a VNC server.
- Enable SSH access on your TV in Homebrew settings
- SSH into your TV
  - Username: `root`
  - Password: `alpine`
- Insert your USB drive into the TV
  - A popup will ask you to format the drive. This is safe to ignore. **Do not format the drive**
- Mount the drive
   ```bash
  # Make Mount Directory
  mkdir -p /tmp/alpine
  
  # Mount USB
  mount -t ext4 /dev/sda1 /tmp/alpine
  ```
- Create necessary bindings for chroot to work
  ```bash
  # Give Device Access
  mount --bind /dev /tmp/alpine/dev
  mount -t proc proc /tmp/alpine/proc
  mount -t sysfs sysfs /tmp/alpine/sys
  mkdir -p /tmp/alpine/dev/pts
  mount --bind /dev/pts /tmp/alpine/dev/pts
  ```
- Enter the chroot
  ```bash
    # Enter chroot
  chroot /tmp/alpine /bin/sh
  ```
- Add the line `printf '\nexport HOME=/root\n' >> /etc/profile` to the end of `/etc/profile`
- Install VNC server and LXQt
  ```bash
  # Install VNC server
  apk add tigervnc openbox xterm
  mkdir -p "$HOME/.vnc"

  # Install LXQt
  apk add lxqt-desktop dbus
  apk add papirus-icon-theme
  ```

**Installing the App:**
TBD

**Credit:** https://github.com/Ur1man5/alpine-on-webOS for the guide on initial chroot 
