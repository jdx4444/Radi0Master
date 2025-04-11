#!/bin/bash
# master_setup.sh
#

cat << 'EOF'


       o
        \    o
         \  /
          \/
 ===================================
|                     |    o  ,===. |    
| ,===.___,===.___,===|    .  || || |
| |       ,---|   |   |    |  |'='| | 
| `       `---^   `---'    `  `---' |
|___________________________________|

EOF

sleep 4

cat << 'EOF'
        * * * * Warning * * * *
__________________________________________
If you haven't changed from wayland to x11:

  - exit this script with "CTRL C", 
  - go to your terminal and type --
  - sudo raspi-config
  - scroll to advanced settings
  - choose x11 
  - reboot
  - run the script again

EOF

sleep 4

# This master script automates the execution of all the other radi0 setup scripts,
# in the following order:
#   1. Geekworm X729 UPS services https://github.com/jdx4444/x729Script
#   2. Plymouth animated splash (from PiSplazh) https://github.com/jdx4444/PiSplazh
#   3. Radi0 main application build (from radi0) https://github.com/jdx4444/radi0
#   4. Radi0 autostart configuration. (from radi0Boot) https://github.com/jdx4444/radi0Boot
#
# IMPORTANT:
#   - Run this script as root (e.g., via sudo)
#
# Exit on any error
set -e

#############################
# initial Checks
#############################

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Use sudo."
  exit 1
fi

# automatically determine the login username from SUDO_USER if available
if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
  TARGET_USER="$SUDO_USER"
else
  read -p "Enter your login username (for home directory paths): " TARGET_USER
fi

USER_HOME="/home/${TARGET_USER}"
if [ ! -d "${USER_HOME}" ]; then
  echo "Error: The home directory for user '${TARGET_USER}' was not found at '${USER_HOME}'. Please verify the username."
  exit 1
fi

echo "Using login username: ${TARGET_USER} (home: ${USER_HOME})"
echo "-----------------------------------------"
echo "Starting master setup script..."
echo "-----------------------------------------"
sleep 1

cat << 'EOF'
 __   __       ________    ___       __      
/\ \ /\ \     /\_____  \ /'___`\   /'_ `\    
\ `\`\/'/'    \/___//'/'/\_\ /\ \ /\ \L\ \   
 `\/ > <          /' /' \/_/// /__\ \___, \  
    \/'/\`\     /' /'      // /_\ \\/__,/\ \ 
    /\_\\ \_\  /\_/       /\______/     \ \_\
    \/_/ \/_/  \//        \/_____/       \/_/
                                                                                        
EOF
sleep 4

echo "========================================="
echo "Section 1: Geekworm X729 UPS Setup"
echo "========================================="
sleep 1

# clone the repository if not already present
UPS_DIR="/opt/x729-script"
if [ ! -d "${UPS_DIR}" ]; then
  echo "[UPS] Cloning Geekworm X729 script repository into ${UPS_DIR}..."
  git clone https://github.com/geekworm-com/x729-script "${UPS_DIR}"
else
  echo "[UPS] Repository already exists in ${UPS_DIR}. Skipping clone."
fi

# install and configure UPS services.

# fan control service
echo "[UPS] Installing x729-fan service..."
cp -f "${UPS_DIR}/x729-fan.sh" /usr/local/bin/
chmod +x /usr/local/bin/x729-fan.sh
cp -f "${UPS_DIR}/x729-fan.service" /lib/systemd/system/

# power management service
echo "[UPS] Installing x729-pwr service..."
cp -f "${UPS_DIR}/xPWR.sh" /usr/local/bin/
chmod +x /usr/local/bin/xPWR.sh
cp -f "${UPS_DIR}/x729-pwr.service" /lib/systemd/system/

# safe shutdown script
echo "[UPS] Installing xSoft.sh..."
cp -f "${UPS_DIR}/xSoft.sh" /usr/local/bin/
chmod +x /usr/local/bin/xSoft.sh

