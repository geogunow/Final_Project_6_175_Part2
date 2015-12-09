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
	mc_incrementers
	mc_spin_lock
	mc_multiply2
	mc_dekker
	)

vmh_dir=../../programs/build/mc_bench/vmh
tso_vmh_dir=../../programs/build/mc_bench_tso/vmh
log_dir=logs
wait_time=3

# create bsim log dir
mkdir -p ${log_dir}

# kill previous bsim if any
pkill bluetcl

# run each test
for test_name in ${bmarks_tests[@]}; do
	# copy vmh file
	if [ "$test_name" = "mc_dekker" ]; then
		mem_file=${tso_vmh_dir}/${test_name}.riscv.vmh
	else
		mem_file=${vmh_dir}/${test_name}.riscv.vmh
	fi
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
