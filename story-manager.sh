#!/bin/bash
set -euo pipefail

# PostHuman Validator - Story Node Setup Script
# ------------------------------------------------
# This script is provided by PostHuman Validator to automate the setup and management of Story nodes.
# Use it to install, configure, and maintain nodes efficiently on the Iliad network.
# Visit https://posthuman.digital for more information and support.
# ------------------------------------------------

MIN_CPU_CORES=4
MIN_RAM_MB=16000
MIN_DISK_GB=200
GO_VERSION="1.22.4"
GETH_VERSION="0.9.3-b224fdf"
STORY_VERSION="0.9.13-b4c7db1"


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

install_dependencies() {
    echo "Updating package list and installing required packages..."
    sudo apt-get update && sudo apt-get upgrade -y
    sudo apt-get install -y curl git jq build-essential gcc unzip wget lz4 systemd
    echo "Dependencies installation complete."
}

install_go() {
    echo "Downloading and installing Go..."
    wget -q "https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go${GO_VERSION}.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go${GO_VERSION}.tar.gz
    rm /tmp/go${GO_VERSION}.tar.gz

    # Update PATH without sourcing .bashrc
    echo "export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin" >> /etc/profile.d/go.sh
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

    go version
    echo "Go installation completed successfully."
}

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

initialize_node() {
    echo "Initializing Iliad network node..."
    "$HOME/bin/story" init --network iliad
    echo "Node initialization completed."
}

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

install_snapshot() {
    echo "Choose the type of snapshot you want to install:"
    echo "1. Pruned Snapshot (updated every 24 hours)"
    echo "2. Archive Snapshot (updated every 6 hours)"
    read -rp "Enter your choice [1-2]: " snapshot_choice

    case $snapshot_choice in
        1)
            echo "Installing Pruned Snapshot..."

            # Stop services
            sudo systemctl stop story story-geth

            # Backup priv_validator_state.json if it exists
            if [ -f "$HOME/.story/story/data/priv_validator_state.json" ]; then
                cp $HOME/.story/story/data/priv_validator_state.json $HOME/.story/story/priv_validator_state.json.backup
            fi

            # Remove old data
            rm -rf $HOME/.story/story/data
            rm -rf $HOME/.story/geth/iliad/geth/chaindata

            # Download and unpack the Story snapshot
            echo "Downloading and extracting Story snapshot..."
            if ! curl -L https://snapshots-pruned.story.posthuman.digital/story_pruned.tar.lz4 | lz4 -dc - | tar -xf - -C $HOME/.story/story; then
                echo "Error: Failed to download or extract the Story snapshot."
                return 1
            fi

            # Restore priv_validator_state.json if it was backed up
            if [ -f "$HOME/.story/story/priv_validator_state.json.backup" ]; then
                mv $HOME/.story/story/priv_validator_state.json.backup $HOME/.story/story/data/priv_validator_state.json
            fi

            # Download and unpack the Geth snapshot
            echo "Downloading and extracting Geth snapshot..."
            if ! curl -L https://snapshots-pruned.story.posthuman.digital/geth_story_pruned.tar.lz4 | lz4 -dc - | tar -xf - -C $HOME/.story/geth/iliad/geth; then
                echo "Error: Failed to download or extract the Geth snapshot."
                return 1
            fi

            # Restart services and check logs
            sudo systemctl restart story story-geth
            echo "Pruned Snapshot installation complete. Monitoring logs..."
            sudo journalctl -u story-geth -u story -f
            ;;
        2)
            echo "Installing Archive Snapshot..."

            # Stop services
            sudo systemctl stop story story-geth

            # Backup priv_validator_state.json if it exists
            if [ -f "$HOME/.story/story/data/priv_validator_state.json" ]; then
                cp $HOME/.story/story/data/priv_validator_state.json $HOME/.story/story/priv_validator_state.json.backup
            fi

            # Remove old data
            rm -rf $HOME/.story/story/data
            rm -rf $HOME/.story/geth/iliad/geth/chaindata

            # Download and unpack the Story snapshot
            echo "Downloading and extracting Story snapshot..."
            if ! curl -L https://snapshots.story.posthuman.digital/story_archive.tar.lz4 | lz4 -dc - | tar -xf - -C $HOME/.story/story; then
                echo "Error: Failed to download or extract the Story snapshot."
                return 1
            fi

            # Restore priv_validator_state.json if it was backed up
            if [ -f "$HOME/.story/story/priv_validator_state.json.backup" ]; then
                mv $HOME/.story/story/priv_validator_state.json.backup $HOME/.story/story/data/priv_validator_state.json
            fi

            # Download and unpack the Geth snapshot
            echo "Downloading and extracting Geth snapshot..."
            if ! curl -L https://snapshots.story.posthuman.digital/geth_story_archive.tar.lz4 | lz4 -dc - | tar -xf - -C $HOME/.story/geth/iliad/geth; then
                echo "Error: Failed to download or extract the Geth snapshot."
                return 1
            fi

            # Restart services and check logs
            sudo systemctl restart story story-geth
            echo "Archive Snapshot installation complete. Monitoring logs..."
            sudo journalctl -u story-geth -u story -f
            ;;
        *)
            echo "Invalid option. Please enter 1 or 2."
            ;;
    esac
}


