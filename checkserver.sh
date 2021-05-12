#!/usr/bin/env bash

# README
# ------
#
# This script is designed to be a passive DeFiChain master node monitoring solution.  It will examine the state of your
# server and alert you to any problems it finds.  More details and specifics can be found in the README.md of the GIT
# repo linked below.
#
# Bugs or suggestions?  Please either message me directly (huwilerm@champlain.edu) or submit a pull request to
# https://github.com/huwiler/defichain-masternode-scripts
#

# INSTALLATION
# ------------
#
# Before this script will work you must:
#
#  - Ensure curl and jq are installed in /usr/bin/
#  - Run from the home directory that contains the .defi folder as that user
#  - If you want the script to send you email, uncomment and edit the config information below OR replace mailgun
#    related code in notify() with local SMTP or a alternative mailer service
#  - Once mail gun (or other notification service) is configured, I recommend setting this up to run from cron.  For
#    example, I run this every half hour via the following crontab entry:
#
#    */30 * * * * /home/huwiler/bin/checkserver.sh
#

# CONFIG
# ------
#
# If using mailgun, uncomment the following lines and replace with your account information
#
#MAIL_GUN_DOMAIN=mg.yourdomain.com
#MAIL_GUN_API=https://api.mailgun.net/v3/mg.yourdomain.com/messages
#MAIL_GUN_USER=api:key-123abcdefghijklmnopqrstuvwxyz123
#MAIL_FROM_LABEL='DeFiChain Masternode'
#EMAIL=you@emaildomain.com

DEBUG_LOG_PATH="./.defi/debug.log"

# Set this to true if you want this script to try and fix chain splits detected automatically
FIX_SPLIT_AUTOMATICALLY=false

# If your server is this number of blocks behind remote API node, you will be notified that your server is out of sync
OUT_OF_SYNC_THRESHOLD=2

# To fix chain splits, these nodes are added at final step of instructions sent to admin
NODE1="185.244.194.174:8555"
NODE2="45.157.177.82:8555"

# Set these to blank if you don't like emojis in your notifications
REWARD_EMOJI="$(printf '\xF0\x9F\xA5\xB3 \xF0\x9F\x8E\x89')"
BAD_NEWS_EMOJI="$(printf '\xF0\x9F\x98\x9F')"
THUMBS_UP_EMOJI="$(printf '\xF0\x9F\x91\x8D')"
GREEN_CHECK_EMOJI="$(printf '\xE2\x9C\x85')"
RED_X_EMOJI="$(printf '\xE2\x9D\x8C')"

# If log file is larger than this (in bytes), alert admin
LOG_FILE_SIZE_THRESHOLD=20000000


######################################################################
# Alert master-node admin via stdout and email if mail gun configured
# Globals:
#   MAIL_GUN_API
#   MAIL_GUN_USER
#   MAIL_GUN_DOMAIN
#   EMAIL
# Arguments:
#   Email subject, Email text
######################################################################
notify () {

  if [[ -v MAIL_GUN_DOMAIN && -v MAIL_GUN_USER && -v MAIL_GUN_API && -v EMAIL ]]; then
    curl -s --user "${MAIL_GUN_USER}" "${MAIL_GUN_API}" -F from="${MAIL_FROM_LABEL} mailgun@${MAIL_GUN_DOMAIN}" -F to="${EMAIL}" -F subject="${1}" -F text="${2}" > /dev/null
  fi

  # If not using mailgun, replace this with whatever SMTP or other notification solution you wish to use.  Arguments $1
  # and $2 contain email subject and message respectively.

  echo ""
  echo "${1}"
  echo ""
  echo "${2}"
  echo ""

}

##################################################################
# Used to append proper ordinal to number.  e.g. 1st 3rd 4th etc
# Arguments:
#   Number
# Output:
#   String ordinal for parameter
##################################################################
ordinal () {
  case "$1" in
    *1[0-9] | *[04-9]) echo "$1"th;;
    *1) echo "$1"st;;
    *2) echo "$1"nd;;
    *3) echo "$1"rd;;
  esac
}


##########################################
# Check if server is running and in sync
##########################################

