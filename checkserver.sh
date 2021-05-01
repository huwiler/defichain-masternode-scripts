#!/usr/bin/env bash

# README
# ------
# Before this script will work, you must:
#  - ensure curl and jq are installed in /usr/bin/
#  - edit the config information below OR replace mailgun related code with local SMTP or a alternative mailer service

# CONFIG
# ------
#
# If using mailgun, uncomment the following lines and replace with your account information
#
#MAIL_GUN_DOMAIN=mg.yourdomain.com
#MAIL_GUN_API=https://api.mailgun.net/v3/mg.yourdomain.com/messages
#MAIL_GUN_USER=api:key-123abcdefghijklmnopqrstuvwxyz123
#EMAIL=you@emaildomain.com

####################################
# Alert master-node admin via email
# Globals:
#   MAIL_GUN_API
#   MAIL_GUN_USER
#   MAIL_GUN_DOMAIN
#   EMAIL
# Arguments:
#   Email subject, Email text
####################################
email_admin () {

  # If not using mailgun, replace this with whatever SMTP or other notification solution you wish to use.  Arguments $1
  # and $2 contain email subject and message respectively.

  curl -s --user "${MAIL_GUN_USER}" "${MAIL_GUN_API}" -F from="DEFICHAIN MASTERNODE mailgun@${MAIL_GUN_DOMAIN}" -F to="${EMAIL}" -F subject="${1}" -F text="${2}"
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
BLOCK_DIFF=$((MAIN_NET_BLOCK_HEIGHT - BLOCK_HEIGHT))

if [[ ${BLOCK_DIFF} -gt 1 ]]; then
  SUBJECT="Uh-oh!! Your Master Node Is Out Of Sync!"
  MESSAGE=$(printf "Your master node block height is ${BLOCK_HEIGHT} but the main net is ${BLOCK_DIFF} blocks ahead (${MAIN_NET_BLOCK_HEIGHT})")
  email_admin "${SUBJECT}" "${MESSAGE}"
fi


#########################
# Check for chain split
#########################

LOCAL_HASH=$(./.defi/defi-cli getblockhash $BLOCK_HEIGHT)
MAIN_NET_HASH=$(/usr/bin/curl -s https://bitcore.az-staging-0.defichain-wallet.com/api/DFI/mainnet/block/${BLOCK_HEIGHT} | /usr/bin/jq -r '.hash')

if [[ ${LOCAL_HASH} != ${MAIN_NET_HASH} ]]; then
  SUBJECT="Uh-oh!! Master Node Chain Split Detected!!!"
  MESSAGE=$(printf "DeFiChain Split detected before block height ${BLOCK_HEIGHT}\n\nLocal hash: ${LOCAL_HASH}\nMainnet hash: ${MAIN_NET_HASH}\n\nSee https://explorer.defichain.com/#/DFI/mainnet/block/${MAIN_NET_HASH}.\n\nTo fix:\n 1: Find block where split occurred in ~/.defi/debug.log and comparing block hashes in explorer.\n 2: defi-cli invalidateblock <incorrect block hash>\n 3: defi-cli reconsiderblock <correct block hash from explorer>\n 4: defi-cli addnode '185.244.194.174:8555' add\n     addnode '185.244.194.174:8555' add")
  email_admin "${SUBJECT}" "${MESSAGE}"
  exit 1
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
    MESSAGE=$(printf "Your master node just earned its ${MINTED_BLOCKS}$(ordinal ${MINTED_BLOCKS}) DeFiChain Reward!")
    email_admin "${SUBJECT}" "${MESSAGE}"
  fi
fi

echo "${MINTED_BLOCKS}" > ${MINTED_BLOCKS_FILE}

echo ""
echo "Your master node is running perfectly :-)"
echo ""

exit 0