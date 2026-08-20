## Summary

Describe the user-visible change and why it is needed.

## Privacy and Security

- What transcript, audio, credential, command, filesystem, or network boundaries change?
- Is every new external action explicit and disabled by default?

## Validation

- [ ] `swift build -Xswiftc -warnings-as-errors`
- [ ] `scripts/run-tests.sh`
- [ ] `scripts/check-coverage.sh`
- [ ] `swift build -c release -Xswiftc -warnings-as-errors`
- [ ] Relevant manual checks are described below

## Manual Checks

List checks that cannot run in CI, or write `Not required`.
