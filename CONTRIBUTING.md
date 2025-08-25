```markdown
# Contributing

Thank you for contributing to Transparent sing-box (Magisk module).

This document explains how to report issues, propose changes and test contributions.

## Reporting issues
- Provide a short title and a clear description of the problem.
- Attach relevant logs from the device:
  - /data/adb/transparent-singbox/transparent-singbox.log
  - Output of iptables/ip6tables/ipset if relevant
- Mention device model, Android version, Magisk version, sing-box version (if available) and any special ROM (MIUI, EMUI, etc).

## Feature requests
- Explain the use case and rationale.
- If possible, propose a design and a patch.

## Pull requests
- Keep scripts POSIX-sh compatible (use /bin/sh constructs).
- Prefer small, focused commits with a clear message.
- Add tests when possible: manual test steps are OK for this project.
- Ensure shell scripts are linted (shellcheck recommended) and are readable.

## Development & testing
- Local build:
  - Run `./build.sh` in the module root to produce `transparent-singbox.zip`.
- Install & test on device:
  1. Push zip to device or use Magisk Manager.
  2. Install module and reboot (or run service.sh start manually).
  3. Check logs in `/data/adb/transparent-singbox/transparent-singbox.log`.
  4. Test start/stop:
     - Stop: `sh /data/adb/modules/transparent-singbox/service.sh stop`
     - Start: `sh /data/adb/modules/transparent-singbox/service.sh`
- If you modify start.rules.sh / iptables logic, test on a non-critical device first. Misconfigured rules can break network connectivity.

## Security
- Do NOT commit secrets (github_token) to the public repository.
- Use the persistent directory `/data/adb/transparent-singbox/github_token` for tokens on-device.
- If you find a security issue, please open a confidential issue or follow the repository security policy.

## CI / Releases
- The repository contains an optional GitHub Actions workflow to create module zips. You can enable it in the `.github/workflows` directory.
- Releases may include a packaged sing-box binary at your discretion. Verify binary integrity if you include it.

## License
- By contributing, you agree to license your contributions under the project's MIT license.
```