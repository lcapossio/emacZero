# Security Policy

Please report suspected vulnerabilities privately before opening a public issue.

- Email: hello@bard0.com
- GitHub private vulnerability reporting:
  https://github.com/lcapossio/emacZero/security/advisories/new
  (enabled; a signed-in GitHub account is needed)
- Include: affected commit or tag, configuration parameters, toolchain, target
  FPGA or integration context, reproduction steps, and expected impact.

If the vulnerability is being actively exploited, or you are a manufacturer
with an EU Cyber Resilience Act reporting obligation for it, put "ACTIVELY
EXPLOITED" in the subject line so it is handled ahead of other reports.

Reports should be acknowledged within 7 calendar days. Confirmed issues should
receive a remediation plan or status update within 30 calendar days. When a fix
is available, a changelog entry or advisory should be published within 90 days
unless coordinated disclosure with affected downstream integrators requires a
different schedule.

Only the latest release is supported: a release stops receiving fixes when the
next one is published, and security fixes ship in a new release.
See the repository root `SECURITY.md` for supported versions, scope, disclosure
expectations, and hardening guidance.
