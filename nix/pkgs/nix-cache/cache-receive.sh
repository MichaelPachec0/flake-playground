# Forced SSH command for the cache-drop-<repo> upload users. The NixOS module
# prepends DROP_DIR=... and MAX_BYTES=..., and writeShellApplication adds
# `set -euo pipefail`. The command the client asked for ($SSH_ORIGINAL_COMMAND)
# is ignored on purpose: all this account can do is append one size-capped
# bundle to incoming/.
#
# The part file is created with `>` (mode 0666, narrowed by the directory's
# default ACL), not mktemp: mktemp's 0600 would mask the ACL entry that lets
# the importer read the file. noclobber keeps `>` from reusing a name.
#
# The directory's default ACL may give this account no access to its own
# files (default:user::---), so the file is only ever touched through the
# descriptor opened at creation: written via fd 3, sized via /proc (stat
# opens nothing), then renamed. It is never reopened or read back by name.
umask 077
set -o noclobber
part="$DROP_DIR/tmp/part.$$.$(date +%s%N)"
trap 'rm -f -- "$part"' EXIT
exec 3>"$part"
head -c "$((MAX_BYTES + 1))" >&3
size=$(stat -L -c %s -- /proc/self/fd/3)
exec 3>&-
if [ "$size" -gt "$MAX_BYTES" ]; then
  echo "cache-receive: upload exceeds $MAX_BYTES bytes, refused" >&2
  exit 3
fi
if [ "$size" -eq 0 ]; then
  echo "cache-receive: empty upload, refused" >&2
  exit 4
fi
mv -- "$part" "$DROP_DIR/incoming/$(date +%s)-$$.tar.zst"
trap - EXIT
echo ok
