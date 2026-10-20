/* RNNoise 0.2's ARM/generic vector code retains this Opus include, but its
 * release archive does not ship the header. Only OPUS_CLEAR is used here. */
#ifndef VELOEDIT_RNNOISE_OS_SUPPORT_H
#define VELOEDIT_RNNOISE_OS_SUPPORT_H
#include "common.h"
#define OPUS_CLEAR(dst, n) RNN_CLEAR(dst, n)
#endif
