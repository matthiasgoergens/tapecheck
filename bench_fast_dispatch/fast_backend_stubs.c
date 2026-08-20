#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/mlvalues.h>

#include <math.h>
#include <stdbool.h>
#include <stdint.h>

static inline uint64_t mix_bits(uint64_t value, int shift)
{
  return value ^ (value >> shift);
}

static inline uint64_t mix64(uint64_t value)
{
  value = mix_bits(value, 33) * UINT64_C(0xff51afd7ed558ccd);
  value = mix_bits(value, 33) * UINT64_C(0xc4ceb9fe1a85ec53);
  return mix_bits(value, 33);
}

static inline uint64_t next_seed(value state)
{
  int64_t *seed = (int64_t *)Data_custom_val(Field(state, 0));
  uint64_t gamma = (uint64_t)Int64_val(Field(state, 1));
  uint64_t next = (uint64_t)*seed + gamma;
  *seed = (int64_t)next;
  return next;
}

static inline uint64_t next_u64(value state) { return mix64(next_seed(state)); }

static inline bool remainder_is_unbiased(
  uint64_t draw,
  uint64_t remainder,
  uint64_t maximum)
{
  return draw - remainder <= UINT64_C(0x7fffffffffffffff) - maximum;
}

CAMLprim value tapecheck_fast_bool(value state)
{
  return Val_bool((next_u64(state) & UINT64_C(1)) != 0);
}

CAMLprim value tapecheck_fast_int(value state, value lo_value, value hi_value)
{
  int64_t lo = Long_val(lo_value);
  int64_t hi = Long_val(hi_value);
  uint64_t maximum = (uint64_t)(hi - lo);
  uint64_t draw;
  uint64_t remainder;
  do {
    draw = next_u64(state) & UINT64_C(0x7fffffffffffffff);
    remainder = draw % (maximum + UINT64_C(1));
  } while (!remainder_is_unbiased(draw, remainder, maximum));
  return Val_long(lo + (int64_t)remainder);
}

double tapecheck_fast_float(value state, double lo, double hi)
{
  double unit = (double)(next_u64(state) >> 11) * 0x1p-53;
  return lo + unit * (hi - lo);
}

CAMLprim value tapecheck_fast_float_byte(
  value state,
  value lo_value,
  value hi_value)
{
  return caml_copy_double(
    tapecheck_fast_float(state, Double_val(lo_value), Double_val(hi_value)));
}
