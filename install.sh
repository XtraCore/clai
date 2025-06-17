#!/bin/bash

# This script installs the 'ai' command-line tool for Linux.
# It creates a dedicated virtual environment, config files, a man page,
# and the executable. It also removes any previous installation.

echo "🚀 Starting installation of the 'ai' CLI tool..."

# --- Determine Real User for Home Directory ---
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
sudo -u "$REAL_USER" mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "   Creating default config file..."
    sudo -u "$REAL_USER" bash -c "cat > '$CONFIG_FILE'" << EOF
[API]
# Set provider to 'deepseek' or 'gemini'
provider = deepseek

[Deepseek]
# Get your Deepseek key from https://platform.deepseek.com/
key = YOUR_DEEPSEEK_API_KEY_HERE
model = deepseek-chat

[Gemini]
# Get your Gemini key from https://aistudio.google.com/app/apikey
key = YOUR_GEMINI_API_KEY_HERE
model = gemini-1.5-flash

[Settings]
timeout = 30
EOF
else
    echo "   Config file already exists. Skipping creation."
fi
sudo -u "$REAL_USER" touch "$HISTORY_FILE"
echo "✅ Configuration files are ready."


# --- Create Virtual Environment ---
echo "🐍 Creating a dedicated virtual environment at $VENV_PATH..."
sudo mkdir -p "$VENV_PATH"
sudo chown $REAL_USER "$VENV_PATH"
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

cat > "$TMP_SCRIPT_PATH" << 'EOF'
#!/usr/bin/env python3
#
# The 'ai' command-line interface with multi-provider support.
#

import sys
import os
import requests
import shutil
import configparser
import subprocess
import json
from pathlib import Path

# --- Configuration ---
CONFIG_DIR = Path.home() / ".config" / "ai"
CONFIG_FILE = CONFIG_DIR / "config.ini"
HISTORY_FILE = CONFIG_DIR / "history"

