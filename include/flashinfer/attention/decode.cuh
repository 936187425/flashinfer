/*
 * Copyright (c) 2023 by FlashInfer team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#ifndef FLASHINFER_DECODE_CUH_
#define FLASHINFER_DECODE_CUH_
#include <cooperative_groups.h>
#include <cuda_bf16.h>
#include <cuda_fp16.h>

#include <cstddef>
#ifdef FLASHINFER_ENABLE_FP8
#include <cuda_fp8.h>
#endif
#include <cuda_runtime.h>

#include <cuda/pipeline>
#include <iostream>
#include <optional>
#include <random>

#include "../cp_async.cuh"
#include "../layout.cuh"
#include "../math.cuh"
#include "../page.cuh"
#include "../pos_enc.cuh"
#include "../utils.cuh"
#include "../vec_dtypes.cuh"
#include "cascade.cuh"
#include "logits_post_hook.cuh"
#include "state.cuh"

namespace flashinfer {

namespace cg = cooperative_groups;
using cp_async::PrefetchMode;
using cp_async::SharedMemFillMode;

namespace {

/*!
 * \brief Load k tile from smem and compute qk
 * \tparam logits_post_hook The logits post hook used in the kernel
 * \tparam pos_encoding_mode The positional encoding mode used in the kernel
 * \tparam head_dim A template integer indicates the head dimension
 * \tparam vec_size A template integer indicates the vector size
 * \tparam bdx A template integer indicates the block size in x dimension
 * \tparam tile_size A template integer indicates the tile size per (bdx * bdy) threads.
 * \tparam T A template type indicates the input data type
 * \param smem A pointer to the start of shared memory
 * \param q_vec A vector of float indicates the thread-local query vector
 * \param freq A vector of float indicates the thread-local rope frequency
 * \param kv_shared_offset An array of uint32_t indicates the k/v tiles offset
 *   in shared memory of different pipeline stages
 * \param kv_idx A integer indicates the thread-local kv position in kv-cache
 * \param compute_stage_idx A integer indicates the compute stage index in the pipeline
 * \param sm_scale A float indicates the scale applied to pre-softmax logits
 * \param s A float indicates the thread-local result of qk
 * \param st The self-attention state to be updated
 */
template <LogitsPostHook logits_post_hook, PosEncodingMode pos_encoding_mode, uint32_t vec_size,
          uint32_t bdx, uint32_t tile_size, typename T> //tile_size=tile_size_per_bdx*bdy. (bdy是group size)
__device__ __forceinline__ void compute_qk(const T* smem, uint32_t compute_stage_idx,
                                           const vec_t<float, vec_size>& q_vec,
                                           const vec_t<float, vec_size>& freq, uint32_t kv_idx_base,
                                           uint32_t iter_base, uint32_t iter_bound,
                                           const int32_t q_offset, float alibi_slope, float* s,
                                           state_t<vec_size>& st, const float logits_soft_cap) {
  uint32_t tx = threadIdx.x, tz = threadIdx.z; // tx:lane_id; tz:replication id 
  float m_prev = st.m; 
// q: q_vec , k: smem[0:vec_size]
#pragma unroll
  for (uint32_t j = 0; j < tile_size; ++j) {   //TODO: tile_size_per_bdx*bdy(其实一个warp会去计算) TODO:这里为什么是tile_size_per_bdx*bdy而不是tile_size_per_bdx？
                                               //我感觉这里是一个bug,
    vec_t<float, vec_size> k_vec;
    if constexpr (pos_encoding_mode == PosEncodingMode::kRoPELlama) {
      // apply rotary embedding for all rows in k matrix of kv-cache
      k_vec = vec_apply_llama_rope<vec_size, bdx>(smem + j * bdx * vec_size, freq,
                                                  kv_idx_base + tz * tile_size + j);
    } else {
      // do not apply rotary embedding
      
      k_vec.cast_load(smem + (j * bdx + tx) * vec_size);
    }
    s[j] = 0.f; //qk的向量得分,是一个scalar.
#pragma unroll
    for (uint32_t i = 0; i < vec_size; ++i) {
      s[j] += q_vec[i] * k_vec[i]; //这个是用CUDA Core计算的两个向量乘积的写法
    }
#pragma unroll
    for (uint32_t offset = bdx / 2; offset > 0; offset /= 2) {
      s[j] += math::shfl_xor_sync(s[j], offset);
    }//math::shfl_xor_sync是一个warp level primitives,即把一个warp中传入的寄存器s[j]进行求最大值，并把一个warp中的最大值返回给s[j]寄存器中.
    s[j] = (iter_base + tz * tile_size + j < iter_bound) ? s[j] : -5e4;
    s[j] = apply_logits_post_hook<logits_post_hook>(s[j], logits_soft_cap);
    if constexpr (pos_encoding_mode == PosEncodingMode::kALiBi) {
      s[j] += alibi_slope * float(int(kv_idx_base + tz * tile_size + j) - q_offset);
    }
    st.m = max(st.m, s[j]); 
  }//此时就计算出一个q与tile_size个k token向量乘结果的最大值.

  float o_scale = math::ptx_exp2(m_prev - st.m);
  st.d *= o_scale; 
#pragma unroll
  for (uint32_t j = 0; j < tile_size; ++j) {
    s[j] = math::ptx_exp2(s[j] - st.m);
    st.d += s[j]; //更新st.d:一共有两部,更新之前算的d(即line:111),然后再加上现在算的.
  }
#pragma unroll
  for (uint32_t i = 0; i < vec_size; ++i) {
    st.o[i] = st.o[i] * o_scale;
  }
}

/*!
 * \brief Load v tile from shared memory and update local state
 * \tparam vec_size A template integer indicates the vector size
 * \tparam bdx A template integer indicates the block size in x dimension
 * \tparam tile_size A template integer indicates the tile size per (bdx * bdy) threads.
 * \tparam T A template type indicates the input data type
 * \param smem A pointer to the start of shared memory
 * \param s A float indicates the pre-softmax attention score
 * \param kv_shared_offset An array of uint32_t indicates the k/v tiles offset
 * in shared memory of different pipeline stages
 * \param compute_stage_idx A integer indicates the compute stage index in the pipeline
 * \param st The flashattention state to be updated
 */
