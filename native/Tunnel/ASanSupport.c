// ASan support for the system extension (DESIGN §2.2 "ASan builds", D73-10). Compiled in every build, active only
// when the sanitizer is: a sysex has no environment and no usable stderr.
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#include <os/log.h>
#include <sanitizer/asan_interface.h>

// Exported and `used`, or dead stripping removes it. use_sigaltstack=0 and the Go-compatible signal options: the Go
// runtime installs its own sigaltstack on C threads that call into Go, and ASan then fails a CHECK at thread exit.
__attribute__((used, visibility("default")))
const char *__asan_default_options(void) {
    return "use_sigaltstack=0:handle_segv=0:handle_sigbus=0:allow_user_segv_handler=1:detect_leaks=0:abort_on_error=1";
}

// Routes reports to OSLog. A C function, never a Swift closure at the top level of main.swift (D73-11).
static void lp_asan_report(const char *report) {
    os_log_fault(OS_LOG_DEFAULT, "ASan report: %{public}s", report);
}

__attribute__((constructor))
static void lp_asan_install_hook(void) {
    __asan_set_error_report_callback(lp_asan_report);
}
#endif
#endif
