#!/bin/sh

ln_scripts() {
    echo "Linking scripts..."
    mkdir -p /data/scripts /app/scripts
    ln -sv /data/scripts/* /app/scripts 2>/dev/null
}

create_ui_config() {
    if [ ! -f /data/ui-config.json ]; then
        echo "Creating empty UI config..."
        echo "{}" >/data/ui-config.json
    fi
}

data_dir_fallback() {
    echo "Setting up data directory fallback..."
    ln -svT /data/ui-config.json /app/ui-config.json 2>/dev/null

    mkdir -p /data/config_states /data/models
    mkdir -p /app/config_states /app/models
    ln -svT /data/config_states/* /app/config_states 2>/dev/null

    find ./models -type f -name 'Put*here.txt' -exec rm {} \;
    find ./models -type d -empty -delete
    ln -svd /data/models/* /app/models 2>/dev/null

    #Installing Onto API Requirements
    #pip install -r requirements.txt

    # Navigate to the extensions folder
    cd /app/extensions

    # Check if the Deforum extension already exists
    if [ -d "sd-forge-deforum" ]; then
        echo "Deforum extension already exists. Skipping clone."
    else
        echo "Cloning Deforum extension..."
        git clone https://github.com/Tok/sd-forge-deforum
    fi
}

install_requirements() {
    if ! pip show torch 2>/dev/null | grep -q Name; then
        echo "Installing torch and related packages... (This will only run once and might take some time)"
        pip install -U --force-reinstall pip setuptools==69.5.1 wheel
        pip install -U \
            --extra-index-url https://download.pytorch.org/whl/cu121 \
            --extra-index-url https://pypi.nvidia.com \
            -r requirements_versions.txt \
            torch==2.3.1 torchvision==0.18.1 xformers==0.0.27
        pip cache purge

        if [ "$(uname -m)" = "x86_64" ]; then
            CC="cc -mavx2" pip install -U --force-reinstall pillow-simd
        fi
    fi
}

correct_permissions() {
    echo "Correcting user data permissions... Please wait a second."
    chmod -R 775 /data 2>/dev/null
    echo "Done."
}

handle_sigint() {
    kill -s INT $python_pid
    wait $python_pid

    echo "WebUI stopped."
    correct_permissions
    exit 0
}

ln_scripts
create_ui_config
data_dir_fallback
install_requirements

trap handle_sigint INT

echo "Starting WebUI with arguments: $*"
python3 /app/launch.py --listen --port 7860 --data-dir /data --gradio-allowed-path "." "$@" &
python_pid=$!

echo "Starting run.py in parallel..."
python3 /run.py &
run_pid=$!

wait $python_pid
wait $run_pid

echo "WebUI stopped."
correct_permissions
