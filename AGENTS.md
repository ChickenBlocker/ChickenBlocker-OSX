# Repository Instructions

Do not run the full test suite unless the user explicitly asks you to do so.
You may run a single test or a focused group of tests without asking only when
you created those tests yourself as part of the current task.
Do not run shellcheck. I don't have it

The Debian appliance administrator at `appliance-admin@10.11.133.222` uses an
interactive password. Do not attempt appliance SSH/SCP commands through tools,
do not add `BatchMode`, and do not invent a transfer workaround after an
authentication failure. Show the user the exact command or provide a script
that prompts for the appliance password, and let the user run it interactively.
Appliance-console `su -` publication is likewise an interactive user step.
