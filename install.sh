#!/bin/bash

# This script installs the 'ai' command-line tool for Linux.
# It creates a dedicated virtual environment, config files, a man page,
# and the executable. It also removes any previous installation.

echo "🚀 Starting installation of the 'ai' CLI tool..."

# --- Determine Real User for Home Directory ---
# When run with sudo, $HOME is /root. We need the home of the user who ran sudo.
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="$(whoami)"
fi
REAL_HOME=$(eval echo ~$REAL_USER)

# --- Configuration ---
VENV_PATH="/usr/local/lib/ai-cli"
INSTALL_PATH="/usr/local/bin/ai"
CONFIG_DIR="$REAL_HOME/.config/ai"
CONFIG_FILE="$CONFIG_DIR/config.ini"
HISTORY_FILE="$CONFIG_DIR/history"
MAN_DIR="/usr/local/share/man/man1"
MAN_PAGE_PATH="$MAN_DIR/ai.1.gz"
TMP_SCRIPT_PATH=$(mktemp)
TMP_MAN_PATH=$(mktemp)

# --- Ensure temp files are cleaned up on exit ---
trap 'rm -f "$TMP_SCRIPT_PATH" "$TMP_MAN_PATH"' EXIT

# --- Prime sudo, asking for password upfront if needed ---
echo "🔐 Checking for sudo privileges..."
sudo -v
if [ $? -ne 0 ]; then
    echo "❌ Sudo password entry failed or was cancelled. Please try again."
    exit 1
fi
echo "✅ Sudo privileges confirmed."

# --- Check for Dependencies ---
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: Python 3 is not installed. Please install it to continue."
    exit 1
fi
echo "✅ Python 3 is available."

# --- Clean up old installation if it exists ---
echo "🔎 Checking for existing installations..."
if [ -f "$INSTALL_PATH" ] || [ -d "$VENV_PATH" ] || [ -f "$MAN_PAGE_PATH" ]; then
    echo "   Found an old version. Removing it for a clean update..."
    sudo rm -f "$INSTALL_PATH"
    sudo rm -rf "$VENV_PATH"
    sudo rm -f "$MAN_PAGE_PATH"
    echo "   Old version removed."
fi

# --- Create Config & History files AS THE REAL USER ---
echo "🏡 Creating configuration directory and files in $CONFIG_DIR..."
# Run file creation as the real user to ensure correct ownership and location.
sudo -u "$REAL_USER" mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "   Creating default config file..."
    sudo -u "$REAL_USER" bash -c "cat > '$CONFIG_FILE'" << EOF
[API]
key = YOUR_API_KEY_HERE
model = deepseek-chat

[Settings]
timeout = 20
EOF
else
    echo "   Config file already exists. Skipping creation."
fi
sudo -u "$REAL_USER" touch "$HISTORY_FILE"
echo "✅ Configuration files are ready."


# --- Create Virtual Environment ---
echo "🐍 Creating a dedicated virtual environment at $VENV_PATH..."
sudo mkdir -p "$VENV_PATH"
# Temporarily change ownership to the current user to create venv
sudo chown $USER "$VENV_PATH"
python3 -m venv "$VENV_PATH"
if [ $? -ne 0 ]; then
    echo "❌ Failed to create virtual environment. Please check permissions."
    exit 1
fi

# --- Install Python libraries into the Venv ---
echo "📦 Installing required Python libraries ('requests')..."
sudo "$VENV_PATH/bin/python3" -m pip install --upgrade pip requests > /dev/null
if [ $? -ne 0 ]; then
    echo "❌ Failed to install Python libraries into the venv."
    exit 1
fi
echo "✅ Python dependencies installed successfully."

# --- Create the Python Script in a temporary file ---
echo "✍️  Creating the main script..."

# Write the script content to a temp file using a 'here document'.
cat > "$TMP_SCRIPT_PATH" << 'EOF'
#!/usr/bin/env python3
#
# The 'ai' command-line interface with advanced features.
#

import sys
import os
import requests
import shutil
import configparser
import subprocess
from pathlib import Path

# --- Configuration ---
API_URL = "https://api.deepseek.com/chat/completions"
CONFIG_DIR = Path.home() / ".config" / "ai"
CONFIG_FILE = CONFIG_DIR / "config.ini"
HISTORY_FILE = CONFIG_DIR / "history"

def print_help():
    """Prints a concise help message."""
    help_text = """
Usage: ai [OPTIONS] <PROMPT>

  A command-line tool to convert natural language into shell commands.

Options:
  -y, --yes          Execute the generated command without confirmation.
  --explain          Explain the generated command instead of executing it.
  --history          Show the history of executed commands.
  -h, --help           Show this message and exit.
"""
    print(help_text)

