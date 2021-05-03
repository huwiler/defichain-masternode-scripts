#!/usr/bin/env bash

# README
# ------
# Before this script will work, you must:
#  - ensure curl and jq are installed in /usr/bin/
#  - run from the home directory that contains the .defi folder as that user
#  - if you want the script to send you email, uncomment and edit the config information below OR replace mailgun
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
#EMAIL=you@emaildomain.com

DEBUG_LOG_PATH="./.defi/debug.log"

# If your server is this number of blocks behind remote API node, you will be notified that your server is out of sync.
OUT_OF_SYNC_THRESHOLD=2

# To fix chain splits, these nodes are added at final step of instructions sent to admin
NODE1="185.244.194.174:8555"
NODE2="45.157.177.82:8555"

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
    curl -s --user "${MAIL_GUN_USER}" "${MAIL_GUN_API}" -F from="DEFICHAIN MASTERNODE mailgun@${MAIL_GUN_DOMAIN}" -F to="${EMAIL}" -F subject="${1}" -F text="${2}"
  fi

  # If not using mailgun, replace this with whatever SMTP or other notification solution you wish to use.  Arguments $1
  # and $2 contain email subject and message respectively.

  echo "${1}"
  echo "${2}"

}

##################################################################
# Used to append proper ordinal to number.  E.g. 1st 3rd 4th etc
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
  SUBJECT="Uh-oh!! Your Master Node Is Out Of Sync!"
  MESSAGE=$(printf "Your master node block height is ${BLOCK_HEIGHT} but the main net is ${BLOCK_DIFF} blocks ahead (${MAIN_NET_BLOCK_HEIGHT}).\n\nNote you can adjust sensitivity of this warning by changing OUT_OF_SYNC_THRESHOLD (currently set to '${OUT_OF_SYNC_THRESHOLD}') in checkserver.sh")
  notify "${SUBJECT}" "${MESSAGE}"
fi


#########################
# Check for chain split
#########################

let "ADJUSTED_BLOCK_HEIGHT = $BLOCK_HEIGHT - 2"
LOCAL_HASH=$(./.defi/defi-cli getblockhash ${ADJUSTED_BLOCK_HEIGHT})
MAIN_NET_HASH=$(/usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${ADJUSTED_BLOCK_HEIGHT} | /usr/bin/jq -r '.hash')

