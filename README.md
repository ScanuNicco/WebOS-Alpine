

# WebOS Alpine Launcher
WebOS Alpine Launcher provides all the tools you need to run desktop linux applications on your WebOS TV in a minimally invasive way. After initial installation, the launcher handles launching and tearing down your chroot environment automatically, so no terminal is required. The app passes all WebOS mouse and keyboard inputs through to the desktop, so any peripherals supported by WebOS should "just work"

**Disclaimer:** While this application was designed not to make invasive changes to your TV's OS, I make no gaurantees that it won't break anything. I am **not** responsible for any negative consequences of using this software.

## Demo
![View Demo](https://github.com/ScanuNicco/WebOS-Alpine/raw/refs/heads/main/WebOS_Alpine_Demo.mp4)

## Installation
### Requirements
- Rooted WebOS TV (This app has only been tested on WebOS 22, but other versions may work)
- USB drive (2GB or more)
- Bluetooth Keyboard and Mouse
  - A Magic Remote should work as a mouse, but this is untested as I do not have one.
  - A USB keyboard/mouse *should* work if your TV has multiple USB ports. This is also untested, since my TV only has one.

### Installation
This project assumes you will be running Alpine off of a USB drive. My TV didn't have any partitions larger than 2GB, so installing on the TV's disk was not an option. This may be possible on higher end TVs that have more storage.

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

On your computer, replace `TV_IP`:

```sh
scp -O dist/com.nscanu.webos-vnc_0.1.0_arm.ipk root@TV_IP:/tmp/alpine.ipk
ssh root@TV_IP
```

In the TV's root shell:

```sh
luna-send -i luna://com.webos.appInstallService/dev/install \
  '{"id":"com.nscanu.webos-vnc","ipkUrl":"/tmp/alpine.ipk","subscribe":true}'
```

**Congratulations!** At this point you should have a functioning Linux desktop environment on your TV. The app

## FAQ
**How fast is it?**

Not very. On my TV, simpler apps like file manager and terminal opened within a few seconds and worked well. Firefox took 15-30s, and browsing the internet was quite slow. The TV ran out of memory when trying to play a youtube video. I imagine preformance is quite a bit better on newer or higher-end models.

**How does it work?**

A bundled shell script mounts your Alpine install, enters the chroot, and launches LXQt and a VNC server. The app itself is mostly just a native VNC client for WebOS. This is the least invasive way to run a desktop on desktop on your TV, but it sacrafices some preformance by running the TV's UI at the same time as LXQt. 

**Can I use a different window manager?**
Right now the app is hardcoded to launch LXQt. If you want support for other WMs feel free to submit a PR.

**Does it work on X version of WebOS?**

Maybe. It might work on other versions, but I can only test on the TV I own. The only way to know for sure is to try it.

**Was AI used to develop this?**

Yes.

## Credit
 https://github.com/Ur1man5/alpine-on-webOS for the guide on setting up alpine in a chroot environment 
