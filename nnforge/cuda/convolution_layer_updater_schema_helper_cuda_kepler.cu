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

#include "convolution_layer_updater_schema_helper_cuda_kepler.h"

#include "convolution_layer_updater_cuda_kepler.cuh"

#include <boost/format.hpp>
#include "../neural_network_exception.h"

namespace nnforge
{
	namespace cuda
	{
		layer_updater_cuda_smart_ptr convolution_layer_updater_schema_helper_cuda_kepler::create_updater_specific(
				const layer_configuration_specific& input_configuration_specific,
				const layer_configuration_specific& output_configuration_specific)
		{
			layer_updater_cuda_smart_ptr res;

			switch (output_configuration_specific.dimension_sizes.size()) 
			{
				case 2:
					res = layer_updater_cuda_smart_ptr(new convolution_layer_updater_cuda_kepler<2>());
					break;
				case 3:
					res = layer_updater_cuda_smart_ptr(new convolution_layer_updater_cuda_kepler<3>());
					break;
				case 4:
					res = layer_updater_cuda_smart_ptr(new convolution_layer_updater_cuda_kepler<4>());
					break;
				default:
					throw neural_network_exception((boost::format("No CUDA updater for the convolutional layer of %1% dimensions for Kepler and above architectures") % output_configuration_specific.dimension_sizes.size()).str());
			}

			return res;
		}
	}
}
