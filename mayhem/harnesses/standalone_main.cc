// Generic standalone reproducer driver for ada-url's libFuzzer harnesses.
//
// Each fuzz/<name>.cc defines `LLVMFuzzerTestOneInput(const uint8_t*, size_t)`.
// Linking one of those objects with THIS object (instead of the libFuzzer
// runtime, $LIB_FUZZING_ENGINE) yields a single-shot reproducer that reads one
// input file and runs the harness exactly once — for replaying a crashing input
// outside of Mayhem/libFuzzer. No fuzzing runtime is involved.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

// Honored by libFuzzer-style harnesses if present; harmless here.
extern "C" __attribute__((weak)) int LLVMFuzzerInitialize(int* argc,
                                                          char*** argv);

int main(int argc, char** argv) {
  if (LLVMFuzzerInitialize) {
    LLVMFuzzerInitialize(&argc, &argv);
  }
  if (argc != 2) {
    fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  FILE* f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "failed to open %s\n", argv[1]);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n < 0) {
    fclose(f);
    return 3;
  }
  std::vector<uint8_t> buf(static_cast<size_t>(n));
  size_t got = n > 0 ? fread(buf.data(), 1, static_cast<size_t>(n), f) : 0;
  fclose(f);
  if (n > 0 && got != static_cast<size_t>(n)) {
    fprintf(stderr, "short read\n");
    return 4;
  }
  LLVMFuzzerTestOneInput(buf.data(), buf.size());
  return 0;
}