def get_config():
    """Reads configuration from file."""
    config = configparser.ConfigParser()
    config.read(CONFIG_FILE)
    api_key = config.get('API', 'key', fallback=os.getenv("DEEPSEEK_API_KEY"))
    model = config.get('API', 'model', fallback='deepseek-chat')
    timeout = config.getint('Settings', 'timeout', fallback=20)
    return {'api_key': api_key, 'model': model, 'timeout': timeout}

def get_system_context():
    """Gathers information about the Linux environment to help the AI."""
    context = {}
    try:
        with open("/etc/os-release") as f:
            context['distribution'] = "".join(f.readlines())
    except FileNotFoundError:
        context['distribution'] = "Unknown"
    common_tools = ['ip', 'ifconfig', 'apt', 'yum', 'dnf', 'pacman', 'docker', 'git', 'systemctl', 'journalctl', 'netstat', 'ss']
    context['available_tools'] = ", ".join([tool for tool in common_tools if shutil.which(tool)])
    return context

def build_prompt(query, context, explanation_mode=False):
    """Creates the final prompt to be sent to the AI model."""
    if explanation_mode:
        task = f"""
        You are an expert-level Linux assistant. Your function is to explain a given shell command.
        - Provide a clear, concise explanation of what the command does.
        - Break down the command, explaining each part (command, flags, pipes, etc.).
        - Do not execute the command. Just explain it.

        The command to explain is: `{query}`
        """
    else:
        task = f"""
        You are an expert-level Linux assistant. Your only function is to convert a user's natural language request into a single, executable shell command.
        - Respond ONLY with the raw command. Do not provide any explanation or markdown.
        - Ensure the command is properly quoted and escaped for direct execution.
        - Use the system context to choose the correct command (e.g., 'apt' on Debian, 'yum' on CentOS).
        - Include 'sudo' if the operation requires superuser privileges.

        --- System Context ---
        Distribution Info:
        {context.get('distribution', 'N/A')}
        Available Tools:
        {context.get('available_tools', 'N/A')}
        ---
        User's Request: "{query}"
        The single, most appropriate command is:
        """
    return task.strip()

def clean_command(command_text):
    """Cleans the raw text from the AI to get a pure command."""
    if command_text.startswith("```") and command_text.endswith("```"):
        command_text = command_text[3:-3].strip().split('\n', 1)[-1]
    return command_text.strip().strip('`')

def log_to_history(command):
    """Appends a successfully executed command to the history file."""
    try:
        with open(HISTORY_FILE, "a") as f:
            f.write(command + "\n")
    except IOError: pass

def execute_command(command_str, auto_confirm):
    """Executes a command using subprocess and logs it to history."""
    if auto_confirm:
        result = subprocess.run(command_str, shell=True, check=False)
        if result.returncode == 0: log_to_history(command_str)
        sys.exit(result.returncode)

    print(f"\nProposed command:\n\n  \033[1;33m{command_str}\033[0m\n", file=sys.stderr)
    confirm = input("Execute this command? [Y/n] ")
    if confirm.lower() != 'n':
        print("🚀 Executing...", file=sys.stderr)
        result = subprocess.run(command_str, shell=True, check=False)
        if result.returncode == 0:
            log_to_history(command_str)
        else:
            print(f"⚠️ Command finished with a non-zero exit code: {result.returncode}", file=sys.stderr)
    else:
        print("Aborted.", file=sys.stderr)

