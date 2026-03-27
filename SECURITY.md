# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, **please report it
privately** rather than opening a public issue.

**How to report:**

- Use [GitHub's private vulnerability reporting](https://github.com/Grebec-IT/secure-env-handle/security/advisories/new)
- Or email: gregor.becker@sobekon.de

**What to include:**

- Description of the vulnerability
- Steps to reproduce
- Which scripts/versions are affected
- Suggested fix (if you have one)

**What to expect:**

- Acknowledgement within 48 hours
- A fix or mitigation plan within 7 days for confirmed issues
- Credit in the release notes (unless you prefer anonymity)

## Scope

This project handles secret encryption and deployment scripts. Security issues
of particular interest include:

- Data exfiltration (scripts sending secrets to unintended destinations)
- Encryption weaknesses or misuse of age/DPAPI
- Credential leakage through logs, error messages, or temp files
- Unsafe file permissions on decrypted secrets
