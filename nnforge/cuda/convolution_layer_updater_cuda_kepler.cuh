/*
 *  Copyright 2011-2014 Maxim Milakov
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#pragma once

#include "layer_updater_cuda.h"

#include <cuda_runtime.h>

#include <boost/format.hpp>

#include "util_cuda.h"
#include "cuda_texture.h"
#include "neural_network_cuda_exception.h"
#include "packed_config.h"
#include "space_filling_curve.h"
#include "sequential_curve.h"

#include "../convolution_layer.h"
#include "../nn_types.h"

#include <sys/time.h>

#include "EvqueueManager.h"

#define FEATURE_MAP_BLOCK_SIZE 4
#define WINDOW_WIDTH_LOCAL 4
#define MAX_BLOCK_SIZE 5
#define MAX_WINDOW_WIDTH 10

//extern EvqueueManager *evqm;
__device__ unsigned long long int d_zero_clock[15];
__device__ unsigned int d_yield; 
__device__ int d_yield_point, d_yield_point_persist;
__device__ unsigned int d_clock_initialized[15];
__device__ int d_elapsed;
int h_yield_point;
int h_elapsed;
int *d_yield_point_ret;
int *d_elapsed_ret;
int counts_three, allocate;
int backprop_kernel_ctr, update_kernel_ctr, update_weights_kernel_ctr;

unsigned int h_clock_initialized[15];

namespace nnforge
{
	namespace cuda
	{

    static __device__ __forceinline__ uint32_t __smid()
    {
	    uint32_t smid;
	    asm volatile("mov.u32 %0, %%smid;" : "=r"(smid));
	    return smid;
    }
 
    static __device__ __forceinline__ uint32_t yield(int *d_ret1, int *d_ret2, unsigned int allotted_slice)
    {
	    __shared__ bool yield;
	    int elapsed = -1;
	    unsigned long long int start_clock = clock64();
	    int mysmid = __smid();
	    if(threadIdx.x == 0)
	    {
		    if(blockIdx.x + blockIdx.y * gridDim.x < 15)
		    {
			if(atomicCAS(&d_clock_initialized[mysmid], 0, 1)==0)
			{
				atomicExch(&d_zero_clock[mysmid], start_clock);
				elapsed = start_clock - d_zero_clock[mysmid];
                                //printf("%d %d\n", blockIdx.x, elapsed);
                        }
			else
			{
				elapsed = start_clock - d_zero_clock[mysmid];
                                //printf("%d %d\n", blockIdx.x, elapsed);
			}
                        if(elapsed > 10000) /*scheduler launch unlikely to take 10us, so can only launch something less than 60*/
                        {
                                printf("LESS BAD %d %d\n", blockIdx.x + blockIdx.y * gridDim.x, elapsed);
                        }
			if(d_yield_point_persist >= 14)
			{
				yield = true;
			}
			else
			{
				yield = false;
				atomicMax(&d_yield_point, blockIdx.x + blockIdx.y * gridDim.x);
				atomicMax(&d_elapsed, elapsed);
			}
			if(blockIdx.x + blockIdx.y * gridDim.x == gridDim.x * gridDim.y - 1)
			{   
                                //printf("FIRST %d %d\n", d_yield_point, d_elapsed);
                                //printf("LAST %d %d %d %d %d\n", elapsed, yield, d_yield_point_persist, d_yield_point, d_elapsed);
				int val = atomicExch(&d_yield_point, 0);
				if(val == gridDim.x * gridDim.y - 1)
					atomicExch(&d_yield_point_persist, 0);
				else
					atomicExch(&d_yield_point_persist, val);
				*d_ret1 = val;
				val = atomicExch(&d_elapsed, 0);
				*d_ret2 = val;
				for(int i=0; i<15; i++)
				{
					atomicExch(&d_clock_initialized[i],0);
					unsigned int val = atomicExch(&d_clock_initialized[i],0);
				}
			}
                     #if 0

			    if(atomicCAS(&d_clock_initialized[mysmid], 0, 1)==0)
			    {
				    atomicExch(&d_zero_clock[mysmid], start_clock);
				    yield = false;
			    }
			    else
			    {
				    elapsed = start_clock - d_zero_clock[mysmid];
				    if(elapsed < 1000) /*Less than 1 us should include all blocks in a dispatch set*/
				    {
					    yield = false;
					    atomicMax(&d_yield_point, blockIdx.x + blockIdx.y * gridDim.x);
					    atomicMax(&d_elapsed, elapsed);
				    }
				    else
				    {
					    yield = true;
				    }
			    }
                     #endif
		    }
		    else
		    {
				    elapsed = start_clock - d_zero_clock[mysmid];
                        if(elapsed <= 1000) /*1us is a tighter limit suitable for high occupancy like 120 or 240, can launch more than 15 when GPU is free*/
                        {
                                //printf("MORE DON'T CARE %d %d\n", blockIdx.x + blockIdx.y * gridDim.x, elapsed);
                        }
			    if(blockIdx.x + blockIdx.y * gridDim.x <= d_yield_point_persist)
			    {
				    yield = true;
			    }
			    else
			    {
				    //elapsed = start_clock - d_zero_clock[mysmid];
				    if(elapsed >= allotted_slice/*20000000*/)
				    {
					    yield = true;
				    }
				    else
				    {
					    yield = false;
					    atomicMax(&d_yield_point, blockIdx.x + blockIdx.y * gridDim.x);
					    atomicMax(&d_elapsed, elapsed);
				    }

			    }

			    if(blockIdx.x + blockIdx.y * gridDim.x == gridDim.x * gridDim.y - 1)
			    {
                                    //printf("SECOND ON %d %d\n", d_yield_point, d_elapsed);
				    unsigned int val = atomicExch(&d_yield_point, 0);

				    if(val == gridDim.x * gridDim.y - 1)
					    atomicExch(&d_yield_point_persist, 0);
				    else
					    atomicExch(&d_yield_point_persist, val);

				    *d_ret1 = val; 
				    val = atomicExch(&d_elapsed, 0);
				    *d_ret2 = val; 
				    for(int i=0; i<15; i++)
				    {
					    atomicExch(&d_clock_initialized[i],0);
					    unsigned int val = atomicExch(&d_clock_initialized[i],0);
				    }
			    }

		    }
	    }
	    __syncthreads();
	    if(yield==true)
	    {
		    return true;                           
	    }
            else
            {
                    return false;
            }
   }

		template<int DIMENSION_COUNT, int WINDOW_WIDTH, int BLOCK_SIZE, bool single_input_feature_map_group>
		__launch_bounds__(256, 4)
		__global__ void convolution_tex_exact_blocked_upd_kernel_kepler(
			float * __restrict output,
			cudaTextureObject_t input_tex,
			cudaTextureObject_t weights_tex,
			const float * __restrict biases,
			const packed_config<DIMENSION_COUNT+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count_striped,
			int output_feature_map_count,
			int entry_count,
			int packed_config_count,
			int input_feature_map_group_size)
		{
			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (packed_config_id < packed_config_count);
			if (in_bounds)
			{
				int xyzw_output[DIMENSION_COUNT];
				int xyzw[DIMENSION_COUNT];
				int total_weight_count = window_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					total_weight_count *= window_sizes[i];
				int weight_count_per_output_feature_map = input_feature_map_count_striped * total_weight_count;
				packed_config<DIMENSION_COUNT+2> conf = packed_config_list[packed_config_id];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw_output[i] = conf.get_val(i);
					xyzw[i] = xyzw_output[i] - left_zero_padding[i];
				}
				int output_feature_map_id = conf.get_val(DIMENSION_COUNT);
				int base_input_feature_map_id = conf.get_val(DIMENSION_COUNT + 1);
				int input_elem_id = entry_id * input_feature_map_count_striped + base_input_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id = input_elem_id * input_sizes[i] + xyzw[i];
				int weights_offset = (output_feature_map_id * input_feature_map_count_striped + base_input_feature_map_id) * total_weight_count;
				int iteration_count = min(input_feature_map_group_size, input_feature_map_count_striped - base_input_feature_map_id);

				float initial_values[FEATURE_MAP_BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
					initial_values[i] = 0.0F;
				if (base_input_feature_map_id == 0)
				{
					#pragma unroll
					for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
						if (i < output_feature_map_count - output_feature_map_id)
							initial_values[i] = biases[output_feature_map_id + i];
				}
				float sums[BLOCK_SIZE * FEATURE_MAP_BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
					#pragma unroll
					for(int j = 0; j < BLOCK_SIZE; ++j)
						sums[i * BLOCK_SIZE + j] = initial_values[i];

				for(int input_layer_id = 0; input_layer_id < iteration_count; ++input_layer_id)
				{
					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 0); input_w < (DIMENSION_COUNT > 3 ? xyzw[3] + window_sizes[3] : 1); ++input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)input_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 0); input_z < (DIMENSION_COUNT > 2 ? xyzw[2] + window_sizes[2] : 1); ++input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)input_sizes[2])) : true;
							for(int input_y = (DIMENSION_COUNT > 1 ? xyzw[1] : 0); input_y < (DIMENSION_COUNT > 1 ? xyzw[1] + window_sizes[1] : 1); ++input_y)
							{
								bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)input_y < (unsigned int)input_sizes[1])) : true;

								float2 input_vals[BLOCK_SIZE + WINDOW_WIDTH - 1];
								int input_x = xyzw[0];
								#pragma unroll
								for(int i = 0; i < BLOCK_SIZE + WINDOW_WIDTH - 1; ++i, ++input_x)
								{
									bool b_fit0 = b_fit1 && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
									input_vals[i] = tex1Dfetch<float2>(input_tex, b_fit0 ? (input_elem_id + i) : -1);
								}

								#pragma unroll
								for(int input_x = 0; input_x < WINDOW_WIDTH; ++input_x)
								{
									float2 weight_list[FEATURE_MAP_BLOCK_SIZE];
									#pragma unroll
									for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
										weight_list[i] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_output_feature_map * i);
									#pragma unroll
									for(int j = 0; j < BLOCK_SIZE; ++j)
									{
										float2 inp = input_vals[input_x + j]; 
										#pragma unroll
										for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
										{
											sums[i * BLOCK_SIZE + j] += inp.x * weight_list[i].x;
											sums[i * BLOCK_SIZE + j] += inp.y * weight_list[i].y;
										}
									}
									weights_offset++;
								} // input_x
								input_elem_id += input_sizes[0];
							} // for input_y
							if (DIMENSION_COUNT > 1)
								input_elem_id += input_sizes[0] * (input_sizes[1] - window_sizes[1]);
						} // for input_z
						if (DIMENSION_COUNT > 2)
							input_elem_id += input_sizes[1] * input_sizes[0] * (input_sizes[2] - window_sizes[2]);
					} // for input_w
					if (DIMENSION_COUNT > 3)
						input_elem_id += input_sizes[2] * input_sizes[1] * input_sizes[0] * (input_sizes[3] - window_sizes[3]);
				}

				int output_offset = entry_id * output_feature_map_count + output_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_offset = output_offset * output_sizes[i] + xyzw_output[i];
				float * base_output = output + output_offset;
				int output_neuron_count_per_feature_map = output_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					output_neuron_count_per_feature_map *= output_sizes[i];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
				{
					if (i < output_feature_map_count - output_feature_map_id)
					{
						#pragma unroll
						for(int j = 0; j < BLOCK_SIZE; ++j)
						{
							if (j < output_sizes[0] - xyzw_output[0])
							{
								if (single_input_feature_map_group)
								{
									base_output[j + output_neuron_count_per_feature_map * i] = sums[i * BLOCK_SIZE + j];
								}
								else
								{
									atomicAdd(base_output + output_neuron_count_per_feature_map * i + j, sums[i * BLOCK_SIZE + j]);
								}
							}
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT, int WINDOW_WIDTH, int BLOCK_SIZE, bool single_input_feature_map_group>
		__launch_bounds__(256, 4)
		__global__ void convolution_tex_exact_blocked_upd_kernel_kepler_instrumented(
			float * __restrict output,
			cudaTextureObject_t input_tex,
			cudaTextureObject_t weights_tex,
			const float * __restrict biases,
			const packed_config<DIMENSION_COUNT+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count_striped,
			int output_feature_map_count,
			int entry_count,
			int packed_config_count,
			int input_feature_map_group_size,/*)*/
                        unsigned long allotted_slice,
                        int *d_ret1,
                        int *d_ret2)
		{
                        if(yield(d_ret1, d_ret2, allotted_slice))
                          return;

			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (packed_config_id < packed_config_count);
			if (in_bounds)
			{
				int xyzw_output[DIMENSION_COUNT];
				int xyzw[DIMENSION_COUNT];
				int total_weight_count = window_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					total_weight_count *= window_sizes[i];
				int weight_count_per_output_feature_map = input_feature_map_count_striped * total_weight_count;
				packed_config<DIMENSION_COUNT+2> conf = packed_config_list[packed_config_id];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw_output[i] = conf.get_val(i);
					xyzw[i] = xyzw_output[i] - left_zero_padding[i];
				}
				int output_feature_map_id = conf.get_val(DIMENSION_COUNT);
				int base_input_feature_map_id = conf.get_val(DIMENSION_COUNT + 1);
				int input_elem_id = entry_id * input_feature_map_count_striped + base_input_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id = input_elem_id * input_sizes[i] + xyzw[i];
				int weights_offset = (output_feature_map_id * input_feature_map_count_striped + base_input_feature_map_id) * total_weight_count;
				int iteration_count = min(input_feature_map_group_size, input_feature_map_count_striped - base_input_feature_map_id);

				float initial_values[FEATURE_MAP_BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
					initial_values[i] = 0.0F;
				if (base_input_feature_map_id == 0)
				{
					#pragma unroll
					for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
						if (i < output_feature_map_count - output_feature_map_id)
							initial_values[i] = biases[output_feature_map_id + i];
				}
				float sums[BLOCK_SIZE * FEATURE_MAP_BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
					#pragma unroll
					for(int j = 0; j < BLOCK_SIZE; ++j)
						sums[i * BLOCK_SIZE + j] = initial_values[i];

				for(int input_layer_id = 0; input_layer_id < iteration_count; ++input_layer_id)
				{
					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 0); input_w < (DIMENSION_COUNT > 3 ? xyzw[3] + window_sizes[3] : 1); ++input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)input_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 0); input_z < (DIMENSION_COUNT > 2 ? xyzw[2] + window_sizes[2] : 1); ++input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)input_sizes[2])) : true;
							for(int input_y = (DIMENSION_COUNT > 1 ? xyzw[1] : 0); input_y < (DIMENSION_COUNT > 1 ? xyzw[1] + window_sizes[1] : 1); ++input_y)
							{
								bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)input_y < (unsigned int)input_sizes[1])) : true;

								float2 input_vals[BLOCK_SIZE + WINDOW_WIDTH - 1];
								int input_x = xyzw[0];
								#pragma unroll
								for(int i = 0; i < BLOCK_SIZE + WINDOW_WIDTH - 1; ++i, ++input_x)
								{
									bool b_fit0 = b_fit1 && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
									input_vals[i] = tex1Dfetch<float2>(input_tex, b_fit0 ? (input_elem_id + i) : -1);
								}

								#pragma unroll
								for(int input_x = 0; input_x < WINDOW_WIDTH; ++input_x)
								{
									float2 weight_list[FEATURE_MAP_BLOCK_SIZE];
									#pragma unroll
									for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
										weight_list[i] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_output_feature_map * i);
									#pragma unroll
									for(int j = 0; j < BLOCK_SIZE; ++j)
									{
										float2 inp = input_vals[input_x + j]; 
										#pragma unroll
										for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
										{
											sums[i * BLOCK_SIZE + j] += inp.x * weight_list[i].x;
											sums[i * BLOCK_SIZE + j] += inp.y * weight_list[i].y;
										}
									}
									weights_offset++;
								} // input_x
								input_elem_id += input_sizes[0];
							} // for input_y
							if (DIMENSION_COUNT > 1)
								input_elem_id += input_sizes[0] * (input_sizes[1] - window_sizes[1]);
						} // for input_z
						if (DIMENSION_COUNT > 2)
							input_elem_id += input_sizes[1] * input_sizes[0] * (input_sizes[2] - window_sizes[2]);
					} // for input_w
					if (DIMENSION_COUNT > 3)
						input_elem_id += input_sizes[2] * input_sizes[1] * input_sizes[0] * (input_sizes[3] - window_sizes[3]);
				}

				int output_offset = entry_id * output_feature_map_count + output_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_offset = output_offset * output_sizes[i] + xyzw_output[i];
				float * base_output = output + output_offset;
				int output_neuron_count_per_feature_map = output_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					output_neuron_count_per_feature_map *= output_sizes[i];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
				{
					if (i < output_feature_map_count - output_feature_map_id)
					{
						#pragma unroll
						for(int j = 0; j < BLOCK_SIZE; ++j)
						{
							if (j < output_sizes[0] - xyzw_output[0])
							{
								if (single_input_feature_map_group)
								{
									base_output[j + output_neuron_count_per_feature_map * i] = sums[i * BLOCK_SIZE + j];
								}
								else
								{
									atomicAdd(base_output + output_neuron_count_per_feature_map * i + j, sums[i * BLOCK_SIZE + j]);
								}
							}
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT, int BLOCK_SIZE, bool single_input_feature_map_group>
		__launch_bounds__(256, 4)
		__global__ void convolution_tex_generic_blocked_upd_kernel_kepler(
			float * __restrict output,
			cudaTextureObject_t input_tex,
			cudaTextureObject_t weights_tex,
			const float * __restrict biases,
			const packed_config<DIMENSION_COUNT+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count_striped,
			int output_feature_map_count,
			int entry_count,
			int packed_config_count,
			int input_feature_map_group_size)
		{
			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (packed_config_id < packed_config_count);
			if (in_bounds)
			{
				int xyzw_output[DIMENSION_COUNT];
				int xyzw[DIMENSION_COUNT];
				int total_weight_count = window_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					total_weight_count *= window_sizes[i];
				int weight_count_per_output_feature_map = input_feature_map_count_striped * total_weight_count;
				packed_config<DIMENSION_COUNT+2> conf = packed_config_list[packed_config_id];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw_output[i] = conf.get_val(i);
					xyzw[i] = xyzw_output[i] - left_zero_padding[i];
				}
				int output_feature_map_id = conf.get_val(DIMENSION_COUNT);
				int base_input_feature_map_id = conf.get_val(DIMENSION_COUNT + 1);
				int input_elem_id = entry_id * input_feature_map_count_striped + base_input_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id = input_elem_id * input_sizes[i] + xyzw[i];
				int weights_offset = (output_feature_map_id * input_feature_map_count_striped + base_input_feature_map_id) * total_weight_count;
				int iteration_count = min(input_feature_map_group_size, input_feature_map_count_striped - base_input_feature_map_id);

				float initial_values[FEATURE_MAP_BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
					initial_values[i] = 0.0F;
				if (base_input_feature_map_id == 0)
				{
					#pragma unroll
					for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
						if (i < output_feature_map_count - output_feature_map_id)
							initial_values[i] = biases[output_feature_map_id + i];
				}
				float sums[BLOCK_SIZE * FEATURE_MAP_BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
					#pragma unroll
					for(int j = 0; j < BLOCK_SIZE; ++j)
						sums[i * BLOCK_SIZE + j] = initial_values[i];

				for(int input_layer_id = 0; input_layer_id < iteration_count; ++input_layer_id)
				{
					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 0); input_w < (DIMENSION_COUNT > 3 ? xyzw[3] + window_sizes[3] : 1); ++input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)input_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 0); input_z < (DIMENSION_COUNT > 2 ? xyzw[2] + window_sizes[2] : 1); ++input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)input_sizes[2])) : true;
							for(int input_y = (DIMENSION_COUNT > 1 ? xyzw[1] : 0); input_y < (DIMENSION_COUNT > 1 ? xyzw[1] + window_sizes[1] : 1); ++input_y)
							{
								bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)input_y < (unsigned int)input_sizes[1])) : true;

								#pragma unroll 4
								for(int input_x = xyzw[0]; input_x < xyzw[0] + window_sizes[0]; ++input_x)
								{
									float2 weight_list[FEATURE_MAP_BLOCK_SIZE];
									#pragma unroll
									for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
										weight_list[i] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_output_feature_map * i);
									#pragma unroll
									for(int j = 0; j < BLOCK_SIZE; ++j)
									{
										int input_x_total = input_x + j;
										bool b_fit0 = b_fit1 && ((unsigned int)input_x_total < (unsigned int)input_sizes[0]);
										float2 inp = tex1Dfetch<float2>(input_tex, b_fit0 ? (input_elem_id - xyzw[0] + input_x_total) : -1); 

										#pragma unroll
										for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
										{
											sums[i * BLOCK_SIZE + j] += inp.x * weight_list[i].x;
											sums[i * BLOCK_SIZE + j] += inp.y * weight_list[i].y;
										}
									}
									weights_offset++;
								} // for input_x
								input_elem_id += input_sizes[0];
							} // for input_y
							if (DIMENSION_COUNT > 1)
								input_elem_id += input_sizes[0] * (input_sizes[1] - window_sizes[1]);
						} // for input_z
						if (DIMENSION_COUNT > 2)
							input_elem_id += input_sizes[1] * input_sizes[0] * (input_sizes[2] - window_sizes[2]);
					} // for input_w
					if (DIMENSION_COUNT > 3)
						input_elem_id += input_sizes[2] * input_sizes[1] * input_sizes[0] * (input_sizes[3] - window_sizes[3]);
				}

				int output_offset = entry_id * output_feature_map_count + output_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_offset = output_offset * output_sizes[i] + xyzw_output[i];
				float * base_output = output + output_offset;
				int output_neuron_count_per_feature_map = output_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					output_neuron_count_per_feature_map *= output_sizes[i];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
				{
					if (i < output_feature_map_count - output_feature_map_id)
					{
						#pragma unroll
						for(int j = 0; j < BLOCK_SIZE; ++j)
						{
							if (j < output_sizes[0] - xyzw_output[0])
							{
								if (single_input_feature_map_group)
								{
									base_output[j + output_neuron_count_per_feature_map * i] = sums[i * BLOCK_SIZE + j];
								}
								else
								{
									atomicAdd(base_output + output_neuron_count_per_feature_map * i + j, sums[i * BLOCK_SIZE + j]);
								}
							}
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT, int BLOCK_SIZE, bool single_input_feature_map_group>
		__launch_bounds__(256, 4)
		__global__ void convolution_tex_generic_blocked_upd_kernel_kepler_instrumented(
			float * __restrict output,
			cudaTextureObject_t input_tex,
			cudaTextureObject_t weights_tex,
			const float * __restrict biases,
			const packed_config<DIMENSION_COUNT+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count_striped,
			int output_feature_map_count,
			int entry_count,
			int packed_config_count,
			int input_feature_map_group_size,/*)*/
                        unsigned long allotted_slice,
                        int *d_ret1,
                        int *d_ret2)
		{
                        if(yield(d_ret1, d_ret2, allotted_slice))
                          return;

			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (packed_config_id < packed_config_count);
			if (in_bounds)
			{
				int xyzw_output[DIMENSION_COUNT];
				int xyzw[DIMENSION_COUNT];
				int total_weight_count = window_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					total_weight_count *= window_sizes[i];
				int weight_count_per_output_feature_map = input_feature_map_count_striped * total_weight_count;
				packed_config<DIMENSION_COUNT+2> conf = packed_config_list[packed_config_id];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw_output[i] = conf.get_val(i);
					xyzw[i] = xyzw_output[i] - left_zero_padding[i];
				}
				int output_feature_map_id = conf.get_val(DIMENSION_COUNT);
				int base_input_feature_map_id = conf.get_val(DIMENSION_COUNT + 1);
				int input_elem_id = entry_id * input_feature_map_count_striped + base_input_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id = input_elem_id * input_sizes[i] + xyzw[i];
				int weights_offset = (output_feature_map_id * input_feature_map_count_striped + base_input_feature_map_id) * total_weight_count;
				int iteration_count = min(input_feature_map_group_size, input_feature_map_count_striped - base_input_feature_map_id);

				float initial_values[FEATURE_MAP_BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
					initial_values[i] = 0.0F;
				if (base_input_feature_map_id == 0)
				{
					#pragma unroll
					for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
						if (i < output_feature_map_count - output_feature_map_id)
							initial_values[i] = biases[output_feature_map_id + i];
				}
				float sums[BLOCK_SIZE * FEATURE_MAP_BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
					#pragma unroll
					for(int j = 0; j < BLOCK_SIZE; ++j)
						sums[i * BLOCK_SIZE + j] = initial_values[i];

				for(int input_layer_id = 0; input_layer_id < iteration_count; ++input_layer_id)
				{
					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 0); input_w < (DIMENSION_COUNT > 3 ? xyzw[3] + window_sizes[3] : 1); ++input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)input_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 0); input_z < (DIMENSION_COUNT > 2 ? xyzw[2] + window_sizes[2] : 1); ++input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)input_sizes[2])) : true;
							for(int input_y = (DIMENSION_COUNT > 1 ? xyzw[1] : 0); input_y < (DIMENSION_COUNT > 1 ? xyzw[1] + window_sizes[1] : 1); ++input_y)
							{
								bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)input_y < (unsigned int)input_sizes[1])) : true;

								#pragma unroll 4
								for(int input_x = xyzw[0]; input_x < xyzw[0] + window_sizes[0]; ++input_x)
								{
									float2 weight_list[FEATURE_MAP_BLOCK_SIZE];
									#pragma unroll
									for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
										weight_list[i] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_output_feature_map * i);
									#pragma unroll
									for(int j = 0; j < BLOCK_SIZE; ++j)
									{
										int input_x_total = input_x + j;
										bool b_fit0 = b_fit1 && ((unsigned int)input_x_total < (unsigned int)input_sizes[0]);
										float2 inp = tex1Dfetch<float2>(input_tex, b_fit0 ? (input_elem_id - xyzw[0] + input_x_total) : -1); 

										#pragma unroll
										for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
										{
											sums[i * BLOCK_SIZE + j] += inp.x * weight_list[i].x;
											sums[i * BLOCK_SIZE + j] += inp.y * weight_list[i].y;
										}
									}
									weights_offset++;
								} // for input_x
								input_elem_id += input_sizes[0];
							} // for input_y
							if (DIMENSION_COUNT > 1)
								input_elem_id += input_sizes[0] * (input_sizes[1] - window_sizes[1]);
						} // for input_z
						if (DIMENSION_COUNT > 2)
							input_elem_id += input_sizes[1] * input_sizes[0] * (input_sizes[2] - window_sizes[2]);
					} // for input_w
					if (DIMENSION_COUNT > 3)
						input_elem_id += input_sizes[2] * input_sizes[1] * input_sizes[0] * (input_sizes[3] - window_sizes[3]);
				}

				int output_offset = entry_id * output_feature_map_count + output_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_offset = output_offset * output_sizes[i] + xyzw_output[i];
				float * base_output = output + output_offset;
				int output_neuron_count_per_feature_map = output_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					output_neuron_count_per_feature_map *= output_sizes[i];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
				{
					if (i < output_feature_map_count - output_feature_map_id)
					{
						#pragma unroll
						for(int j = 0; j < BLOCK_SIZE; ++j)
						{
							if (j < output_sizes[0] - xyzw_output[0])
							{
								if (single_input_feature_map_group)
								{
									base_output[j + output_neuron_count_per_feature_map * i] = sums[i * BLOCK_SIZE + j];
								}
								else
								{
									atomicAdd(base_output + output_neuron_count_per_feature_map * i + j, sums[i * BLOCK_SIZE + j]);
								}
							}
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT, int WINDOW_WIDTH, int BLOCK_SIZE, bool single_output_feature_map_group>
		__launch_bounds__(256, 4)
		__global__ void convolution_backprop_tex_exact_blocked_upd_kernel_kepler(
			float * __restrict input_errors,
			cudaTextureObject_t output_tex,
			cudaTextureObject_t weights_tex,
			const packed_config<DIMENSION_COUNT+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int input_feature_map_count_striped,
			int output_feature_map_count,
			int output_feature_map_count_striped,
			int entry_count,
			int packed_config_count,
			int output_feature_map_group_size)
		{
			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (packed_config_id < packed_config_count);
			if (in_bounds)
			{
				int xyzw_input[DIMENSION_COUNT];
				int xyzw[DIMENSION_COUNT];
				int total_weight_count = window_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					total_weight_count *= window_sizes[i];
				int weight_count_per_striped_input_feature_map = total_weight_count;
				int weight_count_per_output_feature_map = input_feature_map_count_striped * total_weight_count;
				packed_config<DIMENSION_COUNT+2> conf = packed_config_list[packed_config_id];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw_input[i] = conf.get_val(i);
					xyzw[i] = xyzw_input[i] + left_zero_padding[i];
				}
				int input_feature_map_id_striped = conf.get_val(DIMENSION_COUNT);
				int base_output_feature_map_id_striped = conf.get_val(DIMENSION_COUNT + 1);
				int output_elem_id = entry_id * output_feature_map_count_striped + base_output_feature_map_id_striped;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_elem_id = output_elem_id * output_sizes[i] + xyzw[i];
				int weights_offset = ((base_output_feature_map_id_striped << 1) * input_feature_map_count_striped + input_feature_map_id_striped) * total_weight_count;
				int iteration_count = min(output_feature_map_group_size, output_feature_map_count_striped - base_output_feature_map_id_striped);

				float sums[FEATURE_MAP_BLOCK_SIZE * BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE * BLOCK_SIZE; ++i)
					sums[i] = 0.0F;

				for(int output_layer_id = 0; output_layer_id < iteration_count; ++output_layer_id)
				{
					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 1); input_w > (DIMENSION_COUNT > 3 ? xyzw[3] - window_sizes[3] : 0); --input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)output_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 1); input_z > (DIMENSION_COUNT > 2 ? xyzw[2] - window_sizes[2] : 0); --input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)output_sizes[2])) : true;
							for(int input_y = (DIMENSION_COUNT > 1 ? xyzw[1] : 1); input_y > (DIMENSION_COUNT > 1 ? xyzw[1] - window_sizes[1] : 0); --input_y)
							{
								bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)input_y < (unsigned int)output_sizes[1])) : true;

								float2 output_vals[BLOCK_SIZE + WINDOW_WIDTH - 1];
								int input_x = xyzw[0];
								#pragma unroll
								for(int i = 0; i < BLOCK_SIZE + WINDOW_WIDTH - 1; ++i, --input_x)
								{
									bool b_fit0 = b_fit1 && ((unsigned int)input_x < (unsigned int)output_sizes[0]);
									output_vals[i] = tex1Dfetch<float2>(output_tex, b_fit0 ? (output_elem_id - i) : -1);
								}

								#pragma unroll
								for(int input_x = 0; input_x < WINDOW_WIDTH; ++input_x)
								{
									float2 weight_list[FEATURE_MAP_BLOCK_SIZE];
									#pragma unroll
									for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE/2; ++i)
									{
										weight_list[i] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_striped_input_feature_map * i);
										weight_list[i + (FEATURE_MAP_BLOCK_SIZE/2)] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_output_feature_map + weight_count_per_striped_input_feature_map * i);
									}

									#pragma unroll
									for(int j = 0; j < BLOCK_SIZE; ++j)
									{
										#pragma unroll
										for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE/2; ++i)
										{
											sums[(i * 2) * BLOCK_SIZE + j] += output_vals[input_x + j].x * weight_list[i].x;
											sums[(i * 2) * BLOCK_SIZE + j] += output_vals[input_x + j].y * weight_list[(FEATURE_MAP_BLOCK_SIZE/2) + i].x;
											sums[(i * 2 + 1) * BLOCK_SIZE + j] += output_vals[input_x + j].x * weight_list[i].y;
											sums[(i * 2 + 1) * BLOCK_SIZE + j] += output_vals[input_x + j].y * weight_list[(FEATURE_MAP_BLOCK_SIZE/2) + i].y;
										}
									}
									weights_offset++;
								}
								if (DIMENSION_COUNT == 1)
									output_elem_id += output_sizes[0];
								else
									output_elem_id -= output_sizes[0];
							} // for(int input_y
							if (DIMENSION_COUNT == 2)
								output_elem_id += output_sizes[0] * (window_sizes[1] + output_sizes[1]);
							else if (DIMENSION_COUNT > 2)
								output_elem_id += output_sizes[0] * (window_sizes[1] - output_sizes[1]);
						} // for(int input_z
						if (DIMENSION_COUNT == 3)
							output_elem_id += output_sizes[1] * output_sizes[0] * (window_sizes[2] + output_sizes[2]);
						else if (DIMENSION_COUNT > 3)
							output_elem_id += output_sizes[1] * output_sizes[0] * (window_sizes[2] - output_sizes[2]);
					} // for(int input_w
					if (DIMENSION_COUNT == 4)
						output_elem_id += output_sizes[2] * output_sizes[1] * output_sizes[0] * (window_sizes[3] + output_sizes[3]);
					weights_offset += (weight_count_per_output_feature_map << 1) - weight_count_per_striped_input_feature_map;
				} // for(int output_layer_id

				int input_feature_map_id = input_feature_map_id_striped << 1;
				int input_offset = entry_id * input_feature_map_count + input_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_offset = input_offset * input_sizes[i] + xyzw_input[i];
				float * base_input = input_errors + input_offset;
				int input_neuron_count_per_feature_map = input_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					input_neuron_count_per_feature_map *= input_sizes[i];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
				{
					if (i < input_feature_map_count - input_feature_map_id)
					{
						#pragma unroll
						for(int j = 0; j < BLOCK_SIZE; ++j)
						{
							if (j > xyzw_input[0] - input_sizes[0])
							{
								if (single_output_feature_map_group)
								{
									*(base_input + input_neuron_count_per_feature_map * i - j) = sums[i * BLOCK_SIZE + j];
								}
								else
								{
									atomicAdd(base_input + input_neuron_count_per_feature_map * i - j, sums[i * BLOCK_SIZE + j]);
								}
							}
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT, int WINDOW_WIDTH, int BLOCK_SIZE, bool single_output_feature_map_group>
		__launch_bounds__(256, 4)
		__global__ void convolution_backprop_tex_exact_blocked_upd_kernel_kepler_instrumented(
			float * __restrict input_errors,
			cudaTextureObject_t output_tex,
			cudaTextureObject_t weights_tex,
			const packed_config<DIMENSION_COUNT+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int input_feature_map_count_striped,
			int output_feature_map_count,
			int output_feature_map_count_striped,
			int entry_count,
			int packed_config_count,
			int output_feature_map_group_size,/*)*/
                        unsigned long allotted_slice,
                        int *d_ret1,
                        int *d_ret2)
		{
                        if(yield(d_ret1, d_ret2, allotted_slice))
                          return;

			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (packed_config_id < packed_config_count);
			if (in_bounds)
			{
				int xyzw_input[DIMENSION_COUNT];
				int xyzw[DIMENSION_COUNT];
				int total_weight_count = window_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					total_weight_count *= window_sizes[i];
				int weight_count_per_striped_input_feature_map = total_weight_count;
				int weight_count_per_output_feature_map = input_feature_map_count_striped * total_weight_count;
				packed_config<DIMENSION_COUNT+2> conf = packed_config_list[packed_config_id];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw_input[i] = conf.get_val(i);
					xyzw[i] = xyzw_input[i] + left_zero_padding[i];
				}
				int input_feature_map_id_striped = conf.get_val(DIMENSION_COUNT);
				int base_output_feature_map_id_striped = conf.get_val(DIMENSION_COUNT + 1);
				int output_elem_id = entry_id * output_feature_map_count_striped + base_output_feature_map_id_striped;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_elem_id = output_elem_id * output_sizes[i] + xyzw[i];
				int weights_offset = ((base_output_feature_map_id_striped << 1) * input_feature_map_count_striped + input_feature_map_id_striped) * total_weight_count;
				int iteration_count = min(output_feature_map_group_size, output_feature_map_count_striped - base_output_feature_map_id_striped);

				float sums[FEATURE_MAP_BLOCK_SIZE * BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE * BLOCK_SIZE; ++i)
					sums[i] = 0.0F;

				for(int output_layer_id = 0; output_layer_id < iteration_count; ++output_layer_id)
				{
					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 1); input_w > (DIMENSION_COUNT > 3 ? xyzw[3] - window_sizes[3] : 0); --input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)output_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 1); input_z > (DIMENSION_COUNT > 2 ? xyzw[2] - window_sizes[2] : 0); --input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)output_sizes[2])) : true;
							for(int input_y = (DIMENSION_COUNT > 1 ? xyzw[1] : 1); input_y > (DIMENSION_COUNT > 1 ? xyzw[1] - window_sizes[1] : 0); --input_y)
							{
								bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)input_y < (unsigned int)output_sizes[1])) : true;

								float2 output_vals[BLOCK_SIZE + WINDOW_WIDTH - 1];
								int input_x = xyzw[0];
								#pragma unroll
								for(int i = 0; i < BLOCK_SIZE + WINDOW_WIDTH - 1; ++i, --input_x)
								{
									bool b_fit0 = b_fit1 && ((unsigned int)input_x < (unsigned int)output_sizes[0]);
									output_vals[i] = tex1Dfetch<float2>(output_tex, b_fit0 ? (output_elem_id - i) : -1);
								}

								#pragma unroll
								for(int input_x = 0; input_x < WINDOW_WIDTH; ++input_x)
								{
									float2 weight_list[FEATURE_MAP_BLOCK_SIZE];
									#pragma unroll
									for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE/2; ++i)
									{
										weight_list[i] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_striped_input_feature_map * i);
										weight_list[i + (FEATURE_MAP_BLOCK_SIZE/2)] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_output_feature_map + weight_count_per_striped_input_feature_map * i);
									}

									#pragma unroll
									for(int j = 0; j < BLOCK_SIZE; ++j)
									{
										#pragma unroll
										for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE/2; ++i)
										{
											sums[(i * 2) * BLOCK_SIZE + j] += output_vals[input_x + j].x * weight_list[i].x;
											sums[(i * 2) * BLOCK_SIZE + j] += output_vals[input_x + j].y * weight_list[(FEATURE_MAP_BLOCK_SIZE/2) + i].x;
											sums[(i * 2 + 1) * BLOCK_SIZE + j] += output_vals[input_x + j].x * weight_list[i].y;
											sums[(i * 2 + 1) * BLOCK_SIZE + j] += output_vals[input_x + j].y * weight_list[(FEATURE_MAP_BLOCK_SIZE/2) + i].y;
										}
									}
									weights_offset++;
								}
								if (DIMENSION_COUNT == 1)
									output_elem_id += output_sizes[0];
								else
									output_elem_id -= output_sizes[0];
							} // for(int input_y
							if (DIMENSION_COUNT == 2)
								output_elem_id += output_sizes[0] * (window_sizes[1] + output_sizes[1]);
							else if (DIMENSION_COUNT > 2)
								output_elem_id += output_sizes[0] * (window_sizes[1] - output_sizes[1]);
						} // for(int input_z
						if (DIMENSION_COUNT == 3)
							output_elem_id += output_sizes[1] * output_sizes[0] * (window_sizes[2] + output_sizes[2]);
						else if (DIMENSION_COUNT > 3)
							output_elem_id += output_sizes[1] * output_sizes[0] * (window_sizes[2] - output_sizes[2]);
					} // for(int input_w
					if (DIMENSION_COUNT == 4)
						output_elem_id += output_sizes[2] * output_sizes[1] * output_sizes[0] * (window_sizes[3] + output_sizes[3]);
					weights_offset += (weight_count_per_output_feature_map << 1) - weight_count_per_striped_input_feature_map;
				} // for(int output_layer_id

				int input_feature_map_id = input_feature_map_id_striped << 1;
				int input_offset = entry_id * input_feature_map_count + input_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_offset = input_offset * input_sizes[i] + xyzw_input[i];
				float * base_input = input_errors + input_offset;
				int input_neuron_count_per_feature_map = input_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					input_neuron_count_per_feature_map *= input_sizes[i];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
				{
					if (i < input_feature_map_count - input_feature_map_id)
					{
						#pragma unroll
						for(int j = 0; j < BLOCK_SIZE; ++j)
						{
							if (j > xyzw_input[0] - input_sizes[0])
							{
								if (single_output_feature_map_group)
								{
									*(base_input + input_neuron_count_per_feature_map * i - j) = sums[i * BLOCK_SIZE + j];
								}
								else
								{
									atomicAdd(base_input + input_neuron_count_per_feature_map * i - j, sums[i * BLOCK_SIZE + j]);
								}
							}
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT, int BLOCK_SIZE, bool single_output_feature_map_group>
		__launch_bounds__(256, 4)
		__global__ void convolution_backprop_tex_generic_blocked_upd_kernel_kepler(
			float * __restrict input_errors,
			cudaTextureObject_t output_tex,
			cudaTextureObject_t weights_tex,
			const packed_config<DIMENSION_COUNT+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int input_feature_map_count_striped,
			int output_feature_map_count,
			int output_feature_map_count_striped,
			int entry_count,
			int packed_config_count,
			int output_feature_map_group_size)
		{
			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (packed_config_id < packed_config_count);
			if (in_bounds)
			{
				int xyzw_input[DIMENSION_COUNT];
				int xyzw[DIMENSION_COUNT];
				int total_weight_count = window_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					total_weight_count *= window_sizes[i];
				int weight_count_per_striped_input_feature_map = total_weight_count;
				int weight_count_per_output_feature_map = input_feature_map_count_striped * total_weight_count;
				packed_config<DIMENSION_COUNT+2> conf = packed_config_list[packed_config_id];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw_input[i] = conf.get_val(i);
					xyzw[i] = xyzw_input[i] + left_zero_padding[i];
				}
				int input_feature_map_id_striped = conf.get_val(DIMENSION_COUNT);
				int base_output_feature_map_id_striped = conf.get_val(DIMENSION_COUNT + 1);
				int output_elem_id = entry_id * output_feature_map_count_striped + base_output_feature_map_id_striped;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_elem_id = output_elem_id * output_sizes[i] + xyzw[i];
				int weights_offset = ((base_output_feature_map_id_striped << 1) * input_feature_map_count_striped + input_feature_map_id_striped) * total_weight_count;
				int iteration_count = min(output_feature_map_group_size, output_feature_map_count_striped - base_output_feature_map_id_striped);

				float sums[FEATURE_MAP_BLOCK_SIZE * BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE * BLOCK_SIZE; ++i)
					sums[i] = 0.0F;

				for(int output_layer_id = 0; output_layer_id < iteration_count; ++output_layer_id)
				{
					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 1); input_w > (DIMENSION_COUNT > 3 ? xyzw[3] - window_sizes[3] : 0); --input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)output_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 1); input_z > (DIMENSION_COUNT > 2 ? xyzw[2] - window_sizes[2] : 0); --input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)output_sizes[2])) : true;
							for(int input_y = (DIMENSION_COUNT > 1 ? xyzw[1] : 1); input_y > (DIMENSION_COUNT > 1 ? xyzw[1] - window_sizes[1] : 0); --input_y)
							{
								bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)input_y < (unsigned int)output_sizes[1])) : true;

								#pragma unroll 4
								for(int input_x = xyzw[0]; input_x > xyzw[0] - window_sizes[0]; --input_x)
								{
									float2 weight_list[FEATURE_MAP_BLOCK_SIZE];
									#pragma unroll
									for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE/2; ++i)
									{
										weight_list[i] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_striped_input_feature_map * i);
										weight_list[i + (FEATURE_MAP_BLOCK_SIZE/2)] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_output_feature_map + weight_count_per_striped_input_feature_map * i);
									}

									#pragma unroll
									for(int j = 0; j < BLOCK_SIZE; ++j)
									{
										int output_x_total = input_x - j;
										bool b_fit0 = b_fit1 && ((unsigned int)output_x_total < (unsigned int)output_sizes[0]);
										float2 output_val = tex1Dfetch<float2>(output_tex, b_fit0 ? (output_elem_id - xyzw[0] + output_x_total) : -1);
										#pragma unroll
										for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE/2; ++i)
										{
											sums[(i * 2) * BLOCK_SIZE + j] += output_val.x * weight_list[i].x;
											sums[(i * 2) * BLOCK_SIZE + j] += output_val.y * weight_list[(FEATURE_MAP_BLOCK_SIZE/2) + i].x;
											sums[(i * 2 + 1) * BLOCK_SIZE + j] += output_val.x * weight_list[i].y;
											sums[(i * 2 + 1) * BLOCK_SIZE + j] += output_val.y * weight_list[(FEATURE_MAP_BLOCK_SIZE/2) + i].y;
										}
									}

									weights_offset++;
								}
								if (DIMENSION_COUNT == 1)
									output_elem_id += output_sizes[0];
								else
									output_elem_id -= output_sizes[0];
							} // for(int input_y
							if (DIMENSION_COUNT == 2)
								output_elem_id += output_sizes[0] * (window_sizes[1] + output_sizes[1]);
							else if (DIMENSION_COUNT > 2)
								output_elem_id += output_sizes[0] * (window_sizes[1] - output_sizes[1]);
						} // for(int input_z
						if (DIMENSION_COUNT == 3)
							output_elem_id += output_sizes[1] * output_sizes[0] * (window_sizes[2] + output_sizes[2]);
						else if (DIMENSION_COUNT > 3)
							output_elem_id += output_sizes[1] * output_sizes[0] * (window_sizes[2] - output_sizes[2]);
					} // for(int input_w
					if (DIMENSION_COUNT == 4)
						output_elem_id += output_sizes[2] * output_sizes[1] * output_sizes[0] * (window_sizes[3] + output_sizes[3]);
					weights_offset += (weight_count_per_output_feature_map << 1) - weight_count_per_striped_input_feature_map;
				} // for(int output_layer_id

				int input_feature_map_id = input_feature_map_id_striped << 1;
				int input_offset = entry_id * input_feature_map_count + input_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_offset = input_offset * input_sizes[i] + xyzw_input[i];
				float * base_input = input_errors + input_offset;
				int input_neuron_count_per_feature_map = input_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					input_neuron_count_per_feature_map *= input_sizes[i];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
				{
					if (i < input_feature_map_count - input_feature_map_id)
					{
						#pragma unroll
						for(int j = 0; j < BLOCK_SIZE; ++j)
						{
							if (j > xyzw_input[0] - input_sizes[0])
							{
								if (single_output_feature_map_group)
								{
									*(base_input + input_neuron_count_per_feature_map * i - j) = sums[i * BLOCK_SIZE + j];
								}
								else
								{
									atomicAdd(base_input + input_neuron_count_per_feature_map * i - j, sums[i * BLOCK_SIZE + j]);
								}
							}
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT, int BLOCK_SIZE, bool single_output_feature_map_group>
		__launch_bounds__(256, 4)
		__global__ void convolution_backprop_tex_generic_blocked_upd_kernel_kepler_instrumented(
			float * __restrict input_errors,
			cudaTextureObject_t output_tex,
			cudaTextureObject_t weights_tex,
			const packed_config<DIMENSION_COUNT+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int input_feature_map_count_striped,
			int output_feature_map_count,
			int output_feature_map_count_striped,
			int entry_count,
			int packed_config_count,
			int output_feature_map_group_size, /*)*/
                        unsigned long allotted_slice,
                        int *d_ret1,
                        int *d_ret2)
		{
                        if(yield(d_ret1, d_ret2, allotted_slice))
                          return;

			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (packed_config_id < packed_config_count);
			if (in_bounds)
			{
				int xyzw_input[DIMENSION_COUNT];
				int xyzw[DIMENSION_COUNT];
				int total_weight_count = window_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					total_weight_count *= window_sizes[i];
				int weight_count_per_striped_input_feature_map = total_weight_count;
				int weight_count_per_output_feature_map = input_feature_map_count_striped * total_weight_count;
				packed_config<DIMENSION_COUNT+2> conf = packed_config_list[packed_config_id];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw_input[i] = conf.get_val(i);
					xyzw[i] = xyzw_input[i] + left_zero_padding[i];
				}
				int input_feature_map_id_striped = conf.get_val(DIMENSION_COUNT);
				int base_output_feature_map_id_striped = conf.get_val(DIMENSION_COUNT + 1);
				int output_elem_id = entry_id * output_feature_map_count_striped + base_output_feature_map_id_striped;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_elem_id = output_elem_id * output_sizes[i] + xyzw[i];
				int weights_offset = ((base_output_feature_map_id_striped << 1) * input_feature_map_count_striped + input_feature_map_id_striped) * total_weight_count;
				int iteration_count = min(output_feature_map_group_size, output_feature_map_count_striped - base_output_feature_map_id_striped);

				float sums[FEATURE_MAP_BLOCK_SIZE * BLOCK_SIZE];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE * BLOCK_SIZE; ++i)
					sums[i] = 0.0F;

				for(int output_layer_id = 0; output_layer_id < iteration_count; ++output_layer_id)
				{
					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 1); input_w > (DIMENSION_COUNT > 3 ? xyzw[3] - window_sizes[3] : 0); --input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)output_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 1); input_z > (DIMENSION_COUNT > 2 ? xyzw[2] - window_sizes[2] : 0); --input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)output_sizes[2])) : true;
							for(int input_y = (DIMENSION_COUNT > 1 ? xyzw[1] : 1); input_y > (DIMENSION_COUNT > 1 ? xyzw[1] - window_sizes[1] : 0); --input_y)
							{
								bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)input_y < (unsigned int)output_sizes[1])) : true;

								#pragma unroll 4
								for(int input_x = xyzw[0]; input_x > xyzw[0] - window_sizes[0]; --input_x)
								{
									float2 weight_list[FEATURE_MAP_BLOCK_SIZE];
									#pragma unroll
									for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE/2; ++i)
									{
										weight_list[i] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_striped_input_feature_map * i);
										weight_list[i + (FEATURE_MAP_BLOCK_SIZE/2)] = tex1Dfetch<float2>(weights_tex, weights_offset + weight_count_per_output_feature_map + weight_count_per_striped_input_feature_map * i);
									}

									#pragma unroll
									for(int j = 0; j < BLOCK_SIZE; ++j)
									{
										int output_x_total = input_x - j;
										bool b_fit0 = b_fit1 && ((unsigned int)output_x_total < (unsigned int)output_sizes[0]);
										float2 output_val = tex1Dfetch<float2>(output_tex, b_fit0 ? (output_elem_id - xyzw[0] + output_x_total) : -1);
										#pragma unroll
										for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE/2; ++i)
										{
											sums[(i * 2) * BLOCK_SIZE + j] += output_val.x * weight_list[i].x;
											sums[(i * 2) * BLOCK_SIZE + j] += output_val.y * weight_list[(FEATURE_MAP_BLOCK_SIZE/2) + i].x;
											sums[(i * 2 + 1) * BLOCK_SIZE + j] += output_val.x * weight_list[i].y;
											sums[(i * 2 + 1) * BLOCK_SIZE + j] += output_val.y * weight_list[(FEATURE_MAP_BLOCK_SIZE/2) + i].y;
										}
									}

									weights_offset++;
								}
								if (DIMENSION_COUNT == 1)
									output_elem_id += output_sizes[0];
								else
									output_elem_id -= output_sizes[0];
							} // for(int input_y
							if (DIMENSION_COUNT == 2)
								output_elem_id += output_sizes[0] * (window_sizes[1] + output_sizes[1]);
							else if (DIMENSION_COUNT > 2)
								output_elem_id += output_sizes[0] * (window_sizes[1] - output_sizes[1]);
						} // for(int input_z
						if (DIMENSION_COUNT == 3)
							output_elem_id += output_sizes[1] * output_sizes[0] * (window_sizes[2] + output_sizes[2]);
						else if (DIMENSION_COUNT > 3)
							output_elem_id += output_sizes[1] * output_sizes[0] * (window_sizes[2] - output_sizes[2]);
					} // for(int input_w
					if (DIMENSION_COUNT == 4)
						output_elem_id += output_sizes[2] * output_sizes[1] * output_sizes[0] * (window_sizes[3] + output_sizes[3]);
					weights_offset += (weight_count_per_output_feature_map << 1) - weight_count_per_striped_input_feature_map;
				} // for(int output_layer_id

				int input_feature_map_id = input_feature_map_id_striped << 1;
				int input_offset = entry_id * input_feature_map_count + input_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_offset = input_offset * input_sizes[i] + xyzw_input[i];
				float * base_input = input_errors + input_offset;
				int input_neuron_count_per_feature_map = input_sizes[0];
				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					input_neuron_count_per_feature_map *= input_sizes[i];
				#pragma unroll
				for(int i = 0; i < FEATURE_MAP_BLOCK_SIZE; ++i)
				{
					if (i < input_feature_map_count - input_feature_map_id)
					{
						#pragma unroll
						for(int j = 0; j < BLOCK_SIZE; ++j)
						{
							if (j > xyzw_input[0] - input_sizes[0])
							{
								if (single_output_feature_map_group)
								{
									*(base_input + input_neuron_count_per_feature_map * i - j) = sums[i * BLOCK_SIZE + j];
								}
								else
								{
									atomicAdd(base_input + input_neuron_count_per_feature_map * i - j, sums[i * BLOCK_SIZE + j]);
								}
							}
						}
					}
				}
			}
		}

		extern __shared__ float arr[];
		__global__ void convolution_update_biases_upd_kernel_kepler(
			float * __restrict gradient_biases,
			const float * __restrict output_errors,
			int block_size,
			int output_elem_count_per_feature_map,
			int output_feature_map_count,
			int entry_count)
		{
			int output_neuron_id = blockIdx.x * blockDim.x + threadIdx.x;
			int output_feature_map_id = blockIdx.y;
			int block_id = blockIdx.z * blockDim.z + threadIdx.z;
			int base_entry_id = block_size * block_id;
			int thread_id = blockDim.x * threadIdx.z + threadIdx.x;
			int threadblock_size = blockDim.x * blockDim.z;
			float sum = 0.0F;
			int iteration_count = min(entry_count - base_entry_id, block_size);
			if (output_neuron_id < output_elem_count_per_feature_map)
			{
				const float * current_error = output_errors + (base_entry_id * output_feature_map_count + output_feature_map_id) * output_elem_count_per_feature_map + output_neuron_id;
				int output_elem_count_per_entry = output_elem_count_per_feature_map * output_feature_map_count;
				for(int i = 0; i < iteration_count; ++i)
				{
					sum += *current_error;
					current_error += output_elem_count_per_entry;
				}
			}
			arr[thread_id] = sum;
			__syncthreads();

			int t_add_elems = threadblock_size >> 1;
			int t_working_elems = (threadblock_size + 1) >> 1;
			while (t_add_elems > 0)
			{
				if (thread_id < t_add_elems)
					arr[thread_id] += arr[thread_id + t_working_elems];
				t_add_elems = t_working_elems >> 1;
				t_working_elems = (t_working_elems + 1) >> 1;
				__syncthreads();
			}

			if (thread_id == 0)
				atomicAdd(gradient_biases + output_feature_map_id, arr[0]);
		}

		template<int DIMENSION_COUNT, int WINDOW_WIDTH>
		__launch_bounds__(256, 4)
		__global__ void convolution_update_weights_exact_upd_kernel_kepler(
			float2 * __restrict gradient_weights,
			cudaTextureObject_t input_tex,
			cudaTextureObject_t output_tex,
			const packed_config<DIMENSION_COUNT*2+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int output_feature_map_count,
			int input_feature_map_count_striped,
			int output_feature_map_count_striped,
			int input_elem_count_per_entry_striped,
			int output_elem_count_per_entry_striped,
			int entry_count,
			int packed_config_count,
			int last_dimension_group_count)
		{
			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (packed_config_id < packed_config_count) && (entry_id < entry_count);
			if (in_bounds)
			{
				packed_config<DIMENSION_COUNT*2+2> conf = packed_config_list[packed_config_id];
				int weight_xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
					weight_xyzw[i] = conf.get_val(i);
				int xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
					xyzw[i] = conf.get_val(i + DIMENSION_COUNT);

				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
				{
					int input_v = xyzw[i] + weight_xyzw[i] - left_zero_padding[i];
					if ((unsigned int)input_v >= (unsigned int)input_sizes[i])
						return;
				}

				int input_feature_map_striped_id = conf.get_val(DIMENSION_COUNT * 2);
				int output_feature_map_striped_id = conf.get_val(DIMENSION_COUNT * 2 + 1);

				int output_errors_offset = entry_id * output_feature_map_count_striped + output_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_errors_offset = output_errors_offset * output_sizes[i] + xyzw[i];

				int input_elem_id = entry_id * input_feature_map_count_striped + input_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id = input_elem_id * input_sizes[i] + xyzw[i] + weight_xyzw[i] - left_zero_padding[i];

				float sums[WINDOW_WIDTH * 4];
				#pragma unroll
				for(int i = 0; i < WINDOW_WIDTH * 4; ++i)
					sums[i] = 0.0F;

				int iteration_count_x = output_sizes[0];

				int output_shift = last_dimension_group_count * output_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
					output_shift *= output_sizes[i];
				output_shift -= iteration_count_x;

				int input_shift = last_dimension_group_count * input_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
					input_shift *= input_sizes[i];
				input_shift -= iteration_count_x + (WINDOW_WIDTH - 1);

				int input_last = (DIMENSION_COUNT > 1 ? xyzw[DIMENSION_COUNT - 1] + weight_xyzw[DIMENSION_COUNT - 1] - left_zero_padding[DIMENSION_COUNT - 1] : 0);
				for(int t = (DIMENSION_COUNT > 1 ? xyzw[DIMENSION_COUNT - 1] : 0); t < (DIMENSION_COUNT > 1 ? output_sizes[DIMENSION_COUNT - 1] : 1); t += (DIMENSION_COUNT > 1 ? last_dimension_group_count : 1))
				{
					bool b_fit_l = (DIMENSION_COUNT > 1 ? ((unsigned int)input_last < (unsigned int)input_sizes[DIMENSION_COUNT - 1]) : true);
					int input_x = xyzw[0] + weight_xyzw[0] - left_zero_padding[0];

					float2 input_buf[WINDOW_WIDTH];
					#pragma unroll
					for(int i = 1; i < WINDOW_WIDTH; ++i)
					{
						bool b_fit = b_fit_l && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
						input_buf[i] = tex1Dfetch<float2>(input_tex, b_fit ? input_elem_id : -1);
						++input_x;
						++input_elem_id;
					}

					#pragma unroll 4
					for(int x = 0; x < iteration_count_x; ++x)
					{
						float2 output_error = tex1Dfetch<float2>(output_tex, output_errors_offset);

						#pragma unroll
						for(int i = 0; i < WINDOW_WIDTH - 1; ++i)
							input_buf[i] = input_buf[i + 1];
						bool b_fit = b_fit_l && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
						input_buf[WINDOW_WIDTH - 1] = tex1Dfetch<float2>(input_tex, b_fit ? input_elem_id : -1);

						#pragma unroll
						for(int j = 0; j < WINDOW_WIDTH; ++j)
						{
							sums[j * 4] += output_error.x * input_buf[j].x;
							sums[j * 4 + 1] += output_error.x * input_buf[j].y;
							sums[j * 4 + 2] += output_error.y * input_buf[j].x;
							sums[j * 4 + 3] += output_error.y * input_buf[j].y;
						}

						++output_errors_offset;
						++input_elem_id;
						++input_x;
					}

					output_errors_offset += output_shift;
					input_elem_id += input_shift;
					input_last += last_dimension_group_count;
				}

				int output_feature_map_id = output_feature_map_striped_id * 2;
				int weights_offset = output_feature_map_id * input_feature_map_count_striped + input_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					weights_offset = weights_offset * window_sizes[i] + weight_xyzw[i];
				int weight_count_per_feature_map_pair = window_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					weight_count_per_feature_map_pair *= window_sizes[i];

				#pragma unroll
				for(int i = 0; i < 2; ++i)
				{
					if (output_feature_map_id + i < output_feature_map_count)
					{
						int weights_offset1 = weights_offset + i * (input_feature_map_count_striped * weight_count_per_feature_map_pair);
						#pragma unroll
						for(int k = 0; k < WINDOW_WIDTH; ++k)
						{
							int weights_offset3 = weights_offset1 + k;
							float upd_val1 = sums[k * 4 + i * 2];
							float upd_val2 = sums[k * 4 + i * 2 + 1];
							atomicAdd((float *)(gradient_weights + weights_offset3), upd_val1);
							atomicAdd((float *)(gradient_weights + weights_offset3) + 1, upd_val2);
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT, int WINDOW_WIDTH>
		__launch_bounds__(256, 4)
		__global__ void convolution_update_weights_exact_upd_kernel_kepler_instrumented(
			float2 * __restrict gradient_weights,
			cudaTextureObject_t input_tex,
			cudaTextureObject_t output_tex,
			const packed_config<DIMENSION_COUNT*2+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int output_feature_map_count,
			int input_feature_map_count_striped,
			int output_feature_map_count_striped,
			int input_elem_count_per_entry_striped,
			int output_elem_count_per_entry_striped,
			int entry_count,
			int packed_config_count,
			int last_dimension_group_count,/*)*/
                        unsigned long allotted_slice,
                        int *d_ret1,
                        int *d_ret2)
		{
                        if(yield(d_ret1, d_ret2, allotted_slice))
                          return;

			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;
                     #if 0
                        __shared__ bool yield;
                        int elapsed = 0;
                        unsigned long long int start_clock = clock64();
                        int mysmid = __smid();
                        if(threadIdx.x == 0)
                        {
                           if(blockIdx.x + blockIdx.y * gridDim.x < 60)
                           {
                                
                              if(atomicCAS(&d_clock_initialized[mysmid], 0, 1)==0)
                              {
                                  atomicExch(&d_zero_clock[mysmid], start_clock);
                                  yield = false;
                              }
                              else
                              {
				  elapsed = start_clock - d_zero_clock[mysmid];
                                  if(elapsed < 1000) /*Less than 1 us should include all blocks in a dispatch set*/
                                  {
                                      yield = false;
				      atomicMax(&d_yield_point, blockIdx.x + blockIdx.y * gridDim.x);
				      atomicMax(&d_elapsed, elapsed);
                                  }
                                  else
                                  {
                                      yield = true;
                                  }
                              }
                           }
                           else
                           {
			      //if(blockIdx.x + blockIdx.y * gridDim.x % 1000 == 0)
			        //printf("%d %d\n", blockIdx.x + blockIdx.y * gridDim.x, elapsed);
			      if(blockIdx.x + blockIdx.y * gridDim.x < d_yield_point_persist)
                              {
				      yield = true;
                              }
			      else
                              {
                                      /*if(d_yield == 1)
                                      {
                                          yield = true;
                                      }
                                      else
                                      {
                                          yield = false;
                                      }*/
                              
				      elapsed = start_clock - d_zero_clock[mysmid];
				      if(elapsed >= allotted_slice/*20000000*/)
				      {
					      yield = true;
				      }
				      else
				      {
					      yield = false;
					      atomicMax(&d_yield_point, blockIdx.x + blockIdx.y * gridDim.x);
					      atomicMax(&d_elapsed, elapsed);
				      }
                              
                              }
                              
                              if(blockIdx.x + blockIdx.y * gridDim.x == gridDim.x * gridDim.y - 1)
                              {
                                  unsigned int val = atomicExch(&d_yield_point, 0);

                                  if(val == gridDim.x * gridDim.y - 1)
                                      atomicExch(&d_yield_point_persist, 0);
                                  else
                                      atomicExch(&d_yield_point_persist, val);
                                  
                                  *d_ret1 = val; 
                                  val = atomicExch(&d_elapsed, 0);
                                  *d_ret2 = val; 
				  for(int i=0; i<15; i++)
				  {
					  atomicExch(&d_clock_initialized[i],0);
					  unsigned int val = atomicExch(&d_clock_initialized[i],0);
				  }
                              }
                              
                            }
                        }
                        __syncthreads();
                        if(yield==true)
                        {
				return;                           
                        }
                      #endif

			bool in_bounds = (packed_config_id < packed_config_count) && (entry_id < entry_count);
			if (in_bounds)
			{
				packed_config<DIMENSION_COUNT*2+2> conf = packed_config_list[packed_config_id];
				int weight_xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
					weight_xyzw[i] = conf.get_val(i);
				int xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
					xyzw[i] = conf.get_val(i + DIMENSION_COUNT);

				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
				{
					int input_v = xyzw[i] + weight_xyzw[i] - left_zero_padding[i];
					if ((unsigned int)input_v >= (unsigned int)input_sizes[i])
						return;
				}

				int input_feature_map_striped_id = conf.get_val(DIMENSION_COUNT * 2);
				int output_feature_map_striped_id = conf.get_val(DIMENSION_COUNT * 2 + 1);

				int output_errors_offset = entry_id * output_feature_map_count_striped + output_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_errors_offset = output_errors_offset * output_sizes[i] + xyzw[i];

				int input_elem_id = entry_id * input_feature_map_count_striped + input_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id = input_elem_id * input_sizes[i] + xyzw[i] + weight_xyzw[i] - left_zero_padding[i];

				float sums[WINDOW_WIDTH * 4];
				#pragma unroll
				for(int i = 0; i < WINDOW_WIDTH * 4; ++i)
					sums[i] = 0.0F;

				int iteration_count_x = output_sizes[0];

				int output_shift = last_dimension_group_count * output_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
					output_shift *= output_sizes[i];
				output_shift -= iteration_count_x;

				int input_shift = last_dimension_group_count * input_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
					input_shift *= input_sizes[i];
				input_shift -= iteration_count_x + (WINDOW_WIDTH - 1);

				int input_last = (DIMENSION_COUNT > 1 ? xyzw[DIMENSION_COUNT - 1] + weight_xyzw[DIMENSION_COUNT - 1] - left_zero_padding[DIMENSION_COUNT - 1] : 0);
				for(int t = (DIMENSION_COUNT > 1 ? xyzw[DIMENSION_COUNT - 1] : 0); t < (DIMENSION_COUNT > 1 ? output_sizes[DIMENSION_COUNT - 1] : 1); t += (DIMENSION_COUNT > 1 ? last_dimension_group_count : 1))
				{
					bool b_fit_l = (DIMENSION_COUNT > 1 ? ((unsigned int)input_last < (unsigned int)input_sizes[DIMENSION_COUNT - 1]) : true);
					int input_x = xyzw[0] + weight_xyzw[0] - left_zero_padding[0];

					float2 input_buf[WINDOW_WIDTH];
					#pragma unroll
					for(int i = 1; i < WINDOW_WIDTH; ++i)
					{
						bool b_fit = b_fit_l && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
						input_buf[i] = tex1Dfetch<float2>(input_tex, b_fit ? input_elem_id : -1);
						++input_x;
						++input_elem_id;
					}

					#pragma unroll 4
					for(int x = 0; x < iteration_count_x; ++x)
					{
						float2 output_error = tex1Dfetch<float2>(output_tex, output_errors_offset);

						#pragma unroll
						for(int i = 0; i < WINDOW_WIDTH - 1; ++i)
							input_buf[i] = input_buf[i + 1];
						bool b_fit = b_fit_l && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
						input_buf[WINDOW_WIDTH - 1] = tex1Dfetch<float2>(input_tex, b_fit ? input_elem_id : -1);

						#pragma unroll
						for(int j = 0; j < WINDOW_WIDTH; ++j)
						{
							sums[j * 4] += output_error.x * input_buf[j].x;
							sums[j * 4 + 1] += output_error.x * input_buf[j].y;
							sums[j * 4 + 2] += output_error.y * input_buf[j].x;
							sums[j * 4 + 3] += output_error.y * input_buf[j].y;
						}

						++output_errors_offset;
						++input_elem_id;
						++input_x;
					}

					output_errors_offset += output_shift;
					input_elem_id += input_shift;
					input_last += last_dimension_group_count;
				}

				int output_feature_map_id = output_feature_map_striped_id * 2;
				int weights_offset = output_feature_map_id * input_feature_map_count_striped + input_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					weights_offset = weights_offset * window_sizes[i] + weight_xyzw[i];
				int weight_count_per_feature_map_pair = window_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					weight_count_per_feature_map_pair *= window_sizes[i];

				#pragma unroll
				for(int i = 0; i < 2; ++i)
				{
					if (output_feature_map_id + i < output_feature_map_count)
					{
						int weights_offset1 = weights_offset + i * (input_feature_map_count_striped * weight_count_per_feature_map_pair);
						#pragma unroll
						for(int k = 0; k < WINDOW_WIDTH; ++k)
						{
							int weights_offset3 = weights_offset1 + k;
							float upd_val1 = sums[k * 4 + i * 2];
							float upd_val2 = sums[k * 4 + i * 2 + 1];
							atomicAdd((float *)(gradient_weights + weights_offset3), upd_val1);
							atomicAdd((float *)(gradient_weights + weights_offset3) + 1, upd_val2);
						}
					}
				}
			}/*else{
                                printf("%d %d %d\n", blockIdx.x, blockIdx.y, threadIdx.x);
                        }*/
                        /*
                        if(threadIdx.x == 0)
                        {
                           elapsed = clock64() - d_zero_clock[mysmid];
			   if(elapsed >= 10000000)
			   {
			       atomicExch(&d_yield, 1);
			    }
			    else
			    {
			       atomicMax(&d_yield_point, blockIdx.x + blockIdx.y * gridDim.x);
			       atomicMax(&d_elapsed, elapsed);
			    }
                        }
                        */
		}

		template<int DIMENSION_COUNT>
		__launch_bounds__(256, 4)
		__global__ void convolution_update_weights_generic_upd_kernel_kepler(
			float2 * __restrict gradient_weights,
			cudaTextureObject_t input_tex,
			cudaTextureObject_t output_tex,
			const packed_config<DIMENSION_COUNT*2+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int output_feature_map_count,
			int input_feature_map_count_striped,
			int output_feature_map_count_striped,
			int input_elem_count_per_entry_striped,
			int output_elem_count_per_entry_striped,
			int entry_count,
			int packed_config_count,
			int last_dimension_group_count)
		{

			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (packed_config_id < packed_config_count) && (entry_id < entry_count);
			if (in_bounds)
			{
				packed_config<DIMENSION_COUNT*2+2> conf = packed_config_list[packed_config_id];
				int weight_xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
					weight_xyzw[i] = conf.get_val(i);
				int xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
					xyzw[i] = conf.get_val(i + DIMENSION_COUNT);

				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
				{
					int input_v = xyzw[i] + weight_xyzw[i] - left_zero_padding[i];
					if ((unsigned int)input_v >= (unsigned int)input_sizes[i])
						return;
				}

				int input_feature_map_striped_id = conf.get_val(DIMENSION_COUNT * 2);
				int output_feature_map_striped_id = conf.get_val(DIMENSION_COUNT * 2 + 1);

				int output_errors_offset = entry_id * output_feature_map_count_striped + output_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_errors_offset = output_errors_offset * output_sizes[i] + xyzw[i];

				int input_elem_id = entry_id * input_feature_map_count_striped + input_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id = input_elem_id * input_sizes[i] + xyzw[i] + weight_xyzw[i] - left_zero_padding[i];

				float sums[WINDOW_WIDTH_LOCAL * 4];
				#pragma unroll
				for(int i = 0; i < WINDOW_WIDTH_LOCAL * 4; ++i)
					sums[i] = 0.0F;

				int iteration_count_x = output_sizes[0];

				int output_shift = last_dimension_group_count * output_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
					output_shift *= output_sizes[i];
				output_shift -= iteration_count_x;

				int input_shift = last_dimension_group_count * input_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
					input_shift *= input_sizes[i];
				input_shift -= (iteration_count_x + (WINDOW_WIDTH_LOCAL - 1));

				int input_last = (DIMENSION_COUNT > 1 ? xyzw[DIMENSION_COUNT - 1] + weight_xyzw[DIMENSION_COUNT - 1] - left_zero_padding[DIMENSION_COUNT - 1] : 0);
				for(int t = (DIMENSION_COUNT > 1 ? xyzw[DIMENSION_COUNT - 1] : 0); t < (DIMENSION_COUNT > 1 ? output_sizes[DIMENSION_COUNT - 1] : 1); t += (DIMENSION_COUNT > 1 ? last_dimension_group_count : 1))
				{
					bool b_fit_l = (DIMENSION_COUNT > 1 ? ((unsigned int)input_last < (unsigned int)input_sizes[DIMENSION_COUNT - 1]) : true);
					int input_x = xyzw[0] + weight_xyzw[0] - left_zero_padding[0];

					float2 input_buf[WINDOW_WIDTH_LOCAL];
					#pragma unroll
					for(int i = 1; i < WINDOW_WIDTH_LOCAL; ++i)
					{
						bool b_fit = b_fit_l && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
						input_buf[i] = tex1Dfetch<float2>(input_tex, b_fit ? input_elem_id : -1);
						++input_x;
						++input_elem_id;
					}

					#pragma unroll 4
					for(int x = 0; x < iteration_count_x; ++x)
					{
						float2 output_error = tex1Dfetch<float2>(output_tex, output_errors_offset);

						#pragma unroll
						for(int i = 0; i < WINDOW_WIDTH_LOCAL - 1; ++i)
							input_buf[i] = input_buf[i + 1];
						bool b_fit = b_fit_l && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
						input_buf[WINDOW_WIDTH_LOCAL - 1] = tex1Dfetch<float2>(input_tex, b_fit ? input_elem_id : -1);

						#pragma unroll
						for(int j = 0; j < WINDOW_WIDTH_LOCAL; ++j)
						{
							sums[j * 4] += output_error.x * input_buf[j].x;
							sums[j * 4 + 1] += output_error.x * input_buf[j].y;
							sums[j * 4 + 2] += output_error.y * input_buf[j].x;
							sums[j * 4 + 3] += output_error.y * input_buf[j].y;
						}

						output_errors_offset++;
						input_elem_id++;
						++input_x;
					}

					output_errors_offset += output_shift;
					input_elem_id += input_shift;
					input_last += last_dimension_group_count;
				}

				int output_feature_map_id = output_feature_map_striped_id * 2;
				int weights_offset = output_feature_map_id * input_feature_map_count_striped + input_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					weights_offset = weights_offset * window_sizes[i] + weight_xyzw[i];
				int weight_count_per_feature_map_pair = window_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					weight_count_per_feature_map_pair *= window_sizes[i];

				#pragma unroll
				for(int i = 0; i < 2; ++i)
				{
					if (output_feature_map_id + i < output_feature_map_count)
					{
						int weights_offset1 = weights_offset + i * (input_feature_map_count_striped * weight_count_per_feature_map_pair);
						#pragma unroll
						for(int k = 0; k < WINDOW_WIDTH_LOCAL; ++k)
						{
							if (k < window_sizes[0] - weight_xyzw[0])
							{
								int weights_offset3 = weights_offset1 + k;
								float upd_val1 = sums[k * 4 + i * 2];
								float upd_val2 = sums[k * 4 + i * 2 + 1];
								atomicAdd((float *)(gradient_weights + weights_offset3), upd_val1);
								atomicAdd((float *)(gradient_weights + weights_offset3) + 1, upd_val2);
							}
						}
					}
				}
			}
		}

		template<int DIMENSION_COUNT>
		__launch_bounds__(256, 4)
		__global__ void convolution_update_weights_generic_upd_kernel_kepler_instrumented(
			float2 * __restrict gradient_weights,
			cudaTextureObject_t input_tex,
			cudaTextureObject_t output_tex,
			const packed_config<DIMENSION_COUNT*2+2> * __restrict packed_config_list,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int output_feature_map_count,
			int input_feature_map_count_striped,
			int output_feature_map_count_striped,
			int input_elem_count_per_entry_striped,
			int output_elem_count_per_entry_striped,
			int entry_count,
			int packed_config_count,
			int last_dimension_group_count,/*)*/
                        unsigned long allotted_slice,
                        int *d_ret1,
                        int *d_ret2)
		{
                     #if 0
                        __shared__ bool yield;
                        int elapsed = 0;
                        unsigned long long int start_clock = clock64();
                        int mysmid = __smid();
                        if(threadIdx.x == 0)
                        {
                           if(blockIdx.x + blockIdx.y * gridDim.x < 60)
                           {
                                
                              if(atomicCAS(&d_clock_initialized[mysmid], 0, 1)==0)
                              {
                                  atomicExch(&d_zero_clock[mysmid], start_clock);
                                  yield = false;
                              }
                              else
                              {
				  elapsed = start_clock - d_zero_clock[mysmid];
                                  if(elapsed < 1000) /*Less than 1 us should include all blocks in a dispatch set*/
                                  {
                                      yield = false;
				      atomicMax(&d_yield_point, blockIdx.x + blockIdx.y * gridDim.x);
				      atomicMax(&d_elapsed, elapsed);
                                  }
                                  else
                                  {
                                      yield = true;
                                  }
                              }
                           }
                           else
                           {
			      if(blockIdx.x + blockIdx.y * gridDim.x < d_yield_point_persist)
                              {
				      yield = true;
                              }
			      else
                              {
				      elapsed = start_clock - d_zero_clock[mysmid];
				      if(elapsed >= 10000000)
				      {
					      yield = true;
				      }
				      else
				      {
					      yield = false;
					      atomicMax(&d_yield_point, blockIdx.x + blockIdx.y * gridDim.x);
					      atomicMax(&d_elapsed, elapsed);
				      }
                              }
                              if(blockIdx.x + blockIdx.y * gridDim.x == gridDim.x * gridDim.y - 1)
                              {
                                  unsigned int val = atomicExch(&d_yield_point, 0);
                                  atomicExch(&d_yield_point_persist, val);
                                  *d_ret1 = val; 
                                  val = atomicExch(&d_elapsed, 0);
                                  *d_ret2 = val; 
				  for(int i=0; i<15; i++)
				  {
					  atomicExch(&d_clock_initialized[i],0);
					  unsigned int val = atomicExch(&d_clock_initialized[i],0);
				  }
                              }
                            }
                        }
                        __syncthreads();
                        if(yield==true)
                        {
				return;                           
                        }
                      #endif

			int packed_config_id = blockIdx.x * blockDim.x + threadIdx.x;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (packed_config_id < packed_config_count) && (entry_id < entry_count);
			if (in_bounds)
			{
				packed_config<DIMENSION_COUNT*2+2> conf = packed_config_list[packed_config_id];
				int weight_xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
					weight_xyzw[i] = conf.get_val(i);
				int xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
					xyzw[i] = conf.get_val(i + DIMENSION_COUNT);

				#pragma unroll
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
				{
					int input_v = xyzw[i] + weight_xyzw[i] - left_zero_padding[i];
					if ((unsigned int)input_v >= (unsigned int)input_sizes[i])
						return;
				}

				int input_feature_map_striped_id = conf.get_val(DIMENSION_COUNT * 2);
				int output_feature_map_striped_id = conf.get_val(DIMENSION_COUNT * 2 + 1);

				int output_errors_offset = entry_id * output_feature_map_count_striped + output_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_errors_offset = output_errors_offset * output_sizes[i] + xyzw[i];

				int input_elem_id = entry_id * input_feature_map_count_striped + input_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id = input_elem_id * input_sizes[i] + xyzw[i] + weight_xyzw[i] - left_zero_padding[i];

				float sums[WINDOW_WIDTH_LOCAL * 4];
				#pragma unroll
				for(int i = 0; i < WINDOW_WIDTH_LOCAL * 4; ++i)
					sums[i] = 0.0F;

				int iteration_count_x = output_sizes[0];

				int output_shift = last_dimension_group_count * output_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
					output_shift *= output_sizes[i];
				output_shift -= iteration_count_x;

				int input_shift = last_dimension_group_count * input_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT - 1; ++i)
					input_shift *= input_sizes[i];
				input_shift -= (iteration_count_x + (WINDOW_WIDTH_LOCAL - 1));

				int input_last = (DIMENSION_COUNT > 1 ? xyzw[DIMENSION_COUNT - 1] + weight_xyzw[DIMENSION_COUNT - 1] - left_zero_padding[DIMENSION_COUNT - 1] : 0);
				for(int t = (DIMENSION_COUNT > 1 ? xyzw[DIMENSION_COUNT - 1] : 0); t < (DIMENSION_COUNT > 1 ? output_sizes[DIMENSION_COUNT - 1] : 1); t += (DIMENSION_COUNT > 1 ? last_dimension_group_count : 1))
				{
					bool b_fit_l = (DIMENSION_COUNT > 1 ? ((unsigned int)input_last < (unsigned int)input_sizes[DIMENSION_COUNT - 1]) : true);
					int input_x = xyzw[0] + weight_xyzw[0] - left_zero_padding[0];

					float2 input_buf[WINDOW_WIDTH_LOCAL];
					#pragma unroll
					for(int i = 1; i < WINDOW_WIDTH_LOCAL; ++i)
					{
						bool b_fit = b_fit_l && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
						input_buf[i] = tex1Dfetch<float2>(input_tex, b_fit ? input_elem_id : -1);
						++input_x;
						++input_elem_id;
					}

					#pragma unroll 4
					for(int x = 0; x < iteration_count_x; ++x)
					{
						float2 output_error = tex1Dfetch<float2>(output_tex, output_errors_offset);

						#pragma unroll
						for(int i = 0; i < WINDOW_WIDTH_LOCAL - 1; ++i)
							input_buf[i] = input_buf[i + 1];
						bool b_fit = b_fit_l && ((unsigned int)input_x < (unsigned int)input_sizes[0]);
						input_buf[WINDOW_WIDTH_LOCAL - 1] = tex1Dfetch<float2>(input_tex, b_fit ? input_elem_id : -1);

						#pragma unroll
						for(int j = 0; j < WINDOW_WIDTH_LOCAL; ++j)
						{
							sums[j * 4] += output_error.x * input_buf[j].x;
							sums[j * 4 + 1] += output_error.x * input_buf[j].y;
							sums[j * 4 + 2] += output_error.y * input_buf[j].x;
							sums[j * 4 + 3] += output_error.y * input_buf[j].y;
						}

						output_errors_offset++;
						input_elem_id++;
						++input_x;
					}

					output_errors_offset += output_shift;
					input_elem_id += input_shift;
					input_last += last_dimension_group_count;
				}

				int output_feature_map_id = output_feature_map_striped_id * 2;
				int weights_offset = output_feature_map_id * input_feature_map_count_striped + input_feature_map_striped_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					weights_offset = weights_offset * window_sizes[i] + weight_xyzw[i];
				int weight_count_per_feature_map_pair = window_sizes[0];
				for(int i = 1; i < DIMENSION_COUNT; ++i)
					weight_count_per_feature_map_pair *= window_sizes[i];

				#pragma unroll
				for(int i = 0; i < 2; ++i)
				{
					if (output_feature_map_id + i < output_feature_map_count)
					{
						int weights_offset1 = weights_offset + i * (input_feature_map_count_striped * weight_count_per_feature_map_pair);
						#pragma unroll
						for(int k = 0; k < WINDOW_WIDTH_LOCAL; ++k)
						{
							if (k < window_sizes[0] - weight_xyzw[0])
							{
								int weights_offset3 = weights_offset1 + k;
								float upd_val1 = sums[k * 4 + i * 2];
								float upd_val2 = sums[k * 4 + i * 2 + 1];
								atomicAdd((float *)(gradient_weights + weights_offset3), upd_val1);
								atomicAdd((float *)(gradient_weights + weights_offset3) + 1, upd_val2);
							}
						}
					}
				}
			}
		}
#define launch_exact_kernel_const_const_const_const(dimension_count_const, window_width_const, block_size_const, single_input_feature_map_group_count_const) \
	convolution_tex_exact_blocked_upd_kernel_kepler<dimension_count_const,window_width_const,block_size_const,single_input_feature_map_group_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*output_neurons_buffer, input_tex, weights_tex, *data[1], packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific_striped.feature_map_count, output_configuration_specific.feature_map_count, entry_count, forward_packed_config_count, forward_input_feature_map_group_size);

#define launch_generic_kernel_const_const_const(dimension_count_const, block_size_const, single_input_feature_map_group_count_const) \
	convolution_tex_generic_blocked_upd_kernel_kepler<dimension_count_const,block_size_const,single_input_feature_map_group_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*output_neurons_buffer, input_tex, weights_tex, *data[1], packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific_striped.feature_map_count, output_configuration_specific.feature_map_count, entry_count, forward_packed_config_count, forward_input_feature_map_group_size);

#define launch_kernel_const_const_cost(dimension_count_const, window_width, block_size_const, single_input_feature_map_group_count_const) \
	switch (window_width) \
		{ \
		case 1: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 1, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 2: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 2, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 3: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 3, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 4: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 4, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 5: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 5, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 6: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 6, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 7: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 7, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 8: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 8, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 9: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 9, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		case 10: \
			launch_exact_kernel_const_const_const_const(dimension_count_const, 10, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		default: \
			launch_generic_kernel_const_const_const(dimension_count_const, block_size_const, single_input_feature_map_group_count_const); \
			break; \
		};

#define launch_kernel_const_const(dimension_count_const, window_width, block_size, single_input_feature_map_group_count_const) \
	switch (block_size) \
		{ \
		case 1: \
			launch_kernel_const_const_cost(dimension_count_const, window_width, 1, single_input_feature_map_group_count_const); \
			break; \
		case 2: \
			launch_kernel_const_const_cost(dimension_count_const, window_width, 2, single_input_feature_map_group_count_const); \
			break; \
		case 3: \
			launch_kernel_const_const_cost(dimension_count_const, window_width, 3, single_input_feature_map_group_count_const); \
			break; \
		case 4: \
			launch_kernel_const_const_cost(dimension_count_const, window_width, 4, single_input_feature_map_group_count_const); \
			break; \
		case 5: \
			launch_kernel_const_const_cost(dimension_count_const, window_width, 5, single_input_feature_map_group_count_const); \
			break; \
		};

#define launch_kernel(dimension_count_const, window_width, block_size, single_input_feature_map_group_count) \
	switch (single_input_feature_map_group_count) \
		{ \
		case false: \
			launch_kernel_const_const(dimension_count_const, window_width, block_size, false); \
			break; \
		case true: \
			launch_kernel_const_const(dimension_count_const, window_width, block_size, true); \
			break; \
		};

#define launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, window_width_const, block_size_const, single_input_feature_map_group_count_const, allotted_slice) \
	convolution_tex_exact_blocked_upd_kernel_kepler_instrumented<dimension_count_const,window_width_const,block_size_const,single_input_feature_map_group_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*output_neurons_buffer, input_tex, weights_tex, *data[1], packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific_striped.feature_map_count, output_configuration_specific.feature_map_count, entry_count, forward_packed_config_count, forward_input_feature_map_group_size, allotted_slice, d_yield_point_ret, d_elapsed_ret);

#define launch_generic_kernel_const_const_const_instrumented(dimension_count_const, block_size_const, single_input_feature_map_group_count_const, allotted_slice) \
	convolution_tex_generic_blocked_upd_kernel_kepler_instrumented<dimension_count_const,block_size_const,single_input_feature_map_group_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*output_neurons_buffer, input_tex, weights_tex, *data[1], packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific_striped.feature_map_count, output_configuration_specific.feature_map_count, entry_count, forward_packed_config_count, forward_input_feature_map_group_size, allotted_slice, d_yield_point_ret, d_elapsed_ret);

#define launch_kernel_const_const_cost_instrumented(dimension_count_const, window_width, block_size_const, single_input_feature_map_group_count_const, allotted_slice) \
	switch (window_width) \
		{ \
		case 1: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 1, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 2: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 2, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 3: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 3, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 4: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 4, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 5: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 5, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 6: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 6, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 7: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 7, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 8: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 8, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 9: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 9, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 10: \
			launch_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 10, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		default: \
			launch_generic_kernel_const_const_const_instrumented(dimension_count_const, block_size_const, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		};

#define launch_kernel_const_const_instrumented(dimension_count_const, window_width, block_size, single_input_feature_map_group_count_const, allotted_slice) \
	switch (block_size) \
		{ \
		case 1: \
			launch_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 1, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 2: \
			launch_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 2, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 3: \
			launch_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 3, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 4: \
			launch_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 4, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		case 5: \
			launch_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 5, single_input_feature_map_group_count_const, allotted_slice); \
			break; \
		};

#define launch_kernel_instrumented(dimension_count_const, window_width, block_size, single_input_feature_map_group_count, allotted_slice) \
	switch (single_input_feature_map_group_count) \
		{ \
		case false: \
			launch_kernel_const_const_instrumented(dimension_count_const, window_width, block_size, false, allotted_slice); \
			break; \
		case true: \
			launch_kernel_const_const_instrumented(dimension_count_const, window_width, block_size, true, allotted_slice); \
			break; \
		};

#define launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, window_width_const, block_size_const, single_output_feature_map_group_count_const) \
	convolution_backprop_tex_exact_blocked_upd_kernel_kepler<dimension_count_const,window_width_const,block_size_const,single_output_feature_map_group_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*input_errors_buffer, output_tex, weights_tex, packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, input_configuration_specific_striped.feature_map_count, output_configuration_specific.feature_map_count, output_configuration_specific_striped.feature_map_count, entry_count, backward_packed_config_count, backward_output_feature_map_group_size);