BLOCK_HEIGHT=$(./.defi/defi-cli getblockcount)
MAIN_NET_BLOCK_HEIGHT=$(/usr/bin/curl -s https://api.defichain.io/v1/getblockcount | /usr/bin/jq -r '.data')
let "BLOCK_DIFF = $MAIN_NET_BLOCK_HEIGHT - $BLOCK_HEIGHT"

if [[ ${BLOCK_DIFF} -gt ${OUT_OF_SYNC_THRESHOLD} ]]; then
  SUBJECT="Uh-oh!! Your Master Node Is Out Of Sync! $BAD_NEWS_EMOJI"
  MESSAGE=$(printf "Your master node block height is ${BLOCK_HEIGHT} but the main net is ${BLOCK_DIFF} blocks ahead (${MAIN_NET_BLOCK_HEIGHT}).\n\nNote you can adjust sensitivity of this warning by changing OUT_OF_SYNC_THRESHOLD (currently set to '${OUT_OF_SYNC_THRESHOLD}') in checkserver.sh")
  notify "${SUBJECT}" "${MESSAGE}"
fi


#########################
# Check for chain split
#########################

if [[ ${BLOCK_HEIGHT} -gt ${MAIN_NET_BLOCK_HEIGHT} ]]; then
  ADJUSTED_BLOCK_HEIGHT=${MAIN_NET_BLOCK_HEIGHT}
else
  ADJUSTED_BLOCK_HEIGHT=${BLOCK_HEIGHT}
fi

LOCAL_HASH=$(./.defi/defi-cli getblockhash ${ADJUSTED_BLOCK_HEIGHT})
MAIN_NET_HASH=$(/usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${ADJUSTED_BLOCK_HEIGHT} | /usr/bin/jq -r '.hash')

if [[ ${LOCAL_HASH} != ${MAIN_NET_HASH} ]]; then

  if [[ -f ${DEBUG_LOG_PATH} ]]; then

    if [[ $(tail -n 20 ${DEBUG_LOG_PATH} | grep -m 1 "proof of stake failed") ]]; then

      SUBJECT="Uh-oh!! Local Master Node Chain Split Detected!!! $BAD_NEWS_EMOJI"
      MESSAGE=$(printf "DeFiChain Split detected before block height ${ADJUSTED_BLOCK_HEIGHT}\n\nLocal hash: ${LOCAL_HASH}\nMainnet hash: ${MAIN_NET_HASH}\n\nSee https://explorer.defichain.com/#/DFI/mainnet/block/${MAIN_NET_HASH}.\n\nTo fix:\n 1: Find block where split occurred in ~/.defi/debug.log by comparing block hashes in explorer (using link above).\n 2: defi-cli invalidateblock <incorrect block hash>\n 3: defi-cli reconsiderblock <correct block hash from explorer>\n 4: defi-cli addnode '${NODE1}' add\n 5: defi-cli addnode '${NODE2}' add\n\nNote that an attempt to find the split block was attempted and failed.  You can help improve this script by notifying huwilerm@champlain.edu and sending him your debug.log.")


      #########################################
      # Local chain split detected.  Find it.
      #########################################

      IFS=$'\n'
      LINES=( $(tac ${DEBUG_LOG_PATH} | grep UpdateTip | head -50000 | tac) )
      UPDATE_TIP_LOG_REGEX="best=([0-9a-f]+)[[:space:]]height=([0-9]+)"

      if [[ ${LINES[1]} =~ $UPDATE_TIP_LOG_REGEX ]]; then
        RANGE_MIN=${BASH_REMATCH[2]}
      fi

      if [[ ${LINES[-1]} =~ $UPDATE_TIP_LOG_REGEX ]]; then
        RANGE_MAX=${BASH_REMATCH[2]}
      fi

      while [[ "${RANGE_MIN}" -le "${RANGE_MAX}" ]]; do

        let "MID = ($RANGE_MIN + $RANGE_MAX) >> 1"

        HEIGHT=${MID}

        LOCAL_HASH=$(./.defi/defi-cli getblockhash ${HEIGHT})
        MAIN_NET_HASH=$(/usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${HEIGHT} | /usr/bin/jq -r '.hash')

        if [[ ${LOCAL_HASH} != ${MAIN_NET_HASH} ]]; then

          let "HEIGHT_MINUS_ONE = $HEIGHT - 1"

          PREVIOUS_LOCAL_HASH=$(./.defi/defi-cli getblockhash ${HEIGHT_MINUS_ONE})
          PREVIOUS_MAIN_NET_HASH=$(/usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${HEIGHT_MINUS_ONE} | /usr/bin/jq -r '.hash')

          if [[ ${PREVIOUS_LOCAL_HASH} = ${PREVIOUS_MAIN_NET_HASH} ]]; then
            COMMANDS_TO_FIX="./.defi/defi-cli invalidateblock ${LOCAL_HASH} && ./.defi/defi-cli reconsiderblock ${MAIN_NET_HASH} && ./.defi/defi-cli addnode '${NODE1}' add && ./.defi/defi-cli addnode '${NODE2}' add"
            MESSAGE=$(printf "DeFiChain Split detected at block ${HEIGHT}:\n\n----- technical information -----\n$ ./.defi/defi-cli getblockhash ${HEIGHT_MINUS_ONE}\n${PREVIOUS_LOCAL_HASH}\n$ /usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${HEIGHT_MINUS_ONE} | /usr/bin/jq -r '.hash'\n${PREVIOUS_MAIN_NET_HASH}\n${GREEN_CHECK_EMOJI} Local and main-net hash match on block ${HEIGHT_MINUS_ONE}\n\n$ ./.defi/defi-cli getblockhash ${HEIGHT}\n${LOCAL_HASH}\n$ /usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${HEIGHT} | /usr/bin/jq -r '.hash'\n${MAIN_NET_HASH}\n${RED_X_EMOJI} Local and main-net hash don't match on block ${HEIGHT}\n----- end technical information -----\n")
            if [[ $FIX_SPLIT_AUTOMATICALLY = true ]]; then
              MESSAGE=$(printf "${MESSAGE}\n\nIn order to move your node back onto the main chain, the following command will be executed automatically:\n\n$ ${COMMANDS_TO_FIX}\n\nTo avoid having this script do this automatically, set FIX_SPLIT_AUTOMATICALLY=false")
              OUTPUT=$(./.defi/defi-cli invalidateblock ${LOCAL_HASH} && ./.defi/defi-cli reconsiderblock ${MAIN_NET_HASH} && ./.defi/defi-cli addnode '${NODE1}' add && ./.defi/defi-cli addnode '${NODE2}' add)
            else
              MESSAGE=$(printf "${MESSAGE}\n\nIn order to move your node back onto the main chain, the following command should be executed:\n\n$ ${COMMANDS_TO_FIX}\n\nTo have this do this automatically for you, set FIX_SPLIT_AUTOMATICALLY=true")
            fi
            break

          else
            let "RANGE_MAX = $MID - 1"
            continue
          fi
        fi

        let "RANGE_MIN = $MID + 1"
        continue

      done

      notify "${SUBJECT}" "${MESSAGE}"
      exit 1

    else

      SUBJECT="Remote Master Node Chain Split Detected!"
      MAIN_NET_ERROR=$(/usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${ADJUSTED_BLOCK_HEIGHT})
      MESSAGE=$(printf "Chain split detected on remote Defichain wallet node!  Please let admins know at https://t.me/DeFiMasternodes.\n\nProof: \n\n./.defi/defi-cli getblockhash ${ADJUSTED_BLOCK_HEIGHT}\n$LOCAL_HASH\n/usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${ADJUSTED_BLOCK_HEIGHT}\n$MAIN_NET_ERROR")
      notify "${SUBJECT}" "${MESSAGE}"

    fi

  else

    SUBJECT="Uh-oh!! **Possible** Local Master Node Chain Split Detected!!! $BAD_NEWS_EMOJI"
    MESSAGE=$(printf "DeFiChain Split detected before block height ${ADJUSTED_BLOCK_HEIGHT}\n\nNote that this script could not find debug.log to verify whether or not this split occurred locally or on the remote node.\n\nLocal hash: ${LOCAL_HASH}\nMainnet hash: ${MAIN_NET_HASH}\n\nSee https://explorer.defichain.com/#/DFI/mainnet/block/${MAIN_NET_HASH}.\n\nTo fix:\n 1: Find block where split occurred in ~/.defi/debug.log by comparing block hashes in explorer (using link above).\n 2: defi-cli invalidateblock <incorrect block hash>\n 3: defi-cli reconsiderblock <correct block hash from explorer>\n 4: defi-cli addnode '${NODE1}' add\n 5: defi-cli addnode '${NODE2}' add")
    notify "${SUBJECT}" "${MESSAGE}"
    exit 1

  fi

fi


########################
# Check debug log size
########################

if [[ -f ${DEBUG_LOG_PATH} ]]; then
  DEBUG_SIZE=$(stat -c %s ${DEBUG_LOG_PATH})
  if [[ ${DEBUG_SIZE} -gt ${LOG_FILE_SIZE_THRESHOLD} ]]; then
    SUBJECT="Uh Oh, DeFiChain's debug.log Is Too Large ${BAD_NEWS_EMOJI}"
    MESSAGE=$(printf "DeFiChain's ${DEBUG_LOG_PATH} is larger than threshold set in configuration. LOG_FILE_SIZE_THRESHOLD=${LOG_FILE_SIZE_THRESHOLD} bytes. ${DEBUG_LOG_PATH} size is ${DEBUG_SIZE}. Consider configuring logrotate to avoid having the file size grow too large.")
    notify "${SUBJECT}" "${MESSAGE}"
  fi
fi


#####################
# Check for rewards
#####################

MINTED_BLOCKS=$(./.defi/defi-cli getmintinginfo | jq -r '.mintedblocks')
MINTED_BLOCKS_FILE='./.minted_blocks'

if [[ -f "${MINTED_BLOCKS_FILE}" ]]; then
  PREVIOUS_MINTED_BLOCKS="$(<${MINTED_BLOCKS_FILE})"
  if [[ ${MINTED_BLOCKS} > ${PREVIOUS_MINTED_BLOCKS} ]]; then
    SUBJECT="Woo-hoo!! Master Node Rewards Incoming! $REWARD_EMOJI"
    MESSAGE=$(printf "Your master node just earned its $(ordinal ${MINTED_BLOCKS}) DeFiChain Reward!")
    notify "${SUBJECT}" "${MESSAGE}"
  fi
fi

echo "${MINTED_BLOCKS}" > ${MINTED_BLOCKS_FILE}

echo "Your master node is running perfectly $THUMBS_UP_EMOJI"
echo ""

exit 0
