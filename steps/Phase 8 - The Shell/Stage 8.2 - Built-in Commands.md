# Stage 8.2 — Built-in Commands

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 8 - Overview|Phase 8 — The Shell]]

---

## Concept

Now the shell must **understand** the line, not just echo it. You split the line into
a command and arguments (**tokenizing**), then match the command against a table of
**built-ins** — commands the shell runs itself, without loading a program. `help`,
`echo`, and `ls` are natural first built-ins. Built-ins are the quickest way to make
the shell feel real, and `ls` proves the filesystem is reachable from user space.

---

## Specification

- **Tokenize** the line: split on spaces into an argument list (`argv`), where
  `argv[0]` is the command name. Handle multiple spaces and an empty line.
- A built-in table: name → function. On each line, look up `argv[0]`; if found, call
  its function with the arguments.
- First built-ins:
  - `help` — list available commands.
  - `echo` — print the remaining arguments.
  - `ls` — list files, using the filesystem through a syscall (`readdir`/`open`).
  - `clear` (optional) — clear the screen.
- If the command is not a built-in, print "command not found" for now. Stage 8.3
  replaces that with launching a program.

---

## Your task

1. Write a tokenizer that fills an `argv` array from the input line.
2. Build a built-in command table (name + handler).
3. Implement `help`, `echo`, and `ls` (via the filesystem syscalls).
4. Dispatch: match `argv[0]`, call the handler, or print "command not found".
5. Test each built-in, including edge cases (empty line, extra spaces).

---

## How to verify

- `help` lists the commands; `echo hello world` prints `hello world`; `ls` lists the
  ramdisk files.
- An unknown command prints "command not found" and returns to the prompt.
- An empty line just reprints the prompt with no error.

---

## Common traps

- Tokenizing that breaks on leading/trailing/multiple spaces, producing empty
  arguments.
- `ls` assuming direct filesystem access instead of going through a syscall.
- Not null-terminating `argv` or miscounting `argc`.
- Matching commands with a buggy string compare (write or reuse a correct `strcmp`).

---

## Reading

- xv6 shell `sh.c` (tokenizing and command dispatch):
  <https://github.com/mit-pdos/xv6-public/blob/master/sh.c>
- OSDev — *Creating a C Library* (string helpers you will need):
  <https://wiki.osdev.org/Creating_a_C_Library>

Next: **[[Stage 8.3 - Launching Programs]]**.