create_validator() {
    echo "Creating a new validator..."

    # Check if node is fully synced
    local sync_status
    sync_status=$(curl -s localhost:$(sed -n '/\[rpc\]/,/laddr/ { /laddr/ {s/.*://; s/".*//; p} }' $HOME/.story/story/config/config.toml)/status | jq -r '.result.sync_info.catching_up')
    if [ "$sync_status" == "false" ]; then
        echo "Node is fully synced."
    else
        echo "Node is still syncing. Please wait until it is fully synced before creating a validator."
        return 1
    fi

    read -rp "Please enter a unique moniker for your node: " moniker
    "$HOME/bin/story" init --network iliad --moniker "$moniker" --force
    echo "Validator created with moniker: $moniker."

    # Display validator key
    echo "Exporting validator key..."
    "$HOME/bin/story" validator export
    echo "Validator key exported. Please back up the key securely."

    # Display EVM private key
    echo "Exporting EVM private key..."
    "$HOME/bin/story" validator export --export-evm-key
    cat "$HOME/.story/story/config/private_key.txt"
    echo "Use this private key to import your account into a wallet, such as Metamask or Phantom."
}

validator_operations() {
    echo "Validator Operations:"
    echo "1. View Validator Info"
    echo "2. Delegate"
    echo "3. Unstake"
    echo "4. Manage Operators"
    echo "5. Set Withdrawal Address"
    echo "6. Back"
    read -rp "Enter your choice [1-6]: " op_choice

    case $op_choice in
        1)
            echo "Exporting validator public key..."
            "$HOME/bin/story" validator export
            ;;
        2)
            echo "Delegating stake..."
            read -rp "Enter the amount to stake (in wei): " stake_amount

            # Check if the private_key.txt file exists
            if [ ! -f "$HOME/.story/story/config/private_key.txt" ]; then
                echo "Error: private_key.txt not found. Make sure your validator is set up correctly."
                return 1
            fi

            # Extract the private key
            private_key=$(grep "PRIVATE_KEY" "$HOME/.story/story/config/private_key.txt" | awk -F'=' '{print $2}')
            if [ -z "$private_key" ]; then
                echo "Error: Could not extract the private key from private_key.txt."
                return 1
            fi

            # Perform the delegation
            "$HOME/bin/story" validator stake --validator-pubkey "$("$HOME/bin/story" validator export | grep "Compressed Public Key (base64)" | awk '{print $NF}')" --stake "$stake_amount" --private-key "$private_key"
            ;;
        3)
            echo "Unstaking from the validator..."
            read -rp "Enter the amount to unstake (in wei): " unstake_amount
            "$HOME/bin/story" validator unstake --validator-pubkey $(story validator export | grep "Compressed Public Key (base64)" | awk '{print $NF}') --unstake "$unstake_amount" --private-key $(cat $HOME/.story/story/config/private_key.txt | grep "PRIVATE_KEY" | awk -F'=' '{print $2}')
            ;;
        4)
            echo "Managing operators..."
            read -rp "Enter the operator's EVM address: " operator_address
            "$HOME/bin/story" validator add-operator --operator "$operator_address" --private-key $(cat $HOME/.story/story/config/private_key.txt | grep "PRIVATE_KEY" | awk -F'=' '{print $2}')
            ;;
        5)
            echo "Setting withdrawal address..."
            read -rp "Enter the withdrawal EVM address: " withdrawal_address
            "$HOME/bin/story" validator set-withdrawal-address --withdrawal-address "$withdrawal_address" --private-key $(cat $HOME/.story/story/config/private_key.txt | grep "PRIVATE_KEY" | awk -F'=' '{print $2}')
            ;;
        6)
            return
            ;;
        *)
            echo "Invalid option. Please enter a number between 1 and 6."
            ;;
    esac
}

node_operations() {
    echo "Node Operations:"
    echo "1. Node Info"
    echo "2. Your Node Peer"
    echo "3. Your Enode"
    echo "4. Configure Firewall Rules"
    echo "5. Back"
    read -rp "Enter your choice [1-5]: " op_choice

    case $op_choice in
        1)
            echo "Fetching node info..."
            curl localhost:$(sed -n '/\[rpc\]/,/laddr/ { /laddr/ {s/.*://; s/".*//; p} }' $HOME/.story/story/config/config.toml)/status | jq
            ;;
        2)
            echo "Fetching your node peer..."
            echo "$(curl localhost:$(sed -n '/\[rpc\]/,/laddr/ { /laddr/ {s/.*://; s/".*//; p} }' $HOME/.story/story/config/config.toml)/status | jq -r '.result.node_info.id')@$(wget -qO- eth0.me):$(sed -n '/Address to listen for incoming connection/{n;p;}' $HOME/.story/story/config/config.toml | sed 's/.*://; s/".*//')"
            ;;
        3)
            echo "Fetching your enode..."
            "$HOME/bin/story-geth" --exec "admin.nodeInfo.enode" attach ~/.story/geth/iliad/geth.ipc
            ;;
        4)
            echo "Configuring firewall rules..."
            sudo ufw allow 30303/tcp comment geth_p2p_port
            sudo ufw allow 26656/tcp comment story_p2p_port
            echo "Firewall rules added."
            ;;
        5)
            return
            ;;
        *)
            echo "Invalid option. Please enter a number between 1 and 5."
            ;;
    esac
}

