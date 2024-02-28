#include <metal_stdlib>
#include <metal_limits>
using namespace metal;


METAL_FUNC uint nonzero(uint n) {
    return n == 0 ? 1 : n;
}
template<uint N>
constexpr uint nonzero() {
    return N == 0 ? 1 : N;
}

template<typename T>
constexpr ushort granularity() {
    return nonzero<vec_elements<T>::value>();
}

METAL_FUNC uint next_p2(uint x) {
    return 1 << (32 - clz(x - 1));
}
METAL_FUNC uint prev_p2(uint x) {
    return 1 << (31 - clz(x));
}

constant uint MAX_SHARED_MEM = 32767;

template<typename T>
METAL_FUNC uint max_shared_mem(uint n) {
    return min(n, prev_p2(MAX_SHARED_MEM / sizeof(T)));
}

struct Divide {
    template<typename T>
    METAL_FUNC T operator()(T a, T b) { return a / b; }

    METAL_FUNC float  operator()(float  a, float  b) { return fast::divide(a, b); }
    METAL_FUNC float2 operator()(float2 a, float2 b) { return fast::divide(a, b); }
    METAL_FUNC float4 operator()(float4 a, float4 b) { return fast::divide(a, b); }
    METAL_FUNC half   operator()(half   a, half   b) { return divide(a, b); }
    METAL_FUNC half2  operator()(half2  a, half2  b) { return divide(a, b); }
    METAL_FUNC half4  operator()(half4  a, half4  b) { return divide(a, b); }
    #if defined(__HAVE_BFLOAT__)
    METAL_FUNC bfloat  operator()(bfloat  a, bfloat  b) { return static_cast<bfloat>(fast::divide(a, b)); }
    METAL_FUNC bfloat2 operator()(bfloat2 a, bfloat2 b) { return static_cast<bfloat2>( a / b ); }
    METAL_FUNC bfloat4 operator()(bfloat4 a, bfloat4 b) { return static_cast<bfloat4>( a / b ); }
    #endif
};

struct Exp {
    template<typename T>
    METAL_FUNC T operator()(T a) { return fast::exp(a); }

    METAL_FUNC float  operator()(float  a) { return fast::exp(a); }
    METAL_FUNC float2 operator()(float2 a) { return fast::exp(a); }
    METAL_FUNC float4 operator()(float4 a) { return fast::exp(a); }
    METAL_FUNC half   operator()(half   a) { return exp(a); }
    METAL_FUNC half2  operator()(half2  a) { return exp(a); }
    METAL_FUNC half4  operator()(half4  a) { return exp(a); }
    #if defined(__HAVE_BFLOAT__)
    METAL_FUNC bfloat  operator()(bfloat  a) { return static_cast<bfloat>(fast::exp(a)); }
    METAL_FUNC bfloat2 operator()(bfloat2 a) { return static_cast<bfloat2>(fast::exp(static_cast<float2>(a))); }
    METAL_FUNC bfloat4 operator()(bfloat4 a) { return static_cast<bfloat4>(fast::exp(static_cast<float4>(a))); }
    #endif
};

METAL_FUNC uint get_strided_index(
    uint idx,
    constant const uint &num_dims,
    constant const size_t *dims,
    constant const size_t *strides
) {
    uint strided_i = 0;
    for (uint d = 0; d < num_dims; d++) {
        uint dim_idx = num_dims - 1 - d;
        strided_i += (idx % dims[dim_idx]) * strides[dim_idx];
        idx /= dims[dim_idx];
    }
    return strided_i;
}

// Keeps track of the index of the value in the reduction operation (argmin, argmax, etc.)
// and the value itself. The index is also used to break ties in the reduction operation.
// There are two specializations of the indexed class, one for scalar values and one for vector values.
template <typename T, typename = void>
struct indexed;

template <typename T>
struct is_indexed_type {
    static constant constexpr bool value = false;
};

template <typename T>
constexpr constant bool is_indexed_t = is_indexed_type<T>::value;

template <typename T>
struct is_indexed_type<indexed<T>> {
    static constant constexpr bool value = true;
};

template <typename T>
struct _is_vector_impl<indexed<T>> {
    static constant constexpr bool value = is_vector_v<T>;
};

// Specialization for scalar values
template <typename T>
struct indexed<T, typename metal::enable_if_t<is_scalar_v<T>>> {
    uint i;
    T val;

    constexpr indexed<T>() threadgroup = default;
};

// Support turning indexed<T> into indexed<make_scalar_t<T>>.
template <typename T>
struct _make_scalar_impl<indexed<T>> {
    typedef indexed<make_scalar_t<T>> type;
};

// Specialization for vector values
template <typename T>
struct indexed<T, typename metal::enable_if_t<is_vector_v<T>>> {
    using I = vec<uint, vec_elements<T>::value>;
    I i;
    T val;

    constexpr indexed<T>() threadgroup = default;

    // Return 1-dimensional indexed value
    METAL_FUNC constexpr indexed<make_scalar_t<T>> operator[](uint n) const {
        assert(n < N);
        return indexed<make_scalar_t<T>>{ i[n], val[n] };
    }

};

template<typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
constexpr METAL_FUNC bool operator<(indexed<T> lhs, indexed<T> rhs) {
    return lhs.val < rhs.val || (lhs.val == rhs.val && lhs.i < rhs.i);
}

template<typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
constexpr METAL_FUNC bool operator>(indexed<T> lhs, indexed<T> rhs) {
    return lhs.val > rhs.val || (lhs.val == rhs.val && lhs.i > rhs.i);
}

template<typename T>
struct _numeric_limits_impl<indexed<T>> {
    static constexpr METAL_FUNC indexed<T> lowest() {
        return indexed<T>{ 0, numeric_limits<T>::lowest() };
    }

    static constexpr METAL_FUNC indexed<T> max() {
        return indexed<T>{ 0, numeric_limits<T>::max() };
    }
};

#if __METAL_VERSION__ >= 220
METAL_FUNC int64_t simd_shuffle_down(int64_t data, uint16_t delta) {
  return as_type<int64_t>(simd_shuffle_down(as_type<uint2>(data), delta));
}

