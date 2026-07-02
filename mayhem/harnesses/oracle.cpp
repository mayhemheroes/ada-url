// ada-url behavioral oracle — compiled by mayhem/build.sh into build-tests/ada-oracle.
//
// Parses a hard-coded set of well-known URLs, prints each component to stdout in a
// deterministic "KEY=VALUE" format, and exits 0 iff ALL assertions pass.  The lines
// are checked by mayhem/test.sh with exact-match greps so any parser change (or a
// neutered no-op binary) breaks the oracle.
//
// Build: linked from build/singleheader/{ada.cpp,ada.h} with NORMAL (non-fuzzer) flags.
// Run:   build-tests/ada-oracle   (no arguments)
#include <cstdio>
#include <cstdlib>
#include <string>
#include "ada.h"
#include "ada.cpp"   // single-header amalgamation

struct Case {
    const char* input;
    const char* expected_href;
    const char* expected_scheme;   // protocol
    const char* expected_host;
    const char* expected_pathname;
    const char* expected_port;
    const char* expected_search;
    const char* expected_hash;
};

static const Case CASES[] = {
    // Basic HTTPS URL — scheme, host, path, query, fragment
    {
        "https://user:pass@example.com:8080/path/to/page?q=1&r=2#section",
        "https://user:pass@example.com:8080/path/to/page?q=1&r=2#section",
        "https:",
        "example.com:8080",
        "/path/to/page",
        "8080",
        "?q=1&r=2",
        "#section",
    },
    // HTTP with no port, no fragment, no query
    {
        "http://www.example.org/hello/world",
        "http://www.example.org/hello/world",
        "http:",
        "www.example.org",
        "/hello/world",
        "",
        "",
        "",
    },
    // Canonical serialisation: trailing slash on bare host
    {
        "https://example.com",
        "https://example.com/",
        "https:",
        "example.com",
        "/",
        "",
        "",
        "",
    },
    // IPv4 address
    {
        "http://192.0.2.1/resource",
        "http://192.0.2.1/resource",
        "http:",
        "192.0.2.1",
        "/resource",
        "",
        "",
        "",
    },
    // file: URL
    {
        "file:///etc/hosts",
        "file:///etc/hosts",
        "file:",
        "",
        "/etc/hosts",
        "",
        "",
        "",
    },
};

static int FAILS = 0;

static void check(const char* label, const std::string& got, const char* want) {
    if (got == want) {
        printf("OK  %s=%s\n", label, got.c_str());
    } else {
        printf("FAIL %s: want=%s got=%s\n", label, want, got.c_str());
        FAILS++;
    }
}

int main() {
    for (const auto& c : CASES) {
        auto url = ada::parse<ada::url_aggregator>(c.input);
        if (!url) {
            printf("FAIL parse('%s') returned failure\n", c.input);
            FAILS++;
            continue;
        }
        printf("-- %s\n", c.input);
        check("href",     std::string(url->get_href()),     c.expected_href);
        check("scheme",   std::string(url->get_protocol()), c.expected_scheme);
        check("host",     std::string(url->get_host()),     c.expected_host);
        check("pathname", std::string(url->get_pathname()), c.expected_pathname);
        check("port",     std::string(url->get_port()),     c.expected_port);
        check("search",   std::string(url->get_search()),   c.expected_search);
        check("hash",     std::string(url->get_hash()),     c.expected_hash);
    }
    printf("oracle: %d failures\n", FAILS);
    return FAILS == 0 ? 0 : 1;
}