delete_node() {
    echo "Deleting node..."
    sudo systemctl stop story-geth story
    sudo systemctl disable story-geth story
    sudo rm /etc/systemd/system/story-geth.service /etc/systemd/system/story.service
    sudo systemctl daemon-reload
    rm -rf $HOME/.story $HOME/bin/story-geth $HOME/bin/story
    echo "Node successfully deleted."
}

check_sync_status() {
    echo "Fetching sync status..."
    curl -s localhost:26657/status | jq -r '.result.sync_info'
}

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

service_operations() {
    echo "Service Operations:"
    echo "1. Check Logs"
    echo "2. Start Service"
    echo "3. Stop Service"
    echo "4. Restart Service"
    echo "5. Check Service Status"
    echo "6. Reload Services"
    echo "7. Enable Service"
    echo "8. Disable Service"
    echo "9. Back"
    read -rp "Enter your choice [1-9]: " op_choice

    case $op_choice in
        1)
            echo "Checking logs..."
            sudo journalctl -u story -f -o cat
            ;;
        2)
            echo "Starting Story services..."
            sudo systemctl start story story-geth
            echo "Services started."
            ;;
        3)
            echo "Stopping Story services..."
            sudo systemctl stop story story-geth
            echo "Services stopped."
            ;;
        4)
            echo "Restarting Story services..."
            sudo systemctl restart story story-geth
            echo "Services restarted."
            ;;
        5)
            echo "Checking service status..."
            sudo systemctl status story story-geth
            ;;
        6)
            echo "Reloading services..."
            sudo systemctl daemon-reload
            echo "Services reloaded."
            ;;
        7)
            echo "Enabling services..."
            sudo systemctl enable story story-geth
            echo "Services enabled to start at boot."
            ;;
        8)
            echo "Disabling services..."
            sudo systemctl disable story story-geth
            echo "Services disabled."
            ;;
        9)
            return
            ;;
        *)
            echo "Invalid option. Please enter a number between 1 and 9."
            ;;
    esac
}

geth_operations() {
    echo "Geth Operations:"
    echo "1. Check Latest Block"
    echo "2. Check Peers"
    echo "3. Check Sync Status"
    echo "4. Check Gas Price"
    echo "5. Check Account Balance"
    echo "6. Back"
    read -rp "Enter your choice [1-6]: " op_choice

    case $op_choice in
        1)
            echo "Checking the latest block number..."
            "$HOME/bin/story-geth" --exec "eth.blockNumber" attach ~/.story/geth/iliad/geth.ipc
            ;;
        2)
            echo "Checking connected peers..."
            "$HOME/bin/story-geth" --exec "admin.peers" attach ~/.story/geth/iliad/geth.ipc
            ;;
        3)
            echo "Checking if syncing is in progress..."
            "$HOME/bin/story-geth" --exec "eth.syncing" attach ~/.story/geth/iliad/geth.ipc
            ;;
        4)
            echo "Checking gas price..."
            "$HOME/bin/story-geth" --exec "eth.gasPrice" attach ~/.story/geth/iliad/geth.ipc
            ;;
        5)
            read -rp "Enter the EVM address to check the balance: " evm_address
            echo "Checking account balance for $evm_address..."
            "$HOME/bin/story-geth" --exec "eth.getBalance('$evm_address')" attach ~/.story/geth/iliad/geth.ipc
            ;;
        6)
            return
            ;;
        *)
            echo "Invalid option. Please enter a number between 1 and 6."
            ;;
    esac
}

# Main menu loop
while true; do
    echo -e "\nPostHuman Validator - Story Node Installation and Management Menu"
    echo "1. Install Node (Full Setup)"
    echo "2. Install Snapshot for Faster Sync"
    echo "3. Update Node"
    echo "4. Create Validator"
    echo "5. Validator Operations"
    echo "6. Node Operations"
    echo "7. Service Operations"
    echo "8. Geth Operations"
    echo "9. Delete Node"
    echo "10. Check System Requirements"
    echo "11. Check Sync Status"
    echo "12. Exit"
    read -rp "Enter your choice [1-12]: " choice

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
            validator_operations
            ;;
        6)
            node_operations
            ;;
        7)
            service_operations
            ;;
        8)
            geth_operations
            ;;
        9)
            delete_node
            ;;
        10)
            check_system_requirements
            ;;
        11)
            check_sync_status
            ;;
        12)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please enter a number between 1 and 12."
            ;;
    esac
done
