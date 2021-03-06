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

#include "layer_data_list.h"
#include "layer_data.h"
#include "layer.h"
#include "network_output_type.h"

#include <vector>

namespace nnforge
{
	class network_data_initializer
	{
	public:
		network_data_initializer();

	public:
		void initialize(
			layer_data_list& data_list,
			const const_layer_list& layer_list,
			network_output_type::output_type type);
	};
}
