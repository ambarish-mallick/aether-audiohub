// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Radix-2 complex FFT on split real/imaginary arrays.
// Twiddles are computed in double precision and stored in T.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

namespace aether {

template <typename T>
class FFT {
public:
    // n must be a power of two >= 2. Allocates; call off the audio thread.
    void init(std::size_t n) {
        n_ = n;
        bits_ = 0;
        while ((std::size_t(1) << bits_) < n) ++bits_;
        rev_.assign(n, 0);
        for (std::size_t i = 0; i < n; ++i) {
            std::size_t r = 0;
            for (unsigned b = 0; b < bits_; ++b)
                if (i & (std::size_t(1) << b)) r |= std::size_t(1) << (bits_ - 1 - b);
            rev_[i] = static_cast<uint32_t>(r);
        }
        cos_.resize(n / 2);
        sin_.resize(n / 2);
        const double twoPi = 6.283185307179586476925286766559;
        for (std::size_t k = 0; k < n / 2; ++k) {
            cos_[k] = static_cast<T>(std::cos(twoPi * double(k) / double(n)));
            sin_[k] = static_cast<T>(std::sin(twoPi * double(k) / double(n)));
        }
    }

    std::size_t size() const { return n_; }

    // Forward: X[k] = sum x[n] e^{-j2πkn/N}. Inverse is unscaled (caller divides by N).
    void forward(T *re, T *im) const { transform(re, im, false); }
    void inverse(T *re, T *im) const { transform(re, im, true); }

private:
    void transform(T *re, T *im, bool inverse) const {
        const std::size_t n = n_;
        for (std::size_t i = 0; i < n; ++i) {
            const std::size_t j = rev_[i];
            if (j > i) {
                std::swap(re[i], re[j]);
                std::swap(im[i], im[j]);
            }
        }
        const T sign = inverse ? T(1) : T(-1);
        for (std::size_t len = 2; len <= n; len <<= 1) {
            const std::size_t half = len >> 1;
            const std::size_t step = n / len;
            for (std::size_t i = 0; i < n; i += len) {
                for (std::size_t j = 0; j < half; ++j) {
                    const T wr = cos_[j * step];
                    const T wi = sign * sin_[j * step];
                    const std::size_t a = i + j, b = a + half;
                    const T xr = re[b] * wr - im[b] * wi;
                    const T xi = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - xr;
                    im[b] = im[a] - xi;
                    re[a] += xr;
                    im[a] += xi;
                }
            }
        }
    }

    std::size_t n_ = 0;
    unsigned bits_ = 0;
    std::vector<uint32_t> rev_;
    std::vector<T> cos_, sin_;
};

inline std::size_t nextPow2(std::size_t v) {
    std::size_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

} // namespace aether
