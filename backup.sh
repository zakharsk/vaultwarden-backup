#!/bin/bash

set -ex

# Use the value of the corresponding environment variable, or the
# default if none exists.
: ${VAULTWARDEN_ROOT:="$(realpath "${0%/*}"/..)"}
: ${SQLITE3:="/usr/bin/sqlite3"}
: ${RCLONE:="/usr/bin/rclone"}
: ${GPG:="/usr/bin/gpg"}
: ${AGE:="/usr/local/bin/age"}

DATA_DIR="data"
BACKUP_ROOT="${VAULTWARDEN_ROOT}/backup"
BACKUP_TIMESTAMP="$(date '+%Y%m%d-%H%M')"
BACKUP_DIR_NAME="vaultwarden-${BACKUP_TIMESTAMP}"
BACKUP_DIR_PATH="${BACKUP_ROOT}/${BACKUP_DIR_NAME}"
BACKUP_FILE_DIR="archives"
BACKUP_FILE_NAME="${BACKUP_DIR_NAME}.tar.xz"
BACKUP_FILE_PATH="${BACKUP_ROOT}/${BACKUP_FILE_DIR}/${BACKUP_FILE_NAME}"
DB_FILE="db.sqlite3"

source "${BACKUP_ROOT}"/backup.conf

cd "${VAULTWARDEN_ROOT}"
mkdir -p "${BACKUP_DIR_PATH}"

# Back up the database using the Online Backup API (https://www.sqlite.org/backup.html)
# as implemented in the SQLite CLI. However, if a call to sqlite3_backup_step() returns
# one of the transient errors SQLITE_BUSY or SQLITE_LOCKED, the CLI doesn't retry the
# backup step by default; instead, it stops the backup immediately and returns an error.
#
# Encountering this situation is unlikely, but to be on the safe side, the CLI can be
# configured to retry by using the `.timeout <ms>` meta command to set a busy handler
# (https://www.sqlite.org/c3ref/busy_timeout.html), which will keep trying to open a
# locked table until the timeout period elapses.
busy_timeout=30000 # in milliseconds
${SQLITE3} -cmd ".timeout ${busy_timeout}" \
           "file:${DATA_DIR}/${DB_FILE}?mode=ro" \
           ".backup '${BACKUP_DIR_PATH}/${DB_FILE}'"

backup_files=()
for f in attachments config.json rsa_key.der rsa_key.pem rsa_key.pub.der rsa_key.pub.pem sends; do
    if [[ -e "${DATA_DIR}"/$f ]]; then
        backup_files+=("${DATA_DIR}"/$f)
    fi
done
cp -a "${backup_files[@]}" "${BACKUP_DIR_PATH}"
tar -cJf "${BACKUP_FILE_PATH}" -C "${BACKUP_ROOT}" "${BACKUP_DIR_NAME}"
rm -rf "${BACKUP_DIR_PATH}"
md5sum "${BACKUP_FILE_PATH}"
sha1sum "${BACKUP_FILE_PATH}"

if [[ -n ${GPG_PASSPHRASE} ]]; then
    # https://gnupg.org/documentation/manuals/gnupg/GPG-Esoteric-Options.html
    # Note: Add `--pinentry-mode loopback` if using GnuPG 2.1.
    printf '%s' "${GPG_PASSPHRASE}" |
    ${GPG} -c --cipher-algo "${GPG_CIPHER_ALGO}" --batch --passphrase-fd 0 --pinentry-mode loopback "${BACKUP_FILE_PATH}"
    BACKUP_FILE_NAME+=".gpg"
    BACKUP_FILE_PATH+=".gpg"
    md5sum "${BACKUP_FILE_PATH}"
    sha1sum "${BACKUP_FILE_PATH}"
elif [[ -n ${AGE_PASSPHRASE} ]]; then
    export AGE_PASSPHRASE
    ${AGE} -p -o "${BACKUP_FILE_PATH}.age" "${BACKUP_FILE_PATH}"
    BACKUP_FILE_NAME+=".age"
    BACKUP_FILE_PATH+=".age"
    md5sum "${BACKUP_FILE_PATH}"
    sha1sum "${BACKUP_FILE_PATH}"
fi

# Attempt uploading to all remotes, even if some fail.
set +e

success=0
for dest in "${RCLONE_DESTS[@]}"; do
    if ${RCLONE} -vv --no-check-dest copy "${BACKUP_FILE_PATH}" "${dest}"; then
        (( success++ ))
    fi
done

if [[ ${success} == ${#RCLONE_DESTS[@]} ]]; then
    rclone_message="✅ Backup successfully copied to all destinations."
    rclone_result=0
else
    rclone_message="🆘 Backup copied to ${success} of ${#RCLONE_DESTS[@]} destinations."
    rclone_result=1
fi

echo "$rclone_message"
rclone_message=${rclone_message// /%20}
rclone_message=${rclone_message//✅/%E2%9C%85}
rclone_message=${rclone_message//🆘/%F0%9F%86%98}

# Trying to reach the endpoint of the monitoring system
monitor_result=0
if [[ -n ${MONITOR_URL} && -n ${MONITOR_API} ]]; then
  [[ $rclone_result == 0 ]] && status="up" || status="down"
  monitor_request_url="${MONITOR_URL}${MONITOR_API}?status=${status}&msg=${rclone_message}"

  if curl -fsS -m 10 --retry 5 -o /dev/null "${monitor_request_url}"; then
    monitor_message="✅ Monitor URL ${MONITOR_URL} reached"
    monitor_result=0
  else
    monitor_message="🆘 Monitor ${MONITOR_URL} unavailable"
    monitor_result=1
  fi

  echo "$monitor_message"
  monitor_message=${monitor_message// /%20}
  monitor_message=${monitor_message//✅/%E2%9C%85}
  monitor_message=${monitor_message//🆘/%F0%9F%86%98}
fi

# Trying to send a message via Telegram
telegram_result=0
if [[ -n ${TG_API_TOKEN} && -n ${TG_CHAT_ID} ]]; then
  tg_api_base="https://api.telegram.org/bot"

  tg_text="Vaultwarden%3A%0A${rclone_message}"
  if [[ -n ${monitor_message} ]]; then tg_text="${tg_text}%0A${monitor_message}"; fi

  tg_request_url="${tg_api_base}${TG_API_TOKEN}/sendMessage?chat_id=${TG_CHAT_ID}&text=${tg_text}&disable_web_page_preview=true"

  if curl -fsS -m 10 --retry 5 -o /dev/null "${tg_request_url}"; then
      telegram_message="✅ Telegram message for ${TG_CHAT_ID} sent"
      telegram_result=0
    else
      telegram_message="🆘 Failed to send Telegram message for ${TG_CHAT_ID}"
      telegram_result=1
  fi
  echo "${telegram_message}"
fi


if [[ ${rclone_result} == 1 || ${monitor_result} == 1 || ${telegram_result} == 1 ]]; then
  exit 1
else
  exit 0
fi