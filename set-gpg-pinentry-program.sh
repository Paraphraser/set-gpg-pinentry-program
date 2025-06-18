#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# the name of this script is - changed
SCRIPT="$(basename "${0}")"

# discover path to the user's GPG home (usually ~/.gnupg)
GPG_HOME="$(gpgconf --list-dirs homedir)"

# looks like the agent config file needs to be hard-coded
GPGAGENT_CONF="${GPG_HOME}/gpg-agent.conf"

# check that gpg-agent.conf exists (conscious decision NOT to attempt
# an auto-download using wget or curl - the user really should take
# responsibility for ensuring appropriate components are in place).
if [ ! -f "${GPGAGENT_CONF}" ] ; then
	cat <<-HARDENED
	Error: The file ${GPGAGENT_CONF} does not exist on your system.
	       Please download a "hardened" configuration by following the instructions at:
	          https://github.com/drduh/YubiKey-Guide#ssh
	       and then re-run this script.
	HARDENED
	exit 1
fi

# the pinentry-program target is derived from the argument
PIN_EXE=${1:-""} && [ -n "${PIN_EXE}" ] && PIN_EXE="pinentry-${PIN_EXE}"

# adjust path to increase chances of discovering the most appropriate
# program. Whether any given path actually exists on the current system
# is irrelevant. The intended search ordering is MacGPG2 as a special
# case, then Linux, HomeBrew Apple silicon, HomeBrew Intel silicon,
# followed by MacPorts. The original PATH follows so if a program exists
# at all on the system, it should still be found.
PATH="/usr/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:${PATH}"
PATH="/usr/local/MacGPG2/libexec/pinentry-mac.app/Contents/MacOS:${PATH}"

# the path to the proposed program (if available) is:
# ( the "|| true" allows the script to continue if "which" fails)
PIN_PATH="$(which "${PIN_EXE}")" || true