template<uint N>
METAL_FUNC vec<int64_t, N> simd_shuffle_down(vec<int64_t, N> data, uint16_t delta) {
  return as_type<vec<int64_t, N>>(simd_shuffle_down(as_type<vec<uint, 2 * N>>(data), delta));
}
#endif


#if defined(__HAVE_BFLOAT__)
// Metal does not have simd_shuffle_down for bfloat16
METAL_FUNC bfloat simd_shuffle_down(bfloat value, ushort delta) {
    return static_cast<bfloat>(simd_shuffle_down(static_cast<float>(value), delta));
}

template<uint N>
METAL_FUNC vec<bfloat, N> simd_shuffle_down(vec<bfloat, N> value, ushort delta) {
    return as_type<vec<bfloat, N>>(simd_shuffle_down(as_type<vec<float, N / 2>>(value), delta));
}

#endif

template <typename T>
METAL_FUNC indexed<T> simd_shuffle_down(indexed<T> iv, ushort delta) {
    return indexed<T> {
        simd_shuffle_down(iv.i, delta),
        simd_shuffle_down(iv.val, delta)
    };
}

template<typename T>
struct Sum {
    static constexpr METAL_FUNC T init() {
        return 0;
    }
    static METAL_FUNC T simd_op(T a) {
        return simd_sum(a);
    }

    template<typename V>
    METAL_FUNC V operator()(V a, V b) {
        return a + b;
    }
};

template<typename T>
struct Mul {
    static constexpr METAL_FUNC T init() {
        return 1;
    }
    static METAL_FUNC T simd_op(T a) {
        return simd_product(a);
    }

    template<typename V>
    METAL_FUNC V operator()(V a, V b) {
        return a * b;
    }
};

template<typename T>
struct Min {
    static constexpr METAL_FUNC T init() {
        return numeric_limits<T>::max();
    }
    static METAL_FUNC T simd_op(T a) {
        return simd_min(a);
    }

    template<typename V>
    METAL_FUNC V operator()(V a, V b) { return a < b ? a : b; }

    METAL_FUNC float operator()(float a, float b) { return fast::min(a, b); }
    METAL_FUNC float2 operator()(float2 a, float2 b) { return fast::min(a, b); }
    METAL_FUNC float4 operator()(float4 a, float4 b) { return fast::min(a, b); }
    METAL_FUNC half operator()(half a, half b) { return min(a, b); }
    METAL_FUNC half2 operator()(half2 a, half2 b) { return min(a, b); }
    METAL_FUNC half4 operator()(half4 a, half4 b) { return min(a, b); }

    METAL_FUNC uint operator()(uint a, uint b) { return min(a, b); }
    METAL_FUNC uint2 operator()(uint2 a, uint2 b) { return min(a, b); }
    METAL_FUNC uint4 operator()(uint4 a, uint4 b) { return min(a, b); }

    METAL_FUNC uchar operator()(uchar a, uchar b) { return min(a, b); }
    METAL_FUNC uchar2 operator()(uchar2 a, uchar2 b) { return min(a, b); }
    METAL_FUNC uchar4 operator()(uchar4 a, uchar4 b) { return min(a, b); }

    #if __METAL_VERSION__ >= 220
    METAL_FUNC long operator()(long a, long b) { return min(a, b); }
    METAL_FUNC long2 operator()(long2 a, long2 b) { return min(a, b); }
    METAL_FUNC long4 operator()(long4 a, long4 b) { return min(a, b); }
    #endif

    #if defined(__HAVE_BFLOAT__)
    METAL_FUNC bfloat operator()(bfloat a, bfloat b) { return static_cast<bfloat>(fast::min(static_cast<float>(a), static_cast<float>(b))); }
    METAL_FUNC bfloat2 operator()(bfloat2 a, bfloat2 b) { return as_type<bfloat2>(fast::min(as_type<float>(a), as_type<float>(b))); }
    METAL_FUNC bfloat4 operator()(bfloat4 a, bfloat4 b) { return as_type<bfloat4>(fast::min(as_type<float2>(a), as_type<float2>(b))); }
    #endif
};

template<typename T>
struct Max {
    static constexpr METAL_FUNC T init() {
        return numeric_limits<T>::lowest();
    }
    static METAL_FUNC T simd_op(T a) {
        return simd_max(a);
    }

    template<typename V>
    METAL_FUNC V operator()(V a, V b) { return a > b ? a : b; }

    METAL_FUNC float operator()(float a, float b) { return fast::max(a, b); }
    METAL_FUNC float2 operator()(float2 a, float2 b) { return fast::max(a, b); }
    METAL_FUNC float4 operator()(float4 a, float4 b) { return fast::max(a, b); }
    METAL_FUNC half operator()(half a, half b) { return max(a, b); }
    METAL_FUNC half2 operator()(half2 a, half2 b) { return max(a, b); }
    METAL_FUNC half4 operator()(half4 a, half4 b) { return max(a, b); }

    METAL_FUNC uint operator()(uint a, uint b) { return max(a, b); }
    METAL_FUNC uint2 operator()(uint2 a, uint2 b) { return max(a, b); }
    METAL_FUNC uint4 operator()(uint4 a, uint4 b) { return max(a, b); }

    METAL_FUNC uchar operator()(uchar a, uchar b) { return max(a, b); }
    METAL_FUNC uchar2 operator()(uchar2 a, uchar2 b) { return max(a, b); }
    METAL_FUNC uchar4 operator()(uchar4 a, uchar4 b) { return max(a, b); }

    #if __METAL_VERSION__ >= 220
    METAL_FUNC long operator()(long a, long b) { return max(a, b); }
    METAL_FUNC long2 operator()(long2 a, long2 b) { return max(a, b); }
    METAL_FUNC long4 operator()(long4 a, long4 b) { return max(a, b); }
    #endif

    #if defined(__HAVE_BFLOAT__)
    METAL_FUNC bfloat operator()(bfloat a, bfloat b) { return static_cast<bfloat>(fast::max(static_cast<float>(a), static_cast<float>(b))); }
    METAL_FUNC bfloat2 operator()(bfloat2 a, bfloat2 b) { return as_type<bfloat2>(fast::max(as_type<float>(a), as_type<float>(b))); }
    METAL_FUNC bfloat4 operator()(bfloat4 a, bfloat4 b) { return as_type<bfloat4>(fast::max(as_type<float2>(a), as_type<float2>(b))); }
    #endif
};