template <uint32_t vec_size, uint32_t bdx, uint32_t tile_size, typename T>
__device__ __forceinline__ void update_local_state(const T* smem, const float* s,
                                                   uint32_t compute_stage_idx,
                                                   state_t<vec_size>& st) {
  uint32_t tx = threadIdx.x; //tx: lane id
#pragma unroll
  for (uint32_t j = 0; j < tile_size; ++j) {
    vec_t<float, vec_size> v_vec;
    v_vec.cast_load(smem + (j * bdx + tx) * vec_size); // v从shared memory->global memory中
#pragma unroll
    for (uint32_t i = 0; i < vec_size; ++i) {//每个线程只更新o[0:head_dim]中vec_size个元素
      st.o[i] = st.o[i] + s[j] * v_vec[i]; //CUDA Core的方式。 s[j]的计算是在compute_qk device function完成的.
    }
  }
}

/*!
 * \brief Synchronize the state of all warps inside a threadblock.
 * \tparam vec_size A template integer indicates the vector size
 * \tparam bdx A template integer indicates the block size in x dimension
 * \tparam bdy A template integer indicates the block size in y dimension
 * \param st The warp local state
 * \param smem The pointer to shared memory buffer for o
 * \param smem_md The pointer to shared memory buffer for m/d
 */
template <uint32_t vec_size, uint32_t bdx, uint32_t bdy, uint32_t bdz>
__device__ __forceinline__ void sync_state(state_t<vec_size>& st, float* smem, float* smem_md) {
  if constexpr (bdz > 1) { //bdz>1时那么replication warp compute qk都只是计算一部分的q head. 因此需要把计算同一个q head的warp之间汇总md值.
    constexpr uint32_t head_dim = bdx * vec_size; //head_dim=bdx*vec_size
    auto block = cg::this_thread_block();
    uint32_t tx = threadIdx.x, ty = threadIdx.y, tz = threadIdx.z; //tx: thread id; ty: group id; tz:replication id
    st.o.store(smem + (tz * bdy + ty) * head_dim + tx * vec_size);
    smem_md[(tz * bdy + ty) * 2] = st.m;
    smem_md[(tz * bdy + ty) * 2 + 1] = st.d;
    block.sync();
    st.init(); //本质是把 local state 存放到 shared memory
#pragma unroll
    for (uint32_t j = 0; j < bdz; ++j) { //然后遍历bdz个warps 存放到shared memory的local state,然后与自己的local state进行合并.
      float mz = smem_md[(j * bdy + ty) * 2], dz = smem_md[(j * bdy + ty) * 2 + 1];
      vec_t<float, vec_size> oz;
      oz.load(smem + (j * bdy + ty) * head_dim + tx * vec_size);
      st.merge(oz, mz, dz);
    }
  }
}

}  // namespace

/*!
 * \brief FlashAttention decoding cuda kernel with kv-cache for a single request
 * \tparam logits_post_hook The logits post hook used in the kernel
 * \tparam kv_layout The layout of k/v matrices (NHD or HND)
 * \tparam partition_kv Whether to partition kv-cache on sequence length dimension or not
 * \tparam pos_encoding_mode The positional encoding mode
 * \tparam vec_size A template integer indicates the vector size
 * \tparam bdx A template integer indicates the block size in x dimension
 * \tparam bdy A template integer indicates the block size in y dimension
 * \tparam DTypeQ A template type indicates the query data type
 * \tparam DTypeKV A template type indicates the key-value data type
 * \tparam DTypeOut A template type indicates the output data type
 * \param q [num_qo_heads, head_dim] The query matrix
 * \param k [seq_len, num_kv_heads, head_dim] The key matrix in kv-cache
 * \param v [seq_len, num_kv_heads, head_dim] The value matrix in kv-cache
 * \param o [num_qo_heads, head_dim] The output matrix
 * \param info The tensor info of k/v matrices
 * \param sm_scale A float indicates the scale applied to pre-softmax logits
 * \param head_dim A integer indicates the head dimension
 * \param rope_rcp_scale A floating number indicate the reciprocal
 *   of scaling ratio used in PI(Position Interpolation) for RoPE (Rotary
 *   Positional Embeddings)
 * \param rope_rcp_theta A floating number indicate the reciprocal
 *   of "theta" used in RoPE (Rotary Positional Embeddings)
 * \param kv_chunk_size A integer indicates the kv-chunk size
 */
template <LogitsPostHook logits_post_hook, QKVLayout kv_layout, bool partition_kv,
          PosEncodingMode pos_encoding_mode, uint32_t num_stages_smem, uint32_t tile_size_per_bdx,
          uint32_t vec_size, uint32_t bdx, uint32_t bdy, uint32_t bdz, typename DTypeQ, 
          typename DTypeKV, typename DTypeOut>
