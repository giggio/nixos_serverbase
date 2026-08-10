{ lib, ... }:
{
  clevis = {
    # Shell for a systemd `preStart` that turns a clevis JWE on disk into a plaintext file under the unit's
    # RuntimeDirectory, for the unit's own ExecStart to read.
    #
    # Why this shape. A JWE bound to a tang server is inert on its own: reading it off a stolen machine yields
    # nothing, because deriving the key needs a live exchange with the tang box. That is the whole point - the
    # secret stops living on the server and starts living on the network. `clevis decrypt` takes no arguments and
    # needs no configuration, because the JWE carries the tang URL and key id itself, and the thumbprint was pinned
    # when it was ENCRYPTED. So nothing here needs to know where tang is; that value belongs with the JWE, in
    # whichever repository owns the machine.
    #
    # Pair it with `serviceConfig.RuntimeDirectory`, which is what makes this better than the sops secret it
    # replaces rather than merely different: systemd creates /run/<name> mode 0700 owned by the unit's User, and
    # REMOVES IT when the unit stops. For a `Type = "oneshot"` backup job that means the plaintext exists only while
    # the job runs, instead of sitting in /run/secrets from boot to shutdown.
    #
    # Retries because the tang server is a small hidden box on wifi. A backup job that fails because it asked half a
    # second too early is a false alarm, and these units report failures to Telegram. Retrying is not an attempt to
    # hide a real outage: after the last attempt this exits non-zero, the job fails, and the notification fires - a
    # tang server that is genuinely down MUST be visible, since it is also what will unlock the disks.
    decryptToRuntimeScript =
      {
        # The JWE to decrypt. A path in the nix store, or any readable path on the machine.
        jwe,
        # Where to write the plaintext. Normally "$RUNTIME_DIRECTORY/<file>": systemd exports RUNTIME_DIRECTORY to
        # every Exec* of the unit, so preStart and ExecStart name the same path with identical text, and each unit
        # still gets its own private directory without the caller having to repeat its own name.
        out,
        attempts ? 5,
        delaySeconds ? 15,
      }:
      # NOTE: clevis is not self-contained. `clevis decrypt` shells out to `clevis-decrypt-tang`, which needs
      # `curl` to reach the server and `jose` to do the JWE work, so the CALLING UNIT must carry all three on its
      # `path` - clevis alone is not enough. Found the hard way: with only clevis on the path the unit failed the
      # retry loop and reported "tang may be unreachable" while tang was perfectly healthy.
      #
      # stderr is deliberately NOT redirected to /dev/null. It was, and it turned a missing dependency into a
      # message blaming the network - on the one code path that decides whether a backup runs at all.
      #
      # `umask 077` before anything is written, so the plaintext is never briefly world-readable. The output is
      # assembled under a `.partial` name and moved into place only once it is complete and non-empty, so a
      # half-written config can never be handed to rclone - which would fail in a confusing way, or worse, succeed
      # against the wrong remote.
      /* bash */ ''
        umask 077
        rm -f "${out}" "${out}.partial"

        for attempt in $(seq 1 ${toString attempts}); do
          if clevis decrypt < ${lib.escapeShellArg jwe} > "${out}.partial" && [ -s "${out}.partial" ]; then
            mv "${out}.partial" "${out}"
            break
          fi
          rm -f "${out}.partial"
          if [ "$attempt" -lt ${toString attempts} ]; then
            echo "clevis decrypt failed (attempt $attempt/${toString attempts}); tang may be unreachable, retrying in ${toString delaySeconds}s"
            sleep ${toString delaySeconds}
          fi
        done

        if [ ! -s "${out}" ]; then
          echo "FATAL: could not decrypt ${jwe} after ${toString attempts} attempts." >&2
          echo "The tang server is unreachable. This job cannot run without it; the sops copy of this secret is the" >&2
          echo "offline recovery path and is encrypted to the YubiKey." >&2
          exit 1
        fi
      '';
  };
}