#define launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, window_width_const, block_size_const, single_output_feature_map_group_count_const, allotted_slice) \
	convolution_backprop_tex_exact_blocked_upd_kernel_kepler_instrumented<dimension_count_const,window_width_const,block_size_const,single_output_feature_map_group_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*input_errors_buffer, output_tex, weights_tex, packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, input_configuration_specific_striped.feature_map_count, output_configuration_specific.feature_map_count, output_configuration_specific_striped.feature_map_count, entry_count, backward_packed_config_count, backward_output_feature_map_group_size, allotted_slice, d_yield_point_ret, d_elapsed_ret);

#define launch_backprop_generic_kernel_const_const_const(dimension_count_const, block_size_const, single_output_feature_map_group_count_const) \
	convolution_backprop_tex_generic_blocked_upd_kernel_kepler<dimension_count_const,block_size_const,single_output_feature_map_group_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*input_errors_buffer, output_tex, weights_tex, packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, input_configuration_specific_striped.feature_map_count, output_configuration_specific.feature_map_count, output_configuration_specific_striped.feature_map_count, entry_count, backward_packed_config_count, backward_output_feature_map_group_size);

#define launch_backprop_generic_kernel_const_const_const_instrumented(dimension_count_const, block_size_const, single_output_feature_map_group_count_const, allotted_slice) \
	convolution_backprop_tex_generic_blocked_upd_kernel_kepler_instrumented<dimension_count_const,block_size_const,single_output_feature_map_group_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*input_errors_buffer, output_tex, weights_tex, packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, input_configuration_specific_striped.feature_map_count, output_configuration_specific.feature_map_count, output_configuration_specific_striped.feature_map_count, entry_count, backward_packed_config_count, backward_output_feature_map_group_size, allotted_slice, d_yield_point_ret, d_elapsed_ret);

