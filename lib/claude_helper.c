#include <errno.h>
#include <arpa/inet.h>
#include <libgen.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define DEFAULT_TERMUX_PREFIX "/data/data/com.termux/files/usr"
#define CLAUDE_PAYLOAD_NAME "claude.glibc"
#define DNS_PROXY_HEADER_MAX 8192
#define DNS_PROXY_BUFFER_SIZE 16384

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

static int env_has_value(const char *name) {
    const char *value = getenv(name);
    return value != NULL && value[0] != '\0';
}

static const char *first_proxy_value(void) {
    const char *names[] = {"CLAUDE_TERMUX_PROXY", "HTTPS_PROXY", "https_proxy",
                           "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"};

    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        const char *value = getenv(names[i]);
        if (value != NULL && value[0] != '\0') {
            return value;
        }
    }

    return NULL;
}

static void set_proxy_environment(const char *proxy) {
    setenv("HTTPS_PROXY", proxy, 0);
    setenv("https_proxy", proxy, 0);
    setenv("HTTP_PROXY", proxy, 0);
    setenv("http_proxy", proxy, 0);

    if (!env_has_value("CLAUDE_CODE_PROXY_RESOLVES_HOSTS")) {
        setenv("CLAUDE_CODE_PROXY_RESOLVES_HOSTS", "true", 0);
    }
}

static int copy_span(char *dest, size_t dest_len, const char *start, size_t len) {
    if (len == 0 || len >= dest_len) {
        return 0;
    }

    memcpy(dest, start, len);
    dest[len] = '\0';
    return 1;
}

static int send_all(int fd, const void *data, size_t len) {
    const char *ptr = data;

    while (len > 0) {
        ssize_t sent = send(fd, ptr, len, 0);
        if (sent < 0) {
            if (errno == EINTR) {
                continue;
            }
            return 0;
        }
        if (sent == 0) {
            return 0;
        }
        ptr += sent;
        len -= (size_t)sent;
    }

    return 1;
}

static char *find_header_end(char *buf, size_t len) {
    if (len < 4) {
        return NULL;
    }

    for (size_t i = 3; i < len; i++) {
        if (buf[i - 3] == '\r' && buf[i - 2] == '\n' && buf[i - 1] == '\r' &&
            buf[i] == '\n') {
            return &buf[i - 3];
        }
    }

    return NULL;
}

static void send_proxy_status(int fd, int code, const char *reason) {
    char response[128];
    int written = snprintf(response, sizeof(response),
                           "HTTP/1.1 %d %s\r\nConnection: close\r\n\r\n", code, reason);

    if (written > 0 && (size_t)written < sizeof(response)) {
        (void)send_all(fd, response, (size_t)written);
    }
}

static int parse_connect_target(const char *line, char *host, size_t host_len, char *port,
                                size_t port_len) {
    const char *target = NULL;
    const char *target_end = NULL;
    const char *port_start = NULL;
    const char *colon = NULL;

    if (strncmp(line, "CONNECT ", 8) != 0) {
        return 0;
    }

    target = line + 8;
    target_end = strchr(target, ' ');
    if (target_end == NULL || target_end == target) {
        return 0;
    }

    if (*target == '[') {
        const char *close = strchr(target, ']');
        if (close == NULL || close >= target_end || close + 1 >= target_end ||
            close[1] != ':') {
            return 0;
        }
        port_start = close + 2;
        return copy_span(host, host_len, target + 1, (size_t)(close - target - 1)) &&
               copy_span(port, port_len, port_start, (size_t)(target_end - port_start));
    }

    for (const char *ptr = target; ptr < target_end; ptr++) {
        if (*ptr == ':') {
            colon = ptr;
        }
    }
    if (colon == NULL || colon == target || colon + 1 >= target_end) {
        return 0;
    }

    port_start = colon + 1;
    return copy_span(host, host_len, target, (size_t)(colon - target)) &&
           copy_span(port, port_len, port_start, (size_t)(target_end - port_start));
}

static int connect_upstream(const char *host, const char *port) {
    struct addrinfo hints;
    struct addrinfo *result = NULL;
    struct addrinfo *addr = NULL;
    int upstream_fd = -1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = env_is_truthy("CLAUDE_TERMUX_ALLOW_IPV6") ? AF_UNSPEC : AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    if (getaddrinfo(host, port, &hints, &result) != 0) {
        return -1;
    }

    for (addr = result; addr != NULL; addr = addr->ai_next) {
        upstream_fd = socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol);
        if (upstream_fd < 0) {
            continue;
        }
        if (connect(upstream_fd, addr->ai_addr, addr->ai_addrlen) == 0) {
            break;
        }
        close(upstream_fd);
        upstream_fd = -1;
    }

    freeaddrinfo(result);
    return upstream_fd;
}

static void relay_streams(int client_fd, int upstream_fd) {
    char buffer[DNS_PROXY_BUFFER_SIZE];
    int client_open = 1;
    int upstream_open = 1;
    int max_fd = client_fd > upstream_fd ? client_fd : upstream_fd;

    while (client_open || upstream_open) {
        fd_set reads;
        int ready = 0;

        FD_ZERO(&reads);
        if (client_open) {
            FD_SET(client_fd, &reads);
        }
        if (upstream_open) {
            FD_SET(upstream_fd, &reads);
        }

        ready = select(max_fd + 1, &reads, NULL, NULL, NULL);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }

        if (client_open && FD_ISSET(client_fd, &reads)) {
            ssize_t received = recv(client_fd, buffer, sizeof(buffer), 0);
            if (received <= 0) {
                client_open = 0;
                shutdown(upstream_fd, SHUT_WR);
            } else if (!send_all(upstream_fd, buffer, (size_t)received)) {
                break;
            }
        }

        if (upstream_open && FD_ISSET(upstream_fd, &reads)) {
            ssize_t received = recv(upstream_fd, buffer, sizeof(buffer), 0);
            if (received <= 0) {
                upstream_open = 0;
                shutdown(client_fd, SHUT_WR);
            } else if (!send_all(client_fd, buffer, (size_t)received)) {
                break;
            }
        }
    }
}