# add alias for safe shutdown (x729off) to the target user’s .bashrc
ALIAS_LINE="alias x729off='sudo /usr/local/bin/xSoft.sh 0 26'"
TARGET_BASHRC="${USER_HOME}/.bashrc"
if ! grep -qF "$ALIAS_LINE" "${TARGET_BASHRC}"; then
  echo "$ALIAS_LINE" >> "${TARGET_BASHRC}"
  echo "[UPS] Added alias 'x729off' to ${TARGET_BASHRC}."
else
  echo "[UPS] Alias 'x729off' already exists in ${TARGET_BASHRC}."
fi

# Deploy the AC loss shutdown script and its systemd service
echo "[UPS] Deploying AC loss shutdown service..."

# Create the AC loss shutdown Python script.
cat << 'EOF' > /usr/local/bin/ac_loss_shutdown.py
#!/usr/bin/env python3
"""
ac_loss_shutdown.py

This script monitors GPIO6 for an AC loss event.
Upon detecting a rising edge (AC power loss), it waits a debounce delay and,
if AC remains off, calls the xSoft.sh script to trigger a safe shutdown.
"""
import gpiod
import time
import subprocess
import sys

GPIO_CHIP = "gpiochip0"
AC_LOSS_LINE = 6
DEBOUNCE_DELAY = 5

def main():
    try:
        chip = gpiod.Chip(GPIO_CHIP)
    except Exception as e:
        sys.exit(f"Error opening {GPIO_CHIP}: {e}")
    try:
        line = chip.get_line(AC_LOSS_LINE)
    except Exception as e:
        sys.exit(f"Error getting line {AC_LOSS_LINE}: {e}")
    try:
        line.request(consumer="ac_loss_shutdown", type=gpiod.LINE_REQ_EV_BOTH_EDGES)
    except Exception as e:
        sys.exit(f"Error requesting event monitoring: {e}")
    print("AC Loss Shutdown Monitor started. Monitoring GPIO6 for AC power loss events...")
    while True:
        if line.event_wait(5):
            event = line.event_read()
            if event.type == gpiod.LineEvent.RISING_EDGE:
                print("AC power loss detected. Waiting for debounce delay...")
                time.sleep(DEBOUNCE_DELAY)
                if line.get_value() == 1:
                    print("AC power still absent. Initiating safe shutdown...")
                    subprocess.run(["sudo", "/usr/local/bin/xSoft.sh", "0", "26"])
                    break
                else:
                    print("AC power restored during debounce delay. Aborting shutdown.")
            elif event.type == gpiod.LineEvent.FALLING_EDGE:
                print("AC power restored.")
                
if __name__ == "__main__":
    main()
EOF

chmod +x /usr/local/bin/ac_loss_shutdown.py

# Create the systemd service file for the AC loss shutdown.
cat << 'EOF' > /lib/systemd/system/ac-loss-shutdown.service
[Unit]
Description=AC Loss Shutdown Monitor for Geekworm X729 UPS
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ac_loss_shutdown.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable/start the services.
echo "[UPS] Reloading systemd daemon and enabling services..."
systemctl daemon-reload
systemctl enable x729-fan.service && systemctl start x729-fan.service
systemctl enable x729-pwr.service && systemctl start x729-pwr.service
systemctl enable ac-loss-shutdown.service && systemctl start ac-loss-shutdown.service

echo "[UPS] Geekworm X729 UPS setup completed."
echo ""
sleep 1

cat << 'EOF'
 ____    ____    __       ______  ____    __  __     
