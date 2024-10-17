#!/bin/bash
set -euo pipefail

# PostHuman Validator - Story Node Setup Script
# ------------------------------------------------
# This script is provided by PostHuman Validator to automate the setup and management of Story nodes.
# Use it to install, configure, and maintain nodes efficiently on the Iliad network.
# Visit https://posthuman.digital for more information and support.
# ------------------------------------------------

# Define minimum hardware requirements
MIN_CPU_CORES=4
MIN_RAM_MB=16000
MIN_DISK_GB=200

# Define Story and Go versions
GO_VERSION="1.22.4"
GETH_VERSION="0.9.3-b224fdf"
STORY_VERSION="0.9.13-b4c7db1"

# Function to check system requirements
check_system_requirements() {
    echo "Validating system specifications..."
    local cpu_cores=$(nproc --all)
    local ram_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
    local disk_gb=$(df --output=avail / | tail -1 | awk '{print int($1 / 1024 / 1024)}')

    if (( cpu_cores < MIN_CPU_CORES )); then
        echo "Warning: Available CPU cores (${cpu_cores}) are fewer than required (${MIN_CPU_CORES})."
        read -rp "Do you want to continue anyway? (y/N): " choice
        if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
            exit 1
        fi
    fi

    if (( ram_mb < MIN_RAM_MB )); then
        echo "Warning: Available RAM (${ram_mb}MB) is less than required (${MIN_RAM_MB}MB)."
        read -rp "Do you want to continue anyway? (y/N): " choice
        if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
            exit 1
        fi
    fi

    if (( disk_gb < MIN_DISK_GB )); then
        echo "Warning: Available disk space (${disk_gb}GB) is less than required (${MIN_DISK_GB}GB)."
        read -rp "Do you want to continue anyway? (y/N): " choice
        if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
            exit 1
        fi
    fi
    echo "System requirements check completed."
}

# Function to update and install dependencies
install_dependencies() {
    echo "Updating package list and installing required packages..."
    sudo apt-get update && sudo apt-get upgrade -y
    sudo apt-get install -y curl git jq build-essential gcc unzip wget lz4 systemd
    echo "Dependencies installation complete."
}

# Function to install Go
install_go() {
    echo "Downloading and installing Go..."
    wget -q "https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go${GO_VERSION}.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go${GO_VERSION}.tar.gz
    rm /tmp/go${GO_VERSION}.tar.gz
    echo "export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin" >> ~/.profile
    source ~/.profile
    go version
    echo "Go installation completed successfully."
}

# Function to install Story-Geth and Story binaries
install_story_binaries() {
    echo "Downloading and installing Story-Geth and Story binaries..."
    local bin_dir="$HOME/bin"
    mkdir -p "$bin_dir"

    wget -q "https://story-geth-binaries.s3.us-west-1.amazonaws.com/geth-public/geth-linux-amd64-${GETH_VERSION}.tar.gz" -O /tmp/geth.tar.gz
    tar -xzf /tmp/geth.tar.gz -C /tmp
    mv /tmp/geth-linux-amd64-${GETH_VERSION}/geth "$bin_dir/story-geth"

    wget -q "https://story-geth-binaries.s3.us-west-1.amazonaws.com/story-public/story-linux-amd64-${STORY_VERSION}.tar.gz" -O /tmp/story.tar.gz
    tar -xzf /tmp/story.tar.gz -C /tmp
    mv /tmp/story-linux-amd64-${STORY_VERSION}/story "$bin_dir/story"

    rm -rf /tmp/geth.tar.gz /tmp/story.tar.gz /tmp/geth-linux-amd64-${GETH_VERSION} /tmp/story-linux-amd64-${STORY_VERSION}
    echo "Story-Geth and Story binaries installed in $bin_dir."
}

# Function to initialize the Iliad network node
initialize_node() {
    echo "Initializing Iliad network node..."
    "$HOME/bin/story" init --network iliad
    echo "Node initialization completed."
}

# Function to configure systemd services for Story-Geth and Story
setup_systemd_services() {
    echo "Setting up systemd services for Story-Geth and Story..."

    sudo tee /etc/systemd/system/story-geth.service > /dev/null <<EOF
[Unit]
Description=Story Geth Client
After=network.target

[Service]
User=$USER
ExecStart=$HOME/bin/story-geth --iliad --syncmode full
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/story.service > /dev/null <<EOF
[Unit]
Description=Story Consensus Client
After=network.target

[Service]
User=$USER
ExecStart=$HOME/bin/story run
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable story-geth story
    sudo systemctl start story-geth story
    echo "Systemd services have been set up and started."
}

# Function to install snapshot for faster synchronization
install_snapshot() {
    echo "Stopping services and installing snapshot for faster synchronization..."
    sudo systemctl stop story-geth story
    rm -rf $HOME/.story/story/data
    curl -L https://storage.crouton.digital/testnet/story/snapshots/story_latest.tar.lz4 | lz4 -dc - | tar -xf - -C $HOME/.story
    sudo systemctl start story-geth story
    echo "Snapshot installation complete."
}

# Function to create validator
create_validator() {
    echo "Creating a new validator..."
    read -rp "Please enter a unique moniker for your node: " moniker
    "$HOME/bin/story" init --network iliad --moniker "$moniker"
    echo "Validator created with moniker: $moniker."
}

# Function to check sync status
check_sync_status() {
    echo "Fetching sync status..."
    curl -s localhost:26657/status | jq -r '.result.sync_info'
}

# Function to view logs for Story and Story-Geth services
view_logs() {
    echo "Select which logs to view:"
    echo "1. Story Logs"
    echo "2. Story-Geth Logs"
    read -rp "Enter your choice [1-2]: " log_choice

    case $log_choice in
        1)
            echo "Displaying Story logs..."
            sudo journalctl -u story -f -o cat
            ;;
        2)
            echo "Displaying Story-Geth logs..."
            sudo journalctl -u story-geth -f -o cat
            ;;
        *)
            echo "Invalid option. Please enter 1 or 2."
            ;;
    esac
}

# Main menu
while true; do
    echo -e "\nPostHuman Validator - Story Node Installation and Management Menu"
    echo "1. Install Node (Full Setup)"
    echo "2. Install Snapshot for Faster Sync"
    echo "3. Update Node"
    echo "4. Create Validator"
    echo "5. View Logs"
    echo "6. Delete Node"
    echo "7. Check System Requirements"
    echo "8. Check Sync Status"
    echo "9. Exit"
    read -rp "Enter your choice [1-9]: " choice

    case $choice in
        1)
            check_system_requirements
            install_dependencies
            install_go
            install_story_binaries
            initialize_node
            setup_systemd_services
            ;;
        2)
            install_snapshot
            ;;
        3)
            install_story_binaries
            sudo systemctl restart story-geth story
            ;;
        4)
            create_validator
            ;;
        5)
            view_logs
            ;;
        6)
            echo "Deleting node..."
            sudo systemctl stop story-geth story
            sudo systemctl disable story-geth story
            sudo rm /etc/systemd/system/story-geth.service /etc/systemd/system/story.service
            sudo systemctl daemon-reload
            rm -rf $HOME/.story $HOME/bin/story-geth $HOME/bin/story
            echo "Node successfully deleted."
            ;;
        7)
            check_system_requirements
            ;;
        8)
            check_sync_status
            ;;
        9)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please enter a number between 1 and 9."
            ;;
    esac
done
