#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEFAULT_TERMUX_PREFIX "/data/data/com.termux/files/usr"
#define CLAUDE_PAYLOAD_NAME "claude.glibc"

static int path_join(char *buf, size_t len, const char *a, const char *b) {
    int written = snprintf(buf, len, "%s/%s", a, b);
    return written >= 0 && (size_t)written < len;
}

static int first_arg_is_guarded_command(int argc, char **argv) {
    if (argc < 2) {
        return 0;
    }

    return strcmp(argv[1], "update") == 0 || strcmp(argv[1], "upgrade") == 0 ||
           strcmp(argv[1], "install") == 0;
}

static void print_guarded_command_message(const char *command) {
    fprintf(stderr,
            "[claude-termux] Refusing to run `claude %s` through the upstream updater.\n"
            "[claude-termux] /proc/self/exe would point at the glibc loader, not the "
            "Claude payload.\n"
            "[claude-termux] Reinstall or update through the Termux port once its updater "
            "is implemented.\n",
            command);
}

static const char *resolve_prefix(char *fallback, size_t fallback_len) {
    const char *prefix = getenv("PREFIX");

    if (prefix != NULL && prefix[0] != '\0') {
        return prefix;
    }

    if (snprintf(fallback, fallback_len, "%s", DEFAULT_TERMUX_PREFIX) < 0) {
        return NULL;
    }

    if (access(fallback, F_OK) != 0) {
        return NULL;
    }

    return fallback;
}

static int is_native_termux(const char *prefix) {
    char bin_path[PATH_MAX];
    const char *termux_version = getenv("TERMUX_VERSION");

    if (prefix == NULL || prefix[0] == '\0') {
        return 0;
    }

    if (!path_join(bin_path, sizeof(bin_path), prefix, "bin")) {
        return 0;
    }

    if (access(bin_path, F_OK) != 0) {
        return 0;
    }

    if (termux_version != NULL && termux_version[0] != '\0') {
        return 1;
    }

    return strncmp(prefix, DEFAULT_TERMUX_PREFIX, strlen(DEFAULT_TERMUX_PREFIX)) == 0;
}

static int require_file(const char *label, const char *path, int mode) {
    if (access(path, mode) == 0) {
        return 1;
    }

    fprintf(stderr, "[claude-termux] Missing %s: %s\n", label, path);
    return 0;
}

static int env_is_truthy(const char *name) {
    const char *value = getenv(name);

    if (value == NULL || value[0] == '\0') {
        return 0;
    }

    return strcmp(value, "1") == 0 || strcmp(value, "true") == 0 ||
           strcmp(value, "yes") == 0 || strcmp(value, "on") == 0;
}

static void append_res_options(const char *option) {
    const char *existing = getenv("RES_OPTIONS");
    char *combined = NULL;
    int written = 0;

    if (existing == NULL || existing[0] == '\0') {
        setenv("RES_OPTIONS", option, 0);
        return;
    }

    if (strstr(existing, option) != NULL) {
        return;
    }

    written = snprintf(NULL, 0, "%s %s", existing, option);
    if (written < 0) {
        return;
    }

    combined = malloc((size_t)written + 1);
    if (combined == NULL) {
        return;
    }

    (void)snprintf(combined, (size_t)written + 1, "%s %s", existing, option);
    setenv("RES_OPTIONS", combined, 1);
    free(combined);
}

static void append_env_option(const char *name, const char *option) {
    const char *existing = getenv(name);
    char *combined = NULL;
    int written = 0;

    if (existing == NULL || existing[0] == '\0') {
        setenv(name, option, 0);
        return;
    }

    if (strstr(existing, option) != NULL) {
        return;
    }

    written = snprintf(NULL, 0, "%s %s", existing, option);
    if (written < 0) {
        return;
    }

    combined = malloc((size_t)written + 1);
    if (combined == NULL) {
        return;
    }

    (void)snprintf(combined, (size_t)written + 1, "%s %s", existing, option);
    setenv(name, combined, 1);
    free(combined);
}

static void warn_missing_resolver(const char *prefix) {
    char resolver_path[PATH_MAX];

    if (!path_join(resolver_path, sizeof(resolver_path), prefix, "etc/resolv.conf")) {
        return;
    }

    if (access(resolver_path, R_OK) != 0) {
        fprintf(stderr,
                "[claude-termux] Warning: missing resolver config: %s\n"
                "[claude-termux] DNS may fail. Install it with: pkg install resolv-conf\n",
                resolver_path);
    }
}

static int should_bind_resolver_with_proot(const char *prefix, char *proot_path, size_t proot_len,
                                           char *resolv_bind, size_t resolv_bind_len) {
    char termux_resolver[PATH_MAX];
    int written = 0;

    if (env_is_truthy("CLAUDE_TERMUX_NO_PROOT_RESOLV")) {
        return 0;
    }

    if (access("/etc/resolv.conf", R_OK) == 0) {
        return 0;
    }

    if (!path_join(termux_resolver, sizeof(termux_resolver), prefix, "etc/resolv.conf")) {
        return 0;
    }
    if (access(termux_resolver, R_OK) != 0) {
        return 0;
    }

    if (!path_join(proot_path, proot_len, prefix, "bin/proot")) {
        return 0;
    }
    if (access(proot_path, X_OK) != 0) {
        fprintf(stderr,
                "[claude-termux] Warning: /etc/resolv.conf is missing and proot was not "
                "found.\n"
                "[claude-termux] Auth may fail in c-ares DNS paths. Install it with: pkg "
                "install proot\n");
        return 0;
    }

    written =
        snprintf(resolv_bind, resolv_bind_len, "%s:/etc/resolv.conf", termux_resolver);
    if (written < 0 || (size_t)written >= resolv_bind_len) {
        return 0;
    }

    return 1;
}

