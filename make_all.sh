#!/bin/bash -x
mkdir -p lib
mkdir -p bin
cd nnforge
make -j12 $@
cd plain
make -j12 $@
cd ../cuda
make -j12 $@
cd ../..
cd examples
for i in ./*
do
	if [ -d "$i" ];then
		cd $i
		make -j12 $@
		cd ..
	fi
done
cd ..
cd apps
for i in ./*
do
	if [ -d "$i" ];then
		cd $i
		make -j12 $@
		cd ..
	fi
done
cd ..

