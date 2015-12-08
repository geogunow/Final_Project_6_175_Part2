#!/bin/bash

if [ $# -ne 1 ]; then
	echo "Usage ./run_mc_bmarks.sh <proc name>"
	exit
fi

simdut=${1}_dut

bmarks_tests=(
	mc_incrementers
	mc_print
	mc_hello
	mc_produce_consume
	mc_median
	mc_vvadd
	mc_multiply
	mc_dekker
	mc_incrementers
	mc_spin_lock
	mc_multiply2
	)

vmh_dir=../../programs/build/mc_bench/vmh
log_dir=logs
wait_time=3

# create bsim log dir
mkdir -p ${log_dir}

# kill previous bsim if any
pkill bluetcl

# run each test
for test_name in ${bmarks_tests[@]}; do
	# copy vmh file
	mem_file=${vmh_dir}/${test_name}.riscv.vmh
	if [ ! -f $mem_file ]; then
		echo "ERROR: $mem_file does not exit, you need to first compile"
		exit
	fi
	cp ${mem_file} mem.vmh 

	# run test
	./${simdut} > ${log_dir}/${test_name}.log & # run bsim, redirect outputs to log
	sleep ${wait_time} # wait for bsim to setup
	./tb $mem_file # run test bench
	echo ""
done