#define launch_backprop_kernel_const_const_cost(dimension_count_const, window_width, block_size_const, single_output_feature_map_group_count_const) \
	switch (window_width) \
		{ \
		case 1: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 1, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 2: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 2, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 3: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 3, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 4: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 4, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 5: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 5, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 6: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 6, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 7: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 7, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 8: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 8, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 9: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 9, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		case 10: \
			launch_backprop_exact_kernel_const_const_const_const(dimension_count_const, 10, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		default: \
			launch_backprop_generic_kernel_const_const_const(dimension_count_const, block_size_const, single_output_feature_map_group_count_const); \
			break; \
		};

#define launch_backprop_kernel_const_const_cost_instrumented(dimension_count_const, window_width, block_size_const, single_output_feature_map_group_count_const, allotted_slice) \
	switch (window_width) \
		{ \
		case 1: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 1, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 2: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 2, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 3: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 3, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 4: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 4, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 5: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 5, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 6: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 6, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 7: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 7, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 8: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 8, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 9: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 9, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 10: \
			launch_backprop_exact_kernel_const_const_const_const_instrumented(dimension_count_const, 10, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		default: \
			launch_backprop_generic_kernel_const_const_const_instrumented(dimension_count_const, block_size_const, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		};

#define launch_backprop_kernel_const_const(dimension_count_const, window_width, block_size, single_output_feature_map_group_count_const) \
	switch (block_size) \
		{ \
		case 1: \
			launch_backprop_kernel_const_const_cost(dimension_count_const, window_width, 1, single_output_feature_map_group_count_const); \
			break; \
		case 2: \
			launch_backprop_kernel_const_const_cost(dimension_count_const, window_width, 2, single_output_feature_map_group_count_const); \
			break; \
		case 3: \
			launch_backprop_kernel_const_const_cost(dimension_count_const, window_width, 3, single_output_feature_map_group_count_const); \
			break; \
		case 4: \
			launch_backprop_kernel_const_const_cost(dimension_count_const, window_width, 4, single_output_feature_map_group_count_const); \
			break; \
		case 5: \
			launch_backprop_kernel_const_const_cost(dimension_count_const, window_width, 5, single_output_feature_map_group_count_const); \
			break; \
		};

#define launch_backprop_kernel_const_const_instrumented(dimension_count_const, window_width, block_size, single_output_feature_map_group_count_const, allotted_slice) \
	switch (block_size) \
		{ \
		case 1: \
			launch_backprop_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 1, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 2: \
			launch_backprop_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 2, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 3: \
			launch_backprop_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 3, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 4: \
			launch_backprop_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 4, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		case 5: \
			launch_backprop_kernel_const_const_cost_instrumented(dimension_count_const, window_width, 5, single_output_feature_map_group_count_const, allotted_slice); \
			break; \
		};

#define launch_backprop_kernel(dimension_count_const, window_width, block_size, single_output_feature_map_group_count) \
	switch (single_output_feature_map_group_count) \
		{ \
		case false: \
			launch_backprop_kernel_const_const(dimension_count_const, window_width, block_size, false); \
			break; \
		case true: \
			launch_backprop_kernel_const_const(dimension_count_const, window_width, block_size, true); \
			break; \
		};

#define launch_backprop_kernel_instrumented(dimension_count_const, window_width, block_size, single_output_feature_map_group_count, allotted_slice) \
	switch (single_output_feature_map_group_count) \
		{ \
		case false: \
			launch_backprop_kernel_const_const_instrumented(dimension_count_const, window_width, block_size, false, allotted_slice); \
			break; \
		case true: \
			launch_backprop_kernel_const_const_instrumented(dimension_count_const, window_width, block_size, true, allotted_slice); \
			break; \
		};


#define launch_update_exact_kernel_const_const(dimension_count_const, window_width_const) \
	convolution_update_weights_exact_upd_kernel_kepler<dimension_count_const,window_width_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*gradient[0], input_tex, output_tex, packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, output_configuration_specific.feature_map_count, input_configuration_specific_striped.feature_map_count, output_configuration_specific_striped.feature_map_count, input_elem_count_per_entry_striped, output_elem_count_per_entry_striped, entry_count, updater_packed_config_count, updater_last_dimension_group_count);

#define launch_update_exact_kernel_const_const_instrumented(dimension_count_const, window_width_const, allotted_slice) \
	convolution_update_weights_exact_upd_kernel_kepler_instrumented<dimension_count_const,window_width_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*gradient[0], input_tex, output_tex, packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, output_configuration_specific.feature_map_count, input_configuration_specific_striped.feature_map_count, output_configuration_specific_striped.feature_map_count, input_elem_count_per_entry_striped, output_elem_count_per_entry_striped, entry_count, updater_packed_config_count, updater_last_dimension_group_count, allotted_slice, d_yield_point_ret, d_elapsed_ret);

#define launch_update_generic_kernel_const(dimension_count_const) \
	convolution_update_weights_generic_upd_kernel_kepler<dimension_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*gradient[0], input_tex, output_tex, packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, output_configuration_specific.feature_map_count, input_configuration_specific_striped.feature_map_count, output_configuration_specific_striped.feature_map_count, input_elem_count_per_entry_striped, output_elem_count_per_entry_striped, entry_count, updater_packed_config_count, updater_last_dimension_group_count);

