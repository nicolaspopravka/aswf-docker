#include <cpuid.h>
#include <cstdio>
#include <x86intrin.h>

int main()
{
  unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0, cpu = 0;
  const bool extended = __get_cpuid(0x80000001, &eax, &ebx, &ecx, &edx);
  std::printf("CPUID_RDTSCP=%u\n", extended && ((edx >> 27) & 1));
  std::fflush(stdout);
  const auto tick = __rdtscp(&cpu);
  std::printf("tick=%llu cpu=%u\n", tick, cpu);
}
