#!/usr/bin/env bash

# Copyright (C) 2012 - 2018 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
# This file is licensed under the GPLv2+. Please see COPYING for more information.


umask "${NOTE_STORE_UMASK:-077}"
set -o pipefail

GPG_OPTS=( $NOTE_STORE_GPG_OPTS "--quiet" "--yes" "--compress-algo=none" "--no-encrypt-to" )
GPG="gpg"
export GPG_TTY="${GPG_TTY:-$(tty 2>/dev/null)}"
which gpg2 &>/dev/null && GPG="gpg2"
[[ -n $GPG_AGENT_INFO || $GPG == "gpg2" ]] && GPG_OPTS+=( "--batch" "--use-agent" )

# Find the prefix
[[ -v NOTE_STORE_DIR ]] && PREFIX=${NOTE_STORE_DIR}
if [[ ! -v PREFIX ]]; then
	_PREFIX='.'
	while [[ ! -d "${_PREFIX}/.note-store" && $(readlink -m ${_PREFIX}) != "/" ]] ; do
		_PREFIX="${_PREFIX}/.."
	done

	[[ -d "${_PREFIX}/.note-store" ]] && PREFIX="$(readlink -m ${_PREFIX})/.note-store"

	unset _PREFIX
fi

[[ ! -v PREFIX ]] && PREFIX="${HOME}/.note-store"

EXTENSIONS="${NOTE_STORE_EXTENSIONS_DIR:-$PREFIX/.extensions}"

unset GIT_DIR GIT_WORK_TREE GIT_NAMESPACE GIT_INDEX_FILE GIT_INDEX_VERSION GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
export GIT_CEILING_DIRECTORIES="$PREFIX/.."

#
# BEGIN helper functions
#

