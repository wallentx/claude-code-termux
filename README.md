# Claude Code Termux

![](https://img.shields.io/badge/Termux-aarch64-brightgreen?style=flat-square) [![npm]](https://www.npmjs.com/package/@anthropic-ai/claude-code)

[npm]: https://img.shields.io/npm/v/@anthropic-ai/claude-code.svg?style=flat-square

Claude Code is an agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster by executing routine tasks, explaining complex code, and handling git workflows -- all through natural language commands. Use it in your terminal, IDE, or tag @claude on Github.

This fork packages the official Claude Code Linux arm64 binary for native Termux on Android. It does not carry the upstream source tree or commit upstream binaries. Instead, it tracks upstream `anthropics/claude-code` release tags, builds a small native Termux launcher around the official payload, and publishes Termux release artifacts.

**Learn more about Claude Code in the [official documentation](https://code.claude.com/docs/en/overview)**.

## Get Started On Termux

Install the latest Termux artifact:

```bash
curl -fsSL https://raw.githubusercontent.com/wallentx/claude-code-termux/dev/install.sh | bash
```

The installer downloads the latest `claude-termux-aarch64.tar.gz` release asset and installs:

```text
$PREFIX/bin/claude
$PREFIX/bin/claude.glibc
```

Requirements:

- native Termux on Android
- `aarch64`
- `glibc-repo` and `glibc`
- `ca-certificates`
- `resolv-conf`
- `proot`

For non-Termux platforms, use the official Claude Code installer:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

## Release Tracking

CI checks upstream Claude Code tags from `anthropics/claude-code` and compares them with this fork's `vX.Y.Z-termux` release tags. When upstream has a newer tag, the scheduled workflow fails as a release signal.

Release artifacts are built on native Termux runners. The build downloads the official upstream payload, runs an optional payload patch hook if present, builds the native launcher, and uploads an artifact. Upstream and patched binaries stay out of git.

## Reporting Bugs

For Termux packaging issues, use this fork's issue tracker. For Claude Code product issues, use the `/bug` command or file an issue with upstream Anthropic Claude Code.

## Data Collection, Usage, And Retention

When you use Claude Code, Anthropic may collect feedback, which includes usage data, associated conversation data, and user feedback submitted via the `/bug` command.

See Anthropic's [data usage policies](https://code.claude.com/docs/en/data-usage), [Commercial Terms of Service](https://www.anthropic.com/legal/commercial-terms), and [Privacy Policy](https://www.anthropic.com/legal/privacy).
