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

# When a chain split is detected, how far back (# of blocks) should checkserver.sh look?
SPLIT_SEARCH_DISTANCE=40000

# Append "block/<height>" to this API call in order to get corresponding hash.  This is used throughout the script to
# compare local and remote hashes in order to check the health of your node.  These endpoints were provided by @p3root
# in the DeFiChain Masternodes International telegram group (https://t.me/DeFiMasternodes on 5/28/2021).
MAIN_NET_ENDPOINTS=(
  "https://api.az-prod-0.saiive.live/api/v1/mainnet/DFI/"
  "https://api.scw-prod-0.saiive.live/api/v1/mainnet/DFI/"
)


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
# Used to turn an array into a single delimited string
# Arguments:
#   String delimiter
#   Array
# Output:
#   String with all Array elements delimited
##################################################################
join_arr () {
  local IFS="$1"
  shift
  echo "$*"
}


######################################################################################
# Used to grab random MAIN_NET_ENDPOINT and ensure its validity.  If called twice, the
# first server returned will be invalidated and replaced with another registered server.
# Globals MAIN_NET_BLOCK_HEIGHT and MAIN_NET_ENDPOINT are set.  If MAIN_NET_ENDPOINT
# is unset, this indicates there was a problem finding a valid remote server
# Arguments:
#   None
# Output:
#   Sets MAIN_NET_BLOCK_HEIGHT and MAIN_NET_ENDPOINT globals
######################################################################################
INVALID_ENDPOINTS=()
INVALID_ENDPOINT_ERROR_MESSAGES=()
BLOCK_HEIGHT=$(./.defi/defi-cli getblockcount)
MAIN_NET_ENDPOINTS_JOINED=$(join_arr "," "${MAIN_NET_ENDPOINTS[@]}")
MAIN_NET_ENDPOINTS_JOINED="${MAIN_NET_ENDPOINTS_JOINED//,/block\/tip, }block/tip"