template <typename T>
constexpr constant bool is_simd_t = __is_valid_simdgroup_type<T>::value;

template <typename T, typename _E = void>
struct is_valid_simd_type {
    static constant constexpr bool value = false;
};

template <typename T>
constexpr constant bool is_valid_simd_t = is_valid_simd_type<T>::value;

template <typename T>
struct is_valid_simd_type<T, typename metal::enable_if_t<is_simd_t<T>>> {
    static constant constexpr bool value = true;
};

template <typename T>
struct is_valid_simd_type<indexed<T>, typename metal::enable_if_t<is_valid_simd_t<T>>> {
    static constant constexpr bool value = true;
};

#if __METAL_VERSION__ >= 220
template <>
struct is_valid_simd_type<int64_t> {
    static constant constexpr bool value = true;
};
template <uint N>
struct is_valid_simd_type<vec<int64_t, N>> {
    static constant constexpr bool value = true;
};
#endif

#if defined(__HAVE_BFLOAT__)
template <>
struct is_valid_simd_type<bfloat> {
    static constant constexpr bool value = true;
};
template <uint N>
struct is_valid_simd_type<vec<bfloat, N>> {
    static constant constexpr bool value = true;
};
#endif

template <typename T, typename _E = void>
struct is_simd_op {
    static constant constexpr bool value = false;
};
template <typename T>
struct is_simd_op<Sum<T>, typename metal::enable_if_t<is_simd_t<T>>> {
    static constant constexpr bool value = true;
};
template <typename T>
struct is_simd_op<Mul<T>, typename metal::enable_if_t<is_simd_t<T>>> {
    static constant constexpr bool value = true;
};
template <typename T>
struct is_simd_op<Min<T>, typename metal::enable_if_t<is_simd_t<T>>> {
    static constant constexpr bool value = true;
};
template <typename T>
struct is_simd_op<Max<T>, typename metal::enable_if_t<is_simd_t<T>>> {
    static constant constexpr bool value = true;
};

// Helper struct for applying operators.
// The overloaded operator() function is used to apply an operator to two values.
template<
    typename OP,
    typename T,
    typename _E = void
>
struct operation;

// Specialization for scalar values.
template<typename OP, typename T>
struct operation<OP, T, typename metal::enable_if_t<is_scalar_v<T>>> {
    OP op;

    METAL_FUNC T operator()(T a, T b) {
        return op(a, b);
    }
    METAL_FUNC T operator()(T a, T b, uint idx) {
        return this->operator()(a, b);
    }
};

// Specialization for vector values.
template<typename OP, typename T, uint N>
struct operation<OP, vec<T, N>> {
    OP op;

    METAL_FUNC vec<T, N> operator()(vec<T, N> a, vec<T, N> b) {
        return op(a, b);
    }
    METAL_FUNC vec<T, N> operator()(vec<T, N> a, vec<T, N> b, uint _idx) {
        return this->operator()(a, b);
    }
    METAL_FUNC vec<T, N> operator()(vec<T, N> a, vec<T, N> b, vec<uint, N> _idx) {
        return this->operator()(a, b);
    }
};

// Specialization for indexed scalar values.
template<typename OP, typename T>
struct operation<OP, indexed<T>, typename metal::enable_if_t<is_scalar_v<T>>> {
    OP op;

    METAL_FUNC indexed<T> operator()(indexed<T> a, indexed<T> b) {
        return op(a, b);
    }
    METAL_FUNC indexed<T> operator()(indexed<T> a, T b, uint idx) {
        return this->operator()(a, indexed<T>{ idx, b });
    }
};

// Specialization for indexed vector values.
template<typename OP, typename T>
struct operation<OP, indexed<vec<T, 2>>> {
    using V = vec<T, 2>;
    OP op;

    METAL_FUNC indexed<V> operator()(indexed<V> a, indexed<V> b) {
        auto x = op(a[0], b[0]);
        auto y = op(a[1], b[1]);
        return indexed<V>{
            uint2 { x.i, y.i },
            V { x.val, y.val }
        };
    }
    METAL_FUNC indexed<V> operator()(indexed<V> a, V b, uint idx) {
        auto x = op(a[0], indexed<T>{idx,   b[0]});
        auto y = op(a[1], indexed<T>{idx+1, b[1]});
        return indexed<V>{
            uint2 { x.i, y.i },
            V { x.val, y.val }
        };
    }

    METAL_FUNC indexed<V> operator()(indexed<V> a, V b, uint2 indices) {
        auto x = op(a[0], indexed<T>{indices[0], b[0]});
        auto y = op(a[1], indexed<T>{indices[1], b[1]});
        return indexed<V>{
            uint2 { x.i, y.i },
            V { x.val, y.val }
        };
    }
};
template<typename OP, typename T>
struct operation<OP, indexed<vec<T, 4>>> {
    using V = vec<T, 4>;
    OP op;

    METAL_FUNC indexed<V> operator()(indexed<V> a, indexed<V> b) {
        indexed<T> x = op(a[0], b[0]);
        indexed<T> y = op(a[1], b[1]);
        indexed<T> z = op(a[2], b[2]);
        indexed<T> w = op(a[3], b[3]);
        return indexed<V>{
            uint4 { x.i, y.i, z.i, w.i },
            V { x.val, y.val, z.val, w.val }
        };
    }
    METAL_FUNC indexed<V> operator()(indexed<V> a, V b, uint idx) {
        indexed<T> x = op(a[0], indexed<T>{ idx,   b[0] });
        indexed<T> y = op(a[1], indexed<T>{ idx+1, b[1] });
        indexed<T> z = op(a[2], indexed<T>{ idx+2, b[2] });
        indexed<T> w = op(a[3], indexed<T>{ idx+3, b[3] });
        return indexed<V>{
            uint4 { x.i, y.i, z.i, w.i },
            V { x.val, y.val, z.val, w.val }
        };
    }