__global__ void SingleDecodeWithKVCacheKernel(DTypeQ* __restrict__ q, DTypeKV* __restrict__ k, //这个是decode
                                              DTypeKV* __restrict__ v, DTypeOut* __restrict__ o,
                                              float* __restrict__ lse,
                                              tensor_info_t<kv_layout, bdx * vec_size> info,
                                              float logits_soft_cap, float sm_scale,_
                                              float rope_rcp_scale, float rope_rcp_theta,
                                              uint32_t kv_chunk_size) {
  auto block = cg::this_thread_block();
  auto grid = cg::this_grid(); //利用cuda 9.0之后cooperative group的概念,可以获取该线程所在的block和grid的抽象封装,并提供了block和grid层面的sync.
  sm_scale *=
      (logits_post_hook == LogitsPostHook::kNone ? math::log2e : math::ptx_rcp(logits_soft_cap));
  // 我们必须要记住 grid(num_chunks,n_kv_head),block(32,group_size,bdz)及其对应的slide. 在这份代码中num_chunks=1. 32是一个warp的线程数.
  // this code bdx=32,bdy=group_size=n_head/n_kv_head,bdz=k.
  constexpr uint32_t head_dim = bdx * vec_size; //每个head_dim会进行划分，即分配给一个warp中的每个thread.即vec_size=head_dim/bdx.
  uint32_t kv_head_idx = blockIdx.y; //表示该线程处于的kv head id号
  uint32_t qo_head_idx = kv_head_idx * bdy + threadIdx.y; //表示该线程要处理的q head id号. 每个kv_head的stride 为group size即bdy.
  /*
  * kv_head_idx和qo_head_idx的关系:假设有2个kv head,4个qo head, group_size= n_head/n_kv_head=2
  * qo head idx:    0 1  | 2 3
  * 对应的kv head idx: 0 | 1
  * 因此如何通过kv_head_idx计算qo_ head_idx= kv_head_idx*group_size+threadIdx.y【在这个kv head里的group id】
  */
  uint32_t kv_chunk_idx = blockIdx.x; // kv_chunk_idx就是q_len,在这个例子可以当作1.
  uint32_t num_qo_heads = info.num_qo_heads; //qo_heads的q和o的头.
  const float alibi_slope = get_alibi_slope(qo_head_idx, num_qo_heads) * math::log2e;
  uint32_t seq_len = info.kv_len; //kv cache中的长度.

  extern __shared__ uint8_t smem[]; //dynamic shared memory,这个shared memory size是通过kernel<<<>>>传入的.
  // uint8_t ksmem+v_smem[2][num_stages_smem][num_replication][group_size][tile_size_per_bdx][warp_size] tile_size_per_bdx=1,2是ksmem和vsmem
  DTypeKV* k_smem = (DTypeKV*)smem; 
  DTypeKV* v_smem = (DTypeKV*)(smem + num_stages_smem * bdy * tile_size_per_bdx * bdz * head_dim * //这个可以看出,每个q head都会分配一个k v shared memory空间，但是实际上是会造成空间上的浪费. 
                                          sizeof(DTypeKV)); //v cache在shared memory中的base ptr,
  float* smem_md = (float*)(smem + 2 * num_stages_smem * bdy * tile_size_per_bdx * bdz * head_dim *
                                       sizeof(DTypeKV)); 
  //这下面定义的是寄存器的值
  uint32_t tx = threadIdx.x, ty = threadIdx.y, tz = threadIdx.z; //tx对应的是lane id,ty对应的是group id,tz对应的replication id.
  vec_t<float, vec_size> q_vec;
  vec_t<float, vec_size> freq;
  if constexpr (pos_encoding_mode == PosEncodingMode::kRoPELlama) {
#pragma unroll
    for (uint32_t i = 0; i < vec_size; ++i) {
      freq[i] = rope_rcp_scale *
                __powf(rope_rcp_theta,
                       float(2 * ((tx * vec_size + i) % (head_dim / 2))) / float(head_dim));
    }
    // apply rotary embedding to q matrix
    q_vec = vec_apply_llama_rope<vec_size, bdx>(q + info.get_qo_elem_offset(0, qo_head_idx, 0),
                                                freq, seq_len - 1);
    //上面是rope位置编码相关的逻辑,暂时还没有去细扣
  } else {
    // do not apply rotary embedding to q matrix
    // q_vec是直接从global memory到register的考量:
    //1. 当一个寄存器的数据需要从寄存器多次换入和换出时，则需要把数据从global memory先copy到shared memory作为一个cache。但是如果没有多次换入换出，直接从global memory到寄存器更合适。
    //2. 这个kernel是在single request decode阶段，那么seq只有一个token,那么每个thread申请的寄存器是少量的.
    q_vec.cast_load(q + info.get_qo_elem_offset(0, qo_head_idx, tx * vec_size));//tx:lane id
  }
  // multiple q_vec by sm_scale
#pragma unroll
  for (uint32_t i = 0; i < vec_size; ++i) {
    q_vec[i] *= sm_scale;
  }
  block.sync(); 

  uint32_t chunk_start = kv_chunk_idx * kv_chunk_size; //kv_chunk_size=1
  kv_chunk_size = min(kv_chunk_size, seq_len - chunk_start);
  uint32_t chunk_end = chunk_start + kv_chunk_size; 
  // grid size(num_chunk,n_kv_head)
  // 针对kv_head_idx=0时:
  // seq_len: 0 1 2 3 4 ... kv_chunk_size-1 | kv_chunk_size kv_chunk_size+1 ..... 2*kv_chunk_size-1| ...| ..
  // 对应的Block: blockIdx.x=0,blockIdx.y=0  | blockIdx.x=1,blockIdx.y=0                            |    | blockIdx.x=num_chunks-1,blockIdx.y=0

  // preload k tiles and v tiles
  uint32_t producer_kv_idx_base = chunk_start;
  constexpr uint32_t vec_bits = sizeof(DTypeKV) * vec_size * 8;
  
  //把第一个周期计算需要的kv数据以及第二个周期计算需要的kv数据从cp async global memory->shared memory. 
#pragma unroll 
  for (uint32_t iter = 0; iter < num_stages_smem; ++iter) { //num_stages_smem:预取的次数
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      cp_async::pred_load<vec_bits, PrefetchMode::kPrefetch, SharedMemFillMode::kNoFill>( 
          k_smem + (((iter * bdz + tz) * bdy + ty) * tile_size_per_bdx + j) * head_dim + 
          // k_smem[num_stage_smem][num_replication][group_size][tile_size_per_bdx][warp_size]
              tx * vec_size, // iter,tz,ty,j,tx是变量.  PrefetchMode::kPrefetch 模式会读取的数据基础上再额外读取128B.
          k + info.get_kv_elem_offset(
                  producer_kv_idx_base + (tz * bdy + ty) * tile_size_per_bdx + j, kv_head_idx,
                  tx * vec_size),
          producer_kv_idx_base + (tz * bdy + ty) * tile_size_per_bdx + j < chunk_end);
    }
    cp_async::commit_group(); // line 296->line 304 作为一个commit_group.
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      cp_async::pred_load<vec_bits, PrefetchMode::kPrefetch, SharedMemFillMode::kFillZero>(
          v_smem + (((iter * bdz + tz) * bdy + ty) * tile_size_per_bdx + j) * head_dim +
              tx * vec_size,
          v + info.get_kv_elem_offset(
                  producer_kv_idx_base + (tz * bdy + ty) * tile_size_per_bdx + j, kv_head_idx,
                  tx * vec_size),
          producer_kv_idx_base + (tz * bdy + ty) * tile_size_per_bdx + j < chunk_end);
    }
    cp_async::commit_group(); // line 306->314 作为一个commit group
    producer_kv_idx_base += bdy * bdz * tile_size_per_bdx;
  }
  //上述会有2*num_stages_smem commit_group 即 k1,v1,k2,v2,....k_{num_stages_smem},v_{num_stages_smem} [每一个k和v都是一个tile_size_per_bdx size的cp operation]

  // pipelining k/v tiles loading and state updating
  uint32_t consumer_kv_idx_base = chunk_start, stage_idx = 0;
  state_t<vec_size> st_local;
  float s[bdy * tile_size_per_bdx]; //bdy=group size

