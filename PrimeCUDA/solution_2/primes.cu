#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <map>
#include <cuda_runtime.h>

using namespace std::chrono;

#define DEFAULT_SIEVE_SIZE 1'000'000
#define MAX_THREADS 128

#define WORD_INDEX(index) (index >> 5)
#define BIT_INDEX(index) (index & 31)

__global__ void initialize_buffer(uint64_t blockSize, uint64_t wordCount, uint32_t *sieve)
{
    const uint64_t startIndex = uint64_t(blockIdx.x) * blockSize;
    const uint64_t endIndex = ullmin(startIndex + blockSize, wordCount);

    for (uint64_t index = startIndex; index < endIndex; index++)
        sieve[index] = UINT32_MAX;
}

__global__ void unmark_multiples_threads(uint32_t primeCount, uint32_t *primes, uint64_t halfSize, uint32_t sizeSqrt, uint32_t *sieve)
{
    // We unmark every "MAX_THREADS"th prime's multiples, starting with our thread index
    for (uint32_t primeIndex = threadIdx.x; primeIndex < primeCount; primeIndex += MAX_THREADS) 
    {
        const uint32_t prime = primes[primeIndex];
        const uint64_t primeSquared = uint64_t(prime) * prime;

        // Unmark multiples starting at just beyond the square root of the sieve size or the square of the prime, 
        //   whichever is larger.
        uint64_t firstUnmarked = primeSquared > sizeSqrt ? primeSquared : ((sizeSqrt / prime + 1) * prime);
        // We're marking off odd multiples only, so make sure we start with one of those!
        if (!(firstUnmarked & 1))
            firstUnmarked += prime;

        for (uint64_t index = firstUnmarked >> 1; index <= halfSize; index += prime) 
            // Clear the bit in the word that corresponds to the last part of the index 
            atomicAnd(&sieve[WORD_INDEX(index)], ~(uint32_t(1) << BIT_INDEX(index)));
    }
}

__global__ void unmark_multiples_blocks(uint32_t primeCount, uint32_t *primes, uint64_t halfSize, uint32_t sizeSqrt, uint32_t maxThreadIndex, uint64_t blockSize, uint32_t *sieve)
{
    // Calculate the start and end of the block we need to work on, at buffer word boundaries. 
    //   Note that the first variable is a number in sieve space...
    uint64_t blockStart = uint64_t(blockIdx.x) * blockSize + sizeSqrt;
    //   ...and the second is an index in the sieve buffer (representing odd numbers only)
    const uint64_t lastIndex = (blockIdx.x == maxThreadIndex) ? halfSize : (((blockStart + blockSize) & ~uint64_t(63)) >> 1) - 1;

    // If this is not the first block, we actually start at the beginning of the first block word
    if (blockIdx.x != 0)
        blockStart &= ~uint64_t(63);

    for (uint32_t primeIndex = 0; primeIndex < primeCount; primeIndex++)
    {
        const uint32_t prime = primes[primeIndex];
        const uint64_t primeSquared = uint64_t(prime) * prime;

        // Unmark multiples starting at just beyond the start of our block or the square of the prime, 
        //   whichever is larger.
        uint64_t firstUnmarked = primeSquared >= blockStart ? primeSquared : ((blockStart / prime + 1) * prime);
        // We're marking off odd multiples only, so make sure we start with one of those!
        if (!(firstUnmarked & 1))
            firstUnmarked += prime;

        for (uint64_t index = firstUnmarked >> 1; index <= lastIndex; index += prime) 
            // Clear the bit in the word that corresponds to the last part of the index 
            sieve[WORD_INDEX(index)] &= ~(uint32_t(1) << BIT_INDEX(index));
    }
}

enum class Parallelization : char
{
    threads,
    blocks
};

class Sieve 
{
    const uint64_t sieve_size;
    const uint64_t half_size;
    const uint32_t size_sqrt;
    const uint64_t buffer_word_size;
    const uint64_t buffer_byte_size;
    uint32_t *device_sieve_buffer;
    uint32_t *host_sieve_buffer;

