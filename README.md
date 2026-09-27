# macOS 27 Apple Arcade background task loop

On one Mac running macOS 27.0, an Apple Arcade background task (`ArcadeResetPO`) repeatedly scheduled itself in the past. This kept `dasd` and `appstoreagent` active and produced heavy unified logging. The issue may depend on a particular Apple Arcade history or configuration; its prevalence is unknown.

This script checks for the relevant App Store preference and, after showing a plan and asking for confirmation, advances its scheduled date by one week. It backs up the preference, restarts the user's App Store agent, and checks CPU usage afterwards. This is a workaround for the observed loop, not a fix to macOS. The task may become overdue again the following week.

## Before using it

- Read the script first. It changes the `ArcadePayoutResetDate` value in `com.apple.appstored` and restarts `appstoreagent`.
- Run it as your ordinary user, **without `sudo`**.
- Start with `bash dasd-arcade-loop-fix.sh --dry-run`. The script stops if the expected preference or tools are missing.
- To apply the one-week workaround, run `bash dasd-arcade-loop-fix.sh` and review its confirmation prompt.
- To restore the saved date, run `bash dasd-arcade-loop-fix.sh --rollback` with the same backup directory.

The optional `--durable` mode moves the date to 2035, which may suppress this Apple Arcade background task for years. Its effect on Apple Arcade bookkeeping has not been independently established, so avoid that option unless you understand the trade-off.
