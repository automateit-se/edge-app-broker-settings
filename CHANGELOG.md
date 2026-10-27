# Changelog

All notable changes to this app are documented here. Versions follow [semantic versioning](https://semver.org/);
until 1.0, settings may still change.

## 0.1.0

First version. Tested on a Raspberry Pi 4 with the IoT Open edge client installed in Debian (systemd). Not yet
tested in IoT Open's Docker edge client (supervisord).

- Settings for Mosquitto's `max_queued_messages`, `max_queued_bytes`, `queue_qos0_messages` and
  `autosave_interval`, written to `/etc/mosquitto/conf.d/zz-edge-broker-settings.conf`.
- Mosquitto is restarted only when the file changed, and must answer on `127.0.0.1:1883` within 15 seconds;
  otherwise the previous file is put back.
- Settings equal to Mosquitto's defaults remove the file.