/\  _`\ /\  _`\ /\ \     /\  _  \/\  _`\ /\ \/\ \    
\ \,\L\_\ \ \L\ \ \ \    \ \ \L\ \ \,\L\_\ \ \_\ \   
 \/_\__ \\ \ ,__/\ \ \  __\ \  __ \/_\__ \\ \  _  \  
   /\ \L\ \ \ \/  \ \ \L\ \\ \ \/\ \/\ \L\ \ \ \ \ \ 
   \ `\____\ \_\   \ \____/ \ \_\ \_\ `\____\ \_\ \_\
    \/_____/\/_/    \/___/   \/_/\/_/\/_____/\/_/\/_/                                                
EOF
sleep 4
                                                     
echo "========================================="
echo "Section 2: Plymouth Animated Splash Setup"
echo "========================================="
sleep 1

# Prompt for the splash screen images directory.
# if the user leaves this blank or types "assets", default to using the assets directory in the PiSplazh repository
read -p "[Splash] Enter the absolute path to your splash screen images directory (default: assets in the PiSplazh repo): " IMAGE_PATH
if [ -z "$IMAGE_PATH" ] || [ "$IMAGE_PATH" = "assets" ]; then
  # Define the default location for the PiSplazh repository.
  DEFAULT_SPLASH_REPO="${USER_HOME}/PiSplazh"
  DEFAULT_SPLASH_DIR="${DEFAULT_SPLASH_REPO}/assets"
  # If the PiSplazh repository hasn't been cloned yet, clone it automatically.
  if [ ! -d "${DEFAULT_SPLASH_REPO}" ]; then
      echo "[Splash] PiSplazh repository not found. Cloning it into ${DEFAULT_SPLASH_REPO}..."
      git clone https://github.com/jdx4444/PiSplazh "${DEFAULT_SPLASH_REPO}"
  fi
  IMAGE_PATH="${DEFAULT_SPLASH_DIR}"
  echo "[Splash] Defaulting to ${IMAGE_PATH}"
fi

if [ ! -d "${IMAGE_PATH}" ]; then
  echo "[Splash] Error: Directory '${IMAGE_PATH}' does not exist."
  exit 1
fi

# Optionally ask for image count (auto-detect if left blank)
read -p "[Splash] Enter the number of image frames (leave blank to auto-detect): " IMAGE_COUNT
if [ -z "${IMAGE_COUNT}" ]; then
  IMAGE_COUNT=$(ls "${IMAGE_PATH}"/frame*.png 2>/dev/null | wc -l)
  if [ "$IMAGE_COUNT" -eq 0 ]; then
    echo "[Splash] No images found in ${IMAGE_PATH} matching frame*.png."
    exit 1
  fi
fi

# Ask for rotation angle, default is 90 degrees.
read -p "[Splash] Enter the rotation angle in degrees (blank/default is 90): " ROTATION
if [ -z "$ROTATION" ]; then
  ROTATION=90
fi

# Ask for scaling percentage (optional)
read -p "[Splash] Enter scaling percentage (leave blank for none): " SCALE

echo "[Splash] Using images from: ${IMAGE_PATH}"
echo "[Splash] Image count: ${IMAGE_COUNT}"
echo "[Splash] Rotation angle: ${ROTATION} degrees"
if [ -n "${SCALE}" ]; then
  echo "[Splash] Scaling percentage: ${SCALE}%"
fi

# Check for ImageMagick's mogrify if rotation or scaling is required
if ! command -v mogrify &> /dev/null; then
  read -p "[Splash] ImageMagick (mogrify) is required for image processing but is not installed. Install it now? (y/n): " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    apt update && apt install -y imagemagick
  else
    echo "[Splash] Cannot process images without ImageMagick. Exiting."
    exit 1
  fi
fi

# define the theme directory
THEME_DIR="/usr/share/plymouth/themes/myanim"
mkdir -p "$THEME_DIR"

# (Optional) Back up any existing theme images.
if [ -d "$THEME_DIR" ]; then
  cp -r "$THEME_DIR" "${THEME_DIR}_backup_$(date +%s)"
fi

# remove old frame images if any.
rm -f "$THEME_DIR"/frame*.png

# copy images from the user-specified directory
cp "${IMAGE_PATH}"/frame*.png "$THEME_DIR"/

# rotate the image.
echo "[Splash] Rotating images by $ROTATION degrees..."
mogrify -rotate "$ROTATION" "$THEME_DIR"/frame*.png

# scale the images if a scaling percentage was provided
if [ -n "$SCALE" ]; then
  echo "[Splash] Scaling images by ${SCALE}%..."
  mogrify -resize "${SCALE}%" "$THEME_DIR"/frame*.png
fi

# create the Plymouth theme descriptor file
DESCRIPTOR_FILE="$THEME_DIR/myanim.plymouth"
cat <<EOF > "$DESCRIPTOR_FILE"
[Plymouth Theme]
Name=My Animation
Description=Custom animated boot splash
ModuleName=script

[script]
ImageDir=$THEME_DIR
ScriptFile=$THEME_DIR/myanim.script
EOF

# create the Plymouth script file
SCRIPT_FILE="$THEME_DIR/myanim.script"
cat <<EOF > "$SCRIPT_FILE"
// Number of frames: $IMAGE_COUNT
frames = $IMAGE_COUNT;
frameImg = [];
for (i = 1; i <= frames; i++) {
    frameImg[i] = Image("frame" + i + ".png");
}
sprite = Sprite(frameImg[1]);
sprite.SetX(Window.GetWidth()/2 - sprite.GetImage().GetWidth()/2);
sprite.SetY(Window.GetHeight()/2 - sprite.GetImage().GetHeight()/2);
counter = 0;
fun refresh_callback() {
    sprite.SetImage(frameImg[Math.Int(counter / 2) % frames]);
    counter++;
}
Plymouth.SetRefreshFunction(refresh_callback);
EOF

# activate the custom theme
echo "[Splash] Activating the custom Plymouth theme..."
if plymouth-set-default-theme -R myanim; then
  echo "[Splash] Theme activated successfully."
else
  echo "[Splash] Automatic activation failed. Trying manual method..."
  update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "$DESCRIPTOR_FILE" 100
  update-alternatives --set default.plymouth "$DESCRIPTOR_FILE"
  update-initramfs -u
fi

echo "[Splash] Plymouth Animated Splash setup complete."
echo ""
sleep 1

cat << 'EOF'
                 __           __     
                /\ \  __    /'__`\   
    __   __     \_\ \/\_\  /\ \/\ \  
