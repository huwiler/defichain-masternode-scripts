# defichain-masternode-scripts

This is simple script that allows you to keep track of whether or not your node is working properly.

Specifically, it checks to ensure your node is in sync and that it is continuing to operate on the main chain.  It also notifies you when rewards are received.

If a local chain split is detected, it will find the block where the split occurred, it will try to locate the block on which the split occurred and give instructions on how to fix.  You can also configure it to automatically fix the split for you.

Please either send me a message or submit a pull request with change suggestions.  I rarely program in bash, so it's likely I've made silly mistakes.

See readme in code for install instructions.  I have this running every hour via crontab on my masternode.