if [[ ${LOCAL_HASH} != ${MAIN_NET_HASH} ]]; then

  if [[ -f ${DEBUG_LOG_PATH} ]]; then

    if [[ $(tail -n 10 ${DEBUG_LOG_PATH} | grep -m 1 "proof of stake failed") ]]; then

      SUBJECT="Uh-oh!! Local Master Node Chain Split Detected!!!"
      MESSAGE=$(printf "DeFiChain Split detected before block height ${ADJUSTED_BLOCK_HEIGHT}\n\nLocal hash: ${LOCAL_HASH}\nMainnet hash: ${MAIN_NET_HASH}\n\nSee https://explorer.defichain.com/#/DFI/mainnet/block/${MAIN_NET_HASH}.\n\nTo fix:\n 1: Find block where split occurred in ~/.defi/debug.log by comparing block hashes in explorer (using link above).\n 2: defi-cli invalidateblock <incorrect block hash>\n 3: defi-cli reconsiderblock <correct block hash from explorer>\n 4: defi-cli addnode '${NODE1}' add\n 5: defi-cli addnode '${NODE2}' add\n\nNote that an attempt to find the split block was attempted and failed.  You can help improve this script by notifying huwilerm@champlain.edu and sending him your debug.log.")

      # Attempt to find block where split occurred and supply admin with exact code required to fix
      #
      # Explanation:
      #
      # When split occurs, "proof of stake" errors will emit in the debug log starting right after the incorrect block
      # like this:
      #
      # 2021-04-27T06:31:25Z UpdateTip: new best=520903fa2a984fa5aa4af92f9bdeaffa3a1a4aa7a8a17d8260d3ca07d174931f height=808493 version=0x20000000 log2_work=80.765327 tx=2530112 date='2021-04-27T06:31:24Z' progress=1.000000 cache=0.4MiB(2084txo)
      # 2021-04-27T06:31:25Z ERROR: ProcessNewBlock: AcceptBlock FAILED (high-hash, proof of stake failed (code 16))
      #
      # This code attempts to find these lines in the debug log, verifies the split block has incorrect hash, and then
      # verifies that the block before it has the correct hash.  Exact code to verify and fix is then sent to admin.

      DEBUG_LOG_LINE_OF_SPLIT=$(tac ${DEBUG_LOG_PATH} | grep -m 1 UpdateTip)
      DEBUG_LOG_REGEX="best=([0-9a-f]+)[[:space:]]height=([0-9]+)"
      if [[ ${DEBUG_LOG_LINE_OF_SPLIT} =~ $DEBUG_LOG_REGEX ]]; then
        SPLIT_HASH=${BASH_REMATCH[1]}
        SPLIT_HEIGHT=${BASH_REMATCH[2]}
        MAIN_NET_SPLIT_HASH=$(/usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${SPLIT_HEIGHT} | /usr/bin/jq -r '.hash')
        if [[ ${SPLIT_HASH} != ${MAIN_NET_SPLIT_HASH} ]]; then
          let "ONE_BEFORE_SPLIT_HEIGHT = $SPLIT_HEIGHT - 1"
          ONE_BEFORE_SPLIT_HASH=$(./.defi/defi-cli getblockhash ${ONE_BEFORE_SPLIT_HEIGHT})
          MAIN_NET_ONE_BEFORE_SPLIT_HASH=$(/usr/bin/curl -s https://staging-supernode.defichain-wallet.com/api/v1/mainnet/DFI/block/${ONE_BEFORE_SPLIT_HEIGHT} | /usr/bin/jq -r '.hash')
          if [[ ${ONE_BEFORE_SPLIT_HASH} = ${MAIN_NET_ONE_BEFORE_SPLIT_HASH} ]]; then
            MESSAGE=$(printf "DeFiChain Split detected at block ${SPLIT_HEIGHT}.\n\nVerify using ...\n\n./.defi/defi-cli getblockhash ${ONE_BEFORE_SPLIT_HEIGHT}\n./.defi/defi-cli getblockhash ${SPLIT_HEIGHT}\n\n... and comparing with ...\n\nhttps://explorer.defichain.com/#/DFI/mainnet/block/${ONE_BEFORE_SPLIT_HASH}\nhttps://explorer.defichain.com/#/DFI/mainnet/block/${SPLIT_HASH}\n\nTo fix:\n\n 1: defi-cli invalidateblock ${SPLIT_HASH}\n 2: defi-cli reconsiderblock ${MAIN_NET_SPLIT_HASH}\n 3: defi-cli addnode '${NODE1}' add\n 4: defi-cli addnode '${NODE2}' add")
          fi
        fi
      fi

      notify "${SUBJECT}" "${MESSAGE}"
      exit 1

    else

      SUBJECT="Remote Master Node Chain Split Detected!"
      MESSAGE=$(printf "Chain split detected on remote Defichain wallet node!  Please let admins know at https://t.me/DeFiMasternodes.")
      notify "${SUBJECT}" "${MESSAGE}"

    fi

  else

    SUBJECT="Uh-oh!! **Possible** Local Master Node Chain Split Detected!!!"
    MESSAGE=$(printf "DeFiChain Split detected before block height ${ADJUSTED_BLOCK_HEIGHT}\n\nNote that this script could not find debug.log to verify whether or not this split occurred locally or on the remote node.\n\nLocal hash: ${LOCAL_HASH}\nMainnet hash: ${MAIN_NET_HASH}\n\nSee https://explorer.defichain.com/#/DFI/mainnet/block/${MAIN_NET_HASH}.\n\nTo fix:\n 1: Find block where split occurred in ~/.defi/debug.log by comparing block hashes in explorer (using link above).\n 2: defi-cli invalidateblock <incorrect block hash>\n 3: defi-cli reconsiderblock <correct block hash from explorer>\n 4: defi-cli addnode '${NODE1}' add\n 5: defi-cli addnode '${NODE2}' add")
    notify "${SUBJECT}" "${MESSAGE}"
    exit 1

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
    SUBJECT="Woo-hoo!! Master Node Rewards Incoming!"
    MESSAGE=$(printf "Your master node just earned its $(ordinal ${MINTED_BLOCKS}) DeFiChain Reward!")
    notify "${SUBJECT}" "${MESSAGE}"
  fi
fi

echo "${MINTED_BLOCKS}" > ${MINTED_BLOCKS_FILE}

echo ""
echo "Your master node is running perfectly :-)"
echo ""

exit 0
