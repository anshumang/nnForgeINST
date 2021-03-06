APP_NAME=$(shell basename `pwd`)
TARGET=../../bin/$(APP_NAME)
CONFIG_FILE=$(TARGET).cfg
SOURCES+=$(wildcard *.cpp)
OBJECTS+=$(patsubst %.cpp,%.o,$(wildcard *.cpp))
INPUT_DIRECTORY_SEPARATOR?=/
WORKING_DIRECTORY_SEPARATOR?=/

WORKING_FILES_SRC=$(wildcard working_data/*.*)
WORKING_FILES_DST=$(WORKING_FILES_SRC:working_data/%=$(NNFORGE_WORKING_DATA_PATH)$(WORKING_DIRECTORY_SEPARATOR)$(APP_NAME)/%)

all: $(TARGET) $(CONFIG_FILE) $(WORKING_FILES_DST)

$(OBJECTS): $(SOURCES)

$(TARGET): $(OBJECTS) $(LDLIBSDEPEND)
	$(CXX) -o $(TARGET) $(OBJECTS) $(LDLIBSDEPEND) $(LDFLAGS)

$(NNFORGE_WORKING_DATA_PATH)$(WORKING_DIRECTORY_SEPARATOR)$(APP_NAME)/%: working_data/%
	mkdir -p $(NNFORGE_WORKING_DATA_PATH)$(WORKING_DIRECTORY_SEPARATOR)$(APP_NAME)
	cp $< $@

$(CONFIG_FILE): config.cfg
	$(RM) $(CONFIG_FILE)
	echo 'input_data_folder=$(NNFORGE_INPUT_DATA_PATH)/$(APP_NAME)' >> $(CONFIG_FILE)
	echo 'working_data_folder=$(NNFORGE_WORKING_DATA_PATH)/$(APP_NAME)' >> $(CONFIG_FILE)
	cat config.cfg >> $(CONFIG_FILE)

clean:
	$(RM) $(OBJECTS) $(TARGET) $(CONFIG_FILE)

.PHONY: all clean
