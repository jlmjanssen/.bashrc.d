# SPDX-FileCopyrightText: 2026 John Janssen <https://github.com/jlmjanssen>
#
# SPDX-License-Identifier: MIT-0

# The GNU Privaty Guard:
# - set the tty for pinentry prompts
export GPG_TTY="$(command -p tty)"
