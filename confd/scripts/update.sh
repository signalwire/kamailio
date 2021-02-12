#! /usr/bin/env bash

# If the updated_time of the secret has not changed during this update cycle...
if cmp -s /root/startrun /root/endrun; then

  # and if the updated_time is different from the previous run
  # OR this is the first run (no /root/lastrun file present)...
  if ! cmp -s /root/endrun /root/lastrun || [[ ! -f /root/lastrun ]]; then

    # then run our reload commands!
    cp /root/endrun /root/lastrun
    kamcmd tls.reload
  fi
fi
