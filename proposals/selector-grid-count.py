from fractions import Fraction as F
N = 2**53
a = F(0.05)              # double(0.05)
b = F(0.05 + 0.05)       # cumulative[1], computed as a running sum
c = F(0.95)              # double(0.95)
one = F(1.0)
print("0.05*N        =", a*N, "integer?", (a*N).denominator == 1)
print("0.10*N        =", b*N, "integer?", (b*N).denominator == 1)
print("0.95*N        =", c*N, "integer?", (c*N).denominator == 1)
# selector grid: p = k/N, k in [0, N-1]
def count_le(x):   # #{k in [0,N-1] : k/N <= x}
    import math
    m = math.floor(x*N)
    m = min(m, N-1)
    return m+1
def count_lt(x):
    import math
    xn = x*N
    m = math.ceil(xn)-1 if xn.denominator==1 else math.floor(xn)
    m = min(m, N-1)
    return m+1
stock_lo = count_le(a)
stock_hi = count_le(b) - count_le(a)
stock_gen = N - count_le(b)
patch_lo = count_lt(a)
patch_gen = count_lt(c) - count_lt(a)
patch_hi = N - count_lt(c)
print()
print("stock  lo/hi/general:", stock_lo, stock_hi, stock_gen)
print("patch  lo/hi/general:", patch_lo, patch_hi, patch_gen)
print()
print("lo equal:", stock_lo==patch_lo, " hi equal:", stock_hi==patch_hi, " gen equal:", stock_gen==patch_gen)
print("total check:", stock_lo+stock_hi+stock_gen == N, patch_lo+patch_hi+patch_gen == N)