# handle errors/usage or inappropriate argument
if [ -z "${PIN_PATH}" ] ; then

	[ -n "${PIN_EXE}" ] && echo "Error: \"${PIN_EXE}\" command not found."

	# known candidates for PIN entry programs (https://github.com/gpg/pinentry)
	CANDIDATES=( \
		curses efl emacs fltk gnome3 gtk-2 \
		mac qt qt4 qt5 tqt tty w32 x11 \
	)

	# filter down to candidates available on this system
	for I in $(seq $((${#CANDIDATES[@]}-1)) -1 0) ; do
		[ -z "$(which "pinentry-${CANDIDATES[$I]}")" ] && unset CANDIDATES[$I]
	done

	# any candidates left?
	if [ ${#CANDIDATES[@]} -gt 0 ] ; then
		echo -n "Usage:"
		[ "$(uname -s)" = "Darwin" ] && echo -n " {CODESIGN=\"-\"}"
		echo " $SCRIPT { $(echo "${CANDIDATES[@]}" | sed 's/ / | /g') }"
	else
		echo "Error: No pinentry alternatives found on your system."
	fi

	exit 1

fi

# the option to set a pinentry program is controlled by
PIN_OPT="pinentry-program"

# the config instruction is the concatenation of the option and path
PIN_CFG="${PIN_OPT} ${PIN_PATH}"

# (1) deactivate any active forms of the option, then (2) activate an
# inactive form of the option, if one can be found.
sed -i.bak \
    -e "s:^${PIN_OPT}:#&:g" \
    -e "s:^\#[[:blank:]]*${PIN_OPT}[[:blank:]]*${PIN_PATH}:${PIN_CFG}:" \
    "${GPGAGENT_CONF}"

# append the required option if sed did not succeed in activating an
# inactive form of the option.
[ $(grep -c "^${PIN_CFG}" "${GPGAGENT_CONF}") -eq 0 ] && echo "${PIN_CFG}" >>"${GPGAGENT_CONF}"

# apply the change
gpgconf --reload gpg-agent
echo "Activated ${PIN_CFG}"

# stop here if not macOS
[ "$(uname -s)" != "Darwin" ] && exit 0

# ======================================================================
# macOS-specific
# ======================================================================

# code-signing identity defaults to "-" (ad-hoc)
CODESIGN=${CODESIGN:--}

# additional definitions
GPG_CONNECT_AGENT="$(which gpg-connect-agent)"
GPG_CONF="$(which gpgconf)"

REVERSE_DOMAIN="gnupg"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
AGENT_NAME="gpg-agent-pinentry-mac"
AGENT_LABEL="${REVERSE_DOMAIN}.${AGENT_NAME}"
AGENT_PLIST="${AGENTS_DIR}/${AGENT_LABEL}.plist"
DELEGATE="${AGENT_LABEL}-delegate.sh"
DELEGATE_PATH="$GPG_HOME/${DELEGATE}"
DELEGATE_LOG="${DELEGATE_PATH}.log"

# inactivate and remove any and all associated launch agents (the first
# two are historical; the third is any prior install by this script)
for A in "gnupg.gpg-agent" "gpg-agent-symlink" "${AGENT_LABEL}"; do
	P="${HOME}/Library/LaunchAgents/${A}.plist"
	if [ -f "${P}" ] ; then
		echo "Deactivating existing launch agent at ${P}"
		launchctl unload "${P}"
		echo "Removing obsolete launch agent at ${P}"
		rm -f "${P}"
	fi
done

# remove any pre-existing delegate artefacts (destroys any code-signing)
rm -f "${DELEGATE_PATH}" "${DELEGATE_LOG}"

# is pinentry-mac being activated ?
if [ "${PIN_EXE}" = "pinentry-mac" ] ; then

	# yes! install the delegate script
	cat <<-DELEGATE >"${DELEGATE_PATH}"
	#!/bin/sh
	# redirect output to log if triggered by launch agent
	if [ "\$(tty)" = "not a tty" ] ; then
	   touch "$DELEGATE_LOG"
	   exec >> "$DELEGATE_LOG" 2>&1
	fi
	# sense SSH_AUTH_SOCK undefined
	if [ -z "\$SSH_AUTH_SOCK" ] ; then
	   echo "\$(date) SSH_AUTH_SOCK is undefined (symbolic link can't be created)"
	   exit 1
	fi
	# initialise subsystem
	$GPG_CONNECT_AGENT -q /bye
	# discover path to user socket
	USER_AUTH_SOCK="\$($GPG_CONF --list-dirs agent-ssh-socket)"
	if [ -e "\$USER_AUTH_SOCK" ] ; then
	   if [ -S "\$USER_AUTH_SOCK" ] ; then
	      /bin/ln -sf "\$USER_AUTH_SOCK" "\$SSH_AUTH_SOCK"
	      exit $?
	   else
	      echo "\$(date) \$USER_AUTH_SOCK exists but is not a socket"
	   fi
	else
	   echo "\$(date) \$USER_AUTH_SOCK does not exist"
	fi
	exit 1
	DELEGATE

	# make delegate script executable
	chmod +x "${DELEGATE_PATH}"

	# inform user
	echo "Launch agent delegate installed at ${DELEGATE_PATH}"
	
	# initialise log
	cat <<-LOGINIT >"${DELEGATE_LOG}"
	--------------------------------------------------------------------
	$(date)
	  Installing launch agent at path:
	    ${AGENT_PLIST}
	  which invokes delegate script at path:
	    ${DELEGATE_PATH}
	  which will write messages to this log IF there are problems.
	--------------------------------------------------------------------
	LOGINIT
	
	# sign the script. This is not strictly necessary but Gatekeeper is
	# a moving target. See also System Settings » General » Login Items & Extensions
	codesign --sign "${CODESIGN}" --identifier "${AGENT_LABEL}" "${DELEGATE_PATH}"

	# install the launch agent
	cat <<-LAUNCHAGENT >"${AGENT_PLIST}"
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/ProperyList-1.0/dtd">
	<plist version="1.0">
	   <dict>
	      <key>Label</key>
	      <string>${AGENT_LABEL}</string>
	      <key>ProgramArguments</key>
	      <array>
	         <string>${DELEGATE_PATH}</string>
	      </array>
	      <key>RunAtLoad</key>
	      <true/>
	   </dict>
	</plist>
	LAUNCHAGENT

	# activate the launch agent
	echo "Launch agent installed at ${AGENT_PLIST}"
	launchctl load "${AGENT_PLIST}"

fi
