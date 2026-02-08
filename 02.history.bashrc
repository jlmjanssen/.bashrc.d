# SPDX-FileCopyrightText: 1987-2022 Free Software Foundation, Inc.
#
# SPDX-License-Identifier: GPL-3.0-or-later

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000