static int configure_environment(const char *prefix) {
    char cert_path[PATH_MAX];
    char tmp_path[PATH_MAX];
    char browser_path[PATH_MAX];
    const char *tmpdir = getenv("TMPDIR");

    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");

    if (!path_join(cert_path, sizeof(cert_path), prefix, "etc/tls/cert.pem")) {
        return 0;
    }
    if (!require_file("Termux CA bundle", cert_path, R_OK)) {
        fprintf(stderr, "[claude-termux] Install it with: pkg install ca-certificates\n");
        return 0;
    }
    setenv("SSL_CERT_FILE", cert_path, 1);

    if (!env_is_truthy("CLAUDE_TERMUX_ALLOW_IPV6")) {
        append_res_options("no-aaaa");
        append_res_options("single-request");
        append_res_options("timeout:2");
        append_res_options("attempts:2");
        append_env_option("NODE_OPTIONS", "--dns-result-order=ipv4first");
        setenv("BUN_CONFIG_DNS_RESULT_ORDER", "ipv4first", 0);
    }

    if (tmpdir == NULL || tmpdir[0] == '\0') {
        if (!path_join(tmp_path, sizeof(tmp_path), prefix, "tmp")) {
            return 0;
        }
        setenv("TMPDIR", tmp_path, 0);
        setenv("BUN_TMPDIR", tmp_path, 0);
    } else {
        setenv("BUN_TMPDIR", tmpdir, 0);
    }

    /* Claude checks $BROWSER before falling back to xdg-open, and reports
       "no_display" without trying when $BROWSER is unset and no display is
       found. Point it at the Termux URL opener so OAuth login links open in
       the Android browser. setenv without overwrite keeps a user-set BROWSER
       authoritative. */
    if (path_join(browser_path, sizeof(browser_path), prefix, "bin/termux-open-url") &&
        access(browser_path, X_OK) == 0) {
        setenv("BROWSER", browser_path, 0);
    }

    warn_missing_resolver(prefix);
    return 1;
}

int main(int argc, char **argv) {
    char prefix_fallback[PATH_MAX];
    char exec_path[PATH_MAX];
    char exec_path_copy[PATH_MAX];
    char loader_path[PATH_MAX];
    char lib_path[PATH_MAX];
    char payload_path[PATH_MAX];
    char proot_path[PATH_MAX];
    char resolv_bind[PATH_MAX + 32];
    const char *prefix = NULL;
    const char *install_dir = NULL;
    const char *exec_target = NULL;
    char **new_argv = NULL;
    ssize_t read_len;
    int arg_idx = 0;
    int use_proot = 0;

    prefix = resolve_prefix(prefix_fallback, sizeof(prefix_fallback));
    if (!is_native_termux(prefix)) {
        fprintf(stderr,
                "[claude-termux] This launcher is only for native Termux on Android.\n"
                "[claude-termux] Other Linux environments should use the upstream Claude "
                "Linux arm64 binary directly.\n");
        return 1;
    }

    if (first_arg_is_guarded_command(argc, argv)) {
        print_guarded_command_message(argv[1]);
        return 2;
    }

    if (!path_join(loader_path, sizeof(loader_path), prefix,
                   "glibc/lib/ld-linux-aarch64.so.1")) {
        return 1;
    }
    if (!path_join(lib_path, sizeof(lib_path), prefix, "glibc/lib")) {
        return 1;
    }
    if (!require_file("Termux glibc loader", loader_path, X_OK)) {
        fprintf(stderr, "[claude-termux] Install it with: pkg install glibc-repo glibc\n");
        return 1;
    }

    read_len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (read_len < 0 || read_len >= (ssize_t)sizeof(exec_path)) {
        perror("[claude-termux] readlink /proc/self/exe failed");
        return 1;
    }
    exec_path[read_len] = '\0';

    if (snprintf(exec_path_copy, sizeof(exec_path_copy), "%s", exec_path) < 0) {
        return 1;
    }
    install_dir = dirname(exec_path_copy);
    if (!path_join(payload_path, sizeof(payload_path), install_dir, CLAUDE_PAYLOAD_NAME)) {
        return 1;
    }
    if (!require_file("Claude glibc payload", payload_path, R_OK)) {
        return 1;
    }

    if (!configure_environment(prefix)) {
        return 1;
    }

    use_proot =
        should_bind_resolver_with_proot(prefix, proot_path, sizeof(proot_path), resolv_bind,
                                        sizeof(resolv_bind));

    new_argv = calloc((size_t)argc + (use_proot ? 7 : 4), sizeof(*new_argv));
    if (new_argv == NULL) {
        perror("[claude-termux] calloc failed");
        return 1;
    }

    exec_target = loader_path;
    if (use_proot) {
        exec_target = proot_path;
        new_argv[arg_idx++] = proot_path;
        new_argv[arg_idx++] = "-b";
        new_argv[arg_idx++] = resolv_bind;
    }
    new_argv[arg_idx++] = loader_path;
    new_argv[arg_idx++] = "--library-path";
    new_argv[arg_idx++] = lib_path;
    new_argv[arg_idx++] = payload_path;
    for (int i = 1; i < argc; i++) {
        new_argv[arg_idx++] = argv[i];
    }
    new_argv[arg_idx] = NULL;

    execv(exec_target, new_argv);
    perror("[claude-termux] execv failed");
    free(new_argv);
    return 1;
}
