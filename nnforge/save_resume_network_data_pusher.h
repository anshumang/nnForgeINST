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

#include "network_data_pusher.h"

#include <boost/filesystem.hpp>

namespace nnforge
{
	class save_resume_network_data_pusher : public network_data_pusher
	{
	public:
		save_resume_network_data_pusher(const boost::filesystem::path& folder_path);

		virtual ~save_resume_network_data_pusher();

		virtual void push(const training_task_state& task_state);

	private:
		void save_data_to_file(
			network_data_smart_ptr data,
			std::string filename) const;

	private:
		boost::filesystem::path folder_path;
	};
}
