# Security policy

## Reporting a vulnerability

Please report security problems privately, through GitHub's private
vulnerability reporting on this repository:

1. Open [github.com/reprise-voice/reprise](https://github.com/reprise-voice/reprise).
2. Go to the **Security** tab.
3. Choose **Report a vulnerability** and fill in the form.

Do not open a public issue, pull request or discussion for a suspected
vulnerability until it has been fixed and disclosed. The report stays
visible only to you and the repository maintainers, and the discussion,
the fix and the advisory are handled in it.

Problems in the source repositories the build uses from the
[reprise-voice](https://github.com/reprise-voice) organisation (the
FreeSWITCH, Kamailio and Monster UI forks, the Erlang dependency forks) can
be reported here in the same way. Problems in upstream projects that are not
specific to Reprise (FreeSWITCH, Kamailio, CouchDB, RabbitMQ, LavinMQ,
Erlang/OTP, ...) belong with those projects; tell us too if Reprise ships the
affected code.

## What to include

- The component and version: the image name and tag (or digest), or the
  commit of this repository you built from.
- What an attacker can do, and what they need first (network position,
  an account, a privilege level).
- Steps to reproduce: requests, SIP messages, configuration, logs. Remove
  credentials and personal data from anything you attach.
- Whether the problem is already public, and any disclosure date you are
  working to.

## Supported versions

Reprise has just had its first public release. Security fixes are made on
the `main` branch and in the next release; there are no maintained release
branches yet. Upgrade to the latest release to receive fixes.

| Version | Supported |
|---|---|
| Latest release and `main` | Yes |
| Earlier releases | No |
| Upstream Kazoo releases from 2600Hz | No: Reprise cannot fix them |

## Scope

In scope: the code and configurations in this repository, the container
images built from it (`ghcr.io/reprise-voice/reprise`, `reprise-freeswitch`,
`reprise-kamailio`, `reprise-monster-ui`), and the default settings they
ship with.

Deployment-specific weaknesses (exposed broker or CouchDB ports, default
passwords left unchanged, missing TLS) are configuration matters rather than
vulnerabilities; [docker/README.md](docker/README.md) lists the hardening
the images expect. A default that is unsafe is in scope.