//flash attention 计算的迭代.
#pragma unroll 2
  for (uint32_t iter = 0; iter < ceil_div(kv_chunk_size, tile_size_per_bdx * bdy * bdz); ++iter) { //kv_chunk_size的tokens数
    // compute qk
    cp_async::wait_group<2 * num_stages_smem - 1>(); 
    //2*num_stages_smem-1 表示最多只有2*num_stages_smem-1个cp异步事务未完成.即当iter=0时保证了line 305 中k1从global memory到shared memory的异步事务一定完成.
    // 在计算qk时，需要保证q,k已经到达shared memory或register中,因此需要用line 316保证k1的到达,q已经在line 259中已经到达了.
    block.sync();
    compute_qk<logits_post_hook, pos_encoding_mode, vec_size, bdx, bdy * tile_size_per_bdx>( //tile_size_per_bdx=1
        k_smem + (stage_idx * bdz + tz) * bdy * tile_size_per_bdx * head_dim, stage_idx, q_vec, //k_smem [stage_idx][tz][...]
        freq, consumer_kv_idx_base, iter * bdy * tile_size_per_bdx * bdz, kv_chunk_size,
        seq_len - 1, alibi_slope, s, st_local, logits_soft_cap);
    block.sync();
    // load k
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      cp_async::pred_load<vec_bits, PrefetchMode::kPrefetch, SharedMemFillMode::kNoFill>(
          k_smem + (((stage_idx * bdz + tz) * bdy + ty) * tile_size_per_bdx + j) * head_dim + //Very Interesting! 此处采用的是stage_idx原因是这个周期的k数据计算完了，说明没有用了，那么in-place copy新的数据即可
              tx * vec_size,
          k + info.get_kv_elem_offset(
                  producer_kv_idx_base + (tz * bdy + ty) * tile_size_per_bdx + j, kv_head_idx,
                  tx * vec_size),
          producer_kv_idx_base + (tz * bdy + ty) * tile_size_per_bdx + j < chunk_end);
    }
    cp_async::commit_group(); 
    //line317-line336:线程会先cp.wait_group等候这个周期里的数据到达shared memory的相应位置，然后再把下一个周期计算的数据用异步cp拷贝，之后再开始该周期的计算
    // 【这份代码的逻辑是:先计算该周期的计算，然后拷贝下一个周期的计算数据】.

    // update m/d/o state
    cp_async::wait_group<2 * num_stages_smem - 1>(); //当iter=0时保证了line306的v1从global memory到shared memory的异步事务一定完成.
    block.sync();
    update_local_state<vec_size, bdx, bdy * tile_size_per_bdx>(
        v_smem + (stage_idx * bdz + tz) * bdy * tile_size_per_bdx * head_dim, s, stage_idx,
        st_local); //更新o
    block.sync();

    // load v
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) { 
      cp_async::pred_load<vec_bits, PrefetchMode::kPrefetch, SharedMemFillMode::kFillZero>(
          v_smem + (((stage_idx * bdz + tz) * bdy + ty) * tile_size_per_bdx + j) * head_dim +
              tx * vec_size,
          v + info.get_kv_elem_offset(
                  producer_kv_idx_base + (tz * bdy + ty) * tile_size_per_bdx + j, kv_head_idx,
                  tx * vec_size),
          producer_kv_idx_base + (tz * bdy + ty) * tile_size_per_bdx + j < chunk_end);
    }
    cp_async::commit_group(); //与line 349注释的作用一样.

    stage_idx = (stage_idx + 1) % num_stages_smem;
    producer_kv_idx_base += tile_size_per_bdx * bdy * bdz;
    consumer_kv_idx_base += tile_size_per_bdx * bdy * bdz;
  }
  cp_async::wait_group<0>(); //等候上述所有cp都完成.也意味着部分softmax(qk/根号d)o计算完.
  block.sync();

  // sync local state of all warps inside a threadblock
  sync_state<vec_size, bdx, bdy, bdz>(st_local, reinterpret_cast<float*>(smem), smem_md);//因为block size中有bdz这个replication dim在，因此需要将计算同一个q head的warps的local state再进行汇总.
  st_local.normalize();

  st_local.o.cast_store(o + (kv_chunk_idx * num_qo_heads + qo_head_idx) * head_dim + tx * vec_size); //然后把结果存放到global memory中.
  if (lse != nullptr) {
    lse[kv_chunk_idx * num_qo_heads + qo_head_idx] = st_local.get_lse();
  }
}

/*!
 * \brief FlashAttention decoding cuda kernel with paged kv-cache for multiple requests
 * \tparam logits_post_hook The logits post hook used in the kernel
 * \tparam partition_kv Whether to partition kv-cache on sequence length dimension or not
 * \tparam pos_encoding_mode The positional encoding mode
 * \tparam vec_size A template integer indicates the vector size
 * \tparam bdx A template integer indicates the block size in x dimension
 * \tparam bdy A template integer indicates the block size in y dimension
 * \tparam bdz A template integer indicates the block size in z dimension
 * \tparam page_storage Whether to store indices or pointers of each active page
 * \tparam DTypeQ A template type indicates the query data type
 * \tparam DTypeKV A template type indicates the key-value data type
 * \tparam DTypeOut A template type indicates the output data type
 * \tparam IdType A template type indicates the index data type
 * \param q [batch_size, num_qo_heads, head_dim] The query matrix
 * \param paged_kv The paged kv-cache data structure
 * \param o [num_qo_heads, head_dim] The output matrix
 * \param tmp Used-allocated temporary buffer
 * \param lse The logsumexp values
 * \param sm_scale A float indicates the scale applied to pre-softmax logits
 * \param rope_rcp_scale A floating number indicate the reciprocal
 *   of scaling ratio used in PI(Position Interpolation) for RoPE (Rotary
 *   Positional Embeddings)
 * \param rope_rcp_theta A floating number indicate the reciprocal
 *   of "theta" used in RoPE (Rotary Positional Embeddings)
 */