    METAL_FUNC indexed<V> operator()(indexed<V> a, V b, uint4 indices) {
        indexed<T> x = op(a[0], indexed<T>{ indices[0], b[0] });
        indexed<T> y = op(a[1], indexed<T>{ indices[1], b[1] });
        indexed<T> z = op(a[2], indexed<T>{ indices[2], b[2] });
        indexed<T> w = op(a[3], indexed<T>{ indices[3], b[3] });
        return indexed<V>{
            uint4 { x.i, y.i, z.i, w.i },
            V { x.val, y.val, z.val, w.val }
        };
    }
};

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC indexed<T> to_scalar(indexed<T> value) {
    return value;
}

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC indexed<T> to_scalar(indexed<vec<T, 2>> v) {
    OP op;
    return op(v[0], v[1]);
}

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC indexed<T> to_scalar(indexed<vec<T, 4>> v) {
    OP op;
    return op(op(v[0], v[1]), op(v[2], v[3]));
}

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC T to_scalar(T value) {
    return value;
}

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC T to_scalar(vec<T, 2> v) {
    OP op;
    return op(v.x, v.y);
}

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC T to_scalar(vec<T, 4> v) {
    OP op;
    return op(op(v.x, v.y), op(v.z, v.w));
}

// Load elements from global memory into shared memory.
// Handles both indexed and non-indexed types by using operate.
template<
    typename T,
    typename R,
    typename OP,
    ushort BLOCKSIZE,
    bool STRIDED = false,
    typename _E = void
>
struct loader;

template<
    typename T,
    typename R,
    typename OP,
    ushort BLOCKSIZE
>
struct loader<T, R, OP, BLOCKSIZE> {
    operation<OP, R> operate;

    METAL_FUNC R operator()(
        R value,
        constant uint &src_numel,
        constant ushort &el_per_block,
        constant T *src,
        const uint offset,
        const ushort tid
    ) {
        constexpr uint G = granularity<T>();

        const uint thread_id = tid + (offset / G);
        const uint stop_idx = min(el_per_block + offset, src_numel) / G;

        #pragma clang loop unroll(full)
        for (uint i = thread_id; i < stop_idx; i += BLOCKSIZE) {
            value = operate(value, src[i], (i * G));
        }
        return value;
    }

    METAL_FUNC R operator()(
        R value,
        constant uint &src_numel,
        constant size_t *dims,
        constant size_t *strides,
        constant ushort &el_per_block,
        constant T *src,
        const uint offset,
        const ushort tid
    ) {
        return this->operator()(value, src_numel, el_per_block, src, offset, tid);
    }
};

template<
    typename T,
    typename R,
    typename OP,
    ushort BLOCKSIZE
>
struct loader<T, R, OP, BLOCKSIZE, true, typename metal::enable_if_t<is_scalar_v<T>>> {
    operation<OP, R> operate;

    METAL_FUNC R operator()(
        R value,
        constant uint &src_numel,
        constant size_t *dims,
        constant size_t *strides,
        constant ushort &el_per_block,
        constant T *src,
        const uint offset,
        const ushort tid
    ) {
        const uint thread_id = tid + offset;
        const uint stop_idx = el_per_block + offset;

        #pragma clang loop unroll(full)
        for (uint i = thread_id; i < stop_idx; i += BLOCKSIZE) {
            value = operate(value, src[get_strided_index(i, src_numel, dims, strides)], i);
        }
        return value;
    }
};

template <typename T, uint N>
METAL_FUNC vec<T, N> to_vec(array<T, N> arr) {
    vec<T, N> v;
    #pragma clang loop unroll(full)
    for (uint i = 0; i < N; i++) {
        v[i] = arr[i];
    }
    return v;
}

template<
    typename T,
    typename R,
    typename OP,
    ushort BLOCKSIZE,
    uint N
>
struct loader<vec<T, N>, R, OP, BLOCKSIZE, true> {
    operation<OP, R> operate;

    METAL_FUNC R operator()(
        R value,
        constant uint &src_numel,
        constant size_t *dims,
        constant size_t *strides,
        constant ushort &el_per_block,
        constant vec<T, N> *src,
        const uint offset,
        const ushort tid
    ) {
        // Reinterpret src as device T* to allow for strided access.
        constant T *__restrict in = reinterpret_cast<constant T *__restrict>(src);
        array<T, N> values;
        array<uint, N> indices;

        const uint thread_id = tid + (offset / N);
        const uint stop_idx = (el_per_block + offset) / N;

        #pragma clang loop unroll(full)
        for (uint i = thread_id; i < stop_idx; i += BLOCKSIZE) {

            #pragma clang loop unroll(full)
            for (uint j = 0; j < N; j++) {
                indices[j] = i + j;
                values[j] = in[get_strided_index(i + j, src_numel, dims, strides)];
            }
            value = operate(value, to_vec<T, N>(values), to_vec<uint, N>(indices));
        }

        return value;
    }
};

template<
    typename OP,
    ushort BLOCKSIZE,
    typename T,
    typename _E = void
>
struct simdgroup_reducer;

// Specialization for built-in simd operations.
template<typename OP, ushort BLOCKSIZE, typename T>
struct simdgroup_reducer<OP, BLOCKSIZE, T, typename metal::enable_if_t<is_simd_op<OP>::value && is_valid_simd_t<T>>> {
    METAL_FUNC T operator()(T value) {
        return OP::simd_op(value);
    }
    METAL_FUNC T operator()(threadgroup T shared[BLOCKSIZE], const ushort tid) {
        return this->operator()(shared[tid]);
    }
};

// Specialization for custom (non-built-in) simd operations.
template<typename OP, ushort BLOCKSIZE, typename T>
struct simdgroup_reducer<OP, BLOCKSIZE, T, typename metal::enable_if_t<!is_simd_op<OP>::value && is_valid_simd_t<T>>> {
    operation<OP, T> operate;

    METAL_FUNC T operator()(T value) {
        if (BLOCKSIZE >= 32) value = operate(value, simd_shuffle_down(value, 16));
        if (BLOCKSIZE >= 16) value = operate(value, simd_shuffle_down(value,  8));
        if (BLOCKSIZE >=  8) value = operate(value, simd_shuffle_down(value,  4));
        if (BLOCKSIZE >=  4) value = operate(value, simd_shuffle_down(value,  2));
        if (BLOCKSIZE >=  2) value = operate(value, simd_shuffle_down(value,  1));
        return value;
    }
    METAL_FUNC T operator()(threadgroup T shared[BLOCKSIZE], const ushort tid) {
        return this->operator()(shared[tid]);
    }
};

