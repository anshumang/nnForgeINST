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

#include <iostream>
#include <stdio.h>

//#undef NNFORGE_CUDA_BACKEND_ENABLED

#ifdef NNFORGE_CUDA_BACKEND_ENABLED
#include <nnforge/cuda/cuda.h>
#else
#include <nnforge/plain/plain.h>
#endif
#include "imagenet_toolset.h"
#include "EvqueueManager.h"

//extern EvqueueManager *evqm;

#if 0
#include <cupti.h>

#define CUPTI_CALL(call)                                                \
  do {                                                                  \
    CUptiResult _status = call;                                         \
    if (_status != CUPTI_SUCCESS) {                                     \
      const char *errstr;                                               \
      cuptiGetResultString(_status, &errstr);                           \
      fprintf(stderr, "%s:%d: error: function %s failed with error %s.\n", \
              __FILE__, __LINE__, #call, errstr);                       \
      exit(-1);                                                         \
    }                                                                   \
  } while (0)

#define BUF_SIZE (32 * 1024)
//#define BUF_SIZE (1 * 1024)
#define ALIGN_SIZE (8)
#define ALIGN_BUFFER(buffer, align)                                            \
  (((uintptr_t) (buffer) & ((align)-1)) ? ((buffer) + (align) - ((uintptr_t) (buffer) & ((align)-1))) : (buffer))

// Timestamp at trace initialization time. Used to normalized other
// timestamps
static uint64_t startTimestamp;

static const char *
getMemcpyKindString(CUpti_ActivityMemcpyKind kind)
{
  switch (kind) {
  case CUPTI_ACTIVITY_MEMCPY_KIND_HTOD:
    return "HtoD";
  case CUPTI_ACTIVITY_MEMCPY_KIND_DTOH:
    return "DtoH";
  case CUPTI_ACTIVITY_MEMCPY_KIND_HTOA:
    return "HtoA";
  case CUPTI_ACTIVITY_MEMCPY_KIND_ATOH:
    return "AtoH";
  case CUPTI_ACTIVITY_MEMCPY_KIND_ATOA:
    return "AtoA";
  case CUPTI_ACTIVITY_MEMCPY_KIND_ATOD:
    return "AtoD";
  case CUPTI_ACTIVITY_MEMCPY_KIND_DTOA:
    return "DtoA";
  case CUPTI_ACTIVITY_MEMCPY_KIND_DTOD:
    return "DtoD";
  case CUPTI_ACTIVITY_MEMCPY_KIND_HTOH:
    return "HtoH";
  default:
    break;
  }

  return "<unknown>";
}

static void
printActivity(CUpti_Activity *record)
{
  switch (record->kind)
  {
  case CUPTI_ACTIVITY_KIND_MEMCPY:
    {
      CUpti_ActivityMemcpy *memcpy = (CUpti_ActivityMemcpy *) record;
      printf("%s %llu %llu %llu %llu %u\n",
             getMemcpyKindString((CUpti_ActivityMemcpyKind) memcpy->copyKind),
             memcpy->bytes,
             (unsigned long long) (memcpy->start - startTimestamp),
             (unsigned long long) (memcpy->end - startTimestamp),
             (unsigned long long) (memcpy->end - memcpy->start),
             memcpy->streamId);
      break;
    }
  case CUPTI_ACTIVITY_KIND_KERNEL:
  case CUPTI_ACTIVITY_KIND_CONCURRENT_KERNEL:
    {
      const char* kindString = (record->kind == CUPTI_ACTIVITY_KIND_KERNEL) ? "KERNEL" : "CONC KERNEL";
      CUpti_ActivityKernel2 *kernel = (CUpti_ActivityKernel2 *) record;
      printf("%s %s %llu %llu %llu %u %u %u %u %u %u %u\n",
             kindString,
             kernel->name,
             (unsigned long long) (kernel->start - startTimestamp),
             (unsigned long long) (kernel->end - startTimestamp),
             (unsigned long long) (kernel->end - kernel->start),
             kernel->streamId,
             kernel->gridX, kernel->gridY, kernel->gridZ,
             kernel->blockX, kernel->blockY, kernel->blockZ);
      break;
    }
  default:
    printf("  <unknown>\n");
    break;
  }
}

int cnt1, cnt2;
void CUPTIAPI bufferRequested(uint8_t **buffer, size_t *size, size_t *maxNumRecords)
{
  //printf("bufferRequested %d %d\n", ++cnt1, cnt2);
  uint8_t *bfr = (uint8_t *) malloc(BUF_SIZE + ALIGN_SIZE);
  if (bfr == NULL) {
    printf("Error: out of memory\n");
    exit(-1);
  }

  *size = BUF_SIZE;
  *buffer = ALIGN_BUFFER(bfr, ALIGN_SIZE);
  *maxNumRecords = 0;
  //CUPTI_CALL(cuptiActivityFlushAll(0));
}

void CUPTIAPI bufferCompleted(CUcontext ctx, uint32_t streamId, uint8_t *buffer, size_t size, size_t validSize)
{
  //printf("bufferCompleted %d %d\n", cnt1, ++cnt2);
  CUptiResult status;
  CUpti_Activity *record = NULL;

  if (validSize > 0) {

    do {
      status = cuptiActivityGetNextRecord(buffer, validSize, &record);
      if (status == CUPTI_SUCCESS) {
        printActivity(record);
      }
      else if (status == CUPTI_ERROR_MAX_LIMIT_REACHED)
        break;
      else {
        CUPTI_CALL(status);
      }
    } while (1);

    // report any records dropped from the queue
    size_t dropped;
    CUPTI_CALL(cuptiActivityGetNumDroppedRecords(ctx, streamId, &dropped));
    if (dropped != 0) {
      printf("Dropped %u activity records\n", (unsigned int) dropped);
    }
  }

  free(buffer);
}
#endif
int main(int argc, char* argv[])
{
	try
	{
#if 0
                size_t attrValue = 0, attrValueSize = sizeof(size_t);
                printf("Memcpy record = %d bytes, Kernel record = %d bytes\n", sizeof(CUpti_ActivityMemcpy), sizeof(CUpti_ActivityKernel2));
                //CUPTI_CALL(cuptiActivityEnable(CUPTI_ACTIVITY_KIND_MEMCPY));
                //CUPTI_CALL(cuptiActivityEnable(CUPTI_ACTIVITY_KIND_CONCURRENT_KERNEL));

                //CUPTI_CALL(cuptiActivityRegisterCallbacks(bufferRequested, bufferCompleted));
                CUPTI_CALL(cuptiActivityGetAttribute(CUPTI_ACTIVITY_ATTR_DEVICE_BUFFER_SIZE, &attrValueSize, &attrValue));
                printf("%s = %llu\n", "CUPTI_ACTIVITY_ATTR_DEVICE_BUFFER_SIZE", (long long unsigned)attrValue);
                //attrValue /= 8192;
                //CUPTI_CALL(cuptiActivitySetAttribute(CUPTI_ACTIVITY_ATTR_DEVICE_BUFFER_SIZE, &attrValueSize, &attrValue));

                CUPTI_CALL(cuptiActivityGetAttribute(CUPTI_ACTIVITY_ATTR_DEVICE_BUFFER_POOL_LIMIT, &attrValueSize, &attrValue));
                printf("%s = %llu\n", "CUPTI_ACTIVITY_ATTR_DEVICE_BUFFER_POOL_LIMIT", (long long unsigned)attrValue);
                //attrValue /= 4;
                //CUPTI_CALL(cuptiActivitySetAttribute(CUPTI_ACTIVITY_ATTR_DEVICE_BUFFER_POOL_LIMIT, &attrValueSize, &attrValue));

                CUPTI_CALL(cuptiGetTimestamp(&startTimestamp));
#endif
                //evqm = new EvqueueManager(); 
                EvqueueCreate(1);

		#ifdef NNFORGE_CUDA_BACKEND_ENABLED
		nnforge::cuda::cuda::init();
		#else
		nnforge::plain::plain::init();
		#endif

		#ifdef NNFORGE_CUDA_BACKEND_ENABLED
		imagenet_toolset ts(nnforge::factory_generator_smart_ptr(new nnforge::cuda::factory_generator_cuda()));
		#else
		imagenet_toolset ts(nnforge::factory_generator_smart_ptr(new nnforge::plain::factory_generator_plain()));
		#endif

		try
		{
			if (ts.parse(argc, argv))
				ts.do_action();
		}
		catch (const std::exception& e)
		{
			std::cout << "Exception caught: " << e.what() << std::endl;
			return 1;
		}
	}
	catch (const std::exception& e)
	{
		std::cout << "Exception caught: " << e.what() << std::endl;
		return 1;
	}

        //delete evqm;
	EvqueueDestroy();
	return 0;
}
