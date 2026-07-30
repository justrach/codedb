# macho: x86_64-macos binaries reserve no headerpad, so `codesign` overwrites the entry point

**Labels:** `bug`, `os-macos`, `backend-self-hosted`, `linking`

## Summary

The self-hosted Mach-O linker emits **x86_64-macos** executables with only **8 bytes** (sometimes **0 bytes**) of free space between the end of the load commands and the start of `__TEXT,__text`, and it does **not** emit an `LC_CODE_SIGNATURE` load command for that target.

When the user later runs `codesign`, Apple's `codesign` must *add* a 16-byte `linkedit_data_command` (`LC_CODE_SIGNATURE`). There is no room, so it writes **8 bytes past the end of the load-command region — directly over the first instructions of `__TEXT,__text`**, which for `-O ReleaseFast` / `ReleaseSafe` / `ReleaseSmall` is exactly the `LC_MAIN` entry point.

`codesign` reports success. The resulting binary is silently corrupted and crashes on launch with `SIGILL` or `SIGSEGV`, or — worse — appears to run while performing wild stores through uninitialized registers.

**aarch64-macos is unaffected** because Zig already emits `LC_CODE_SIGNATURE` there (ad-hoc self-signing is mandatory on Apple Silicon), so re-signing reuses the existing load command instead of appending one.

**This appears to be fixed on master** (`0.17.0-dev.1509+bb296ab9b`), which reserves 4104 bytes of headerpad. Filing so the fix is tracked, confirmed intentional, and considered for backport to the 0.16.x / 0.17.x release branches — the currently shipping toolchains all produce corrupt signed x86_64 binaries.

## Minimal repro

`hello.zig`:

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("hello\n", .{});
}
```

```console
$ zig build-exe hello.zig -O ReleaseFast -target x86_64-macos -lc
$ arch -x86_64 ./hello          # host is arm64; Rosetta 2
hello
$ codesign -f -s - hello        # succeeds, no warning
hello: replacing existing signature
$ arch -x86_64 ./hello
zsh: illegal hardware instruction  ./hello
$ echo $?
132
```

Exit code is `132` (SIGILL) or `139` (SIGSEGV) depending on the byte values that land on the entry point — see "Why the signal varies" below.

## Root cause — byte-level evidence

Load-command region vs. `__text` for the same `hello.zig`:

| build | `ncmds` | end of load cmds | `__text` file offset | **slack** | emits `LC_CODE_SIGNATURE`? |
|---|---|---|---|---|---|
| 0.17.0-dev.813, x86_64, ReleaseFast | 16 | 1880 | 1888 | **8** | no |
| 0.17.0-dev.813, x86_64, ReleaseSmall | 16 | 1880 | 1880 | **0** | no |
| 0.17.0-dev.813, aarch64, ReleaseFast | 17 | 1896 | 1896 | 0 | **yes** |
| 0.17.0-dev.1509 (master), x86_64, ReleaseFast | 16 | 1880 | 5984 | **4104** | no |

`LC_CODE_SIGNATURE` is a `linkedit_data_command` = 16 bytes. With 8 bytes of slack, `codesign` writes bytes 1880..1895; `__text` starts at 1888. After signing, `ncmds` is 17 and the load commands end at **1896 — eight bytes inside `__text`**.

`LC_MAIN entryoff` for this build is `0x760` = **1888** — the exact byte that gets overwritten.

Raw bytes at file offset 1888, before and after `codesign -f -s -`:

```
unsigned: 55 48 89 e5 41 57 41 56  41 55 41 54 53 48 83 ec ...
signed:   f0 90 05 00 a0 52 00 00  41 55 41 54 53 48 83 ec ...
          ^^^^^^^^^^^ ^^^^^^^^^^^
          dataoff     datasize     <- tail of the injected LC_CODE_SIGNATURE
                                      (0x000590f0 = 364784, 0x52a0 = 21152 —
                                       matches `otool -l` on the signed file)
```

Disassembly of the entry point, before:

```asm
pushq  %rbp
movq   %rsp, %rbp
pushq  %r15
pushq  %r14
pushq  %r12
pushq  %rbx
subq   $0xa0, %rsp
```

and after signing:

```asm
lock                       ; f0 90 = LOCK prefix on NOP -> #UD -> SIGILL
nop
addl   $0x52a000, %eax
addb   %al, 0x55(%rcx)
pushq  %r12
pushq  %rbx
subq   $0xa0, %rsp
```

The crash report agrees:

```
exception: { "type": "EXC_BAD_INSTRUCTION", "signal": "SIGILL",
             "codes": "0x0000000000000001, 0x0000000000000000" }
termination: { "indicator": "Illegal instruction: 4", "byProc": "exc handler" }
triggered thread frames:
  0  <unmapped>
  1  dyld  start + 3240
```

i.e. it dies immediately on the first instruction `dyld` jumps to.

## Why the signal varies (and why it is sometimes not a crash)

The bytes written over the entry point are the `dataoff` / `datasize` fields of the injected load command, so **they depend on the size of the binary being signed**. Different sizes produce different garbage instructions:

- `f0 90 …` → `lock nop` → `#UD` → **SIGILL (132)**
- other sizes → wild memory operand → **SIGSEGV (139)**
- and sometimes → instructions that happen not to fault

The last case is the dangerous one. A real 7 MB executable of ours (`codedb`, same toolchain, same 8-byte slack, same `entryoff = 0x760`) signs to:

```asm
andb   $0x0, 0x6c(%rbx)     ; wild store
andb   %al, (%rcx)          ; wild store
addb   %al, 0x54(%rcx)      ; wild store
pushq  %rbx                 ; note: push rbp/r15/r14/r12 were consumed
subq   $0xa0, %rsp
```

