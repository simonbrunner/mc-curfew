# mc-curfew

Bedtime for selected players on a self-hosted Minecraft server. A small bash script plus cron, no plugins or mods needed.

Shortly before their curfew a player gets a friendly warning in the game, is then removed from the whitelist and kicked, and is added back in the morning. While the curfew is on, the player cannot connect at all. That avoids the "kick, reconnect, kick again" game, and other players are not affected.

- Works with any server type and version that has RCON and a whitelist (Vanilla, Paper, Fabric, …)
- Built for [itzg/minecraft-server](https://github.com/itzg/docker-minecraft-server): finds the container by its compose service name and uses the bundled `rcon-cli`
- Per-player curfew window, with different times per weekday (e.g. later on weekends)
- Per-player message language: English, German, French, Italian, Spanish
- One cron line; missed unlocks are caught up automatically
- Logs only real changes to syslog, so you can see when someone tried to play anyway

## Install

```bash
sudo cp mc-curfew.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/mc-curfew.sh
sudo cp mc-curfew.conf.example /etc/mc-curfew.conf
sudo nano /etc/mc-curfew.conf      # service name, players, windows
sudo mc-curfew.sh status           # check container, windows and current state
```

Then add a single cron entry (`sudo crontab -e`):

```
* * * * *  /usr/local/bin/mc-curfew.sh tick >/dev/null 2>&1
```

## Configuration

`/etc/mc-curfew.conf` (or `mc-curfew.conf` next to the script, or the path in `$MC_CURFEW_CONF`):

```bash
SERVICE="minecraft"            # docker compose service name of the server
DEFAULT_WINDOW="21:30-06:30"   # for players without a window of their own
WARN_MINUTES=10                # in-game warning before the curfew starts
DEFAULT_LANG="en"              # en | de | fr | it | es

PLAYERS=(
  [ExamplePlayer]="en"                                   # DEFAULT_WINDOW every night
  [AnotherPlayer]="de 21:00-06:30 fr,sa:22:30-08:00"     # later on weekend nights
  [ThirdPlayer]="fr 20:30-07:00 sa:off"                  # free on Saturday night
)
```

Each player entry is `"<lang> [window] [days:window ...]"`:

- **window:** `HH:MM-HH:MM`, may cross midnight; `off` means no curfew. Daytime windows such as `13:00-15:00` work too.
- **days:window:** A different window for the night that *starts* on these days. `fr,sa:22:30-08:00` means Friday 22:30 until Saturday 08:00, and Saturday 22:30 until Sunday 08:00. Day names are `mo tu we th fr sa su`; the German `di mi do so` work as well.

Instead of the service lookup you can set `CONTAINER` to a fixed container name. Without Docker, set `RCON_CMD` to any RCON client that takes the command as its last argument, e.g. `mcrcon -H 127.0.0.1 -P 25575 -p secret`.

## How it works

`tick` runs every minute and handles each player on their own:

- **Warning:** `WARN_MINUTES` before the window starts, once per night.
- **Lock:** During the window the player is removed from the whitelist and kicked. This repeats every minute as a safety net, e.g. after a server restart that restores the whitelist from the `WHITELIST` environment variable. A player who is offline is not affected.
- **Unlock:** When the window ends, the player is added back. If the server is down at that moment, the next run catches up.

State is kept in `/var/lib/mc-curfew` (`STATE_DIR`).

## Usage

| Command | |
|---|---|
| `mc-curfew.sh tick` | Run from cron every minute |
| `mc-curfew.sh status` | Windows for tonight, current state per player, online list, whitelist |
| `mc-curfew.sh skip <player>` | Exception: no curfew for the current or next night (unlocks right away) |
| `mc-curfew.sh warn [player ...]` | Send the warning now |
| `mc-curfew.sh enforce [player ...]` | Lock now; stays locked until `unlock` (also for players not in the config) |
| `mc-curfew.sh unlock [player ...]` | Unlock now; inside the window the next `tick` locks again – use `skip` instead |

To test your configuration at a given time without waiting for it:

```bash
MC_CURFEW_NOW="2026-10-02 23:15" mc-curfew.sh status
```

## Logs

```bash
journalctl -t mc-curfew
```

Entries only appear when a player was actually removed, kicked or added back. A kick in the middle of the night therefore means someone was online during the curfew.

Rejected login attempts are in the server log:

```bash
docker logs <container> 2>&1 | grep -i "not white-listed"
```

## Notes

- Cron runs in the system time zone. Check it with `timedatectl`.
- The script detects success by Minecraft's replies ("Removed …", "Kicked …", "Added …"). If a server version words them differently, only the log entries are missing; the curfew still works.
- Add your own language by adding two lines to the `msg()` function.

## License

MIT
