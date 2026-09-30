# The AI agent account

Every managed host gets a login called `agent` for an AI agent to work under.
Every program it starts is written to `/var/log/agent-commands.log`, and Alloy
ships that file to Loki as its own integration, `job="integrations/agent"`.

The settings are in `group_vars/all/10_agent.yml`, the tasks in
`roles/baseline/tasks/31_agent.yml`, and the Alloy pipeline in the
`agent_commands` block of `roles/alloy/templates/config.alloy.j2`.

## How it fits together

```
ssh agent@host '<cmd>'
        │
        ▼
kernel audit ── execve under auid=agent or euid=agent, key agent_cmd
        │
        ▼
auditd ──► /usr/local/sbin/agent-command-log   (auditd plugin, libauparse)
        │
        ▼
/var/log/agent-commands.log                    (one JSON object per command)
        │
        ▼
Alloy loki.process "agent_commands"  ──►  Loki  {job="integrations/agent"}
```

**It is audited in the kernel, not from the shell.** An agent rarely has an
interactive shell: it sends `ssh agent@host '<cmd>'`, and PROMPT_COMMAND,
history files and `pam_tty_audit` only see interactive terminals. The kernel
sees every `execve`, from any shell, script or interpreter, so the log holds
the command the agent sent *and* every program that command started. The agent
cannot opt out without root.

**The rules match on the login uid (`auid`) as well as the effective uid.**
`pam_loginuid` sets `auid` when the agent logs in over SSH, and neither `sudo`
nor `su` changes it. So `sudo apt install x` run by the agent is logged, with
`auid=agent` and `euid=root`. The `euid` rules catch processes running as the
agent that did not come from its own login, such as `sudo -u agent` from the
admin account.

**Failed `$PATH` lookups are filtered in the kernel** (`-F exit!=-ENOENT`).
`execvp` tries each directory in `$PATH` in turn, and every miss would
otherwise be its own log line. Other failures are kept, EACCES above all.

**The plugin uses libauparse** (`python3-audit`) instead of parsing records
itself. One command is several audit records (SYSCALL, EXECVE, CWD,
PROCTITLE…) that can interleave with other events, and arguments containing a
space or a quote arrive hex encoded. Long arguments are split into chunks too.
auparse handles all of that.

## What a line looks like

On disk:

```json
{"ts": "2026-09-30T17:58:20.799Z", "cmd": "uname -r", "argv": ["uname", "-r"], "exe": "/usr/bin/uname", "cwd": "/home/agent", "auid": "agent", "uid": "agent", "euid": "agent", "tty": "(none)", "ses": "5", "pid": "3993", "ppid": "3992", "success": "yes", "exit": "0"}
```

`cmd` is `argv` quoted with `shlex.join`, so it can be pasted back into a
shell.

In Loki, **the log line is the command itself** and its timestamp is when the
command ran, not when it was shipped. Other fields:

| Field | Where | Meaning |
|---|---|---|
| `job` | label | always `integrations/agent` |
| `instance` | label | the host, like every other job |
| `euid` | label | who the command ran as. `root` means through sudo |
| `auid` | metadata | the account that logged in, which is always the agent |
| `uid` | metadata | real uid |
| `exe` | metadata | the binary actually executed, with the full path |
| `cwd` | metadata | working directory |
| `ses` | metadata | audit session id, one per SSH login |
| `pid`, `ppid` | metadata | to rebuild the process tree |
| `success`, `exit` | metadata | whether the `execve` worked, e.g. `EACCES(Permission denied)` |
| `tty` | metadata | `(none)` for `ssh host '<cmd>'`, `pts/N` for an interactive session |

`euid` is the only real label, because each value of a label is its own Loki
stream. It is bounded by the accounts on the host.

## Queries

```logql
# everything the agent did on one host
{job="integrations/agent", instance="vps-docker"}

# everything it did as root
{job="integrations/agent", euid="root"}

# one SSH session, in order
{job="integrations/agent", instance="vps-docker"} | ses="5"

# anything that was refused
{job="integrations/agent"} | success="no"

# commands per host over time
sum by (instance) (count_over_time({job="integrations/agent"}[5m]))
```

## Giving the agent access

Add its public key to `agent_ssh_keys` in `group_vars/all/10_agent.yml` (or in
one host's host_vars), then re-run:

```bash
ansible-playbook main.yml -i inventory --ask-vault-pass --tags agent,ssh
```

`ssh` is in the tags because on `[vps]` and `[vpn]` hosts `AllowUsers` in
`42_ssh.yml` has to name the account. That only works against a converged host
(see the tag caveat in `CLAUDE.md`).

The key list is **exclusive**: any other key in the agent's `authorized_keys`
is removed. The account has no password, so the key is the only way in.

Things to decide per host:

- **`agent_sudo`** (off by default). With it, sudo commands are still logged
  and attributed to the agent. But root can stop auditd and edit the log, so
  with sudo on this is a record of an honest agent, not a tamper-proof one.
  Without sudo, the log is root-owned, `0640`, and outside the agent's reach.
- **Do not add the agent to the `docker` group.** Membership is root in all
  but name (`docker run -v /:/host …`), and anything the agent then does
  inside a container runs in the container's own processes. Those are not
  logged as the agent's.
- **`agent_user_manage: false`** in a host's host_vars drops the account's
  management, the audit rules and the Alloy pipeline together on that host.
  Turning it off does not delete an existing account.

## Verifying it works

On the host:

```bash
sudo auditctl -l | grep agent_cmd           # 4 rules on x86_64, 2 elsewhere
pgrep -af agent-command-log                 # the plugin, started by auditd
sudo -u agent -i true; sudo tail -n3 /var/log/agent-commands.log
```

(`sudo -u agent` shows up through the `euid` rules. A real SSH login shows up
through `auid`.)

In Grafana: `{job="integrations/agent", instance="<host>"}` should show the
commands within a few seconds.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Rules listed, log file never created | The plugin is not running. `journalctl -u auditd` shows why; the usual cause is `import auparse` failing because `python3-audit` is missing. auditd restarts a crashing plugin only `max_restarts` times (10), then stops trying until auditd itself is restarted. |
| `auditctl -l` shows no `agent_cmd` rules | Another rules file ends with `-e 2` (immutable). Rules then only change at a reboot. Or the rules failed to load: `sudo augenrules --check` and `sudo augenrules --load`. |
| Commands from `sudo -u agent` appear, SSH logins do not | `auid` is unset, so `pam_loginuid` is not in the sshd PAM stack. Check `/etc/pam.d/sshd` for `session required pam_loginuid.so`. |
| Log fills, Loki shows nothing | Check the Alloy UI (`ssh -L 12345:localhost:12345 <host>`) for `loki.source.file.agent_commands`. Alloy starts tailing at the *end* of the file, so lines written before it first started are not shipped. |
| Very noisy log | A script the agent runs spawns a lot of processes. Each one is a line, by design. Filter at query time (`!= "..."`) rather than weakening the rule. |
