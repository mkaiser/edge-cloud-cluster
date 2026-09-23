# Windows helper scripts

Three double-clickable scripts for people using the cluster from a Windows laptop: connect to
the VPN, map a network drive, unmap it. They wrap the manual commands in
`doc/vpn-user-access.md` and handle the traps that make a hand-typed attempt fail with a
message that does not describe the actual problem.

Copy the whole folder to the laptop — the scripts are self-contained and need no repo
checkout.

## Use

```bat
vpn-connect.bat                        REM connect (no arguments needed)
vpn-connect.bat -Status                REM is it connected? changes nothing

map-drive.bat X \\fs-1\eda alice       REM map X:, prompts for the password
map-drive.bat X \\fs-1\userhomes       REM prompts for the account name too
unmap-drive.bat X                      REM disconnect and forget the password
```

**Or just double-click them and answer the questions.** Run with no arguments, each script
asks for what it needs and explains every answer - `map-drive.bat` offers the known shares by
number, so no UNC path has to be typed and no drive letter remembered:

```
Which share should be mapped?
  1) \\fs-1\userhomes     your home directory
  2) \\fs-1\eda           EDA installer media (needs the eda-developer group)
  or type a full path of the form \\server\share
Share [1]:
```

After `vpn-connect.bat` succeeds, check the Tailscale icon in the notification area (bottom
right, possibly behind the `^` arrow). It must read **Connected** before a drive mapping will
work, and it is the only ongoing sign the VPN is still up.

**Your username is your AD account, not a Tailscale login.** The scripts add the required
`AD\` prefix for you, so pass just the account name.

## What each one handles for you

| Script | Does the non-obvious part |
|---|---|
| `vpn-connect.bat` | checks Tailscale is installed (and links the download if not); composes `--login-server` with its `https://` scheme, which the client needs but fails *silently* without; always passes `--accept-routes`, without which the lab LAN is unreachable in a way that looks like a firewall problem; detects that the machine is already on the Tailscale SaaS or a previous cluster and re-authenticates, which plain `tailscale up` refuses to do |
| `map-drive.bat` | prefixes `AD\`, without which Windows sends `<pc-name>\alice` and the re-prompt reads as a wrong password; clears the cached credential for that server first, because Windows replays *failed* credentials per server and a corrected username otherwise appears not to help; prompts for the password rather than taking it as an argument, so it stays out of console history |
| `unmap-drive.bat` | reads the server name before removing the mapping, then clears its Credential Manager entry too; also removes remembered mappings `net use` does not list (Explorer API + `HKCU\Network\<letter>`), verifies the letter is really gone and fails loudly if not |

## Notes

- The `.bat` wrappers exist because a stock Windows 11 refuses to run a `.ps1` at all
  (`PSSecurityException`). They pass `-ExecutionPolicy Bypass` for that one call rather than
  changing any machine-wide setting.
- None of them requests Administrator rights, deliberately: a drive mapped from an elevated
  shell lands in a separate logon session where Explorer cannot see it. `map-drive.bat` warns
  when it notices it is running elevated.
- `Connect-Vpn.ps1` carries this cluster's control server as its default, kept current by
  `scripts/environment/updateConfigFromProjectSettings.sh`. **A copy already on a laptop goes
  stale when the cluster is recreated** — take a fresh copy, or pass
  `-Server vpn.<subdomain>.<domain>`. Registrations do not survive a recreate either, so
  everyone signs in again regardless.
- While the cluster issues staging certificates, `vpn-connect.bat` fails on the TLS handshake
  until the staging roots are trusted once — see `scripts/tailscale/README.md`.

Full background, the manual commands, and troubleshooting: `doc/vpn-user-access.md`.