// Specialization for non-simd types.
//template<typename OP, ushort BLOCKSIZE, typename T>
//struct simdgroup_reducer<OP, BLOCKSIZE, T, typename metal::enable_if_t<!is_valid_simd_t<T>>> {
//    operation<OP, T> operate;
//
//    METAL_FUNC T operator()(
//        volatile threadgroup T shared[BLOCKSIZE],
//        const ushort tid
//    ) {
//        T value = shared[tid];
//        if (BLOCKSIZE >= 32) value = operate(value, shared[tid + 16]);
//        if (BLOCKSIZE >= 16) value = operate(value, shared[tid +  8]);
//        if (BLOCKSIZE >=  8) value = operate(value, shared[tid +  4]);
//        if (BLOCKSIZE >=  4) value = operate(value, shared[tid +  2]);
//        if (BLOCKSIZE >=  2) value = operate(value, shared[tid +  1]);
//        return value;
//    }
//    METAL_FUNC T operator()(T value) {
//        return value;
//    }
//};

template<typename T, typename OP, ushort BLOCKSIZE>
struct block_reducer {
    simdgroup_reducer<OP, BLOCKSIZE, T> simd_reduce;
    operation<OP, T> operate;
    threadgroup T *shared;

    block_reducer(threadgroup T shared[BLOCKSIZE]) {
        this->shared = shared;
    }

    METAL_FUNC T operator()(T value, const ushort tid) {
        if (BLOCKSIZE >= 64) {
            // Only store in threadgroup shared memory if needed.
            shared[tid] = value;
            // Threadgroup barrier is needed to ensure that all threads have written to shared memory
            threadgroup_barrier(mem_flags::mem_none);
        }

        #pragma clang loop unroll(full)
        for (ushort s = BLOCKSIZE / 2; s >= 64; s >>= 1) {
            if (tid < s) shared[tid] = operate(shared[tid], shared[tid + s]);
            threadgroup_barrier(mem_flags::mem_none);
        }
        if (tid < 32) {
            // Last shared memory reduce can be done without tid < s check.
            if (BLOCKSIZE >= 64) {
                value = operate(shared[tid], shared[tid + 32]);
                simdgroup_barrier(mem_flags::mem_none);
            }
            // Remaining 32 threads can be reduced with simdgroup_reduce.
            value = simd_reduce(value);
        }

        return value;
    }
};

// Inspired by "Optimizing Parallel Reduction in CUDA" by Mark Harris
template<
    typename T,
    typename R,
    typename ReductionOp,
    ushort BLOCKSIZE,
    bool STRIDED = false
>
METAL_FUNC void reduce(
    constant uint &num_dims,
    constant size_t *dims,
    constant size_t *strides,
    constant ushort &el_per_block,
    constant T *src,
    device make_scalar_t<R> *dst,
    threadgroup make_scalar_t<R> shared[BLOCKSIZE],
    uint tid [[ thread_index_in_threadgroup ]],
    uint dst_id [[ threadgroup_position_in_grid ]]
) {
    using ST = make_scalar_t<T>;
    using SR = make_scalar_t<R>;

    loader<T, R, ReductionOp, BLOCKSIZE, STRIDED> load;
    block_reducer<ST, ReductionOp, BLOCKSIZE> block_reduce(shared);

    // Initialize shared memory for current thread to correct value for reduction operation
    shared[tid] = ReductionOp::init();

    // Calcluate offset for the threadgroup of current thread;
    const uint offset = dst_id * el_per_block;

    // Load with reduction from global memory into shared memory
    R value = R(ReductionOp::init());
    value = load(
        value,
        num_dims,
        dims,
        strides,
        el_per_block,
        src,
        offset,
        tid
    );

    // Complete reduction
    SR result =  block_reduce(to_scalar<ReductionOp>(value), tid);

    if (tid == 0) dst[dst_id] = result;
}

#define reduce_case(OP, T, R, N)                        \
case N: {                                               \
    threadgroup make_scalar_t<R> shared[N];             \
    reduce<T, R, OP<make_scalar_t<R>>, N, STRIDED>(     \
        num_dims,                                       \
        dims,                                           \
        strides,                                        \
        el_per_block,                                   \
        src,                                            \
        dst,                                            \
        shared,                                         \
        tid,                                            \
        dst_id);                                        \
    break;                                              \
}

#define ARG(...) __VA_ARGS__

#define impl_reduce_inner(OP, NAME, T)                  \
kernel void NAME(                                       \
    constant uint &num_dims,                            \
    constant ushort &el_per_block,                      \
    constant T *src,                                    \
    device make_scalar_t<T> *dst,                       \
    ushort tid [[ thread_index_in_threadgroup ]],       \
    ushort dst_id [[ threadgroup_position_in_grid ]],   \
    ushort block_dim [[ threads_per_threadgroup ]]      \
) {                                                     \
    constant size_t *dims = {};                         \
    constant size_t *strides = {};                      \
    const bool STRIDED = false;                         \
    switch (max_shared_mem<T>(block_dim)) {             \
        reduce_case(OP, ARG(T), ARG(T), 2048);          \
        reduce_case(OP, ARG(T), ARG(T), 1024);          \
        reduce_case(OP, ARG(T), ARG(T),  512);          \
        reduce_case(OP, ARG(T), ARG(T),  256);          \
        reduce_case(OP, ARG(T), ARG(T),  128);          \
        reduce_case(OP, ARG(T), ARG(T),   64);          \
        reduce_case(OP, ARG(T), ARG(T),   32);          \
        reduce_case(OP, ARG(T), ARG(T),   16);          \
        reduce_case(OP, ARG(T), ARG(T),    8);          \
        reduce_case(OP, ARG(T), ARG(T),    4);          \
        reduce_case(OP, ARG(T), ARG(T),    2);          \
        reduce_case(OP, ARG(T), ARG(T),    1);          \
    }                                                   \
}

