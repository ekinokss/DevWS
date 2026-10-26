# DevWS privacy information

This document describes the privacy behavior of the DevWS application, its packaged Windows setup, and this repository.

## Summary

DevWS does not include telemetry, analytics, or usage reporting that sends data to the project maintainers. DevWS itself does not make background network requests for normal workspace operation. It stores configuration, state, backups, and diagnostic data locally.

Network activity can still occur in the following expected cases:

- **WinGet-based prerequisite acquisition.** When the packaged setup needs a machine-wide AutoHotkey v2 installation and none is present, it invokes WinGet to download and install AutoHotkey. WinGet may contact Microsoft and the package source; AutoHotkey and WinGet have their own terms and privacy policies. If AutoHotkey is already installed for all users, the setup does not use WinGet.
- **User-configured commands and applications.** DevWS launches the terminals, applications, and startup commands configured by the user. Those programs may access the network according to their own behavior and privacy policies. DevWS does not proxy, inspect, or report their traffic.
- **Release and source downloads.** DevWS source and release assets are hosted on GitHub. Downloading them is subject to GitHub's privacy statement.

DevWS does not claim that no network activity can ever occur. The statements above describe what DevWS itself does.

## Local data

DevWS stores its canonical configuration, runtime state, disposable backups, diagnostic traces, and generated hotkey files on the local machine under the documented DevWS paths. These files are not uploaded by DevWS. Configured external commands may read or transmit files or data according to their own behavior.

## Accounts and identifiers

DevWS does not require a DevWS account and does not collect user identifiers for the project. No user data is sold.

## Third-party components

DevWS relies on locally installed components including Windows Terminal, PowerShell, Windows scheduled tasks, and AutoHotkey. Their own privacy terms apply to their operation.

## Contact

For privacy questions, use the project issue tracker: https://github.com/ekinokss/DevWS/issues

This document may be updated as DevWS distribution changes, including WinGet catalog publication.
