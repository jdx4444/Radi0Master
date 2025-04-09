#!/bin/bash
# master_setup.sh
#

# ASCII Art Banner for radi0
cat << 'EOF'

                                           __________
__________________________________________/ ___  _  /\ ______________________
                    |    o  ,===.        //    ||  \\  \_______             /|
,===.___,===.___,===|    .  || ||       ||_____||___\\/       /o           / |
|       ,---|   |   |    |  |'='|       | -/  \--------/  \--/o/          /  /     
`       `---^   `---'    `  `---'        --\__/--------\__/---           /  / 
________        ________        ________        ________        ________/  /  
-------        --------        --------        --------        --------/  / 
                                                                    _ /| /       
                                                                  _/  | /                       
_________________________________________________________________/| |__/         
                       END OF THE ROAD                          | |/   
________________________________________________________________|/   

jdx4444

EOF

# This master script automates the execution of all the other radi0 setup scripts,
# in the following order:
#   1. Geekworm X729 UPS services https://github.com/jdx4444/x729Script
#   2. Plymouth animated splash (from PiSplazh) https://github.com/jdx4444/PiSplazh
#   3. Radi0 main application build (from radi0) https://github.com/jdx4444/radi0
#   4. Radi0 autostart configuration. (from radi0Boot) https://github.com/jdx4444/radi0Boot
#
#
# IMPORTANT:
#   - Run this script as root (e.g., via sudo)
#   - Git and network connectivity are required.
#
# Exit on any error
set -e

#############################
# Preliminary Checks & Prompts
#############################

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Use sudo."
  exit 1
fi

# Automatically determine the login username from SUDO_USER if available.
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

#############################
# Section 1: Geekworm X729 UPS Setup
#############################
echo "========================================="
echo "Section 1: Geekworm X729 UPS Setup"
echo "========================================="
sleep 1

# Clone the repository if not already present.
UPS_DIR="/opt/x729-script"
if [ ! -d "${UPS_DIR}" ]; then
  echo "[UPS] Cloning Geekworm X729 script repository into ${UPS_DIR}..."
  git clone https://github.com/geekworm-com/x729-script "${UPS_DIR}"
else
  echo "[UPS] Repository already exists in ${UPS_DIR}. Skipping clone."
fi

# Install and configure UPS services.

# Fan control service
echo "[UPS] Installing x729-fan service..."
cp -f "${UPS_DIR}/x729-fan.sh" /usr/local/bin/
chmod +x /usr/local/bin/x729-fan.sh
cp -f "${UPS_DIR}/x729-fan.service" /lib/systemd/system/

# Power management service
echo "[UPS] Installing x729-pwr service..."
cp -f "${UPS_DIR}/xPWR.sh" /usr/local/bin/
chmod +x /usr/local/bin/xPWR.sh
cp -f "${UPS_DIR}/x729-pwr.service" /lib/systemd/system/

# Safe shutdown script
echo "[UPS] Installing xSoft.sh..."
cp -f "${UPS_DIR}/xSoft.sh" /usr/local/bin/
chmod +x /usr/local/bin/xSoft.sh

# Add alias for safe shutdown (x729off) to the target user’s .bashrc.
ALIAS_LINE="alias x729off='sudo /usr/local/bin/xSoft.sh 0 26'"
TARGET_BASHRC="${USER_HOME}/.bashrc"
if ! grep -qF "$ALIAS_LINE" "${TARGET_BASHRC}"; then
  echo "$ALIAS_LINE" >> "${TARGET_BASHRC}"
  echo "[UPS] Added alias 'x729off' to ${TARGET_BASHRC}."
else
  echo "[UPS] Alias 'x729off' already exists in ${TARGET_BASHRC}."
fi

# Deploy the AC loss shutdown script and its systemd service.
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

#############################
# Section 2: Plymouth Splash Setup
#############################
echo "========================================="
echo "Section 2: Plymouth Animated Splash Setup"
echo "========================================="
sleep 1

# Prompt for the splash screen images directory.
read -p "[Splash] Enter the absolute path to your splash screen images directory (images must be named frame1.png, frame2.png, ...): " IMAGE_PATH
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
read -p "[Splash] Enter the rotation angle in degrees (default is 90): " ROTATION
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

# Check for ImageMagick's mogrify if rotation or scaling is required.
if ! command -v mogrify &> /dev/null; then
  read -p "[Splash] ImageMagick (mogrify) is required for image processing but is not installed. Install it now? (y/n): " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    apt update && apt install -y imagemagick
  else
    echo "[Splash] Cannot process images without ImageMagick. Exiting."
    exit 1
  fi
fi

# Define the theme directory.
THEME_DIR="/usr/share/plymouth/themes/myanim"
mkdir -p "$THEME_DIR"

# (Optional) Back up any existing theme images.
if [ -d "$THEME_DIR" ]; then
  cp -r "$THEME_DIR" "${THEME_DIR}_backup_$(date +%s)"
fi

# Remove old frame images if any.
rm -f "$THEME_DIR"/frame*.png

# Copy images from the user-specified directory.
cp "${IMAGE_PATH}"/frame*.png "$THEME_DIR"/

# Rotate the images.
echo "[Splash] Rotating images by $ROTATION degrees..."
mogrify -rotate "$ROTATION" "$THEME_DIR"/frame*.png

# Scale the images if a scaling percentage was provided.
if [ -n "$SCALE" ]; then
  echo "[Splash] Scaling images by ${SCALE}%..."
  mogrify -resize "${SCALE}%" "$THEME_DIR"/frame*.png
fi

# Create the Plymouth theme descriptor file.
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

# Create the Plymouth script file.
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

# Activate the custom theme.
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

#############################
# Section 3: Radi0 Application Build
#############################
echo "========================================="
echo "Section 3: Radi0 Application Build"
echo "========================================="
sleep 1

# Define the Radi0 directory based on the login user's home.
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

# Build the application.
echo "[Radi0] Building the Radi0 application..."
pushd "${RADI0_DIR}" > /dev/null
make
popd > /dev/null

# Check if the executable was created.
APP_EXEC="${RADI0_DIR}/radi0x"
if [ ! -f "${APP_EXEC}" ]; then
  echo "[Radi0] Error: Radi0 executable not found at ${APP_EXEC}. Build may have failed."
  exit 1
fi
echo "[Radi0] Radi0 built successfully at ${APP_EXEC}."
echo ""
sleep 1

#############################
# Section 4: Radi0 Autostart Setup
#############################
echo "========================================="
echo "Section 4: Radi0 Autostart Setup"
echo "========================================="
sleep 1

# Prompt for an optional delay before launching the app (default is 2 seconds).
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

#############################
# Completion Message
#############################
echo "========================================="
echo "All sections completed successfully!"
echo "NOTE:"
echo "  - The UPS setup is active (check with 'systemctl status x729-fan.service', etc.)."
echo "  - For the alias to take effect, please have user '${TARGET_USER}' log out and back in or run 'source ${TARGET_BASHRC}'."
echo "  - A reboot may be required for the Plymouth splash theme to take effect and for autostart changes to load."
echo "========================================="
echo "Master setup complete. Reboot your system to ensure all changes take effect."