#define impl_reduce_strided(OP, NAME, T, NAME_SUFFIX)   \
kernel void NAME##_strided##NAME_SUFFIX(                \
    constant uint &num_dims,                            \
    constant size_t *dims,                              \
    constant size_t *strides,                           \
    constant ushort &el_per_block,                      \
    constant T *src,                                    \
    device make_scalar_t<T> *dst,                       \
    ushort tid [[ thread_index_in_threadgroup ]],       \
    ushort dst_id [[ threadgroup_position_in_grid ]],   \
    ushort block_dim [[ threads_per_threadgroup ]]      \
) {                                                     \
    const bool STRIDED = true;                          \
    switch (max_shared_mem<T>(block_dim)) {             \
        reduce_case(OP, ARG(T), ARG(T), 2048);          \
        reduce_case(OP, ARG(T), ARG(T), 1024);          \
        reduce_case(OP, ARG(T), ARG(T),  512);          \
        reduce_case(OP, ARG(T), ARG(T),  256);          \
        reduce_case(OP, ARG(T), ARG(T),  128);          \
        reduce_case(OP, ARG(T), ARG(T),   64);          \
        reduce_case(OP, ARG(T), ARG(T),   32);          \
        reduce_case(OP, ARG(T), ARG(T),   16);          \
        reduce_case(OP, ARG(T), ARG(T),    8);          \
        reduce_case(OP, ARG(T), ARG(T),    4);          \
        reduce_case(OP, ARG(T), ARG(T),    2);          \
        reduce_case(OP, ARG(T), ARG(T),    1);          \
    }                                                   \
}

#define impl_reduce(OP, NAME, T)                    \
impl_reduce_inner(OP, NAME, T)                      \
impl_reduce_inner(OP, NAME##x2, ARG(vec<T, 2>))     \
impl_reduce_inner(OP, NAME##x4, ARG(vec<T, 4>))     \
impl_reduce_strided(OP, NAME, T, )                  \
impl_reduce_strided(OP, NAME, ARG(vec<T, 2>), x2)   \
impl_reduce_strided(OP, NAME, ARG(vec<T, 4>), x4)

template<
    typename T,
    typename ReductionOp,
    ushort BLOCKSIZE,
    bool STRIDED
>
METAL_FUNC void reduce(
    constant uint &num_dims,
    constant size_t *dims,
    constant size_t *strides,
    constant ushort &el_per_block,
    constant T *src,
    device uint *dst,
    threadgroup indexed<make_scalar_t<T>> shared[BLOCKSIZE],
    ushort tid [[ thread_index_in_threadgroup ]],
    ushort dst_id [[ threadgroup_position_in_grid ]]
) {
    using I = indexed<make_scalar_t<T>>;
    loader<T, indexed<T>, ReductionOp, BLOCKSIZE, STRIDED> load;
    block_reducer<I, ReductionOp, BLOCKSIZE> block_reduce(shared);

    // Initialize shared memory for current thread to correct value for reduction operation
    shared[tid] = ReductionOp::init();

    // Calcluate offset for the threadgroup of current thread
    const uint offset = dst_id * el_per_block;

    // Load with reduction from global memory into shared memory
    indexed<T> value = indexed<T>{ 0, ReductionOp::init().val };
    value = load(
        value,
        num_dims,
        dims,
        strides,
        el_per_block,
        src,
        offset,
        tid
    );

    // Complete reduction
    I result =  block_reduce(to_scalar<ReductionOp>(value), tid);

    // Return index of reduce result
    if (tid == 0) dst[dst_id] = result.i;
}

#define arg_reduce_case(OP, N, T)                       \
case N: {                                               \
    using I = indexed<make_scalar_t<T>>;                \
    threadgroup I shared[N];                            \
    reduce<T, OP<I>, N, STRIDED>(                       \
        num_dims,                                       \
        dims,                                           \
        strides,                                        \
        el_per_block,                                   \
        src,                                            \
        dst,                                            \
        shared,                                         \
        tid,                                            \
        dst_id);                                        \
    break;                                              \
}

#define impl_arg_reduce_inner(OP, NAME, T, NAME_SUFFIX) \
kernel void NAME##NAME_SUFFIX(                          \
    constant uint &num_dims,                            \
    constant ushort &el_per_block,                      \
    constant T *src,                                    \
    device uint *dst,                                   \
    ushort tid [[ thread_index_in_threadgroup ]],       \
    ushort dst_id [[ threadgroup_position_in_grid ]],   \
    ushort block_dim [[ threads_per_threadgroup ]]      \
) {                                                     \
    constant size_t *dims = {};                         \
    constant size_t *strides = {};                      \
    const bool STRIDED = false;                         \
    switch (max_shared_mem<indexed<T>>(block_dim)) {    \
        arg_reduce_case(OP,  1024, ARG(T));             \
        arg_reduce_case(OP,  512, ARG(T));              \
        arg_reduce_case(OP,  256, ARG(T));              \
        arg_reduce_case(OP,  128, ARG(T));              \
        arg_reduce_case(OP,   64, ARG(T));              \
        arg_reduce_case(OP,   32, ARG(T));              \
        arg_reduce_case(OP,   16, ARG(T));              \
        arg_reduce_case(OP,    8, ARG(T));              \
        arg_reduce_case(OP,    4, ARG(T));              \
        arg_reduce_case(OP,    2, ARG(T));              \
        arg_reduce_case(OP,    1, ARG(T));              \
    }                                                   \
}                                                       \
kernel void NAME##_strided##NAME_SUFFIX(                \
    constant uint &num_dims,                            \
    constant size_t *dims,                              \
    constant size_t *strides,                           \
    constant ushort &el_per_block,                      \
    constant T *src,                                    \
    device uint *dst,                                   \
    ushort tid [[ thread_index_in_threadgroup ]],       \
    ushort dst_id [[ threadgroup_position_in_grid ]],   \
    ushort block_dim [[ threads_per_threadgroup ]]      \
) {                                                     \
    const bool STRIDED = true;                          \
    switch (max_shared_mem<indexed<T>>(block_dim)) {    \
        arg_reduce_case(OP,  1024, ARG(T));             \
        arg_reduce_case(OP,  512, ARG(T));              \
        arg_reduce_case(OP,  256, ARG(T));              \
        arg_reduce_case(OP,  128, ARG(T));              \
        arg_reduce_case(OP,   64, ARG(T));              \
        arg_reduce_case(OP,   32, ARG(T));              \
        arg_reduce_case(OP,   16, ARG(T));              \
        arg_reduce_case(OP,    8, ARG(T));              \
        arg_reduce_case(OP,    4, ARG(T));              \
        arg_reduce_case(OP,    2, ARG(T));              \
        arg_reduce_case(OP,    1, ARG(T));              \
    }                                                   \
}


