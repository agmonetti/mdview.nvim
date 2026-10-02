// Opt-in Linux process isolation for the evaluated Merman CLI. Included by preview.cpp.
#pragma once
#include <cerrno>
#include <csignal>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <optional>
#include <poll.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t mermaid_child_group = 0;
static void stop_mermaid_worker(int signal) {
    if (mermaid_child_group > 0) kill(-mermaid_child_group, SIGKILL);
    _exit(128 + signal);
}
static void install_mermaid_cleanup() {
    struct sigaction action {};
    action.sa_handler = stop_mermaid_worker;
    sigemptyset(&action.sa_mask);
    for (int signal : {SIGTERM, SIGINT, SIGHUP}) sigaction(signal, &action, nullptr);
}

class MermaidRenderer {
    std::string binary, directory, background, theme;
    std::vector<std::string> images;
    int fit_width = 1, count = 0;
    uint64_t retained_pixels = 0;
    Clock::time_point load_started;
    static constexpr uint64_t max_pixels = 4 * 1024 * 1024;
    static constexpr size_t max_source = 1024 * 1024;
    static std::string diagnostic(const std::string& path) {
        std::ifstream stream(path, std::ios::binary);
        char data[4096]; stream.read(data, sizeof(data));
        std::string message(data, static_cast<size_t>(stream.gcount()));
        for (char& c : message) if (static_cast<unsigned char>(c) < 32) c = ' ';
        return message;
    }
    static void limit(int resource, rlim_t amount) {
        struct rlimit value {amount, amount};
        if (setrlimit(resource, &value) != 0) _exit(126);
    }
    bool execute(const std::string& source, const std::string& png, const std::string& errors) {
        const auto pixels = std::min<uint64_t>(static_cast<uint64_t>(fit_width) * 4096, max_pixels);
        std::vector<std::string> arguments {binary, "render", source, "--format", "png", "--output", png,
            "--theme", theme, "--background", background, "--raster-fit-width", std::to_string(fit_width),
            "--raster-max-width", std::to_string(fit_width), "--raster-max-height", "4096",
            "--raster-max-pixels", std::to_string(pixels), "--resource-profile", "interactive",
            "--resource-limit", "max_source_bytes=1048576", "--operation-timeout-ms", "5000", "--quiet"};
        std::vector<char*> argv;
        for (auto& argument : arguments) argv.push_back(argument.data());
        argv.push_back(nullptr);
        int error_fd = open(errors.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
        if (error_fd < 0 || null_fd < 0) {
            if (error_fd >= 0) close(error_fd);
            if (null_fd >= 0) close(null_fd);
            throw std::runtime_error("Cannot create Mermaid subprocess streams");
        }
        const auto parent = getpid();
        const auto started = Clock::now();
        pid_t child = fork();
        if (child == 0) {
            if (setpgid(0, 0) != 0 || prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) _exit(126);
            // resvg scheduling weights are advisory, not an intermediate-allocation bound.
            // RLIMIT_AS is the hard bound for all allocations, including opaque resvg layers.
            limit(RLIMIT_AS, 768ULL * 1024 * 1024);
            limit(RLIMIT_CPU, 6);
            limit(RLIMIT_FSIZE, 24ULL * 1024 * 1024);
            limit(RLIMIT_CORE, 0);
            if (dup2(null_fd, STDIN_FILENO) < 0 || dup2(null_fd, STDOUT_FILENO) < 0 || dup2(error_fd, STDERR_FILENO) < 0) _exit(126);
            close(null_fd); close(error_fd);
            execv(binary.c_str(), argv.data());
            const char message[] = "Cannot execute configured Mermaid renderer";
            write(STDERR_FILENO, message, sizeof(message)-1);
            _exit(127);
        }
        close(null_fd); close(error_fd);
        if (child < 0) throw std::runtime_error("Cannot start Mermaid renderer");
        mermaid_child_group = child;
        setpgid(child, child);
        int status = 0;
        bool timed_out = false;
        for (;;) {
            auto result = waitpid(child, &status, WNOHANG);
            if (result == child) break;
            if (result < 0 && errno != EINTR) {
                kill(-child, SIGKILL); kill(child, SIGKILL);
                while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
                mermaid_child_group = 0;
                throw std::runtime_error("Cannot wait for Mermaid renderer");
            }
            if (elapsed(started) >= 6000 || elapsed(load_started) >= 15000) {
                timed_out = true;
                kill(-child, SIGKILL); kill(child, SIGKILL);
                while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
                break;
            }
            poll(nullptr, 0, 10);
        }
        // A configured wrapper must not leave descendants after completing its request.
        kill(-child, SIGKILL);
        mermaid_child_group = 0;
        if (timed_out) throw std::runtime_error("Mermaid renderer exceeded its time budget");
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            auto message = diagnostic(errors);
            // The pinned CLI emits this diagnostic only when a detected family is not built in.
            // A syntax, resource or subprocess failure must still invalidate the LOAD.
            if (WIFEXITED(status) && WEXITSTATUS(status) == 1
                && message.rfind("Unsupported diagram type: ", 0) == 0
                && message.size() > sizeof("Unsupported diagram type: ") - 1) return false;
            if (message.empty()) message = WIFSIGNALED(status) ? "renderer stopped by signal " + std::to_string(WTERMSIG(status)) : "renderer exited with status " + std::to_string(WEXITSTATUS(status));
            throw std::runtime_error("Mermaid render failed: " + message);
        }
        return true;
    }
public:
    ~MermaidRenderer() { clear(); }
    void clear() noexcept {
        if (!directory.empty()) {
            std::error_code error;
            std::filesystem::remove_all(directory, error);
        }
        directory.clear(); binary.clear(); images.clear(); count = 0; retained_pixels = 0;
    }
    void configure(std::string executable, std::string path, std::string rgb, int width) {
        if (executable.empty() || executable[0] != '/' || path.empty() || path[0] != '/' || std::filesystem::path(path).lexically_normal() == "/")
            throw std::runtime_error("Mermaid renderer and diagram directory must be absolute paths");
        if (rgb.empty()) rgb = "#0d1117";
        if (rgb.size() != 7 || rgb[0] != '#' || rgb.find_first_not_of("0123456789abcdefABCDEF", 1) != std::string::npos)
            throw std::runtime_error("Invalid Mermaid background RGB");
        auto channel = [&](size_t offset) {
            double value = std::stoi(rgb.substr(offset, 2), nullptr, 16) / 255.0;
            return value <= 0.04045 ? value / 12.92 : std::pow((value + 0.055) / 1.055, 2.4);
        };
        theme = 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5) < 0.5 ? "dark" : "default";
        binary = std::move(executable); directory = std::move(path); background = std::move(rgb);
        fit_width = std::max(1, width - 64); load_started = Clock::now();
        std::filesystem::create_directories(directory);
    }
    bool enabled() const { return !binary.empty(); }
    bool owns_image(const std::string& url) const { return std::find(images.begin(), images.end(), url) != images.end(); }
    std::optional<std::string> render(const std::string& literal, int line) {
        try {
            if (literal.size() > max_source) throw std::runtime_error("Mermaid source exceeds 1 MiB");
            if (count >= 16) throw std::runtime_error("LOAD exceeds 16 Mermaid diagrams");
            if (elapsed(load_started) >= 15000) throw std::runtime_error("Mermaid LOAD exceeded its time budget");
            const auto stem = (std::filesystem::path(directory) / ("diagram-" + std::to_string(count++))).string();
            const auto source = stem + ".mmd", png = stem + ".png", errors = stem + ".stderr";
            std::ofstream stream(source, std::ios::binary);
            stream.write(literal.data(), literal.size()); stream.close();
            if (!stream) throw std::runtime_error("Cannot write Mermaid source");
            if (!execute(source, png, errors)) {
                std::filesystem::remove(source); std::filesystem::remove(errors);
                std::filesystem::remove(png);
                return std::nullopt;
            }
            std::ifstream image(png, std::ios::binary);
            unsigned char header[24] {};
            image.read(reinterpret_cast<char*>(header), sizeof(header));
            const unsigned char signature[] {137, 80, 78, 71, 13, 10, 26, 10};
            if (image.gcount() != sizeof(header) || std::memcmp(header, signature, 8) || std::memcmp(header + 12, "IHDR", 4))
                throw std::runtime_error("Mermaid renderer did not produce a PNG");
            auto dimension = [&](int offset) { return (uint32_t(header[offset]) << 24) | (uint32_t(header[offset+1]) << 16) | (uint32_t(header[offset+2]) << 8) | uint32_t(header[offset+3]); };
            const auto width = dimension(16), height = dimension(20);
            const uint64_t pixels = uint64_t(width) * height;
            if (!width || !height || width > static_cast<uint32_t>(fit_width) || height > 4096 || pixels > max_pixels || pixels + retained_pixels > 16ULL * 1024 * 1024)
                throw std::runtime_error("Mermaid PNG exceeds raster budget");
            retained_pixels += pixels;
            std::filesystem::remove(source); std::filesystem::remove(errors);
            // Preserve percent-containing local paths through litehtml's URL decoder.
            std::string url;
            const char* digits = "0123456789ABCDEF";
            for (unsigned char c : png) {
                if (std::isalnum(c) || c == '/' || c == '-' || c == '_' || c == '.') url += c;
                else { url += '%'; url += digits[c >> 4]; url += digits[c & 15]; }
            }
            images.push_back(url);
            return url;
        } catch (const std::exception& error) {
            throw std::runtime_error("Mermaid block at line " + std::to_string(line) + ": " + error.what());
        }
    }
};