    void unmark_multiples(Parallelization type, uint32_t primeCount, uint32_t *primeList) 
    {
        // Copy the first (square root of sieve size) buffer bytes to the device
        cudaMemcpy(device_sieve_buffer, host_sieve_buffer, (size_sqrt >> 4) + 1, cudaMemcpyHostToDevice);
        // Allocate device buffer for the list of primes and copy the prime list to it
        uint32_t *devicePrimeList;
        cudaMalloc(&devicePrimeList, primeCount * sizeof(uint32_t));
        cudaMemcpy(devicePrimeList, primeList, primeCount << 2, cudaMemcpyHostToDevice);

        // Unmark multiples on the GPU and then release the prime list buffer
        if (type == Parallelization::threads)
        {
            const uint32_t threadCount = min(MAX_THREADS, primeCount);
            unmark_multiples_threads<<<1, threadCount>>>(primeCount, devicePrimeList, half_size, size_sqrt, device_sieve_buffer);
        }
        else
        {
            const uint64_t sieveSpace = sieve_size - size_sqrt;
            uint64_t blockCount = sieveSpace << 6;
            if (sieveSpace & 63)
                blockCount++;
            const uint32_t threadCount = (uint32_t)min(uint64_t(MAX_THREADS), blockCount);
            uint64_t blockSize = sieveSpace / threadCount;
            if (sieveSpace % threadCount)
                blockSize++;

            unmark_multiples_blocks<<<threadCount, 1>>>(primeCount, devicePrimeList, half_size, size_sqrt, threadCount - 1, blockSize, device_sieve_buffer);
        }
        
        cudaFree(devicePrimeList);

        // Copy the sieve buffer from the device to the host 
        cudaMemcpy(host_sieve_buffer, device_sieve_buffer, buffer_byte_size, cudaMemcpyDeviceToHost);
    }

    public:

    Sieve(unsigned long size) :
        sieve_size(size),
        half_size(size >> 1),
        size_sqrt((uint32_t)sqrt(size) + 1),
        buffer_word_size((half_size >> 5) + 1),
        buffer_byte_size(buffer_word_size << 2)
    {
        // Allocate and initialize device sieve buffer
        cudaMalloc(&device_sieve_buffer, buffer_byte_size);
        initialize_buffer<<<MAX_THREADS, 1>>>(buffer_word_size / MAX_THREADS + 1, buffer_word_size, device_sieve_buffer);
        
        // Allocate host sieve buffer and initialize the bytes up to the square root of the sieve size
        host_sieve_buffer = (uint32_t *)malloc(buffer_byte_size);
        memset(host_sieve_buffer, 255, (size_sqrt >> 4) + 1);
        cudaDeviceSynchronize();
    }

    ~Sieve() 
    {
        cudaFree(device_sieve_buffer);
        free(host_sieve_buffer);
    }

    uint32_t *run(Parallelization type = Parallelization::threads)
    {
        // Calculate the size of the array we need to reserve for the primes we find up to and including the square root of
        //   the sieve size. x / (ln(x) - 1) is a good approximation, but often lower than the actual number, which would
        //   cause out-of-bound indexing. This is why we use x / (ln(x) - 1.2) to "responsibly over-allocate".
        const uint32_t primeListSize = uint32_t(double(size_sqrt) / (log(size_sqrt) - 1.2));

        uint32_t primeList[primeListSize];
        uint32_t primeCount = 0;

        // We clear multiples up to and including size_sqrt
        const uint32_t lastMultipleIndex = size_sqrt >> 1;

        for (uint32_t factor = 3; factor <= size_sqrt; factor += 2)
        {
            uint64_t index = factor >> 1;

            if (host_sieve_buffer[WORD_INDEX(index)] & (uint32_t(1) << BIT_INDEX(index))) 
            {
                primeList[primeCount++] = factor;

                for (index = (factor * factor) >> 1; index <= lastMultipleIndex; index += factor)
                    host_sieve_buffer[WORD_INDEX(index)] &= ~(uint32_t(1) << BIT_INDEX(index));
            }
        }

        unmark_multiples(type, primeCount, primeList);

        // Required to be truly compliant with Primes project rules
        return host_sieve_buffer;
    }

