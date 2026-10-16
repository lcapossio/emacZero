# Security Policy

Please report suspected vulnerabilities privately before opening a public issue.

- Email: hello@bard0.com
- GitHub private vulnerability reporting:
  https://github.com/lcapossio/emacZero/security/advisories/new
  (if the link does not open a report form, use email)
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

The latest release is the supported version; older releases are not patched.
See the repository root `SECURITY.md` for supported versions, scope, disclosure
expectations, and hardening guidance.
