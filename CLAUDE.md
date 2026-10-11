# CLAUDE.md

This file provides guidance for AI assistants (Claude and others) working in this repository. Keep it updated as the project evolves.

---

## Repository Overview

A macOS menu-bar tool that scrolls Claude desktop-client replies across the MacBook notch area like a teleprompter, with selectable scroll speed.

- **Repo**: `kidgitt/idea`
- **Status**: First app version (`NotchPrompter/`); reading replies via the macOS Accessibility API was verified with `spike/ax-probe`
- **Branch strategy**: See [Branch Conventions](#branch-conventions) below

---

## Project Structure

```
/
├── CLAUDE.md                  # This file
├── NotchPrompter/             # The menu-bar app (Swift package, run with `swift run -c release`)
│   ├── Package.swift
│   ├── README.md              # Features, how to run, file overview
│   └── Sources/NotchPrompter/
└── spike/
    └── ax-probe/              # Swift CLI: reads Claude replies via the Accessibility API (feasibility spike)
        ├── Package.swift
        ├── README.md          # How to build/run on a Mac and what results to report
        └── Sources/ax-probe/
```

Swift code only builds on macOS (`swift build` inside `NotchPrompter/` or `spike/ax-probe/`); it cannot be compiled in the Linux cloud environment.

The Claude desktop client's accessibility-tree structure that the app relies on is documented at the top of `NotchPrompter/Sources/NotchPrompter/ClaudeUI.swift`. If Claude updates break reading, use `ax-probe locate "<text>"` to inspect the new structure.

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Language | Swift 5.9 (Swift Package Manager, no third-party dependencies) |
| Framework | AppKit, macOS Accessibility API (ApplicationServices), CoreText |
| Platform | macOS 14+ |
| Testing | Manual on a Mac (no automated tests yet) |
| CI/CD | — |

---

## Development Setup

> **TODO**: Add setup instructions once the project is initialized.

### Prerequisites

- List required tools and versions here

### Installation

```bash
# Clone the repo
git clone <repo-url>
cd idea

# Install dependencies (update command for your stack)
# npm install | pip install -r requirements.txt | go mod download | etc.
```

### Environment Variables

> **TODO**: Document all required environment variables here. Never commit secrets.

```
# Copy .env.example to .env and fill in values
cp .env.example .env
```

| Variable | Required | Description |
|----------|----------|-------------|
| (none yet) | — | — |

---

## Common Commands

> **TODO**: Update with real commands once the project is set up.

```bash
# Development server
# npm run dev | python main.py | go run . | etc.

# Run tests
# npm test | pytest | go test ./... | etc.

# Lint / format
# npm run lint | ruff check . | golangci-lint run | etc.

# Build
# npm run build | python -m build | go build ./... | etc.
```

---

## Testing

> **TODO**: Describe the testing strategy once established.

- **Framework**: (to be determined)
- **Test location**: (to be determined)
- **Coverage requirements**: (to be determined)

### Running Tests

```bash
# Run all tests
# <command>

# Run a single test file
# <command>

# Run with coverage
# <command>
```

---

## Branch Conventions

| Branch pattern | Purpose |
|----------------|---------|
| `main` | Production-ready code — never push directly |
| `develop` | Integration branch for features |
| `feature/<short-description>` | New features |
| `fix/<short-description>` | Bug fixes |
| `claude/<description>` | Branches created by AI assistants |

> AI assistants should always work on a designated `claude/` branch and open a PR — never push directly to `main`.

---

## Commit Message Style

Use the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <short summary>

[optional body]

[optional footer]
```

**Types**: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`

**Examples**:
```
feat(auth): add JWT refresh token support
fix(api): handle null response from upstream service
docs: update CLAUDE.md with project structure
chore(deps): bump lodash to 4.17.21
```

- Subject line: imperative mood, ≤72 characters, no trailing period
- Reference issues in the footer: `Closes #42`

---

## Code Style & Conventions

> **TODO**: Fill in language/framework-specific conventions once chosen.

### General Rules

- Keep functions small and single-purpose
- Prefer explicit over implicit
- No commented-out code in commits
- No secrets or credentials in source files

### Naming

| Thing | Convention |
|-------|------------|
| (to be defined) | — |

### Linting / Formatting

- **Linter**: (to be determined)
- **Formatter**: (to be determined)
- Run linting before committing; CI will enforce it

---

## Pull Request Guidelines

1. Open a PR against `develop` (or `main` if there is no develop branch)
2. Fill in the PR template with a summary, test plan, and any relevant context
3. All CI checks must pass before merging
4. At least one human review required before merge
5. Squash-merge feature branches to keep history clean

---

## AI Assistant Instructions

### What you should do

- Read this file at the start of every session
- Explore the codebase structure before making changes
- Follow the commit message and branch conventions above
- Run tests and linting after making changes
- Keep this file updated when the project structure changes

### What you should NOT do

- Push directly to `main` or `develop`
- Commit secrets, credentials, or `.env` files
- Add speculative abstractions or features not requested
- Skip CI checks with `--no-verify`
- Amend published commits

### Before opening a PR

- [ ] Tests pass locally
- [ ] Linter passes with no errors
- [ ] CLAUDE.md is updated if project structure changed
- [ ] Commit messages follow the Conventional Commits format

---

## Updating This File

This file should be updated whenever:

- New dependencies or tools are added
- The project structure changes significantly
- New conventions are established
- Setup steps change

Keep sections marked **TODO** accurate — remove them once filled in, or remove the section entirely if it does not apply.