It **exits 0 and prints correct output**, while doing three stores through whatever `%rbx`/`%rcx` `dyld` happened to leave behind and running `main` on an unbalanced frame. This is almost certainly why the downstream reports are intermittent — some users segfault on launch, others do not.

Also note `-O Debug` does *not* reproduce, purely by luck: its `LC_MAIN entryoff` is `0x122f80`, far from `__text`'s start, so the clobbered 8 bytes land in an unrelated function.

## Full matrix

`hello.zig`, `-target x86_64-macos -lc`, executed as `arch -x86_64 ./hello`, **3 runs per cell**, exit codes listed.

### Toolchain A — master `0.17.0-dev.1509+bb296ab9b` (aarch64-macos host)

| signing | exit codes | result |
|---|---|---|
| unsigned | `0, 0, 0` | prints `hello` |
| ad-hoc (`codesign -f -s -`) | `0, 0, 0` | prints `hello` |
| Developer ID + `--options runtime` | `0, 0, 0` | prints `hello` |

### Toolchain B — control, current stable `0.17.0-dev.813+2153f8143`

| signing | exit codes | result |
|---|---|---|
| unsigned | `0, 0, 0` | prints `hello` |
| ad-hoc (`codesign -f -s -`) | `132, 132, 132` | **SIGILL on launch** |
| Developer ID + `--options runtime` | `132, 132, 132` | **SIGILL on launch** |
| ad-hoc, built with `-headerpad 0x1000` | `0, 0, 0` | prints `hello` (workaround) |

### Supporting cells (toolchain B unless noted)

| case | unsigned | ad-hoc signed |
|---|---|---|
| `-O Debug`, x86_64 | `0, 0, 0` | `0, 0, 0` (entry far from `__text` start) |
| `-O ReleaseSafe`, x86_64 | `0, 0, 0` | `139, 139, 139` |
| `-O ReleaseFast`, x86_64 | `0, 0, 0` | `139, 139, 139` |
| `-O ReleaseSmall`, x86_64 | `0, 0, 0` | `139, 139, 139` |
| same four, without `-lc` | `0, 0, 0` | identical to above |
| `-O ReleaseFast`, **aarch64** (run natively) | `0, 0, 0` | `0, 0, 0` |
| `-headerpad 0x400 / 0x800 / 0x1000 / 0x2000`, x86_64 ReleaseFast | `0, 0, 0` | `0, 0, 0` |

Note the two different crash signals above are the size-dependence described earlier — those binaries were built with `--name`, changing their size and therefore the bytes written over the entry point.

### C control — signing itself is fine

```c
#include <stdio.h>
int main(void){ printf("hello\n"); return 0; }
```

```console
$ clang -O2 -arch x86_64 -o hello-c hello.c
$ codesign -f -s - hello-c
```

| binary | unsigned | ad-hoc signed |
|---|---|---|
| `clang -O2 -arch x86_64` | `0, 0, 0` | `0, 0, 0` |

`ld64` always reserves headerpad, so `codesign` has room to append the load command. This confirms the fault is in the Zig-produced Mach-O layout, not in `codesign`, Rosetta, or the OS version.

## Expected

`zig build-exe -target x86_64-macos` should reserve enough headerpad for a later `LC_CODE_SIGNATURE` (`ld64` reserves a page by default), or emit `LC_CODE_SIGNATURE` for x86_64-macos as it already does for aarch64-macos — either way, `codesign` on a Zig-produced binary must not overwrite `__text`.

Arguably `codesign` should also refuse rather than silently corrupting the image, but the linker side is the actionable fix and matches `ld64` behaviour.

## Workaround (for released toolchains)

Explicitly reserve headerpad. Any value ≥ 16 bytes is sufficient; a page matches `ld64`:

```console
$ zig build-exe hello.zig -O ReleaseFast -target x86_64-macos -lc -headerpad 0x1000
```

or, from `build.zig` (`headerpad_size` exists in `std.Build.Step.Compile` in 0.17.0-dev.813):

```zig
exe.headerpad_size = 0x1000;
```

Both move `__text` to `0x1760` and produce a signed binary that runs cleanly (`0, 0, 0`).

## Environment

- Host: Apple Silicon (arm64), macOS **26.5.1**, build **25F80**
- x86_64 binaries executed under **Rosetta 2** via `arch -x86_64` (crash report shows `translated: true`); the corruption is present in the file itself and is not Rosetta-specific
- Xcode **26.5** (build 17F42); `codesign` from that toolchain
- Affected: `zig 0.17.0-dev.813+2153f8143` (and 0.16.x, per the downstream reports)
- Fixed: `zig 0.17.0-dev.1509+bb296ab9b`
- Targets affected: `x86_64-macos` only; `aarch64-macos` is fine
- Optimization modes affected: `ReleaseFast`, `ReleaseSafe`, `ReleaseSmall` (`Debug` masks it by luck)

## Downstream context

- justrach/codedb#504 — original user report ("MacOS intel x64 segmentation error", `codedb` exiting 139 on launch on an Intel Mac). Closed downstream without a root cause; the x86_64 release slice has shipped **unsigned** ever since as a workaround.
- justrach/codedb#618 — tracking issue to re-enable codesign + notarization for `codedb-darwin-x86_64`, explicitly blocked on this. Shipping unsigned means the Intel slice cannot be notarized and trips Gatekeeper.

## Questions

1. Was the headerpad change on master intentional, and is there a commit/PR to reference?
2. Can it be backported to the 0.16.x / 0.17.x release branches? Every currently released toolchain produces x86_64-macos binaries that are silently corrupted by `codesign`, and the failure mode is sometimes "runs fine but stores through garbage pointers" rather than a clean crash.
