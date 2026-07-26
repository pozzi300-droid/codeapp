# Baseline: silent dotnet and hanging csrun

- Baseline commit installed on device: `dcf529675f287e4988f74c39de59c3fbae2dad0e`.
- `dotnet`, `dotnet --info`, and `dotnet run` return immediately without visible output.
- `csrun` never returns a prompt.
- Device reproduction is stable according to the user; it cannot be run on the Linux host.
- GitHub Actions run `30205065519` proves the native arm64 Mono JIT, managed payload, Roslyn, App Extension, and host ABI are present in the IPA.
- Current help/info paths call `fputs(..., thread_stdout)` without flushing.
- Managed `Console.Out` uses process file descriptors 1/2; the current host never maps them to ios_system's per-command `thread_stdout/thread_stderr` pipe.
- The first `mono_jit_init` call attaches its invoking thread as Mono's initial thread; the current host then unconditionally calls `mono_thread_attach` and `mono_thread_detach` on it.

## Stopping condition

Minimal handler/host fix committed, strict GitHub Actions Mono and IPA workflows green, and an on-device test supplied. Final runtime confirmation requires the user's iPad.