#define impl_arg_reduce(OP, NAME, T)                    \
impl_arg_reduce_inner(OP, NAME, T, )                    \
impl_arg_reduce_inner(OP, NAME, ARG(vec<T, 2>), x2)     \
impl_arg_reduce_inner(OP, NAME, ARG(vec<T, 4>), x4)

// Contains the intermediate results for the online softmax calculation.
// m: max
// d: sum of the exponentials
template <typename T>
struct MD {
    T m;
    T d;

    constexpr MD<T>() = default;
    constexpr MD<T>() threadgroup = default;

    static constant constexpr uint N = vec_elements<T>::value;

    // Return 1-dimensional MD
    constexpr MD<make_scalar_t<T>> operator[](uint n) {
        assert(n < N);
        return MD<make_scalar_t<T>>{ m[n], d[n] };
    }
};

// Enable operations for softmax MD
template<typename OP, typename T>
struct operation<OP, MD<T>, typename metal::enable_if_t<is_scalar_v<T>>> {
    OP op;

    METAL_FUNC MD<T> operator()(MD<T> a, MD<T> b) {
        return op(a, b);
    }
    METAL_FUNC MD<T> operator()(MD<T> a, T b, uint _idx) {
        return this->operator()(a, MD<T>{ b, static_cast<T>(1.0) });
    }
};

template<typename OP, typename T>
struct operation<OP, MD<vec<T, 2>>> {
    using V = vec<T, 2>;
    OP op;

    METAL_FUNC MD<V> operator()(MD<V> a, MD<V> b) {
        MD<T> x = op(a[0], b[0]);
        MD<T> y = op(a[1], b[1]);
        return MD<V>{
            V { x.m, y.m },
            V { x.d, y.d }
        };
    }
    METAL_FUNC MD<V> operator()(MD<V> a, V b, uint _i) {
        return this->operator()(a, MD<V>{ b, V(static_cast<T>(1.0)) });
    }

    METAL_FUNC MD<V> operator()(MD<V> a, V b, uint4 _i) {
        return this->operator()(a, MD<V>{ b, V(static_cast<T>(1.0)) });
    }
};

template<typename OP, typename T>
struct operation<OP, MD<vec<T, 4>>> {
    using V = vec<T, 4>;
    OP op;

    METAL_FUNC MD<V> operator()(MD<V> a, MD<V> b) {
        MD<T> x = op(a[0], b[0]);
        MD<T> y = op(a[1], b[1]);
        MD<T> z = op(a[2], b[2]);
        MD<T> w = op(a[3], b[3]);
        return MD<V>{
            V { x.m, y.m, z.m, w.m },
            V { x.d, y.d, z.d, w.d }
        };
    }
    METAL_FUNC MD<V> operator()(MD<V> a, V b, uint _i) {
        return this->operator()(a, MD<V>{ b, V(static_cast<T>(1.0)) });
    }

    METAL_FUNC MD<V> operator()(MD<V> a, V b, uint4 _i) {
        return this->operator()(a, MD<V>{ b, V(static_cast<T>(1.0)) });
    }
};

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC MD<T> to_scalar(MD<T> value) {
    return value;
}

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC MD<T> to_scalar(MD<vec<T, 2>> v) {
    OP op;
    return op(v[0], v[1]);
}

template<typename OP, typename T, typename _E = typename metal::enable_if_t<is_scalar_v<T>>>
METAL_FUNC MD<T> to_scalar(MD<vec<T, 4>> v) {
    OP op;
    return op(op(v[0], v[1]), op(v[2], v[3]));
}

template <typename T>
METAL_FUNC MD<T> simd_shuffle_down(MD<T> md, ushort delta) {
    return MD<T> {
        simd_shuffle_down(md.m, delta),
        simd_shuffle_down(md.d, delta)
    };
}

// Enable simd_shuffle_down for softmax MD
template <typename T>
struct is_valid_simd_type<MD<T>, typename metal::enable_if_t<is_valid_simd_t<T>>> {
    static constant constexpr bool value = true;
};

template<typename T>
struct MDReduceOp {
    Exp fast_exp;

    static constexpr METAL_FUNC MD<T> init() {
        return MD<T>{ numeric_limits<T>::lowest(), 0 };
    }

    METAL_FUNC MD<T> operator()(MD<T> a, MD<T> b) {
        bool a_bigger = a.m > b.m;
        MD<T> bigger_m = a_bigger ? a : b;
        MD<T> smaller_m = a_bigger ? b : a;
        MD<T> res;
        res.d = bigger_m.d + smaller_m.d * fast_exp(smaller_m.m - bigger_m.m);
        res.m = bigger_m.m;
        return res;
    }
};

template<
    typename T,
    ushort BLOCKSIZE,
    typename _E = void
>
struct finalize_softmax;

template<typename T, ushort BLOCKSIZE>
struct finalize_softmax<T, BLOCKSIZE, typename metal::enable_if_t<is_scalar_v<T>>> {
    Divide fast_divide;
    Exp fast_exp;

    METAL_FUNC void operator()(
        constant T *src,
        device T *dst,
        threadgroup MD<T> &md_total,
        const uint thread_id,
        const uint stop_idx
    ) {
        const T d_total_inverse = fast_divide(static_cast<T>(1.0), md_total.d);
        for (uint idx = thread_id; idx < stop_idx; idx += BLOCKSIZE) {
            dst[idx] = fast_exp(src[idx] - md_total.m) * d_total_inverse;
        }
    }
};


template<typename T, ushort BLOCKSIZE>
struct finalize_softmax<T, BLOCKSIZE, typename metal::enable_if_t<is_vector_v<T>>> {
    using ST = make_scalar_t<T>;
    Divide fast_divide;
    Exp fast_exp;

    METAL_FUNC void operator()(
        constant T *src,
        device ST *dst,
        threadgroup MD<ST> &md_total,
        const uint thread_id,
        const uint stop_idx
    ) {
        constant ST *__restrict in = reinterpret_cast<constant ST *__restrict>(src);
        const ST d_total_inverse = fast_divide(static_cast<ST>(1.0), md_total.d);

        #pragma clang loop unroll(full)
        for (uint idx = thread_id; idx < stop_idx; idx += BLOCKSIZE) {
            dst[idx] = fast_exp(in[idx] - md_total.m) * d_total_inverse;
        }
    }
};