#define launch_update_generic_kernel_const_instrumented(dimension_count_const, allotted_slice) \
	convolution_update_weights_generic_upd_kernel_kepler_instrumented<dimension_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*gradient[0], input_tex, output_tex, packed_config_list, output_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, output_configuration_specific.feature_map_count, input_configuration_specific_striped.feature_map_count, output_configuration_specific_striped.feature_map_count, input_elem_count_per_entry_striped, output_elem_count_per_entry_striped, entry_count, updater_packed_config_count, updater_last_dimension_group_count, allotted_slice, d_yield_point_ret, d_elapsed_ret);

#define launch_update_kernel(dimension_count_const, window_width) \
	switch (window_width) \
		{ \
		case 1: \
			launch_update_exact_kernel_const_const(dimension_count_const, 1); \
			break; \
		case 2: \
			launch_update_exact_kernel_const_const(dimension_count_const, 2); \
			break; \
		case 3: \
			launch_update_exact_kernel_const_const(dimension_count_const, 3); \
			break; \
		case 4: \
			launch_update_exact_kernel_const_const(dimension_count_const, 4); \
			break; \
		case 5: \
			launch_update_exact_kernel_const_const(dimension_count_const, 5); \
			break; \
		case 6: \
			launch_update_exact_kernel_const_const(dimension_count_const, 6); \
			break; \
		case 7: \
			launch_update_exact_kernel_const_const(dimension_count_const, 7); \
			break; \
		case 8: \
			launch_update_exact_kernel_const_const(dimension_count_const, 8); \
			break; \
		case 9: \
			launch_update_exact_kernel_const_const(dimension_count_const, 9); \
			break; \
		case 10: \
			launch_update_exact_kernel_const_const(dimension_count_const, 10); \
			break; \
		default: \
			launch_update_generic_kernel_const(dimension_count_const); \
			break; \
		};

