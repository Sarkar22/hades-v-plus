# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# model.py -- the expected values of the app 'compute' (compute.c), computed independently:
# the same arithmetic, written with Python's unbounded integers and the 32-bit wrap-around,
# C's division (rounding toward zero) and C's remainder modelled explicitly.
#
#   python3 test/freertos/sdk/apps/compute/model.py
#       prints the four constants as compute.c defines them
# ---------------------------------------------------------------------------------------------
N = 16
MASK = 0xFFFFFFFF


def signed(x):
    """A 32-bit pattern as int32_t."""
    x &= MASK
    return x - (1 << 32) if x & 0x80000000 else x


def c_div(a, b):
    """C's a / b for int32_t: the quotient rounded toward zero."""
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def c_rem(a, b):
    """C's a % b: a - (a / b) * b, so its sign is that of a."""
    return a - c_div(a, b) * b


def matrices():
    """A and B, filled row by row from s = 1 with s = s * 1664525 + 1013904223 (mod 2^32):
    each element is (s >> 16) - 32768 of the next s."""
    s = 1
    out = []
    for _ in range(2):
        m = [[0] * N for _ in range(N)]
        for i in range(N):
            for j in range(N):
                s = (s * 1664525 + 1013904223) & MASK
                m[i][j] = (s >> 16) - 32768
        out.append(m)
    return out


def main():
    a, b = matrices()
    c = [[signed(sum(a[i][k] * b[k][j] for k in range(N))) for j in range(N)] for i in range(N)]
    trace = sum(c[i][i] for i in range(N)) & MASK
    quotients = sum(c_div(c[i][j], j + 1) for i in range(N) for j in range(N)) & MASK
    remainders = sum(c_rem(c[i][j], 7) for i in range(N) for j in range(N)) & MASK
    mulhu = sum(((a[i][j] & MASK) * (b[j][i] & MASK)) >> 32 for i in range(N) for j in range(N)) & MASK
    print(f'#define COMPUTE_TRACE         0x{trace:08x}u')
    print(f'#define COMPUTE_QUOTIENTS     0x{quotients:08x}u')
    print(f'#define COMPUTE_REMAINDERS    0x{remainders:08x}u')
    print(f'#define COMPUTE_MULHU         0x{mulhu:08x}u')


if __name__ == '__main__':
    main()