    uint64_t count_primes() 
    {
        uint64_t primeCount = 0;
        const uint64_t lastWord = WORD_INDEX(half_size);
        uint32_t word;

        for (uint64_t index = 0; index < lastWord; index++)
        {
            word = host_sieve_buffer[index];
            while (word) 
            {
                if (word & 1)
                    primeCount++;

                word >>= 1;
            }
        }

        word = host_sieve_buffer[lastWord];
        const uint32_t lastBit = BIT_INDEX(half_size);
        for (uint32_t index = 0; word && index <= lastBit; index++) 
        {
            if (word & 1)
                primeCount++;
            
            word >>= 1;
        }

        return primeCount;
    }
};

const std::map<uint64_t, const int> resultsDictionary =
{
    {             10UL, 4         }, // Historical data for validating our results - the number of primes
    {            100UL, 25        }, //   to be found under some limit, such as 168 primes under 1000
    {          1'000UL, 168       },
    {         10'000UL, 1229      },
    {        100'000UL, 9592      },
    {      1'000'000UL, 78498     },
    {     10'000'000UL, 664579    },
    {    100'000'000UL, 5761455   },
    {  1'000'000'000UL, 50847534  },
    { 10'000'000'000UL, 455052511 },
};

// Assumes any first argument is the desired sieve size. Defaults to DEFAULT_SIEVE_SIZE.
uint64_t determineSieveSize(int argc, char *argv[])
{
    if (argc < 2)
        return DEFAULT_SIEVE_SIZE;

    const uint64_t sieveSize = strtoul(argv[1], nullptr, 0);

    if (sieveSize == 0) 
        return DEFAULT_SIEVE_SIZE;

    if (resultsDictionary.find(sieveSize) == resultsDictionary.end())
        fprintf(stderr, "WARNING: Results cannot be validated for selected sieve size of %zu!\n\n", sieveSize);
    
    return sieveSize;
}

void printResults(Parallelization type, uint64_t sieveSize, uint64_t primeCount, double duration, uint64_t passes)
{
    const auto expectedCount = resultsDictionary.find(sieveSize);
    const auto countValidated = expectedCount != resultsDictionary.end() && expectedCount->second == primeCount;
    const char *parallelizationLabel = type == Parallelization::threads ? "threads" : "blocks";

    fprintf(stderr, "Passes: %zu, Time: %lf, Avg: %lf, Max GPU threads: %d, Type: %s, Limit: %zu, Count: %zu, Validated: %d\n", 
            passes,
            duration,
            duration / passes,
            MAX_THREADS,
            parallelizationLabel,
            sieveSize,
            primeCount,
            countValidated);

    printf("rbergen_faithful_cuda_%s;%zu;%f;1;algorithm=base,faithful=yes,bits=1\n\n", parallelizationLabel, passes, duration);
}

int main(int argc, char *argv[])
{
    const uint64_t sieveSize = determineSieveSize(argc, argv);

    Parallelization types[] = { Parallelization::threads, Parallelization::blocks };

    for (auto &type : types)
    {
        uint64_t passes = 0;

        Sieve *sieve = nullptr;

        const auto startTime = steady_clock::now();
        duration<double, std::micro> runTime;

        do
        {
            delete sieve;

            sieve = new Sieve(sieveSize);
            sieve->run(type);

            passes++;

            runTime = steady_clock::now() - startTime;
        }
        while (duration_cast<seconds>(runTime).count() < 5);

        const size_t primeCount = sieve->count_primes();
        
        delete sieve;

        printResults(type, sieveSize, primeCount, duration_cast<microseconds>(runTime).count() / 1000000.0, passes); 
    }
}
