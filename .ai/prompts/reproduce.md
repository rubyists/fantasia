# Reproduce Stage

Reproduce **{{ issue.identifier }}**: {{ issue.title }} on current main before
diagnosis. Capture a minimal repeatable failing test, command, or visual
artifact; report commit, environment, trigger, expected and observed behavior
in `.stokowski/report.json`. If it does not reproduce, report exactly what was
tried and stop. Do not diagnose or implement a fix here.