/\`/__\/'__`\   /'_` \/\ \ \ \ \ \ \ 
\ \ \//\ \L\.\_/\ \L\ \ \ \ \ \ \_\ \
 \ \_\\ \__/.\_\ \___,_\ \_\ \ \____/
  \/_/ \/__/\/_/\/__,_ /\/_/  \/___/                                                                   
EOF
sleep 4

echo "========================================="
echo "Section 3: Radi0 Application Build"
echo "========================================="
sleep 1

# define the Radi0 directory based on the login user's home
RADI0_DIR="${USER_HOME}/radi0"
if [ ! -d "${RADI0_DIR}" ]; then
  echo "[Radi0] Radi0 directory not found in ${RADI0_DIR}."
  read -p "[Radi0] Do you want to clone the Radi0 repository now? (y/n): " clone_choice
  if [[ "$clone_choice" =~ ^[Yy]$ ]]; then
    git clone https://github.com/jdx4444/radi0.git "${RADI0_DIR}"
  else
    echo "[Radi0] Please clone the repository manually and re-run this section."
    exit 1
  fi
else
  echo "[Radi0] Radi0 directory found in ${RADI0_DIR}. Skipping clone."
fi

# build the application
echo "[Radi0] Building the Radi0 application..."
pushd "${RADI0_DIR}" > /dev/null
make
popd > /dev/null

