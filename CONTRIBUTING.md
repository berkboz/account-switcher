# Contributing

1. Open or pick a GitHub issue that says what and why.
2. Branch from `main`: `<type>/<short-topic>` (e.g. `fix/codex-restart-prompt`).
3. Follow `AGENTS.md` and `DESIGN.md`. Build with `./build.sh` and exercise the change with the
   `--test-swap` / `--dump` flags (see README, Development). For `windows/` changes run
   `dotnet run --project windows/tests/CoreTests -c Release`.
4. Commit small, imperative messages ("Keep sidebar order on switch").
5. Open a PR with `Closes #N`, what and why, and how you tested (screenshots for UI changes).

Never commit: secrets, account names or emails, `dist/`, `.DS_Store`. This repo is public.
Learned something the next person needs? Add it to `AGENTS.md` in the same PR.