set_git() {
	INNER_GIT_DIR="${2%/*}"
	while [[ ! -d $INNER_GIT_DIR && ${INNER_GIT_DIR%/*}/ == "${PREFIX%/}/"* ]]; do
		INNER_GIT_DIR="${INNER_GIT_DIR%/*}"
	done
	[[ $(git -C "$INNER_GIT_DIR" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] || INNER_GIT_DIR=""
}
git_add_file() {
	[[ -n $INNER_GIT_DIR ]] || return
	git -C "$INNER_GIT_DIR" add "$1" || return
	[[ -n $(git -C "$INNER_GIT_DIR" status --porcelain "$1") ]] || return
	git_commit "$2"
}
git_commit() {
	local sign=""
	[[ -n $INNER_GIT_DIR ]] || return
	[[ $(git -C "$INNER_GIT_DIR" config --bool --get note.signcommits) == "true" ]] && sign="-S"
	git -C "$INNER_GIT_DIR" commit $sign -m "$1"
}
yesno() {
	[[ -t 0 ]] || return 0
	local response
	read -r -p "$1 [y/N] " response
	[[ $response == [yY] ]] || exit 1
}
die() {
	echo "$@" >&2
	exit 1
}
verify_file() {
	[[ -n $NOTE_STORE_SIGNING_KEY ]] || return 0
	[[ -f $1.sig ]] || die "Signature for $1 does not exist."
	local fingerprints="$($GPG $NOTE_STORE_GPG_OPTS --verify --status-fd=1 "$1.sig" "$1" 2>/dev/null | sed -n 's/^\[GNUPG:\] VALIDSIG \([A-F0-9]\{40\}\) .* \([A-F0-9]\{40\}\)$/\1\n\2/p')"
	local fingerprint found=0
	for fingerprint in $NOTE_STORE_SIGNING_KEY; do
		[[ $fingerprint =~ ^[A-F0-9]{40}$ ]] || continue
		[[ $fingerprints == *$fingerprint* ]] && { found=1; break; }
	done
	[[ $found -eq 1 ]] || die "Signature for $1 is invalid."
}
set_gpg_recipients() {
	GPG_RECIPIENT_ARGS=( )
	GPG_RECIPIENTS=( )

	if [[ -n $NOTE_STORE_KEY ]]; then
		for gpg_id in $NOTE_STORE_KEY; do
			GPG_RECIPIENT_ARGS+=( "-r" "$gpg_id" )
			GPG_RECIPIENTS+=( "$gpg_id" )
		done
		return
	fi

	local current="$PREFIX/$1"
	while [[ $current != "$PREFIX" && ! -f $current/.gpg-id ]]; do
		current="${current%/*}"
	done
	current="$current/.gpg-id"

	if [[ ! -f $current ]]; then
		cat >&2 <<-_EOF
		Error: You must run:
		    $PROGRAM init your-gpg-id
		before you may use the note store.

		_EOF
		cmd_usage
		exit 1
	fi

	verify_file "$current"

	local gpg_id
	while read -r gpg_id; do
		GPG_RECIPIENT_ARGS+=( "-r" "$gpg_id" )
		GPG_RECIPIENTS+=( "$gpg_id" )
	done < "$current"
}

reencrypt_path() {
	local prev_gpg_recipients="" gpg_keys="" current_keys="" index notefile
	local groups="$($GPG $NOTE_STORE_GPG_OPTS --list-config --with-colons | grep "^cfg:group:.*")"
	while read -r -d "" notefile; do
		[[ -L $notefile ]] && continue
		local notefile_dir="${notefile%/*}"
		notefile_dir="${notefile_dir#$PREFIX}"
		notefile_dir="${notefile_dir#/}"
		local notefile_display="${notefile#$PREFIX/}"
		notefile_display="${notefile_display%.gpg}"
		local notefile_temp="${notefile}.tmp.${RANDOM}.${RANDOM}.${RANDOM}.${RANDOM}.--"

		set_gpg_recipients "$notefile_dir"
		if [[ $prev_gpg_recipients != "${GPG_RECIPIENTS[*]}" ]]; then
			for index in "${!GPG_RECIPIENTS[@]}"; do
				local group="$(sed -n "s/^cfg:group:$(sed 's/[\/&]/\\&/g' <<<"${GPG_RECIPIENTS[$index]}"):\\(.*\\)\$/\\1/p" <<<"$groups" | head -n 1)"
				[[ -z $group ]] && continue
				IFS=";" eval 'GPG_RECIPIENTS+=( $group )' # http://unix.stackexchange.com/a/92190
				unset "GPG_RECIPIENTS[$index]"
			done
			gpg_keys="$($GPG $NOTE_STORE_GPG_OPTS --list-keys --with-colons "${GPG_RECIPIENTS[@]}" | sed -n 's/^sub:[^idr:]*:[^:]*:[^:]*:\([^:]*\):[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[a-zA-Z]*e[a-zA-Z]*:.*/\1/p' | LC_ALL=C sort -u)"
		fi
		current_keys="$(LC_ALL=C $GPG $NOTE_STORE_GPG_OPTS -v --no-secmem-warning --no-permission-warning --decrypt --list-only --keyid-format long "$notefile" 2>&1 | sed -n 's/^gpg: public key is \([A-F0-9]\+\)$/\1/p' | LC_ALL=C sort -u)"

		if [[ $gpg_keys != "$current_keys" ]]; then
			echo "$notefile_display: reencrypting to ${gpg_keys//$'\n'/ }"
			$GPG -d "${GPG_OPTS[@]}" "$notefile" | $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$notefile_temp" "${GPG_OPTS[@]}" &&
			mv "$notefile_temp" "$notefile" || rm -f "$notefile_temp"
		fi
		prev_gpg_recipients="${GPG_RECIPIENTS[*]}"
	done < <(find "$1" -path '*/.git' -prune -o -iname '*.gpg' -print0)
}
check_sneaky_paths() {
	local path
	for path in "$@"; do
		[[ $path =~ /\.\.$ || $path =~ ^\.\./ || $path =~ /\.\./ || $path =~ ^\.\.$ ]] && die "Error: You've attempted to note a sneaky path to note. Go home."
	done
}

#
# END helper functions
#

#
# BEGIN platform definable
#

tmpdir() {
	[[ -n $SECURE_TMPDIR ]] && return
	local warn=1
	[[ $1 == "nowarn" ]] && warn=0
	local template="$PROGRAM.XXXXXXXXXXXXX"
	if [[ -d /dev/shm && -w /dev/shm && -x /dev/shm ]]; then
		SECURE_TMPDIR="$(mktemp -d "/dev/shm/$template")"
		remove_tmpfile() {
			rm -rf "$SECURE_TMPDIR"
		}
		trap remove_tmpfile EXIT
	else
		[[ $warn -eq 1 ]] && yesno "$(cat <<-_EOF
		Your system does not have /dev/shm, which means that it may
		be difficult to entirely erase the temporary non-encrypted
		note file after editing.

		Are you sure you would like to continue?
		_EOF
		)"
		SECURE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/$template")"
		shred_tmpfile() {
			find "$SECURE_TMPDIR" -type f -exec $SHRED {} +
			rm -rf "$SECURE_TMPDIR"
		}
		trap shred_tmpfile EXIT
	fi

}
GETOPT="getopt"
SHRED="shred -f -z"
BASE64="base64"

source "$(dirname "$0")/platform/$(uname | cut -d _ -f 1 | tr '[:upper:]' '[:lower:]').sh" 2>/dev/null # PLATFORM_FUNCTION_FILE

#
# END platform definable
#


#
# BEGIN subcommand functions
#

cmd_version() {
	echo notes v0.9
}

cmd_usage() {
	cmd_version
	echo
	cat <<-_EOF
	Usage:
	    $PROGRAM init [--path=subfolder,-p subfolder] gpg-id...
	        Initialize new note storage in the current directory and use gpg-id for encryption.
	        Selectively reencrypt existing notes using new gpg-id.
	    $PROGRAM [ls] [subfolder]
	        List notes.
	    $PROGRAM find note-names...
	    	List notes that match note-names.
	    $PROGRAM grep [GREPOPTIONS] search-string
	        Search for note files containing search-string when decrypted.
	    $PROGRAM edit note-name
	        Insert a new note or edit an existing note using ${EDITOR:-vi}.
	    $PROGRAM rm [--recursive,-r] [--force,-f] note-name
	        Remove existing note or directory, optionally forcefully.
	    $PROGRAM mv [--force,-f] old-path new-path
	        Renames or moves old-path to new-path, optionally forcefully, selectively reencrypting.
	    $PROGRAM cp [--force,-f] old-path new-path
	        Copies old-path to new-path, optionally forcefully, selectively reencrypting.
	    $PROGRAM git git-command-args...
	        If the note store is a git repository, execute a git command
	        specified by git-command-args.
	    $PROGRAM help
	        Show this text.
	    $PROGRAM version
	        Show version information.

	More information may be found in the note(1) man page.
	_EOF
}

cmd_init() {
	local opts id_path=""
	opts="$($GETOPT -o p: -l path: -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-p|--path) id_path="$2"; shift 2 ;;
		--) shift; break ;;
	esac done

	PREFIX='./.note-store'

	[[ $err -ne 0 || $# -lt 1 ]] && die "Usage: $PROGRAM $COMMAND [--path=subfolder,-p subfolder] gpg-id..."
	[[ -n $id_path ]] && check_sneaky_paths "$id_path"
	[[ -n $id_path && ! -d $PREFIX/$id_path && -e $PREFIX/$id_path ]] && die "Error: $PREFIX/$id_path exists but is not a directory."

	local gpg_id="$PREFIX/$id_path/.gpg-id"
	set_git "$gpg_id"

	if [[ $# -eq 1 && -z $1 ]]; then
		[[ ! -f "$gpg_id" ]] && die "Error: $gpg_id does not exist and so cannot be removed."
		rm -v -f "$gpg_id" || exit 1
		if [[ -n $INNER_GIT_DIR ]]; then
			git -C "$INNER_GIT_DIR" rm -qr "$gpg_id"
			git_commit "Deinitialize ${gpg_id}${id_path:+ ($id_path)}."
		fi
		rmdir -p "${gpg_id%/*}" 2>/dev/null
	else
		mkdir -v -p "$PREFIX/$id_path"
		printf "%s\n" "$@" > "$gpg_id"
		local id_print="$(printf "%s, " "$@")"
		echo "Note store initialized for ${id_print%, }${id_path:+ ($id_path)}"
		git_add_file "$gpg_id" "Set GPG id to ${id_print%, }${id_path:+ ($id_path)}."
		if [[ -n $NOTE_STORE_SIGNING_KEY ]]; then
			local signing_keys=( ) key
			for key in $NOTE_STORE_SIGNING_KEY; do
				signing_keys+=( --default-key $key )
			done
			$GPG "${GPG_OPTS[@]}" "${signing_keys[@]}" --detach-sign "$gpg_id" || die "Could not sign .gpg_id."
			key="$($GPG --verify --status-fd=1 "$gpg_id.sig" "$gpg_id" 2>/dev/null | sed -n 's/^\[GNUPG:\] VALIDSIG [A-F0-9]\{40\} .* \([A-F0-9]\{40\}\)$/\1/p')"
			[[ -n $key ]] || die "Signing of .gpg_id unsuccessful."
			git_add_file "$gpg_id.sig" "Signing new GPG id with ${key//[$IFS]/,}."
		fi
	fi

	reencrypt_path "$PREFIX/$id_path"
	git_add_file "$PREFIX/$id_path" "Reencrypt note store using new GPG id ${id_print%, }${id_path:+ ($id_path)}."
}

cmd_find() {
	[[ $# -eq 0 ]] && die "Usage: $PROGRAM $COMMAND note-names..."
	IFS="," eval 'echo "Search Terms: $*"'
	local terms="*$(printf '%s*|*' "$@")"
	tree -C -l --noreport -P "${terms%|*}" --prune --matchdirs --ignore-case "$PREFIX" | tail -n +2 | sed -E 's/\.gpg(\x1B\[[0-9]+m)?( ->|$)/\1\2/g'
}

cmd_grep() {
	[[ $# -lt 1 ]] && die "Usage: $PROGRAM $COMMAND [GREPOPTIONS] search-string"
	local notefile grepresults
	while read -r -d "" notefile; do
		grepresults="$($GPG -d "${GPG_OPTS[@]}" "$notefile" | grep --color=always "$@")"
		[[ $? -ne 0 ]] && continue
		notefile="${notefile%.gpg}"
		notefile="${notefile#$PREFIX/}"
		local notefile_dir="${notefile%/*}/"
		[[ $notefile_dir == "${notefile}/" ]] && notefile_dir=""
		notefile="${notefile##*/}"
		printf "\e[94m%s\e[1m%s\e[0m:\n" "$notefile_dir" "$notefile"
		echo "$grepresults"
	done < <(find -L "$PREFIX" -path '*/.git' -prune -o -iname '*.gpg' -print0)
}

cmd_edit() {
	[[ $# -ne 1 ]] && die "Usage: $PROGRAM $COMMAND note-name"

	local path="${1%/}"
	check_sneaky_paths "$path"
	mkdir -p -v "$PREFIX/$(dirname -- "$path")"
	set_gpg_recipients "$(dirname -- "$path")"
	local notefile="$PREFIX/$path.gpg"
	set_git "$notefile"

	tmpdir #Defines $SECURE_TMPDIR
	local tmp_file="$(mktemp -u "$SECURE_TMPDIR/XXXXXX")-${path//\//-}.txt"

	local action="Add"
	if [[ -f $notefile ]]; then
		$GPG -d -o "$tmp_file" "${GPG_OPTS[@]}" "$notefile" || exit 1
		action="Edit"
	fi
	${EDITOR:-vi} "$tmp_file"
	[[ -f $tmp_file ]] || die "New note not saved."
	$GPG -d -o - "${GPG_OPTS[@]}" "$notefile" 2>/dev/null | diff - "$tmp_file" &>/dev/null && die "Note unchanged."
	while ! $GPG -e "${GPG_RECIPIENT_ARGS[@]}" -o "$notefile" "${GPG_OPTS[@]}" "$tmp_file"; do
		yesno "GPG encryption failed. Would you like to try again?"
	done
	git_add_file "$notefile" "$action note for $path using ${EDITOR:-vi}."
}

cmd_delete() {
	local opts recursive="" force=0
	opts="$($GETOPT -o rf -l recursive,force -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-r|--recursive) recursive="-r"; shift ;;
		-f|--force) force=1; shift ;;
		--) shift; break ;;
	esac done
	[[ $# -ne 1 ]] && die "Usage: $PROGRAM $COMMAND [--recursive,-r] [--force,-f] note-name"
	local path="$1"
	check_sneaky_paths "$path"

	local notedir="$PREFIX/${path%/}"
	local notefile="$PREFIX/$path.gpg"
	[[ -f $notefile && -d $notedir && $path == */ || ! -f $notefile ]] && notefile="${notedir%/}/"
	[[ -e $notefile ]] || die "Error: $path is not in the note store."
	set_git "$notefile"

	[[ $force -eq 1 ]] || yesno "Are you sure you would like to delete $path?"

	rm $recursive -f -v "$notefile"
	set_git "$notefile"
	if [[ -n $INNER_GIT_DIR && ! -e $notefile ]]; then
		git -C "$INNER_GIT_DIR" rm -qr "$notefile"
		set_git "$notefile"
		git_commit "Remove $path from store."
	fi
	rmdir -p "${notefile%/*}" 2>/dev/null
}

cmd_copy_move() {
	local opts move=1 force=0
	[[ $1 == "copy" ]] && move=0
	shift
	opts="$($GETOPT -o f -l force -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-f|--force) force=1; shift ;;
		--) shift; break ;;
	esac done
	[[ $# -ne 2 ]] && die "Usage: $PROGRAM $COMMAND [--force,-f] old-path new-path"
	check_sneaky_paths "$@"
	local old_path="$PREFIX/${1%/}"
	local old_dir="$old_path"
	local new_path="$PREFIX/$2"

	if ! [[ -f $old_path.gpg && -d $old_path && $1 == */ || ! -f $old_path.gpg ]]; then
		old_dir="${old_path%/*}"
		old_path="${old_path}.gpg"
	fi
	echo "$old_path"
	[[ -e $old_path ]] || die "Error: $1 is not in the note store."

	mkdir -p -v "${new_path%/*}"
	[[ -d $old_path || -d $new_path || $new_path == */ ]] || new_path="${new_path}.gpg"

	local interactive="-i"
	[[ ! -t 0 || $force -eq 1 ]] && interactive="-f"

	set_git "$new_path"
	if [[ $move -eq 1 ]]; then
		mv $interactive -v "$old_path" "$new_path" || exit 1
		[[ -e "$new_path" ]] && reencrypt_path "$new_path"

		set_git "$new_path"
		if [[ -n $INNER_GIT_DIR && ! -e $old_path ]]; then
			git -C "$INNER_GIT_DIR" rm -qr "$old_path" 2>/dev/null
			set_git "$new_path"
			git_add_file "$new_path" "Rename ${1} to ${2}."
		fi
		set_git "$old_path"
		if [[ -n $INNER_GIT_DIR && ! -e $old_path ]]; then
			git -C "$INNER_GIT_DIR" rm -qr "$old_path" 2>/dev/null
			set_git "$old_path"
			[[ -n $(git -C "$INNER_GIT_DIR" status --porcelain "$old_path") ]] && git_commit "Remove ${1}."
		fi
		rmdir -p "$old_dir" 2>/dev/null
	else
		cp $interactive -r -v "$old_path" "$new_path" || exit 1
		[[ -e "$new_path" ]] && reencrypt_path "$new_path"
		git_add_file "$new_path" "Copy ${1} to ${2}."
	fi
}

cmd_git() {
	set_git "$PREFIX/"
	if [[ $1 == "init" ]]; then
		INNER_GIT_DIR="$PREFIX"
		git -C "$INNER_GIT_DIR" "$@" || exit 1
		git_add_file "$PREFIX" "Add current contents of note store."

		echo '*.gpg diff=gpg' > "$PREFIX/.gitattributes"
		git_add_file .gitattributes "Configure git repository for gpg file diff."
		git -C "$INNER_GIT_DIR" config --local diff.gpg.binary true
		git -C "$INNER_GIT_DIR" config --local diff.gpg.textconv "$GPG -d ${GPG_OPTS[*]}"
	elif [[ -n $INNER_GIT_DIR ]]; then
		tmpdir nowarn #Defines $SECURE_TMPDIR. We don't warn, because at most, this only copies encrypted files.
		export TMPDIR="$SECURE_TMPDIR"
		git -C "$INNER_GIT_DIR" "$@"
	else
		die "Error: the note store is not a git repository. Try \"$PROGRAM git init\"."
	fi
}

cmd_extension_or_edit() {
	if ! cmd_extension "$@"; then
		COMMAND="edit"
		cmd_edit "$@"
	fi
}

SYSTEM_EXTENSION_DIR=""
cmd_extension() {
	check_sneaky_paths "$1"
	local user_extension system_extension extension
	[[ -n $SYSTEM_EXTENSION_DIR ]] && system_extension="$SYSTEM_EXTENSION_DIR/$1.bash"
	[[ $NOTE_STORE_ENABLE_EXTENSIONS == true ]] && user_extension="$EXTENSIONS/$1.bash"
	if [[ -n $user_extension && -f $user_extension && -x $user_extension ]]; then
		verify_file "$user_extension"
		extension="$user_extension"
	elif [[ -n $system_extension && -f $system_extension && -x $system_extension ]]; then
		extension="$system_extension"
	else
		return 1
	fi
	shift
	source "$extension" "$@"
	return 0
}

#
# END subcommand functions
#

PROGRAM="${0##*/}"
COMMAND="$1"

case "$1" in
	init) shift;			cmd_init "$@" ;;
	help|--help) shift;		cmd_usage "$@" ;;
	version|--version) shift;	cmd_version "$@" ;;
	find|search) shift;		cmd_find "$@" ;;
	grep) shift;			cmd_grep "$@" ;;
	edit) shift;			cmd_edit "$@" ;;
	delete|rm|remove) shift;	cmd_delete "$@" ;;
	rename|mv) shift;		cmd_copy_move "move" "$@" ;;
	copy|cp) shift;			cmd_copy_move "copy" "$@" ;;
	git) shift;			cmd_git "$@" ;;
	*)				cmd_extension_or_edit "$@" ;;
esac
exit 0