get_remote_server () {

  if [[ -v MAIN_NET_ENDPOINT ]]; then
    INVALID_ENDPOINTS+=(${MAIN_NET_ENDPOINT})
    unset MAIN_NET_ENDPOINT
  fi

  # randomize server endpoint order
  MAIN_NET_ENDPOINTS=( $(shuf -e "${MAIN_NET_ENDPOINTS[@]}") )

  # iterate all registered api endpoints and ensure they are valid
  for MAIN_NET_ENDPOINT in "${MAIN_NET_ENDPOINTS[@]}"; do

    # has endpoint already been flagged invalid?
    IN_INVALID_ARRAY=$(echo "${INVALID_ENDPOINTS[@]}" | grep -o "${MAIN_NET_ENDPOINT}" | wc -w)
    if [[ ${IN_INVALID_ARRAY} -ne "0" ]]; then
      unset MAIN_NET_ENDPOINT
      continue
    fi

    MAIN_NET_SERVER_TIP=$(/usr/bin/curl -s "${MAIN_NET_ENDPOINT}block/tip")
    if [[ -v MAIN_NET_BLOCK_HEIGHT ]]; then
      PREVIOUS_MAIN_NET_BLOCK_HEIGHT=MAIN_NET_BLOCK_HEIGHT
    fi

    # does the server return a valid response when querying for block height?
    MAIN_NET_BLOCK_HEIGHT=$(echo "${MAIN_NET_SERVER_TIP}" | /usr/bin/jq -r '.height')
    if [[ ! "${MAIN_NET_BLOCK_HEIGHT}" =~ ^[0-9]{6,10}$ ]]; then
      echo "WARNING: Invalid response received from ${MAIN_NET_ENDPOINT}block/tip:"
      echo "${MAIN_NET_SERVER_TIP}"
      INVALID_ENDPOINTS+=(${MAIN_NET_ENDPOINT})
      INVALID_ENDPOINT_ERROR_MESSAGES+=("${MAIN_NET_ENDPOINT}block/tip: Returning invalid API response: ${MAIN_NET_SERVER_TIP}")
      unset MAIN_NET_ENDPOINT
      continue
    fi

    return

  done

  unset MAIN_NET_ENDPOINT

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


##################################
# Check if server is out of sync
##################################

get_remote_server

SLOW_REMOTE_BLOCK_HEIGHTS=()
while true; do

  if [[ -v MAIN_NET_ENDPOINT ]]; then
    let "BLOCK_DIFF = $MAIN_NET_BLOCK_HEIGHT - $BLOCK_HEIGHT"
    BLOCK_DIFF=${BLOCK_DIFF#-}
    if [[ ${BLOCK_DIFF} -gt ${OUT_OF_SYNC_THRESHOLD} ]]; then
      if [[ ${BLOCK_HEIGHT} -gt ${MAIN_NET_BLOCK_HEIGHT} ]]; then
        echo "WARNING: Remote node ${MAIN_NET_ENDPOINT} is ${BLOCK_DIFF} blocks behind local node."
        SLOW_REMOTE_BLOCK_HEIGHTS+=(${BLOCK_HEIGHT})
        INVALID_ENDPOINT_ERROR_MESSAGES+=("${MAIN_NET_ENDPOINT}block/tip: Block height is ${MAIN_NET_BLOCK_HEIGHT}.  This is ${BLOCK_DIFF} blocks behind your node, which has a block height of ${BLOCK_HEIGHT}.  To adjust sensitivity of OUT_OF_SYNC_THRESHOLD, set in checkserver.sh.  It's currently set to '${OUT_OF_SYNC_THRESHOLD}'")
        get_remote_server
        continue
      fi
      SUBJECT="Uh-oh!! Your Master Node Is Out Of Sync! $BAD_NEWS_EMOJI"
      MESSAGE=$(printf "Your master node block height is ${BLOCK_HEIGHT}, which is ${BLOCK_DIFF} blocks behind remote node ${MAIN_NET_ENDPOINT}.\n\nNote you can adjust sensitivity of this warning by changing OUT_OF_SYNC_THRESHOLD (currently set to '${OUT_OF_SYNC_THRESHOLD}') in checkserver.sh")
      notify "${SUBJECT}" "${MESSAGE}"
      break
    fi

    # yay! we're all in sync.
    break

  else
    INVALID_ENDPOINT_ERROR_MESSAGES_JOINED=$(join_arr ";" "${INVALID_ENDPOINT_ERROR_MESSAGES[@]}")
    INVALID_ENDPOINT_ERROR_MESSAGES_JOINED="${INVALID_ENDPOINT_ERROR_MESSAGES_JOINED//;/; }"
    SUBJECT="Uh-oh!! All remote nodes are invalid!"
    MESSAGE=$(printf "All remote nodes used to perform diagnostic checks against your node appear to be having issues: ${INVALID_ENDPOINT_ERROR_MESSAGES_JOINED}.  If this problem persists, please let folks at https://t.me/DeFiMasternodes know.")
    notify "${SUBJECT}" "${MESSAGE}"
    echo "WARNING: All registered (${MAIN_NET_ENDPOINTS_JOINED}) nodes are out of sync."
    exit 1
  fi

done


###############################
# Check for remote chain split
###############################

while true; do

  if [[ ${BLOCK_HEIGHT} -gt ${MAIN_NET_BLOCK_HEIGHT} ]]; then
    ADJUSTED_BLOCK_HEIGHT=${MAIN_NET_BLOCK_HEIGHT}
  else
    ADJUSTED_BLOCK_HEIGHT=${BLOCK_HEIGHT}
  fi

  LOCAL_HASH=$(./.defi/defi-cli getblockhash ${ADJUSTED_BLOCK_HEIGHT})
  MAIN_NET_HASH=$(/usr/bin/curl -s "${MAIN_NET_ENDPOINT}block/${ADJUSTED_BLOCK_HEIGHT}" | /usr/bin/jq -r '.hash')

  if [[ ${LOCAL_HASH} != ${MAIN_NET_HASH} ]]; then
    if [[ -f ${DEBUG_LOG_PATH} ]]; then
      if [[ ! $(tail -n 20 ${DEBUG_LOG_PATH} | grep -m 1 "proof of stake failed") ]]; then
        echo "WARNING: possible remote split detected at ${MAIN_NET_ENDPOINT}block/${ADJUSTED_BLOCK_HEIGHT}."
        INVALID_ENDPOINT_ERROR_MESSAGES+=("${MAIN_NET_ENDPOINT}block/${ADJUSTED_BLOCK_HEIGHT}: Possible remote split detected.  Local hash (${LOCAL_HASH}) and remote hash (${MAIN_NET_HASH}) do not match at height ${ADJUSTED_BLOCK_HEIGHT} and analysis of local debug.log doesn't seem to indicate a local split.")
        get_remote_server
        continue
      fi
    fi
  fi

  break

done


###############################
# Check for local chain split
###############################

if [[ ${LOCAL_HASH} != ${MAIN_NET_HASH} ]]; then

  if [[ -f ${DEBUG_LOG_PATH} ]]; then

    if [[ -v MAIN_NET_ENDPOINT ]]; then

      SUBJECT="Uh-oh!! Local Master Node Chain Split Detected!!! $BAD_NEWS_EMOJI"
      MESSAGE=$(printf "DeFiChain Split detected before block height ${ADJUSTED_BLOCK_HEIGHT}\n\nLocal hash: ${LOCAL_HASH}\nMainnet hash: ${MAIN_NET_HASH}\n\nSee https://explorer.defichain.com/#/DFI/mainnet/block/${MAIN_NET_HASH}.\n\nTo fix:\n 1: Find block where split occurred in ~/.defi/debug.log by comparing block hashes in explorer (using link above).\n 2: defi-cli invalidateblock <incorrect block hash>\n 3: defi-cli reconsiderblock <correct block hash from explorer>\n 4: defi-cli addnode ${NODE1} add\n 5: defi-cli addnode ${NODE2} add\n\nNote that an attempt to find the split block was attempted and failed.")


      #########################################
      # Local chain split detected.  Find it.
      #########################################

      RANGE_MAX=${BLOCK_HEIGHT}
      let "RANGE_MIN = $RANGE_MAX - $SPLIT_SEARCH_DISTANCE"

      while [[ "${RANGE_MIN}" -le "${RANGE_MAX}" ]]; do

        let "MID = ($RANGE_MIN + $RANGE_MAX) >> 1"

        HEIGHT=${MID}

        LOCAL_HASH=$(./.defi/defi-cli getblockhash ${HEIGHT})
        MAIN_NET_HASH=$(/usr/bin/curl -s "${MAIN_NET_ENDPOINT}block/${HEIGHT}" | /usr/bin/jq -r '.hash')

        if [[ ${LOCAL_HASH} != ${MAIN_NET_HASH} ]]; then

          let "HEIGHT_MINUS_ONE = $HEIGHT - 1"

          PREVIOUS_LOCAL_HASH=$(./.defi/defi-cli getblockhash ${HEIGHT_MINUS_ONE})
          PREVIOUS_MAIN_NET_HASH=$(/usr/bin/curl -s "${MAIN_NET_ENDPOINT}block/${HEIGHT_MINUS_ONE}" | /usr/bin/jq -r '.hash')

          if [[ ${PREVIOUS_LOCAL_HASH} = ${PREVIOUS_MAIN_NET_HASH} ]]; then

            ERROR_MESSAGE=""
            if [[ ${MAIN_NET_HASH} = "null" ]]; then
              MAIN_NET_HASH="<get this from https://chainz.cryptoid.info/dfi/block.dws?${HEIGHT}.htm>"
              FIX_SPLIT_AUTOMATICALLY=false
              ERROR_MESSAGE="\n\n* You need to look the block hash at height ${HEIGHT} manually due to error on remote node and replace ${MAIN_NET_HASH} with that value."
            fi

            COMMANDS_TO_FIX=$(printf "./.defi/defi-cli invalidateblock ${LOCAL_HASH}\n./.defi/defi-cli reconsiderblock ${MAIN_NET_HASH}\n./.defi/defi-cli addnode ${NODE1} add\n./.defi/defi-cli addnode ${NODE2} add")
            MESSAGE=$(printf "DeFiChain Split detected at block ${HEIGHT}:\n\n----- technical information -----\n$ ./.defi/defi-cli getblockhash ${HEIGHT_MINUS_ONE}\n${PREVIOUS_LOCAL_HASH}\n$ /usr/bin/curl -s ${MAIN_NET_ENDPOINT}block/${HEIGHT_MINUS_ONE} | /usr/bin/jq -r '.hash'\n${PREVIOUS_MAIN_NET_HASH}\n${GREEN_CHECK_EMOJI} Local and main-net hash match on block ${HEIGHT_MINUS_ONE}\n\n$ ./.defi/defi-cli getblockhash ${HEIGHT}\n${LOCAL_HASH}\n$ /usr/bin/curl -s ${MAIN_NET_ENDPOINT}block/${HEIGHT} | /usr/bin/jq -r '.hash'\n${MAIN_NET_HASH}\n${RED_X_EMOJI} Local and main-net hash don't match on block ${HEIGHT}\n----- end technical information -----\n")
            if [[ $FIX_SPLIT_AUTOMATICALLY = true ]]; then
              MESSAGE=$(printf "${MESSAGE}\n\nIn order to move your node back onto the main chain, the following command will be executed automatically:\n\n$ ${COMMANDS_TO_FIX}\n\nTo avoid having this script do this automatically, set FIX_SPLIT_AUTOMATICALLY=false")
              OUTPUT=$(./.defi/defi-cli invalidateblock ${LOCAL_HASH} && ./.defi/defi-cli reconsiderblock ${MAIN_NET_HASH} && ./.defi/defi-cli addnode ${NODE1} add && ./.defi/defi-cli addnode ${NODE2} add)
            else
              MESSAGE=$(printf "${MESSAGE}\n\nIn order to move your node back onto the main chain, the following command should be executed:\n\n$ ${COMMANDS_TO_FIX}")
            fi

            MESSAGE=$(printf "${MESSAGE}${ERROR_MESSAGE}")

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

      INVALID_ENDPOINT_ERROR_MESSAGES_JOINED=$(join_arr ";" "${INVALID_ENDPOINT_ERROR_MESSAGES[@]}")
      INVALID_ENDPOINT_ERROR_MESSAGES_JOINED="${INVALID_ENDPOINT_ERROR_MESSAGES_JOINED//;/; }"
      SUBJECT="Uh-oh!! Local Master Node Chain Split Detected!!! $BAD_NEWS_EMOJI"
      MESSAGE=$(printf "DeFiChain Split detected before block height ${ADJUSTED_BLOCK_HEIGHT}\n\nNote that this script exhaustively checked against all registered remote nodes, but due to the following problems detected, each were invalidated: ${INVALID_ENDPOINT_ERROR_MESSAGES_JOINED}.  Because of these problems, checkserver.sh was not able to automatically verify and find the split for you.\n\nLocal hash: ${LOCAL_HASH}\nMainnet hash: ${MAIN_NET_HASH}\n\nSee https://explorer.defichain.com/#/DFI/mainnet/block/${MAIN_NET_HASH}.\n\nTo fix:\n 1: Find block where split occurred in ~/.defi/debug.log by comparing block hashes in explorer (using link above).\n 2: defi-cli invalidateblock <incorrect block hash>\n 3: defi-cli reconsiderblock <correct block hash from explorer>\n 4: defi-cli addnode ${NODE1} add\n 5: defi-cli addnode ${NODE2} add")
      notify "${SUBJECT}" "${MESSAGE}"
      exit 1

    fi

  else

    SUBJECT="Uh-oh!! **Possible** Local Master Node Chain Split Detected!!! $BAD_NEWS_EMOJI"
    MESSAGE=$(printf "DeFiChain Split detected before block height ${ADJUSTED_BLOCK_HEIGHT}\n\nNote that this script could not find debug.log to verify whether or not this split occurred locally or on the remote node.\n\nLocal hash: ${LOCAL_HASH}\nMainnet hash: ${MAIN_NET_HASH}\n\nSee https://explorer.defichain.com/#/DFI/mainnet/block/${MAIN_NET_HASH}.\n\nTo fix:\n 1: Find block where split occurred in ~/.defi/debug.log by comparing block hashes in explorer (using link above).\n 2: defi-cli invalidateblock <incorrect block hash>\n 3: defi-cli reconsiderblock <correct block hash from explorer>\n 4: defi-cli addnode ${NODE1} add\n 5: defi-cli addnode ${NODE2} add")
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