static void handle_proxy_client(int client_fd) {
    char request[DNS_PROXY_HEADER_MAX + 1];
    char host[NI_MAXHOST];
    char port[NI_MAXSERV];
    size_t used = 0;
    size_t header_len = 0;
    char *header_end = NULL;
    char *line_end = NULL;
    int upstream_fd = -1;

    while (used < DNS_PROXY_HEADER_MAX && header_end == NULL) {
        ssize_t received = recv(client_fd, request + used, DNS_PROXY_HEADER_MAX - used, 0);
        if (received <= 0) {
            return;
        }
        used += (size_t)received;
        request[used] = '\0';
        header_end = find_header_end(request, used);
    }

    if (header_end == NULL) {
        send_proxy_status(client_fd, 400, "Bad Request");
        return;
    }
    header_len = (size_t)(header_end - request) + 4;

    line_end = strstr(request, "\r\n");
    if (line_end == NULL) {
        send_proxy_status(client_fd, 400, "Bad Request");
        return;
    }
    *line_end = '\0';

    if (!parse_connect_target(request, host, sizeof(host), port, sizeof(port))) {
        send_proxy_status(client_fd, 405, "Method Not Allowed");
        return;
    }

    upstream_fd = connect_upstream(host, port);
    if (upstream_fd < 0) {
        send_proxy_status(client_fd, 502, "Bad Gateway");
        return;
    }

    if (!send_all(client_fd, "HTTP/1.1 200 Connection Established\r\n\r\n", 39)) {
        close(upstream_fd);
        return;
    }

    if (used > header_len &&
        !send_all(upstream_fd, request + header_len, used - header_len)) {
        close(upstream_fd);
        return;
    }

    relay_streams(client_fd, upstream_fd);
    close(upstream_fd);
}

static void reap_proxy_workers(void) {
    while (waitpid(-1, NULL, WNOHANG) > 0) {
    }
}

static void run_dns_proxy(int listener_fd) {
    signal(SIGPIPE, SIG_IGN);
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (getppid() == 1) {
        _exit(0);
    }

    for (;;) {
        int client_fd = accept(listener_fd, NULL, NULL);
        pid_t worker = 0;

        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }

        worker = fork();
        if (worker == 0) {
            signal(SIGPIPE, SIG_IGN);
            prctl(PR_SET_PDEATHSIG, SIGTERM);
            close(listener_fd);
            handle_proxy_client(client_fd);
            close(client_fd);
            _exit(0);
        }
        if (worker < 0) {
            handle_proxy_client(client_fd);
        }

        close(client_fd);
        reap_proxy_workers();
    }

    close(listener_fd);
    _exit(0);
}

static int start_dns_proxy(char *proxy_url, size_t proxy_url_len) {
    int listener_fd = -1;
    int yes = 1;
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);
    pid_t proxy_pid = 0;
    int written = 0;

    listener_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listener_fd < 0) {
        return 0;
    }

    (void)setsockopt(listener_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;

    if (bind(listener_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(listener_fd, 16) != 0 ||
        getsockname(listener_fd, (struct sockaddr *)&addr, &addr_len) != 0) {
        close(listener_fd);
        return 0;
    }

    proxy_pid = fork();
    if (proxy_pid < 0) {
        close(listener_fd);
        return 0;
    }

    if (proxy_pid == 0) {
        run_dns_proxy(listener_fd);
    }

    close(listener_fd);
    written = snprintf(proxy_url, proxy_url_len, "http://127.0.0.1:%u",
                       (unsigned int)ntohs(addr.sin_port));
    return written > 0 && (size_t)written < proxy_url_len;
}

static void configure_proxy_environment(void) {
    const char *proxy = first_proxy_value();
    char local_proxy[64];

    if (proxy != NULL) {
        set_proxy_environment(proxy);
        return;
    }

    if (env_is_truthy("CLAUDE_TERMUX_NO_DNS_PROXY") ||
        env_is_truthy("CLAUDE_TERMUX_DISABLE_DNS_PROXY")) {
        return;
    }

    if (start_dns_proxy(local_proxy, sizeof(local_proxy))) {
        set_proxy_environment(local_proxy);
    } else {
        fprintf(stderr,
                "[claude-termux] Warning: could not start local DNS proxy; network auth "
                "may still use upstream resolver paths.\n");
    }
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

    if (first_proxy_value() != NULL) {
        return;
    }

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
    configure_proxy_environment();

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
    const char *prefix = NULL;
    const char *install_dir = NULL;
    char **new_argv = NULL;
    ssize_t read_len;
    int arg_idx = 0;

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

    new_argv = calloc((size_t)argc + 4, sizeof(*new_argv));
    if (new_argv == NULL) {
        perror("[claude-termux] calloc failed");
        return 1;
    }

    new_argv[arg_idx++] = loader_path;
    new_argv[arg_idx++] = "--library-path";
    new_argv[arg_idx++] = lib_path;
    new_argv[arg_idx++] = payload_path;
    for (int i = 1; i < argc; i++) {
        new_argv[arg_idx++] = argv[i];
    }
    new_argv[arg_idx] = NULL;

    execv(loader_path, new_argv);
    perror("[claude-termux] execv failed");
    free(new_argv);
    return 1;
}
