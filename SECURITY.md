# Security policy

Please report vulnerabilities privately, through GitHub's **Report a vulnerability** button on the Security tab of this repository. Don't open a public issue.

This package never needs your Cloudflare App Secret on the client. If you find a way the client could leak one, or a way around the broker's session or room checks described in [docs/design.md](docs/design.md#5-broker-contract), that is in scope.
