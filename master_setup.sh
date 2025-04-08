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
# Exit immediately if any command exits with a non-zero status.
set -e

#####################################
# Preliminary Checks & User Prompts #
#####################################

# Ensure the script is run as root.
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Use sudo."
  exit 1
fi

# Ask for the target non-root username.
read -p "Enter the target non-root username for configuration (e.g., your login name): " TARGET_USER
USER_HOME="/home/${TARGET_USER}"
if [ ! -d "${USER_HOME}" ]; then
  echo "Error: The home directory for user '${TARGET_USER}' was not found at '${USER_HOME}'."
  exit 1
fi

echo "Using target user '${TARGET_USER}' with home directory: ${USER_HOME}"
echo "-----------------------------------------"
echo "Starting master setup script..."
echo "-----------------------------------------"
sleep 1

###############################################
# Section 1: Geekworm X729 UPS Setup (Two Repositories)
###############################################
echo "========================================="
echo "Section 1: Geekworm X729 UPS Setup"
echo "========================================="
sleep 1

# Clone Geekworm's x729-script repository.
UPS_GEEKWORM_DIR="/opt/x729-script"
if [ ! -d "${UPS_GEEKWORM_DIR}" ]; then
  echo "[x729] Cloning Geekworm x729-script repository into ${UPS_GEEKWORM_DIR}..."
  git clone https://github.com/geekworm-com/x729-script.git "${UPS_GEEKWORM_DIR}"
else
  echo "[x729] Geekworm repository already exists in ${UPS_GEEKWORM_DIR}. Skipping clone."
fi

# Clone the custom x729Script repository.
UPS_CUSTOM_DIR="/opt/x729Script"
if [ ! -d "${UPS_CUSTOM_DIR}" ]; then
  echo "[x729] Cloning custom x729Script repository into ${UPS_CUSTOM_DIR}..."
  git clone https://github.com/jdx4444/x729Script.git "${UPS_CUSTOM_DIR}"
else
  echo "[x729] Custom x729Script repository already exists in ${UPS_CUSTOM_DIR}. Skipping clone."
fi

# Install UPS services (using files from the Geekworm repository).

# Fan control service.
echo "[x729] Installing x729-fan service..."
cp -f "${UPS_GEEKWORM_DIR}/x729-fan.sh" /usr/local/bin/
chmod +x /usr/local/bin/x729-fan.sh
cp -f "${UPS_GEEKWORM_DIR}/x729-fan.service" /lib/systemd/system/

# Power management service.
echo "[x729] Installing x729-pwr service..."
cp -f "${UPS_GEEKWORM_DIR}/xPWR.sh" /usr/local/bin/
chmod +x /usr/local/bin/xPWR.sh
cp -f "${UPS_GEEKWORM_DIR}/x729-pwr.service" /lib/systemd/system/

# Safe shutdown script.
echo "[x729] Installing xSoft.sh..."
cp -f "${UPS_GEEKWORM_DIR}/xSoft.sh" /usr/local/bin/
chmod +x /usr/local/bin/xSoft.sh

# Add safe shutdown alias (x729off) to the target user's .bashrc.
ALIAS_LINE="alias x729off='sudo /usr/local/bin/xSoft.sh 0 26'"
TARGET_BASHRC="${USER_HOME}/.bashrc"
if ! grep -qF "$ALIAS_LINE" "${TARGET_BASHRC}"; then
  echo "$ALIAS_LINE" >> "${TARGET_BASHRC}"
  echo "[x729] Added alias 'x729off' to ${TARGET_BASHRC}."
else
  echo "[x729] Alias 'x729off' already exists in ${TARGET_BASHRC}."
fi

