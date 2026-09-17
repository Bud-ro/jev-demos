# jev-demos

I got access to TypeSafe's Jev model. I want to build some demos.

Built in Dart since I like that language the most. Mono-repo approach, where
every package is its own demo. Common scaffold code lives in `packages/jev_common`:
a shim for their API (or anything else) if needed.

| Package | What |
| --- | --- |
| `packages/jev_common` | Shim for their API, `.env` loading, result recording. |
| `packages/maze_lookahead` | Checking spatial reasoning and its ability to think ahead. |

## Setup

`.env` is in gitignore, it should be set up and ready (copy `.env.example`).

    dart pub get
    dart test packages/jev_common packages/maze_lookahead

## Run

    dart run maze_lookahead --help

[TODO] conventions / anything else worth saying.