def main():
    try:
        if '-h' in sys.argv or '--help' in sys.argv:
            print_help()
            sys.exit(0)

        config = get_config()
        api_key = config['api_key']

        if not api_key or "YOUR_API_KEY_HERE" in api_key:
            print("Error: API key not found. Please set it in ~/.config/ai/config.ini or as DEEPSEEK_API_KEY.", file=sys.stderr)
            sys.exit(1)
        
        if '--history' in sys.argv:
            if HISTORY_FILE.exists(): print(HISTORY_FILE.read_text())
            sys.exit(0)

        auto_confirm = '-y' in sys.argv or '--yes' in sys.argv
        explain_mode = '--explain' in sys.argv

        filtered_args = [arg for arg in sys.argv[1:] if arg not in ('-y', '--yes', '--explain', '-h', '--help')]
        if not filtered_args:
            print_help()
            sys.exit(1)
        user_query = " ".join(filtered_args)

        if not auto_confirm: print("🧠 Thinking...", file=sys.stderr)

        system_context = get_system_context()
        prompt = build_prompt(user_query, system_context)
        
        headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
        payload = {"model": config['model'], "messages": [{"role": "user", "content": prompt}], "temperature": 0.1, "max_tokens": 150, "stream": False}
        response = requests.post(API_URL, headers=headers, json=payload, timeout=config['timeout'])
        response.raise_for_status()
        generated_command = clean_command(response.json()['choices'][0]['message']['content'])

        if explain_mode:
            print(f"Command:\n  `{generated_command}`\n\nExplanation:", file=sys.stderr)
            explanation_prompt = build_prompt(generated_command, system_context, explanation_mode=True)
            payload["messages"] = [{"role": "user", "content": explanation_prompt}]
            payload["max_tokens"] = 500
            response = requests.post(API_URL, headers=headers, json=payload, timeout=config['timeout'])
            response.raise_for_status()
            print(response.json()['choices'][0]['message']['content'])
        else:
            execute_command(generated_command, auto_confirm)

    except requests.exceptions.RequestException as e:
        print(f"Error communicating with API: {e}", file=sys.stderr)
    except (KeyError, IndexError):
        print("Error: Could not parse API response.", file=sys.stderr)
    except KeyboardInterrupt:
        print("\nAborted by user.", file=sys.stderr)
        sys.exit(130)

if __name__ == "__main__":
    main()
EOF

# --- Create the Man Page ---
echo "📖 Creating the man page..."
cat > "$TMP_MAN_PATH" << 'EOF'
.TH AI 1 "June 2024" "ai cli" "User Commands"
.SH NAME
ai - A command-line helper to convert natural language into shell commands.
.SH SYNOPSIS
.B ai
[\fIOPTIONS\fR] \fIPROMPT\fR
.SH DESCRIPTION
\fBai\fR is a tool that uses the Deepseek AI API to translate a natural language prompt into an executable shell command. It provides a confirmation step before execution for safety.
.SH OPTIONS
.TP
\fB-y, --yes\fR
Execute the generated command immediately without asking for confirmation. Useful for scripting.
.TP
\fB--explain\fR
Instead of executing the command, ask the AI to provide an explanation of what the command does.
.TP
\fB--history\fR
Display a log of previously executed commands.
.TP
\fB-h, --help\fR
Show a brief help message and exit.
.SH FILES
.TP
\fI~/.config/ai/config.ini\fR
The configuration file for the API key and other settings. The installer creates a default template.
.TP
\fI~/.config/ai/history\fR
The log file where successfully executed commands are stored.
.SH EXAMPLES
.TP
.B Getting your IP address:
$ ai what is my local ip
.TP
.B Explaining a command:
$ ai --explain find all files larger than 100M
.TP
.B Running without confirmation:
$ ai -y update my system packages
EOF

# --- Install Script and Man Page ---
# Update shebang in script
sed -i "1s|.*|#!${VENV_PATH}/bin/python3|" "$TMP_SCRIPT_PATH"
# Move script to final destination
echo "   Installing script to $INSTALL_PATH..."
sudo mv "$TMP_SCRIPT_PATH" "$INSTALL_PATH"
if [ $? -ne 0 ]; then echo "❌ Error moving script. Check permissions." >&2; exit 1; fi
# Set permissions for script
echo "   Making script executable..."
sudo chmod a+rx "$INSTALL_PATH"

# Create man directory and install man page
echo "   Installing man page to $MAN_DIR..."
sudo mkdir -p "$MAN_DIR"
sudo gzip -c "$TMP_MAN_PATH" > "$MAN_PAGE_PATH"
if [ $? -ne 0 ]; then echo "❌ Error installing man page. Check permissions." >&2; exit 1; fi
sudo chmod 644 "$MAN_PAGE_PATH"

# --- Final Instructions ---
echo -e "\n\n✅ \033[1;32mInstallation Successful!\033[0m"
echo ""
echo "--- ⚠️ IMPORTANT: CONFIGURE YOUR API KEY ---"
echo "The installer has created a configuration file for your user ($REAL_USER) here:"
echo -e "  \033[1;33m$CONFIG_FILE\033[0m"
echo "Please edit this file and replace 'YOUR_API_KEY_HERE' with your actual Deepseek API key."
echo ""
echo "You can now use the new features:"
echo "  - ai 'your request'     (Normal operation)"
echo "  - ai -h, --help           (Show help)"
echo "  - man ai                  (View the manual page)"

# Cleanly exit
trap - EXIT
exit 0