// Welford's algorithm approach for an online softmax implementation.
// Same as the Online normalizer calculation for softmax: https://arxiv.org/pdf/1805.02867.pdf
template<typename T, ushort BLOCKSIZE>
METAL_FUNC void softmax(
    constant uint &src_numel,
    constant ushort &el_per_block,
    constant T *src,
    device make_scalar_t<T> *dst,
    threadgroup MD<make_scalar_t<T>> shared[BLOCKSIZE],
    threadgroup MD<make_scalar_t<T>> &md_total,

    ushort tid [[ thread_index_in_threadgroup ]],
    ushort dst_id [[ threadgroup_position_in_grid ]]
) {
    using ST = make_scalar_t<T>;
    using MDReduceOp = MDReduceOp<ST>;

    loader<T, MD<T>, MDReduceOp, BLOCKSIZE> load;
    block_reducer<MD<ST>, MDReduceOp, BLOCKSIZE> block_reduce(shared);
    finalize_softmax<T, BLOCKSIZE> softmax_finalize;

    // Calcluate offset for the threadgroup of current thread;
    const uint offset = dst_id * el_per_block;

    // Calculate partial result for current thread
    MD<T> md_partial = MD<T> { numeric_limits<T>::lowest(), 0 };
    md_partial = load(
        md_partial,
        src_numel,
        el_per_block,
        src,
        offset,
        tid
    );

    // Reduce in shared memory
    MD<ST> md = block_reduce(to_scalar<MDReduceOp>(md_partial), tid);

    if (tid == 0) md_total = md;
    threadgroup_barrier(mem_flags::mem_none);

    // Finalize softmax
    const uint thread_id = tid + offset;
    const uint stop_idx = min(el_per_block + offset, src_numel);
    softmax_finalize(src, dst, md_total, thread_id, stop_idx);
}

#define softmax_case(T, N)                              \
case N: {                                               \
    using SMDT = MD<make_scalar_t<T>>;                  \
    threadgroup SMDT shared[N];                         \
    threadgroup SMDT md_total;                          \
    softmax<T, N>(                                      \
        src_numel,                                      \
        el_per_block,                                   \
        src,                                            \
        dst,                                            \
        shared,                                         \
        md_total,                                       \
        tid,                                            \
        dst_id);                                        \
    break;                                              \
}

#define impl_softmax_inner(NAME, T)                     \
kernel void NAME(                                       \
    constant uint &src_numel,                           \
    constant ushort &el_per_block,                      \
    constant T *src,                                    \
    device make_scalar_t<T> *dst,                       \
                                                        \
    ushort tid [[ thread_index_in_threadgroup ]],       \
    ushort dst_id [[ threadgroup_position_in_grid ]],   \
    ushort block_dim [[ threads_per_threadgroup ]]      \
) {                                                     \
    switch (max_shared_mem<T>(block_dim)) {             \
        softmax_case(T, 1024);                          \
        softmax_case(T,  512);                          \
        softmax_case(T,  256);                          \
        softmax_case(T,  128);                          \
        softmax_case(T,   64);                          \
        softmax_case(T,   32);                          \
        softmax_case(T,   16);                          \
        softmax_case(T,    8);                          \
        softmax_case(T,    4);                          \
        softmax_case(T,    2);                          \
        softmax_case(T,    1);                          \
    }                                                   \
}

#define impl_softmax(NAME, T)                           \
impl_softmax_inner(NAME, T)                             \
impl_softmax_inner(NAME##x2, T##2)                      \
impl_softmax_inner(NAME##x4, T##4)

impl_reduce(Sum, fast_sum_f32, float)
impl_reduce(Sum, fast_sum_u32, uint)
impl_reduce(Sum, fast_sum_f16, half)
impl_reduce(Sum, fast_sum_u8, uint8_t)

impl_reduce(Mul, fast_mul_f32, float)
impl_reduce(Mul, fast_mul_u32, uint)
impl_reduce(Mul, fast_mul_f16, half)
impl_reduce(Mul, fast_mul_u8, uint8_t)

impl_reduce(Max, fast_max_f32, float)
impl_reduce(Max, fast_max_u32, uint)
impl_reduce(Max, fast_max_f16, half)
impl_reduce(Max, fast_max_u8, uint8_t)

impl_reduce(Min, fast_min_f32, float)
impl_reduce(Min, fast_min_u32, uint)
impl_reduce(Min, fast_min_f16, half)
impl_reduce(Min, fast_min_u8, uint8_t)

impl_arg_reduce(Min, fast_argmin_f32, float)
impl_arg_reduce(Min, fast_argmin_f16, half)
impl_arg_reduce(Min, fast_argmin_u32, uint)
impl_arg_reduce(Min, fast_argmin_u8, uint8_t)

impl_arg_reduce(Max, fast_argmax_f32, float)
impl_arg_reduce(Max, fast_argmax_f16, half)
impl_arg_reduce(Max, fast_argmax_u32, uint)
impl_arg_reduce(Max, fast_argmax_u8, uint8_t)

impl_softmax(softmax_f32, float)
impl_softmax(softmax_f16, half)

#if __METAL_VERSION__ >= 220
impl_reduce(Sum, fast_sum_i64, int64_t)
impl_reduce(Mul, fast_mul_i64, int64_t)
impl_reduce(Min, fast_min_i64, int64_t)
impl_reduce(Max, fast_max_i64, int64_t)

impl_arg_reduce(Min, fast_argmin_i64, int64_t)
impl_arg_reduce(Max, fast_argmax_i64, int64_t)
#endif

#if defined(__HAVE_BFLOAT__)
impl_reduce(Sum, fast_sum_bf16, bfloat)
impl_reduce(Mul, fast_mul_bf16, bfloat)
impl_reduce(Max, fast_max_bf16, bfloat)
impl_reduce(Min, fast_min_bf16, bfloat)

impl_arg_reduce(Min, fast_argmin_bf16, bfloat)
impl_arg_reduce(Max, fast_argmax_bf16, bfloat)

impl_softmax(softmax_bf16, bfloat)
#endif
