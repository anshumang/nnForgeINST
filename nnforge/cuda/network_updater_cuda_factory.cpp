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

#include "network_updater_cuda_factory.h"

#include "network_updater_cuda.h"

namespace nnforge
{
	namespace cuda
	{
		network_updater_cuda_factory::network_updater_cuda_factory(cuda_running_configuration_const_smart_ptr cuda_config)
			: cuda_config(cuda_config)
		{
		}

		network_updater_cuda_factory::~network_updater_cuda_factory()
		{
		}

		network_updater_smart_ptr network_updater_cuda_factory::create(
			network_schema_smart_ptr schema,
			const_error_function_smart_ptr ef) const
		{
			return network_updater_smart_ptr(new network_updater_cuda(
				schema,
				ef,
				cuda_config));
		}
	}
}