template <LogitsPostHook logits_post_hook, bool partition_kv, PosEncodingMode pos_encoding_mode,
          uint32_t num_stages_smem, uint32_t tile_size_per_bdx, uint32_t vec_size, uint32_t bdx,
          uint32_t bdy, uint32_t bdz, PageStorage page_storage, QKVLayout kv_layout,
          typename DTypeQ, typename DTypeKV, typename DTypeOut, typename IdType>
__global__ void BatchDecodeWithPagedKVCacheKernel(
    DTypeQ* __restrict__ q, IdType* __restrict__ q_offset,
    paged_kv_t<page_storage, kv_layout, DTypeKV, IdType> paged_kv,
    kv_partition_info_t<IdType> kv_partition_info, DTypeOut* __restrict__ o,
    float* __restrict__ lse, bool* __restrict__ block_valid_mask, float logits_soft_cap,
    float sm_scale, float rope_rcp_scale, float rope_rcp_theta) {
  auto block = cg::this_thread_block();
  sm_scale *=
      (logits_post_hook == LogitsPostHook::kNone ? math::log2e : math::ptx_rcp(logits_soft_cap));

  constexpr uint32_t head_dim = bdx * vec_size;
  const uint32_t batch_idx = blockIdx.x;
  const uint32_t kv_head_idx = blockIdx.y;
  const uint32_t qo_head_idx = kv_head_idx * bdy + threadIdx.y;
  const uint32_t num_qo_heads = gridDim.y * bdy;
  const float alibi_slope = get_alibi_slope(qo_head_idx, num_qo_heads) * math::log2e;
  const uint32_t cur_chunk_start = partition_kv ? kv_partition_info.chunk_start_pos[batch_idx] : 0U;
  const uint32_t cur_page_indptr_begin = paged_kv.indptr[batch_idx],
                 cur_page_indptr_end = paged_kv.indptr[batch_idx + 1];
  // NOTE(Zihao): when CUDAGraph is enabled, we will launch more blocks than
  // the actual batch size, so we need to check if the current batch is valid
  if (block_valid_mask && !block_valid_mask[batch_idx]) return;
  const uint32_t cur_last_page_len = paged_kv.last_page_len[batch_idx];
  const uint32_t kv_chunk_len =
      cur_page_indptr_begin != cur_page_indptr_end
          ? (cur_page_indptr_end - cur_page_indptr_begin - 1) * paged_kv.page_size +
                cur_last_page_len
          : 0;
  const uint32_t seq_len =
      partition_kv ? kv_partition_info.seq_lens_before_partition[batch_idx] : kv_chunk_len;
  const uint32_t mapped_batch_idx =
      partition_kv ? kv_partition_info.batch_idx_map[batch_idx] : batch_idx;

  extern __shared__ uint8_t smem[];
  DTypeKV* k_smem = (DTypeKV*)smem;
  DTypeKV* v_smem = (DTypeKV*)(smem + num_stages_smem * tile_size_per_bdx * bdy * bdz * head_dim *
                                          sizeof(DTypeKV));
  DTypeKV** k_ptrs_smem = (DTypeKV**)(smem + 2 * num_stages_smem * tile_size_per_bdx * bdy * bdz *
                                                 head_dim * sizeof(DTypeKV));
  float* smem_md = (float*)(smem + 2 * num_stages_smem * tile_size_per_bdx * bdy * bdz * head_dim *
                                       sizeof(DTypeKV));

  const uint32_t tx = threadIdx.x, ty = threadIdx.y, tz = threadIdx.z;
  vec_t<float, vec_size> q_vec;
  vec_t<float, vec_size> freq;
  int32_t q_offset_val = q_offset == nullptr ? (seq_len - 1) : q_offset[mapped_batch_idx];
  if constexpr (pos_encoding_mode == PosEncodingMode::kRoPELlama) {
#pragma unroll
    for (uint32_t i = 0; i < vec_size; ++i) {
      freq[i] = rope_rcp_scale *
                __powf(rope_rcp_theta,
                       float(2 * ((tx * vec_size + i) % (head_dim / 2))) / float(head_dim));
    }
    // apply rotary embedding to q matrix
    q_vec = vec_apply_llama_rope<vec_size, bdx>(
        q + (mapped_batch_idx * num_qo_heads + qo_head_idx) * head_dim, freq, q_offset_val);
  } else {
    // do not apply rotary embedding to q matrix
    q_vec.cast_load(q + (mapped_batch_idx * num_qo_heads + qo_head_idx) * head_dim + tx * vec_size);
  }
#pragma unroll
  for (uint32_t i = 0; i < vec_size; ++i) {
    q_vec[i] *= sm_scale;
  }
  block.sync();

  // preload k/v tiles
  uint32_t stage_idx = 0;
  constexpr uint32_t vec_bits = sizeof(DTypeKV) * vec_size * 8;
  // NOTE(Zihao): when CUDAGraph is disabled, gridDim.x = batch_size, otherwise,
  // we guarantee that indptr array length is greater than or equal to batch_size + 1,
  // so we can safely access paged_kv.indptr[batch_idx + 1]
  const IdType last_indptr = paged_kv.indptr[gridDim.x];

  static_assert(num_stages_smem <= bdx);
#pragma unroll
  for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
    uint32_t q, r;
    paged_kv.page_size.divmod(((j * bdz + tz) * bdy + ty) * bdx + tx, q, r);
    k_ptrs_smem[((j * bdz + tz) * bdy + ty) * bdx + tx] =
        paged_kv.protective_get_k_ptr(cur_page_indptr_begin + q, kv_head_idx, r, 0, last_indptr);
  }
  block.sync();

  DTypeKV* k_ptrs[tile_size_per_bdx];
#pragma unroll
  for (uint32_t iter = 0; iter < num_stages_smem; ++iter) {
#pragma unroll
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      k_ptrs[j] =
          k_ptrs_smem[((iter * bdz + tz) * bdy + ty) * tile_size_per_bdx + j] + tx * vec_size;
    }
#pragma unroll
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      cp_async::pred_load<vec_bits, PrefetchMode::kPrefetch, SharedMemFillMode::kNoFill>(
          k_smem + (((stage_idx * bdz + tz) * bdy + ty) * tile_size_per_bdx + j) * head_dim +
              tx * vec_size,
          k_ptrs[j], ((iter * bdz + tz) * bdy + ty) * tile_size_per_bdx + j < kv_chunk_len);
    }
    cp_async::commit_group();
