#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 John Janssen <https://github.com/jlmjanssen>
#
# SPDX-License-Identifier: MIT-0

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "Error: This script must be run, not sourced." >&2
    return 1
fi

SCRIPT_PATH="$(command -p realpath ${0%/*})"
TARGET_PATH="$(command -p realpath ~/.bashrc.d)"
if [[ "${SCRIPT_PATH}" != "${TARGET_PATH}" ]]; then
    echo "Error: Please clone the repository to ~/.bashrc.d" >&2
    exit 1
fi

if [[ -h ~/.bashrc ]]; then
    echo "Error: ~/.bashrc is already a symlink." >&2
    exit 1
fi

command -p chmod 700 ~/.bashrc.d
command -p mv ~/.bashrc ~/.bashrc.d/.bashrc-$(date +%Y%m%d-%H%M%S)
command -p ln -s .bashrc.d/bashrc ~/.bashrc

echo ".bashrc.d has been successfully installed."
