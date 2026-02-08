# SPDX-FileCopyrightText: 2026 John Janssen <https://github.com/jlmjanssen>
#
# SPDX-License-Identifier: MIT-0

# If not running interactively, don't do anything
[[ ! $- =~ i ]] && return

# Load bash run-control files for interactive shells
for rcfile in ~/.bashrc.d/*.bashrc; do
  [[ -f "${rcfile}" ]] && source "${rcfile}"
done
unset rcfile