#pragma unroll
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      DTypeKV* v_ptr = k_ptrs[j] + paged_kv.kv_offset_delta();
      cp_async::pred_load<vec_bits, PrefetchMode::kPrefetch, SharedMemFillMode::kFillZero>(
          v_smem + (((stage_idx * bdz + tz) * bdy + ty) * tile_size_per_bdx + j) * head_dim +
              tx * vec_size,
          v_ptr, ((iter * bdz + tz) * bdy + ty) * tile_size_per_bdx + j < kv_chunk_len);
    }
    cp_async::commit_group();
    stage_idx = (stage_idx + 1) % num_stages_smem;
  }

  state_t<vec_size> st;
  float s[bdy * tile_size_per_bdx];

#pragma unroll 2
  for (uint32_t iter = 0; iter < ceil_div(kv_chunk_len, tile_size_per_bdx * bdy * bdz); ++iter) {
    if ((iter + num_stages_smem) % bdx == 0) {
#pragma unroll
      for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
        uint32_t q, r;
        paged_kv.page_size.divmod(((iter + num_stages_smem) * tile_size_per_bdx * bdy * bdz +
                                   ((j * bdz + tz) * bdy + ty) * bdx + tx),
                                  q, r);
        k_ptrs_smem[((j * bdz + tz) * bdy + ty) * bdx + tx] = paged_kv.protective_get_k_ptr(
            cur_page_indptr_begin + q, kv_head_idx, r, 0, last_indptr);
      }
    }
    // compute qk
    cp_async::wait_group<2 * num_stages_smem - 1>();
    block.sync();
    compute_qk<logits_post_hook, pos_encoding_mode, vec_size, bdx, bdy * tile_size_per_bdx>(
        k_smem + (stage_idx * bdz + tz) * bdy * tile_size_per_bdx * head_dim, stage_idx, q_vec,
        freq,
        (paged_kv.rope_pos_offset == nullptr ? 0 : paged_kv.rope_pos_offset[mapped_batch_idx]) +
            cur_chunk_start + iter * tile_size_per_bdx * bdy * bdz,
        iter * tile_size_per_bdx * bdy * bdz, kv_chunk_len, q_offset_val, alibi_slope, s, st,
        logits_soft_cap);
    block.sync();

#pragma unroll
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      k_ptrs[j] = k_ptrs_smem[((((iter + num_stages_smem) % bdx) * bdz + tz) * bdy + ty) *
                                  tile_size_per_bdx +
                              j] +
                  tx * vec_size;
    }
    // load k tiles
#pragma unroll
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      cp_async::pred_load<vec_bits, PrefetchMode::kPrefetch, SharedMemFillMode::kNoFill>(
          k_smem + (((stage_idx * bdz + tz) * bdy + ty) * tile_size_per_bdx + j) * head_dim +
              tx * vec_size,
          k_ptrs[j],
          (((iter + num_stages_smem) * bdz + tz) * bdy + ty) * tile_size_per_bdx + j <
              kv_chunk_len);
    }
    cp_async::commit_group();

    // update m/d/o states
    cp_async::wait_group<2 * num_stages_smem - 1>();
    block.sync();
    update_local_state<vec_size, bdx, bdy * tile_size_per_bdx>(
        v_smem + (stage_idx * bdz + tz) * bdy * tile_size_per_bdx * head_dim, s, stage_idx, st);
    block.sync();

    // load v tiles
#pragma unroll
    for (uint32_t j = 0; j < tile_size_per_bdx; ++j) {
      DTypeKV* v_ptr = k_ptrs[j] + paged_kv.kv_offset_delta();
      cp_async::pred_load<vec_bits, PrefetchMode::kPrefetch, SharedMemFillMode::kFillZero>(
          v_smem + (((stage_idx * bdz + tz) * bdy + ty) * tile_size_per_bdx + j) * head_dim +
              tx * vec_size,
          v_ptr,
          (((iter + num_stages_smem) * bdz + tz) * bdy + ty) * tile_size_per_bdx + j <
              kv_chunk_len);
    }
    cp_async::commit_group();
    stage_idx = (stage_idx + 1) % num_stages_smem;
  }
  cp_async::wait_group<0>();
  block.sync();

  // sync local state of all warps inside a threadblock
  sync_state<vec_size, bdx, bdy, bdz>(st, reinterpret_cast<float*>(smem), smem_md);
  st.normalize();

  st.o.cast_store(o + (batch_idx * num_qo_heads + qo_head_idx) * head_dim + tx * vec_size);
  // write lse
  if (lse != nullptr) {
    lse[batch_idx * num_qo_heads + qo_head_idx] = st.get_lse();
  }
}

/*!
 * \brief Get the heuristic number of threads per threadblock
 * \param group_size The number of qo heads that maps to the same kv head in GQA.
 * \param sizeof_dtype The size (in terms of bytes) of the input data type
 */
constexpr uint32_t get_heuristic_num_threads(uint32_t group_size, uint32_t sizeof_dtype) {
  if (group_size == 8U) {
    if (sizeof_dtype == 1U) {
      return 256U;  // not enough registers for 512 threads
    } else {
      return 512U;
    }
  } else {
#ifdef FLASHINFER_ENABLE_BF16
    return 128U;
#else
    return 64U;
#endif
  }
}

/*!
 * \brief FlashAttention decoding with kv-cache for a single request
 * \tparam DTypeQ A template type indicates the query data type
 * \tparam DTypeKV A template type indicates the key-value data type
 * \tparam DTypeOut A template type indicates the output data type
 * \param q The query matrix, shape: [num_qo_heads, head_dim]
 * \param k The key matrix in kv-cache, shape: [seq_len, num_kv_heads, head_dim]
 *   for NHD layout, [num_kv_heads, seq_len, head_dim] for HND layout
 * \param v The value matrix in kv-cache, shape: [seq_len, num_kv_heads,
 *   head_dim] for NHD layout, [num_kv_heads, seq_len, head_dim] for HND layout
 * \param o The output matrix, shape: [num_qo_heads, head_dim]
 * \param tmp Used-allocated temporary buffer
 * \param num_qo_heads A integer indicates the number of heads of query and output
 * \param num_kv_heads A integer indicates the number of heads of key and value
 * \param seq_len A integer indicates the sequence length
 * \param head_dim A integer indicates the head dimension
 * \param kv_layout The layout of q/k/v matrices
 * \param pos_encoding_mode The positional encoding mode
 * \param rope_scale The scaling factor used in RoPE Interpolation
 * \param rope_theta The theta used in RoPE
 * \param stream The cuda stream to launch the kernel
 * \return status Indicates whether CUDA calls are successful
 */
