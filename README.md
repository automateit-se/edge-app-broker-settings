# Broker settings (IoT Open edge app)

An IoT Open edge app that sets how much the edge client's Mosquitto broker queues for IoT Open while the internet is
down, and how often the queue is saved to disk. The settings are a form in IoT Open's own user interface or in
[App Management](https://github.com/automateit-se/appmanagement), so nobody has to log in to the edge client to
change them.

## Why

An edge client (for example a Raspberry Pi with IoT Open's edge client, or IoT Open's Docker edge client) runs a
local Mosquitto broker with a bridge to IoT Open. When the internet is down, the bridge's messages are queued
locally and sent when it is back. With Mosquitto's defaults:

- at most **1000 messages** are queued (`max_queued_messages`); when the queue is full, new messages are dropped,
  so the end of a long outage is what is missing,
- only messages published with **QoS 1 or 2** are queued (`queue_qos0_messages` off),
- the queue is saved to disk every **30 minutes** (`autosave_interval` 1800 s), when persistence is on.

How long 1000 messages last depends on how often values change. To measure it on the edge client:

```bash
timeout 600 mosquitto_sub -h localhost -t 'obj/#' -v | wc -l   # messages in 10 minutes
```

1000 divided by the messages per minute is the number of minutes the default queue covers.

## Settings

| Setting | Default | Mosquitto option |
|---|---|---|
| Max antal köade meddelanden | 1000 | `max_queued_messages` (0-10 000 000; 0 = no limit) |
| Max storlek på kön (MB) | 0 = no limit | `max_queued_bytes` (0-4096 MB) |
| Köa även QoS 0 | off | `queue_qos0_messages` |
| Spara kön till disk (sekunder) | 1800 | `autosave_interval` (10-86 400) |

The defaults are Mosquitto's own. A queued message is usually 100-300 bytes, so 100 000 messages take about 30 MB
of memory. The options apply to every persistent client of the broker, not only to the bridge.

## How it works

- The app writes the settings that differ from Mosquitto's defaults to one file of its own,
  `/etc/mosquitto/conf.d/zz-edge-broker-settings.conf`. IoT Open's own `iotopen.conf` is never touched.
- Only when the file changed, Mosquitto is restarted: with `systemctl` on an edge client installed in Linux, with
  `supervisorctl` in IoT Open's Docker edge client. The bridge and local clients are disconnected for a few seconds
  and reconnect by themselves.
- After the restart the broker must answer on `127.0.0.1:1883` within 15 seconds. If it does not, the previous file
  is put back and Mosquitto is restarted again, so a setting can never leave the edge client without a broker (for
  example when the same option is also set in another file, which Mosquitto refuses).
- The file is written again at every start of the app. In the Docker edge client `/etc/mosquitto` is not kept when
  the container is recreated, so the settings come back by themselves after an update.
- **Back to Mosquitto's defaults:** set every value to its default. The file is then removed and Mosquitto
  restarted. Stopping or removing the app leaves the last settings in place.

What happened is in the app's log: the settings it found, whether Mosquitto was restarted, and any error.

## Security

Edge apps run as root on the edge client. This app keeps what it does as root small:

- the only file it writes or removes is `/etc/mosquitto/conf.d/zz-edge-broker-settings.conf`,
- the file is built only from integers within fixed limits and one on/off value, so no text from the settings can
  reach Mosquitto's configuration,
- the only commands it runs are fixed: restarting Mosquitto and asking whether it runs.

## Requirements

- An IoT Open edge client: an IoT Open gateway, an edge client installed in Linux (systemd), or the IoT Open Docker
  Edge Client (supervisord).
- Mosquitto reading `/etc/mosquitto/conf.d/` (`include_dir`), as in Debian's and IoT Open's configuration.
- The app installed on the installation in any way: IoT Open's own user interface, App Management or IoT Open's API.

## Development

`app.lua` is the whole app, `app.json` its settings and `edge-app.json` its description in App Management. It runs
in the edge client's Lua runtime (`iotopen-rt`, Lua 5.3). The runtime reports anything the code returns as an
error, so `app.lua` only returns its pure functions to the tests (`BROKER_SETTINGS_TEST`).

```bash
lua5.3 tests/test_app.lua
```

The tests fake the edge client (settings, file system, commands and broker): what is written for which settings,
that values are limited, that unchanged settings do not restart the broker, that the defaults remove the file, and
that a broker that does not come back gets the previous file.

## License

MIT, see [LICENSE](LICENSE).
