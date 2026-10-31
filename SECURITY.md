# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for them.

Useful details: the Analyxer version or commit, your macOS version, what an attacker could do, and the steps to reproduce it. You will get an answer as soon as possible; this is a one-person project, so please allow a few days.

## Scope

In scope are problems in Analyxer itself, for example:

- handling of untrusted input (APKs, project folders, PCAP files, tool output) that leads to code execution, path traversal or writing outside the chosen folders
- the tool manager accepting a download that does not match its published checksum, or fetching from somewhere other than the documented source
- integrity checks of analysis projects that can be bypassed

Out of scope are vulnerabilities in the external tools Analyxer calls (Android SDK, JDK, Node.js, REA, JADX, Frida); please report those to their projects. Findings about apps you analysed with Analyxer belong to those apps' developers.

## Supported versions

Only the latest commit on `main` is supported. There are no binary releases yet.