template <uint32_t HEAD_DIM, LogitsPostHook LOGITS_POST_HOOK, QKVLayout KV_LAYOUT,
          PosEncodingMode POS_ENCODING_MODE, typename DTypeQ, typename DTypeKV, typename DTypeOut>
cudaError_t SingleDecodeWithKVCacheDispatched(DTypeQ* q, DTypeKV* k, DTypeKV* v, DTypeOut* o,
                                              DTypeOut* tmp, uint32_t num_qo_heads,
                                              uint32_t num_kv_heads, uint32_t seq_len,
                                              float logits_soft_cap, float sm_scale,
                                              float rope_scale, float rope_theta,
                                              cudaStream_t stream) {
  // grid(num_chunk,n_kv_heads),block(bdx,bdy(group_size),bdz) bdx实际上就是warp_size,group_size表明一个kv head被group_size个q heads共享.
  // 因为在single request decode阶段,num_chunk=ceil(1 token/n_kv_head)=1.
  const float rope_rcp_scale = 1.f / rope_scale;
  const float rope_rcp_theta = 1.f / rope_theta;
  constexpr uint32_t vec_size = std::max(16UL / sizeof(DTypeKV), HEAD_DIM / 32UL); //vec_size在qk计算时每个thread负责的部分向量计算的元素数
  // 非常有意思,这里constexpr的目的是,很多template function里会通过模板传入vec_size这个参数即在编译的时候就已经确认了,那么在运行的时候就会更快一点.
  constexpr uint32_t num_stages_smem = 2U; //预取数据的周期数+1
  constexpr uint32_t bdx = HEAD_DIM / vec_size; //一般是指32即warp_size
  static_assert(bdx <= 32U);
  DISPATCH_GQA_GROUP_SIZE(num_qo_heads / num_kv_heads, GROUP_SIZE, { //计算GQA的flashAttention
    constexpr uint32_t bdy = GROUP_SIZE;
    constexpr uint32_t num_threads = //用get_heuristic_num_threads的方法来预测下一个block中有多少threads是合理的.
        std::max(get_heuristic_num_threads(GROUP_SIZE, sizeof(DTypeKV)), bdx * bdy);
    constexpr uint32_t bdz = num_threads / (bdx * bdy); //即bdz表示一个qk head在一个周期里同时进行bdz个k.
    tensor_info_t<KV_LAYOUT, HEAD_DIM> info(1, seq_len, num_qo_heads, num_kv_heads);
    constexpr uint32_t tile_size_per_bdx = GROUP_SIZE == 1 ? (sizeof(DTypeKV) == 1 ? 2U : 8U) : 1U; //后续的所有代码假设tile_size_per_bdx=1即group size!=1.
    const uint32_t smem_size = 
        2U * num_stages_smem * bdy * tile_size_per_bdx * bdz * HEAD_DIM * sizeof(DTypeKV) + //这里的2是k smem和v smem
        2U * bdy * bdz * sizeof(float); //这里的2是m和d. 因为对于decode阶段的GQA,一个warp只会有一个m和d的值(bdy和bdz表示有多少warp).
    if (seq_len <= 256 || tmp == nullptr) {
      // no need to use partition-kv kernel
      auto kernel =
          SingleDecodeWithKVCacheKernel<LOGITS_POST_HOOK, KV_LAYOUT, /*partition_kv=*/false,
                                        POS_ENCODING_MODE, num_stages_smem, tile_size_per_bdx,
                                        vec_size, bdx, bdy, bdz, DTypeQ, DTypeKV, DTypeOut>;
      FLASHINFER_CUDA_CALL(
          cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));

      dim3 nblks = dim3(1, num_kv_heads);
      dim3 nthrs = dim3(bdx, bdy, bdz);
      float* lse = nullptr;
      void* args[] = {(void*)&q,
                      (void*)&k,
                      (void*)&v,
                      (void*)&o,
                      (void*)&lse,
                      (void*)&info,
                      (void*)&logits_soft_cap,
                      (void*)&sm_scale,
                      (void*)&rope_rcp_scale,
                      (void*)&rope_rcp_theta,
                      (void*)&seq_len};
      FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
    } else {
      // use partition-kv kernel
      auto kernel =
          SingleDecodeWithKVCacheKernel<LOGITS_POST_HOOK, KV_LAYOUT, /*partition_kv=*/true,
                                        POS_ENCODING_MODE, num_stages_smem, tile_size_per_bdx,
                                        vec_size, bdx, bdy, bdz, DTypeQ, DTypeKV, DTypeOut>;
      FLASHINFER_CUDA_CALL(
          cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));

      int num_blocks_per_sm = 0;
      int num_sm = 0;
      int dev_id = 0;
      FLASHINFER_CUDA_CALL(cudaGetDevice(&dev_id)); //判断是否有device id
      FLASHINFER_CUDA_CALL(cudaDeviceGetAttribute(&num_sm, cudaDevAttrMultiProcessorCount, dev_id));  //这个是高效的获取device 属性的API. From:https://developer.nvidia.com/blog/cuda-pro-tip-the-fast-way-to-query-device-properties/
      FLASHINFER_CUDA_CALL(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&num_blocks_per_sm, kernel,
                                                                         num_threads, smem_size)); 
                                                                         //计算一个sm中最多可以贮存多少active blocks by  cudaOccupancyMaxActiveBlocksPerMultiprocessor
                                                                         // https://developer.nvidia.com/blog/cuda-pro-tip-occupancy-api-simplifies-launch-configuration/
      uint32_t max_grid_size = uint32_t(num_blocks_per_sm) * uint32_t(num_sm);//每个sm中active blocks数
      uint32_t max_num_kv_chunks = max_grid_size / num_kv_heads;//即每个kv_heads可以使用的block数
      uint32_t kv_chunk_size = max(ceil_div(seq_len, max_num_kv_chunks), 256); //seq_len表示的一个seq中的tokens,即该seq下需要使用多少
      uint32_t num_chunks = ceil_div(seq_len, kv_chunk_size);
      dim3 nblks = dim3(num_chunks, num_kv_heads); //grid size : num_chunks=seq_len/seq_len/max_grid_size/n_kv_heads.= max_grid_size/n_kv_heads即一个kv_head可以同时处理几个q head.
      if (nblks.x == 0 || nblks.y == 0) {
        std::ostringstream err_msg;
        err_msg << "Invalid kernel configuration: nblks=(" << nblks.x << "," << nblks.y << ")";
        throw std::runtime_error(err_msg.str());
      }
      dim3 nthrs = dim3(bdx, bdy, bdz); //block size (warp_size,group_size,每个kv_head在一个周期里可以同时处理几个qk计算)
      float* tmp_lse = (float*)(tmp + num_chunks * num_qo_heads * HEAD_DIM);
      void* args[] = {(void*)&q,
                      (void*)&k,
                      (void*)&v,
                      (void*)&tmp,
                      (void*)&tmp_lse,
                      (void*)&info,
                      (void*)&logits_soft_cap,
                      (void*)&sm_scale,
                      (void*)&rope_rcp_scale,
                      (void*)&rope_rcp_theta,
                      (void*)&kv_chunk_size};
      FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
      FLASHINFER_CUDA_CALL(
          MergeStates(tmp, tmp_lse, o, nullptr, num_chunks, 1, num_qo_heads, HEAD_DIM, stream));
    }
  });
  return cudaSuccess;
}

