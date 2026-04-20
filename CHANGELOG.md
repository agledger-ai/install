# Changelog

This changelog tracks changes to the AGLedger installer (this repository). For AGLedger server changes, see <https://agledger.ai/docs/changelog>.

Releases here are tagged to match the AGLedger server version they ship against.

## Unreleased

- Initial public release. Install scripts, Docker Compose files, Helm chart, and supply-chain artifacts moved from the private `agledger-api/deploy` tree to this repository.
- `install.sh` resolves the default version from the live Docker Hub tag list rather than a hardcoded string, so fresh clones always install the current stable release.