def print_help():
    """Prints a concise help message."""
    help_text = """
Usage: ai [OPTIONS] <PROMPT>

  A command-line tool to convert natural language into shell commands using different AI providers.

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
    
    provider = config.get('API', 'provider', fallback='deepseek').lower()
    
    conf = { 'provider': provider }
    
    if provider == 'deepseek':
        conf['api_key'] = config.get('Deepseek', 'key', fallback=os.getenv("DEEPSEEK_API_KEY"))
        conf['model'] = config.get('Deepseek', 'model', fallback='deepseek-chat')
        conf['url'] = "https://api.deepseek.com/chat/completions"
    elif provider == 'gemini':
        conf['api_key'] = config.get('Gemini', 'key', fallback=os.getenv("GEMINI_API_KEY"))
        conf['model'] = config.get('Gemini', 'model', fallback='gemini-1.5-flash')
        conf['url'] = f"https://generativelanguage.googleapis.com/v1beta/models/{conf['model']}:generateContent"
    
    conf['timeout'] = config.getint('Settings', 'timeout', fallback=30)
    return conf

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

def build_prompt_text(query, context, explanation_mode=False):
    """Creates the final prompt text to be sent to the AI model."""
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

def call_generative_api(config, prompt_text, max_tokens=150):
    """Calls the configured generative AI API."""
    provider = config['provider']
    headers = {"Content-Type": "application/json"}
    payload = {}

    if provider == 'deepseek':
        headers["Authorization"] = f"Bearer {config['api_key']}"
        payload = {
            "model": config['model'],
            "messages": [{"role": "user", "content": prompt_text}],
            "temperature": 0.1, "max_tokens": max_tokens, "stream": False
        }
    elif provider == 'gemini':
        headers["x-goog-api-key"] = config['api_key']
        payload = {
            "contents": [{"parts":[{"text": prompt_text}]}],
            "generationConfig": {
                "temperature": 0.1,
                "maxOutputTokens": max_tokens
            }
        }
    
    response = requests.post(config['url'], headers=headers, json=payload, timeout=config['timeout'])
    response.raise_for_status()
    data = response.json()

    # Parse response based on provider
    if provider == 'deepseek':
        return data['choices'][0]['message']['content']
    elif provider == 'gemini':
        return data['candidates'][0]['content']['parts'][0]['text']

def clean_command(command_text):
    """Cleans the raw text from the AI to get a pure command."""
    if command_text.startswith("```") and command_text.endswith("```"):
        command_text = command_text[3:-3].strip().split('\n', 1)[-1]
    return command_text.strip().strip('`')

def log_to_history(command):
    try:
        with open(HISTORY_FILE, "a") as f: f.write(command + "\n")
    except IOError: pass

def execute_command(command_str, auto_confirm):
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
        if not config.get('api_key') or "YOUR_" in config.get('api_key'):
            print(f"Error: API key for provider '{config['provider']}' not found. Please set it in {CONFIG_FILE}", file=sys.stderr)
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
        prompt = build_prompt_text(user_query, system_context)
        raw_response = call_generative_api(config, prompt)
        generated_command = clean_command(raw_response)

        if explain_mode:
            print(f"Command:\n  `{generated_command}`\n\nExplanation:", file=sys.stderr)
            explanation_prompt = build_prompt_text(generated_command, system_context, explanation_mode=True)
            explanation = call_generative_api(config, explanation_prompt, max_tokens=500)
            print(explanation)
        else:
            execute_command(generated_command, auto_confirm)

    except requests.exceptions.RequestException as e:
        print(f"Error communicating with API: {e}", file=sys.stderr)
    except (KeyError, IndexError, TypeError):
        print("Error: Could not parse API response. Check your API key and model name.", file=sys.stderr)
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
ai - Converts natural language into shell commands using a configurable AI provider.
.SH SYNOPSIS
.B ai
[\fIOPTIONS\fR] \fIPROMPT\fR
.SH DESCRIPTION
\fBai\fR is a tool that uses a configured AI provider (Deepseek or Gemini) to translate a natural language prompt into an executable shell command. It provides a confirmation step before execution for safety.
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
The configuration file. Use this to set your AI provider, API keys, and other settings.
.TP
\fI~/.config/ai/history\fR
The log file where successfully executed commands are stored.
.SH CONFIGURATION
The provider is set in \fI~/.config/ai/config.ini\fR under the \fB[API]\fR section. Set \fBprovider\fR to either \fIdeepseek\fR or \fIgemini\fR. Then, fill in the corresponding API key under the \fB[Deepseek]\fR or \fB[Gemini]\fR section.
EOF

# --- Install Script and Man Page ---
sed -i "1s|.*|#!${VENV_PATH}/bin/python3|" "$TMP_SCRIPT_PATH"
echo "   Installing script to $INSTALL_PATH..."
sudo mv "$TMP_SCRIPT_PATH" "$INSTALL_PATH"
if [ $? -ne 0 ]; then echo "❌ Error moving script. Check permissions." >&2; exit 1; fi
echo "   Making script executable..."
sudo chmod a+rx "$INSTALL_PATH"

echo "   Installing man page to $MAN_DIR..."
sudo mkdir -p "$MAN_DIR"
sudo gzip -c "$TMP_MAN_PATH" > "$MAN_PAGE_PATH"
if [ $? -ne 0 ]; then echo "❌ Error installing man page. Check permissions." >&2; exit 1; fi
sudo chmod 644 "$MAN_PAGE_PATH"

# --- Final Instructions ---
echo -e "\n\n✅ \033[1;32mInstallation Successful!\033[0m"
echo ""
echo "--- ⚠️ IMPORTANT: CONFIGURE YOUR PROVIDER AND API KEY ---"
echo "The installer has created a configuration file for your user ($REAL_USER) here:"
echo -e "  \033[1;33m$CONFIG_FILE\033[0m"
echo "Please edit this file to choose your provider ('deepseek' or 'gemini') and add your API key(s)."
echo ""
echo "You can now use the tool. Run \`man ai\` for more details."

# Cleanly exit
trap - EXIT
exit 0