template <uint32_t HEAD_DIM, PageStorage page_storage, LogitsPostHook LOGITS_POST_HOOK,
          QKVLayout kv_layout, PosEncodingMode POS_ENCODING_MODE, typename DTypeQ, typename DTypeKV,
          typename DTypeOut, typename IdType>
cudaError_t BatchDecodeWithPagedKVCacheDispatched(
    DTypeQ* q, IdType* q_offset, paged_kv_t<page_storage, kv_layout, DTypeKV, IdType> paged_kv,
    kv_partition_info_t<IdType> kv_partition_info, DTypeOut* o, DTypeOut* tmp_v, float* tmp_s,
    float* lse, bool* block_valid_mask, uint32_t padded_batch_size, uint32_t num_qo_heads,
    float logits_soft_cap, float sm_scale, float rope_scale, float rope_theta,
    cudaStream_t stream) {
  const float rope_rcp_scale = 1.f / rope_scale;
  const float rope_rcp_theta = 1.f / rope_theta;
  const uint32_t num_kv_heads = paged_kv.num_heads;

  constexpr uint32_t vec_size = std::max(16UL / sizeof(DTypeKV), HEAD_DIM / 32UL);
  constexpr uint32_t num_stages_smem = 2U;
  constexpr uint32_t bdx = HEAD_DIM / vec_size;
  static_assert(bdx <= 32);
  DISPATCH_GQA_GROUP_SIZE(num_qo_heads / num_kv_heads, GROUP_SIZE, {
    constexpr uint32_t bdy = GROUP_SIZE;
    constexpr uint32_t num_threads = std::max(128U, bdx * bdy);
    constexpr uint32_t bdz = num_threads / (bdx * bdy);
    constexpr uint32_t tile_size_per_bdx = GROUP_SIZE == 1 ? (sizeof(DTypeKV) == 1 ? 2U : 4U) : 1U;
    const uint32_t smem_size =
        2 * num_stages_smem * tile_size_per_bdx * bdy * bdz * HEAD_DIM * sizeof(DTypeKV) +
        std::max(tile_size_per_bdx * num_threads * sizeof(DTypeKV*), 2 * bdy * bdz * sizeof(float));

    if (tmp_v == nullptr) {
      // do not use partition-kv kernel
      dim3 nblks(padded_batch_size, num_kv_heads);
      dim3 nthrs(bdx, bdy, bdz);
      auto kernel =
          BatchDecodeWithPagedKVCacheKernel<LOGITS_POST_HOOK, /*partition_kv=*/false,
                                            POS_ENCODING_MODE, num_stages_smem, tile_size_per_bdx,
                                            vec_size, bdx, bdy, bdz, page_storage, kv_layout,
                                            DTypeQ, DTypeKV, DTypeOut, IdType>;
      FLASHINFER_CUDA_CALL(
          cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
      void* args[] = {(void*)&q,
                      (void*)&q_offset,
                      (void*)&paged_kv,
                      (void*)&kv_partition_info,
                      (void*)&o,
                      (void*)&lse,
                      (void*)&block_valid_mask,
                      (void*)&logits_soft_cap,
                      (void*)&sm_scale,
                      (void*)&rope_rcp_scale,
                      (void*)&rope_rcp_theta};
      FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
    } else {
      // use partition-kv kernel
      auto partition_kv_kernel =
          BatchDecodeWithPagedKVCacheKernel<LOGITS_POST_HOOK, /*partition_kv=*/true,
                                            POS_ENCODING_MODE, num_stages_smem, tile_size_per_bdx,
                                            vec_size, bdx, bdy, bdz, page_storage, kv_layout,
                                            DTypeQ, DTypeKV, DTypeOut, IdType>;
      FLASHINFER_CUDA_CALL(cudaFuncSetAttribute(
          partition_kv_kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
      void* args[] = {(void*)&q,
                      (void*)&q_offset,
                      (void*)&paged_kv,
                      (void*)&kv_partition_info,
                      (void*)&tmp_v,
                      (void*)&tmp_s,
                      (void*)&block_valid_mask,
                      (void*)&logits_soft_cap,
                      (void*)&sm_scale,
                      (void*)&rope_rcp_scale,
                      (void*)&rope_rcp_theta};
      dim3 nblks(padded_batch_size, num_kv_heads);
      dim3 nthrs(bdx, bdy, bdz);
      FLASHINFER_CUDA_CALL(
          cudaLaunchKernel((void*)partition_kv_kernel, nblks, nthrs, args, smem_size, stream));
      FLASHINFER_CUDA_CALL(VariableLengthMergeStates(
          tmp_v, tmp_s, kv_partition_info.chunk_indptr, o, lse,
          kv_partition_info.batch_size_before_partition, num_qo_heads, HEAD_DIM, stream));
    }
  });
  return cudaSuccess;
}

}  // namespace flashinfer

#endif  // FLASHINFER_DECODE_CUH_