#define launch_update_kernel_instrumented(dimension_count_const, window_width, allotted_slice) \
	switch (window_width) \
		{ \
		case 1: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 1, allotted_slice); \
			break; \
		case 2: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 2, allotted_slice); \
			break; \
		case 3: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 3, allotted_slice); \
			break; \
		case 4: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 4, allotted_slice); \
			break; \
		case 5: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 5, allotted_slice); \
			break; \
		case 6: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 6, allotted_slice); \
			break; \
		case 7: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 7, allotted_slice); \
			break; \
		case 8: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 8, allotted_slice); \
			break; \
		case 9: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 9, allotted_slice); \
			break; \
		case 10: \
			launch_update_exact_kernel_const_const_instrumented(dimension_count_const, 10, allotted_slice); \
			break; \
		default: \
			launch_update_generic_kernel_const_instrumented(dimension_count_const, allotted_slice); \
			break; \
		};

		template<int dimension_count>
		class convolution_layer_updater_cuda_kepler : public layer_updater_cuda
		{
		public:
			convolution_layer_updater_cuda_kepler()
			{
			}

			virtual ~convolution_layer_updater_cuda_kepler()
			{
			}

			virtual void enqueue_test(
				unsigned int offset_input_entry_id,
				cudaStream_t stream_id,
				const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& data,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& data_custom,
				const_cuda_linear_buffer_device_smart_ptr input_neurons_buffer,
				cuda_linear_buffer_device_smart_ptr output_neurons_buffer,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
				std::vector<cuda_memobject_smart_ptr>& dynamic_memobjects,
				unsigned int entry_count,
				bool force_deterministic)
			{
				if (dynamic_memobjects[0] == 0)
					dynamic_memobjects[0] = cuda_texture_smart_ptr(new cuda_texture(additional_buffers[0], 2));
				cuda_texture& input_tex = *(dynamic_cast<cuda_texture *>(dynamic_memobjects[0].get()));

				if (dynamic_memobjects[1] == 0)
					dynamic_memobjects[1] = cuda_texture_smart_ptr(new cuda_texture(data[0], 2));
				cuda_texture& weights_tex = *(dynamic_cast<cuda_texture *>(dynamic_memobjects[1].get()));

				int original_input_elem_offset = offset_input_entry_id * input_elem_count_per_entry;
				cuda_util::copy_to_striped(
					*cuda_config,
					(const float *)(*input_neurons_buffer) + original_input_elem_offset,
					*additional_buffers[0],
					input_elem_count_per_feature_map,
					input_configuration_specific.feature_map_count,
					entry_count,
					stream_id);

				if (forward_input_feature_map_group_count > 1)
					cuda_util::set_with_value(
						*cuda_config,
						*output_neurons_buffer,
						0.0F,
						output_elem_count_per_entry * entry_count,
						stream_id);

				const packed_config<forward_dimension_count> * packed_config_list = static_cast<const packed_config<forward_dimension_count> *>((const void *)*additional_buffers[2]);

				std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
					*cuda_config,
					forward_packed_config_count,
					entry_count,
					1);

				bool single_input_feature_map_group_count = (forward_input_feature_map_group_count == 1);

                                unsigned long grid[3], block[3];
                                grid[0]=kernel_dims.first.x; grid[1]=kernel_dims.first.y; grid[2]=kernel_dims.first.z;
                                block[0]=kernel_dims.second.x; block[1]=kernel_dims.second.y; block[2]=kernel_dims.second.z;
                                KernelIdentifier kid("convolution_tex_exact_blocked_upd_kernel_kepler", grid, block);
                                if(allocate == 0)
                                {
                                cudaMalloc(&d_yield_point_ret, sizeof(int));
                                cudaMalloc(&d_elapsed_ret, sizeof(int));
                                allocate = 1;
                                }

                                unsigned long have_run_for=0;

                                h_yield_point = 0;
                                h_elapsed = -2;
                                int t=-2;
				cudaMemcpy(d_yield_point_ret, &t, sizeof(int), cudaMemcpyHostToDevice);
				cudaMemcpy(d_elapsed_ret, &h_elapsed, sizeof(int), cudaMemcpyHostToDevice);
                                update_kernel_ctr++;
                                bool yield_global = false, yield_global_select = false, yield_local = true, yield_local_select = false;
                                if(/*update_kernel_ctr%8==6*/true)
                                {
                                     yield_global_select = true;
                                     yield_local_select = true;
                                }
                                long service_id=-1, service_id_dummy=-1;
                                int progress_checker = 0;
				//std::cout << "ue before loop " << h_yield_point << " " << grid[0]*grid[1]-1 << std::endl;
				while(h_yield_point < grid[0]*grid[1]-1)
				{
					//std::cout << "ue inside loop " << grid[0]*grid[1]-1 << std::endl;
                                        progress_checker++;
                                        assert(progress_checker<1000);
					if(yield_global)
					{
						if(h_yield_point == 0)
						{
							service_id = EvqueueLaunch(kid, have_run_for, service_id_dummy);
							std::cout << "New UE " << h_yield_point << " " << service_id << std::endl;
							assert(service_id != -1);
						}
						else
						{
							service_id_dummy = EvqueueLaunch(kid, have_run_for, service_id);
							std::cout << "In service UE " << h_yield_point << " " << service_id << std::endl;
							assert(service_id_dummy == -1);
						}
						assert(service_id != -1);
					}
					if(yield_local && yield_local_select)
					{
						//std::cout << "ue local " << grid[0]*grid[1]-1 << std::endl;
						struct timeval start, end;
                                                assert(yield_global == false);
						//std::cout << "UE instrumented " << grid[0]*grid[1]-1 << std::endl;
						unsigned long allotted_slice=128000000; /*10000000000;*/ //10s, surely can't exceed this
                                                int t_yield_point = -2, t_elapsed = -2;
						cudaMemcpy(d_yield_point_ret, &h_yield_point, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(d_elapsed_ret, &h_elapsed, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(&d_yield_point, &t_yield_point, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(&d_elapsed, &t_elapsed, sizeof(int), cudaMemcpyHostToDevice);
                                                t_yield_point = 0; t_elapsed = 0;
						gettimeofday(&start, NULL);
						launch_kernel_instrumented(dimension_count, window_sizes[0], forward_x_block_size, single_input_feature_map_group_count, allotted_slice);
						cudaMemcpy(&h_yield_point, d_yield_point_ret, sizeof(int), cudaMemcpyDeviceToHost);
						gettimeofday(&end, NULL);
						cudaMemcpy(&h_elapsed, d_elapsed_ret, sizeof(int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&t_yield_point, &d_yield_point, sizeof(int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&t_elapsed, &d_elapsed, sizeof(int), cudaMemcpyDeviceToHost);
						//std::cout << "ue " << " " << h_yield_point << " " << h_elapsed << " " << grid[0]*grid[1] << " " << (end.tv_sec - start.tv_sec)*1000000 + (end.tv_usec - start.tv_usec) << " " << t_yield_point << " " << t_elapsed << std::endl;
						assert(h_elapsed != -2);
						assert(t_elapsed != -2);
						assert(t_yield_point != -2);
						//have_run_for += h_elapsed;
						h_elapsed = -2;

					}
					else if(yield_global && yield_global_select && (service_id != 10000000))
					{
						//std::cout << "ue global " << grid[0]*grid[1]-1 << std::endl;
                                                assert(yield_local == false);
						unsigned long allotted_slice=10000000; /*10000000000;*/ //10s, surely can't exceed this
						launch_kernel_instrumented(dimension_count, window_sizes[0], forward_x_block_size, single_input_feature_map_group_count, allotted_slice);
						cudaMemcpy(&h_yield_point, d_yield_point_ret, sizeof(unsigned int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&h_elapsed, d_elapsed_ret, sizeof(int), cudaMemcpyDeviceToHost);
						have_run_for += h_elapsed;
						//std::cout << "UE " << h_yield_point << "/" << grid[0]*grid[1]-1 << " " << h_elapsed << std::endl;
					}
					else
					{
						//std::cout << "ue default " << grid[0]*grid[1]-1 << std::endl;
						launch_kernel(dimension_count, window_sizes[0], forward_x_block_size, single_input_feature_map_group_count);
						break;
					}
                                }
				//std::cout << "ue after loop " << grid[0]*grid[1]-1 << std::endl;
                                h_yield_point = 0;
			}

			virtual void enqueue_backprop(
				cudaStream_t stream_id,
				const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& data,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& data_custom,
				const_cuda_linear_buffer_device_smart_ptr output_neurons_buffer,
				const_cuda_linear_buffer_device_smart_ptr input_neurons_buffer,
				cuda_linear_buffer_device_smart_ptr output_errors_buffer,
				cuda_linear_buffer_device_smart_ptr input_errors_buffer,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
				std::vector<cuda_memobject_smart_ptr>& dynamic_memobjects,
				unsigned int entry_count,
				bool force_deterministic)
			{
				if (!backprop_required)
					throw neural_network_exception("convolution_layer_updater_cuda_kepler is not configured to do backprop but requested to");

				if (dynamic_memobjects[2] == 0)
					dynamic_memobjects[2] = cuda_texture_smart_ptr(new cuda_texture(additional_buffers[1], 2));
				cuda_texture& output_tex = *(dynamic_cast<cuda_texture *>(dynamic_memobjects[2].get()));

				if (dynamic_memobjects[1] == 0)
					dynamic_memobjects[1] = cuda_texture_smart_ptr(new cuda_texture(data[0], 2));
				cuda_texture& weights_tex = *(dynamic_cast<cuda_texture *>(dynamic_memobjects[1].get()));

				if (backward_output_feature_map_group_count > 1)
					cuda_util::set_with_value(
						*cuda_config,
						*input_errors_buffer,
						0.0F,
						input_elem_count_per_entry * entry_count,
						stream_id);

				const packed_config<backward_dimension_count> * packed_config_list = static_cast<const packed_config<backward_dimension_count> *>((const void *)*additional_buffers[4]);

				std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
					*cuda_config,
					backward_packed_config_count,
					entry_count,
					1);

				bool single_output_feature_map_group_count = (backward_output_feature_map_group_count == 1);

                                unsigned long grid[3], block[3];
                                grid[0]=kernel_dims.first.x; grid[1]=kernel_dims.first.y; grid[2]=kernel_dims.first.z;
                                block[0]=kernel_dims.second.x; block[1]=kernel_dims.second.y; block[2]=kernel_dims.second.z;
                                KernelIdentifier kid("convolution_backprop_tex_exact_blocked_upd_kernel_kepler", grid, block);
                                if(allocate == 0)
                                {
                                cudaMalloc(&d_yield_point_ret, sizeof(int));
                                cudaMalloc(&d_elapsed_ret, sizeof(int));
                                allocate = 1;
                                }

                                unsigned long have_run_for=0;

                                h_yield_point = 0;
                                h_elapsed = -2;
                                int t=-2;
				cudaMemcpy(d_yield_point_ret, &t, sizeof(int), cudaMemcpyHostToDevice);
				cudaMemcpy(d_elapsed_ret, &h_elapsed, sizeof(int), cudaMemcpyHostToDevice);
                                backprop_kernel_ctr++;
                                bool yield_global = false, yield_global_select = false, yield_local = true, yield_local_select = false;
				//std::cout << "BPE " << backprop_kernel_ctr << " " << grid[0]*grid[1]-1 << std::endl;
                                if(true/*(backprop_kernel_ctr%7==3)*//*||(backprop_kernel_ctr%7==4)||(backprop_kernel_ctr%7==6)*/)
                                {
                                      yield_global_select = true;
                                      yield_local_select = true;
                                }
				long service_id = -1, service_id_dummy = -1;
                                int progress_checker = 0;
				//std::cout << "bpe before loop " << h_yield_point << " " << grid[0]*grid[1]-1 << std::endl;
                                while(h_yield_point < grid[0]*grid[1]-1)
				{
					//std::cout << "bpe inside loop " << grid[0]*grid[1]-1 << std::endl;
                                        progress_checker++;
                                        assert(progress_checker<1000);
					if(yield_global)
					{
						if(h_yield_point == 0)
						{
							service_id = EvqueueLaunch(kid, have_run_for, service_id_dummy);
							std::cout << "New BPE " << h_yield_point << " " << service_id << std::endl;
							assert(service_id != -1);
						}
						else
						{
							service_id_dummy = EvqueueLaunch(kid, have_run_for, service_id);
							std::cout << "In service BPE " << h_yield_point << " " << service_id << std::endl;
							assert(service_id_dummy == -1);
						}
						assert(service_id != -1);
					}
                                        if(yield_local && yield_local_select)
                                        {
						//std::cout << "bpe local " << grid[0]*grid[1]-1 << std::endl;
						struct timeval start, end;
                                                assert(yield_global == false);
						unsigned long allotted_slice=128000000; /*10000000000;*/ //10s, surely can't exceed this
                                                int t_yield_point = -2, t_elapsed = -2;
						cudaMemcpy(d_yield_point_ret, &h_yield_point, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(d_elapsed_ret, &h_elapsed, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(&d_yield_point, &t_yield_point, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(&d_elapsed, &t_elapsed, sizeof(int), cudaMemcpyHostToDevice);
                                                t_yield_point = 0; t_elapsed = 0;
						gettimeofday(&start, NULL);
						launch_backprop_kernel_instrumented(dimension_count, window_sizes[0], backward_x_block_size, single_output_feature_map_group_count, allotted_slice);
						cudaMemcpy(&h_yield_point, d_yield_point_ret, sizeof(int), cudaMemcpyDeviceToHost);
						gettimeofday(&end, NULL);
						cudaMemcpy(&h_elapsed, d_elapsed_ret, sizeof(int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&t_yield_point, &d_yield_point, sizeof(int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&t_elapsed, &d_elapsed, sizeof(int), cudaMemcpyDeviceToHost);
						//std::cout << "bpe " << " " << h_yield_point << " " << h_elapsed << " " << grid[0]*grid[1] << " " << (end.tv_sec - start.tv_sec)*1000000 + (end.tv_usec - start.tv_usec) << " " << t_yield_point << " " << t_elapsed << std::endl;
						assert(h_elapsed != -2);
						assert(t_elapsed != -2);
						assert(t_yield_point != -2);
						//have_run_for += h_elapsed;
						h_elapsed = -2;
                                        }
					else if(yield_global && yield_global_select && (service_id != 10000000))
					{
						//std::cout << "bpe global " << grid[0]*grid[1]-1 << std::endl;
                                                assert(yield_local == false);
						unsigned long allotted_slice=10000000; /*10000000000;*/ //10s, surely can't exceed this
						launch_backprop_kernel_instrumented(dimension_count, window_sizes[0], backward_x_block_size, single_output_feature_map_group_count, allotted_slice);
						cudaMemcpy(&h_yield_point, d_yield_point_ret, sizeof(unsigned int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&h_elapsed, d_elapsed_ret, sizeof(int), cudaMemcpyDeviceToHost);
						have_run_for += h_elapsed;
						//std::cout << "BPE " << h_yield_point << "/" << grid[0]*grid[1]-1 << " " << h_elapsed << std::endl;
					}
					else
					{
						//std::cout << "bpe default " << grid[0]*grid[1]-1 << std::endl;
						launch_backprop_kernel(dimension_count, window_sizes[0], backward_x_block_size, single_output_feature_map_group_count);
						break;
					}
				}
				//std::cout << "bpe after loop " << grid[0]*grid[1]-1 << std::endl;
                                h_yield_point = 0;
			}

			virtual void enqueue_update_weights(
				unsigned int offset_input_entry_id,
				cudaStream_t stream_id,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& gradient,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& data_custom,
				const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
				cuda_linear_buffer_device_smart_ptr output_errors_buffer,
				const_cuda_linear_buffer_device_smart_ptr input_neurons_buffer,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
				std::vector<cuda_memobject_smart_ptr>& dynamic_memobjects,
				unsigned int entry_count,
				bool force_deterministic)
			{
				// Update biases
				{
					int block_size = get_bias_update_block_size(entry_count);
					int block_count = (entry_count + block_size - 1) / block_size;
					std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
						*cuda_config,
						output_elem_count_per_feature_map,
						1,
						block_count);
					kernel_dims.first.y = output_configuration_specific.feature_map_count;
					int threadblock_size = kernel_dims.second.x * kernel_dims.second.y * kernel_dims.second.z;
					int smem_size = threadblock_size * sizeof(float);
					convolution_update_biases_upd_kernel_kepler<<<kernel_dims.first, kernel_dims.second, smem_size, stream_id>>>(
						*gradient[1],
						*output_errors_buffer,
						block_size,
						output_elem_count_per_feature_map,
						output_configuration_specific.feature_map_count,
						entry_count);
				}

				if (dynamic_memobjects[2] == 0)
					dynamic_memobjects[2] = cuda_texture_smart_ptr(new cuda_texture(additional_buffers[1], 2));
				cuda_texture& output_tex = *(dynamic_cast<cuda_texture *>(dynamic_memobjects[2].get()));

				if (dynamic_memobjects[0] == 0)
					dynamic_memobjects[0] = cuda_texture_smart_ptr(new cuda_texture(additional_buffers[0], 2));
				cuda_texture& input_tex = *(dynamic_cast<cuda_texture *>(dynamic_memobjects[0].get()));

				cuda_util::copy_to_striped(
					*cuda_config,
					*output_errors_buffer,
					*additional_buffers[1],
					output_elem_count_per_feature_map,
					output_configuration_specific.feature_map_count,
					entry_count,
					stream_id);

				const packed_config<updater_dimension_count> * packed_config_list = static_cast<const packed_config<updater_dimension_count> *>((const void *)*additional_buffers[3]);

				std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
					*cuda_config,
					updater_packed_config_count,
					entry_count,
					1);
                                unsigned long grid[3], block[3];
                                grid[0]=kernel_dims.first.x; grid[1]=kernel_dims.first.y; grid[2]=kernel_dims.first.z;
                                //std::cout << grid[0] << " " << grid[1] << " " << std::endl;
                                block[0]=kernel_dims.second.x; block[1]=kernel_dims.second.y; block[2]=kernel_dims.second.z;
                                KernelIdentifier kid("convolution_update_weights_exact_upd_kernel_kepler", grid, block);
                                struct timeval start, end;
                                //gettimeofday(&start, NULL);
                                //cudaDeviceSynchronize();
                                //gettimeofday(&end, NULL);
                                //std::cout << (end.tv_sec - start.tv_sec)*1000000 + (end.tv_usec - start.tv_usec) << std::endl;
                                
                                if(allocate == 0)
                                {
                                cudaMalloc(&d_yield_point_ret, sizeof(int));
                                cudaMalloc(&d_elapsed_ret, sizeof(int));
                                allocate = 1;
                                }

                                unsigned long have_run_for=0;

                                h_yield_point = 0;
                                h_elapsed = -2;
                                int t=-2;
				cudaMemcpy(d_yield_point_ret, &t, sizeof(int), cudaMemcpyHostToDevice);
				cudaMemcpy(d_elapsed_ret, &h_elapsed, sizeof(int), cudaMemcpyHostToDevice);
                                update_weights_kernel_ctr++;
                                bool yield_global = false, yield_global_select = false, yield_local = true, yield_local_select = false;
                                if(/*(update_weights_kernel_ctr%8==7)||(update_weights_kernel_ctr%8==5)||(update_weights_kernel_ctr%8==3)*//*||(update_weights_kernel_ctr%8==0)*/true)
                                {
                                     yield_global_select = true;
                                     yield_local_select = true;
                                }
                                long service_id=-1, service_id_dummy=-1;
                                int progress_checker = 0;
				//std::cout << "uwe before loop " << h_yield_point << " " << grid[0]*grid[1]-1 << std::endl;
				while(h_yield_point < grid[0]*grid[1]-1)
				{
					//std::cout << "uwe inside loop " << grid[0]*grid[1]-1 << std::endl;
                                        progress_checker++;
                                        assert(progress_checker<1000);
					if(yield_global)
					{
						if(h_yield_point == 0)
						{
							service_id = EvqueueLaunch(kid, have_run_for, service_id_dummy);
							std::cout << "New UWE " << h_yield_point << " " << service_id << std::endl;
							assert(service_id != -1);
						}
						else
						{
							service_id_dummy = EvqueueLaunch(kid, have_run_for, service_id);
							std::cout << "In service UWE " << h_yield_point << " " << service_id << std::endl;
							assert(service_id_dummy == -1);
						}
						assert(service_id != -1);
					}
                                        if(yield_local && yield_local_select)
                                        {
						//std::cout << "uwe local " << grid[0]*grid[1]-1 << std::endl;
						struct timeval start, end;
                                                assert(yield_global == false);
						unsigned long allotted_slice=128000000; /*10000000000;*/ //10s, surely can't exceed this
                                                int t_yield_point = -2, t_elapsed = -2;
						cudaMemcpy(d_yield_point_ret, &h_yield_point, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(d_elapsed_ret, &h_elapsed, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(&d_yield_point, &t_yield_point, sizeof(int), cudaMemcpyHostToDevice);
						cudaMemcpy(&d_elapsed, &t_elapsed, sizeof(int), cudaMemcpyHostToDevice);
                                                t_yield_point = 0; t_elapsed = 0;
						gettimeofday(&start, NULL);
						launch_update_kernel_instrumented(dimension_count, window_sizes[0], allotted_slice);
						cudaMemcpy(&h_yield_point, d_yield_point_ret, sizeof(int), cudaMemcpyDeviceToHost);
						gettimeofday(&end, NULL);
						cudaMemcpy(&h_elapsed, d_elapsed_ret, sizeof(int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&t_yield_point, &d_yield_point, sizeof(int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&t_elapsed, &d_elapsed, sizeof(int), cudaMemcpyDeviceToHost);
						//std::cout << "uwe " << " " << h_yield_point << " " << h_elapsed << " " << grid[0]*grid[1] << " " << (end.tv_sec - start.tv_sec)*1000000 + (end.tv_usec - start.tv_usec) << " " << t_yield_point << " " << t_elapsed << std::endl;
						assert(h_elapsed != -2);
						assert(t_elapsed != -2);
						assert(t_yield_point != -2);
						//have_run_for += h_elapsed;
						h_elapsed = -2;
					}
					else if(yield_global && yield_global_select && (service_id != 10000000))
					{
						//std::cout << "uwe global " << grid[0]*grid[1]-1 << std::endl;
                                                assert(yield_local == false);
						unsigned long allotted_slice=10000000; /*10000000000;*/ //10s, surely can't exceed this
						launch_update_kernel_instrumented(dimension_count, window_sizes[0], allotted_slice);
						cudaMemcpy(&h_yield_point, d_yield_point_ret, sizeof(unsigned int), cudaMemcpyDeviceToHost);
						cudaMemcpy(&h_elapsed, d_elapsed_ret, sizeof(int), cudaMemcpyDeviceToHost);
						have_run_for += h_elapsed;
					}
					else
					{
						//std::cout << "uwe default " << grid[0]*grid[1]-1 << std::endl;
						launch_update_kernel(dimension_count, window_sizes[0]);
						break;
					}
                                }
				//std::cout << "uwe after loop " << grid[0]*grid[1]-1 << std::endl;
                                h_yield_point = 0;
			}

		protected:
			static const int forward_dimension_count = (dimension_count + 2);
			static const int backward_dimension_count = (dimension_count + 2);
			static const int updater_dimension_count = (dimension_count * 2 + 2);

			virtual bool is_in_place_backprop() const
			{
				return false;
			}

			virtual void updater_configured()
			{
				nnforge_shared_ptr<const convolution_layer> layer_derived = nnforge_dynamic_pointer_cast<const convolution_layer>(layer_schema);

				for(int i = 0; i < dimension_count; ++i)
				{
					window_sizes[i] = layer_derived->window_sizes[i];
					input_sizes[i] = input_configuration_specific.dimension_sizes[i];
					output_sizes[i] = output_configuration_specific.dimension_sizes[i];
					left_zero_padding[i] = layer_derived->left_zero_padding[i];
				}

				{
					input_configuration_specific_striped = cuda_util::get_layer_configuration_specific_striped(input_configuration_specific);
					input_elem_count_per_entry_striped = input_configuration_specific_striped.get_neuron_count();

					forward_x_block_size = get_block_size(output_configuration_specific.dimension_sizes[0]);
					forward_x_block_count = (output_configuration_specific.dimension_sizes[0] + forward_x_block_size - 1) / forward_x_block_size;
					forward_output_feature_map_block_count = (output_configuration_specific.feature_map_count + FEATURE_MAP_BLOCK_SIZE - 1) / FEATURE_MAP_BLOCK_SIZE;

					forward_packed_config_count = forward_x_block_count * input_configuration_specific_striped.feature_map_count * forward_output_feature_map_block_count;
					for(int i = 1; i < dimension_count; ++i)
						forward_packed_config_count *= output_sizes[i];
				}

				{
					output_configuration_specific_striped = cuda_util::get_layer_configuration_specific_striped(output_configuration_specific);
					output_elem_count_per_entry_striped = output_configuration_specific_striped.get_neuron_count();

					backward_x_block_size = get_block_size(input_configuration_specific.dimension_sizes[0]);
					backward_x_block_count = (input_configuration_specific.dimension_sizes[0] + backward_x_block_size - 1) / backward_x_block_size;
					backward_input_feature_map_block_count = (input_configuration_specific_striped.feature_map_count + (FEATURE_MAP_BLOCK_SIZE/2) - 1) / (FEATURE_MAP_BLOCK_SIZE/2);

					backward_packed_config_count = backward_x_block_count * backward_input_feature_map_block_count * output_configuration_specific_striped.feature_map_count;
					for(int i = 1; i < dimension_count; ++i)
						backward_packed_config_count *= input_sizes[i];
				}

				{
					updater_window_x_block_count = (window_sizes[0] <= MAX_WINDOW_WIDTH) ? 1 : (window_sizes[0] + WINDOW_WIDTH_LOCAL - 1) / WINDOW_WIDTH_LOCAL;
					updater_packed_config_count = output_configuration_specific_striped.feature_map_count * input_configuration_specific_striped.feature_map_count * updater_window_x_block_count;
					for(int i = 1; i < dimension_count; ++i)
					{
						updater_packed_config_count *= window_sizes[i];
						updater_packed_config_count *= output_sizes[i];
					}
					updater_last_dimension_group_count = (dimension_count > 1) ? output_sizes[dimension_count - 1] : 1;
				}

				weight_elem_count = output_configuration_specific.feature_map_count * input_configuration_specific_striped.feature_map_count * 2;
				for(int i = 0; i < dimension_count; ++i)
					weight_elem_count *= window_sizes[i];
			}

			virtual std::vector<size_t> get_sizes_of_additional_buffers_per_entry() const
			{
				std::vector<size_t> res;

				res.push_back(input_elem_count_per_entry_striped * sizeof(float2));
				res.push_back(output_elem_count_per_entry_striped * sizeof(float2));

				return res;
			}

			virtual std::vector<size_t> get_sizes_of_additional_buffers_fixed() const
			{
				std::vector<size_t> res;

				res.push_back(sizeof(packed_config<forward_dimension_count>) * forward_packed_config_count);

				res.push_back(sizeof(packed_config<updater_dimension_count>) * updater_packed_config_count);

				if (backprop_required)
					res.push_back(sizeof(packed_config<backward_dimension_count>) * backward_packed_config_count);

				return res;
			}

			virtual void set_max_entry_count(unsigned int max_entry_count)
			{
				{
					forward_packed_config_count = forward_x_block_count * forward_output_feature_map_block_count;
					for(int i = 1; i < dimension_count; ++i)
						forward_packed_config_count *= output_sizes[i];
					forward_input_feature_map_group_count = cuda_util::get_group_count(
						*cuda_config,
						forward_packed_config_count * max_entry_count,
						input_configuration_specific_striped.feature_map_count);
					forward_input_feature_map_group_size = (input_configuration_specific_striped.feature_map_count + forward_input_feature_map_group_count - 1) / forward_input_feature_map_group_count;
					forward_packed_config_count *= forward_input_feature_map_group_count;
				}

				{
					updater_packed_config_count = output_configuration_specific_striped.feature_map_count * input_configuration_specific_striped.feature_map_count * updater_window_x_block_count;
					for(int i = 1; i < dimension_count; ++i)
					{
						updater_packed_config_count *= window_sizes[i];
						updater_packed_config_count *= (i == dimension_count - 1) ? 1 : output_sizes[i];
					}
					if (dimension_count > 1)
					{
						updater_last_dimension_group_count = cuda_util::get_group_count(
							*cuda_config,
							updater_packed_config_count * max_entry_count,
							output_sizes[dimension_count - 1]);
						updater_packed_config_count *= updater_last_dimension_group_count;
					}
					else
						updater_last_dimension_group_count = 1;

					updater_single_elem_per_destination = (updater_window_x_block_count == 1) && (updater_last_dimension_group_count == 1);
					for(int i = 1; i < dimension_count - 1; ++i)
						updater_single_elem_per_destination = updater_single_elem_per_destination && (output_sizes[i] == 1);
				}

				if (backprop_required)
				{
					backward_packed_config_count = backward_x_block_count * backward_input_feature_map_block_count;
					for(int i = 1; i < dimension_count; ++i)
						backward_packed_config_count *= input_sizes[i];
					backward_output_feature_map_group_count = cuda_util::get_group_count(
						*cuda_config,
						backward_packed_config_count * max_entry_count,
						output_configuration_specific_striped.feature_map_count);
					backward_output_feature_map_group_size = (output_configuration_specific_striped.feature_map_count + backward_output_feature_map_group_count - 1) / backward_output_feature_map_group_count;
					backward_packed_config_count *= backward_output_feature_map_group_count;
				}
			}

			virtual std::vector<unsigned int> get_linear_addressing_through_texture_per_entry() const
			{
				std::vector<unsigned int> res;

				res.push_back(input_elem_count_per_entry_striped);
				res.push_back(output_elem_count_per_entry_striped);

				return res;
			}

			virtual void fill_additional_buffers(const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers) const
			{
				{
					std::vector<packed_config<forward_dimension_count> > task_list;
					{
						nnforge_array<int, dimension_count> size_list;
						for(int i = 0; i < dimension_count; ++i)
							size_list[i] = (i == 0) ? forward_x_block_count : output_sizes[i];
						std::vector<nnforge_array<int, dimension_count> > ordered_list;
						sequential_curve<dimension_count>::fill_pattern(size_list, ordered_list);
						packed_config<forward_dimension_count> new_elem;
						for(int input_feature_map_group_id = 0; input_feature_map_group_id < forward_input_feature_map_group_count; ++input_feature_map_group_id)
						{
							new_elem.set_val(dimension_count + 1, input_feature_map_group_id * forward_input_feature_map_group_size);
							for(int output_feature_map_block_id = 0; output_feature_map_block_id < forward_output_feature_map_block_count; ++output_feature_map_block_id)
							{
								new_elem.set_val(dimension_count, output_feature_map_block_id * FEATURE_MAP_BLOCK_SIZE);
								for(int j = 0; j < ordered_list.size(); ++j)
								{
									const nnforge_array<int, dimension_count>& spatial_dimensions = ordered_list[j];
									for(int i = 0; i < dimension_count; ++i)
										new_elem.set_val(i, (i == 0) ? (spatial_dimensions[i] * forward_x_block_size) : spatial_dimensions[i]);
									task_list.push_back(new_elem);
								}
							}
						}
					}
					cuda_safe_call(cudaMemcpy(*additional_buffers[2], &(*task_list.begin()), sizeof(packed_config<forward_dimension_count>) * task_list.size(), cudaMemcpyHostToDevice));
				}

				{
					std::vector<packed_config<updater_dimension_count> > task_list;

					nnforge_array<int, dimension_count * 2> size_list;
					for(int i = 1; i < dimension_count; ++i)
					{
						size_list[i - 1] = window_sizes[i];
						size_list[(dimension_count - 1) + i - 1] = ((dimension_count > 1) && (i == dimension_count - 1)) ? updater_last_dimension_group_count : output_sizes[i];
					}
					size_list[(dimension_count - 1) * 2] = input_configuration_specific_striped.feature_map_count;
					size_list[(dimension_count - 1) * 2 + 1] = output_configuration_specific_striped.feature_map_count;
					std::vector<nnforge_array<int, dimension_count*2> > updater_config_ordered_list;
					space_filling_curve<dimension_count*2>::fill_pattern(size_list, updater_config_ordered_list);

					packed_config<updater_dimension_count> new_elem;
					new_elem.set_val(dimension_count, 0);
					for(int ordered_elem_id = 0; ordered_elem_id < updater_config_ordered_list.size(); ++ordered_elem_id)
					{
						const nnforge_array<int, dimension_count*2>& ordered_elem = updater_config_ordered_list[ordered_elem_id];
						for(int i = 1; i < dimension_count; ++i)
						{
							new_elem.set_val(i, ordered_elem[i - 1]);
							new_elem.set_val(dimension_count + i, ordered_elem[(dimension_count - 1) + i - 1]);
						}
						new_elem.set_val(dimension_count * 2, ordered_elem[(dimension_count - 1) * 2]);
						new_elem.set_val(dimension_count * 2 + 1, ordered_elem[(dimension_count - 1) * 2 + 1]);

						for(int i = 0; i < updater_window_x_block_count; ++i)
						{
							new_elem.set_val(0, i * WINDOW_WIDTH_LOCAL);
							task_list.push_back(new_elem);
						}
					}

					cuda_safe_call(cudaMemcpy(*additional_buffers[3], &(*task_list.begin()), sizeof(packed_config<updater_dimension_count>) * task_list.size(), cudaMemcpyHostToDevice));
				}

				if (backprop_required)
				{
					std::vector<packed_config<backward_dimension_count> > task_list;
					{
						nnforge_array<int, dimension_count> size_list;
						for(int i = 0; i < dimension_count; ++i)
							size_list[i] = (i == 0) ? backward_x_block_count : input_sizes[i];
						std::vector<nnforge_array<int, dimension_count> > ordered_list;
						sequential_curve<dimension_count>::fill_pattern(size_list, ordered_list);
						packed_config<backward_dimension_count> new_elem;
						for(int output_feature_map_group_id = 0; output_feature_map_group_id < backward_output_feature_map_group_count; ++output_feature_map_group_id)
						{
							new_elem.set_val(dimension_count + 1, output_feature_map_group_id * backward_output_feature_map_group_size);
							for(int input_feature_map_block_id = 0; input_feature_map_block_id < backward_input_feature_map_block_count; ++input_feature_map_block_id)
							{
								new_elem.set_val(dimension_count, input_feature_map_block_id * (FEATURE_MAP_BLOCK_SIZE/2));
								for(int j = 0; j < ordered_list.size(); ++j)
								{
									const nnforge_array<int, dimension_count>& spatial_dimensions = ordered_list[j];
									for(int i = 0; i < dimension_count; ++i)
										new_elem.set_val(i, (i == 0) ? (spatial_dimensions[i] * backward_x_block_size + backward_x_block_size - 1) : spatial_dimensions[i]);
									task_list.push_back(new_elem);
								}
							}
						}
					}
					cuda_safe_call(cudaMemcpy(*additional_buffers[4], &(*task_list.begin()), sizeof(packed_config<backward_dimension_count>) * task_list.size(), cudaMemcpyHostToDevice));
				}
			}

			virtual int get_dynamic_memobject_count() const
			{
				return 3;
			}

			virtual unsigned int get_data_elem_count(unsigned int part_id, unsigned int source_elem_count) const
			{
				if (part_id != 0)
					return layer_updater_cuda::get_data_elem_count(part_id, source_elem_count);

				return weight_elem_count;
			}

			virtual void fill_data_for_device(
				unsigned int part_id,
				const float * src,
				float * dst,
				unsigned int count) const
			{
				if (part_id != 0)
					return layer_updater_cuda::fill_data_for_device(part_id, src, dst, count);

				unsigned int window_total_size = 1;
				for(int i = 0; i < dimension_count; ++i)
					window_total_size *= window_sizes[i];

				unsigned int input_feature_map_count_striped = input_configuration_specific_striped.feature_map_count;

				unsigned int src_offset = 0;
				unsigned int dst_offset = 0;
				for(unsigned int output_feature_map_id = 0; output_feature_map_id < output_configuration_specific.feature_map_count; ++output_feature_map_id)
				{
					for(unsigned int input_feature_map_id_striped = 0; input_feature_map_id_striped < input_feature_map_count_striped; ++input_feature_map_id_striped, dst_offset += window_total_size * 2)
					{
						bool second_feature_map_present = (input_feature_map_id_striped * 2 + 1 < input_configuration_specific.feature_map_count);
						for(int dst_elem_id = 0; dst_elem_id < window_total_size; ++dst_elem_id)
						{
							dst[dst_offset + dst_elem_id * 2] = src[src_offset + dst_elem_id];
							float other_val = 0.0F;
							if (second_feature_map_present)
								other_val = src[src_offset + dst_elem_id + window_total_size];
							dst[dst_offset + dst_elem_id * 2 + 1] = other_val;
						}

						src_offset += window_total_size * (second_feature_map_present ? 2 : 1);
					}
				}
			}

			virtual void fill_data_for_host(
				unsigned int part_id,
				const float * src,
				float * dst,
				unsigned int count) const
			{
				if (part_id != 0)
					return layer_updater_cuda::fill_data_for_host(part_id, src, dst, count);

				unsigned int window_total_size = 1;
				for(int i = 0; i < dimension_count; ++i)
					window_total_size *= window_sizes[i];

				unsigned int input_feature_map_count_striped = input_configuration_specific_striped.feature_map_count;

				unsigned int src_offset = 0;
				unsigned int dst_offset = 0;
				for(unsigned int output_feature_map_id = 0; output_feature_map_id < output_configuration_specific.feature_map_count; ++output_feature_map_id)
				{
					for(unsigned int input_feature_map_id_striped = 0; input_feature_map_id_striped < input_feature_map_count_striped; ++input_feature_map_id_striped, src_offset += window_total_size * 2)
					{
						bool second_feature_map_present = (input_feature_map_id_striped * 2 + 1 < input_configuration_specific.feature_map_count);
						for(int src_elem_id = 0; src_elem_id < window_total_size; ++src_elem_id)
						{
							dst[dst_offset + src_elem_id] = src[src_offset + src_elem_id * 2];
							if (second_feature_map_present)
								dst[dst_offset + src_elem_id + window_total_size] = src[src_offset + src_elem_id * 2 + 1];
						}

						dst_offset += window_total_size * (second_feature_map_present ? 2 : 1);
					}
				}
			}

			array_by_val<int, dimension_count> output_sizes;
			array_by_val<int, dimension_count> input_sizes;
			array_by_val<int, dimension_count> window_sizes;
			array_by_val<int, dimension_count> left_zero_padding;

			layer_configuration_specific input_configuration_specific_striped;
			layer_configuration_specific output_configuration_specific_striped;
			unsigned int input_elem_count_per_entry_striped;
			unsigned int output_elem_count_per_entry_striped;

			int forward_x_block_size;
			int forward_x_block_count;
			int forward_input_feature_map_group_count;
			int forward_input_feature_map_group_size;
			int forward_output_feature_map_block_count;
			int forward_packed_config_count;

			int backward_x_block_size;
			int backward_x_block_count;
			int backward_output_feature_map_group_count;
			int backward_output_feature_map_group_size;
			int backward_input_feature_map_block_count;
			int backward_packed_config_count;

			int updater_packed_config_count;
			int updater_window_x_block_count;
			int updater_last_dimension_group_count;
			bool updater_single_elem_per_destination;

			unsigned int weight_elem_count;

		private:
			static int get_block_size(int width)
			{
				int block_count = (width + MAX_BLOCK_SIZE - 1) / MAX_BLOCK_SIZE;
				int block_size = (width + block_count - 1) / block_count;
				return block_size;
			}

			static int get_bias_update_block_size(int entry_count)
			{
				int block_size = std::min(std::max(static_cast<int>(sqrtf(static_cast<float>(entry_count))), 1), entry_count);
				return block_size;
			}

			static int get_threadblock_size_biases(int output_neuron_count)
			{
				int threadblock_size;

				if (output_neuron_count < 128)
				{
					threadblock_size = (output_neuron_count + 32 - 1) / 32 * 32;
				}
				else
				{
					int threadblock_count = (output_neuron_count + 128 - 1) / 128;
					threadblock_size = (output_neuron_count + threadblock_count - 1) / threadblock_count;
					threadblock_size = (threadblock_size + 32 - 1) / 32 * 32;
				}

				return threadblock_size;
			}
		};
	}
}