# Deploy the AC loss shutdown monitor.
echo "[x729] Deploying AC loss shutdown monitor..."
cat << 'EOF' > /usr/local/bin/ac_loss_shutdown.py
#!/usr/bin/env python3
"""
ac_loss_shutdown.py

Monitors GPIO6 for an AC loss event and triggers a safe shutdown after a debounce delay.
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

echo "[x729] Reloading systemd daemon and starting services..."
systemctl daemon-reload
systemctl enable x729-fan.service && systemctl start x729-fan.service
systemctl enable x729-pwr.service && systemctl start x729-pwr.service
systemctl enable ac-loss-shutdown.service && systemctl start ac-loss-shutdown.service
echo "[x729] X729 UPS setup completed successfully!"
echo ""
sleep 1

###########################################
# Section 2: Plymouth Boot Splash Setup (PiSplazh)
###########################################
echo "========================================="
echo "Section 2: Plymouth Animated Splash Setup"
echo "========================================="
sleep 1

# Ensure the PiSplazh repository is properly cloned.
PISPLAZH_DIR="/opt/PiSplazh"
if [ ! -d "${PISPLAZH_DIR}" ] || [ ! -d "${PISPLAZH_DIR}/.git" ]; then
  echo "[Splash] Cloning PiSplazh repository into ${PISPLAZH_DIR}..."
  rm -rf "${PISPLAZH_DIR}"
  git clone https://github.com/jdx4444/PiSplazh.git "${PISPLAZH_DIR}"
else
  echo "[Splash] PiSplazh repository exists. Updating with latest changes..."
  pushd "${PISPLAZH_DIR}" > /dev/null
  git pull
  popd > /dev/null
fi

# Allow the user to choose their splash images.
echo "[Splash] You can use sample images provided with PiSplazh."
read -p "[Splash] Enter the absolute path to your splash screen images (or leave blank to use sample images from ${PISPLAZH_DIR}/sample): " IMAGE_PATH
if [ -z "$IMAGE_PATH" ]; then
  IMAGE_PATH="${PISPLAZH_DIR}/sample"
fi
if [ ! -d "${IMAGE_PATH}" ]; then
  echo "[Splash] Error: Directory '${IMAGE_PATH}' does not exist."
  exit 1
fi

# Optionally ask for image count.
read -p "[Splash] Enter the number of image frames (leave blank to auto-detect): " IMAGE_COUNT
if [ -z "${IMAGE_COUNT}" ]; then
  IMAGE_COUNT=$(ls "${IMAGE_PATH}"/frame*.png 2>/dev/null | wc -l)
  if [ "$IMAGE_COUNT" -eq 0 ]; then
    echo "[Splash] No images found in ${IMAGE_PATH} matching frame*.png. Exiting."
    exit 1
  fi
fi

# Prompt for rotation angle (default is 90).
read -p "[Splash] Enter the rotation angle in degrees (default is 90): " ROTATION
if [ -z "$ROTATION" ]; then
  ROTATION=90
fi

# Prompt for optional scaling percentage.
read -p "[Splash] Enter scaling percentage (leave blank for none): " SCALE

echo "[Splash] Using images from: ${IMAGE_PATH}"
echo "[Splash] Image count: ${IMAGE_COUNT}"
echo "[Splash] Rotation: ${ROTATION} degrees"
if [ -n "${SCALE}" ]; then
  echo "[Splash] Scaling: ${SCALE}%"
fi

# Execute the PiSplazh install script.
echo "[Splash] Installing Plymouth splash using PiSplazh..."
pushd "${PISPLAZH_DIR}" > /dev/null
if [ -n "$SCALE" ]; then
  bash ./install_plymouth.sh -p "${IMAGE_PATH}" -c "${IMAGE_COUNT}" -r "${ROTATION}" -s "${SCALE}"
else
  bash ./install_plymouth.sh -p "${IMAGE_PATH}" -c "${IMAGE_COUNT}" -r "${ROTATION}"
fi
popd > /dev/null

echo "[Splash] Plymouth Animated Splash setup complete."
echo ""
sleep 1

###################################
# Section 3: Radi0 Application Build
###################################
echo "========================================="
echo "Section 3: Radi0 Application Build"
echo "========================================="
sleep 1

RADI0_DIR="${USER_HOME}/radi0"
if [ ! -d "${RADI0_DIR}" ]; then
  echo "[Radi0] Cloning Radi0 repository into ${RADI0_DIR}..."
  sudo -u "${TARGET_USER}" git clone https://github.com/jdx4444/radi0.git "${RADI0_DIR}"
else
  echo "[Radi0] Radi0 repository exists in ${RADI0_DIR}. Updating with latest changes..."
  pushd "${RADI0_DIR}" > /dev/null
  sudo -u "${TARGET_USER}" git pull
  popd > /dev/null
fi

# Build the Radi0 application.
echo "[Radi0] Building Radi0 application..."
pushd "${RADI0_DIR}" > /dev/null
sudo -u "${TARGET_USER}" make clean 2>/dev/null || true
sudo -u "${TARGET_USER}" make
popd > /dev/null

APP_EXEC="${RADI0_DIR}/radi0x"
if [ ! -f "${APP_EXEC}" ]; then
  echo "[Radi0] Error: Radi0 executable not found at ${APP_EXEC}. Build may have failed."
  exit 1
fi
echo "[Radi0] Radi0 built successfully at ${APP_EXEC}."
echo ""
sleep 1

#####################################
# Section 4: Radi0 Autostart Setup
#####################################
echo "========================================="
echo "Section 4: Radi0 Autostart Setup"
echo "========================================="
sleep 1

# Clone (or update) the Radi0Boot repository.
RADI0BOOT_DIR="${USER_HOME}/radi0Boot"
if [ ! -d "${RADI0BOOT_DIR}" ]; then
  echo "[Autostart] Cloning Radi0Boot repository into ${RADI0BOOT_DIR}..."
  sudo -u "${TARGET_USER}" git clone https://github.com/jdx4444/radi0Boot.git "${RADI0BOOT_DIR}"
else
  echo "[Autostart] Radi0Boot repository exists in ${RADI0BOOT_DIR}. Updating..."
  pushd "${RADI0BOOT_DIR}" > /dev/null
  sudo -u "${TARGET_USER}" git pull
  popd > /dev/null
fi

# Prompt for optional launch delay.
read -p "[Autostart] Enter delay in seconds before launching Radi0 (default is 2): " DELAY_SECONDS
if [ -z "$DELAY_SECONDS" ]; then
  DELAY_SECONDS=2
fi

AUTOSTART_DIR="${USER_HOME}/.config/autostart"
DESKTOP_FILE="${AUTOSTART_DIR}/radi0x_app.desktop"

echo "[Autostart] Setting up Radi0 autostart for user ${TARGET_USER}."
echo "[Autostart] Application: ${APP_EXEC}"
echo "[Autostart] Autostart directory: ${AUTOSTART_DIR}"

sudo -u "${TARGET_USER}" mkdir -p "${AUTOSTART_DIR}"

cat <<EOF > "${DESKTOP_FILE}"
[Desktop Entry]
Type=Application
Name=Radi0x Application
Comment=Autostart Radi0x with a delay of ${DELAY_SECONDS} seconds
Exec=bash -c 'sleep ${DELAY_SECONDS}; exec ${APP_EXEC}'
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

rm -f "${AUTOSTART_DIR}/hide_cursor.desktop" "${AUTOSTART_DIR}/kiosk.desktop" 2>/dev/null

echo "[Autostart] Radi0 autostart setup complete."
echo ""
sleep 1

#############################
# Final Completion Message
#############################
echo "========================================="
echo "All sections completed successfully!"
echo "Notes:"
echo "  - X729 UPS services are active (check with 'systemctl status ...')."
echo "  - For the x729off alias to take effect, have '${TARGET_USER}' log out and back in (or run 'source ${TARGET_BASHRC}')."
echo "  - Plymouth splash activation and autostart changes may require a reboot."
echo "========================================="
echo "Master setup complete. Please reboot your system for all changes to take effect."