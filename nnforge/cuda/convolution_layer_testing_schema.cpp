/*
 *  Copyright 2011-2013 Maxim Milakov
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

#include "convolution_layer_testing_schema.h"

#include "../convolution_layer.h"
#include "../neural_network_exception.h"
#include "fully_connected_layer_tester_cuda.h"
#include "convolution_1x1_layer_tester_cuda.h"
#include "convolution_layer_tester_cuda.h"
#include "convolution_layer_testing_schema_helper_cuda_kepler.h"
#include "convolution_layer_testing_schema_helper_cuda_fermi.h"

#include <boost/format.hpp>

namespace nnforge
{
	namespace cuda
	{
		convolution_layer_testing_schema::convolution_layer_testing_schema()
		{
		}

		convolution_layer_testing_schema::~convolution_layer_testing_schema()
		{
		}

		const boost::uuids::uuid& convolution_layer_testing_schema::get_uuid() const
		{
			return convolution_layer::layer_guid;
		}

		layer_testing_schema_smart_ptr convolution_layer_testing_schema::create_specific() const
		{
			return layer_testing_schema_smart_ptr(new convolution_layer_testing_schema());
		}

		layer_tester_cuda_smart_ptr convolution_layer_testing_schema::create_tester_specific(
			const layer_configuration_specific& input_configuration_specific,
			const layer_configuration_specific& output_configuration_specific) const
		{
			layer_tester_cuda_smart_ptr res;

			nnforge_shared_ptr<const convolution_layer> layer_derived = nnforge_dynamic_pointer_cast<const convolution_layer>(layer_schema);

			bool zero_padding = (layer_derived->left_zero_padding == std::vector<unsigned int>(layer_derived->left_zero_padding.size(), 0))
				&& (layer_derived->right_zero_padding == std::vector<unsigned int>(layer_derived->right_zero_padding.size(), 0));

			if (zero_padding && (output_configuration_specific.get_neuron_count() == output_configuration_specific.feature_map_count))
			{
				res = layer_tester_cuda_smart_ptr(new fully_connected_layer_tester_cuda());
			}
			else if (zero_padding && (input_configuration_specific.dimension_sizes == output_configuration_specific.dimension_sizes))
			{
				res = layer_tester_cuda_smart_ptr(new convolution_1x1_layer_tester_cuda());
			}
			else if (input_configuration_specific.dimension_sizes.size() <= 0) /*2 : cuDNN*/
			{
				res = layer_tester_cuda_smart_ptr(new convolution_layer_tester_cuda());
			}
			else
			{
				res = convolution_layer_testing_schema_helper_cuda_kepler::create_tester_specific(input_configuration_specific, output_configuration_specific);
			}

			return res;
		}
	}
}
