# Claude notes — protocol-emulator

See AGENTS.md for test rules (gate-level tests use top-level pins only).

## Git permissions

Claude has free commit and push permission in this repo and in
protocol-emulator-compiler, on any branch, including creating and pushing new
branches. Push finished, locally verified work without asking.

Never commit the NEXT_STEPS.md Amaranth section or `codex-session-*.md` files.

## CI watch

After every push, schedule a check about 2 hours later that confirms CI
is not stuck. Baselines: gds 1.5-1.8 h, precheck about 1.9 h, gl_test
about 20 min. Flag any job running more than 1.5 times its baseline.
