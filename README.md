# defichain-masternode-scripts

IMPORTANT: This script is still in active development.  If you choose to use it, you may run into bugs.  Please report issues here.

This is simple script that allows you to keep track of whether or not your node is working properly.

Specifically, it checks to ensure your node is in sync and that it is continuing to operate on the main chain.  It also notifies you when rewards are received.

If a local or remote chain split is detected, it will find the block where the split occurred and give instructions on how to fix.

Please either send me a message or submit a pull request with change suggestions.  I rarely program in bash, so it's likely I've made silly mistakes.

See readme in code for install instructions.  I have this running every hour via crontab on my masternode.