# check if the executable was created
APP_EXEC="${RADI0_DIR}/radi0x"
if [ ! -f "${APP_EXEC}" ]; then
  echo "[Radi0] Error: Radi0 executable not found at ${APP_EXEC}. Build may have failed."
  exit 1
fi
echo "[Radi0] Radi0 built successfully at ${APP_EXEC}."
echo ""
sleep 1

cat << 'EOF'
 __         __      __   __      
/\ \      /'__`\  /'__`\/\ \__   
\ \ \____/\ \/\ \/\ \/\ \ \ ,_\  
 \ \ '__`\ \ \ \ \ \ \ \ \ \ \/  
  \ \ \L\ \ \ \_\ \ \ \_\ \ \ \_ 
   \ \_,__/\ \____/\ \____/\ \__\
    \/___/  \/___/  \/___/  \/__/                                              
EOF
sleep 4

echo "========================================="
echo "Section 4: Radi0 Autostart Setup"
echo "========================================="
sleep 1

# prompt for an optional delay before launching the app (default is 2 seconds).
echo "Imortant*** delay on startup allows for services to load. Add a longer delay than default 2 seconds if BT and/or USB are not working"
read -p "[Autostart] Enter delay in seconds before launching Radi0 (default is 2): " DELAY_SECONDS
if [ -z "$DELAY_SECONDS" ]; then
  DELAY_SECONDS=2
fi

APP_PATH="${APP_EXEC}"
AUTOSTART_DIR="${USER_HOME}/.config/autostart"
DESKTOP_FILE="${AUTOSTART_DIR}/radi0x_app.desktop"

echo "[Autostart] Configuring autostart for Radi0."
echo "[Autostart] App Path: ${APP_PATH}"
echo "[Autostart] Autostart directory: ${AUTOSTART_DIR}"

# Check if the application executable exists.
if [ ! -f "${APP_PATH}" ]; then
  echo "[Autostart] Error: Application executable not found at ${APP_PATH}."
  exit 1
fi

# Make sure the application is executable.
chmod +x "${APP_PATH}"

# Create autostart directory if needed.
mkdir -p "${AUTOSTART_DIR}"

# Create/update the .desktop file.
cat <<EOF > "${DESKTOP_FILE}"
[Desktop Entry]
Type=Application
Name=Radi0x Application
Comment=Autostart Radi0x with delay
Exec=bash -c 'sleep ${DELAY_SECONDS}; exec ${APP_PATH}'
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

# Clean up any conflicting old autostart files (customize as needed).
rm -f "${AUTOSTART_DIR}/hide_cursor.desktop" "${AUTOSTART_DIR}/kiosk.desktop" 2>/dev/null

echo "[Autostart] Radi0 autostart setup complete."
echo ""
sleep 1

echo "========================================="
echo "All sections completed successfully!"
echo "NOTE:"
echo "  - The UPS setup is active (check with 'systemctl status x729-fan.service')."
echo "  - For the alias to take effect, please Reboot or run 'source ${TARGET_BASHRC}'."
echo "  - at the bottom of /boot/firmware/config.txt -- add: disable_splash=1 and dtoverlay=pwm-2chan,pin2=13,func2=4"
echo "  - at the end of /boot/firmware/cmdline.txt -- add: loglevel=3 vt.global_cursor_default=0"
echo "  - reboot required for the Plymouth splash theme to take effect and for autostart changes to load."
echo "========================================="
echo "Master setup complete. Reboot your system to ensure all changes take effect."
sleep 16

cat << 'EOF'
           __________
__________/ ___  _  /\ ______________________
         //    ||  \\  \_______             /|
        ||_____||___\\/       /o           / |
        | -/  \--------/  \--/o/          /  /     
        `--\__/--------\__/---           /  / 
 ________       ________        ________/  /  
--------       --------        --------/  / 
                                    _ /| /       
                                 _/  | /                       
______________________________/| |__/         
        3ND 0F TH3 R0AD      | |/   
_____________________________|/   

jdx4444

EOF