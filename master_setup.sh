#!/bin/bash
# master_setup.sh
#
# This interactive master script sequentially runs:
#   1. The Geekworm X729 UPS setup (from x729Script)
#   2. The custom animated Plymouth splash installation (from PiSplazh)
#   3. The radi0 C++ GUI application build process (from radi0)
#   4. The radi0 autostart configuration (from radi0Boot)
#
# It prompts for key configuration values so that multiple users can run it without modifying the script.
#
# IMPORTANT:
#   - Run this script as root (e.g., via sudo)
#   - Network connectivity and git are required.
#   - Some sub-scripts warn if run as root. For radi0 autostart, the script is executed as the target user.
#
# Exit immediately if a command exits with a non-zero status.
set -e

#####################################
# Utility: Print a progress message #
#####################################
progress() {
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    sleep 1
}

#####################################
# Global Configuration Prompts      #
#####################################

# Prompt for the target username (for radi0 autostart configuration).
read -p "Enter the target username for radi0 autostart (e.g., your username): " TARGET_USERNAME
if [ -z "$TARGET_USERNAME" ]; then
    echo "No username provided. Exiting."
    exit 1
fi
# Determine the home directory for the target user.
TARGET_HOME=$(eval echo "~${TARGET_USERNAME}")
echo "Using target username: $TARGET_USERNAME (home: $TARGET_HOME)"
echo ""

# Prompt for the path to the PNG images (for Plymouth splash installation).
read -p "Enter the full path to your PNG images for the splash screen (the folder containing frame*.png files): " IMG_PATH
if [ -z "$IMG_PATH" ]; then
    echo "No image path provided. Exiting."
    exit 1
fi

# (Optional) Prompt for image frame count (if not provided the splash script will auto-detect).
read -p "Enter the number of image frames (or leave blank to auto-detect): " IMAGE_COUNT

# Prompt for rotation angle (default is 90 degrees).
read -p "Enter the rotation angle (default 90): " ROTATION
if [ -z "$ROTATION" ]; then
    ROTATION=90
fi

# (Optional) Prompt for scaling percentage.
read -p "Enter a scaling percentage (or leave blank for no scaling): " SCALE

# Prompt for the directory where the radi0 repository should be built.
read -p "Enter the full path where the radi0 repository should be cloned (default: ${TARGET_HOME}/radi0): " RADI0_DIR
if [ -z "$RADI0_DIR" ]; then
    RADI0_DIR="${TARGET_HOME}/radi0"
fi

# Prompt for the delay (in seconds) before launching the radi0 application.
read -p "Enter the delay in seconds for the radi0 autostart (default 2) *** add a longer delay if your USB music or BT music isn't loading: " DELAY_SECONDS
if [ -z "$DELAY_SECONDS" ]; then
    DELAY_SECONDS=2
fi

#####################################
# Step 1: Geekworm X729 UPS Setup   #
#####################################
progress "Step 1: Configuring Geekworm X729 UPS Software"
# First, try to use a local copy of setup_x729.sh; if not present, clone the repository.
if [ -f "./setup_x729.sh" ]; then
    echo "Found local setup_x729.sh. Running it now..."
    bash ./setup_x729.sh
else
    echo "Local setup_x729.sh not found. Cloning the x729Script repository..."
    git clone https://github.com/jdx4444/x729Script.git || { echo "Cloning x729Script failed! Exiting."; exit 1; }
    cd x729Script
    bash setup_x729.sh
    cd ..
fi

#####################################
# Step 2: Plymouth Splash Installation
#####################################
progress "Step 2: Installing Custom Plymouth Boot Splash"
# Build the command line for install_plymouth.sh based on user inputs.
PLY_CMD="./install_plymouth.sh -p \"$IMG_PATH\" -r \"$ROTATION\""
if [ ! -z "$IMAGE_COUNT" ]; then
    PLY_CMD="$PLY_CMD -c $IMAGE_COUNT"
fi
if [ ! -z "$SCALE" ]; then
    PLY_CMD="$PLY_CMD -s $SCALE"
fi
echo "Executing: $PLY_CMD"
# Check for a local install_plymouth.sh; if not, clone the repository.
if [ -f "./install_plymouth.sh" ]; then
    bash -c "$PLY_CMD"
else
    echo "Local install_plymouth.sh not found. Cloning the PiSplazh repository..."
    git clone https://github.com/jdx4444/PiSplazh.git || { echo "Cloning PiSplazh failed! Exiting."; exit 1; }
    cd PiSplazh
    bash -c "$PLY_CMD"
    cd ..
fi

#####################################
# Step 3: Build radi0 Application   #
#####################################
progress "Step 3: Building the radi0 Application"
# If the specified radi0 repository directory does not exist, clone it.
if [ ! -d "$RADI0_DIR" ]; then
    echo "radi0 repository not found in ${RADI0_DIR}. Cloning radi0..."
    git clone https://github.com/jdx4444/radi0.git "$RADI0_DIR" || { echo "Cloning radi0 failed! Exiting."; exit 1; }
fi
# Build the application.
echo "Changing directory to ${RADI0_DIR} and building radi0..."
cd "$RADI0_DIR"
make || { echo "Build failed! Exiting."; exit 1; }
if [ ! -f "./radi0x" ]; then
    echo "Build completed but the radi0x executable was not found. Exiting."
    exit 1
fi
echo "radi0x built successfully!"
cd -

#####################################
# Step 4: Configure radi0 Autostart #
#####################################
progress "Step 4: Setting up radi0 Autostart"
# We need the radi0Boot autostart script. Try to use a local copy; if not, clone the repository.
if [ -f "./radi0Boot.sh" ]; then
    echo "Found local radi0Boot.sh. Preparing it for autostart configuration..."
    AUTOSTART_SCRIPT="./radi0Boot.sh"
else
    echo "Local radi0Boot.sh not found. Cloning the radi0Boot repository..."
    git clone https://github.com/jdx4444/radi0Boot.git || { echo "Cloning radi0Boot failed! Exiting."; exit 1; }
    # Assume the script is named radi0Boot.sh inside the repository.
    cp radi0Boot/radi0Boot.sh ./radi0Boot.sh
    AUTOSTART_SCRIPT="./radi0Boot.sh"
fi
# Modify the autostart script to use the provided target username and delay.
sed -i "s/^TARGET_USERNAME=.*/TARGET_USERNAME=\"$TARGET_USERNAME\"/" "$AUTOSTART_SCRIPT"
sed -i "s/^DELAY_SECONDS=.*/DELAY_SECONDS=$DELAY_SECONDS/" "$AUTOSTART_SCRIPT"
echo "Updated radi0Boot.sh with TARGET_USERNAME=$TARGET_USERNAME and DELAY_SECONDS=$DELAY_SECONDS."
echo "Running radi0 autostart configuration as user $TARGET_USERNAME..."
# Run the radi0Boot script as the target user so that the proper home directory is used.
sudo -u "$TARGET_USERNAME" bash "$AUTOSTART_SCRIPT"

#####################################
# Final Message                     #
#####################################
progress "Setup Complete"
echo "All components have been installed/configured successfully."
echo "Please REBOOT your Raspberry Pi for all changes to take effect."
