# Win11Debloat vendored source

- Source: https://github.com/Raphire/Win11Debloat
- Revision: `3d8feefbbc672d55af4b84c8681a1996538e04e2`
- Downloaded: 2026-11-21
- Archive: https://codeload.github.com/Raphire/Win11Debloat/zip/3d8feefbbc672d55af4b84c8681a1996538e04e2
- License: MIT; original copyright and license in `Win11Debloat/LICENSE`.

The complete upstream archive is retained without source modifications. Repository text files may have Git line-ending normalization. No automatic upstream update happens during cleanup. Review a new revision before replacing this directory.

The unified entry reads this revision's default settings, lets the user select individual settings, writes a `Version: 1.0` config with `Tweaks` and `Deployment`, and runs the copy saved in the run directory in a separate Windows PowerShell process. Explorer restart is disabled. A restore point is requested using upstream behavior, including enabling system protection if necessary. Upstream may skip a recent restore point or log a failure; process exit alone does not prove every setting or restore point succeeded.

The wrapper excludes upstream `DisableTelemetry` (changes Defender sample submission) and `DisableWidgets` (force-stops matching processes). Custom group G1 covers telemetry/widgets without these upstream effects. These exclusions do not modify the vendored source.

Upstream backups/undo registry files and custom journals are distinct. The custom restore script does not undo upstream changes, deleted temporary files, component cleanup, or Recall snapshots.
